#!/usr/bin/env bash
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
guide="$root/skills/odd-flow/references/orca-dispatch.md"
failed=0

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

need() {
    grep -qF -- "$3" <<<"$2" || fail "$1: $3"
}

docs=$(cat "$guide") || exit 1
need "${guide##*/}" "$docs" '"command(orca orchestration)"'
need "${guide##*/}" "$docs" '"command(regex:orca orchestration (send|check|ask|reply) [^;&|`$\\r\\n]*)"'

if grep -qE 'command\(orca\)|command\((regex:)?orca[^"`]*\.\*' <<<"$docs"; then
    fail "${guide##*/}: overbroad Orca permission rule"
fi

exit "$failed"
