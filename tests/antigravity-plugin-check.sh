#!/usr/bin/env bash
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 -I - "$root" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
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
    def run_hook(self, stdin, hook_env=env, cwd=root):
        result = subprocess.run(
            [sys.executable, "-I", "./scripts/session-start.py", "--runtime", "antigravity"],
            input=stdin, env=hook_env, cwd=cwd, check=True, capture_output=True, text=True,
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
        manifest = json.loads((root / ".antigravity-plugin/plugin.json").read_text())
        self.assertEqual(manifest["name"], "odd-flow")
        self.assertNotIn("skills", manifest)
        self.assertNotIn("hooks", manifest)
        self.assertTrue((root / "skills/odd-flow/SKILL.md").is_file())

    def test_three_native_hooks(self):
        # Antigravity's root hooks.json maps a hook name to per-event handlers: flat for
        # SessionStart and PreInvocation, grouped (matcher + hooks) for PreToolUse.
        config = json.loads((root / "hooks.json").read_text())
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
        self.assertTrue(text.startswith(core.read_text().strip()))
        self.assertIn("session key: ANTIGRAVITY_CONVERSATION_ID; agent: antigravity", text)
        self.assertIn("mode: full-delegation", text)
        self.assertNotIn("wrong-", text)

    def test_organic_mode(self):
        payload = json.dumps({"conversationId": "agy-organic"})
        text = self.message(self.run_hook(payload))
        core = root / "skills/odd-flow/assets/core-block.md"
        self.assertTrue(text.startswith(core.read_text().strip()))
        self.assertIn("session key: ANTIGRAVITY_CONVERSATION_ID; agent: antigravity", text)

    def test_ignores_foreign_plugin_roots(self):
        text = self.message(self.run_hook(json.dumps({"conversationId": conversation})))
        self.assertNotIn("core block unavailable", text)

    def test_malformed_input_stays_valid(self):
        for stdin in ("not json", "", "[]", '{"conversationId": 7}'):
            with self.subTest(stdin=stdin):
                steps = self.run_hook(stdin)
                self.assertIsInstance(steps, list)
                for step in steps:
                    self.assertEqual(set(step), {"systemMessage"})

    def test_profile_failure_keeps_organic_fallback(self):
        broken = dict(env, ODD_FLOW_HOME=str(scratch / "missing" / "file"))
        (scratch / "missing").write_text("not a directory")
        text = self.message(self.run_hook(json.dumps({"conversationId": conversation}), broken))
        self.assertIn("organic", text.lower())


unittest.main()
PY
