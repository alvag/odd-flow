#!/usr/bin/env bash
# Pin the Review close line and the forecast gates.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
skill="$root/skills/odd-flow"
refs="$skill/references"
failed=0

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

need() {
    grep -qF -- "$2" "$1"
}

format='Review: done | declined | skipped (<reason>)'
need "$skill/SKILL.md" "$format" &&
    need "$refs/odd-protocol.md" "$format" &&
    need "$refs/review.md" "$format" ||
    fail 'S1: Review status format in all three close contracts'

when=$(sed -n '/^## When$/,/^## Candidate$/p' "$refs/review.md")
review_row=$(grep '^| Review |' "$refs/delegation.md")
grep -qE '^- If the user asks for review, .*wait for a yes' <<< "$when" &&
    grep -qE '^- .*high-risk item and verification passed, .*without waiting for a yes' <<< "$when" &&
    grep -qF 'verification passed on a change that names a high-risk item' <<< "$review_row" &&
    ! grep -qF 'accepted the review forecast' <<< "$review_row" ||
    fail 'S2: only a user-requested review waits for forecast approval'

exit "$failed"
