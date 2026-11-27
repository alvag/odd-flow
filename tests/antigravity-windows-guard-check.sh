#!/usr/bin/env bash
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
python3 -I - "$root" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

root, scratch = (Path(value).resolve() for value in sys.argv[1:])
sys.argv[1:] = []
script = root / "scripts/pre-tool-use.py"
native = [sys.executable, "-I", str(script)]
wrapped = [sys.executable, "-I", "-c", """
import pathlib
import runpy
import sys

sys.platform = sys.argv[1]
sys.argv = sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")
"""]
env = dict(os.environ, CLAUDE_PLUGIN_ROOT=str(root))
valid = "# Role: write\n\n## Allowed edit surfaces\nsrc/code.py\n"
invalid = "# Role: write\n\n## Allowed edit surfaces\n../bad\n"

# Only the shell reader is emulated; the hook uses the host filesystem.
for name, spec in (
    (r"specs\valid.md", valid), (r"specs\with spaces.md", valid),
    (r"specs\invalid.md", invalid), ("it's.md", valid), ("its.md", valid),
    ("~tilde.md", valid), ("bad/it's.md", invalid), ("bad/its.md", valid),
    ("a^b.md", valid), ("ab.md", valid), ("x%OS%y.md", valid),
):
    path = scratch / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(spec, encoding="utf-8")

launch = "orca orchestration task-create --spec-file "
relative = launch + r"specs\valid.md"
parse_reason = "cannot parse the orchestration launch"
parse_hint = "Write the launch as a plain command"


def run_hook(argv, payload):
    result = subprocess.run(argv, input=json.dumps({"cwd": str(scratch)} | payload),
                            cwd=root, env=env, capture_output=True, text=True, timeout=10)
    assert (result.returncode, result.stderr) == (0, ""), result
    return json.loads(result.stdout)


class WindowsGuardCheck(unittest.TestCase):
    def check(self, command, decision="allow", *reason, platform="win32"):
        argv = native if sys.platform == platform else [*wrapped, platform, str(script)]
        output = run_hook([*argv, "--runtime", "antigravity"], {
            "toolCall": {"name": "run_command", "args": {"CommandLine": command}},
        })
        self.assertEqual(output["decision"], decision, output)
        if decision == "allow":
            self.assertNotIn("reason", output)
        else:
            self.assertTrue(output["reason"].startswith("odd-flow: "), output)
            for part in reason:
                self.assertIn(part, output["reason"])

    def test_literal_spec_paths(self):
        for name, path in (
            ("absolute", str(scratch / r"specs\valid.md")),
            ("relative", r"specs\valid.md"),
            ("single-quoted with spaces", r"'specs\with spaces.md'"),
            ("double-quoted", r'"specs\valid.md"'),
            ("doubled single quote", "'it''s.md'"),
            ("quoted tilde", "'~tilde.md'"),
        ):
            with self.subTest(name=name):
                self.check(launch + path)

    def test_invalid_spec_paths(self):
        for path, name in ((r"specs\invalid.md", "invalid.md"), ("'bad/it''s.md'", "it's.md")):
            with self.subTest(path=path):
                self.check(launch + path, "deny", name, "../bad")

    def test_each_launch_in_batch_is_checked(self):
        with self.subTest(batch="two valid specs"):
            self.check(relative + "; " + relative.replace("task-create", "worker-start"))
        for separator in (";", "|", "&&", "||", "\n", "\r\n"):
            with self.subTest(separator=separator):
                self.check(relative + separator + launch + r"specs\invalid.md",
                           "deny", "invalid.md", "../bad")

    def test_unsupported_syntax_fails_closed(self):
        base = launch + "its.md"
        for name, command in (
            ("backtick", base + " --comment a`b"),
            ("dollar before launch recognition", "orca orchestration $v --spec-file its.md"),
            ("at sign", base + " --comment @v"),
            ("braces", base + " --comment {v}"),
            ("parentheses", base + " --comment (v)"),
            ("line comment", base + " # note"),
            ("block comment", base + " <# note #>"),
            ("stop parsing", base + " --% note"),
            ("quoted stop parsing", base + " '--%' note"),
            ("redirection", base + " > out.txt"),
            ("call operator", "& " + base),
            ("comma", base + " --comment a,b"),
            ("adjacent quotes", launch + "it''s.md"),
            ("empty quote", base + " --comment ''"),
            ("double quote inside single quotes", base + """ --comment 'a"b'"""),
            ("double quote inside double quotes", base + ' --comment "a""b"'),
            ("interpolation inside double quotes", base + ' --comment "$v"'),
            ("backtick inside double quotes", base + ' --comment "a`b"'),
            ("space and trailing backslash", base + r""" --comment 'a b\'"""),
            ("lone CR", base + "\r"),
            ("non-ASCII space", base + "\u00a0"),
            ("typographic quotes", launch + "\u2018its.md\u2019"),
            ("unterminated quote", base + " --comment 'a"),
            ("bare tilde", launch + r"~\x.md"),
            ("batch caret", "orca.cmd orchestration task-create --spec-file a^b.md"),
            ("batch percent expansion", "orca.cmd orchestration task-create --spec-file 'x%OS%y.md'"),
        ):
            with self.subTest(name=name):
                self.check(command, "deny", parse_reason, parse_hint)

    def test_unrecognized_raw_launch_is_denied(self):
        self.check(f'powershell -Command "{launch}its.md"', "deny", parse_reason, parse_hint)

    def test_unrelated_command_is_not_parsed(self):
        self.check("& $unrelated")

    def test_posix_readers_are_unchanged(self):
        platform = "linux" if sys.platform == "win32" else sys.platform
        self.check(relative, "deny", "cannot read spec file", "specsvalid.md", platform=platform)
        output = run_hook(native, {"tool_name": "Bash", "tool_input": {"command": relative}})
        details = output["hookSpecificOutput"]
        self.assertEqual(details["permissionDecision"], "deny")
        self.assertIn("cannot read spec file", details["permissionDecisionReason"])
        self.assertIn("specsvalid.md", details["permissionDecisionReason"])


unittest.main(verbosity=2)
PY
