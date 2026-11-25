# Pane dispatch hardening

Objective: close the open follow-ups on worker pane placement and dispatch. Branch: `fix/pane-dispatch-hardening`. Delivery: `ask-on-risk`. Runner: `bash tests/pane-check.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (Max, verbatim): "R4-001 (high): skills/odd-flow/scripts/pane.py runs its Orca calls (terminal list, split, create) under the exclusive pane lock with no subprocess timeout; one hung call blocks every parallel launch. Reproduce (for example a fake orca that sleeps), then add the smallest fix: a timeout on those calls with a clear error and a non-zero exit, so the lock is released. Decide whether a timed-out split or create may have opened a terminal and say what the coordinator must do (orca-dispatch.md step 3 already covers an unparsable reply)."
- S2 (Max, verbatim): "skills/odd-flow/references/orca-dispatch.md does not say that task-create needs an Orca Run: it failed with run_required until orchestration run-create ran (observed 2026-11-25). Document the step where it belongs."
- S3 (Max, verbatim): "From split-agent-mismatch (Engram #8439, topic odd-flow/split-agent-mismatch): the stale-width record (<TMPDIR>/odd-flow-pane-<parent>.cols) is still used when its mtime is in the future; and no test pins the exact 10-minute boundary. Fix the first with the smallest change and add both tests."
- S4 (Max, verbatim): "Constraint from Max: odd-flow must work for people without an Orca bot, and for Claude, Codex and Antigravity workers. Keep placement rules unchanged."
- S5 (Max, verbatim): "Keep CHANGELOG edits to your own bullets under [Unreleased]."
- S6 (Max, verbatim): "Risk: R4-001 changes launch behavior; get an independent verify before merge_ready."
- S8 (bot, verbatim, 2026-11-25): "On the count: orca-dispatch.md is in your surface, so you may reword that line to not depend on an exact hook count (for example \"N hooks are new or changed\"). Keep it to that line."
- S7 (assumption): the "both tests" of S3 are (a) a record with a future mtime is not reused and (b) a record just inside the 10-minute window is reused while one just outside it is not.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1, S4-S5 | Timeout on pane.py Orca calls, tests, orca-dispatch.md step 3 note, CHANGELOG bullet | orca:write (sequential: shares pane.py, tests, orca-dispatch.md) | done | task_b95f11f96715; RED 41/4 failed, GREEN 45/0 (spot check 45/0); commit c76b83f |
| T2 | S3, S5, S7 | Reject future-mtime width record; future-mtime and 10-minute boundary tests; CHANGELOG bullet | orca:write (after T1: same files) | done | task_eef87e03ee5a; RED 47/1 failed, GREEN 48/0 (spot check 48/0); commit b7c4c91 |
| T3 | S2, S4-S5, S8 | Document run-create before task-create in orca-dispatch.md; reword the hooks-count line (S8); CHANGELOG bullet | orca:write (after T2: same files) | done | task_80a3db4b36a4; docs only (exception: no RED); pane-check 48/0, full-delegation-check 100/0 (spot check); commit fdeeb19 |
| T4 | S6 | Independent verify of T1-T3 candidate | orca:verify (Verification trigger, item 4) | done | task_13e68df6de2c; S1-S8 met, no blockers; 1140-case placement differential identical except future-mtime; base b1c3bf0, candidate fdeeb19 |
| T4b | S1 | Verify follow-ups: add its lock-release regression test; say a timed-out split/create can open a pane late | orca:write (T1 correction, Codex pane closed: relaunch) | done | task_6c2a5974ecf5; new test RED on base pane.py, GREEN 49/0 (spot check 49/0, no leftover process); commit 6894094 |
| T5 | S6 | Review and refute after verify | orca:review, orca:refute (Review trigger) | done | range b1c3bf0..6894094; resilience: R4-001 WARNING; reliability: R3-001 WARNING, R3-002 SUGGESTION; no BLOCKER/CRITICAL, so no refute and no correction |

## Log

- L1 (Max via supervisor, 2026-11-25): "Goal (Max approved): close the open follow-ups on worker pane placement and dispatch. 1. R4-001 (high): skills/odd-flow/scripts/pane.py runs its Orca calls (terminal list, split, create) under the exclusive pane lock with no subprocess timeout; one hung call blocks every parallel launch. Reproduce (for example a fake orca that sleeps), then add the smallest fix: a timeout on those calls with a clear error and a non-zero exit, so the lock is released. Decide whether a timed-out split or create may have opened a terminal and say what the coordinator must do (orca-dispatch.md step 3 already covers an unparsable reply). 2. skills/odd-flow/references/orca-dispatch.md does not say that task-create needs an Orca Run: it failed with run_required until orchestration run-create ran (observed 2026-11-25). Document the step where it belongs. 3. From split-agent-mismatch (Engram #8439, topic odd-flow/split-agent-mismatch): the stale-width record (<TMPDIR>/odd-flow-pane-<parent>.cols) is still used when its mtime is in the future; and no test pins the exact 10-minute boundary. Fix the first with the smallest change and add both tests. Sources: odd/tasks/pane-placement-per-launch.md (Follow-ups section), Engram #8439, tests/pane-check.sh. Constraint from Max: odd-flow must work for people without an Orca bot, and for Claude, Codex and Antigravity workers. Keep placement rules unchanged. Expected surfaces (confirm and tell the bot the final list before writers start): skills/odd-flow/scripts/pane.py, tests/pane-check.sh, skills/odd-flow/references/orca-dispatch.md, odd/tasks/pane-placement-per-launch.md (mark follow-ups done), CHANGELOG.md. A parallel workstream (worker-token-hardening) edits orca-plugin/, scripts/prompt-submit.py, references/mode-full-delegation.md, tests/parent-guard-check.sh, tests/role-prompts-check.sh, README.md, odd/tasks/worker-marker-token.md and CHANGELOG.md. Keep CHANGELOG edits to your own bullets under [Unreleased]. Risk: R4-001 changes launch behavior; get an independent verify before merge_ready."
- 2026-11-25: classified large (supervisor waits, several deliverables, Risk item 4: the pane lock). Units run in order because they share files.
- 2026-11-25: Run run_9089488b4844. T1 split-right (222 cols). Codex showed "Hooks need review" with "3 hooks are new or changed"; bot: Max's standing answer is 2, he selects it himself. T1 started after tui-idle.
- 2026-11-25: T1 done: 30 s timeout in terminal(), no env var; dispatch step 3 covers a timed-out split/create. Commit approval asked (msg_1ec8f4bd336f); bot ended its turn without answering, so nothing is committed: T1 stays staged, unreferenced candidate efd3564c6afe11998c5cc37d633f6e0cae4fda0f. Ask again in merge_ready. T2 launched split-right (222 cols).
- 2026-11-25: Max (via bot): "1 Commit T1 now, T2 and T3 after spot check". T1 committed c76b83f fix: time out hung orca calls during pane placement.
- 2026-11-25: T2 done: recorded_width rejects age < 0; age exactly 600 s still reused, 600.001 s rejected (unchanged boundary). Committed b7c4c91 fix: ignore future-dated stale-width records.
- 2026-11-25: T3 launched split-right (222 cols), base b7c4c91. Baseline full-delegation-check 100/0.
- 2026-11-25: T3 done, committed fdeeb19 docs: create an orca run before task-create in the dispatch guide. Next: T4 verify on b1c3bf0..fdeeb19.
- 2026-11-25: T4 verify passed (report: scratch T4-verify-report.md). Advisories: a real split/create can finish after the timeout, so a pane may appear after the coordinator checked terminal list (S1 asks what the coordinator must do, so T4b documents it); pane-placement-per-launch.md follow-ups not marked (parent does it now). Verifier supplied a ready lock-release regression test (fails on base, passes on candidate); T4b adds it. Unverified: real Orca split/create timeout and run_required (need live mutating Orca calls).
- 2026-11-25: T4b done, committed 6894094 test: pin the pane lock release after a hung orca call. Review forecast (notice, item 4 high risk after passed verify): lenses resilience + reliability, roles review x2 then refute for blocking findings, at most one correction.
- 2026-11-25: T5 launched in parallel: resilience split-right, reliability split-below under it (parallel placement worked under the lock).
- 2026-11-25: T5 resilience: 1 WARNING R4-001 (inferential, introduced): a pane that Orca opens late after a split/create timeout has no identifier in the error and no bounded recheck; it already runs the worker command, so it can be left as an orphan agent with no Task. Not blocking (WARNING): follow-up. Report: scratch T5-review-resilience.json.
- 2026-11-25: T5 reliability: R3-001 WARNING (introduced): the lock-release test asserts only exit codes and the 4 s bound, so it also passes if the flock is removed or the second launch runs first; R3-002 SUGGESTION: no test covers the shipped 30 s default (all override it). Review done: no blocking finding.

## Follow-ups (out of scope)

- R4-001 (WARNING): after a split/create timeout, a pane Orca opens late runs the worker command with no Task, no title and no identifier in the error; the guide's recheck is bound to the next launch only.
- R3-001 (WARNING): make the lock-release test prove the second launch waited on the lock (for example by checking that its first Orca call comes after the first launch's timeout).
- R3-002 (SUGGESTION): no test pins the 30 s default.
- Unverified live: real Orca split/create timeout; run_required from task-create without a Run.
