#!/usr/bin/env bash
# Check placement against fake Orca layouts without touching any real terminal.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/skills/odd-flow/scripts/pane.py"
T=$(mktemp -d)
pass=0; fail=0
expect() { # name, expected exit, actual exit, expected output, [expected argv]
  local argv
  argv=$(calls)
  if [[ "$2" == "$3" && "$out" == *"$4"* && "$argv" == *"${5:-}"* ]]; then
    pass=$((pass+1)); echo "PASS $1"
  else
    fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $2 and: $4 ${5:-}"
    echo "  got  exit $3: $out$argv"
  fi
}

printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$@" >>"$ORCA_LOG"' \
  'case "$1 $2" in' \
  '  "terminal list") cat "$ORCA_LAYOUT" ;;' \
  '  "terminal split")' \
  '    case "${ORCA_FAIL_SPLIT:-}" in' \
  '      garbage) echo "not json"; exit 0 ;;' \
  '      nohandle) echo "{\"ok\":true,\"result\":{}}"; exit 0 ;;' \
  '    esac' \
  '    if [ "${ORCA_FAIL_SPLIT:-}" = 1 ]; then' \
  '      echo "{\"ok\":false,\"error\":{\"message\":\"split refused\"}}"; exit 1' \
  '    fi' \
  '    echo "{\"ok\":true,\"result\":{\"split\":{\"handle\":\"term_new\"}}}" ;;' \
  '  "terminal set-pane-title") echo "{\"ok\":true}" ;;' \
  '  *) exit 99 ;;' \
  'esac' >"$T/orca"
chmod +x "$T/orca"
printf '%s\n' '{"default":"test","profiles":{"test":{"verify":{"agent":"claude"},"write":{"agent":"antigravity"}}}}' >"$T/profiles.json"

leaf() { printf '{"type":"terminal","handle":"%s"}' "$1"; }
split() { printf '{"type":"pane-split","direction":"%s","first":%s,"second":%s}' "$1" "$2" "$3"; }
layout() {
  printf '{"ok":true,"result":{"visualLayouts":[{"root":{"type":"group","tabs":[]}},{"root":{"type":"split","first":{"type":"group","tabs":[]},"second":{"type":"group","tabs":[{"panes":%s}]}}}]}}\n' "$1" >"$T/layout"
}
open_pane() {
  : >"$T/argv"
  env -i HOME="$T" PATH="$PATH" TMPDIR="$T" ODD_FLOW_HOME="$T" ORCA_CLI_COMMAND="$T/orca" \
    ORCA_LOG="$T/argv" ORCA_LAYOUT="$T/layout" ORCA_TERMINAL_HANDLE="${parent-term_parent}" \
    ${min_cols+ODD_FLOW_SPLIT_MIN_COLS="$min_cols"} ORCA_FAIL_SPLIT="${fail_split-0}" \
    python3 -I "$P" open --title 'T1 verify: example' --json "$@" 2>&1
}
calls() {
  printf '\nargv:\n'
  cat "$T/argv"
  printf '\nend argv'
}

p=$(leaf term_parent); r1=$(leaf term_r1); r2=$(leaf term_r2); r3=$(leaf term_r3)
list_call=$'\nargv:\nterminal\nlist\n--include-visual-layouts\n--json'
right_call=$'\nterminal\nsplit\n--terminal\nterm_parent\n--direction\nvertical\n--command\nclaude\n--json'
title_call=$'\nterminal\nset-pane-title\n--terminal\nterm_new\n--title\nT1 verify: example\n--json'

layout "$p"
out=$(open_pane --role verify --cols 160); ec=$?
expect "wide parent: split right and set title" 0 "$ec" '"placement": "split-right", "handle": "term_new"' \
  "$list_call$right_call$title_call"$'\n\nend argv'

out=$(open_pane --role verify --cols 159); ec=$?
expect "narrow parent: tab without splitting" 0 "$ec" '"placement": "tab", "handle": null' "$list_call"$'\n\nend argv'

out=$(min_cols=159 open_pane --role verify --cols 159); ec=$?
expect "override makes the narrow parent split" 0 "$ec" '"placement": "split-right"'

layout "$(split vertical "$p" "$r1")"
out=$(open_pane --role verify --cols 80); ec=$?
expect "existing column: split below despite width" 0 "$ec" '"placement": "split-below"' \
  $'\nsplit\n--terminal\nterm_r1\n--direction\nhorizontal\n'

layout "$(split vertical "$p" "$(split horizontal "$r1" "$(split horizontal "$r2" "$r3")")")"
out=$(open_pane --role verify --cols 80); ec=$?
expect "split the tallest leaf, not the last leaf" 0 "$ec" '"target": "term_r1"' $'\nsplit\n--terminal\nterm_r1\n'

layout "$(split vertical "$p" "$(split horizontal "$r1" "$r2")")"
out=$(open_pane --role verify --cols 80); ec=$?
expect "split the later leaf on a tie" 0 "$ec" '"target": "term_r2"' $'\nsplit\n--terminal\nterm_r2\n'

out=$(open_pane --role write --cols 200); ec=$?
expect "unsupported agent: tab and no Orca call" 0 "$ec" '"placement": "tab"' $'\nargv:\n\nend argv'

out=$(fail_split=1 open_pane --role verify --cols 200); ec=$?
expect "split failure is visible" 1 "$ec" "split refused"

out=$(parent="" open_pane --role verify --cols 200); ec=$?
expect "outside Orca: refuse" 2 "$ec" "workers fall back to subagents or inline"

layout "$(split vertical "$p" "$(split horizontal "$(split vertical "$r1" "$r2")" "$(split horizontal "$r3" "$(leaf term_r4)")")")"
out=$(open_pane --role verify --cols 80); ec=$?
expect "vertical split in the column keeps half height" 0 "$ec" '"target": "term_r2"'

hint='A pane may have opened. Check terminal list and close it.'
hint_ec=1
for reply in garbage nohandle; do
  out=$(fail_split=$reply open_pane --role verify --cols 200); ec=$?
  if [[ "$ec" != 1 || "$out" != 'odd-flow: Orca terminal split:'*"$hint" ]]; then
    hint_ec=0
    break
  fi
done
expect "uncertain split reply reports possible open pane" 1 "$hint_ec" "$hint"

printf '{"ok":true,"result":{"visualLayouts":[{"root":{"type":"group","tabs":null}}]}}\n' >"$T/layout"
out=$(open_pane --role verify --cols 200); ec=$?
expect "malformed layout reports an odd-flow error" 1 "$ec" "odd-flow: malformed Orca terminal layout" "$list_call"$'\n\nend argv'

echo "scratch: $T"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
