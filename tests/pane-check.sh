#!/usr/bin/env bash
# Check placement against fake Orca layouts without touching any real terminal.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/skills/odd-flow/scripts/pane.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
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
  'if [ "$2" = list ]; then printf "%s\n" "${ORCA_HANG:+hung }list entered" >>"$ORCA_LOG.lists"; fi' \
  'if [ "$2" = "${ORCA_HANG:-}" ]; then' \
  '  if [ "$2" = list ]; then exec sleep 5; fi' \
  '  case "$2" in' \
  '    split|create) printf "%s\n" "$2" >"$ORCA_LOG.pending" ;;' \
  '  esac' \
  '  sleep 5' \
  'fi' \
  'case "$1 $2" in' \
  '  "terminal list")' \
  '    case "$(cat "$ORCA_LOG.pending" 2>/dev/null)" in' \
  '      split) echo "{\"ok\":true,\"result\":{\"terminals\":[{\"handle\":\"term_late_split\",\"title\":null,\"command\":\"claude\"}]}}"; exit 0 ;;' \
  '      create) echo "{\"ok\":true,\"result\":{\"terminals\":[{\"handle\":\"term_late_tab\",\"title\":\"T1 verify: example\",\"command\":\"claude\"}]}}"; exit 0 ;;' \
  '    esac' \
  '    cat "$ORCA_LAYOUT" ;;' \
  '  "terminal create")' \
  '    case "${ORCA_FAIL_CREATE:-}" in' \
  '      1) echo "{\"ok\":false,\"error\":{\"message\":\"create refused\"}}"; exit 1 ;;' \
  '      garbage) echo "not json"; exit 0 ;;' \
  '      nohandle) echo "{\"ok\":true,\"result\":{\"terminal\":{}}}"; exit 0 ;;' \
  '    esac' \
  '    echo "{\"ok\":true,\"result\":{\"terminal\":{\"handle\":\"term_tab\"}}}" ;;' \
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
printf '%s\n' '{"default":"test","profiles":{"test":{"verify":{"agent":"claude"},"write":{"agent":"antigravity"},"explore":{"agent":"antigravity","model":"gemini-4","effort":"low"},"review":{"agent":"pi"}}}}' >"$T/profiles.json"

# Test-only seam: replace the TTY sampler and clock and optionally trace the
# subprocess timeout while running the real CLI and pane lock against fake Orca.
printf '%s\n' \
  'import fcntl, os, sys, time' \
  'from pathlib import Path' \
  'from types import SimpleNamespace' \
  'sys.dont_write_bytecode = True' \
  'script, widths, orca_timeout, record_age, *args = sys.argv[1:]' \
  'sys.path.insert(0, str(Path(script).parent))' \
  'import pane' \
  'if orca_timeout:' \
  '    pane.ORCA_TIMEOUT_SECS = int(orca_timeout)' \
  'if os.environ.get("ORCA_TRACE_TIMEOUT"):' \
  '    run = pane.subprocess.run' \
  '    def trace_timeout(argv, **kwargs):' \
  '        print("Orca subprocess timeout: {}s".format(kwargs.get("timeout")), file=sys.stderr)' \
  '        return run(argv, **kwargs)' \
  '    pane.subprocess.run = trace_timeout' \
  'samples = iter(widths.split())' \
  'now = 0' \
  'def sleep(seconds):' \
  '    global now' \
  '    now += seconds' \
  'def lock_held():' \
  '    lock = Path(os.environ["TMPDIR"]) / "odd-flow-pane-term_parent.lock"' \
  '    if lock.exists():' \
  '        with lock.open() as fd:' \
  '            try:' \
  '                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' \
  '            except BlockingIOError:' \
  '                return True' \
  '    return False' \
  'def sample():' \
  '    with open(os.environ["ORCA_LOG"] + ".samples", "a") as log:' \
  '        print(round(now * 1000), lock_held(), file=log)' \
  '    width = next(samples)' \
  '    return None if width == "unknown" else int(width)' \
  'if os.environ.get("ORCA_HANG") == "list":' \
  '    terminal = pane.terminal' \
  '    def trace_hung_list(*args):' \
  '        events = os.environ["ORCA_LOG"] + ".lists"' \
  '        with open(events, "a") as log:' \
  '            print("lock held:", lock_held(), file=log)' \
  '        try:' \
  '            return terminal(*args)' \
  '        finally:' \
  '            with open(events, "a") as log:' \
  '                print("hung list finished", file=log)' \
  '    pane.terminal = trace_hung_list' \
  'wall_time = time.time' \
  'if record_age:' \
  '    wall_time = lambda: 1_700_000_000' \
  '    mtime = wall_time() - float(record_age)' \
  '    os.utime(Path(os.environ["TMPDIR"]) / "odd-flow-pane-term_parent.cols", (mtime, mtime))' \
  'pane.parent_cols = sample' \
  'pane.time = SimpleNamespace(monotonic_ns=lambda: round(now * 1_000_000_000), sleep=sleep, time=wall_time)' \
  'sys.argv = [script, *args]' \
  'sys.exit(pane.main())' >"$T/sample.py"

leaf() { printf '{"type":"terminal","handle":"%s"}' "$1"; }
split() { printf '{"type":"pane-split","direction":"%s","first":%s,"second":%s}' "$1" "$2" "$3"; }
layout() {
  printf '{"ok":true,"result":{"visualLayouts":[{"root":{"type":"group","tabs":[]}},{"root":{"type":"split","first":{"type":"group","tabs":[]},"second":{"type":"group","tabs":[{"panes":%s}]}}}]}}\n' "$1" >"$T/layout"
}
open_pane() {
  local command=(python3 -I "$P") format=(--json)
  if [[ -n "${widths+x}${orca_timeout+x}${trace_timeout+x}" ]]; then
    command=(python3 -I "$T/sample.py" "$P" "${widths-}" "${orca_timeout-}" "${record_age-}")
  fi
  if [[ -n "${text_output+x}" ]]; then
    format=()
  fi
  : >"$T/argv"
  : >"$T/argv.samples"
  : >"$T/argv.pending"
  env -i HOME="$T" PATH="$PATH" TMPDIR="$T" ODD_FLOW_HOME="$T" ORCA_CLI_COMMAND="$T/orca" \
    ORCA_LOG="$T/argv" ORCA_LAYOUT="$T/layout" ORCA_TERMINAL_HANDLE="${parent-term_parent}" \
    ${min_cols+ODD_FLOW_SPLIT_MIN_COLS="$min_cols"} ORCA_FAIL_SPLIT="${fail_split-0}" \
    ${settle_ms+ODD_FLOW_SPLIT_SETTLE_MS="$settle_ms"} ORCA_FAIL_CREATE="${fail_create-0}" \
    ORCA_HANG="${hang-}" ORCA_TRACE_TIMEOUT="${trace_timeout-}" \
    "${command[@]}" open --title 'T1 verify: example' ${format[@]+"${format[@]}"} "$@" 2>&1
}
calls() {
  printf '\nargv:\n'
  cat "$T/argv"
  printf '\nend argv'
  if [[ -s "$T/argv.samples" ]]; then
    printf '\nsamples:\n'
    cat "$T/argv.samples"
  fi
}

p=$(leaf term_parent); r1=$(leaf term_r1); r2=$(leaf term_r2); r3=$(leaf term_r3)
list_call=$'\nargv:\nterminal\nlist\n--include-visual-layouts\n--json'
tab_call=$'\nterminal\ncreate\n--worktree\ncurrent\n--title\nT1 verify: example\n--command\nclaude\n--json'
right_call=$'\nterminal\nsplit\n--terminal\nterm_parent\n--direction\nvertical\n--command\nclaude\n--json'
title_call=$'\nterminal\nset-pane-title\n--terminal\nterm_new\n--title\nT1 verify: example\n--json'
width_record="$T/odd-flow-pane-term_parent.cols"

layout "$p"
rm -f "$width_record"
out=$(widths='118' settle_ms=0 open_pane --role verify); ec=$?
expect "narrow width without a recorded split creates a titled tab" 0 "$ec" \
  '"placement": "tab", "handle": "term_tab"' "$list_call$tab_call"$'\n\nend argv\nsamples:\n0 True'
expect "created tab reports the resolved verify role and null defaults" 0 "$ec" \
  '"role": "verify", "agent": "claude", "model": null, "effort": null'

rm -f "$width_record"
out=$(widths='80 81 82' settle_ms=200 open_pane --role verify); ec=$?
expect "width stays narrow: tab at the bound using the last width" 0 "$ec" \
  '"cols": 82, "min_cols": 160, "reason": "parent terminal is 82 columns wide (minimum 160)"' \
  "$list_call$tab_call"$'\n\nend argv\nsamples:\n0 True\n100 True\n200 True'

rm -f "$width_record"
out=$(widths='80 80 80' settle_ms=150 open_pane --role verify); ec=$?
expect "partial last step stays within the bound" 0 "$ec" \
  '"cols": 80' "$list_call$tab_call"$'\n\nend argv\nsamples:\n0 True\n100 True\n150 True'

out=$(widths='219' settle_ms=0 open_pane --role verify); ec=$?
expect "consecutive launches: measure again and split right at 219 columns" 0 "$ec" \
  '"placement": "split-right", "handle": "term_new"' \
  "$list_call$right_call$title_call"$'\n\nend argv\nsamples:\n0 True'

# Orca reports the parent alone again when the split closes, before the TTY grows.
printf '219\n' >"$width_record"
out=$(widths='110 110 110' settle_ms=200 open_pane --role verify); ec=$?
expect "parent alone after a split closes: use the fresh recorded width after settling" 0 "$ec" \
  '"cols": 110, "min_cols": 160, "reason": "parent terminal measured 110 columns; recorded width is 219 columns"' \
  "$list_call$right_call$title_call"$'\n\nend argv\nsamples:\n0 True\n100 True\n200 True'

printf '219\n' >"$width_record"
touch -t 200001010000 "$width_record" || exit 1
out=$(widths='110' settle_ms=0 open_pane --role verify); ec=$?
expect "an expired wide record is ignored" 0 "$ec" '"placement": "tab", "handle": "term_tab"' "$list_call$tab_call"

out=$(record_age=-1 widths='110' settle_ms=0 open_pane --role verify); ec=$?
expect "a future-dated wide record is ignored" 0 "$ec" \
  '"placement": "tab", "handle": "term_tab"' "$list_call$tab_call"

out=$(record_age=600 widths='110' settle_ms=0 open_pane --role verify); ec=$?
expect "a record exactly 10 minutes old is reused" 0 "$ec" \
  '"placement": "split-right", "handle": "term_new"' "$list_call$right_call$title_call"

out=$(record_age=600.001 widths='110' settle_ms=0 open_pane --role verify); ec=$?
expect "a record just over 10 minutes old is ignored" 0 "$ec" \
  '"placement": "tab", "handle": "term_tab"' "$list_call$tab_call"

layout "$(split horizontal "$p" "$r1")"
printf '219\n' >"$width_record"
out=$(widths='110' settle_ms=0 open_pane --role verify); ec=$?
expect "parent shares its tab: ignore the recorded wide width" 0 "$ec" \
  '"placement": "tab", "handle": "term_tab"' "$list_call$tab_call"$'\n\nend argv\nsamples:\n0 True'
layout "$p"

out=$(fail_create=1 open_pane --role verify --cols 118); ec=$?
expect "tab create refusal is visible" 1 "$ec" 'Orca terminal create: create refused' \
  "$list_call$tab_call"$'\n\nend argv'

out=$(fail_create=garbage open_pane --role verify --cols 118); ec=$?
expect "non-JSON tab create reply warns that a terminal may have opened" 1 "$ec" \
  'A terminal may have opened. Check terminal list and close it.' "$list_call$tab_call"$'\n\nend argv'

out=$(fail_create=nohandle open_pane --role verify --cols 118); ec=$?
expect "tab create reply without a handle warns that a terminal may have opened" 1 "$ec" \
  'missing terminal handle. A terminal may have opened' "$list_call$tab_call"$'\n\nend argv'

out=$(trace_timeout=1 open_pane --role verify --cols 118); ec=$?
expect "Orca subprocesses use the shipped 30-second timeout" 0 "$ec" \
  $'Orca subprocess timeout: 30s\nOrca subprocess timeout: 30s\n' "$list_call$tab_call"

out=$(hang=list orca_timeout=1 open_pane --role verify --cols 160); ec=$?
expect "list timeout stops placement" 1 "$ec" \
  'odd-flow: Orca terminal list: timed out (limit: 1s)' "$list_call"$'\n\nend argv'

started=$SECONDS
out=$(hang=create orca_timeout=1 open_pane --role verify --cols 118); ec=$?
if (( SECONDS - started >= 4 )); then
  out="Exceeded the 4-second bound: $out"
  ec=99
fi
expect "create timeout does not wait for a child holding the output pipe" 1 "$ec" \
  'Orca terminal create: timed out (limit: 1s). A terminal may have opened. Check terminal list and close it.' \
  "$list_call$tab_call"$'\n\nend argv'
out="$out"$'\n'"$(ORCA_LOG="$T/argv" ORCA_LAYOUT="$T/layout" "$T/orca" terminal list --json)"
expect "create timeout identifies the late tab by worktree and title" 1 "$ec" \
  'Worktree: current; title: "T1 verify: example".'$'\n''{"ok":true,"result":{"terminals":[{"handle":"term_late_tab","title":"T1 verify: example","command":"claude"}]}}'

layout "$(split vertical "$p" "$r1")"
out=$(hang=split orca_timeout=1 open_pane --role verify --cols 160); ec=$?
expect "split timeout warns that a pane may have opened" 1 "$ec" \
  'Orca terminal split: timed out (limit: 1s). A pane may have opened. Check terminal list and close it.' \
  "$list_call"$'\nterminal\nsplit\n--terminal\nterm_r1\n--direction\nhorizontal\n--command\nclaude\n--json\n\nend argv'
out="$out"$'\n'"$(ORCA_LOG="$T/argv" ORCA_LAYOUT="$T/layout" "$T/orca" terminal list --json)"
expect "split timeout identifies the late untitled pane by split target and direction" 1 "$ec" \
  'Split target: term_r1; direction: horizontal; intended title: "T1 verify: example".'$'\n''{"ok":true,"result":{"terminals":[{"handle":"term_late_split","title":null,"command":"claude"}]}}'
layout "$p"

out=$(hang=set-pane-title orca_timeout=1 open_pane --role verify --cols 160); ec=$?
expect "title timeout preserves the opened pane and reports a title error" 0 "$ec" \
  '"title_error": "Orca terminal set-pane-title: timed out (limit: 1s)"' \
  "$list_call$right_call$title_call"$'\n\nend argv'

out=$(widths='81 165' settle_ms=100 open_pane --role verify); ec=$?
expect "width settles under lock: split right using the new width" 0 "$ec" \
  '"cols": 165, "min_cols": 160' "$list_call$right_call$title_call"$'\n\nend argv\nsamples:\n0 True\n100 True'

out=$(widths='unknown' settle_ms=1000 open_pane --role verify); ec=$?
expect "unknown first width: tab without retrying" 0 "$ec" \
  '"cols": null, "min_cols": 160, "reason": "parent terminal width is unknown"' \
  "$list_call$tab_call"$'\n\nend argv\nsamples:\n0 True'

out=$(widths='81' settle_ms=1000 open_pane --role review); ec=$?
expect "no split command: one sample and no Orca call" 0 "$ec" \
  '"reason": "no split command for pi"' $'\nargv:\n\nend argv\nsamples:\n0 True'

out=$(widths='200' settle_ms=100 open_pane --role write); ec=$?
expect "antigravity without model: split right with agy" 0 "$ec" '"placement": "split-right", "handle": "term_new"' \
  $'\nterminal\nsplit\n--terminal\nterm_parent\n--direction\nvertical\n--command\nagy\n--json'

out=$(widths='200' settle_ms=100 open_pane --role explore); ec=$?
expect "antigravity with model and effort: split right with agy flags" 0 "$ec" '"placement": "split-right", "handle": "term_new"' \
  $'\n--command\nagy --model \'gemini-4\' --effort \'low\'\n--json'
expect "right split reports the resolved explore role, model and effort" 0 "$ec" \
  '"role": "explore", "agent": "antigravity", "model": "gemini-4", "effort": "low"'

out=$(text_output=1 open_pane --role explore --cols 200); ec=$?
expect "text preserves placement and appends the resolved role notice" 0 "$ec" \
  'pane: split-right term_new: parent terminal has at least 160 columns | explore -> antigravity / gemini-4 / effort low'

rm -f "$width_record"
out=$(widths='80 unknown' settle_ms=500 open_pane --role verify); ec=$?
expect "width lost mid-wait: tab with unknown width" 0 "$ec" \
  '"cols": null, "min_cols": 160, "reason": "parent terminal width is unknown"' \
  "$list_call$tab_call"$'\n\nend argv\nsamples:\n0 True\n100 True'

for value in -1 invalid; do
  out=$(settle_ms=$value open_pane --role verify --cols 160); ec=$?
  expect "invalid settle bound ($value) fails before Orca calls" 2 "$ec" \
    'odd-flow: ODD_FLOW_SPLIT_SETTLE_MS must be a non-negative integer' $'\nargv:\n\nend argv'
done

out=$(widths='160' settle_ms=100 open_pane --role verify); ec=$?
expect "first width is wide: split right without retrying" 0 "$ec" \
  '"placement": "split-right", "handle": "term_new"' "$list_call$right_call$title_call"

out=$(open_pane --role verify --cols 160); ec=$?
expect "wide parent: split right and set title" 0 "$ec" '"placement": "split-right", "handle": "term_new"' \
  "$list_call$right_call$title_call"$'\n\nend argv'

out=$(widths='' settle_ms=100 open_pane --role verify --cols 159); ec=$?
expect "fixed narrow width: tab without sampling" 0 "$ec" '"placement": "tab", "handle": "term_tab"' "$list_call$tab_call"$'\n\nend argv'

out=$(min_cols=159 open_pane --role verify --cols 159); ec=$?
expect "override makes the narrow parent split" 0 "$ec" '"placement": "split-right"'

layout "$(split vertical "$p" "$r1")"
out=$(widths='80' settle_ms=100 open_pane --role verify); ec=$?
expect "existing column: split below without retrying" 0 "$ec" '"placement": "split-below"' \
  $'\nsplit\n--terminal\nterm_r1\n--direction\nhorizontal\n'
expect "lower split reports the resolved verify role and null defaults" 0 "$ec" \
  '"role": "verify", "agent": "claude", "model": null, "effort": null'

layout "$(split vertical "$p" "$(split horizontal "$r1" "$(split horizontal "$r2" "$r3")")")"
out=$(open_pane --role verify --cols 80); ec=$?
expect "split the tallest leaf, not the last leaf" 0 "$ec" '"target": "term_r1"' $'\nsplit\n--terminal\nterm_r1\n'

layout "$(split vertical "$p" "$(split horizontal "$r1" "$r2")")"
out=$(open_pane --role verify --cols 80); ec=$?
expect "split the later leaf on a tie" 0 "$ec" '"target": "term_r2"' $'\nsplit\n--terminal\nterm_r2\n'

out=$(open_pane --role review --cols 200); ec=$?
expect "unsupported agent: tab without a handle or Orca call" 0 "$ec" '"placement": "tab", "handle": null' $'\nargv:\n\nend argv'
expect "tab without a handle reports the resolved review role and null defaults" 0 "$ec" \
  '"role": "review", "agent": "pi", "model": null, "effort": null'

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

per_launch_rule='Run `pane.py open` again for every launch; never reuse a placement result or handle.'
out=$(grep -F -- "$per_launch_rule" "$ROOT/skills/odd-flow/references/orca-dispatch.md"); ec=$?
expect "dispatch guide requires fresh placement on every launch" 0 "$ec" "$per_launch_rule"

role_rule='Pass the unit’s own role to `--role`; never hardcode a role in a reused helper or loop.'
mismatch_rule='Before `task-create`, compare the returned `agent`, `model` and `effort` with the same fields in the resolve JSON from step 1 (`null` means the profile does not set that field). On a mismatch, close the returned handle, if any, with `ORCA terminal close --terminal <handle>` and report the mismatch without launching.'
out=$(grep -F -e "$role_rule" -e "$mismatch_rule" "$ROOT/skills/odd-flow/references/orca-dispatch.md")
ec=1
if [[ "$out" == *"$role_rule"* && "$out" == *"$mismatch_rule"* ]]; then
  ec=0
fi
expect "dispatch guide checks the unit role before task creation" 0 "$ec" "$mismatch_rule"

layout "$p"
rm -f "$width_record"
out=$(open_pane --role verify --cols 219); ec=$?
[[ ! -e "$width_record" ]] || ec=1
expect "a fixed --cols split records no width" 0 "$ec" '"placement": "split-right", "handle": "term_new"'

printf '150\n' >"$width_record"
out=$(widths='110' settle_ms=0 open_pane --role verify); ec=$?
expect "a recorded width below the minimum is ignored" 0 "$ec" \
  '"placement": "tab", "handle": "term_tab", "parent": "term_parent", "target": null, "cols": 110'

layout "$(split vertical "$p" "$r1")"
rm -f "$width_record"
out=$(widths='219' settle_ms=0 open_pane --role verify); ec=$?
[[ ! -e "$width_record" ]] || ec=1
expect "a split below records no width" 0 "$ec" '"placement": "split-below", "handle": "term_new"'

# Two launches for the same parent: the second waits on the pane lock and runs once the first times out.
layout "$p"
started=$SECONDS
: >"$T/argv"; : >"$T/argv.samples"
: >"$T/argv.lists"
env -i HOME="$T" PATH="$PATH" TMPDIR="$T" ODD_FLOW_HOME="$T" ORCA_CLI_COMMAND="$T/orca" ORCA_LOG="$T/argv" \
  ORCA_LAYOUT="$T/layout" ORCA_TERMINAL_HANDLE=term_parent ORCA_HANG=list \
  python3 -I "$T/sample.py" "$P" "" 1 "" open --role verify --title 'T1 verify: example' --cols 160 --json \
  >"$T/first.out" 2>&1 &
first=$!
for ((i = 0; i < 100; i++)); do
  grep -qx 'hung list entered' "$T/argv.lists" && break
  sleep 0.01
done
second_ec=99
second_out='hung list did not start in time'
if (( i < 100 )); then
  echo 'second launch' >>"$T/argv.lists"
  second_out=$(env -i HOME="$T" PATH="$PATH" TMPDIR="$T" ODD_FLOW_HOME="$T" ORCA_CLI_COMMAND="$T/orca" ORCA_LOG="$T/argv" \
    ORCA_LAYOUT="$T/layout" ORCA_TERMINAL_HANDLE=term_parent ORCA_HANG= \
    python3 -I "$T/sample.py" "$P" "" 1 "" open --role verify --title 'T1 verify: example' --cols 160 --json 2>&1)
  second_ec=$?
fi
wait "$first"; first_ec=$?
events=$(cat "$T/argv.lists")
out="first=$first_ec $(cat "$T/first.out") second=$second_ec $second_out"$'\n'"$events"
ec=0
if (( first_ec != 1 || second_ec != 0 || SECONDS - started >= 4 )); then ec=1; fi
[[ "$events" == $'lock held: True\nhung list entered\nsecond launch\nhung list finished\nlist entered' ]] || ec=1
expect "a hung list releases the pane lock to a parallel launch" 0 "$ec" \
  'first=1 odd-flow: Orca terminal list: timed out (limit: 1s) second=0 {"placement": "split-right", "handle": "term_new"'

echo "scratch: $T"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
