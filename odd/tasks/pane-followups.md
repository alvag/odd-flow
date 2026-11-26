# Pane follow-ups

Objective: close the follow-ups left by pane-dispatch-hardening (odd/tasks/pane-dispatch-hardening.md, Follow-ups section). Branch: `fix/pane-followups`. Delivery: `ask-on-risk`. Runner: `bash tests/pane-check.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (Max, verbatim): "R4-001: after a split or create timeout, Orca can still open the pane late; it already runs the worker command, has no title, and the timeout error does not identify it, so it can be left running with no Task. Find the smallest change that lets the coordinator find and close that pane (for example, the error names the target and the intended title, or the pane gets identified before the call), and update orca-dispatch.md step 3 to match. Reproduce first with a fake orca."
- S2 (Max, verbatim): "R3-002: no test pins the 30-second default timeout. Add one."
- S3 (Max, verbatim): "tests/pane-check.sh leaves its scratch in /var/folders because macOS mktemp -d ignores TMPDIR; make the test clean up its own scratch (and create it where it means to)."
- S4 (Max, verbatim): "Constraint from Max: odd-flow must work for people without an Orca bot, and for Claude, Codex and Antigravity workers. Keep placement rules unchanged."
- S5 (Max, verbatim): "Expected surfaces (confirm and tell the bot the final list before writers start): skills/odd-flow/scripts/pane.py, tests/pane-check.sh, skills/odd-flow/references/orca-dispatch.md, odd/tasks/pane-dispatch-hardening.md, CHANGELOG.md. Parallel workstreams: test-infra-followups (tests/codex-plugin-check.sh, tests/parent-guard-check.sh, tests/orca-plugin-docs-check.sh, orca-plugin test tooling, README.md, CHANGELOG.md) and orca-orchestration-spike (odd/tasks only). Keep CHANGELOG edits to your own bullets under [Unreleased]."
- S6 (Max, verbatim): "Risk: item 1 changes launch behavior; get an independent verify before merge_ready."
- S7 (Max, verbatim): "Commits: Max approves commits per unit; ask the bot before the first commit (offer \"commit each unit after its spot check\" as an option)."
- S8 (observed, not a requirement): `orca terminal split --help` says: "A timeout does not mean the split failed: the pane may still open and run --command. Re-run the same command with --retry-split <leafId> from the error to wait for that pane instead of splitting again."
- S9 (Max via bot, 2026-11-25, verbatim): "1 Commit each unit after its spot check". This is now his default for every workstream.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1, S4, S5, S8 | Late pane after split/create timeout can be found and closed; dispatch step 3 updated; CHANGELOG bullet | orca:write (Risk item 4/6: launch behavior under the pane lock) | done | 0f2468a; RED pane-check 49/2, GREEN 51/0; parent spot check pane-check 51/0 |
| T2 | S2 | Test pins the 30 s default timeout | orca:write (after T1: shares tests/pane-check.sh) | done | b6b612d; RED (31 s default in a base copy) 51/1, GREEN 52/0; parent spot check pane-check 52/0 |
| T3 | S3 | pane-check.sh creates scratch under its intended dir and removes it | orca:write (after T2: shares tests/pane-check.sh) | done | 63e44c2; repro: base leaked scratch outside TMPDIR on pass and fail runs, fix removes it; parent spot check pane-check 52/0, exit 0, printed scratch dir gone |
| T4 | S6 | Independent verify of T1-T3 | orca:verify (Verification trigger) | done | passed, no blockers (report /private/tmp/claude-501/-Users-max-orca-workspaces-odd-flow-pane-followups/686e8bf1-ed9f-4614-a5f2-ce3ef29b3685/scratchpad/verify.u4djeU/report.md) |
| T4b | S1 | Verify advisories: step-3 matching test on visualLayouts, restore split-right timeout assertion, doc: exclude own handles / report ambiguity | orca:write (verify advisories inside S1) | done | 0381df5; RED 53/3, GREEN 56/0; parent spot check pane-check 56/0 |
| T5 | S6 | Review: resilience + reliability lenses on 5506569..0381df5 | orca:review x2 (Review trigger: verify passed on item 4) | done | no blocking finding: resilience 2 WARNING (pre-existing) + 1 SUGGESTION; reliability 2 WARNING + 2 SUGGESTION (introduced, not blocking) |
| T6 | S1-S3 | Mark follow-ups done in pane-dispatch-hardening.md | parent (odd/tasks) | done | follow-ups marked |

## Log

- L1 (Max, 2026-11-25): workstream brief pasted at session start (Goal, items 1-3, constraint, expected surfaces, risk, commits); S1-S7 quote it verbatim.
- 2026-11-25: classified large (supervisor waits, several deliverables, per-unit commits, launch behavior under the pane lock). Units share tests/pane-check.sh, so they run in order. Base 87cbbcb.
- 2026-11-25: Final surfaces and commit question sent to the bot (msg_fa525e2df414). Bot status msg_816bf8585d3f: it ended its turn without answering. Not resent; question still open. No commit until Max answers.
- 2026-11-25: Run run_d55b8d726a9b. T1 placed split-right (222 cols) term_0d108922-0b9c-4bba-8d79-8c5b46e7d415, tui-idle ok, started dispatch ctx_9342354b2c9c.
- 2026-11-25: Bot answer msg_1478581537df to msg_fa525e2df414: option 1 (S9). The parent commits each unit after its spot check.
- 2026-11-25: T1 done (report /tmp/odd-flow-T1-pane-followups.iC0foZ): timeout errors name split target, direction and intended title, or create worktree and title; dispatch step 3 matches via terminal list --include-visual-layouts and closes only an identified terminal. No --retry-split, no assumption about Orca's timeout payload. Spot check pane-check 51/0; surface matches. Committed 0f2468a. Worker released (external_terminal) and pane closed. Writer scratch left in /var/folders (T3 addresses the cause) and /tmp/pane-followups-orca-cli.json; parent removes at close. T2 next, base 0f2468a.
- 2026-11-25: T2 done (worker_done msg_5d0464a75e21; summary only, no report file): the sampler traces subprocess.run's timeout kwarg; the test expects 30 s on both calls of a tab placement. Spot check pane-check 52/0; surface matches. Committed b6b612d. Released and pane closed. T3 next.
- 2026-11-25: T3 done (report /tmp/pane-s3.MGgXjaih/report.txt): explicit mktemp template under ${TMPDIR:-/tmp} plus EXIT trap. Other tests/*.sh with the same pattern listed in the report (test-infra-followups owns them; tell the bot in merge_ready). Committed 63e44c2. Released and pane closed. T4 verify next on 87cbbcb..63e44c2.
- 2026-11-25: T4 verify launched (task_a08a828fc766, dispatch ctx_11d1d3a44424, split-right). Bot status msg_29b8afd070b8: main moved to 5506569 (test-infra-followups merged; only CHANGELOG.md overlaps). Rebase onto 5506569 keeping all bullets before merge_ready; rebase waits until T4 reports so the verifier's tree does not move.
- 2026-11-25: T4 verify passed S1-S4, no blockers (msg_51d5267bc5af). Advisories: (a) the late-pane tests never run the step-3 matching against visualLayouts; (b) the split-right timeout text is no longer asserted (T1 replaced it with split-below); (c) a foreign pane split from the same target later is also "next to the reported target": step 3 should exclude handles from earlier placements and report when more than one unknown pane qualifies; (d) live tab titles equal their first terminal's running title, so create matching by tab title may miss and then reports (fails safe); (e) --retry-split unusable because pane.py kills the CLI first; (f) pre-existing full-delegation-check scratch leak (other owner). Unverified: real Orca late open, create tab title persistence. Worker released, pane closed.
- 2026-11-25: Rebased onto 5506569 (pre-rebase HEAD 63e44c2) with union merge for CHANGELOG.md (core.attributesFile in scratch). New commits 5ad69af (T1), 39d9fae (T2), e5b9878 (T3). One [Unreleased] Fixed section; all bullets kept. Every tests/*.sh exits 0 (23 scripts, including orca-plugin-typecheck.sh, which installs packages into a temp prefix); git diff --check 5506569..HEAD clean.
- 2026-11-25: T4b launched for advisories a-c (d noted in the doc as fail-safe if the writer finds it fits; e, f out of scope), base e5b9878.
- 2026-11-25: T4b done (report /tmp/pane-t4b-report.3oGDHq0f2W): expect_late drives step-3 matching on visualLayouts for split-right, split-below and create; split-right timeout text asserted again; step 3 excludes own earlier handles and reports no or multiple matches. pane.py unchanged. Committed 0381df5. Released, pane closed. Review forecast (notice; item 4 high risk after passed verify): lenses resilience + reliability, roles review x2 then refute for blocking findings, at most one correction.
- 2026-11-25: T5 resilience (report /private/tmp/claude-501/-Users-max-orca-workspaces-odd-flow-pane-followups/62d56bcf-f932-4f09-99b1-cc0bac7dd40c/scratchpad/review-resilience.json): no blockers. R4-001 WARNING pre-existing: placement context only on subprocess timeout; parse-failure and missing-handle errors carry no target/title, though step 3 sends the coordinator to check there too. R4-002 WARNING pre-existing, inferential: an Orca-reported split timeout (S8) goes through the ok:false branch with no hint or context; --retry-split not mentioned. R4-003 SUGGESTION introduced: create recovery keys on a tab title that may follow the running title; fails safe; a handle-set diff would be title-independent. All follow-ups (not blocking). Released, pane closed. Waiting for reliability.
- 2026-11-25: T5 reliability (report /private/tmp/claude-501/-Users-max-orca-workspaces-odd-flow-pane-followups/da0c6343-4897-4978-b77e-444dda53381d/scratchpad/review-reliability.json): no blockers. R3-001 WARNING: the step-3 exclusion and ambiguity rules have no test; the test matcher would pick a foreign sibling (target re-split after the late pane) as a unique match. R3-002 WARNING: the JSON-quoted title is untested (fixed plain title; the test regex does not JSON-decode). R3-003 SUGGESTION: the 30 s pin is tied to subprocess.run's timeout kwarg. R3-004 SUGGESTION: no guide grep pins the step-3 text. Review done: no blocking finding, so no refute or correction. Released, pane closed. T6 done (parent). Leftover writer and test scratch in /var/folders removed (14 dirs, inspected first).

## Follow-ups (out of scope)

- R4-001 (resilience WARNING, pre-existing): parse-failure and missing-handle errors carry no placement context.
- R4-002 (resilience WARNING, inferential): an Orca-reported split timeout gets no hint or context; --retry-split unused.
- R4-003 (resilience SUGGESTION): create recovery keys on a tab title that may follow the running title; a handle-set diff would be title-independent.
- R3-001 (reliability WARNING): no test for the exclusion and ambiguity rules; the test matcher picks a foreign sibling.
- R3-002 (reliability WARNING): JSON-quoted title untested.
- R3-003, R3-004 (reliability SUGGESTION): the 30 s pin is coupled to the subprocess.run kwarg; no guide grep for step 3.
- Other tests/*.sh create scratch with bare mktemp -d and several never remove it (list in /tmp/pane-s3.MGgXjaih/report.txt); owned by test-infra-followups.
- Unverified live: real Orca late open after a timeout; created tab title persistence.
