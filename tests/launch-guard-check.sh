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

    def test_nested_shell_bypasses_are_denied(self):
        inner = "powershell -Command orca orchestration task-create --help"
        for command in (
            f"if true; then {inner}; fi",
            f"for x in 1; do {inner}; done",
            f"time {inner}",
            f"nohup {inner}",
            f"nice -n 5 {inner}",
            "timeout --signal=TERM 5 cmd /c orca orchestration task-create --help",
            """bash -c 'orca orchestration "task-create" --spec-file valid.md'""",
            """sh -c 'orca "orchestration" task-create --spec-file valid.md'""",
            "bash -c 'v=task-create; orca orchestration $v --spec-file valid.md'",
        ):
            with self.subTest(reader="linux", command=command):
                self.deny("linux", command, nested_hint)
        for reader in readers:
            for program in ("powershell -Command", "pwsh -Command", "cmd /c"):
                for inner in (
                    "orca orchestration 'task-create' --spec-file valid.md",
                    "orca orchestration 'worker-start' --spec-file valid.md",
                    "orca 'orchestration' task-create --spec-file valid.md",
                ):
                    command = f'{program} "{inner}"'
                    with self.subTest(reader=reader, command=command):
                        self.deny(reader, command, nested_hint)

    def test_directory_change_bypasses_are_denied(self):
        for change in (
            "command cd folder", "builtin cd folder", "if true; then cd folder; fi",
            "for d in folder; do cd $d; done", "if false; then true; else cd folder; fi",
            "time cd folder", "if false; then true; elif cd folder; then true; fi",
        ):
            with self.subTest(reader="linux", change=change):
                self.deny("linux", f"{change}; {relative}", cwd_hint)
        for change in ("cd..", "CD\\"):
            with self.subTest(reader="win32", change=change):
                self.deny("win32", f"{change}; {relative}", cwd_hint)

    def test_double_quoted_backtick_dynamic_verb_is_denied(self):
        for prefix in ("X=", "echo ", ""):
            command = prefix + '"`orca orchestration $v --spec-file valid.md`"'
            with self.subTest(command=command):
                self.deny("linux", command, verb_hint)

    def test_env_chdir_requires_an_absolute_spec(self):
        for option in ("-C folder", "-iC folder", "-iCfolder", "--chdir folder", "--chdir=folder"):
            with self.subTest(option=option):
                self.deny("linux", f"env {option} {relative}", cwd_hint)
                self.allow("linux", f"env {option} {absolute}")
        self.allow("linux", f"env -C folder true; {relative}")

    def test_shells_reading_script_from_stdin_are_denied(self):
        for command in (
            """bash <<< 'orca orchestration "task-create" --help'""",
            """echo 'orca orchestration "task-create" --help' | sh""",
            """echo 'orca orchestration "task-create" --help' |""" + "\nsh",
            f"bash < script.sh; {absolute}",
        ):
            with self.subTest(command=command):
                self.deny("linux", command, nested_hint)
        self.allow("linux", f"{absolute} | cat")
        self.allow("linux", f"{absolute} || bash --version")
        self.deny("win32", """echo 'orca orchestration task-create --help' | sh""", nested_hint)

    def test_wrapper_short_options_keep_the_actual_program_visible(self):
        for wrapper in ("env -iu KEY", "env -P altpath", "timeout -vs TERM 10", "exec -ca fake"):
            with self.subTest(wrapper=wrapper):
                self.deny("linux", f'{wrapper} bash -c "orca orchestration \'task-create\' --help"', nested_hint)
        for option in ("-S", "-iS", "--split-string", "--split-string="):
            with self.subTest(option=option):
                gap = "" if option.endswith("=") else " "
                self.deny("linux", f"""env {option}{gap}'orca orchestration "task-create" --help'""", nested_hint)

    def test_case_patterns_do_not_end_substitutions(self):
        for command, hint in (
            (f"X=$(case a in a)cd folder; {relative};; esac)", cwd_hint),
            ("X=$(case a in a)orca orchestration $v --help;; esac)", verb_hint),
            ("X=$(case a in (a|b)orca orchestration $v --help;; esac)", verb_hint),
            ("""X=$(case a in a)bash -c 'orca orchestration "task-create" --help';; esac)""", nested_hint),
        ):
            with self.subTest(command=command):
                self.deny("linux", command, hint)
        self.allow("linux", f"X=$(case a in a)case b in b)({absolute});; esac;; esac)")

    def test_shells_eval_and_compound_prefixes_are_checked(self):
        for shell in ("zsh", "dash", "ksh"):
            with self.subTest(shell=shell):
                self.deny("linux", f"""{shell} -c 'orca orchestration "task-create" --help'""", nested_hint)
        for reader, evaluator, change in (
            ("linux", "eval", "cd folder"),
            ("win32", "Invoke-Expression", "Set-Location folder"),
            ("win32", "iex", "Set-Location folder"),
        ):
            with self.subTest(evaluator=evaluator):
                self.deny(reader, f'{evaluator} "orca orchestration \'task-create\' --help"', nested_hint)
            with self.subTest(evaluator=evaluator, change=change):
                self.deny(reader, f'{evaluator} "{change}"; {relative}', nested_hint)
        for command, hint in (
            (f"function f {{ cd folder; }}; f; {relative}", cwd_hint),
            ("function f { orca orchestration $v --help; }; f", verb_hint),
            ("""function f { bash -c 'orca orchestration "task-create" --help'; }; f""", nested_hint),
            ("coproc orca orchestration $v --help", verb_hint),
        ):
            with self.subTest(command=command):
                self.deny("linux", command, hint)

    def test_non_launch_orchestration_after_unrelated_shells_stays_allowed(self):
        for reader, command in (
            ("linux", "echo hi | sh; orca orchestration check --json"),
            ("linux", """eval "$(python3 -c 'print(1)')" >/dev/null; """
                      "orca orchestration send --to bot:x --type status --subject a --body-file /tmp/b.md"),
            ("win32", 'iex "1+1"; orca orchestration check --json'),
            ("win32", "echo hi | sh; orca orchestration check --json"),
            ("linux", "env -S 'echo hi'; orca orchestration check --json"),
            ("linux", "echo orchestration | cat; echo hi | sh; orca orchestration check --json"),
        ):
            with self.subTest(reader=reader, command=command):
                self.allow(reader, command)

    def test_nested_shell_hazards_still_deny_launches(self):
        for reader, command in (
            ("linux", "echo 'v=task-create; orca orchestration $v --spec-file bad.md' | sh"),
            ("linux", "bash <<< 'v=task-create; orca orchestration $v --spec-file bad.md'"),
            ("linux", f"{absolute}; echo hi | sh"),
            ("linux", f"env -S 'echo hi'; X=$({relative})"),
            ("win32", f'{absolute}; iex "1+1"'),
            ("win32", """echo 'ORCA ORCHESTRATION TASK-CREATE --help' | cat | sh"""),
        ):
            with self.subTest(reader=reader, command=command):
                self.deny(reader, command, nested_hint)

    def test_non_orca_commands_mentioning_orchestration_stay_allowed(self):
        for command in (
            "rg orchestration *.md", 'grep -rn orchestration "$PWD"',
            "git grep orchestration tests/*.sh", "echo orchestration $status",
            "echo orchestration `date`", "cat orchestration ~/notes.md",
            'python3 -c "print(1)" orchestration "$x"',
        ):
            with self.subTest(command=command):
                self.allow("linux", command)
        for program in ("$ORCA", "${ORCA_CLI_COMMAND:-orca}", "/usr/local/bin/orca", "orca.exe", "orca.cmd"):
            with self.subTest(program=program):
                self.deny("linux", f"env KEY=value {program} orchestration $v --help", verb_hint)


unittest.main(verbosity=2)
PY
