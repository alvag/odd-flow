#!/usr/bin/env bash
# Behavioral checks for odd-flow scripts/profile.py, run against isolated state.
set -u
P="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/profile.py"
EX="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/assets/profiles.example.json"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
logical_T=$(CDPATH= cd -L -- "$T" && pwd -L) || exit 1
T=$logical_T
export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude" CODEX_HOME="$T/codex"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
pass=0; fail=0
run() { env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" CODEX_HOME="$CODEX_HOME" "$@" python3 -I "$P" ${ARGS} 2>&1; }
expect() { # name, expected substring, actual, expected exit, actual exit, optional exact
  if [[ "$4" == "$5" && ("$3" == "$2" || ("${6:-}" != exact && "$3" == *"$2"*)) ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $4 and: $2"; echo "  got  exit $5: $3"; fi
}

if python3 -I - "$P" "$T" "$HOME" "$PATH" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

script, scratch, home, path = sys.argv[1:]
root = Path(scratch) / "json-reads"
sessions = root / "sessions"
sessions.mkdir(parents=True)
profiles = root / "profiles.json"
env = {"HOME": home, "PATH": path, "ODD_FLOW_HOME": str(root)}
env.update({key: os.environ[key] for key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME")})


def run(*args, **overrides):
    return subprocess.run([sys.executable, "-I", script, *args],
                          env={**env, **overrides}, capture_output=True)


def payload(command, expected, **overrides):
    result = run(command, "--json", **overrides)
    assert result.returncode == 0 and not result.stderr, (command, result)
    assert json.loads(result.stdout) == expected, (command, result.stdout)


def text(command, expected, **overrides):
    result = run(command, **overrides)
    assert (result.returncode, result.stdout, result.stderr) == (0, expected, b""), result


payload("list", {"path": None, "default": None, "profiles": []})
roles = {"verify": {"agent": "claude", "model": "example", "effort": "high"}}
minimal = {"write": {"agent": "codex"}}
profiles.write_text(json.dumps({
    "default": "minimal", "profiles": {"minimal": minimal, "bound": roles},
    "workflow": {"bound": {"orchestratorMode": "full-delegation"}},
}))
payload("list", {"path": str(profiles), "default": "minimal", "profiles": [
    {"name": "bound", "default": False, "mode": "full-delegation", "roles": roles},
    {"name": "minimal", "default": True, "mode": "organic", "roles": minimal},
]}, ODD_ORCHESTRATOR_MODE="organic")
text("list", b"bound: verify | mode: full-delegation\nminimal (default): write | mode: organic\n")

(sessions / "thread.json").write_text('{"profile":"bound","mode":"organic"}')
session = {"CODEX_THREAD_ID": "thread", "ORCA_TERMINAL_HANDLE": "term_json"}
fallback = {"agent": "codex", "model": None, "effort": None}
payload("show", {
    "profile": "bound", "source": "session (CODEX_THREAD_ID)", "session_key": "CODEX_THREAD_ID",
    "agent": "codex", "mode": "organic", "mode_source": "session (CODEX_THREAD_ID)",
    "rules": "references/mode-organic.md", "orca_terminal": "term_json",
    "roles": {**dict.fromkeys(("explore", "write", "review", "refute"), fallback), **roles},
}, **session)
text("show", (
    b"profile: bound (session (CODEX_THREAD_ID)); session key: CODEX_THREAD_ID; agent: codex\n"
    b"mode: organic (session (CODEX_THREAD_ID)); rules: references/mode-organic.md\n"
    b"  explore -> codex / agent default model (role not in profile)\n"
    b"  write -> codex / agent default model (role not in profile)\n"
    b"  verify -> claude / example / effort high\n"
    b"  review -> codex / agent default model (role not in profile)\n"
    b"  refute -> codex / agent default model (role not in profile)\n"
    b"orca: terminal term_json; workers launch through Orca\n"
), **session)

profiles.write_text('{"profiles":{"invalid":{"write":{"effort":"high"}}}}')
for command in ("list", "show"):
    before, after = run(command), run(command, "--json")
    assert before.returncode == after.returncode == 2, (command, before, after)
    assert not after.stdout and before.stderr == after.stderr, (command, before, after)
PY
then pass=$((pass+1)); echo "PASS list/show JSON contracts and text preservation"
else fail=$((fail+1)); echo "FAIL list/show JSON contracts or text preservation"
fi

ARGS="resolve write --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "no file: current agent, no model" '"flags": ["--agent", "claude"]' "$out" 0 $ec
settings=$(printf '%s\n' "$out" | python3 -I -c '
import json, shlex, sys
from pathlib import Path

argv = shlex.split(json.load(sys.stdin)["split_command"])
path = Path(sys.argv[1]).with_name("claude-worker-settings.json")
if argv == ["claude", "--settings", str(path)] and json.loads(path.read_text()) == {
    "enabledPlugins": {"engram@engram": False},
}:
    print("isolated")
' "$P")
expect "no Engram installed: Claude command uses settings that disable only Engram" "isolated" "$settings" 0 "$ec" exact

cp "$EX" "$T/profiles.json"
ARGS="resolve verify --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "file default applies" '"--model", "claude-opus-5-5", "--effort", "high"' "$out" 0 $ec

ARGS="resolve verify --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=claude-codex); ec=$?
expect "env overrides default" '"--agent", "codex", "--model", "gpt-6.2-sol"' "$out" 0 $ec

ARGS="use minimal"; out=$(run CODEX_THREAD_ID=th-1); ec=$?
expect "use binds via codex thread id" "bound to this session via CODEX_THREAD_ID" "$out" 0 $ec

ARGS="resolve verify --json"; out=$(run CODEX_THREAD_ID=th-1 ODD_PROFILE=claude-codex); ec=$?
expect "session binding beats env; model optional" '"profile": "minimal", "profile_source": "session (CODEX_THREAD_ID)"' "$out" 0 $ec

ARGS="resolve write --json"; out=$(run CODEX_THREAD_ID=th-1); ec=$?
expect "role missing from profile uses current agent" '"flags": ["--agent", "codex"]' "$out" 0 $ec

ARGS="resolve verify --json"; out=$(run CODEX_THREAD_ID=th-2); ec=$?
expect "other session not affected by binding" '"profile": "claude", "profile_source": "file default"' "$out" 0 $ec

ARGS="resolve review-readability --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=claude-codex); ec=$?
expect "lens override" '"--agent", "claude", "--model", "claude-sonnet-5-5"' "$out" 0 $ec

ARGS="resolve review-risk --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=claude-codex); ec=$?
expect "lens falls back to review" '"entry_role": "review"' "$out" 0 $ec

ARGS="resolve review-second --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=claude-codex); ec=$?
expect "second reviewer falls back to review" '"entry_role": "review", "agent": "codex", "model": "gpt-6.2-astra", "effort": "high"' "$out" 0 $ec

ARGS="resolve review-unknown --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=claude-codex); ec=$?
expect "unknown review role does not fall back" "unknown role 'review-unknown'" "$out" 2 $ec

printf '%s\n' '{"default":"dual","profiles":{"dual":{"review":{"agent":"codex","model":"gpt-6.2-astra","effort":"high"},"review-second":{"agent":"claude","model":"claude-sonnet-5-5","effort":"medium"}}}}' > "$T/profiles.json"
ARGS="resolve review-second --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "second reviewer uses its explicit entry" '"entry_role": "review-second", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "medium"' "$out" 0 $ec
cp "$EX" "$T/profiles.json"

printf '%s\n' '{"review":{"agent":"codex","model":"gpt-6.2-astra","effort":"high"},"review-second":{"agent":"claude","model":"claude-sonnet-5-5","effort":"medium"}}' > "$T/roles.json"
ARGS="save DUALS --roles-file $T/roles.json --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "save accepts review-second" "profile 'DUALS' saved to" "$out" 0 $ec
ARGS="resolve review-second --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=DUALS); ec=$?
expect "saved review-second resolves its own entry" '"entry_role": "review-second", "agent": "claude", "model": "claude-sonnet-5-5", "effort": "medium"' "$out" 0 $ec
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=DUALS); ec=$?
expect "show lists base review role" "  review -> codex / gpt-6.2-astra / effort high" "$out" 0 $ec
if [[ "$out" == *review-second* ]]; then
  fail=$((fail+1)); echo "FAIL show does not list review-second"; echo "$out"
else
  pass=$((pass+1)); echo "PASS show does not list review-second"
fi
printf '%s\n' '{"review-second":{"effort":"low"}}' > "$T/bad.json"
before=$(shasum -a 256 < "$T/profiles.json")
ARGS="save BADS --roles-file $T/bad.json --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "review-second effort requires model" "role 'review-second': 'effort' requires 'model'" "$out" 2 $ec
after=$(shasum -a 256 < "$T/profiles.json")
expect "rejected save leaves file unchanged" "$before" "$after" 0 0
cp "$EX" "$T/profiles.json"

ARGS="use B"; out=$(run ORCA_PANE_KEY=tab:pane); ec=$?
expect "use unknown profile fails" "profile 'B' is not defined" "$out" 2 $ec

ARGS="resolve write"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=nope); ec=$?
expect "unknown env profile fails, no silent fallback" "profile 'nope' from env ODD_PROFILE is not defined" "$out" 2 $ec

ARGS="use minimal"; out=$(run ORCA_PANE_KEY=tab:pane); ec=$?
expect "pane fallback binding" "via ORCA_PANE_KEY (bound to the Orca pane" "$out" 0 $ec

ARGS="resolve write"; out=$(run ORCA_PANE_KEY=tab:pane); ec=$?
expect "pane only, role absent: no agent known" "cannot determine the agent for role 'write'" "$out" 2 $ec

ARGS="use minimal"; out=$(run); ec=$?
expect "no session id: use fails" "no session id found" "$out" 2 $ec

ARGS="clear"; out=$(run CODEX_THREAD_ID=th-1); ec=$?
expect "clear removes binding" "session binding removed" "$out" 0 $ec
ARGS="resolve verify --json"; out=$(run CODEX_THREAD_ID=th-1); ec=$?
expect "after clear, default again" '"profile_source": "file default"' "$out" 0 $ec

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ORCA_TERMINAL_HANDLE=term_abc); ec=$?
expect "show: inside an Orca terminal" "orca: terminal term_abc; workers launch through Orca" "$out" 0 $ec

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "show: outside Orca" "orca: no Orca terminal (ORCA_TERMINAL_HANDLE unset); workers fall back to subagents or inline" "$out" 0 $ec

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ORCA_TERMINAL_HANDLE=$'term_abc\n```\ninjected'); ec=$?
expect "show: malformed handle not echoed" "orca: ORCA_TERMINAL_HANDLE is malformed (ignored); workers fall back to subagents or inline" "$out" 0 $ec
if [[ "$out" == *injected* ]]; then fail=$((fail+1)); echo "FAIL show: malformed handle text leaked"; else pass=$((pass+1)); echo "PASS show: malformed handle text not leaked"; fi

ARGS="resolve verify --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ORCA_TERMINAL_HANDLE='term_a`b'); ec=$?
expect "resolve: malformed handle is null" '"orca_terminal": null' "$out" 0 $ec

ARGS="resolve verify --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ORCA_TERMINAL_HANDLE=term_abc); ec=$?
expect "resolve: orca terminal field" '"orca_terminal": "term_abc"' "$out" 0 $ec

ARGS="resolve verify --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "resolve: no orca terminal, launch unchanged" '"launch": "worker-start", "terminal_command": null, "orca_terminal": null' "$out" 0 $ec

printf '{"profiles":{"X":{"write":{"effort":"high"}}}}' > "$T/profiles.json"
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "effort without model rejected" "'effort' requires 'model'" "$out" 2 $ec

printf '{"profiles":{"X":{"writer":{}}}}' > "$T/profiles.json"
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "unknown role rejected" "unknown role" "$out" 2 $ec

printf '{"default":"Y","profiles":{"X":{}}}' > "$T/profiles.json"
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "undefined default rejected" "default profile 'Y' is not defined" "$out" 2 $ec

printf '{bad' > "$T/profiles.json"
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "invalid json rejected" "invalid JSON" "$out" 2 $ec

# --- unreadable state must fail explicitly, never degrade to none/organic ---
prune_zero=$'removed 0 session binding(s) older than 30 days\nremoved 0 prompt-hook record(s) older than 30 days\nremoved 0 mode-notice record(s) older than 30 days'
if [ "$(id -u)" -ne 0 ]; then
  U="$T/unreadable"; mkdir -p "$U/sessions"
  cp "$EX" "$U/profiles.json"; printf '{"profile":"minimal"}' > "$U/sessions/s1.json"
  chmod 000 "$U/profiles.json"
  for cmd in "show" "resolve write --json" "mode --json" "list"; do
    ARGS="$cmd"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
    expect "unreadable profiles.json fails: $cmd" "odd-flow: $U/profiles.json:" "$out" 2 $ec
  done
  chmod 600 "$U/profiles.json"
  chmod 000 "$U"
  for cmd in "show" "resolve write --json" "mode --json"; do
    ARGS="$cmd"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
    expect "unreadable ODD_FLOW_HOME fails: $cmd" "odd-flow: $U/" "$out" 2 $ec
  done
  chmod 700 "$U"
  chmod 000 "$U/sessions/s1.json"
  for cmd in "show" "resolve write --json" "mode --json"; do
    ARGS="$cmd"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
    expect "unreadable session binding fails: $cmd" "odd-flow: $U/sessions/" "$out" 2 $ec
  done
  chmod 600 "$U/sessions/s1.json"
  chmod 000 "$U/sessions"
  for cmd in "show" "resolve write --json" "mode --json"; do
    ARGS="$cmd"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
    expect "unreadable sessions dir fails: $cmd" "odd-flow: $U/sessions/" "$out" 2 $ec
  done
  chmod 700 "$U/sessions"

  # clear: unreadable and read-only sessions dir
  for mode in 000 500; do
    chmod 700 "$U/sessions"; printf '{"profile":"minimal"}' > "$U/sessions/s1.json"; chmod "$mode" "$U/sessions"
    ARGS="clear"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
    expect "clear on sessions dir $mode fails explicitly" "odd-flow: $U/sessions/" "$out" 2 $ec
    chmod 700 "$U/sessions"
    [ -f "$U/sessions/s1.json" ] && { pass=$((pass+1)); echo "PASS clear $mode leaves s1.json"; } || { fail=$((fail+1)); echo "FAIL clear $mode removed s1.json"; }
  done

  chmod 500 "$U/sessions"
  ARGS="use minimal"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
  expect "use on read-only sessions dir fails explicitly" "odd-flow: cannot write session binding:" "$out" 2 $ec
  ARGS="session-mode organic"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$U"); ec=$?
  chmod 700 "$U/sessions"
  expect "session-mode on read-only sessions dir fails explicitly" "odd-flow: cannot write session binding:" "$out" 2 $ec

  mode_home="$T/mode-read-only-parent"
  mkdir "$mode_home"
  chmod 500 "$mode_home"
  out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$mode_home"); ec=$?
  chmod 700 "$mode_home"
  expect "session-mode on read-only sessions parent fails explicitly" "odd-flow: cannot write session binding:" "$out" 2 $ec

  data="$HOME/.claude/plugins/data"
  codex_data="$CODEX_HOME/plugins/data"
  agy_data="$HOME/.gemini/antigravity-cli/plugin_data"
  mkdir -p "$data/other-plugin" "$codex_data/other-plugin" "$agy_data/other-plugin"
  chmod 400 "$data" "$codex_data" "$agy_data"
  ARGS="prune"; out=$(run CLAUDE_CONFIG_DIR="$HOME/.claude"); ec=$?
  chmod 700 "$data" "$codex_data" "$agy_data"
  expect "prune ignores non-searchable data roots without matching entries" "$prune_zero" "$out" 0 $ec exact

  mkdir -p "$data/odd-flow-one" "$data/odd-flow-two"
  chmod 400 "$data"
  ARGS="prune"; out=$(run CLAUDE_CONFIG_DIR="$HOME/.claude"); ec=$?
  chmod 700 "$data"
  expected="odd-flow: $data: cannot discover plugin data: [Errno 13] Permission denied: '$data'"
  expect "prune reports a non-searchable Claude data root once" "$prune_zero"$'\n'"$expected" "$out" 2 $ec exact

  # prune: unreadable home, unreadable sessions dir, read-only sessions dir with an expired binding
  PR="$T/prune"; mkdir -p "$PR/sessions"; touch -t 202001010000 "$PR/sessions/old.json"
  chmod 000 "$PR"
  ARGS="prune"; out=$(run ODD_FLOW_HOME="$PR"); ec=$?
  expect "prune on unreadable home fails explicitly" "$prune_zero"$'\n'"odd-flow: $PR/sessions: cannot read session bindings: [Errno 13] Permission denied: '$PR/sessions'" "$out" 2 $ec exact
  chmod 700 "$PR"
  for mode in 000 500; do
    chmod "$mode" "$PR/sessions"
    ARGS="prune"; out=$(run ODD_FLOW_HOME="$PR"); ec=$?
    if [[ "$mode" == 000 ]]; then
      expected="odd-flow: $PR/sessions: cannot read session bindings: [Errno 13] Permission denied: '$PR/sessions'"
    else
      expected="odd-flow: $PR/sessions/old.json: cannot remove session binding: [Errno 13] Permission denied: '$PR/sessions/old.json'"
    fi
    expect "prune on sessions dir $mode fails explicitly" "$prune_zero"$'\n'"$expected" "$out" 2 $ec exact
    chmod 700 "$PR/sessions"
    [ -f "$PR/sessions/old.json" ] && { pass=$((pass+1)); echo "PASS prune $mode leaves old.json"; } || { fail=$((fail+1)); echo "FAIL prune $mode removed old.json"; }
  done

  # session-start must report unresolved mode, never "profile: none", when the home is unreadable
  SS="$(cd "$(dirname "$0")/.." && pwd)/scripts/session-start.py"
  chmod 000 "$PR"
  for rt in "" "--runtime codex" "--runtime antigravity"; do
    out=$(env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$PR" python3 -I "$SS" $rt 2>&1 </dev/null); ec=$?
    expect "session-start ($rt) unreadable home: mode unresolved" "mode unresolved (" "$out" 0 $ec
    if [[ "$out" == *"profile: none"* ]]; then fail=$((fail+1)); echo "FAIL session-start ($rt) printed profile: none"; else pass=$((pass+1)); echo "PASS session-start ($rt) no profile: none"; fi
  done
  chmod 700 "$PR"
else
  echo "SKIP unreadable-state checks (running as root)"
fi

for capability in O_DIRECTORY dir_fd; do
  out=$(env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" python3 -I - "$P" "$capability" 2>&1 <<'PY'
import os
import runpy
import sys
from unittest.mock import patch

script, capability = sys.argv[1:]
sys.argv = [script, "prune"]
if capability == "O_DIRECTORY":
    del os.O_DIRECTORY
    runpy.run_path(script, run_name="__main__")
else:
    os.supports_dir_fd.clear()
    with patch.object(os, "lstat", side_effect=NotImplementedError("dir_fd unavailable")):
        runpy.run_path(script, run_name="__main__")
PY
  ); ec=$?
  expect "prune rejects missing $capability support" "odd-flow: prune requires O_DIRECTORY and directory file descriptor support" "$out" 2 $ec exact
done

# not-a-directory / is-a-directory state fails explicitly (no root-sensitive permissions needed)
NF="$T/homefile"; : > "$NF"
ARGS="mode --json"; out=$(run ODD_FLOW_HOME="$NF"); ec=$?
expect "ODD_FLOW_HOME as file: mode fails" "odd-flow: $NF" "$out" 2 $ec
ARGS="prune"; out=$(run ODD_FLOW_HOME="$NF"); ec=$?
expect "ODD_FLOW_HOME as file: prune fails" "odd-flow: $NF" "$out" 2 $ec
SF="$T/sessions-as-file"; mkdir -p "$SF"; : > "$SF/sessions"
ARGS="prune --days 30"; out=$(run ODD_FLOW_HOME="$SF"); ec=$?
expect "sessions as file: prune keeps full path in errno" "$prune_zero"$'\n'"odd-flow: $SF/sessions: cannot read session bindings: [Errno 20] Not a directory: '$SF/sessions'" "$out" 2 $ec exact

if python3 -I - "$P" "$T" <<'PY'
import hashlib
import os
import runpy
import subprocess
import sys
import time
from pathlib import Path

script, scratch = sys.argv[1:]
root = Path(scratch) / "session-state"
home, claude, codex, state = (root / name for name in ("home", "claude", "codex", "state"))
outside = root / "other-plugin"
env = {
    "HOME": str(home), "CLAUDE_CONFIG_DIR": str(claude), "CODEX_HOME": str(codex),
    "ODD_FLOW_HOME": str(state), "CLAUDE_PLUGIN_DATA": str(outside), "PLUGIN_DATA": str(outside),
}
now = time.time()
old_key = hashlib.sha256(b"old session").hexdigest()
new_key = hashlib.sha256(b"new session").hexdigest()
recent_by_default = now - 15 * 86400
expired_by_default = now - 60 * 86400
removed, kept = [], []


def file(path, mtime, group):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    os.utime(path, (mtime, mtime))
    group.append(path)
    return path


def prune(*args, **overrides):
    result = subprocess.run([sys.executable, "-I", script, "prune", *args],
                            env={**env, **overrides}, capture_output=True, text=True)
    assert (result.returncode, result.stderr) == (0, ""), result
    return result.stdout.splitlines()


claude_data = claude / "plugins/data"
data_dirs = (
    claude_data / "odd-flow-market",
    home / ".claude/plugins/data/odd-flow-market",
    codex / "plugins/data/odd-flow-one",
    codex / "plugins/data/odd-flow-two",
    home / ".gemini/antigravity-cli/plugin_data/odd-flow",
)
for data_dir in data_dirs:
    for bucket in ("prompt-sessions", "session-modes"):
        file(data_dir / bucket / old_key, recent_by_default, removed)
        file(data_dir / bucket / new_key, now, kept)

target = file(outside / "prompt-sessions" / old_key, expired_by_default, kept)
(claude_data / "odd-flow-symlink").symlink_to(outside, target_is_directory=True)
file(claude_data / "unrelated/prompt-sessions" / old_key, expired_by_default, kept)
file(data_dirs[0] / "worker-tokens" / old_key, expired_by_default, kept)
bucket = data_dirs[0] / "prompt-sessions"
for name in ("A" * 64, old_key[:-1], old_key + ".json"):
    file(bucket / name, expired_by_default, kept)
link = bucket / ("1" * 64)
link.symlink_to(target)
kept.append(link)
file(bucket / ("2" * 64) / old_key, expired_by_default, kept)
linked_bucket = claude_data / "odd-flow-linked-bucket"
linked_bucket.mkdir()
(linked_bucket / "prompt-sessions").symlink_to(target.parent, target_is_directory=True)

lines = prune("--days", "7")
assert not [path for path in removed if path.exists()], lines
assert not [path for path in kept if not path.exists()], lines
assert lines[0] == "no session bindings", lines
assert lines[1:] == [
    "removed 5 prompt-hook record(s) older than 7 days",
    "removed 5 mode-notice record(s) older than 7 days",
], lines

# Both Claude config paths may refer to the same directory.
file(data_dirs[1] / "prompt-sessions" / old_key, expired_by_default, [])
file(data_dirs[1] / "session-modes" / old_key, recent_by_default, kept)
default_lines = prune(CLAUDE_CONFIG_DIR=str(home / ".claude"))
assert default_lines == [
    "no session bindings",
    "removed 1 prompt-hook record(s) older than 30 days",
    "removed 0 mode-notice record(s) older than 30 days",
], default_lines
assert all(path.exists() for path in kept)

bindings = state / "sessions"
old_binding = file(bindings / "old.json", expired_by_default, [])
file(bindings / "recent.json", recent_by_default, kept)
file(bindings / "not-a-binding", expired_by_default, kept)
binding_link = bindings / "link.json"
binding_link.symlink_to(target)
kept.append(binding_link)
file(bindings / "directory.json" / "nested.json", expired_by_default, kept)

os.environ.update(env)
helpers = runpy.run_path(script)
discovered = list(helpers["discover_plugin_data_dirs"]())
assert len(discovered) == 6 and set(discovered) == {*data_dirs, linked_bucket}, discovered
os.environ["CLAUDE_CONFIG_DIR"] = str(home / ".claude")
only_default_claude = list(helpers["discover_plugin_data_dirs"]())
assert len(only_default_claude) == 4 and set(only_default_claude) == set(data_dirs[1:]), only_default_claude
listed = helpers["list_session_state"](discovered)
assert {key: len(value) for key, value in listed.items()} == {
    "session_bindings": 2, "prompt_sessions": 5, "session_modes": 6,
}, listed
assert old_binding.exists() and all(path.exists() for path in kept)
assert prune(HOME=str(root / "no-runtimes"), CLAUDE_CONFIG_DIR="", CODEX_HOME="")[0] == (
    "removed 1 session binding(s) older than 30 days"
)
assert not old_binding.exists() and all(path.exists() for path in kept)

outside_binding = file(outside / "old.json", expired_by_default, [])
real_home = root / "real-state"
aliased_binding = file(real_home / "sessions" / "old.json", expired_by_default, [])
alias = root / "state-alias"
alias.symlink_to(real_home, target_is_directory=True)
alias_lines = prune(ODD_FLOW_HOME=str(alias))
assert alias_lines[0] == "removed 1 session binding(s) older than 30 days", alias_lines
assert not aliased_binding.exists()

linked_home = root / "linked-state"
linked_home.mkdir()
(linked_home / "sessions").symlink_to(outside, target_is_directory=True)
assert prune(ODD_FLOW_HOME=str(linked_home))[0] == "no session bindings"
assert outside_binding.exists()

linked_config = root / "linked-config"
linked_config.mkdir()
plugin_parent = root / "plugin-parent"
linked_record = file(plugin_parent / "data/odd-flow-market/prompt-sessions" / old_key,
                     expired_by_default, [])
(linked_config / "plugins").symlink_to(plugin_parent, target_is_directory=True)
assert prune(CLAUDE_CONFIG_DIR=str(linked_config))[1] == "removed 1 prompt-hook record(s) older than 30 days"
assert not linked_record.exists()

broken = claude_data / "odd-flow-broken" / "prompt-sessions"
file(broken, expired_by_default, [])
expired = (
    file(bindings / "partial.json", expired_by_default, []),
    file(broken.parent / "session-modes" / old_key, expired_by_default, []),
    file(data_dirs[-1] / "prompt-sessions" / old_key, expired_by_default, []),
)
errors = [f"odd-flow: {broken}: cannot read prompt-hook records: [Errno 20] Not a directory: '{broken}'"]
blocks = []
if os.geteuid() != 0:
    codex_root = codex / "plugins/data"
    stuck = file(data_dirs[0] / "session-modes" / old_key, expired_by_default, [])
    blocks = [(codex_root, 0o000), (stuck.parent, 0o500)]
    errors.extend([
        f"odd-flow: {codex_root}: cannot discover plugin data: [Errno 13] Permission denied: '{codex_root}'",
        f"odd-flow: {stuck}: cannot remove mode-notice record: [Errno 13] Permission denied: '{stuck}'",
    ])
try:
    for folder, mode in blocks:
        folder.chmod(mode)
    result = subprocess.run([sys.executable, "-I", script, "prune"], env=env,
                            capture_output=True, text=True)
finally:
    for folder, _ in blocks:
        folder.chmod(0o700)
assert result.returncode == 2, result
assert result.stdout.splitlines() == [
    "removed 1 session binding(s) older than 30 days",
    "removed 1 prompt-hook record(s) older than 30 days",
    "removed 1 mode-notice record(s) older than 30 days",
], result
assert sorted(result.stderr.splitlines()) == sorted(errors), result
assert not [path for path in expired if path.exists()]
assert broken.is_file() and (not blocks or stuck.is_file())
PY
then pass=$((pass+1)); echo "PASS prune session state discovery, eligibility and removal"
else fail=$((fail+1)); echo "FAIL prune session state discovery, eligibility or removal"
fi

PD="$T/profdir"; mkdir -p "$PD/profiles.json"
ARGS="show"; out=$(run ODD_FLOW_HOME="$PD"); ec=$?
expect "profiles.json as directory: show fails" "odd-flow: $PD/profiles.json" "$out" 2 $ec

# preservation: genuinely missing files keep the none/organic fallback
M="$T/missing"; mkdir -p "$M"
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$M"); ec=$?
expect "missing files: show stays none/organic" "profile: none" "$out" 0 $ec
expect "missing files: show reports organic" "mode: organic (default)" "$out" 0 $ec
ARGS="mode"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_FLOW_HOME="$M/absent"); ec=$?
expect "missing home dir: mode stays organic" "organic" "$out" 0 $ec

echo "passed=$pass failed=$fail scratch=$T"
[ "$fail" -eq 0 ]
