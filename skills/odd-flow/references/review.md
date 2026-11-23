# Review

Verification asks "does the change do what was requested". Review is an adversarial outside view of a change that already passed verification. Never use review to re-check specs.

## When

- The user asks for a review, or
- the change names a high-risk item and verification passed.

Before launching, give the user a one-line forecast (lenses, roles, at most one correction) and wait for a yes.

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
2. Send every blocking finding in one batch to a `refute` worker. `corroborated` stays; `refuted` becomes advisory; `inconclusive` or a missing result escalates to the user. A `refute` run inline (`orca-dispatch.md`, Without Orca) is not independent: it never demotes a finding; a finding it would refute goes to the user unchanged, with the refutation attached.
3. One bounded correction: one batch that fixes every corroborated finding and nothing else, touching only the candidate's paths, at most `min(200, ceil(candidate_changed_lines / 2))` lines. Write it inline or with one `write` worker.
4. Validate once with a `verify` worker scoped to the original specs plus the corrected findings. A regression or an unfixed finding escalates to the user. No second correction and no new review round.

## Close

Report per lens: findings kept, refuted, follow-ups, the correction commit, and the validation result.
