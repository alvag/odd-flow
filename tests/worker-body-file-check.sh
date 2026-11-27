#!/usr/bin/env bash
# Pin the --body-file rule for Orca messages and show why --body is unsafe.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
skill="$root/skills/odd-flow"
failed=0

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

need() {
    grep -qF -- "$3" <<<"$2" || fail "$1: $3"
}

for file in "$skill"/assets/roles/{explore,write,verify,review,refute}.md \
    "$skill/assets/spec-template.md" "$skill/references/orca-dispatch.md"; do
    line=$(grep -F -- 'pass its literal path with `--body-file`' "$file")
    for rule in 'pass its literal path with `--body-file`' 'never put report or question text in `--body`' \
        'scratch file in the OS temp directory outside the repository' '%TEMP%' 'never heredocs'; do
        need "${file##*/}" "$line" "$rule"
    done
done

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/orca" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case $1 in
        --body) printf '%s\n' "$2" ;;
        --body-file) cat -- "$2" ;;
    esac
    shift
done
STUB
chmod +x "$tmp/orca"
report='Ran `echo EXECUTED` here.'
printf '%s\n' "$report" >"$tmp/report.md"

got=$(PATH="$tmp:$PATH" bash -c 'orca orchestration send --body-file "$1"' probe "$tmp/report.md")
[ "$got" = "$report" ] || fail "--body-file delivered: $got"
got=$(PATH="$tmp:$PATH" bash -c "orca orchestration send --body \"$report\"")
[ "$got" = 'Ran EXECUTED here.' ] || fail "double-quoted --body delivered: $got"

exit "$failed"
