#!/usr/bin/env bash
# Behavioral checks for scripts/context.py against fake Claude Code transcripts and
# Codex rollouts in an isolated home.
set -u
C="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/context.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
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

printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40000},"model_context_window":258400}}}\n' \
  >"$T/codex/sessions/2026/11/23/rollout-2026-11-23T10-00-00-th-10.jsonl"
runtime=$(run CODEX_HOME="$T/codex" CODEX_THREAD_ID=th-10); ec=$?
expect "codex: 40k holds at 15% of the runtime window" '"tokens": 40000, "window": 258400, "threshold": 38760, "holds": true' "$runtime" 0 $ec
out=$(env -i HOME="$T" PATH="$PATH" CODEX_HOME="$T/codex" CODEX_THREAD_ID=th-10 python3 -I "$C" 2>&1); ec=$?
expect "text mode: prints the computed threshold" "context: 40000 tokens of 258400 (codex rollout); writer context trigger: holds (threshold 38760)" "$out" 0 $ec

capped=$(run CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=sess-1 ODD_FLOW_CONTEXT_WINDOW=1000000); ec=$?
expect "claude: a one-million-token override keeps the 150k cap" '"window": 1000000, "threshold": 150000, "holds": true' "$capped" 0 $ec

usage false 31000 0 0 >"$T/claude/projects/-repo/sess-3.jsonl"
override=$(run CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=sess-3 ODD_FLOW_CONTEXT_WINDOW=200000); ec=$?
expect "claude: 31k holds at 15% of the override window" '"tokens": 31000, "window": 200000, "threshold": 30000, "holds": true' "$override" 0 $ec

invalid=$(env -i HOME="$T" PATH="$PATH" CODEX_HOME="$T/codex" CODEX_THREAD_ID=th-10 \
  ODD_FLOW_CONTEXT_WINDOW=oops python3 -I "$C" --json 2>"$T/override-stderr"); ec=$?
warning=$(cat "$T/override-stderr")
if [[ "$ec" == 0 && "$invalid" == "$runtime" &&
      "$(wc -l <"$T/override-stderr" | tr -d '[:space:]')" == 1 &&
      "$warning" == *ODD_FLOW_CONTEXT_WINDOW* ]]; then
  pass=$((pass+1)); echo "PASS invalid override: ignored with one warning on stderr"
else
  echo "FAIL invalid override: expected unchanged output, exit 0, and one warning naming ODD_FLOW_CONTEXT_WINDOW"
  echo "  got exit $ec, stdout: $invalid; stderr: $warning"
  fail=$((fail+1))
fi

unknown=$(run CLAUDE_CONFIG_DIR="$T/claude" CLAUDE_CODE_SESSION_ID=sess-1)
if [[ "$runtime" == *'"window_source": "runtime"'* &&
      "$override" == *'"window_source": "ODD_FLOW_CONTEXT_WINDOW"'* &&
      "$unknown" == *'"window_source": null'* ]]; then
  pass=$((pass+1)); echo "PASS json: identifies runtime, overridden, and unknown windows"
else
  fail=$((fail+1)); echo "FAIL json: identifies runtime, overridden, and unknown windows"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
