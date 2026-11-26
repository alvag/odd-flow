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
| T1 | S1, S2, S6, S10, S11 | pane.py errors carry placement context (parse failure, missing handle, Orca-reported split timeout); Orca-reported split timeout waits for the late pane via --retry-split; dispatch step 3 and CHANGELOG updated | orca:write (Risk item 4: launch behavior under the pane lock) | in_progress | task_40eb2dca21d8, dispatch ctx_0c442e359b4f |
| T2 | S3, S4, S11 | create-timeout recovery by terminal-handle diff, not tab title; tests for step-3 exclusion of own handles and no/multiple-match reporting; test matcher cannot pick a foreign sibling; dispatch step 3 and CHANGELOG updated | orca:write (after T1: shares pane.py, pane-check.sh, orca-dispatch.md) | pending | |
| T3 | S7 | Independent verify of T1-T2 | orca:verify (Verification trigger: item 4) | pending | |

## Log

- L1 (Max via supervisor, 2026-11-26): workstream brief pasted at session start (goal: implement issue #1; notes on --retry-split, risk, surfaces, parallel workstreams, commit messages); S1-S9 quote it and the issue verbatim.
- 2026-11-26: classified large (supervisor waits, high-risk concurrency item, independent verify, per-unit commits). T1 and T2 share every surface, so they run in order. Base e844437.
