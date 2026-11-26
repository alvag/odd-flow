#!/usr/bin/env bash
# Checks the delivered instructions, not model adherence.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
S="$R/skills/odd-flow"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; }
has() { [[ "$3" == *"$2"* ]] && ok "$1" || ko "$1" "missing: $2"; }

continuity() {
  sed -n '/^### Authorized work continuity$/{
    p
    n
    :section
    /^#/q
    p
    n
    b section
  }' "$@"
}

for block in core-block.md core-block-full-delegation.md; do
  continuity "$S/assets/$block" > "$T/$block"
  section=$(cat "$T/$block")
  has "$block: continue authorized steps" 'continue them without asking for approval at each step' "$section"
  has "$block: run the next step" 'next step you can run now; run it' "$section"
  has "$block: interpret short replies in context" 'against the immediately preceding proposal' "$section"
  has "$block: preference is not authorization" 'Accepting a preference alone does not authorize implementation' "$section"
  has "$block: stop conditions" 'Stop only for a real human decision' "$section"
  if [[ "$section" == *'binds only the work it names'* && "$section" == *'continue independent authorized work'* ]]; then
    ok "$block: scoped stop"
  else
    ko "$block: scoped stop" 'expected both: binds only the work it names; continue independent authorized work'
  fi
  has "$block: do not infer permission" 'Never infer permission to publish' "$section"
done
cmp -s "$T/core-block.md" "$T/core-block-full-delegation.md" \
  && ok 'both core blocks carry byte-identical continuity sections' \
  || ko 'both core blocks carry byte-identical continuity sections'

FULL='{"default":"A","profiles":{"A":{},"B":{}},"workflow":{"A":{"orchestratorMode":"full-delegation"}}}'
printf '%s' "$FULL" > "$T/profiles.json"
hook() { # script, payload, env...
  local script="$1" payload="$2"; shift 2
  printf '%s' "$payload" | env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_PLUGIN_ROOT="$R" "$@" python3 -I "$R/scripts/$script" 2>&1
}
ctx() { python3 -I -c 'import json,sys; d=sys.stdin.read(); print(json.loads(d)["hookSpecificOutput"]["additionalContext"] if d.strip() else "")'; }

out=$(hook session-start.py '{"source":"startup","session_id":"s1"}' ODD_PROFILE=B | ctx)
has 'organic SessionStart delivers the continuity section' "$(cat "$T/core-block.md")" "$out"
out=$(hook session-start.py '{"source":"startup","session_id":"s2"}' | ctx)
has 'full-delegation SessionStart delivers the continuity section' "$(cat "$T/core-block-full-delegation.md")" "$out"

has 'odd-protocol: independent work continues' 'independent authorized work continues' "$(cat "$S/references/odd-protocol.md")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
