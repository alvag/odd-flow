#!/usr/bin/env bash
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
export HOME="$scratch" USERPROFILE="$scratch" ODD_FLOW_HOME="$scratch/profiles"
unset ANTIGRAVITY_CONVERSATION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CODEX_SESSION_ID PYTHONUTF8

cat >"$scratch/orca" <<'SH'
#!/bin/sh
[ "$*" = 'agent installed --json' ] || exit 99
if [ "${INVALID_ORCA_UTF8:-}" = 1 ]; then
  printf '{"agents":[{"id":"\377"}]}\n'
else
  printf '{"agents":[{"id":"\342\217\260"}]}\n'
fi
SH
chmod +x "$scratch/orca"
orca_cli="$scratch/orca"
if [[ "$(python3 -I -c 'import sys; print(sys.platform)')" == win32 ]]; then
  printf '@"%s" "%s" %%*\r\n' "$(cygpath -w "$(command -v sh)")" "$(cygpath -w "$scratch/orca")" >"$scratch/orca.cmd"
  orca_cli="$scratch/orca.cmd"
fi

python3 -I - "$root" "$scratch" "$orca_cli" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

root, scratch, orca = map(Path, sys.argv[1:])
sys.argv[1:] = []
profile = root / "skills/odd-flow/scripts/profile.py"
clock = "\u23f0"
session = "utf8-io-test"
workspace = scratch / f"workspace-{clock}"
workspace.mkdir()
subprocess.run(["git", "init", "--quiet", str(workspace)], check=True)
env = {
    "PATH": os.environ["PATH"],
    "HOME": str(scratch),
    "USERPROFILE": str(scratch),
    "ODD_FLOW_HOME": str(scratch / "profiles"),
    "PLUGIN_DATA": str(scratch / "plugin-data"),
    "CLAUDE_PLUGIN_DATA": str(scratch / "claude-data"),
    "ORCA_CLI_COMMAND": str(orca),
}
if sys.platform == "win32":
    env["SystemRoot"] = os.environ["SYSTEMROOT"]
(scratch / "profiles").mkdir()
(scratch / "profiles/profiles.json").write_text(
    json.dumps({"default": "caf\u00e9", "profiles": {"caf\u00e9": {}}}), encoding="utf-8",
)
for key in ("ANTIGRAVITY_CONVERSATION_ID", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"):
    subprocess.run(
        [sys.executable, "-I", str(profile), "session-mode", "full-delegation"],
        env=dict(env, **{key: session}), check=True, capture_output=True,
    )


def utf8(payload):
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


class Utf8IoCheck(unittest.TestCase):
    def hook(self, script, runtime, payload):
        args = ("--runtime", runtime) if runtime else ()
        return subprocess.run(
            [sys.executable, "-I", str(root / "scripts" / script), *args],
            cwd=workspace, env=env, input=payload, capture_output=True,
        )

    def guard(self, runtime, payload):
        return self.hook("pre-tool-use.py", runtime, utf8({"cwd": str(workspace), **payload}))

    def permission(self, done):
        self.assertEqual(done.returncode, 0, done.stderr)
        if not done.stdout:
            return None
        return json.loads(done.stdout)["hookSpecificOutput"]["permissionDecision"]

    def test_antigravity_edit_and_unrelated_command(self):
        for name, args, expected in (
            ("write_file", {"Path": f"src/{clock}.py"}, "deny"),
            ("write_file", {"Path": f"odd/tasks/{clock}.md"}, "allow"),
            ("run_command", {"CommandLine": f"echo {clock}"}, "allow"),
        ):
            with self.subTest(name=name, expected=expected):
                done = self.guard("antigravity", {
                    "conversationId": session, "toolCall": {"name": name, "args": args},
                })
                self.assertEqual(done.returncode, 0, done.stderr)
                output = json.loads(done.stdout)
                self.assertEqual(output["decision"], expected)
                if expected == "deny":
                    self.assertIn(f"Parent edit denied for {args['Path']!r}", output["reason"])

    def test_claude_edit(self):
        for path, expected in ((f"src/{clock}.py", "deny"), (f"odd/tasks/{clock}.md", None)):
            with self.subTest(expected=expected):
                done = self.guard("", {
                    "session_id": session, "tool_name": "Write", "tool_input": {"file_path": path},
                })
                self.assertEqual(self.permission(done), expected)
                if expected == "deny":
                    self.assertIn(
                        f"Parent edit denied for {path!r}",
                        json.loads(done.stdout)["hookSpecificOutput"]["permissionDecisionReason"],
                    )

    def test_codex_patch(self):
        for path, expected in ((f"src/{clock}.py", "deny"), (f"odd/tasks/{clock}.md", None)):
            with self.subTest(expected=expected):
                done = self.guard("codex", {
                    "session_id": session, "tool_name": "apply_patch",
                    "tool_input": {"command": f"*** Begin Patch\n*** Add File: {path}\n+test\n*** End Patch"},
                })
                self.assertEqual(self.permission(done), expected)

    def test_codex_rejects_invalid_utf8(self):
        payload = utf8({
            "cwd": str(workspace), "session_id": session, "tool_name": "apply_patch",
            "tool_input": {"command": f"*** Begin Patch\n*** Add File: odd/tasks/{clock}.md\n+test\n*** End Patch"},
        }).replace(clock.encode("utf-8"), b"\xff")
        done = self.hook("pre-tool-use.py", "codex", payload)
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout, b"")

    def test_session_start_binds_utf8_payload(self):
        done = self.hook("session-start.py", "antigravity", utf8({
            "conversationId": session, "source": f"startup-{clock}",
        }))
        self.assertEqual(done.returncode, 0, done.stderr)
        step, = json.loads(done.stdout)["injectSteps"]
        context = step["systemMessage"]["systemMessage"]
        core = root / "skills/odd-flow/assets/core-block-full-delegation.md"
        self.assertTrue(context.startswith(core.read_text(encoding="utf-8").strip()))
        header = context.partition("### odd-flow session state")[2].split("\n", 1)[0]
        self.assertEqual(header, f" (SessionStart source: startup-{clock})")
        self.assertIn("profile: caf\u00e9 (file default);", context)
        self.assertIn("session key: ANTIGRAVITY_CONVERSATION_ID; agent: antigravity", context)

    def test_orca_agent_discovery_preserves_utf8(self):
        done = subprocess.run(
            [sys.executable, "-I", str(profile), "discover", "--json"],
            env=env, capture_output=True, check=True,
        )
        result = json.loads(done.stdout)
        self.assertNotIn("orca_error", result)
        self.assertEqual([agent["id"] for agent in result["agents"]], [clock])

    def test_orca_invalid_utf8_fails_closed(self):
        done = subprocess.run(
            [sys.executable, "-I", str(profile), "check"],
            env=dict(env, INVALID_ORCA_UTF8="1"), capture_output=True,
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertIn(b"cannot list Orca agents", done.stderr)
        self.assertIn(b"'utf-8' codec", done.stderr)


unittest.main()
PY
