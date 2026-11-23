#!/usr/bin/env bash
# Behavioral checks for scripts/context.py against fake Claude Code transcripts and
# Codex rollouts in an isolated home.
set -u
C="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/context.py"
T=$(mktemp -d)
pass=0; fail=0
expect() { # name, expected substring, actual, expected exit, actual exit
  if [[ "$3" == *"$2"* && "$4" == "$5" ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $4 and: $2"; echo "  got  exit $5: $3"; fi
}
run() { env -i HOME="$T" PATH="$PATH" "$@" python3 -I "$C" --json 2>&1; }

mkdir -p "$T/claude/projects/-repo" "$T/codex/sessions/2026/11/23"
usage() { printf '{"type":"assistant","isSidechain":%s,"message":{"model":"m","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":9}}}\n' "$@"; }
{ printf '{"type":"user","message":{"content":"hi"}}\n'
  usage false 10 20 30
  usage false 2 58 160000
  usage true 1 1 999999
  printf 'not json\n'; } >"$T/claude/projects/-repo/sess-1.jsonl"

out=$(run CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=sess-1); ec=$?
expect "claude: last main-thread usage is the context" '"tokens": 160060' "$out" 0 $ec
expect "claude: over the threshold, the trigger holds" '"holds": true' "$out" 0 $ec
expect "claude: names its source" '"source": "claude transcript"' "$out" 0 $ec

usage false 1 1 1000 >"$T/claude/projects/-repo/sess-2.jsonl"
out=$(run CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=sess-2); ec=$?
expect "claude: under the threshold, the trigger does not hold" '"holds": false' "$out" 0 $ec

out=$(run CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=missing); ec=$?
expect "claude: no transcript is unknown, not an error" '"tokens": null' "$out" 0 $ec
expect "claude: unknown says why" 'no transcript' "$out" 0 $ec

printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120000},"model_context_window":258400}}}\n{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":151000},"model_context_window":258400}}}\n' \
  >"$T/codex/sessions/2026/11/23/rollout-2026-11-23T10-00-00-th-9.jsonl"
out=$(run CODEX_HOME="$T/codex" CODEX_THREAD_ID=th-9); ec=$?
expect "codex: last token_count is the context" '"tokens": 151000' "$out" 0 $ec
expect "codex: reports the context window" '"window": 258400' "$out" 0 $ec
expect "codex: over the threshold, the trigger holds" '"holds": true' "$out" 0 $ec

out=$(run ANTIGRAVITY_CONVERSATION_ID=a-1); ec=$?
expect "antigravity: unknown, with a reason" '"reason": "no token source known for antigravity"' "$out" 0 $ec

out=$(env -i HOME="$T" PATH="$PATH" CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=sess-1 python3 -I "$C" 2>&1); ec=$?
expect "text mode: one line with tokens and the verdict" "context: 160060 tokens (claude transcript); writer context trigger: holds (threshold 150000)" "$out" 0 $ec

rm -rf "$T"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
