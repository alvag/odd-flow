#!/usr/bin/env bash
# Behavioral checks for the orchestrator mode in odd-flow scripts/profile.py, run against an isolated ODD_FLOW_HOME.
set -u
P="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/profile.py"
T=$(mktemp -d)
pass=0; fail=0
run() { env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" "$@" python3 -I "$P" ${ARGS} 2>&1; }
expect() { # name, expected substring, actual, expected exit, actual exit
  if [[ "$3" == *"$2"* && "$4" == "$5" ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $4 and: $2"; echo "  got  exit $5: $3"; fi
}
absent() { # name, unexpected substring, actual
  if [[ "$3" != *"$2"* ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  did not want: $2"; echo "  got: $3"; fi
}
write() { printf '%s' "$1" > "$T/profiles.json"; }

TWO='{
  "default": "A",
  "profiles": {
    "A": {
      "write": { "agent": "claude" }
    },
    "B": {
      "write": { "agent": "codex" }
    }
  },
  "workflow": {
    "B": { "orchestratorMode": "full-delegation" }
  }
}
'

# --- T1: format, resolution and reporting ---

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "no file: organic by default" "mode: organic (default)" "$out" 0 $ec

write "$TWO"
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "profile without workflow entry: organic" "mode: organic (default)" "$out" 0 $ec

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=B); ec=$?
expect "workflow entry gives full delegation" "mode: full-delegation (profile B)" "$out" 0 $ec

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=B ODD_ORCHESTRATOR_MODE=organic); ec=$?
expect "env override wins over the profile" "mode: organic (env ODD_ORCHESTRATOR_MODE)" "$out" 0 $ec

ARGS="mode --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=B ODD_ORCHESTRATOR_MODE=organic); ec=$?
expect "mode --json with the override still names the profile" '"profile": "B"' "$out" 0 $ec

ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s1 ODD_ORCHESTRATOR_MODE=full); ec=$?
expect "unknown env mode fails, no silent fallback" "ODD_ORCHESTRATOR_MODE: unknown mode 'full'" "$out" 2 $ec

ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "list shows each profile's mode" "B: write | mode: full-delegation" "$out" 0 $ec
expect "list shows organic profiles too" "A (default): write | mode: organic" "$out" 0 $ec

ARGS="use B"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "use reports the new mode and its reference" "mode: full-delegation (profile B); rules: references/mode-full-delegation.md" "$out" 0 $ec

ARGS="resolve write --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "resolve still works with a workflow map" '"profile": "B"' "$out" 0 $ec

write '{"profiles":{"A":{}},"workflow":{"A":{"orchestratorMode":"full"}}}'
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s9); ec=$?
expect "unknown mode value rejected" "workflow 'A': unknown orchestratorMode 'full' (known: organic, full-delegation)" "$out" 2 $ec

write '{"profiles":{"A":{}},"workflow":{"Z":{"orchestratorMode":"organic"}}}'
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s9); ec=$?
expect "workflow entry for an undefined profile rejected" "workflow 'Z': profile is not defined" "$out" 2 $ec

write '{"profiles":{"A":{}},"workflow":{"A":{"mode":"organic"}}}'
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s9); ec=$?
expect "unknown workflow field rejected" "workflow 'A': unknown fields ['mode']" "$out" 2 $ec

write '{"profiles":{"A":{}},"workflow":[]}'
ARGS="list"; out=$(run CLAUDE_CODE_SESSION_ID=s9); ec=$?
expect "workflow must be an object" "'workflow' must be an object" "$out" 2 $ec

# --- T2: changing the mode ---

write "$TWO"
before=$(cat "$T/profiles.json")
ARGS="set-mode A full-delegation"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "set-mode is a dry run with a diff" '+    "A": { "orchestratorMode": "full-delegation" },' "$out" 0 $ec
expect "set-mode dry run says nothing was written" "dry run: nothing written" "$out" 0 $ec
[[ "$(cat "$T/profiles.json")" == "$before" ]] && { pass=$((pass+1)); echo "PASS dry run leaves the file unchanged"; } || { fail=$((fail+1)); echo "FAIL dry run changed the file"; }

ARGS="set-mode A full-delegation --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "set-mode --yes writes" "profile 'A' mode: full-delegation" "$out" 0 $ec
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "written mode applies" "mode: full-delegation (profile A)" "$out" 0 $ec

ARGS="set-mode A full-delegation --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "same mode writes nothing" "already full-delegation; nothing written" "$out" 0 $ec

ARGS="set-mode A organic --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "organic removes the workflow entry" '-    "A": { "orchestratorMode": "full-delegation" },' "$out" 0 $ec
ARGS="set-mode B organic --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
absent "an empty workflow map is dropped" '"workflow"' "$(cat "$T/profiles.json")"

ARGS="set-mode Q organic"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "set-mode on an undefined profile fails" "profile 'Q' is not defined" "$out" 2 $ec
ARGS="set-mode A turbo"; out=$(run CLAUDE_CODE_SESSION_ID=s2); ec=$?
expect "set-mode rejects an unknown mode" "invalid choice: 'turbo'" "$out" 2 $ec

write "$TWO"
ARGS="session-mode full-delegation"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
expect "session-mode binds the mode to this session" "mode: full-delegation bound to this session via CLAUDE_CODE_SESSION_ID" "$out" 0 $ec
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
expect "session mode wins over the profile" "mode: full-delegation (session (CLAUDE_CODE_SESSION_ID))" "$out" 0 $ec
expect "session mode keeps the file default profile" "profile: A (file default)" "$out" 0 $ec
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s4); ec=$?
expect "session mode does not leak to another session" "mode: organic (default)" "$out" 0 $ec
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s3 ODD_ORCHESTRATOR_MODE=organic); ec=$?
expect "env beats the session mode" "mode: organic (env ODD_ORCHESTRATOR_MODE)" "$out" 0 $ec

ARGS="use A"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
expect "use drops the session mode and applies the profile's" "mode: organic (default)" "$out" 0 $ec
ARGS="session-mode full-delegation"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
expect "session-mode keeps a bound profile" "profile: A (session (CLAUDE_CODE_SESSION_ID))" "$out" 0 $ec

ARGS="session-mode organic"; out=$(run); ec=$?
expect "session-mode without a session id fails" "no session id found" "$out" 2 $ec
expect "session-mode without a session id names the mode override" "launch with ODD_ORCHESTRATOR_MODE instead" "$out" 2 $ec

ARGS="clear"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s3); ec=$?
expect "clear removes the session mode too" "mode: organic (default)" "$out" 0 $ec

# --- preservation: existing writers keep the workflow map ---
write "$TWO"
printf '{"write":{"agent":"claude"}}' > "$T/roles.json"
ARGS="save C --roles-file $T/roles.json --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s5); ec=$?
expect "save keeps the workflow map" '"B": { "orchestratorMode": "full-delegation" }' "$(cat "$T/profiles.json")" 0 $ec
ARGS="default B --yes"; out=$(run CLAUDE_CODE_SESSION_ID=s5); ec=$?
expect "default keeps the workflow map" '"B": { "orchestratorMode": "full-delegation" }' "$(cat "$T/profiles.json")" 0 $ec
ARGS="show"; out=$(run CLAUDE_CODE_SESSION_ID=s5); ec=$?
expect "the new default's mode applies" "mode: full-delegation (profile B)" "$out" 0 $ec

readme="${P%/skills/odd-flow/scripts/profile.py}/README.md"
organic="${P%/scripts/profile.py}/references/mode-organic.md"
full_delegation="${P%/scripts/profile.py}/references/mode-full-delegation.md"

if grep -qF -- '| Write code | Writes it itself by default. | Never; every change goes to a bounded writer' "$readme" &&
   grep -qF -- 'Work inline by default.' "$organic" &&
   grep -qF -- 'never edit a file yourself' "$full_delegation"; then
  pass=$((pass+1)); echo "PASS mode comparison: write code"
else
  fail=$((fail+1)); echo "FAIL mode comparison: write code"
fi

if grep -qF -- 'the lower of 150k tokens and 15% of the window' "$readme" &&
   grep -qF -- 'min(150000, max(1, floor(0.15 × window)))' "$organic"; then
  pass=$((pass+1)); echo "PASS mode comparison: writer context threshold"
else
  fail=$((fail+1)); echo "FAIL mode comparison: writer context threshold"
fi

if grep -qF -- "| Review corrections | Inline or with one writer. | Always one writer, with the corrected findings as its spec and the candidate's paths as its surface. |" "$readme" &&
   grep -qF -- 'Write it inline or with one `write` worker.' "$organic" &&
   grep -qF -- "with the corrected findings as its spec and the candidate's paths as its surface" "$full_delegation"; then
  pass=$((pass+1)); echo "PASS mode comparison: review corrections"
else
  fail=$((fail+1)); echo "FAIL mode comparison: review corrections"
fi

if grep -qF -- 'runs each role inline, one unit at a time' "$readme" &&
   grep -qF -- 'reports the blocker for each pending writer unit and stops it' "$readme" &&
   grep -qF -- 'the parent runs the role itself, one unit at a time' "$organic" &&
   grep -qF -- 'report the blocker for each pending unit and stop it' "$full_delegation"; then
  pass=$((pass+1)); echo "PASS mode comparison: without Orca"
else
  fail=$((fail+1)); echo "FAIL mode comparison: without Orca"
fi

echo "passed=$pass failed=$fail scratch=$T"
[ "$fail" -eq 0 ]
