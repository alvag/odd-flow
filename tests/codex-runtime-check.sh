#!/usr/bin/env bash
# Codex runtime binding of the hook scripts.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok $1"; else echo "FAIL $1"; fail=1; fi; }
export HOME="$tmp/home" TMPDIR="$tmp"
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CODEX_SESSION_ID ORCA_PANE_KEY ODD_FLOW_HOME ODD_ORCHESTRATOR_MODE ODD_PROFILE PLUGIN_ROOT PLUGIN_DATA CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA
mkdir -p "$HOME/.config/odd-flow"
cat > "$HOME/.config/odd-flow/profiles.json" <<'EOF'
{"default":"org","profiles":{"org":{"verify":{"agent":"claude"}},"fd":{"write":{"agent":"codex"}}},"workflow":{"fd":{"orchestratorMode":"full-delegation"}}}
EOF
CLAUDE_CODE_SESSION_ID=s1 python3 -I "$root/skills/odd-flow/scripts/profile.py" use fd >/dev/null
sha() { printf %s "$1" | shasum -a 256 | cut -c1-64; }
out=$(echo '{"session_id":"c2","source":"startup"}' | CLAUDE_CODE_SESSION_ID=s1 PLUGIN_ROOT="$root" CLAUDE_PLUGIN_ROOT=/nonexistent python3 -I "$root/scripts/session-start.py" --runtime codex)
check "codex ignores inherited Claude session" '[[ "$out" == *"profile: org (file default); session key: CODEX_THREAD_ID; agent: codex"* ]]'
out=$(echo '{"session_id":"c2","prompt":"# Role: verify"}' | CLAUDE_CODE_SESSION_ID=s1 PLUGIN_ROOT="$root" PLUGIN_DATA="$tmp/pd" CLAUDE_PLUGIN_DATA="$tmp/cpd" python3 -I "$root/scripts/prompt-submit.py" --runtime codex)
check "codex marker under PLUGIN_DATA" '[ "$(cat "$tmp/pd/prompt-sessions/$(sha c2)")" = worker ] && [ ! -e "$tmp/cpd" ]'
check "codex organic prints empty context" '[ "$out" = '"'"'{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}}'"'"' ]'
out=$(echo '{"session_id":"s3","source":"startup"}' | PLUGIN_ROOT=/nonexistent CODEX_THREAD_ID=c9 python3 -I "$root/scripts/session-start.py")
check "claude mode keeps CLAUDE key" '[[ "$out" == *"session key: CLAUDE_CODE_SESSION_ID; agent: claude"* ]]'
out=$(echo '{"session_id":"s3","prompt":"# Role: write"}' | ODD_ORCHESTRATOR_MODE=full-delegation PLUGIN_DATA="$tmp/pd2" CLAUDE_PLUGIN_DATA="$tmp/cpd2" python3 -I "$root/scripts/prompt-submit.py")
check "claude marker under CLAUDE_PLUGIN_DATA" '[ "$(cat "$tmp/cpd2/prompt-sessions/$(sha s3)")" = worker ] && [ ! -e "$tmp/pd2" ]'
worker_line="You are a dispatched worker. Follow your spec's role rules, not the coordinator rules from session start."
context=$(printf '%s' "$out" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
check "claude full delegation worker gets role context" '[ "$context" = "$worker_line" ]'

switch_hook() {
  local script=$1
  shift
  printf '{"session_id":"codex-switch","source":"resume","prompt":"hello"}\n' |
    PLUGIN_ROOT="$root" PLUGIN_DATA="$tmp/switch" CLAUDE_PLUGIN_DATA="$tmp/wrong" \
    env "$@" python3 -I "$root/scripts/$script" --runtime codex
}
codex_context() {
  python3 -I -c 'import json, sys; output = json.load(sys.stdin)["hookSpecificOutput"]; assert output["hookEventName"] == "UserPromptSubmit"; print(output["additionalContext"])'
}
mode_marker="$tmp/switch/session-modes/$(sha codex-switch)"
switch_hook session-start.py ODD_ORCHESTRATOR_MODE=full-delegation >/dev/null
check "Codex SessionStart records under PLUGIN_DATA" '[[ -f "$mode_marker" && "$(cat "$mode_marker")" == full-delegation && ! -e "$tmp/wrong" ]]'
out=$(switch_hook prompt-submit.py | codex_context)
check "Codex organic switch emits exactly the notice" '[ "$out" = "odd-flow mode changed to organic (default); the session-start full-delegation rules no longer apply. Rules: skills/odd-flow/references/mode-organic.md." ]'
out=$(switch_hook prompt-submit.py | codex_context)
check "Codex organic notice does not repeat" '[ -z "$out" ]'
seed="$tmp/seed"
out=$(printf '{"session_id":"codex-seed","prompt":"hello"}\n' | PLUGIN_DATA="$seed" python3 -I "$root/scripts/prompt-submit.py" --runtime codex | codex_context)
mode_marker="$seed/session-modes/$(sha codex-seed)"
check "first Codex prompt seeds missing mode without a notice" '[[ -z "$out" && -f "$mode_marker" && "$(cat "$mode_marker")" == organic ]]'

run_ps() {
  local session=$1 prompt=$2 data=$3
  shift 3
  printf '{"session_id":"%s","prompt":%s}\n' "$session" "$prompt" |
    ODD_ORCHESTRATOR_MODE=full-delegation PLUGIN_ROOT="$root" PLUGIN_DATA="$tmp/$data" CLAUDE_PLUGIN_DATA="$tmp/$data" \
    python3 -I "$root/scripts/prompt-submit.py" "$@" |
    python3 -I -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}
for rt in claude codex; do
  set --
  if [ "$rt" = codex ]; then set -- --runtime codex; fi
  o2='"Please carry out this task from my Orca coordinator by following the brief I pasted below.\n\nx"'
  check "orca2 worker first prompt [$rt]" '[ "$(run_ps w9 "$o2" "$rt" "$@")" = "$worker_line" ]'
  check "worker line persists [$rt]" '[ "$(run_ps w9 "\"hello\"" "$rt" "$@")" = "$worker_line" ]'
  run_ps p9 '"hello"' "$rt" "$@" >/dev/null
  check "parent stays coordinator [$rt]" '[[ "$(run_ps p9 "\"# Role: write\"" "$rt" "$@")" == "odd-flow mode: full-delegation"* ]]'
  check "role must be whole first line [$rt]" '[[ "$(run_ps x9 "\"# Role: write extra\"" "$rt" "$@")" == "odd-flow mode: full-delegation"* ]]'
  check "no data dir keeps coordinator [$rt]" '[[ "$(printf "%s\n" "{\"session_id\":\"n9\",\"prompt\":\"# Role: write\"}" | ODD_ORCHESTRATOR_MODE=full-delegation PLUGIN_ROOT="$root" python3 -I "$root/scripts/prompt-submit.py" "$@")" == *"odd-flow mode: full-delegation"* ]]'
done
exit $fail
