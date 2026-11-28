#!/usr/bin/env bash
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
python3 -I - "$ROOT" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

root, scratch = (Path(value).resolve() for value in sys.argv[1:])
sys.argv[1:] = []
script = root / "scripts/pre-tool-use.py"
wrapper = """
import runpy
import sys
sys.platform = sys.argv[1]
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")
"""
env = dict(os.environ, HOME=str(scratch), USERPROFILE=str(scratch),
           XDG_CONFIG_HOME=str(scratch), ODD_FLOW_HOME=str(scratch))
spec = scratch / "valid.md"
spec.write_text("# Role: write\n\n## Allowed edit surfaces\nsrc/code.py\n", encoding="utf-8")

launch = "orca orchestration task-create --spec-file "
relative = launch + "valid.md"
absolute = launch + f"'{spec}'"
readers = ("linux", "win32")
nested_hint = "run orca orchestration directly without a nested shell"
cwd_hint = "pass an absolute --spec-file path or run the launch without changing directory"
verb_hint = "write the literal orchestration verb"


class LaunchGuardCheck(unittest.TestCase):
    def decision(self, reader, command):
        # Send the command as data to the hook; never execute it in a shell.
        payload = {"cwd": str(scratch), "toolCall": {
            "name": "run_command", "args": {"CommandLine": command},
        }}
        result = subprocess.run(
            [sys.executable, "-I", "-c", wrapper, reader, str(script), "--runtime", "antigravity"],
            input=json.dumps(payload), cwd=scratch, env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual((result.returncode, result.stderr), (0, ""), result)
        return json.loads(result.stdout)

    def deny(self, reader, command, hint):
        output = self.decision(reader, command)
        self.assertEqual(output["decision"], "deny", output)
        self.assertIn(hint, output["reason"])

    def allow(self, reader, command):
        self.assertEqual(self.decision(reader, command), {"decision": "allow"})

    def test_nested_shell_launches_require_direct_commands(self):
        for reader in readers:
            for program, option in (
                ("PoWeRsHeLl.EXE", "-Command"), ("pwsh", "-Command"), ("cmd", "/c"),
                ("env bash", "-c"), ("env -u KEY bash", "-c"), ("/bin/sh", "-c"),
                (r"'C:\tools\PWSh.cmd'", "-Command"),
            ):
                with self.subTest(reader=reader, program=program):
                    self.deny(reader, f"{program} {option} orca orchestration task-create --help", nested_hint)
            with self.subTest(reader=reader, quoted=True):
                self.deny(reader, f"bash -c '{relative}'", nested_hint)

    def test_relative_file_after_directory_change(self):
        for reader in readers:
            for change, separator in (
                ("cd folder", ";"), ("SET-LOCATION folder", "&&"), ("Push-Location folder", "||"),
                ("pushd folder", "|"), ("popd", "\n"), ("sl folder", ";"), ("chdir folder", ";"),
                ("Pop-Location", ";"),
            ):
                with self.subTest(reader=reader, change=change):
                    self.deny(reader, f"{change}{separator} {relative}", cwd_hint)
        for command in (f"cd folder; TASK_ID=$({relative})", f'cd folder; TASK_ID="$({relative})"',
                        f"TASK_ID=$(cd folder; {relative})"):
            with self.subTest(command=command):
                self.deny("linux", command, cwd_hint)
        for path in (r"\valid.md", "C:valid.md"):
            with self.subTest(path=path):
                self.deny("win32", "Set-Location folder; " + launch + path, cwd_hint)

    def test_absolute_file_after_directory_change(self):
        for reader in readers:
            for change in ("cd folder", "Set-Location folder"):
                with self.subTest(reader=reader, change=change):
                    self.allow(reader, f"{change}; {absolute}")
        denial = runpy.run_path(str(script))["denial_reason"]
        scope = denial.__globals__
        surface = Mock()
        surface.is_writer.return_value = False
        for path in (r"C:\odd-flow-test\valid.md", r"\\server\share\valid.md"):
            with self.subTest(path=path):
                # Do not access an actual drive or network share during a test.
                surface.reset_mock()
                payload = {"cwd": str(scratch), "tool_name": "Bash", "tool_input": {
                    "command": f"Set-Location folder; {launch}'{path}'",
                }}
                with patch.dict(scope, load_surface=lambda: surface):
                    self.assertIsNone(denial(payload, read_launches=scope["powershell_launches"]))
                surface.read_spec.assert_called_once()

    def test_posix_dynamic_verbs_require_literals(self):
        for verb in ("$v", '"$v"', "$(printf help)", "`printf help`", "task-*", "task-{create,list}"):
            with self.subTest(verb=verb):
                self.deny("linux", f"orca orchestration {verb} --help", verb_hint)

    def test_documented_launches_and_literal_other_verbs(self):
        task = relative + " --environment local --task-title 'T1 write: example' --json"
        existing = "orca orchestration worker-start --environment local --task task_x --terminal term_x --json"
        worker = ("orca orchestration worker-start --environment local --spec-file valid.md "
                  "--task-title 'T1 write: example' --worktree current --agent claude")
        for reader in readers:
            for command in (task, existing, worker, *(
                f"orca orchestration {verb}" for verb in
                ("send", "check", "ask", "reply", "task-list", "worker-release")
            )):
                with self.subTest(reader=reader, command=command):
                    self.allow(reader, command)
        self.allow("linux", f"TASK_ID=$({task})")
        self.allow("linux", f"( {task} ) & {{ {worker}; }} & wait")
        for separator in (";", "&&", "\n"):
            with self.subTest(separator=separator):
                self.allow("win32", f"{task}{separator} {worker}")


unittest.main(verbosity=2)
PY
