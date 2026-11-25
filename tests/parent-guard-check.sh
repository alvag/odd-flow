#!/usr/bin/env bash
# Exercise the Claude Code hooks through stdin with isolated state.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
echo "Scratch: $T"
env -i PATH="$PATH" python3 -I - "$ROOT" "$T" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

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
prompt("trailing-worker", "Updated Orca dispatch\n\n  ODD-Flow-Worker: WrItE  \n \t\n")
check("S11 a trailing marker exempts a Claude worker",
      edit("code", session="trailing-worker", **full))
prompt("non-trailing-marker", "Updated Orca dispatch\nodd-flow-worker: write\nTask text")
check("S11 a non-trailing marker leaves the Claude parent guarded",
      edit("code", session="non-trailing-marker", **full), "deny")
wrapped = 'Updated Orca dispatch\n\n<pasted_content id="ef22">\nTask text\n'
closing = '</pasted_content id="ef22">'
trailing = "odd-flow-worker: write\n \t\n"
prompt("wrapped-worker", wrapped + trailing + closing + "\n")
check("S11 a marker before a quoted closing tag exempts a Claude worker",
      edit("code", session="wrapped-worker", **full))
prompt("unquoted-wrapped-worker", wrapped.replace('id="ef22"', "id=Brief_9-a")
       + trailing + "</pasted_content id=Brief_9-a>\n")
check("S11 a marker before an unquoted closing tag still exempts a Claude worker",
      edit("code", session="unquoted-wrapped-worker", **full))
prompt("wrapped-parent", wrapped + closing + "\n")
check("S11 a closing tag without a preceding marker leaves the parent guarded",
      edit("code", session="wrapped-parent", **full), "deny")
prompt("double-closing", wrapped + trailing + closing + "\n" + closing)
check("S11 two closing tags leave the parent guarded",
      edit("code", session="double-closing", **full), "deny")
for i, tag in enumerate(('</pasted_content id="ef22>', '</pasted_content id=ef22">',
                         '</pasted_content id="">', '</pasted_content>')):
    prompt(f"bad-tag-{i}", "Updated Orca dispatch\nodd-flow-worker: write\n" + tag)
    check(f"S11 malformed closing tag {tag!r} leaves the parent guarded",
          edit("code", session=f"bad-tag-{i}", **full), "deny")
prompt("non-ascii-role", "# Role: rev" + chr(0x131) + "ew\nTask")
check("S11 a non-ASCII first-line role leaves the parent guarded",
      edit("code", session="non-ascii-role", **full), "deny")
prompt("non-ascii-marker", "Updated Orca dispatch\nodd-flow-worker: rev" + chr(0x131) + "ew")
check("S11 a marker with a non-ASCII case variant leaves the parent guarded",
      edit("code", session="non-ascii-marker", **full), "deny")
prompt("fenced-marker", "Look:\n```\nodd-flow-worker: write\n```\n")
check("S11 a marker in a closed fenced block leaves the parent guarded",
      edit("code", session="fenced-marker", **full), "deny")
for i, tail in enumerate(("odd-flow-worker: deploy", "odd-flow-worker: write now",
                          "> odd-flow-worker: write", "odd-flow-worker:write")):
    prompt(f"bad-marker-{i}", "Updated Orca dispatch\n" + tail)
    check(f"S11 malformed marker {tail!r} leaves the parent guarded",
          edit("code", session=f"bad-marker-{i}", **full), "deny")
prompt("late-marker", "Hello")
prompt("late-marker", "Task\n\nodd-flow-worker: write\n")
check("S11 a marker on a later prompt cannot mark a parent",
      edit("code", session="late-marker", **full), "deny")
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
