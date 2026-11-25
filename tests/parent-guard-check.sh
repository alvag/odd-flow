#!/usr/bin/env bash
# Exercise the Claude Code hooks through stdin with isolated state.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
echo "Scratch: $T"
env -i PATH="$PATH" python3 -I -B - "$ROOT" "$T" <<'PY'
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch

root, scratch = map(Path, sys.argv[1:])
scratch = scratch.resolve()
home, temp, data, profiles = (scratch / name for name in ("home", "temp", "data", "profiles"))
workspace, folder = (scratch / name for name in ("workspace", "folder"))
for directory in (home, temp, data, profiles, workspace / "src", folder / "src"):
    directory.mkdir(parents=True)
env = {
    "PATH": os.environ["PATH"],
    "HOME": str(home),
    "TMPDIR": str(temp),
    "CLAUDE_PLUGIN_DATA": str(data),
    "ODD_FLOW_HOME": str(profiles),
    "ODD_FLOW_STATE_DIR": str(scratch),
}
(profiles / "profiles.json").write_text('{"default":"A","profiles":{"A":{}}}')
subprocess.run(["git", "init", "-q", str(workspace)], env=env, check=True)
subprocess.run(
    [sys.executable, "-I", str(root / "skills/odd-flow/scripts/profile.py"),
     "session-mode", "full-delegation"],
    env={**env, "CLAUDE_CODE_SESSION_ID": "parent"}, check=True, capture_output=True,
)
(workspace / "odd/tasks/nested").mkdir(parents=True)
(workspace / "odd/tasks/link.md").symlink_to(workspace / "src/code.py")

failed = 0


def check(label, actual, expected=None, reason=()):
    global failed
    try:
        assert actual.returncode == 0 and not actual.stderr
        if expected is None:
            assert not actual.stdout
        else:
            output = json.loads(actual.stdout)["hookSpecificOutput"]
            assert output["hookEventName"] == "PreToolUse"
            assert output["permissionDecision"] == expected
            assert all(part in output["permissionDecisionReason"] for part in reason)
    except (AssertionError, ValueError, KeyError):
        failed += 1
        print(f"FAIL {label}: expected {expected or 'silence'} {reason}, got {actual!r}")
    else:
        print(f"PASS {label}")


def hook(script, payload, **overrides):
    settings = {key: value for key, value in (env | overrides).items() if value is not None}
    return subprocess.run(
        [sys.executable, "-I", str(root / "scripts" / script)], cwd=scratch, env=settings,
        input=json.dumps(payload), capture_output=True, text=True, timeout=12,
    )


def prompt(session, value, **overrides):
    return hook("prompt-submit.py", {"session_id": session, "prompt": value}, **overrides)


def edit(target, tool="Edit", session="parent", cwd=workspace / "src", agent_id="", **overrides):
    field = "notebook_path" if tool == "NotebookEdit" else "file_path"
    return hook("pre-tool-use.py", {
        "tool_name": tool, "tool_input": {} if target is None else {field: target},
        "session_id": session, "cwd": str(cwd), "agent_id": agent_id,
    }, **overrides)


full = {"ODD_ORCHESTRATOR_MODE": "full-delegation"}
for tool in ("Edit", "Write", "NotebookEdit"):
    check(f"S1/S5 {tool} uses payload session binding and Git top level",
          edit("../code", tool), "deny", ("../code", "bounded writer"))
check("S5 organic mode is silent", edit("code", session="organic"))
check("S5 unresolved mode is silent", edit("code", ODD_ORCHESTRATOR_MODE="invalid"))
check("S5 native subagent is exempt", edit("code", agent_id="agent-1"))

check("S4 organic prompt output stays silent", prompt("regular", "Hello"))
check("S4 repeats cannot mark an existing parent", prompt("regular", "# Role: write"))
check("S4 existing parent stays guarded", edit("code", session="regular", **full), "deny")
for session, first in (
    ("orca", "  You are working inside Orca, a multi-agent IDE.\nDispatch data"),
    ("lead", "Please carry out this task from my Orca coordinator by following the brief I pasted below."),
    ("../worker", "\n  # rOlE: WrItE\nTask"),
):
    check(f"S3/S4 first prompt for {session} stays silent in organic mode", prompt(session, first))
    check(f"S4 recognized worker is exempt: {session}", edit("code", session=session, **full))
check("S4 a role on a later line does not mark a session", prompt("not-role", "Hello\n# Role: write"))
check("S4 non-worker remains guarded", edit("code", session="not-role", **full), "deny")
tokens = scratch / "worker-tokens"
tokens.mkdir(mode=0o700)


def issue(token, role="write", age_ms=0):
    record = tokens / hashlib.sha256(token.encode("ascii")).hexdigest()
    with os.fdopen(os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        json.dump({"role": role, "issuedAt": time.time_ns() // 1_000_000 - age_ms}, stream)
    return record


def marker_check(session, tail, expected=None, **overrides):
    check(f"S8 {session} prompt stays silent", prompt(session, "Updated Orca dispatch\n" + tail, **overrides))
    check(f"S8 {session} guard decision", edit("code", session=session, **full), expected)


def session_decision(session):
    marker = data / "prompt-sessions" / hashlib.sha256(session.encode("ascii")).hexdigest()
    return marker.read_text() if marker.is_file() else None


token = "1" * 32
record = issue(token)
marker_check("trailing-worker", f"\n  ODD-Flow-Worker: WrItE {token}  \n \t\n")
if record.exists():
    failed += 1
    print("FAIL S8 accepted token record was not removed")
else:
    print("PASS S8 accepted token record was removed")
marker_check("reused-token", f"odd-flow-worker: write {token}", "deny")

token = "b" * 32
record = issue(token)
dispatch_prefix = "You are working inside Orca, a multi-agent IDE.\n# Role: write\n\n"
dispatch = f"{dispatch_prefix}odd-flow-worker: write {token}"
for session in ("tokened-dispatch", "reused-tokened-dispatch"):
    check(f"S8 {session} prompt stays silent", prompt(session, dispatch))
    check(f"S8 {session} is an exempt worker", edit("code", session=session, **full))
    if record.exists():
        failed += 1
        print(f"FAIL S8 {session} left the token record behind")
    else:
        print(f"PASS S8 {session} left no token record")
check("S17 copied marker prompt stays silent",
      prompt("copied-dispatch-marker", f"odd-flow-worker: write {token}"))
decision = session_decision("copied-dispatch-marker")
if decision == "parent":
    print("PASS S17 copied marker records the new session as parent")
else:
    failed += 1
    print(f"FAIL S17 copied marker: decision={decision}")
check("S17 copied marker leaves the new session guarded",
      edit("code", session="copied-dispatch-marker", **full), "deny")

session = "no-getuid"
token = "bc" * 16
record = issue(token)
result = subprocess.run(
    [sys.executable, "-I", "-c", "import os, runpy, sys; del os.getuid; "
     "runpy.run_path(sys.argv[1], run_name='__main__')", str(root / "scripts/prompt-submit.py")],
    cwd=scratch, env=env | full, capture_output=True, text=True, timeout=12,
    input=json.dumps({"session_id": session, "prompt": f"{dispatch_prefix}odd-flow-worker: write {token}"}),
)
decision = session_decision(session)
expected_context = {"hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "You are a dispatched worker. Follow your spec's role rules, "
                         "not the coordinator rules from session start.",
}}
if (decision == "worker" and record.is_file() and result.returncode == 0 and not result.stderr
        and result.stdout == json.dumps(expected_context) + "\n"):
    print("PASS S8/S12 without getuid: worker fallback and first-prompt context, token record kept")
else:
    failed += 1
    print(f"FAIL S8/S12 without getuid: decision={decision!r}, record exists={record.is_file()}, {result!r}")

spec = importlib.util.spec_from_file_location("prompt_submit", root / "scripts/prompt-submit.py")
prompt_submit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prompt_submit)
now_ms = 1_700_000_000_000
with patch.dict(os.environ, {"ODD_FLOW_STATE_DIR": str(scratch)}), patch.object(
    time, "time_ns", return_value=now_ms * 1_000_000
):
    for digit, age_ms, accepted in (
        ("c", 900_000, True),
        ("d", 900_001, False),
        ("e", -60_000, True),
        ("f", -60_001, False),
    ):
        token = digit * 32
        record = issue(token, age_ms=age_ms)
        actual = prompt_submit.consume_worker_token(f"odd-flow-worker: write {token}")
        if actual is accepted and record.exists() is (not accepted):
            print(f"PASS S8 token age {age_ms} ms: accepted={accepted}")
        else:
            failed += 1
            print(f"FAIL S8 token age {age_ms} ms: accepted={actual}, record exists={record.exists()}")

marker_check("bare-marker", "odd-flow-worker: write", "deny")
for session, digit, role, age_ms in (
    ("wrong-role", "2", "verify", 0),
    ("expired-token", "3", "write", 16 * 60_000),
    ("future-token", "4", "write", -120_000),
    ("malformed-token", "A", "write", 0),
):
    token = digit * 32
    issue(token, role, age_ms)
    marker_check(session, f"odd-flow-worker: write {token}", "deny")
marker_check("missing-record", f"odd-flow-worker: write {'5' * 32}", "deny")

for session, tag_id, digit in (
    ("wrapped-worker", '"ef22"', "6"),
    ("unquoted-wrapped-worker", "Brief_9-a", "7"),
):
    token = digit * 32
    issue(token)
    marker_check(session, f"<pasted_content id={tag_id}>\nTask text\n"
                 f"odd-flow-worker: write {token}\n \t\n</pasted_content id={tag_id}>\n")

token = "8" * 32
record = issue(token)
trailing = f"odd-flow-worker: write {token}"
wrapped = '<pasted_content id="ef22">\nTask text\n'
closing = '</pasted_content id="ef22">'
marker_check("non-trailing-marker", trailing + "\nTask text", "deny")
marker_check("wrapped-parent", wrapped + closing, "deny")
marker_check("double-closing", wrapped + trailing + "\n" + closing + "\n" + closing, "deny")
for i, tag in enumerate(('</pasted_content id="ef22>', '</pasted_content id=ef22">',
                         '</pasted_content id="">', '</pasted_content>')):
    marker_check(f"bad-tag-{i}", wrapped + trailing + "\n" + tag, "deny")
prompt("non-ascii-role", "# Role: rev" + chr(0x131) + "ew\nTask")
check("S11 a non-ASCII first-line role leaves the parent guarded",
      edit("code", session="non-ascii-role", **full), "deny")
review_token = "9" * 32
issue(review_token, "review")
marker_check("non-ascii-marker", f"odd-flow-worker: rev{chr(0x131)}ew {review_token}", "deny")
marker_check("fenced-marker", "Look:\n```\n" + trailing + "\n```\n", "deny")
for i, tail in enumerate((f"odd-flow-worker: deploy {token}", trailing + " now",
                          "> " + trailing, f"odd-flow-worker:write {token}")):
    marker_check(f"bad-marker-{i}", tail, "deny")
prompt("late-marker", "Hello")
marker_check("late-marker", trailing, "deny")
if not record.is_file():
    failed += 1
    print("FAIL S8 a later prompt consumed the token record")
else:
    print("PASS S8 a later prompt did not consume the token record")

symlink_state = scratch / "symlink-state"
symlink_state.mkdir()
(symlink_state / "worker-tokens").symlink_to(tokens, target_is_directory=True)
for session, pair, state_dir, mode in (
    ("relative-state-dir", "00", ".", 0o700),
    ("symlinked-worker-tokens", "aa", str(symlink_state), 0o700),
    ("loose-worker-tokens", "bb", str(scratch), 0o755),
    ("setgid-worker-tokens", "0c", str(scratch), 0o2700),
    ("sticky-worker-tokens", "0d", str(scratch), 0o1700),
):
    token = pair * 16
    record = issue(token)
    tokens.chmod(mode)
    marker_check(session, f"odd-flow-worker: write {token}", "deny", ODD_FLOW_STATE_DIR=state_dir)
    decision = session_decision(session)
    if decision == "parent" and record.is_file():
        print(f"PASS S12 {session} records parent and keeps the token record")
    else:
        failed += 1
        print(f"FAIL S12 {session}: decision={decision}, record exists={record.is_file()}")
tokens.chmod(0o700)

check("S4 absent plugin data preserves prompt output",
      prompt("no-data", "# Role: write", CLAUDE_PLUGIN_DATA=None))
check("S4 absent plugin data does not mark",
      edit("code", session="no-data", CLAUDE_PLUGIN_DATA=None, **full), "deny")
check("S4 marker write failure preserves prompt output",
      prompt("no-write", "# Role: write", CLAUDE_PLUGIN_DATA=str(profiles / "profiles.json")))
check("S4 failed marker write does not mark",
      edit("code", session="no-write", CLAUDE_PLUGIN_DATA=str(profiles / "profiles.json"), **full), "deny")

check("S6 direct task Markdown is allowed", edit("../odd/tasks/task.md"))
check("S6 nested task Markdown is denied", edit("../odd/tasks/nested/task.md"), "deny")
check("S6 symlink resolves before checking task exception", edit("../odd/tasks/link.md"), "deny")
case_alias = workspace.with_name(workspace.name.upper())
if case_alias.is_dir() and case_alias.samefile(workspace):
    check("S6 a case alias of the workspace is still guarded",
          edit(str(case_alias / "code.py")), "deny")
check("S6 system temp outside the workspace is allowed", edit(str(temp / "scratch.md")))
outside = "/odd-flow-parent-guard-external.md"
check("S6/S7 non-temp external path asks for exact-diff confirmation",
      edit(outside), "ask", (outside, "named", "confirmed", "exact diff"))
check("S6 missing path denies", edit(None), "deny")
check("S6 non-string path denies", edit(7), "deny")
check("S6 non-Git workspace uses project directory",
      edit("../code", cwd=folder / "src", CLAUDE_PROJECT_DIR=str(folder)), "deny")
check("S6 non-Git workspace falls back to payload cwd", edit("code", cwd=folder / "src"), "deny")
check("S7 internal resolution error denies once mode is known", edit("bad\0path"), "deny")

hooks = json.loads((root / "hooks/hooks.json").read_text())["hooks"]
matched = {tool for entry in hooks["PreToolUse"] for tool in entry["matcher"].split("|")}
if not {"Agent", "Task", "Bash", "Edit", "Write", "NotebookEdit"} <= matched:
    failed += 1
    print(f"FAIL S5 matcher: {matched}")
else:
    print("PASS S5 matcher includes parent edit tools and writer launch tools")

sys.exit(bool(failed))
PY
