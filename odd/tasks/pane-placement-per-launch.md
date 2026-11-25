# Pane placement per launch

Objective: measure worker pane placement on every worker launch without relying on the orchestrator to remember it. Branch: `fix/pane-placement-per-launch`. Delivery: merge request to the supervisor bot (`merge_ready:`). Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim): "Goal: worker pane placement must be measured on every worker launch without relying on the orchestrator to remember it."
- S2 (user, verbatim): "Wanted: make the launch path measure placement per launch by itself (for example the launch step or launcher runs pane.py), so a stale result cannot be reused. Reproduce the failure first, then the smallest change that removes it. Keep the existing rules: split-right at >= ODD_FLOW_SPLIT_MIN_COLS (default 160), split-below when a right column exists, tab otherwise; Claude, Codex and Antigravity workers."
- S3 (user, verbatim): "Constraint from Max: odd-flow must work for people who use it without any Orca bot. Do not assume a supervisor bot exists. Out of scope (Max rejected): Codex pre-launch health checks and detection of Codex's \"Hooks need review\" menu."
- S4 (Max via bot, verbatim): "1 Fix tests, then commit" — create-failure tests, the consecutive-launch test on the width sampler (it must fail if a stale measurement is reused), and a grep check for the per-launch rule.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1-S3 | `pane.py` opens tabs itself and returns a single-use handle; `orca-dispatch.md` step 3 requires one `pane.py open` per launch; tests; CHANGELOG | orca:write | done | dispatch `ctx_5bb650fcf895`; 4 files within surface; RED 18/7, GREEN 25/0, run.sh 21/0; parent reran pane-check: passed=25 failed=0; candidate `b8e7346` |
| T1v | S1-S3 | Independent verification (Risk item 3) | orca:verify | done | dispatch `ctx_7e1925d1a4da`: met, no blockers; live tab at --cols 118 returned a handle and closed |
| T1r | S1-S3 | Review: reliability, resilience, readability | orca:review | done | no BLOCKER/CRITICAL; warnings R3-001/R4-002 (create failures untested), R2-001/R3-002 (consecutive test uses --cols), R4-001 (no timeout under lock) |
| T2 | S4 | Test fixes from review in `tests/pane-check.sh` | orca:write | done | dispatch `ctx_e2c60a222736`; 1 file within surface; six mutants each failed only its assertion; pane-check 29/0, run.sh 21/0; parent reran pane-check: passed=29 failed=0 |
| T2v | S1-S4 | Validation of the corrected findings | orca:verify | done | dispatch `ctx_1f41e5ddaaca` on candidate `61ee714`: S1-S4 met, R3-001/R4-002, R2-001/R3-002, R3-003 fixed (mutants), no blockers; only tests/pane-check.sh changed since `b8e7346` |

## Follow-ups (out of scope)

- [x] R4-001 (done in c76b83f, `odd/tasks/pane-dispatch-hardening.md` T1): Orca calls in `pane.py` (`terminal list`, `split`, `create`) run under the exclusive pane lock with no subprocess timeout; a hung call blocks every parallel launch.
- [x] (done in fdeeb19, `odd/tasks/pane-dispatch-hardening.md` T3) `orca-dispatch.md` does not say that `task-create` needs an Orca Run: it failed with `run_required` until `orchestration run-create` ran (observed 2026-11-25).

## Log

- 2026-11-25: T1 launched split-right (219 cols). Review found no blockers; Max chose "1 Fix tests, then commit".
- 2026-11-25: T2 and its validation passed; committed on `fix/pane-placement-per-launch`.
