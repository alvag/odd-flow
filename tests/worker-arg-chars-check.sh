#!/usr/bin/env bash
# Pin the inline-argument rule for Orca worker messages.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
skill="$root/skills/odd-flow"
guide="$skill/references/orca-dispatch.md"
failed=0

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

need() {
    grep -qF -- "$3" <<<"$2" || fail "$1: $3"
}

for file in "$skill"/assets/roles/{explore,write,verify,review,refute}.md \
    "$skill/assets/spec-template.md" "$guide"; do
    line=$(grep -F -- 'Keep every inline argument' "$file")
    for rule in 'Keep every inline argument of `orca orchestration` commands' \
        '`--subject`' '`--outcome`' '`--question`' \
        'free of `;`, `&`, `|`, backticks, `$`, and line breaks' \
        'put that text in the body file instead'; do
        need "${file##*/}" "$line" "$rule"
    done
done

python3 - "$guide" <<'PY' || fail 'Windows Orca permission matching'
import json
from pathlib import Path
import re
import sys

prefix = "command(regex:"
rule, = (
    json.loads(line.strip())
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.lstrip().startswith(f'"{prefix}orca orchestration ')
)
pattern = rule.removeprefix(prefix).removesuffix(")")
command = (
    'orca orchestration send --type worker_done --subject "{}" '
    r'--body-file "C:\Temp\report.md" --outcome succeeded'
)
if not re.fullmatch(pattern, command.format("Checks passed")):
    sys.exit("Clean worker_done did not match the Windows permission rule")
for char in ";&|`$\r\n":
    if re.fullmatch(pattern, command.format(f"Checks {char} report")):
        sys.exit(f"Inline subject containing {char!r} matched the Windows permission rule")
PY

exit "$failed"
