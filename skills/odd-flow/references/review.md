# Review

Verification asks "does the change do what was requested". Review is an adversarial outside view of a change that already passed verification. Never use review to re-check specs.

## When

- Choose the review type before applying the ordinary rules below. Run dual review only on these requests: "revisión dual", "dual review", "doble revisión", "sométela a juicio", or "ponla a juicio"; "haz una segunda revisión" stays an ordinary review; if the request is unclear, ask "¿review normal o dual?" before launching either review. High risk alone does not trigger dual review. The forecast below applies only to ordinary review. For a dual request, use the forecast and steps in [Dual review](#dual-review).
- If the user asks for review, give the one-line forecast (lenses, roles, at most one correction) and wait for a yes.
- Otherwise, if the change names a high-risk item and verification passed, give the same forecast as a notice and launch without waiting for a yes.

## Candidate

Pin it before launching: base commit, candidate commit, and the list of changed paths. Reviewers read that range (`git diff <base>..<candidate>`), never the live worktree. Run formatters before pinning.

## Lenses

Pick only the lenses the change's consequences touch; one concern pays for one lens.

| Lens | Choose when |
|---|---|
| `risk` | A mistake could expose, lose or irreversibly change data, credentials, permissions, guards or consumed contracts |
| `resilience` | Behavior under failure changes: errors, retries, timeouts, partial writes, load, concurrency |
| `readability` | What others read or depend on changes: public APIs, messages, docs, structure |
| `reliability` | Logic or observable behavior changes that tests should pin |

Launch one `review` worker per lens, together, with `assets/roles/review.md` and the lens name.

## Reducing findings

1. Only candidate-caused `BLOCKER` or `CRITICAL` findings (`causal_disposition` introduced, behavior-activated or worsened) block. Pre-existing and base-only findings become follow-ups. `unknown` causality escalates to the user.
2. Send every blocking finding in one batch to a `refute` worker. `corroborated` stays; `refuted` becomes advisory; `inconclusive` or a missing result escalates to the user. A `refute` the parent runs itself (`orca-dispatch.md`, Without Orca) is not independent: it never demotes a finding; a finding it would refute goes to the user unchanged, with the refutation attached.
3. One bounded correction: one batch that fixes every corroborated finding and nothing else, touching only the candidate's paths, at most `min(200, ceil(candidate_changed_lines / 2))` lines. Who writes it: the active mode file (Review correction).
4. Validate once with a `verify` worker scoped to the original specs plus the corrected findings. A regression or an unfixed finding escalates to the user. No second correction and no new review round.

## Dual review

Use the triggers in [When](#when). Give a one-line forecast and wait for a yes. Name both reviewers' agents and models from `resolve review` and `resolve review-second`, note if they share one model (same resolved agent and model), and forecast at most two correction rounds.

Pin the change as in [Candidate](#candidate). Launch both reviewers concurrently with `assets/roles/review.md`, `Mode: dual`, the same pinned candidate and criteria, and the assigned ID prefix (`D1` for `review`, `D2` for `review-second`). Each covers all four lenses in one sweep and reports once without seeing the other's output.

Merge the reports. Apply step 1 of [Reducing findings](#reducing-findings). A candidate-caused `BLOCKER` or `CRITICAL` is corroborated if both reviewers report the same defect at the same location. Corroborated findings skip `refute`. Send single-source blocking findings to one `refute` batch and apply step 2 of Reducing findings to that batch, including its outcome rules and its limit on parent-run `refute`. The dual steps below replace only steps 3 and 4 (correction and validation).

1. If a correction is needed, round 1 uses the ordinary bounded correction, including the active mode's writer route and line bound. Then launch both reviewers as new workers in `Mode: re-check` with only the corrected finding rows and the correction diff. They return `verified | corroborated | regression` for each corrected ID and add no findings.
2. A missing or `unavailable` re-check result escalates to the user. A `corroborated` or `regression` result allows one more bounded correction and the same scoped re-check. At most two correction rounds; escalate survivors to the user.
3. Finally validate once with a `verify` worker scoped to the original specs plus the corrected findings. Escalate a regression or an unfixed finding as in ordinary review.

Follow the dual close rule in [Close](#close).

## Close

If dual review ran, report `Review: done (dual)` regardless of the `Risk:` line. State whether the outcome is `approved` or `escalated`. Report per reviewer: findings kept, refuted, follow-ups, rounds used, correction commits, and final validation.

Otherwise, apply the ordinary close rule below.

If `Risk:` names a high-risk item, add exactly one line: `Review: done | declined | skipped (<reason>)`. With `Risk: none`, omit it.

- `done`: Review ran. Report per lens: findings kept, refuted, follow-ups, the correction commit, and the validation result.
- `declined`: The user said no to the forecast and review did not run.
- `skipped (<reason>)`: Review did not run for another reason, such as failed verification, a user stop, or a worker launch failure.
