#!/usr/bin/env bash
# Replay Antigravity 1.5.16 PreInvocation and PreToolUse hook stdin through the plugin's configured commands.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 -I - "$root" "$scratch" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import unittest

root, scratch = map(Path, sys.argv[1:])
sys.argv[1:] = []
scratch = scratch.resolve()
workspace = scratch / "repo"
temp = scratch / "temp"
profiles = scratch / "profiles"
for directory in (workspace / "odd/tasks", workspace / "src", temp, profiles):
    directory.mkdir(parents=True)
(workspace / "src/link.md").symlink_to(workspace / "src/code.py")
(workspace / "odd/tasks/link.md").symlink_to(workspace / "src/code.py")
env = {
    "PATH": os.environ["PATH"], "HOME": str(scratch), "TMPDIR": str(temp),
    "PLUGIN_DATA": str(scratch / "data"), "ODD_FLOW_HOME": str(profiles),
    "PLUGIN_ROOT": str(scratch / "wrong-root"), "CLAUDE_PLUGIN_ROOT": str(scratch / "wrong-root"),
    "CLAUDE_CODE_SESSION_ID": "wrong-session", "CODEX_THREAD_ID": "wrong-session",
}
(profiles / "profiles.json").write_text('{"default":"org","profiles":{"org":{}}}')
subprocess.run(["git", "init", "-q", str(workspace)], env=env, check=True)
profile = root / "skills/odd-flow/scripts/profile.py"
for conversation in ("parent", "worker"):
    subprocess.run(
        [sys.executable, "-I", str(profile), "session-mode", "full-delegation"],
        env={k: v for k, v in env.items() if k in ("PATH", "HOME", "ODD_FLOW_HOME")}
        | {"ANTIGRAVITY_CONVERSATION_ID": conversation},
        check=True, capture_output=True,
    )
hooks, = json.loads((root / "hooks.json").read_text()).values()
writer = "# Role: write"
valid = writer + "\n\n## Allowed edit surfaces\nsrc/code.py\n"
invalid = writer + "\n\n## Allowed edit surfaces\n../bad\n"
(workspace / "src/valid.md").write_text(valid)
(workspace / "src/invalid.md").write_text(invalid)


def run_hook(command, payload, hook_env=env):
    result = subprocess.run(shlex.split(command), input=json.dumps(payload), cwd=root,
                            env=hook_env, capture_output=True, text=True, timeout=10)
    assert (result.returncode, result.stderr) == (0, ""), result
    return json.loads(result.stdout)


class PreInvocationCheck(unittest.TestCase):
    OMIT = object()

    def invoke(self, conversation, prompt, number=0, **extra):
        hook, = hooks["PreInvocation"]
        self.assertEqual(shlex.split(hook["command"]),
                         ["python3", "-I", "./scripts/prompt-submit.py", "--runtime", "antigravity"])
        payload = {"conversationId": conversation, "lastUserInput": prompt, "invocationNum": number,
                   "initialNumSteps": 0, "cwd": str(workspace), "workspacePaths": [str(workspace)],
                   "hookEventName": "PreInvocation"} | extra
        if number is self.OMIT:
            del payload["invocationNum"]
        output = run_hook(hook["command"], payload)
        self.assertEqual(set(output), {"injectSteps"})
        return output["injectSteps"]

    def text(self, steps):
        step, = steps
        return step["systemMessage"]["systemMessage"]

    def test_parent_reinjection_only_on_first_invocation(self):
        for number in (0, self.OMIT, None):
            self.assertIn("odd-flow mode: full-delegation", self.text(self.invoke("parent", "hello", number=number)))
        for number in (1, 2, "0"):
            self.assertEqual(self.invoke("parent", "hello", number=number), [])

    def test_worker_marker_and_message(self):
        steps = self.invoke("worker", "You are working inside Orca, a multi-agent IDE.\n# Role: write")
        self.assertIn("You are a dispatched worker", self.text(steps))
        marker = scratch / "data/prompt-sessions" / hashlib.sha256(b"worker").hexdigest()
        self.assertEqual(marker.read_text(), "worker")
        self.assertIn("You are a dispatched worker", self.text(self.invoke("worker", "later prompt")))

    def test_organic_and_malformed_inputs_emit_nothing(self):
        self.assertEqual(self.invoke("organic-session", "hello"), [])
        hook, = hooks["PreInvocation"]
        for stdin in ("not json", "", "[]"):
            result = subprocess.run(shlex.split(hook["command"]), input=stdin, cwd=root, env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual((result.returncode, result.stderr), (0, ""))
            self.assertEqual(json.loads(result.stdout), {"injectSteps": []})

    def test_empty_stdin_emits_nothing_under_full_delegation_default(self):
        fd_profiles = scratch / "fd-profiles"
        fd_profiles.mkdir(exist_ok=True)
        (fd_profiles / "profiles.json").write_text(json.dumps({
            "default": "fd",
            "profiles": {"fd": {}},
            "workflow": {"fd": {"orchestratorMode": "full-delegation"}},
        }))
        fd_env = dict(env, ODD_FLOW_HOME=str(fd_profiles))
        hook, = hooks["PreInvocation"]
        for stdin in ("", "not json", "[]", "null"):
            result = subprocess.run(
                shlex.split(hook["command"]), input=stdin, cwd=root, env=fd_env,
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual((result.returncode, result.stderr), (0, ""))
            self.assertEqual(json.loads(result.stdout), {"injectSteps": []})


class PreToolUseCheck(unittest.TestCase):
    def check(self, name, args, decision="allow", *reason, conversation="parent", **payload):
        entry, = hooks["PreToolUse"]
        self.assertIn("matcher", entry)
        hook, = entry["hooks"]
        self.assertEqual(shlex.split(hook["command"]),
                         ["python3", "-I", "./scripts/pre-tool-use.py", "--runtime", "antigravity"])
        output = run_hook(hook["command"], {
            "toolCall": {"id": "call-1", "name": name, "args": args}, "conversationId": conversation,
            "cwd": str(workspace / "src"), "workspacePaths": [str(workspace)],
            "hookEventName": "PreToolUse"} | payload)
        self.assertEqual(output["decision"], decision)
        if decision == "allow":
            self.assertNotIn("reason", output)
        else:
            self.assertTrue(output["reason"].startswith("odd-flow: "))
            for part in reason:
                self.assertIn(part, output["reason"])

    def test_tool_matcher_covers_guarded_tools(self):
        import re
        entry, = hooks["PreToolUse"]
        for tool in ("write_file", "edit_file", "write_to_file", "replace_file_content",
                     "multi_replace_file_content", "run_command", "invoke_subagent"):
            self.assertRegex(tool, entry["matcher"])

    def test_closed_parent_paths(self):
        for tool, field in (("write_file", "Path"), ("replace_file_content", "TargetFile")):
            self.check(tool, {field: "../odd/tasks/new.md"})
            self.check(tool, {field: "code.py"}, "deny", "bounded writer")
            self.check(tool, {field: str(temp / "x.txt")})
        self.check("write_file", {"Path": "link.md"}, "deny")
        self.check("write_file", {"Path": "../odd/tasks/link.md"}, "deny")
        self.check("edit_file", {"Path": "code.py"}, "deny", cwd=None)
        self.check("write_file", {}, "deny")
        external = "/odd-flow-fixture-external/denied.txt"
        self.check("write_file", {"Path": external}, "force_ask", "named the file", "exact diff")

    def test_git_workspace_path_without_cwd_uses_git_top_level(self):
        entry, = hooks["PreToolUse"]
        hook, = entry["hooks"]
        for path, decision in (("../README.md", "deny"), ("../odd/tasks/x.md", "allow")):
            with self.subTest(path=path):
                output = run_hook(hook["command"], {
                    "toolCall": {"name": "write_file", "args": {"Path": path}},
                    "conversationId": "parent", "workspacePaths": [str(workspace / "src")],
                    "hookEventName": "PreToolUse",
                })
                self.assertEqual(output["decision"], decision)

    def test_non_git_workspace_root_is_separate_from_relative_edit_base(self):
        project = scratch / "non-git"
        nested = project / "src"
        nested.mkdir(parents=True)
        for path, decision in (("../README.md", "deny"),
                               ("../odd/tasks/new.md", "allow"),
                               ("odd/tasks/new.md", "deny")):
            with self.subTest(path=path):
                self.check("write_file", {"Path": path}, decision, cwd=str(nested),
                           workspacePaths=[str(workspace), str(project)])
        self.check("write_file", {"Path": "../README.md"}, "deny",
                   cwd=str(workspace / "src"), workspacePaths=[str(project)])
        self.check("write_file", {"Path": "README.md"}, "deny",
                   cwd=None, workspacePaths=[str(project)])
        elsewhere = scratch / "elsewhere"
        elsewhere.mkdir()
        self.check("write_file", {"Path": str(project / "README.md")}, "deny",
                   cwd=str(elsewhere), workspacePaths=[str(project), str(workspace)])

    def test_edit_denied_when_worker_classification_fails(self):
        isolated = scratch / "broken-hooks"
        isolated.mkdir()
        hook_copy = isolated / "pre-tool-use.py"
        shutil.copyfile(root / "scripts/pre-tool-use.py", hook_copy)
        command = shlex.join([sys.executable, "-I", str(hook_copy), "--runtime", "antigravity"])
        payload = {"conversationId": "parent", "cwd": str(workspace),
                   "toolCall": {"name": "write_file", "args": {"Path": "README.md"}}}
        for failure in ("missing helper", "worker marker exception"):
            with self.subTest(failure=failure):
                if failure == "worker marker exception":
                    (isolated / "prompt-submit.py").write_text(
                        "def is_worker_session(session):\n    raise OSError('broken marker')\n")
                output = run_hook(command, payload)
                self.assertEqual(output["decision"], "deny")
                self.assertTrue(output["reason"].startswith("odd-flow: "))
        unrelated = payload | {"toolCall": {"name": "run_command", "args": {"CommandLine": "printf x"}}}
        self.assertEqual(run_hook(command, unrelated), {"decision": "allow"})

    def test_workspace_symlink_to_external_and_temp_denied(self):
        (workspace / "src/link_tmp.txt").symlink_to(temp / "x.txt")
        (workspace / "src/link_ext.txt").symlink_to("/odd-flow-fixture-external/denied.txt")
        (workspace / "odd/tasks/link_ext.md").symlink_to("/odd-flow-fixture-external/denied.txt")
        self.check("write_file", {"Path": "link_tmp.txt"}, "deny")
        self.check("write_file", {"Path": "link_ext.txt"}, "deny")
        self.check("write_file", {"Path": "../odd/tasks/link_ext.md"}, "force_ask", "named the file", "exact diff")

    def test_worker_organic_and_unresolved_mode(self):
        self.check("write_file", {"Path": "code.py"}, conversation="organic-session")
        marker_hook, = hooks["PreInvocation"]
        run_hook(marker_hook["command"], {"conversationId": "worker",
                 "lastUserInput": "# Role: write", "invocationNum": 0})
        self.check("write_file", {"Path": "code.py"}, conversation="worker")
        broken = dict(env, ODD_FLOW_HOME=str(scratch / "missing" / "file"))
        (scratch / "missing").write_text("not a directory")
        entry, = hooks["PreToolUse"]
        hook, = entry["hooks"]
        output = run_hook(hook["command"], {
            "toolCall": {"id": "c", "name": "write_file", "args": {"Path": "code.py"}},
            "conversationId": "unresolved", "cwd": str(workspace)}, broken)
        self.assertEqual(output["decision"], "deny")

    def test_writer_launch_admission_in_both_modes(self):
        for conversation in ("parent", "organic-session"):
            with self.subTest(conversation=conversation):
                self.check("run_command", {"CommandLine": "orca orchestration task-create --spec-file invalid.md"},
                           "deny", "invalid.md", "../bad", conversation=conversation)
                self.check("run_command", {"CommandLine": "orca orchestration task-create --spec-file valid.md"},
                           conversation=conversation)
                self.check("run_command", {"CommandLine": f"orca orchestration worker-start --spec {shlex.quote(writer)}"},
                           "deny", "Allowed edit surfaces", conversation=conversation)
                self.check("invoke_subagent", {"Prompt": writer}, "deny", "Allowed edit surfaces",
                           conversation=conversation)
                self.check("invoke_subagent", {"Prompt": valid}, conversation=conversation)
        self.check("run_command", {"CommandLine": "printf x > code.py"})
        self.check("invoke_subagent", {"Prompt": "# Role: explore"})


unittest.main(verbosity=2)
PY
