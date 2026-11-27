#!/usr/bin/env bash
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
python3 -I - "$root" "$scratch" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import unittest

root, scratch = map(Path, sys.argv[1:])
sys.argv[1:] = []
profile = root / "skills/odd-flow/scripts/profile.py"
script = root / "scripts/session-start.py"
conversation = "agy-conversation-test"
env = {
    "PATH": os.environ["PATH"],
    "HOME": str(scratch),
    "ODD_FLOW_HOME": str(scratch / "profiles"),
    "CLAUDE_PLUGIN_ROOT": str(scratch / "wrong-claude-root"),
    "PLUGIN_ROOT": str(scratch / "wrong-codex-root"),
    "CLAUDE_CODE_SESSION_ID": "wrong-claude-session",
    "CODEX_THREAD_ID": "wrong-codex-session",
}


def set_session_mode(mode):
    subprocess.run(
        [sys.executable, "-I", str(profile), "session-mode", mode],
        env={k: v for k, v in env.items() if k in ("PATH", "HOME", "ODD_FLOW_HOME")}
        | {"ANTIGRAVITY_CONVERSATION_ID": conversation},
        check=True, capture_output=True,
    )


class AntigravityPluginCheck(unittest.TestCase):
    def run_hook(self, stdin, hook_env=env, cwd=root, script="session-start.py"):
        result = subprocess.run(
            [sys.executable, "-I", f"./scripts/{script}", "--runtime", "antigravity"],
            input=stdin, env=hook_env, cwd=cwd, check=True, capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(result.stderr, "")
        output = json.loads(result.stdout)
        self.assertEqual(set(output), {"injectSteps"})
        return output["injectSteps"]

    def message(self, steps):
        step, = steps
        self.assertEqual(set(step), {"systemMessage"})
        self.assertEqual(set(step["systemMessage"]), {"systemMessage"})
        return step["systemMessage"]["systemMessage"]

    def test_manifest_selects_default_skill(self):
        manifest = json.loads((root / ".antigravity-plugin/plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "odd-flow")
        self.assertNotIn("skills", manifest)
        self.assertNotIn("hooks", manifest)
        self.assertTrue((root / "skills/odd-flow/SKILL.md").is_file())

    def test_three_native_hooks(self):
        # Antigravity's root hooks.json maps a hook name to per-event handlers: flat for
        # SessionStart and PreInvocation, grouped (matcher + hooks) for PreToolUse.
        config = json.loads((root / "hooks.json").read_text(encoding="utf-8"))
        spec, = config.values()
        self.assertEqual(set(spec), {"SessionStart", "PreInvocation", "PreToolUse"})
        commands = {
            "SessionStart": ("session-start.py", spec["SessionStart"]),
            "PreInvocation": ("prompt-submit.py", spec["PreInvocation"]),
        }
        group, = spec["PreToolUse"]
        self.assertEqual(set(group), {"matcher", "hooks"})
        commands["PreToolUse"] = ("pre-tool-use.py", group["hooks"])
        for event, (name, handlers) in commands.items():
            with self.subTest(event=event):
                hook, = handlers
                self.assertEqual(set(hook), {"type", "command"})
                self.assertEqual(hook["type"], "command")
                self.assertEqual(
                    shlex.split(hook["command"]),
                    ["python3", "-I", f"./scripts/{name}", "--runtime", "antigravity"],
                )
                self.assertNotIn("PLUGIN_ROOT", hook["command"])
                self.assertTrue((root / "scripts" / name).is_file())

    def test_conversation_id_beats_inherited_ids(self):
        set_session_mode("full-delegation")
        payload = json.dumps({"conversationId": conversation})
        text = self.message(self.run_hook(payload))
        core = root / "skills/odd-flow/assets/core-block-full-delegation.md"
        self.assertTrue(text.startswith(core.read_text(encoding="utf-8").strip()))
        self.assertIn("session key: ANTIGRAVITY_CONVERSATION_ID; agent: antigravity", text)
        self.assertIn("mode: full-delegation", text)
        self.assertNotIn("wrong-", text)

    def test_organic_mode(self):
        payload = json.dumps({"conversationId": "agy-organic"})
        text = self.message(self.run_hook(payload))
        core = root / "skills/odd-flow/assets/core-block.md"
        self.assertTrue(text.startswith(core.read_text(encoding="utf-8").strip()))
        self.assertIn("session key: ANTIGRAVITY_CONVERSATION_ID; agent: antigravity", text)

    def test_ignores_foreign_plugin_roots(self):
        text = self.message(self.run_hook(json.dumps({"conversationId": conversation})))
        self.assertNotIn("core block unavailable", text)

    def test_mode_switch_on_first_invocation_only(self):
        hook_env = dict(env, PLUGIN_DATA=str(scratch / "data"))

        def prompt(number):
            return self.run_hook(json.dumps({
                "conversationId": conversation, "invocationNum": number, "lastUserInput": "hello",
            }), hook_env, script="prompt-submit.py")

        set_session_mode("full-delegation")
        self.run_hook(json.dumps({"conversationId": conversation, "source": "startup"}), hook_env)
        self.assertEqual(
            self.message(prompt(0)),
            "odd-flow mode: full-delegation (session (ANTIGRAVITY_CONVERSATION_ID)). "
            "The parent coordinates and writes only what the mode file lists; bounded writers "
            "make all other workspace changes. Rules: skills/odd-flow/references/mode-full-delegation.md.",
        )
        set_session_mode("organic")
        self.assertEqual(prompt(1), [])
        self.assertEqual(
            self.message(prompt(0)),
            "odd-flow mode changed to organic (session (ANTIGRAVITY_CONVERSATION_ID)); "
            "the session-start full-delegation rules no longer apply. "
            "Rules: skills/odd-flow/references/mode-organic.md.",
        )
        self.assertEqual(prompt(0), [])

    def test_first_prompt_worker_marker(self):
        tokens = scratch / "worker-tokens"
        tokens.mkdir(mode=0o700)
        hook_env = dict(env, ODD_FLOW_STATE_DIR=str(scratch), PLUGIN_DATA=str(scratch / "marker-data"),
                        ODD_ORCHESTRATOR_MODE="full-delegation")
        worker = ("You are a dispatched worker. Follow your spec's role rules, "
                  "not the coordinator rules from session start.")

        def issue(token, role="review", age_ms=0):
            record = tokens / hashlib.sha256(token.encode("ascii")).hexdigest()
            with os.fdopen(os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
                json.dump({"role": role, "issuedAt": time.time_ns() // 1_000_000 - age_ms}, stream)
            return record

        def prompt(session, value):
            payload = json.dumps({"conversationId": session, "invocationNum": 0, "lastUserInput": value})
            return self.message(self.run_hook(payload, hook_env, script="prompt-submit.py"))

        def marker_context(session, tail):
            return prompt(session, "Updated Orca dispatch\n" + tail)

        def parent(context):
            self.assertTrue(context.startswith("odd-flow mode: full-delegation"), context)

        token = "1" * 32
        record = issue(token)
        with self.subTest(scenario="valid-token"):
            self.assertEqual(marker_context("trailing-worker", f"\n  ODD-Flow-Worker: ReViEw {token}  \n"),
                             worker)
        with self.subTest(scenario="consumed"):
            self.assertFalse(record.exists())
        with self.subTest(scenario="reused-token"):
            parent(marker_context("reused-token", f"odd-flow-worker: review {token}"))

        token = "b" * 32
        record = issue(token, "write")
        dispatch = f"You are working inside Orca, a multi-agent IDE.\n# Role: write\n\nodd-flow-worker: write {token}"
        for session in ("tokened-dispatch", "reused-tokened-dispatch"):
            with self.subTest(scenario=session):
                self.assertEqual(prompt(session, dispatch), worker)
                self.assertFalse(record.exists())

        with self.subTest(scenario="bare-marker"):
            parent(marker_context("bare-marker", "odd-flow-worker: review"))

        for session, digit, role, age_ms in (
            ("wrong-role", "2", "verify", 0),
            ("expired-token", "3", "review", 16 * 60_000),
            ("future-token", "4", "review", -120_000),
            ("malformed-token", "A", "review", 0),
            ("missing-record", "5", None, 0),
        ):
            with self.subTest(scenario=session):
                token = digit * 32
                if role is not None:
                    issue(token, role, age_ms)
                parent(marker_context(session, f"odd-flow-worker: review {token}"))

        for session, tag_id, digit in (
            ("quoted-worker", '"Brief_9-a"', "6"),
            ("unquoted-worker", "Brief_9-a", "7"),
            ("wrapped-parent", '"Brief_9-a"', None),
            ("double-closing", '"Brief_9-a"', "8"),
        ):
            with self.subTest(scenario=session):
                closing = f"</pasted_content id={tag_id}>"
                value = f"<pasted_content id={tag_id}>\nTask text\n"
                if digit is not None:
                    token = digit * 32
                    issue(token)
                    value += f"odd-flow-worker: review {token}\n \t\n"
                value += closing
                if session == "double-closing":
                    value += "\n" + closing
                context = marker_context(session, value)
                if session.endswith("-worker"):
                    self.assertEqual(context, worker)
                else:
                    parent(context)

        self.assertEqual(prompt("preamble", "You are working inside Orca, a multi-agent IDE.\nTask"), worker)
        self.assertEqual(prompt("first-line-role", "# Role: review\nTask"), worker)

        token = "0" * 32
        record = issue(token)
        tokens.chmod(0o755)
        with self.subTest(scenario="loose-worker-tokens"):
            parent(marker_context("loose-worker-tokens", f"odd-flow-worker: review {token}"))
            self.assertTrue(record.is_file())

    def test_malformed_input_stays_valid(self):
        for stdin in ("not json", "", "[]", '{"conversationId": 7}'):
            with self.subTest(stdin=stdin):
                steps = self.run_hook(stdin)
                self.assertIsInstance(steps, list)
                for step in steps:
                    self.assertEqual(set(step), {"systemMessage"})

    def test_profile_failure_keeps_organic_fallback(self):
        broken = dict(env, ODD_FLOW_HOME=str(scratch / "missing" / "file"))
        (scratch / "missing").write_text("not a directory", encoding="utf-8")
        text = self.message(self.run_hook(json.dumps({"conversationId": conversation}), broken))
        self.assertIn("organic", text.lower())


unittest.main()
PY
