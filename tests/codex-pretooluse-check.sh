#!/usr/bin/env bash
# Replay Codex 0.171.0 hook stdin through the plugin's configured command.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
printf 'Codex PreToolUse check scratch: %s\n' "$scratch"
python3 -I - "$root" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import unittest

root, scratch = map(Path, sys.argv[1:])
sys.argv[1:] = []
scratch = scratch.resolve()
workspace = scratch / "repo"
folder = scratch / "folder"
temp = scratch / "temp"
profiles = scratch / "profiles"
for directory in (workspace / "odd/tasks/nested", workspace / "src", folder, temp, profiles):
    directory.mkdir(parents=True)
(workspace / "odd/tasks/link.md").symlink_to(workspace / "src/code.py")
(workspace / "src/link").symlink_to(workspace / "odd/tasks", target_is_directory=True)
(workspace / "odd/tasks/link-target.md").write_text("task")
(workspace / "src/task-link.md").symlink_to(workspace / "odd/tasks/link-target.md")
env = {
    "PATH": os.environ["PATH"], "HOME": str(scratch), "TMPDIR": str(temp),
    "PLUGIN_ROOT": str(root), "PLUGIN_DATA": str(scratch / "codex-data"),
    "CLAUDE_PLUGIN_ROOT": str(scratch / "wrong-root"),
    "CLAUDE_PLUGIN_DATA": str(scratch / "wrong-data"),
    "CLAUDE_CODE_SESSION_ID": "wrong-session", "CLAUDE_PROJECT_DIR": str(temp),
    "CODEX_THREAD_ID": "wrong-session", "ODD_FLOW_HOME": str(profiles),
}
(profiles / "profiles.json").write_text('{"default":"org","profiles":{"org":{}}}')
subprocess.run(["git", "init", "-q", str(workspace)], env=env, check=True)
for session in ("parent", "worker"):
    subprocess.run(
        [sys.executable, "-I", str(root / "skills/odd-flow/scripts/profile.py"),
         "session-mode", "full-delegation"],
        env={**env, "CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": session},
        check=True, capture_output=True,
    )
manifest = json.loads((root / ".codex-plugin/plugin.json").read_text())
hooks = json.loads((root / manifest["hooks"]).read_text())["hooks"]


def run_hook(command, payload):
    argv = [arg.replace("${PLUGIN_ROOT}", env["PLUGIN_ROOT"]) for arg in shlex.split(command)]
    return subprocess.run(argv, input=json.dumps(payload), cwd=scratch, env=env,
                          capture_output=True, text=True, timeout=10)


prompt, = hooks["UserPromptSubmit"][0]["hooks"]
result = run_hook(prompt["command"], {
    "hook_event_name": "UserPromptSubmit", "session_id": "worker",
    "prompt": "You are working inside Orca, a multi-agent IDE.\n# Role: write",
})
assert result.returncode == 0 and not result.stderr
assert "You are a dispatched worker" in result.stdout

writer = "# Role: write"
valid = writer + "\n\n## Allowed edit surfaces\nsrc/code.py\n"
invalid = writer + "\n\n## Allowed edit surfaces\n../bad\n"
(workspace / "src/valid spec.md").write_text(valid)
(workspace / "src/invalid.md").write_text(invalid)


class CodexPreToolUseCheck(unittest.TestCase):
    def check(self, tool, args, *reason, session="parent", cwd=workspace / "src", **identity):
        entry, = [item for item in hooks["PreToolUse"] if re.search(item["matcher"], tool)]
        hook, = entry["hooks"]
        result = run_hook(hook["command"], {
            "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": args,
            "session_id": session, "cwd": str(cwd), **identity,
        })
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        if not reason:
            self.assertEqual(result.stdout, "")
        else:
            self.assertTrue(result.stdout, f"expected denial containing {reason}")
            output = json.loads(result.stdout)["hookSpecificOutput"]
            self.assertEqual(output["hookEventName"], "PreToolUse")
            self.assertEqual(output["permissionDecision"], "deny")
            for part in reason:
                self.assertIn(part, output["permissionDecisionReason"])

    def patch(self, body, *reason, **payload):
        self.check("apply_patch", {"command": f"*** Begin Patch\n{body}\n*** End Patch\n"},
                   *reason, **payload)

    def test_closed_parent_paths_and_atomic_mixed_patch(self):
        allowed = "*** Add File: ../odd/tasks/new.md\n+new"
        self.patch(allowed)
        self.patch(allowed + "\n*** Delete File: code.py", "code.py", "bounded writer")
        self.patch("*** Add File: ../odd/tasks/nested/new.md\n+new", "nested/new.md")
        self.patch("*** Add File: ../odd/tasks/link.md\n+new", "link.md")
        self.patch("*** Add File: link/../tasks/new.md\n+new", "tasks/new.md")
        case_alias = workspace.with_name(workspace.name.upper())
        if case_alias.exists() and case_alias.samefile(workspace):
            self.patch(f"*** Add File: {case_alias}/src/code.py\n+new", "code.py")

    def test_both_move_targets(self):
        self.patch("*** Update File: code.py\n*** Move to: ../odd/tasks/new.md", "code.py")
        self.patch("*** Update File: ../odd/tasks/old.md\n*** Move to: code.py", "code.py")
        self.patch("*** Update File: ../odd/tasks/old.md\n*** Move to: ../odd/tasks/new.md")
        self.patch("*** Delete File: task-link.md", "task-link.md")

    def test_outside_gate_and_non_git_cwd(self):
        self.patch(f"*** Add File: {temp}/allowed.txt\n+x")
        external = "/odd-flow-fixture-external/denied.txt"  # Classified only; never written.
        self.patch(f"*** Add File: {external}\n+x", external, "named the file", "exact diff")
        self.patch("*** Add File: new.py\n+x", "new.py", "bounded writer", cwd=folder)

    def test_malformed_or_unclassifiable(self):
        for args in ({}, {"command": "not a patch"}, {"command": []}, {
            "command": "*** Begin Patch\n*** Add File: ../odd/tasks/new.md\ninvalid\n*** End Patch",
        }):
            with self.subTest(args=args):
                self.check("apply_patch", args, "Could not verify")
        self.patch("*** Environment ID: remote\n*** Add File: ../odd/tasks/new.md\n+x",
                   "Could not verify")

    def test_recognized_worker_and_organic_exemptions(self):
        body = "*** Add File: code.py\n+x"
        self.patch(body, session="organic")
        self.patch(body, session="worker")
        self.patch(body, agent_id="native-child", agent_type="default")
        self.patch(body, "code.py", agent_type="write", model="worker-model")

    def test_literal_orca_writer_launches_in_both_modes(self):
        for session in ("parent", "organic"):
            with self.subTest(session=session):
                self.check("Bash", {"command": "orca orchestration task-create --spec-file invalid.md"},
                           "invalid.md", "../bad", session=session)
                self.check("Bash", {"command": "orca orchestration task-create --spec-file 'valid spec.md'"},
                           session=session)
                self.check("Bash", {"command": f"orca orchestration worker-start --spec {shlex.quote(writer)}"},
                           "Allowed edit surfaces", session=session)
                self.check("Bash", {"command": f"orca orchestration worker-start --spec={shlex.quote(valid)}"},
                           session=session)
        self.check("Bash", {"command": "orca orchestration worker-start --task existing"})
        self.check("Bash", {"command": "printf x > code.py"})

    def test_native_writer_message_and_text_items(self):
        self.check("spawn_agent", {"message": writer}, "Allowed edit surfaces")
        self.check("spawn_agent", {"message": valid})
        self.check("spawn_agent", {"items": [{"type": "text", "text": invalid}]},
                   "../bad", session="organic")
        self.check("spawn_agent", {"items": [{"type": "text", "text": writer},
                                           {"type": "text", "text": valid[len(writer):]}]},
                   session="organic")
        self.check("spawn_agent", {"message": "# Role: explore", "agent_type": "write"})


unittest.main(verbosity=2)
PY
