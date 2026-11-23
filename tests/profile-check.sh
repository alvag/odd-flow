#!/usr/bin/env bash
# Behavioral checks for odd-flow scripts/profile.py, run against an isolated ODD_FLOW_HOME.
set -u
P="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/profile.py"
EX="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/assets/profiles.example.json"
T=$(mktemp -d)
pass=0; fail=0
run() { env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" "$@" python3 -I "$P" ${ARGS} 2>&1; }
expect() { # name, expected substring, actual, expected exit, actual exit
  if [[ "$3" == *"$2"* && "$4" == "$5" ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $4 and: $2"; echo "  got  exit $5: $3"; fi
}

ARGS="resolve write --json"; out=$(run CLAUDE_CODE_SESSION_ID=s1); ec=$?
expect "no file: current agent, no model" '"flags": ["--agent", "claude"]' "$out" 0 $ec

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

echo "passed=$pass failed=$fail scratch=$T"
[ "$fail" -eq 0 ]
