#!/usr/bin/env bash
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
printf 'Codex plugin check scratch: %s\n' "$scratch"
python3 -I - "$root" "$scratch" <<'PY'
import hashlib
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
session = "codex-plugin-test"
env = {
    "PATH": os.environ["PATH"],
    "HOME": str(scratch),
    "ODD_FLOW_HOME": str(scratch / "profiles"),
    "PLUGIN_ROOT": str(root),
    "PLUGIN_DATA": str(scratch / "codex-data"),
    "CLAUDE_PLUGIN_ROOT": str(scratch / "wrong-root"),
    "CLAUDE_PLUGIN_DATA": str(scratch / "claude-data"),
    "CLAUDE_CODE_SESSION_ID": "wrong-session",
}


def set_session_mode():
    profile_env = dict(env, CODEX_THREAD_ID=session)
    del profile_env["CLAUDE_CODE_SESSION_ID"]
    subprocess.run(
        [sys.executable, "-I", str(profile), "session-mode", "full-delegation"],
        env=profile_env, check=True, capture_output=True,
    )


class CodexPluginCheck(unittest.TestCase):
    def hook_context(self, script, event, **payload):
        result = subprocess.run(
            [sys.executable, "-I", str(root / "scripts" / script), "--runtime", "codex"],
            input=json.dumps({"session_id": session, "hook_event_name": event, **payload}),
            env=env, check=True, capture_output=True, text=True, encoding="utf-8",
        )
        self.assertEqual(result.stderr, "")
        self.assertTrue(result.stdout, f"{script} did not emit hook JSON")
        output = json.loads(result.stdout)
        self.assertEqual(set(output), {"hookSpecificOutput"})
        specific = output["hookSpecificOutput"]
        self.assertEqual(specific["hookEventName"], event)
        return specific["additionalContext"]

    def test_manifest_and_marketplace(self):
        manifest = json.loads((root / ".codex-plugin/plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "odd-flow")
        self.assertTrue((root / manifest["skills"] / "odd-flow/SKILL.md").is_file())
        self.assertEqual(manifest["hooks"], "./hooks/codex-hooks.json")
        self.assertTrue((root / manifest["hooks"]).is_file())
        market = json.loads((root / ".agents/plugins/marketplace.json").read_text(encoding="utf-8"))
        self.assertEqual(market["name"], "odd-flow")
        entry, = market["plugins"]
        self.assertEqual(entry["name"], manifest["name"])
        self.assertEqual(entry["source"]["source"], "local")
        self.assertEqual((root / entry["source"]["path"]).resolve(), root.resolve())

    def test_only_codex_hook_events_and_commands(self):
        config = json.loads((root / "hooks/codex-hooks.json").read_text(encoding="utf-8"))["hooks"]
        self.assertEqual(set(config), {"SessionStart", "UserPromptSubmit", "PreToolUse"})
        start, = config["SessionStart"]
        self.assertEqual(set(start["matcher"].split("|")), {"startup", "resume", "clear", "compact"})
        submit, = config["UserPromptSubmit"]
        self.assertNotIn("matcher", submit)
        pre, = config["PreToolUse"]
        self.assertEqual(pre["matcher"], "^(apply_patch|spawn_agent|Bash)$")
        for entry, script in ((start, "session-start.py"), (submit, "prompt-submit.py"),
                              (pre, "pre-tool-use.py")):
            hook, = entry["hooks"]
            self.assertEqual(hook["type"], "command")
            self.assertEqual(
                shlex.split(hook["command"]),
                ["python3", "-I", "${PLUGIN_ROOT}/scripts/" + script, "--runtime", "codex"],
            )
            self.assertTrue((root / "scripts" / script).is_file())

    def test_session_start_binds_codex_profile(self):
        set_session_mode()
        context = self.hook_context("session-start.py", "SessionStart", source="startup")
        self.assertIn("SessionStart source: startup", context)
        self.assertIn("session key: CODEX_THREAD_ID; agent: codex", context)
        self.assertNotIn("CLAUDE_CODE_SESSION_ID", context)
        core = root / "skills/odd-flow/assets/core-block-full-delegation.md"
        self.assertTrue(context.startswith(core.read_text(encoding="utf-8").strip()))

    def test_prompt_submit_uses_codex_mode_and_worker_data(self):
        set_session_mode()
        context = self.hook_context("prompt-submit.py", "UserPromptSubmit", prompt="# Role: write")
        self.assertEqual(
            context,
            "You are a dispatched worker. Follow your spec's role rules, not the coordinator rules from session start.",
        )
        key = hashlib.sha256(session.encode()).hexdigest()
        marker = scratch / "codex-data/prompt-sessions" / key
        self.assertEqual(marker.read_text(encoding="utf-8"), "worker")
        self.assertFalse((scratch / "claude-data").exists())


unittest.main()
PY
