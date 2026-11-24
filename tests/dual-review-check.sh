#!/usr/bin/env bash
# Pin the dual review trigger, reduction, rounds and close.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
skill="$root/skills/odd-flow"
prompt="$skill/assets/roles/review.md"
failed=0

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

forbidden=$(printf %s 'SnVkZ21lbnQgRGF5' | base64 --decode) || exit 1
grep -rFn -- "$forbidden" "$root/skills" "$root/NOTES.md" "$root/README.md" "$root/tests"
[ "$?" -eq 1 ] || fail 'S2: no legacy name in skills, NOTES, README or tests'

review="$skill/references/review.md"
when=$(sed -n '/^## When$/,/^- If the user asks for review,/p' "$review")
dual=$(sed -n '/^## Dual review$/,/^## Close$/p' "$review")
close=$(sed -n '/^## Close$/,$p' "$review")
dual_mode=$(grep '^- `Mode: dual`:' "$prompt")
recheck=$(sed -n '/^- `Mode: re-check`:/,$p' "$prompt")
grep -qF 'Run dual review only on these requests: "revisión dual", "dual review", "doble revisión", "sométela a juicio", or "ponla a juicio";' <<< "$when" &&
    grep -qF '"haz una segunda revisión" stays an ordinary review;' <<< "$when" &&
    grep -qF 'if the request is unclear, ask "¿review normal o dual?" before launching either review.' <<< "$when" &&
    grep -qF '[When](#when)' <<< "$dual" ||
    fail 'S3: route explicit, ordinary and unclear requests in When before launch'
grep -qF 'High risk alone does not trigger dual review.' <<< "$when" ||
    fail 'S3: high risk alone cannot trigger dual review'
grep -qF 'The forecast below applies only to ordinary review. For a dual request, use the forecast and steps in [Dual review](#dual-review).' <<< "$when" ||
    fail 'S3: dual requests use the dual forecast, not the ordinary forecast'
grep -qF 'note if they share one model (same resolved agent and model)' <<< "$dual" ||
    fail 'S4: forecast when both reviewers share an agent and model'
grep '^| Review |' "$skill/references/delegation.md" | grep -qF 'dual also uses `review-second`' ||
    fail 'S4: delegation Review row lists the second reviewer'
grep -qF 'Launch both reviewers concurrently' <<< "$dual" &&
    grep -qF '`D1` for `review`, `D2` for `review-second`' <<< "$dual" &&
    grep -qF 'Each covers all four lenses in one sweep and reports once without seeing the other' <<< "$dual" &&
    grep -qF 'one generalist sweep across all four lens focuses' <<< "$dual_mode" &&
    grep -qF "Run blind: do not read the other reviewer's report." <<< "$dual_mode" &&
    grep -qF 'Use the same JSON schema and severities with `"lens": "dual"` and IDs starting at `D1-001` or `D2-001`' <<< "$dual_mode" ||
    fail 'S5: dual reviewers run concurrently and blind with all four lenses, dual JSON and assigned ID prefixes'
grep -qF 'Apply step 1 of [Reducing findings](#reducing-findings).' <<< "$dual" &&
    grep -qF 'Send single-source blocking findings to one `refute` batch and apply step 2' <<< "$dual" &&
    grep -qF 'including its outcome rules and its limit on parent-run `refute`.' <<< "$dual" &&
    grep -qF 'The dual steps below replace only steps 3 and 4 (correction and validation).' <<< "$dual" ||
    fail 'S6: dual reduction preserves ordinary causality and single-source refute rules and replaces only correction and validation'
grep -qF 'A candidate-caused `BLOCKER` or `CRITICAL` is corroborated if both reviewers report the same defect at the same location.' <<< "$dual" &&
    grep -qF 'Corroborated findings skip `refute`.' <<< "$dual" ||
    fail 'S6: findings on the same defect and location from both reviewers skip refute'
grep -qE 'At most two correction rounds; .*escalate.* to the user' <<< "$dual" ||
    fail 'S7: at most two correction rounds, then escalate survivors'
grep -qF 'When the spec selects a variant, it replaces the lens assignment; `Mode: re-check` also replaces the review duties and return schema.' < <(head -n 1 "$prompt") ||
    fail 'S7: the role header states which ordinary instructions each variant replaces'
grep -qF 'Finally validate once with a `verify` worker scoped to the original specs plus the corrected findings.' <<< "$dual" ||
    fail 'S7: one final verify covers the original specs and corrected findings'
grep -qF '`Mode: re-check`' <<< "$recheck" &&
    grep -qF '`verified`: The corrected finding no longer holds at the correction.' <<< "$recheck" &&
    grep -qF '`corroborated`: The finding still holds.' <<< "$recheck" &&
    grep -qF '`regression`: The correction introduced a new defect at the corrected lines.' <<< "$recheck" &&
    grep -qE '"inspection": *\{ *"status": *"completed \| unavailable"' <<< "$recheck" &&
    grep -qF 'A missing or `unavailable` re-check result escalates to the user.' <<< "$dual" ||
    fail 'S7: re-check defines outcomes, reports inspection and escalates missing or unavailable results'
grep -qF 'Follow the dual close rule in [Close](#close).' <<< "$dual" &&
    grep -qF 'If dual review ran, report `Review: done (dual)` regardless of the `Risk:` line.' <<< "$close" &&
    grep -qF 'State whether the outcome is `approved` or `escalated`.' <<< "$close" &&
    grep -qF 'Report per reviewer: findings kept, refuted, follow-ups, rounds used, correction commits, and final validation.' <<< "$close" ||
    fail 'S8: Close owns the dual status line, outcome and per-reviewer report'

exit "$failed"
