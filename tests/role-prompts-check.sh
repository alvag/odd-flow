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
need "$roles/verify.md" "run, on base and candidate, the user's exact failing command or the writer's recorded repro steps"
need "$roles/verify.md" "Run the project's documented commands for what changed as written, inside the probe copy"
need "$roles/verify.md" 'as a check, not proof: the result may support a verdict but never replaces your own probes'
need "$roles/verify.md" 'Never create a container, database, toolchain or environment of your own, inside or outside the scratch copy; the scratch copy itself is the only exception'
need "$roles/verify.md" 'A documented setup command follows this setup-attempt rule'
need "$roles/verify.md" 'Report documented commands that need network or an install step under `unverified`; do not strip those steps or run the command'
need "$roles/verify.md" 'For setup, treat this as a missing prerequisite'
need "$roles/verify.md" 'If a documented probe command cannot run from the copy, report it under `unverified` and continue with the other probes'
need "$roles/verify.md" 'For every `unverified` entry, include the exact command, reason and any output'

need "$roles/review.md" '"proof_refs": ["path:line or command"]'
need "$roles/review.md" 'never `introduced`'
for lens in risk resilience readability reliability; do
    grep -qE "^- $lens: .*Do not flag" "$roles/review.md" || fail "$lens counterexample"
done
grep -qE '^- risk: flag secrets, .*permission and guard changes.*consumed contracts' "$roles/review.md" || fail 'B2: risk scope'
grep -qE '^- resilience: .*missing fallback or retry.*weak or broken error paths.*observability.*rollback' "$roles/review.md" || fail 'B2: resilience scope'
grep -qE '^- readability: .*duplication' "$roles/review.md" || fail 'B2: readability scope'
grep -qE '^- reliability: .*tests on the visible contract.*tests tied to implementation details.*missing named edge cases.*nondeterminism.*focused or skipped tests' "$roles/review.md" || fail 'A11: reliability scope'

need "$roles/write.md" 'interaction_required'
need "$roles/write.md" 'closed set of options'
need "$roles/write.md" 'question: <only when interaction_required>'
need "$roles/write.md" 'implement the minimum change that turns it GREEN'
need "$roles/write.md" 'Write only the code the spec needs'
need "$roles/write.md" 'For a bug, reproduce it before changing code'
need "$roles/write.md" 'repro: <steps> → <before> → <after>'
need "$roles/write.md" 'For build, test and run commands, find how the project does it'
need "$roles/write.md" 'Run a documented command as written'
need "$roles/write.md" "Use the project's documented way to select a test subset"
need "$roles/write.md" 'Never create a new environment, container, database, test harness or tool path when the project has one'
need "$roles/write.md" "Name the evidence for each thing you build: the user's words, a failing test, an observed failure, or a caller that exists today"
need "$roles/write.md" 'find the callers of what you touch and fix the shared cause once'
need "$roles/write.md" "Follow the project's established conventions for configuration (such as environment variables), patterns, structure, naming and code style. A convention decides how to build what a requirement needs, never whether to add it: building a required item the project's way is not unrequested machinery, and each item in the list below still needs a requirement; the convention only picks its form."
need "$roles/write.md" 'A convention decides how to build what a requirement needs, never whether to add it'
need "$roles/write.md" 'each item in the list below still needs a requirement'
grep -qF -- 'The list below applies to additions beyond those conventions' "$roles/write.md" && fail 'write.md: conventions must not exempt additions from the requirement list'
need "$roles/write.md" 'Each of these needs a requirement that names it'
need "$roles/write.md" 'config key, config file or environment variable'
need "$roles/write.md" 'generic parameter with a single use or that the spec does not need'
need "$roles/write.md" "the project's existing tests for what changed, and the test of each requested rule"
need "$roles/write.md" 'and the preservation and differential checks these rules require'
need "$roles/write.md" 'cite the spec item or high-risk item that justifies it'
need "$roles/write.md" 'Never drop or skip existing or needed validation at trust boundaries'
need "$roles/write.md" 'Do not compress or split code to look small'
need "$roles/write.md" 'Do not comment on self-explanatory code or narrate the change'
need "$roles/write.md" 'before, this did X; now it does Y'
need "$roles/write.md" 'read your diff and remove what has no reason'
need "$roles/write.md" 'Return exactly in this format, at most ~2000 tokens:'
need "$roles/write.md" 'Do not include diffs, file dumps or full command output; name the path, the command and the observed result line, and put long output in a scratch file whose path you list under `scratch_paths`.'
need "$roles/write.md" '- <addition beyond the smallest change>: <evidence from the "Name the evidence" rule>'

need "$root/skills/odd-flow/references/odd-protocol.md" 'GREEN with the minimum change'
need "$root/skills/odd-flow/references/odd-protocol.md" 'A reported bug is reproduced before it is fixed or declared working'
need "$root/skills/odd-flow/references/commit.md" 'every testable change it carries has observed local proof'

need "$delegation" 'Spot check: re-run one command a worker reported before accepting its result: the command that proves the main acceptance criterion, or the RED-to-GREEN test when the writer worked test-first.'
for block in core-block.md core-block-full-delegation.md; do
    need "$root/skills/odd-flow/assets/$block" 'Close every request with the verified outcome, every failed, skipped or pending check, residual risks workers reported, and the next step. Never report a check as passed without observed output.'
done
need "$root/skills/odd-flow/references/odd-protocol.md" 'Report verified outcome, every failed, skipped or pending check, residual risks workers reported (the writer'"'"'s `risks:` and the verifier'"'"'s `advisories` and `unverified` items), and the next step.'
need "$root/skills/odd-flow/references/odd-protocol.md" 'Items the writer judged missing count as residual risks, even when its `risks:` field also says `Risk: none`.'
need "$root/skills/odd-flow/SKILL.md" 'Close every request with: verified outcome; every failed, skipped or pending check; residual risks workers reported; next step; `Risk: item N (reason)` or `Risk: none` for code changes; and the profile and roles used when workers ran.'

parent_inputs=$(sed -n '/^## What the parent passes$/,/^## Correction bounds$/p' "$delegation")
printf '%s\n' "$parent_inputs" | grep -qE '^- For .*verify.*Base commit.*Candidate commit.*git commit-tree' || fail 'B1: parent pins both verifier commits'

need "$root/README.md" 'The hook accepts only a valid, unused token for that role.'

exit "$failed"
