# Dual review

Objective: add an explicit-request dual review mode to `review.md`: two blind generalist reviewers (ideally different agents or models), corroboration replaces the refuter, scoped re-check, at most two correction rounds. Branch: `feature/dual-review`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim, name redacted per S2): "hagamoslo asi, pero no mencionamos \"[name]\"", accepting the parent's proposal (verbatim): "En `review.md` se suma un modo \"dual\" que solo corre si lo pides. Lanza 2 workers `review` ciegos, generalistas en vez de lentes, idealmente con agentes o modelos distintos." / "Lo que encuentran los dos jueces se acepta sin pasar por el refuter. Lo que encuentra uno solo va a `refute`, como hoy." / "Después siguen el mismo arreglo acotado y la misma validación de siempre, más una re-revisión acotada de los jueces y como máximo una segunda ronda." / "El costo es una sección en `review.md`, unas líneas en el prompt de `review`, y probablemente un rol nuevo en el perfil (por ejemplo `review-b`) para elegir el segundo modelo."
- S2 (user constraint): no artifact (code, docs, tests, NOTES.md, commit messages, this document) names the Gentle Shell two-judge flow. The mode is called "dual review".
- S3 (user-approved trigger list, see L4-L5): dual review runs only on these requests: "revisión dual" / "dual review", "doble revisión", "sométela a juicio" / "ponla a juicio". "haz una segunda revisión" stays an ordinary review. When a request is unclear, the parent asks "¿review normal o dual?". A high-risk item never starts it; the ordinary review rules stay unchanged. Like any user-requested review, the parent gives the one-line forecast and waits for a yes.
- S4 (assumption, profile role): a new optional role `review-second` picks the second reviewer's agent, model and effort; the first reviewer resolves `review`. `review-second` falls back to `review` through the existing `review-` prefix fallback in `resolve_role`. When both resolve to the same agent and model, the parent states in the forecast that the reviewers share one model. `profile.py show` output and existing roles stay unchanged. The create-profile wizard offers `review-second` only if the user asks, recommending an agent or model different from `review`.
- S5 (assumption, discovery): both reviewers receive the same pinned candidate and criteria, cover all four lenses as generalists, run concurrently, never see each other's output, and report once (one sweep). Same JSON shape and severities as ordinary review; finding IDs `D1-001` (first reviewer) and `D2-001` (second).
- S6 (assumption, reduction): the parent merges both reports. A candidate-caused `BLOCKER`/`CRITICAL` that both reviewers report (same location and defect) is corroborated and skips `refute`; one reported by only one reviewer goes to one `refute` batch under the ordinary rules. Causality rules and follow-ups are those of ordinary review.
- S7 (assumption, rounds): round 1 is the ordinary bounded correction (same writer route and line bound). Then both reviewers, each in a new worker, re-check only the corrected finding IDs and the correction diff, returning `verified | corroborated | regression` per ID; they add no new findings. Any `corroborated` or `regression` allows one more bounded correction and re-check (round 2). Whatever survives round 2 escalates to the user; no third round. Finally one `verify` worker validates once, scoped to the original specs plus the corrected findings.
- S8 (assumption, close): the close reports `Review: done (dual)` plus, per reviewer, findings kept, refuted, follow-ups, rounds used, correction commits and the final validation; the outcome is `approved` or `escalated`.
- S9 (assumption, history): rewrite the NOTES.md line that says the Gentle Shell two-judge flow is "not replicated" so it states that dual review covers it in a lighter form, without naming it (S2).

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S4 | `review-second` role: `scripts/profile.py`, `references/profiles.md`, tests | orca:write (full delegation; parallel with T2, disjoint surfaces) | done | dispatch `ctx_316703aea508`; tests/profile-check.sh passed=64 failed=0 (parent) |
| T2 | S1-S3, S5-S9 | Dual review mode: `references/review.md`, `assets/roles/review.md` (dual and re-check variants), `references/delegation.md` Review row, NOTES.md, pinning test | orca:write (full delegation; parallel with T1) | done | first pass `ctx_29dc00cba2ae`; S3 correction `ctx_62243301d64e`; parent: dual-review-check exit 0, run.sh 19/19 |
| T4 | S2-S8 | Verifier advisories A1, A2, A4, A5, A6 and its regression tests | orca:write (full delegation; follows T3) | done | dispatch `ctx_7bb1e69e37f6`; parent: dual-review, review-close, role-prompts, profile, full-delegation checks exit 0; run.sh 19/19 |
| T5 | S1-S9 | Ordinary review (Risk item 3, verification passed): lenses readability, reliability | orca:review | done | candidate `d68da6a` (base `4a4b027`); readability `ctx_991ac03463a7`: R2-001 WARNING + 4 SUGGESTION; reliability `ctx_3f4a662c693c`: 3 WARNING; no BLOCKER/CRITICAL, no refute, no correction required |
| T6 | S2-S8 | Review follow-ups R2-001..R2-005, R3-001..R3-003 | orca:write (full delegation) | done | dispatch ctx_621ee488b6d4; parent: dual-review, review-close, role-prompts, profile, full-delegation exit 0; run.sh 19/19; diff --check clean |
| T3 | S1-S9 | Independent verification of T1+T2 candidate | orca:verify (Risk item 3: shared review prompt and profile roles) | done | dispatch `ctx_342935deaa6e`; base `4a4b027`, candidate `437c73b`: S1-S9 met, no blockers, advisories A1-A7; live Orca dual run unverified |

## Log

- L1 (user, 2026-11-24): "iremos en orden, analicemos el punto 1 primero, verifiquemos que nos aporta, que ventajas o desventajas hay, si es sobre ingenieroa o no"
- L2 (user, 2026-11-24, name redacted per S2): "hagamoslo asi, pero no mencionamos \"[name]\""
- L3 (2026-11-24): branch `feature/dual-review` created from `main` `4a4b027`. Next: launch T1 and T2 in parallel.
- L4 (user, 2026-11-24): "con que tipo de pedido se dispara: puedo decir, sometelo a juicio o haz una segunda revision o como?" Parent proposed (verbatim): "\"revisión dual\" / \"dual review\"", "\"doble revisión\"", "\"sométela a juicio\" / \"ponla a juicio\"", "\"Haz una segunda revisión\" quedaría como review normal", and on doubt the parent asks "¿review normal o dual?".
- L5 (user, 2026-11-24): "si, me sirve". S3 rewritten; T2 reopened for the trigger list.
- L6 (2026-11-24): T1 done: writer ctx_316703aea508; parent observed tests/profile-check.sh passed=64 failed=0; diff within surface (3 files). T2 first pass done (ctx_29dc00cba2ae): parent observed dual-review, review-close, role-prompts and full-delegation checks exit 0; diff within surface (5 files).
- L7 (2026-11-24): T3 verify passed (S1-S9 met, no blockers); T4 fixed advisories A1, A2, A4-A6; T5 ordinary review (readability, reliability) found no BLOCKER/CRITICAL; T6 fixed all 8 follow-ups. Unverified: a live Orca dual review run. Next: commit on feature/dual-review after user approval.
