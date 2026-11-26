#!/usr/bin/env bash
# Behavioral checks for odd-flow scripts/init.py against scratch files only.
set -u
I="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/init.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1: $2"; }
run() { python3 -I "$I" "$@" 2>&1; }

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

out=$(env -i HOME="$HOME" PATH="$PATH" python3 -I "$I" plan 2>&1); [[ $? == 2 && "$out" == *"cannot detect the agent runtime"* ]] && ok "no runtime detected: refuses" || ko "detect" "$out"
out=$(env -i HOME="$T/home" PATH="$PATH" CODEX_THREAD_ID=x python3 -I "$I" plan 2>&1); [[ "$out" == *"$T/home/.codex/AGENTS.md"* ]] && ok "codex detected from session var" || ko "codex detect" "$out"
out=$(env -i HOME="$T/home" PATH="$PATH" ANTIGRAVITY_CONVERSATION_ID=x python3 -I "$I" plan 2>&1); [[ "$out" == *"$T/home/.gemini/GEMINI.md"* ]] && ok "antigravity detected from session var" || ko "agy detect" "$out"

# failure during the atomic write must leave the target intact and no temp (append to tests/init-check.sh before the summary)
h="$T/fail.md"; printf 'x\n<!-- odd-flow:core -->\nold\n<!-- /odd-flow:core -->\n' > "$h"; cp "$h" "$T/fail.orig"
out=$(python3 -I -c 'import sys,os; sys.path.insert(0,os.path.dirname(sys.argv[1])); import init
def boom(*a,**k): raise OSError(28,"injected")
init.os.replace=boom; sys.exit(init.main(["remove","--target",sys.argv[2]]))' "$I" "$h" 2>&1)
[[ $? == 2 && "$out" == *"injected"* ]] && cmp -s "$h" "$T/fail.orig" && [[ -z $(find "$T" -name '.odd-flow-*' -print) ]] && ok "failed write keeps the target and leaves no temp" || ko "failed write" "$out"
# a block-only file is emptied, mode kept
o="$T/only.md"; python3 -I "$I" apply --target "$o" >/dev/null; chmod 640 "$o"
out=$(run remove --target "$o"); [[ $? == 0 && ! -s "$o" && $(stat -f %Lp "$o" 2>/dev/null || stat -c %a "$o") == 640 ]] && ok "block-only file emptied, mode kept" || ko "block-only" "$out"

echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
