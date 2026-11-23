#!/usr/bin/env bash
# Pin the role prompt qualifiers and the parent's verifier inputs.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
roles="$root/skills/odd-flow/assets/roles"
delegation="$root/skills/odd-flow/references/delegation.md"
failed=0

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

need() {
    grep -qF -- "$2" "$1" || fail "${1##*/}: $2"
}

for rule in 'Base commit' 'Candidate commit' 'exactly once more' 'Run zero probes' 'never count a fixture as a pass'; do
    need "$roles/verify.md" "$rule"
done

need "$roles/review.md" '"proof_refs": ["path:line or command"]'
need "$roles/review.md" 'never `introduced`'
for lens in risk resilience readability reliability; do
    grep -qE "^- $lens: .*Do not flag" "$roles/review.md" || fail "$lens counterexample"
done
grep -qE '^- risk: flag secrets, .*permission and guard changes.*consumed contracts' "$roles/review.md" || fail 'B2: risk scope'
grep -qE '^- resilience: .*missing fallback or retry.*error paths.*observability.*rollback' "$roles/review.md" || fail 'B2: resilience scope'
grep -qE '^- readability: .*duplication' "$roles/review.md" || fail 'B2: readability scope'

need "$roles/write.md" 'interaction_required'
need "$roles/write.md" 'closed set of options'
need "$roles/write.md" 'question: <only when interaction_required>'

parent_inputs=$(sed -n '/^## What the parent passes$/,/^## Correction bounds$/p' "$delegation")
printf '%s\n' "$parent_inputs" | grep -qE '^- For .*verify.*Base commit.*Candidate commit.*git commit-tree' || fail 'B1: parent pins both verifier commits'

exit "$failed"
