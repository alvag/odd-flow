# Pane placement follow-ups

Objective: implement GitHub issue alvag/odd-flow#1, "Pane placement: error context and late-pane recovery follow-ups". Branch: `fix/pane-placement-followups`. Delivery: `ask-on-risk`. Runner: `bash tests/pane-check.sh`.
Profile: `claude-gpt`.

## Specs

Issue #1 body, verbatim:

- S1 (issue, verbatim): "**R4-001** (resilience, pre-existing): `pane.py` parse-failure and missing-handle errors carry no placement context (target, direction, intended title), unlike timeout errors."
- S2 (issue, verbatim): "**R4-002** (resilience, inferential): a split timeout that Orca itself reports gets no hint or context, and Orca's `--retry-split <leafId>` (from `orca terminal split --help`) is not used to wait for the pane that may still open."
- S3 (issue, verbatim): "**R4-003** (resilience, suggestion): late-pane recovery after a `create` timeout matches on the tab title, which may follow the running title; a diff of terminal handles before and after would not depend on the title."
- S4 (issue, verbatim): "**R3-001** (reliability): no test covers the dispatch step-3 rules that exclude the coordinator's own earlier handles and report no or multiple matches; the test matcher can pick a foreign sibling pane."
- S5 (issue, verbatim): "Runner: `bash tests/pane-check.sh`."

Workstream brief (Max via supervisor, verbatim excerpts):

- S6 (Max, verbatim): "R4-002 mentions Orca's `--retry-split <leafId>`; check `orca terminal split --help` on the installed Orca (1.4.278) before relying on it. If it needs a live mutating Orca call to verify, list it as unverified rather than faking it."
- S7 (Max, verbatim): "This changes launch behavior under the pane lock (high-risk item: concurrency), so get an independent verify before merge_ready."
- S8 (Max, verbatim): "Expected surfaces: skills/odd-flow/scripts/pane.py, tests/pane-check.sh, skills/odd-flow/references/orca-dispatch.md, CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>."
- S9 (Max, verbatim): "Commit messages may reference the issue (\"Refs #1\"); code and comments must not mention issue numbers, specs or tasks."
- S10 (observed 2026-11-26, Orca 1.4.278, `orca terminal split --help`, not a requirement): usage lists `[--retry-split <leafId>]`; Notes: "A timeout does not mean the split failed: the pane may still open and run --command. Re-run the same command with --retry-split <leafId> from the error to wait for that pane instead of splitting again."
- S11 (constraint carried from odd/tasks/pane-followups.md S4, Max, verbatim): "Constraint from Max: odd-flow must work for people without an Orca bot, and for Claude, Codex and Antigravity workers. Keep placement rules unchanged."

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1, S2, S6, S10, S11 | pane.py errors carry placement context (parse failure, missing handle, Orca-reported split timeout); Orca-reported split timeout waits for the late pane via --retry-split; dispatch step 3 and CHANGELOG updated | orca:write (Risk item 4: launch behavior under the pane lock) | done | b0871aa; RED pane-check 53/6, GREEN 59/0; parent spot check pane-check 59/0; leaf ID source: installed Orca 1.4.278 app.asar (error.data.splitId, splitMayStillComplete); live late split unverified |
| T2 | S3, S4, S11 | create-timeout recovery by terminal-handle diff, not tab title; tests for step-3 exclusion of own handles and no/multiple-match reporting; test matcher cannot pick a foreign sibling; dispatch step 3 and CHANGELOG updated | orca:write (after T1: shares pane.py, pane-check.sh, orca-dispatch.md) | done | ebd32d3; RED pane-check 42/22 (old matcher picked term_foreign; no baseline in create errors), GREEN 64/0; parent spot check pane-check 64/0; live late create unverified |
| T3 | S7 | Independent verify of T1-T2 | orca:verify (Verification trigger: item 4) | done | passed, no blockers; S1-S4, S11 met; live --retry-split and late create unverified (report /private/tmp/claude-501/-Users-max-orca-workspaces-odd-flow-pane-placement-followups/27f405e7-c924-4837-bb78-d4de01e65eb1/scratchpad/verify.QFOr1z/report.md) |
| T4 | S7 | Review: resilience + reliability lenses on c931827..c5e5155 | orca:review x2 (Review trigger: verify passed on item 4) | done | no blocking finding: resilience 1 WARNING + 2 SUGGESTION, reliability 2 WARNING + 1 SUGGESTION (all introduced, non-blocking; no refute or correction) |

## Log

- L1 (Max via supervisor, 2026-11-26): workstream brief pasted at session start (goal: implement issue #1; notes on --retry-split, risk, surfaces, parallel workstreams, commit messages); S1-S9 quote it and the issue verbatim.
- 2026-11-26: classified large (supervisor waits, high-risk concurrency item, independent verify, per-unit commits). T1 and T2 share every surface, so they run in order. Base e844437.
- 2026-11-26: T1 done (b0871aa). Writer report: Orca 1.4.278 reports a pending split as ok:false, error.code runtime_error, error.data {splitId, tabId, splitMayStillComplete: true, nextSteps} (app.asar out/main/index.js; app.asar.unpacked out/cli/output/cli-error.js:119-128,149-164). No live split, create or close was run. T2 next.
- 2026-11-26: T2 done (ebd32d3). T3 verify launched on e844437..ebd32d3.
- 2026-11-26: T3 verify passed, no blockers. Advisories: narrow retry window (Orca waitForLeafInTab appearMs 10 s / startMs 30 s vs pane.py 30 s kill), worst-case lock hold 90 s, step-3 guide rules tested only via the test-local matcher, own-handle exclusion tested on create only. Supervisor: main moved to c931827, rebase before merge_ready.
- 2026-11-26: rebased onto main c931827 (clean): 229bf0f (T1), fcbbee2 (T2), c5e5155 (doc). pane-check 64/0 after rebase. T4 review launched.
- 2026-11-26: T4 review done, no BLOCKER/CRITICAL, so no refute and no correction (review.md). Follow-ups:
  - R4-001 (resilience WARNING): a failed --retry-split drops the first reply's leaf ID and Orca message (pane.py:57), leaving only a positional match that can be ambiguous.
  - R4-002 (resilience SUGGESTION, inferential): the retry shares the 30 s client limit, below Orca's own wait (appearMs 10 s + startMs 30 s), so it cannot recover slow-PTY panes.
  - R4-003 (resilience SUGGESTION): create recovery has no fallback when the baseline is unavailable, e.g. a list truncated at the host default of 200 terminals; pane.py passes no --limit.
  - R3-001 (reliability WARNING): split-retry guards untested (non-UUID or missing splitId; retry returning a non-pending error); verifier proposed badid/norecord fake cases.
  - R3-002 (reliability WARNING): baseline rejections untested (truncated list, non-list terminals, row without handle, list timeout).
  - R3-003 (reliability SUGGESTION): step-3 rules tested only through a test-local matcher; own-handle exclusion only on create; matcher truncated branch unreached.
  - Unverified live: --retry-split late split, late create recovery by handle diff, error.data surviving a real host timeout.
