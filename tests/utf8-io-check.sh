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

SUBPROCESS_TIMEOUT = 15

root, scratch, orca = map(Path, sys.argv[1:])
sys.argv[1:] = []
profile = root / "skills/odd-flow/scripts/profile.py"
clock = "\u23f0"
profile_name = f"prof-{clock}"
session = "utf8-io-test"
workspace = scratch / f"workspace-{clock}"
workspace.mkdir()
subprocess.run(["git", "init", "--quiet", str(workspace)], check=True, timeout=SUBPROCESS_TIMEOUT)
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
    json.dumps({"default": profile_name, "profiles": {profile_name: {}}}), encoding="utf-8",
)
for key in ("ANTIGRAVITY_CONVERSATION_ID", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"):
    subprocess.run(
        [sys.executable, "-I", str(profile), "session-mode", "full-delegation"],
        env=dict(env, **{key: session}), check=True, capture_output=True, timeout=SUBPROCESS_TIMEOUT,
    )


def utf8(payload):
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


class Utf8IoCheck(unittest.TestCase):
    def hook(self, script, runtime, payload, *, cwd=workspace):
        args = ("--runtime", runtime) if runtime else ()
        return subprocess.run(
            [sys.executable, "-I", str(root / "scripts" / script), *args],
            cwd=cwd, env=env, input=payload, capture_output=True, timeout=SUBPROCESS_TIMEOUT,
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

    def test_claude_rejects_invalid_utf8(self):
        path = f"odd/tasks/{clock}.md"
        payload = utf8({
            "cwd": str(workspace), "session_id": session, "tool_name": "Write",
            "tool_input": {"file_path": path},
        }).replace(path.encode("utf-8"), b"odd/tasks/\xff.md")
        done = self.hook("pre-tool-use.py", "", payload)
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertEqual(done.stdout, b"")
        self.assertIn(b"not valid UTF-8", done.stderr)

    def test_antigravity_rejects_invalid_utf8(self):
        path = f"odd/tasks/{clock}.md"
        payload = utf8({
            "cwd": str(workspace), "conversationId": session,
            "toolCall": {"name": "write_file", "args": {"Path": path}},
        }).replace(path.encode("utf-8"), b"odd/tasks/\xff.md")
        done = self.hook("pre-tool-use.py", "antigravity", payload)
        self.assertEqual(done.returncode, 0, done.stderr)
        output = json.loads(done.stdout)
        self.assertEqual(output["decision"], "deny")
        self.assertIn("not valid UTF-8", output["reason"])

    def test_subdirectory_edit_uses_utf8_workspace_root(self):
        cwd = workspace / "sub"
        cwd.mkdir()
        for path, expected in (("../x.py", "deny"), (f"../odd/tasks/{clock}.md", None)):
            for runtime, payload in (
                ("antigravity", {
                    "conversationId": session,
                    "toolCall": {"name": "write_file", "args": {"Path": path}},
                }),
                ("", {
                    "session_id": session, "tool_name": "Write", "tool_input": {"file_path": path},
                }),
                ("codex", {
                    "session_id": session, "tool_name": "apply_patch",
                    "tool_input": {"command": f"*** Begin Patch\n*** Add File: {path}\n+test\n*** End Patch"},
                }),
            ):
                with self.subTest(runtime=runtime or "claude", path=path):
                    # Escape stdin so this check isolates the Git subprocess output.
                    request = json.dumps({"cwd": str(cwd), **payload}).encode("ascii")
                    done = self.hook("pre-tool-use.py", runtime, request, cwd=cwd)
                    if runtime == "antigravity":
                        self.assertEqual(done.returncode, 0, done.stderr)
                        self.assertEqual(json.loads(done.stdout)["decision"], expected or "allow")
                    else:
                        self.assertEqual(self.permission(done), expected)
                        if runtime == "codex" and expected == "deny":
                            self.assertIn(
                                f"Parent edit denied for {path!r}",
                                json.loads(done.stdout)["hookSpecificOutput"]["permissionDecisionReason"],
                            )

    def test_session_start_binds_utf8_payload(self):
        done = self.hook("session-start.py", "antigravity", utf8({
            "conversationId": session, "source": f"startup-{clock}",
        }))
        self.assertEqual(done.returncode, 0, done.stderr)
        step, = json.loads(done.stdout)["injectSteps"]
        context = step["systemMessage"]["systemMessage"]
        core = root / "skills/odd-flow/assets/core-block-full-delegation.md"
        self.assertTrue(context.startswith(core.read_text(encoding="utf-8").strip()))
        state = context.partition("### odd-flow session state")[2]
        header, _, details = state.partition("\n")
        with self.subTest(field="source"):
            self.assertEqual(header, f" (SessionStart source: startup-{clock})")
        with self.subTest(field="profile"):
            self.assertIn(f"profile: {profile_name} (file default);", details)
        self.assertIn("session key: ANTIGRAVITY_CONVERSATION_ID; agent: antigravity", context)

    def test_orca_agent_discovery_preserves_utf8(self):
        done = subprocess.run(
            [sys.executable, "-I", str(profile), "discover", "--json"],
            env=env, capture_output=True, check=True, timeout=SUBPROCESS_TIMEOUT,
        )
        result = json.loads(done.stdout)
        self.assertNotIn("orca_error", result)
        self.assertEqual([agent["id"] for agent in result["agents"]], [clock])

    def test_orca_invalid_utf8_fails_closed(self):
        done = subprocess.run(
            [sys.executable, "-I", str(profile), "check"],
            env=dict(env, INVALID_ORCA_UTF8="1"), capture_output=True, timeout=SUBPROCESS_TIMEOUT,
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertIn(b"cannot list Orca agents", done.stderr)
        self.assertIn(b"'utf-8' codec", done.stderr)


unittest.main()
PY
