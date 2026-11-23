# Pane width race

Objective: stop `pane.py open` from choosing a tab because it read the parent width before Orca finished reflowing a closed pane. Branch: `feature/role-prompts` (shared with this session's backlog; own commit). Delivery: `ask-on-risk`. Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim, backlog item 2 from the previous session): "arreglar la carrera de pane.py al medir el ancho"
- S2 (evidence): `NOTES.md` (Open items, first bullet): `pane.py open` read 81 columns just after the parent closed the verifier's right-column pane; the parent measured 165 moments later; once 133. Explorer E2 (2026-11-23): `pane.py:152` reads the TTY width once, before the pane lock (`:160-164`) and before the layout read (`:165`); nothing waits; Orca's `terminal list --include-visual-layouts` gives split topology but no rows or columns. The race is plausible, not reproduced.
- S3 (assumption): without `--cols`, the width is read after the pane lock is acquired, so a launch that follows another launch's split measures after that split.
- S4 (assumption): when no right column exists and the measured width is below the minimum, `pane.py` re-reads the parent TTY width every 100 ms, for at most `ODD_FLOW_SPLIT_SETTLE_MS` milliseconds in total (default 1000; `0` disables the wait; any other non-integer or negative value fails like an invalid `ODD_FLOW_SPLIT_MIN_COLS`). As soon as a sample reaches the minimum it opens `split-right`; if none does, it returns `tab` with the last sample in `cols` and in the reason. An unknown width (TTY unreadable) returns `tab` at once, as today.
- S5 (assumption, preservation): a right column (`split-below`), a wide first read (`split-right`) and `--cols` (fixed width, never re-sampled) behave exactly as today, with no added wait and the same JSON and text output.
- S6 (assumption): the JSON output keeps its fields; `cols` is the width the decision used. A deterministic test drives a sequence of widths without a real TTY through a test-only seam the writer chooses (for example an environment variable read only by the width sampler), documented as test-only in the code.
- S7 (assumption): `NOTES.md` moves the open item to resolved with what changed and that the original race was not reproduced; any doc that states how the width is measured says so.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1-S7 | `pane.py` width read after lock and bounded settle wait, tests in `tests/pane-check.sh`, `NOTES.md` | orca:write (full delegation, parallel with role-prompts T1: disjoint surfaces) | done | dispatch `ctx_f441b73bfbae`; 3 files within surface (+98/-15); writer RED 3 cases, GREEN pane-check 17/17, run.sh 9/9; parent reran pane-check: passed=17 failed=0; candidate `95f33a3` |
| T2 | S1-S7 | Independent verification (Risk item 4: lock ordering and timing) | orca:verify (verification trigger) | done | dispatch `ctx_9f0fb785c67e`: S1-S7 met, no blockers; 29 preserved paths byte-identical to base (real pty, fake orca, external lock holder); 7 advisories; live race unverified. Parent live probe in Orca: closed the right-column pane, then `pane.py open` at once: settle 0 -> split-right 269 cols; default -> split-right 269 cols (race not reproduced either way) |
| T3 | S4-S6 | The verifier's four regression tests in `tests/pane-check.sh` (unknown width, no-split role, bound not a multiple of 100, width lost mid-wait) | orca:write (user request L3) | done | dispatch `ctx_c3f4f5933db4`; preservation tests, each mutation failed only its check in scratch; pane-check 21/21, run.sh 10/10; parent reran pane-check: passed=21 failed=0 |

## Log

- L1 (user, 2026-11-23): "continuemos con el backlog de odd-flow"
- L2 (2026-11-23): backlog item 2 of Engram #8307. Explorer E2 dispatches `ctx_ee3c9fd46569`, `ctx_e2fd46e4512f`. Fix chosen by the parent: re-sample only when the narrow-width result would open a tab, so the common wide and right-column paths gain no wait.
- L3 (user, 2026-11-23): "lanza el writer con los tests y la nota, luego commitea"
- L4 (2026-11-23): T1-T3 committed as `90b3297` (`fix: wait for the pane width to settle before choosing a tab`), approved by the user (L3).
