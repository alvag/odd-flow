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
export ODD_FLOW_STATE_DIR="$tmp"
mkdir -m 700 "$ODD_FLOW_STATE_DIR/worker-tokens"

issue() {
  python3 -I - "$1" "$2" "$3" <<'PYTHON'
import hashlib
import json
import os
from pathlib import Path
import sys
import time

token, role, age = sys.argv[1:]
record = Path(os.environ["ODD_FLOW_STATE_DIR"]) / "worker-tokens" / hashlib.sha256(token.encode("ascii")).hexdigest()
with os.fdopen(os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
    json.dump({"role": role, "issuedAt": time.time_ns() // 1_000_000 - int(age)}, stream)
PYTHON
}
marker_prompt() {
  run_ps "$1" "\"Updated Orca dispatch\\n$2\"" codex --runtime codex
}
token=11111111111111111111111111111111
issue "$token" verify 0
out=$(marker_prompt trailing-worker "\\n  ODD-Flow-Worker: VeRiFy $token  \\n \\t\\n")
check "trailing token gives Codex worker context" '[ "$out" = "$worker_line" ]'
check "accepted Codex token record is removed" '[ ! -e "$ODD_FLOW_STATE_DIR/worker-tokens/$(sha "$token")" ]'
out=$(marker_prompt reused-token "odd-flow-worker: verify $token")
check "reused token leaves Codex coordinator context" '[[ "$out" == "odd-flow mode: full-delegation"* ]]'

token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
issue "$token" write 0
dispatch="\"You are working inside Orca, a multi-agent IDE.\n# Role: write\n\nodd-flow-worker: write $token\""
for session in tokened-dispatch reused-tokened-dispatch; do
  out=$(run_ps "$session" "$dispatch" codex --runtime codex)
  check "$session gives Codex worker context" '[ "$out" = "$worker_line" ]'
  check "$session leaves no Codex token record" '[ ! -e "$ODD_FLOW_STATE_DIR/worker-tokens/$(sha "$token")" ]'
done

out=$(marker_prompt bare-marker "odd-flow-worker: verify")
check "bare marker leaves Codex coordinator context" '[[ "$out" == "odd-flow mode: full-delegation"* ]]'

for scenario in wrong-role expired-token future-token malformed-token missing-record; do
  case "$scenario" in
    wrong-role) token=22222222222222222222222222222222; issue "$token" write 0 ;;
    expired-token) token=33333333333333333333333333333333; issue "$token" verify 960000 ;;
    future-token) token=44444444444444444444444444444444; issue "$token" verify -120000 ;;
    malformed-token) token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; issue "$token" verify 0 ;;
    missing-record) token=55555555555555555555555555555555 ;;
  esac
  out=$(marker_prompt "$scenario" "odd-flow-worker: verify $token")
  check "$scenario leaves Codex coordinator context" '[[ "$out" == "odd-flow mode: full-delegation"* ]]'
done

quoted='\"Brief_9-a\"'
for scenario in quoted-worker unquoted-worker wrapped-parent double-closing; do
  tag_id=$quoted
  case "$scenario" in
    quoted-worker) token=66666666666666666666666666666666 ;;
    unquoted-worker) token=77777777777777777777777777777777; tag_id=Brief_9-a ;;
    double-closing) token=88888888888888888888888888888888 ;;
  esac
  closing="</pasted_content id=$tag_id>"
  tail=$closing
  if [ "$scenario" != wrapped-parent ]; then
    issue "$token" verify 0
    tail="odd-flow-worker: verify $token\\n \\t\\n$closing"
  fi
  if [ "$scenario" = double-closing ]; then tail="$tail\\n$closing"; fi
  out=$(marker_prompt "$scenario" "\\n<pasted_content id=$tag_id>\\nTask text\\n$tail")
  case "$scenario" in
    *-worker) check "$scenario gives Codex worker context" '[ "$out" = "$worker_line" ]' ;;
    *) check "$scenario leaves Codex coordinator context" '[[ "$out" == "odd-flow mode: full-delegation"* ]]' ;;
  esac
done

printf 'export const value: number = 1;\n' > "$tmp/type-strip-probe.ts"
if node --input-type=module -e 'await import(process.argv[1])' "$tmp/type-strip-probe.ts" >/dev/null 2>&1; then
  python3 -I - "$root" "$tmp" <<'PYTHON'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
plugin = (root / "orca-plugin/src/prompt-hook.ts").as_uri()
for runtime in ("claude", "codex", "antigravity"):
    state = scratch / f"cross-side-{runtime}"
    data = state / "hook-data"
    dispatch = subprocess.run(
        ["node", "--input-type=module", "-e", r"""
            const { promptWithWorkerMarker } = await import(process.argv[1]);
            process.stdout.write(promptWithWorkerMarker({
                inputKind: 'orchestration', prompt: 'Task\n\n# Role: write'
            }, { stateDir: process.argv[2] }));
        """, plugin, str(state)],
        check=True, capture_output=True, text=True,
    ).stdout
    marker_line = dispatch.rstrip().splitlines()[-1]
    token = marker_line.split()[-1]
    record = state / "worker-tokens" / hashlib.sha256(token.encode("ascii")).hexdigest()
    assert record.is_file(), runtime

    for session, value, expected in (("first", dispatch, "worker"), ("second", marker_line, "parent")):
        if runtime == "antigravity":
            payload = {"conversationId": session, "invocationNum": 0, "lastUserInput": value}
        else:
            payload = {"session_id": session, "prompt": value}
        args = [] if runtime == "claude" else ["--runtime", runtime]
        subprocess.run(
            [sys.executable, "-I", str(root / "scripts/prompt-submit.py"), *args],
            env=dict(os.environ, ODD_FLOW_STATE_DIR=str(state), PLUGIN_DATA=str(data),
                     CLAUDE_PLUGIN_DATA=str(data)),
            input=json.dumps(payload), check=True, capture_output=True, text=True,
        )
        session_marker = data / "prompt-sessions" / hashlib.sha256(session.encode("ascii")).hexdigest()
        assert session_marker.read_text() == expected, (runtime, session, expected)
        assert not record.exists(), (runtime, session)
    print(f"ok plugin-issued token consumed once [{runtime}]")
PYTHON
  cross_side_status=$?
  check "plugin and runtime hooks share the token contract" '[ "$cross_side_status" -eq 0 ]'
else
  echo "SKIP plugin-to-hook worker marker test: node cannot strip TypeScript"
fi
exit $fail
