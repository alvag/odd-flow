#!/usr/bin/env bash
# Exercise only the public CLI and Claude Code hook payload.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI="$ROOT/skills/odd-flow/scripts/surface.py"
HOOK="$ROOT/scripts/pre-tool-use.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
echo "Scratch: $T"
fail=0

expect() {
  if "$@"; then
    echo "PASS $label"
  else
    echo "FAIL $label (exit $code)"
    cat "$T/out" "$T/err"
    fail=$((fail + 1))
  fi
}

invoke() {
  env -u CLAUDE_PLUGIN_ROOT python3 -I -c '
import json, sys
tool, field, value = sys.argv[1:]
print(json.dumps({"tool_name": tool, "tool_input": {field: value}}))
' "$1" "$2" "$3" |
    env -u CLAUDE_PLUGIN_ROOT python3 -I "$HOOK" >"$T/out" 2>"$T/err"
  code=$?
}

silent() { [[ "$code" == 0 && ! -s "$T/out" && ! -s "$T/err" ]]; }
deny() {
  [[ "$code" == 0 && ! -s "$T/err" ]] &&
    python3 -I -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        decision = json.load(f)["hookSpecificOutput"]
    assert decision["hookEventName"] == "PreToolUse"
    assert decision["permissionDecision"] == "deny"
    assert all(text in decision["permissionDecisionReason"] for text in sys.argv[2:])
except (ValueError, KeyError, AssertionError):
    sys.exit(1)
' "$T/out" "$@"
}

writer='# Role: write'
heading='## Allowed edit surfaces'
good="$writer"$'\n\n'"$heading"$'\n- `src/main.py`\n* docs/**/*.md\n\n## Task\nignored'
invalid="$writer"$'\n\n'"$heading"$'\n../escape'
printf '%s\n' "$good" >"$T/valid spec.md"
printf '%s\n' "$invalid" >"$T/invalid.md"
printf '# Role: explore\n' >"$T/explore.md"

label='S4 Agent uses the first non-empty line'
invoke Agent prompt $'\n\n'"$writer"
expect deny "$heading" missing
label='S4 Task validates writer prompts too'
invoke Task prompt "$writer"
expect deny "$heading" missing
label='S4 parallel task-create checks the second launch'
invoke Bash command "( orca orchestration task-create --environment local --spec-file '$T/valid spec.md' --task-title 'T1 write: first' --json >'$T/first.out' 2>&1 ) &
{ orca orchestration task-create --environment local --spec-file='$T/invalid.md' --task-title 'T2 write: second' --json >'$T/second.out' 2>'$T/second.err'; } &
wait"
expect deny 'invalid.md' '../escape'
label='S4 documented worker-start with a valid spec file'
invoke Bash command "orca orchestration worker-start --environment local --spec-file '$T/valid spec.md' --task-title 'T1 write: first' --worktree current --agent claude"
expect silent
label='S4 documented worker-start by task ID does not recheck'
invoke Bash command 'orca orchestration worker-start --environment local --task t1 --terminal term_test --json'
expect silent
for flag in '--spec ' '--spec='; do
  label="S4 worker-start accepts the inline form ${flag% }"
  invoke Bash command "orca orchestration worker-start ${flag}'$invalid' --worktree current --agent claude"
  expect deny '../escape'
done

label='S5 exact heading required'
invoke Agent prompt "$writer"$'\n## allowed edit surfaces\nsrc/main.py'
expect deny "$heading" missing
label='S5 section ends at the next Markdown heading'
invoke Agent prompt "$writer"$'\n'"$heading"$'\n\n### Next\nsrc/main.py'
expect deny "$heading" empty
for entry in . ./ / /tmp/file '~/file' 'src/../file' '*' '**/*' '*.py' '<repo-relative path>'; do
  label="S5 rejects $entry"
  invoke Agent prompt "$writer"$'\n'"$heading"$'\n- `'"$entry"'`'
  case "$entry" in
    .|./|/) rule='repository root' ;;
    /tmp/file) rule='absolute path' ;;
    '~/'*) rule='home-relative' ;;
    *../*) rule='parent segment' ;;
    '<'*) rule='placeholder' ;;
    *) rule='first path segment' ;;
  esac
  expect deny "$entry" "$rule"
done

for path in '$SPEC' '`read_path`' '*.md'; do
  label="S6 rejects unresolved spec path $path"
  invoke Bash command "orca orchestration task-create --spec-file '$path'"
  expect deny "$path" 'literal spec path'
done
label='S6 denies a missing spec file'
invoke Bash command "orca orchestration task-create --spec-file '$T/missing.md'"
expect deny 'missing.md' 'read' 'literal spec path'
label='S6 denies an unreadable spec file'
mkdir "$T/directory"
invoke Bash command "orca orchestration task-create --spec-file '$T/directory'"
expect deny 'directory' 'read' 'literal spec path'
label='S6 denies unparseable launch arguments'
invoke Bash command "orca orchestration worker-start --spec-file 'unclosed"
expect deny 'parse' 'literal spec path'

label='S7 preserves a plain Bash command'
invoke Bash command 'ls -la'
expect silent
label='S7 preserves an Agent prompt without the heading'
invoke Agent prompt $'Explore the repo.\n# Role: write'
expect silent
label='S7 preserves a non-writer spec'
invoke Bash command "orca orchestration task-create --spec-file '$T/explore.md'"
expect silent

label='S8 CLI prints only the normalized entries'
python3 -I "$CLI" check "$T/valid spec.md" >"$T/out" 2>"$T/err"
code=$?
entries() {
  [[ "$code" == 0 && ! -s "$T/err" ]] &&
    printf 'src/main.py\ndocs/**/*.md\n' | cmp -s - "$T/out"
}
expect entries
label='S8 CLI prints a reason on stderr and exits 2'
python3 -I "$CLI" check "$T/invalid.md" >"$T/out" 2>"$T/err"
code=$?
cli_error() {
  [[ "$code" == 2 && ! -s "$T/out" ]] &&
    grep -F '../escape' "$T/err" | grep -Fq 'parent segment'
}
expect cli_error

launch_forms() {
  local command
  for command in \
    "\"\${ORCA_CLI_COMMAND:-orca}\" orchestration task-create --spec-file '$T/invalid.md'" \
    "\"\$ORCA\" orchestration worker-start --spec-file '$T/invalid.md' --agent claude" \
    "id=\`orca orchestration task-create --spec-file '$T/invalid.md' --json\`" \
    "bash -c 'orca orchestration task-create --spec-file invalid.md'"; do
    invoke Bash command "$command"
    deny 'literal spec path' || return 1
  done
}
label='B1 wrappers, variable executables and opaque launches are checked'
expect launch_forms

label='B2 every surface heading is checked'
invoke Agent prompt "$writer"$'\n\n'"$heading"$'\nsrc/a.py\n\n## Task\nx\n\n'"$heading"$'\n/etc'
expect deny /etc

label='B3 malformed surface entries are rejected after stripping'
malformed_entries() {
  local entry
  for entry in '- `/etc` (config)' '$HOME/src' '{src,/etc}' 'src/a, /etc' '+ /etc' '> /etc' '1. /etc'; do
    invoke Agent prompt "$writer"$'\n\n'"$heading"$'\n'"$entry"
    deny "${entry#- }" || return 1
  done
}
expect malformed_entries

label='A1 a UTF-8 BOM and role capitalization do not skip validation'
invoke Agent prompt $'\xef\xbb\xbf# Role: WRITE\n## Allowed edit surfaces\n/etc'
expect deny /etc

label='A2 a fenced heading does not declare a surface'
invoke Agent prompt "$writer"$'\n```markdown\n'"$heading"$'\nsrc/a.py\n```'
expect deny "$heading" missing

label='A4 both help flags bypass launch validation'
launch_help() {
  invoke Bash command 'orca orchestration task-create --help'
  silent || return 1
  invoke Bash command 'orca orchestration worker-start -h'
  silent
}
expect launch_help

label='A6 a detected writer launch denies on an internal parser error'
printf '%s\n' '{"tool_name":"Agent","tool_input":{"prompt":"# Role: write"}}' |
  CLAUDE_PLUGIN_ROOT="$T/missing-plugin" python3 -I "$HOOK" >"$T/out" 2>"$T/err"
code=$?
expect deny 'internal error'

label='A7 docs describe the prompt-only fallback, manual check and rejected entries'
surface_docs() {
  local docs="$ROOT/skills/odd-flow/references/delegation.md" rule
  grep -Fqi 'prompt-only' "$ROOT/NOTES.md" &&
    grep -Fqi 'prompt-only' "$docs" &&
    grep -Fq 'surface.py check' "$docs" || return 1
  for rule in 'repo root' 'absolute path' '`~`' '`..`' 'wildcard' 'placeholder' 'backtick' 'dollar' 'brace' 'comma' 'list marker' 'quote marker'; do
    grep -Fq "$rule" "$docs" || return 1
  done
}
expect surface_docs

opaque_launches() {
  local prefix="orca orchestration task-create --spec-file '$T/valid spec.md'; "
  invoke Bash command "$prefix"'bash -c '"'"'orca orchestration task-create --spec-file invalid.md'"'"
  deny 'cannot parse the orchestration launch' || return 1
  invoke Bash command "$prefix""T=\"\`orca orchestration task-create --spec-file '$T/invalid.md'\`\""
  deny 'cannot parse the orchestration launch'
}
label='S4 a parsed launch does not hide an opaque launch'
expect opaque_launches

quoted_launches() {
  local prefix="orca orchestration task-create --spec-file '$T/valid spec.md'; "
  invoke Bash command "T=\"\$(orca orchestration task-create --spec-file \"$T/valid spec.md\" --json)\""
  silent || return 1
  invoke Bash command "$prefix""T=\"\$(orca orchestration task-create --spec-file '$T/invalid.md' --json)\""
  deny 'invalid.md' '../escape' 'parent segment'
}
label='S4 quoted $() validates the enclosed launch'
expect quoted_launches

label='S6 an opaque launch denial tells the caller how to rewrite it'
invoke Bash command "bash -c 'orca orchestration task-create --spec-file invalid.md'"
expect deny 'cannot parse the orchestration launch' 'plain command' 'unquoted $()'

parent_task_create() {
  local prefix='T=$($ORCA orchestration task-create --environment local --spec-file '
  local suffix=' --task-title "T1 write: x" --json | python3 -I -c '"'"'import json,sys;print(json.load(sys.stdin)["result"]["taskId"])'"'"')'
  invoke Bash command "$prefix'$T/valid spec.md'$suffix"
  silent || return 1
  invoke Bash command "$prefix$T/invalid.md$suffix"
  deny 'invalid.md' '../escape' 'parent segment'
}
label='S4 parent task-create pipeline keeps validating specs'
expect parent_task_create

label='S4 parent worker-start by task ID still needs no spec'
invoke Bash command '$ORCA orchestration worker-start --environment local --task task_x --terminal term_x --json'
expect silent

[ "$fail" -eq 0 ]
