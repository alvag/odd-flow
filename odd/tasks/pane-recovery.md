# Pane placement recovery and test gaps

Objective: implement GitHub issue alvag/odd-flow#24, "Pane placement: recovery and test gaps after the split retry and handle-diff changes". Branch: `fix/pane-recovery`. Delivery: `ask-on-risk`. Runner: `bash tests/pane-check.sh`.
Profile: `claude-gpt`.

## Specs

Issue #24 body, verbatim (`gh issue view 24 -R alvag/odd-flow`, 2026-11-26):

- S1 (issue, verbatim): "Follow-ups from the review of the pane placement follow-ups (#1). None blocked the merge."
- S2 (issue, verbatim, Resilience): "A failed `--retry-split` drops the first reply's leaf ID and Orca message (`skills/odd-flow/scripts/pane.py`, the split error path), so the coordinator is left with only a positional match, which can be ambiguous. Keep the leaf ID and the first message in the final error."
- S3 (issue, verbatim, Resilience): "The retry shares the 30 s client limit (`ORCA_TIMEOUT_SECS`), below Orca's own wait (about 10 s for the leaf plus 30 s for its PTY), so it cannot recover slow-PTY panes. The worst-case pane lock hold also grows from 60 s to 90 s. Decide the retry's limit and whether the lock hold is acceptable."
- S4 (issue, verbatim, Resilience): "Create recovery has no fallback when the baseline is unavailable, for example a terminal list truncated at Orca's default limit of 200; `pane.py` passes no `--limit`."
- S5 (issue, verbatim, Reliability, tests in `tests/pane-check.sh`): "Split-retry guards untested: a non-UUID or missing `splitId`, and a retry that returns a non-pending error. The verifier proposed fake cases for both."
- S6 (issue, verbatim, Reliability): "Baseline rejections untested: truncated list, non-list `terminals`, a row without a handle, a list timeout."
- S7 (issue, verbatim, Reliability): "The step-3 recovery rules in `references/orca-dispatch.md` are tested only through a test-local matcher; own-handle exclusion is tested only for create."
- S8 (issue, verbatim): "Still unverified live (needs real Orca timeouts): a late split recovered by `--retry-split`, a late create recovered by the handle diff, and `error.data` surviving a real host timeout."

Workstream brief (Max via supervisor, verbatim excerpts):

- S9 (Max, verbatim): "The second resilience item (the retry's time limit and the 60 s to 90 s worst-case lock hold) is a decision: investigate it, then send me a question with options (with their cost and risk) before a writer changes the limit."
- S10 (Max, verbatim): "Check Orca's behavior on the installed Orca (1.4.278): `orca terminal split --help`, `orca terminal list --help` (its --limit). If a point needs a live mutating Orca call to verify, list it as unverified rather than faking it."
- S11 (Max, verbatim): "This changes launch behavior under the pane lock (high-risk item: concurrency), so get an independent verify before merge_ready."
- S12 (Max, verbatim): "Expected surfaces: skills/odd-flow/scripts/pane.py, tests/pane-check.sh, CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>. skills/odd-flow/references/orca-dispatch.md belongs to rules-wording right now; ask me before changing its step 3."
- S13 (Max, verbatim): "Commit messages may reference the issue (\"Refs #24\"); code and comments must not mention issue numbers, specs or tasks. Do not push and do not touch the GitHub issue; I close it after the push."
- S14 (observed 2026-11-26, Orca 1.4.278, not a requirement): `orca terminal list --help` usage: `orca terminal list [--worktree <selector>] [--limit <n>] [--include-visual-layouts] [--json]`, "--limit <n>  Maximum number of rows to return". `orca terminal split --help` Notes: "A timeout does not mean the split failed: the pane may still open and run --command. Re-run the same command with --retry-split <leafId> from the error to wait for that pane instead of splitting again."
- S15 (constraint carried from odd/tasks/pane-followups.md S4, Max, verbatim): "Constraint from Max: odd-flow must work for people without an Orca bot, and for Claude, Codex and Antigravity workers. Keep placement rules unchanged."

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S5, S10, S13, S15 | Failed --retry-split keeps the first reply's leaf ID and Orca message in the final error; tests for split-retry guards (non-UUID or missing splitId, retry returning a non-pending error); CHANGELOG bullet | orca:write (Risk item 4: launch behavior under the pane lock) | done | b76e0eb; RED pane-check 67/1 (original reply context missing), GREEN 68/0; base 64/0 stdout unchanged for existing cases; parent spot check pane-check 68/0 |
| T2 | S3, S4, S7, S9, S10, S14 | Map the retry time limit and lock hold options (cost, risk), Orca --limit semantics and baseline fallback options, and options to close the step-3 test gap | orca:explore (Mapping trigger: Orca app.asar internals plus pane.py beyond the parent read budget) | done | msg_1dc645ce16a9 (corrected report, status message); options sent to supervisor msg_802c6dd73713 |
| T3 | S3, S9 | Change the retry limit as Max decides (question to supervisor first) | orca:write (after T2 and Max's decision; shares pane.py) | done | a11cbf5; Q1 B (L2); RED pane-check 72/1 (trace 30/30/30/30), GREEN 73/0; parent spot check 73/0; live slow-PTY recovery unverified | |
| T4 | S4, S6, S10, S15 | Create recovery fallback when the baseline is unavailable; tests for baseline rejections (truncated list, non-list terminals, row without handle, list timeout); CHANGELOG bullet | orca:write (after T1 and T2; shares pane.py, pane-check.sh) | done | 130cadb; RED pane-check 72/1 (missing limit), GREEN 73/0; parent spot check pane-check 73/0; live late create unverified | |
| T5 | S7, S12, S15 | Step-3 recovery rules tested beyond the test-local matcher; own-handle exclusion tested for split | orca:write (after T4; shares pane-check.sh; orca-dispatch.md step 3 only after asking) | done | 7087433; exception to RED (rule already holds): new case fails with the matcher's split exclusion disabled (73/1), passes restored (74/0); parent spot check 74/0 | |
| T6 | S11 | Independent verify of T1-T5 | orca:verify (Verification trigger: item 4) | pending | |

## Log

- L1 (Max via supervisor, 2026-11-26): workstream brief pasted at session start (goal: implement issue #24; notes on the retry-limit decision, Orca help checks, risk, surfaces, parallel workstreams, commit messages); S1-S13 quote it and the issue verbatim.
- 2026-11-26: classified large (supervisor waits, a pending decision, high-risk concurrency item, independent verify, per-unit commits). Base fda7253. Background: odd/tasks/pane-placement-followups.md. T1 and T2 launch together (T2 is read-only and reads the base commit).
- 2026-11-26: Run run_28bfc4d44844. T1 write (term_9d966285, split-right) and T2 explore (term_63c34c63, split-below) launched.
- 2026-11-26: T2 first worker_done (msg_acaa2b965e8d) had no options or evidence (npx asar failed on a root-owned npm cache). One correction sent: follow-up ctx_6904d8dec7f6 (task_97206dbd39c1), read app.asar directly, report via --body-file.
- 2026-11-26: T1 done (b76e0eb). Writer: split-handle validation moved into terminal() so a retry reply without a handle keeps the original context (pane.py:54-71). Live late split unverified.
- 2026-11-26: T2 done after one correction (report msg_1dc645ce16a9). Findings: client 30 s kill races Orca's 30 s host wait (waitForLeafInTab appearMs 10 s, startMs 30 s; CLI RPC timeout 60 s), so the first split may never see splitId; pane lock is flock LOCK_EX with no timeout (pane.py:207-209); split route under the lock is list + split + title, worst case 90 s, 120 s with a retry; terminal list defaults to 200, slices to --limit, no cap found. Question sent to the supervisor (msg_802c6dd73713): Q1 retry limit (recommend 40 s for both split calls), Q2 baseline (recommend explicit --limit 1000), Q3 step-3 tests (recommend split own-handle case only). T3-T5 wait for the reply.
- 2026-11-26: supervisor reply msg_dc5f16a2436e: "ODDFlow Bot ended its turn without answering your question, so do it yourself or tell your owner that ODDFlow Bot couldn't take it." Q1 (retry limit) is Max's decision per S9: T3 stays blocked, not defaulted. Q2 and Q3 are implementation choices inside the authorized issue scope: the coordinator takes the recommended options (Q2 A: explicit --limit 1000 on the create baseline, no-guess rule unchanged; Q3 A: split own-handle exclusion case in pane-check.sh, no orca-dispatch.md change) and reports them in merge_ready. Status sent to the supervisor.
- L2 (Max via supervisor, 2026-11-26, msg_85b1bdd90b59, verbatim): "vamos con tus recomendaciones" ("go with your recommendations"): Q1 B (both split calls 40 s, list and title stay 30 s, one fixed constant), Q2 A, Q3 A. T3 unblocked. Order: T4 (spec ready), then T3, then T5; all share pane.py or pane-check.sh.
- 2026-11-26: T4 write launched (task_d6646b6015b9, term_f058fae1-1eb8-4fcd-a6a2-3ae53b455600).
- 2026-11-26: T4 done (130cadb). T3 write launched next.
- 2026-11-26: T3 write launched (task_3c118c09a7e5, term_d978a4ef).
- 2026-11-26: T3 first report: split and retry 40 s (ORCA_SPLIT_TIMEOUT_SECS), others 30 s; RED 72/1, GREEN 73/0. Writer: title runs after unlock, so the lock hold is layout list 30 + split 40 + retry 40 = 110 s worst case (the Q1 estimate of 140 s counted the title). Correction sent (ctx_a0f7ed09e059): it had rewritten an existing CHANGELOG bullet from 855426d; restore it and add its own bullet.
- 2026-11-26: T3 done (a11cbf5) after one CHANGELOG correction. T5 write launched next.
- 2026-11-26: T5 done (7087433). T6 verify launched on fda7253..HEAD.
