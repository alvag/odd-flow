#!/usr/bin/env bash
# Behavioral checks for odd-flow scripts/init.py against scratch files only.
set -u
I="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/init.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1: $2"; }
isolated() { env -i HOME="$T/home" PATH="$PATH" ODD_FLOW_HOME="$T/profiles" "$@" 2>&1; }
run() { isolated python3 -I "$I" "$@"; }

assets="$(dirname "$I")/../assets"
expected_block() {
    python3 -I -X utf8 -c 'import pathlib, sys
print("<!-- odd-flow:core -->")
print(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip("\n"))
print("<!-- /odd-flow:core -->")' "$assets/$1"
}
expected_block core-block.md > "$T/organic"
expected_block core-block-full-delegation.md > "$T/full-delegation"

windows_plan() {
    isolated python3 -I -B -X utf8 -c '
import os, sys
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import init
sys.stdout.reconfigure(newline="\n")
with patch.object(init, "os", SimpleNamespace(name="nt", path=os.path)):
    sys.exit(init.main(["plan", "--mode", "organic", "--target", sys.argv[2]]))' "$I" "$1"
}

windows_output=$(windows_plan "$T/O'Brien AGENTS.md"); ec=$?
[[ $ec == 0 && "$windows_output" == *"apply (PowerShell): & "*" 'apply' '--mode' 'organic' '--target' '"*"O''Brien AGENTS.md'"$'\n'"apply (bash): "*" apply --mode organic --target "*"O'\"'\"'Brien AGENTS.md'"$'\n'* ]] &&
    ok "Windows plan prints labeled PowerShell and bash apply commands" ||
    ko "Windows plan prints labeled PowerShell and bash apply commands" "exit $ec or wrong labels and quoting"

# Check the escaping independently of the line label so missing quote doubling is its own RED.
windows_output=$(windows_plan "$T/O’Brien a‘b‚c‛d.md"); ec=$?
[[ $ec == 0 && "$windows_output" == *": & "*"O’’Brien a‘‘b‚‚c‛‛d.md'"$'\n'* ]] &&
    ok "Windows plan doubles typographic single quotes in PowerShell" ||
    ko "Windows plan doubles typographic single quotes in PowerShell" "exit $ec or wrong typographic quoting"

bash_apply_line() { sed -n -e $'s/\r$//' -e 's/^apply: //p' -e 's/^apply (bash): //p'; }

m="$T/mode target.md"
out=$(isolated ODD_ORCHESTRATOR_MODE=full-delegation python3 -I "$I" plan --runtime codex --target "$m"); ec=$?
[[ $ec == 0 && "$out" == *"mode: full-delegation (env ODD_ORCHESTRATOR_MODE); block: assets/core-block-full-delegation.md"* ]] && ok "plan names resolved mode, source and asset" || ko "plan names resolved mode, source and asset" "exit $ec or missing mode line"

apply_cmd=$(printf '%s\n' "$out" | bash_apply_line)
if [[ "$apply_cmd" == *"--runtime codex"* && "$apply_cmd" == *"--mode full-delegation"* && "$apply_cmd" == *"--target "* ]] &&
    isolated ODD_ORCHESTRATOR_MODE=organic bash -c "$apply_cmd" >/dev/null &&
    cmp -s "$m" "$T/full-delegation"; then
    ok "plan prints a runnable apply command pinned to its mode and arguments"
else
    ko "plan prints a runnable apply command pinned to its mode and arguments" "command: $apply_cmd"
fi

mkdir "$T/plan-cwd" "$T/apply-cwd"
plan_cwd=$(cd "$T/plan-cwd" && pwd -P)
relative_target=$(cd "$plan_cwd" && isolated python3 -I -c 'import os, sys; sys.stdout.write(os.path.abspath("relative target.md"))')
relative_plan=$(cd "$plan_cwd" && run plan --mode organic --target 'relative target.md'); ec=$?
relative_apply=$(printf '%s\n' "$relative_plan" | bash_apply_line)
if [[ $ec == 0 && -n "$relative_target" && "$relative_plan" == "target: $relative_target (will be created)"* && -n "$relative_apply" ]] &&
    (cd "$T/apply-cwd" && isolated bash -c "$relative_apply" >/dev/null) &&
    cmp -s "$T/plan-cwd/relative target.md" "$T/organic" &&
    [[ ! -e "$T/apply-cwd/relative target.md" ]]; then
    ok "a relative target is pinned to the plan directory"
else
    ko "a relative target is pinned to the plan directory" "plan exit $ec or replay did not write the planned file"
fi

if isolated ODD_ORCHESTRATOR_MODE=invalid python3 -I "$I" apply --mode organic --target "$T/explicit.md" >/dev/null &&
    cmp -s "$T/explicit.md" "$T/organic" &&
    isolated ODD_ORCHESTRATOR_MODE=full-delegation python3 -I "$I" apply --target "$T/resolved.md" >/dev/null &&
    cmp -s "$T/resolved.md" "$T/full-delegation"; then
    ok "apply uses an explicit mode without resolving, or resolves when omitted"
else
    ko "apply uses an explicit mode without resolving, or resolves when omitted" "apply failed or installed a different block"
fi

session_plan=$(isolated CLAUDE_CODE_SESSION_ID=init-test python3 -I "$(dirname "$I")/profile.py" session-mode full-delegation &&
    isolated CLAUDE_CODE_SESSION_ID=init-test python3 -I "$I" plan --target "$T/session.md"); ec=$?
[[ "$out" == *"warning:"*"session-only"*"persistent"* && $ec == 0 &&
    "$session_plan" == *"session (CLAUDE_CODE_SESSION_ID)"*"warning:"*"session-only"*"persistent"* ]] &&
    ok "plan warns when persisting a mode from the environment or session" ||
    ko "plan warns when persisting a mode from the environment or session" "session exit $ec or missing warning"

warning=$(printf '%s\n' "$session_plan" | sed -n '/^warning: /p')
env_apply=$(isolated ODD_ORCHESTRATOR_MODE=full-delegation python3 -I "$I" apply --target "$T/apply-env.md"); env_ec=$?
session_apply=$(isolated CLAUDE_CODE_SESSION_ID=init-test python3 -I "$I" apply --target "$T/session.md"); session_ec=$?
current_apply=$(isolated CLAUDE_CODE_SESSION_ID=init-test python3 -I "$I" apply --target "$T/session.md"); current_ec=$?
explicit_apply=$(isolated ODD_ORCHESTRATOR_MODE=full-delegation python3 -I "$I" apply --mode organic --target "$T/apply-explicit.md"); explicit_ec=$?
if [[ -n "$warning" && $env_ec == 0 && $session_ec == 0 && $current_ec == 0 && $explicit_ec == 0 &&
    "$env_apply" == *"odd-flow block written"*"mode: full-delegation"*"assets/core-block-full-delegation.md"*"$warning"* &&
    "$session_apply" == *"odd-flow block written"*"mode: full-delegation"*"assets/core-block-full-delegation.md"*"$warning"* &&
    "$current_apply" == *"up to date, nothing written"*"mode: full-delegation"*"$warning"* &&
    "$explicit_apply" == *"odd-flow block written"*"mode: organic"*"assets/core-block.md"* && "$explicit_apply" != *"warning:"* ]]; then
    ok "apply reports the mode and asset and warns only on session-only resolution"
else
    ko "apply reports the mode and asset and warns only on session-only resolution" "missing mode, asset or expected warning"
fi

refuses=1
for command in plan apply; do
    refused=$(isolated ODD_ORCHESTRATOR_MODE=invalid python3 -I "$I" "$command" --target "$T/refused.md"); ec=$?
    unknown=$(isolated python3 -I -c 'import os, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import init
result = subprocess.CompletedProcess([], 0, b"{\"mode\": \"invalid\", \"source\": \"default\"}", b"")
with patch("subprocess.run", return_value=result):
    sys.exit(init.main(sys.argv[2:]))' "$I" "$command" --target "$T/refused.md"); unknown_ec=$?
    [[ $ec == 2 && "$refused" == *"--mode"* && $unknown_ec == 2 && "$unknown" == *"--mode"* && ! -e "$T/refused.md" ]] || refuses=0
done
[[ $refuses == 1 ]] && ok "plan and apply refuse failed resolution and unknown modes" || ko "plan and apply refuse failed resolution and unknown modes" "expected exit 2, --mode guidance and no write"

cp "$T/organic" "$T/stale.md"
stale=$(isolated ODD_ORCHESTRATOR_MODE=full-delegation python3 -I "$I" plan --target "$T/stale.md"); ec=$?
printf '<!-- odd-flow:core -->\nold\n<!-- /odd-flow:core -->\n' > "$T/old.md"
old=$(run plan --target "$T/old.md"); old_ec=$?
[[ $ec == 0 && "$stale" == *"installed mode: organic"*"status: changes pending"* &&
    $old_ec == 0 && "$old" == *"installed mode: unknown"*"status: changes pending"* ]] &&
    ok "plan identifies a different or unrecognized installed block" ||
    ko "plan identifies a different or unrecognized installed block" "missing installed mode or pending status"

f="$T/new/CLAUDE.md"
out=$(run plan --target "$f"); [[ $? == 0 && "$out" == *"will be created"* && ! -e "$f" ]] && ok "plan writes nothing" || ko "plan writes nothing" "$out"
out=$(run apply --target "$f"); [[ $? == 0 && "$out" == *"(new file)"* && $(grep -c '<!-- odd-flow:core -->' "$f") == 1 ]] && ok "apply creates file with one block" || ko "apply creates" "$out"
out=$(run apply --target "$f"); [[ "$out" == *"up to date"* ]] && ok "apply is idempotent" || ko "idempotent" "$out"

g="$T/user.md"; printf '# Mine\n\nKeep this line.\n' > "$g"; cp "$g" "$T/user.orig"
run apply --target "$g" >/dev/null
head -3 "$g" | cmp -s - "$T/user.orig" && ok "user text above block preserved byte for byte" || ko "preserve prefix" "$(head -3 "$g")"
ls "$T"/user.md.bak-odd-flow-* >/dev/null 2>&1 && ok "backup created before write" || ko "backup" "none"

printf '\nTrailing user text.\n' >> "$g"
python3 -I -c 'import sys,re; p=sys.argv[1]; s=open(p).read(); s=s.replace("## ODD workflow (odd-flow)","## OLD BLOCK"); open(p,"w").write(s)' "$g"
run apply --target "$g" >/dev/null
[[ $(grep -c '<!-- odd-flow:core -->' "$g") == 1 && $(grep -c 'OLD BLOCK' "$g") == 0 && $(grep -c 'Trailing user text.' "$g") == 1 && $(grep -c 'Keep this line.' "$g") == 1 ]] && ok "stale block replaced in place, text after it kept" || ko "replace" "$(grep -n 'odd-flow\|OLD\|Trailing\|Keep' "$g")"

d="$T/dup.md"; cat "$g" "$g" > "$d"
out=$(run apply --target "$d"); [[ $? == 2 && "$out" == *"more than one odd-flow block"* ]] && ok "two blocks refused" || ko "dup" "$out"
u="$T/unbal.md"; printf 'x\n<!-- odd-flow:core -->\nbody\n' > "$u"
out=$(run apply --target "$u"); [[ $? == 2 && "$out" == *"unbalanced"* ]] && ok "unbalanced marker refused" || ko "unbal" "$out"
ln -s "$g" "$T/link.md"
out=$(run apply --target "$T/link.md"); [[ $? == 2 && "$out" == *"symlink"* ]] && ok "symlink target refused" || ko "symlink" "$out"

chmod 600 "$g"
cp "$g" "$T/before-remove"
ln "$g" "$T/remove-link"
out=$(run remove --target "$g"); [[ $? == 0 && $(grep -c 'odd-flow:core' "$g") == 0 && $(grep -c 'Keep this line.' "$g") == 1 && $(grep -c 'Trailing user text.' "$g") == 1 ]] && ok "remove deletes only the block" || ko "remove" "$out"
if ! cmp -s "$T/before-remove" "$T/remove-link"; then
    ko "remove uses atomic replacement" "the hard link's content changed"
elif [[ $(grep -c 'odd-flow:core' "$g") != 0 ]]; then
    ko "remove uses atomic replacement" "the target still has the block"
elif [[ $(python3 -I -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$g") != 0o600 ]]; then
    ko "remove uses atomic replacement" "the target mode changed"
elif [[ -n $(find "$T" -name '.odd-flow-*' -print) ]]; then
    ko "remove uses atomic replacement" "a temporary file remains"
else
    ok "remove replaces the inode, preserves mode and leaves no temporary files"
fi

out=$(run plan); [[ $? == 2 && "$out" == *"cannot detect the agent runtime"* ]] && ok "no runtime detected: refuses" || ko "detect" "$out"
out=$(isolated CODEX_THREAD_ID=x python3 -I "$I" plan); [[ "$out" == *"$T/home/.codex/AGENTS.md"* ]] && ok "codex detected from session var" || ko "codex detect" "$out"
out=$(isolated ANTIGRAVITY_CONVERSATION_ID=x python3 -I "$I" plan); [[ "$out" == *"$T/home/.gemini/GEMINI.md"* ]] && ok "antigravity detected from session var" || ko "agy detect" "$out"

# failure during the atomic write must leave the target intact and no temp
h="$T/fail.md"; printf 'x\n<!-- odd-flow:core -->\nold\n<!-- /odd-flow:core -->\n' > "$h"; cp "$h" "$T/fail.orig"
out=$(python3 -I -c 'import sys,os; sys.path.insert(0,os.path.dirname(sys.argv[1])); import init
def boom(*a,**k): raise OSError(28,"injected")
init.os.replace=boom; sys.exit(init.main(["remove","--target",sys.argv[2]]))' "$I" "$h" 2>&1)
[[ $? == 2 && "$out" == *"injected"* ]] && cmp -s "$h" "$T/fail.orig" && [[ -z $(find "$T" -name '.odd-flow-*' -print) ]] && ok "failed write keeps the target and leaves no temp" || ko "failed write" "$out"
# a block-only file is emptied, mode kept
o="$T/only.md"; run apply --target "$o" >/dev/null; chmod 640 "$o"
out=$(run remove --target "$o"); [[ $? == 0 && ! -s "$o" && $(python3 -I -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$o") == 640 ]] && ok "block-only file emptied, mode kept" || ko "block-only" "$out"

echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
