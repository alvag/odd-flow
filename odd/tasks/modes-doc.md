# Organic and full-delegation modes comparison

Objective: add a verified side-by-side comparison of the two orchestrator modes to the README (issue alvag/odd-flow#16). Branch: `docs/modes-doc`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh`.
Profile: `claude-gpt` (full-delegation).

## Specs

- S1 (Max, verbatim): see L1. Check every draft row against mode-organic.md, mode-full-delegation.md, delegation.md and odd-protocol.md on main; fix unsupported rows; cite rules here, not in the README.
- S2 (issue #16, verbatim): see L2.
- S3 (parent, derived from S1-S2): the README gets the verified table below, verbatim, followed by the summary line. Rule citations are under "Row evidence".
- S4 (parent, assumption): place it as a new section `## Organic and full delegation compared` directly after the README's intro paragraph (the only mode description) and before `## Contents`. One lead sentence, the table, then the summary line. The README layout does not need a linked doc.
- S5 (parent, derived from S1 "pinning a few table rows"): extend the existing `tests/mode-check.sh` with four pins. Each pin checks that the README row text and the source rule text are both present, so a change to either side fails:
  1. Write code: README `| Write code | Writes it itself by default. | Never; every change goes to a bounded writer`; mode-organic.md `Work inline by default.`; mode-full-delegation.md `never edit a file yourself`.
  2. Writer context threshold: README `the lower of 150k tokens and 15% of the window`; mode-organic.md `min(150000, max(1, floor(0.15 × window)))`.
  3. Review corrections: README `| Review corrections | Inline or with one writer. | Always one writer, with the corrected findings as its spec and the candidate's paths as its surface. |`; mode-organic.md ``Write it inline or with one `write` worker.``; mode-full-delegation.md `with the corrected findings as its spec and the candidate's paths as its surface`.
  4. Without Orca: README `runs each role inline, one unit at a time` and `reports the blocker for each pending writer unit and stops it`; mode-organic.md `the parent runs the role itself, one unit at a time`; mode-full-delegation.md `report the blocker for each pending unit and stop it`.
  Pins avoid delegation.md, which another workstream is editing.
- S6 (Max, verbatim): "CHANGELOG.md (own bullet under [Unreleased] only)". One bullet under `## [Unreleased]` `### Added` naming the README comparison and the mode-check pins.
- S7 (existing constraint): README.md and CHANGELOG.md must not contain tokens matching `[TSL][0-9]+` (tests/orca-plugin-docs-check.sh:50); no issue, task or spec identifiers in README, CHANGELOG or the test.

### Verified table (S3)

| Moment | Organic: the coordinator... | Full delegation: the coordinator... |
|---|---|---|
| Authorize and understand | Keeps investigation, review and planning requests read-only until a change is asked; reads in one batch of up to 3 calls (~10k tokens), and beyond that, or past ~5 sequential lookups, launches `explore`. | Same; also leaves reading that prepares a writer to that writer's spec. |
| Classify (small or large) | Small: works inline, no feature document. Large: creates the feature document before the first write or writer launch. | Size decides tracking and risk only: a small task still goes to a writer (no feature document); a large task gets the document before the first writer. |
| Write code | Writes it itself by default. | Never; every change goes to a bounded writer with allowed edit surfaces, or the blocker is reported. |
| When a writer launches | Only on a trigger: 2+ independent units with disjoint edit surfaces, each several minutes of work (several files or ~100+ changed lines), launched together; or `context.py` reports that the context reached its threshold (the lower of 150k tokens and 15% of the window). Never for size, file count, a large task alone or price. | Always: one writer per unit of behavior, never while a unit it depends on still runs; independent units with disjoint surfaces together, units sharing a file one at a time. |
| What it may write | Any workspace file; outside the workspace only after the user names the file and confirms the exact diff. | Only scratch outside the workspace, `odd/tasks/*.md`, Engram, Git operations, and files written by `profile.py` or `init.py` after the user confirms; outside the workspace, the same named-file rule. In Claude Code, Codex and Antigravity, the parent edit guard denies its other direct workspace edits (not shell writes). |
| A writer returns | Re-runs one reported command (spot check) and checks the changed files against the edit surface. | Same. |
| The user names another agent | Launches the role that matches the request ("have Codex check this"). | Same. |
| Independent verification (`verify`) | When the change's Risk line names a high-risk item. | Same. |
| Review (`review`, `refute`) | When the user asks (ordinary or dual), or verification passed on a high-risk change. | Same. |
| Review corrections | Inline or with one writer. | Always one writer, with the corrected findings as its spec and the candidate's paths as its surface. |
| A worker exhausts its bound | Names the cause; fixes inline when small and understood, otherwise relaunches once with the diagnosis and a new hypothesis. A repeated cause blocks the unit. | Launches one new writer with the diagnosis, the new evidence and a changed hypothesis or scope; never edits. A repeated cause blocks the unit. |
| Without Orca | Subagents; with no subagent, runs each role inline, one unit at a time. | Subagents; with no subagent, reports the blocker for each pending writer unit and stops it. |
| Verify or review with no worker possible | Runs it itself and says in the close it was not independent. | Same (they only read). |
| Commits, tracking, close | Commits large-task units (a small task only when asked), keeps the feature document and its Engram mirror, closes with outcome, failed or pending checks and next step. Routes: `inline`, `orca:<role>`, `subagent:<role>`. | Same; routes: `orca:<role>`, `subagent:<role>`, `blocked`. |

Summary line (from the issue, kept): "The modes differ only in who writes and what follows from it; exploring, verifying, reviewing, the spot check and the close follow the same rules."

### Row evidence

| Row | Draft change | Rule |
|---|---|---|
| Authorize and understand | Added read-only authorization, "one batch" and the ~5 sequential lookups bound. | odd-protocol.md §1 Authorize ("Investigation, explanation, review, audit, comparison and proposal requests are read-only"); §2 Explore ("Parent read budget: one parallel batch, at most 3 calls, about 10k tokens. Beyond that, the mapping trigger holds"); delegation.md Mapping row ("more than ~5 sequential lookups"); mode-full-delegation.md Who writes ("Reading that prepares a writer belongs in that writer's spec, not in your context."). |
| Classify | Full: "tracking only" → "tracking and risk only"; organic: document before the first write or writer launch. | mode-full-delegation.md Who writes ("Task size decides tracking and risk only, never who writes. A small task gets a writer and no feature document; a large task also gets the feature document before the first writer launches."); mode-organic.md ("Small path: inline; no workers."); odd-protocol.md §4 Small path ("no feature document"), §5 Track; tracking.md ("before the first source write or writer launch"). |
| Write code | Unchanged. | mode-organic.md ("Work inline by default."); mode-full-delegation.md ("You are a coordinator: you never implement."; "If no writer can run, report that blocker; never edit a file yourself."; "Every launch carries `## Allowed edit surfaces`."). |
| When a writer launches | Added "disjoint edit surfaces", "a large task alone", the 150k fallback wording, and "never while a unit it depends on still runs". | mode-organic.md Writer triggers table (Writer: parallel, Writer: context), Measuring context ("`min(150000, max(1, floor(0.15 × window)))` tokens"), Who writes ("Never delegate for size, file count, a large task alone, or price."); mode-full-delegation.md Who writes ("One writer per unit of behavior ..., never launched while a unit it depends on still runs"; "Independent units with disjoint surfaces launch together in one turn; units that need the same file run one at a time."). |
| What it may write | Added the named-file rule in full delegation and scoped the guard to Claude Code, Codex and Antigravity direct edits (not shell). | mode-organic.md Who writes (outside-workspace rule); delegation.md Files outside the workspace ("In both modes, only the parent may write a file outside the workspace"); mode-full-delegation.md Who writes (closed list) and Parent edit guard ("The guard does not cover writes through `Bash`"; Codex `apply_patch`; Antigravity file-edit tools). |
| A writer returns | "checks the edit surface" → "checks the changed files against the edit surface". | delegation.md Correction bounds ("Spot check: re-run one command a worker reported before accepting its result."), Allowed edit surfaces ("After each writer returns, compare `git diff --name-only` ... against its surface"); mode-full-delegation.md Writer spec ("re-run one reported command as a spot check and check the surface"). The worker-rules workstream is changing the spot check target. |
| The user names another agent | New row: the draft omitted the fourth shared trigger. | delegation.md Named agent row ("The user explicitly asks for another agent ("have Codex check this")"; "The triggers below hold in both modes."). |
| Independent verification | "the change names" → "the change's Risk line names". | delegation.md Verification row. |
| Review | Unchanged. | delegation.md Review row. |
| Review corrections | Full: added "the candidate's paths as its surface". | mode-organic.md Review correction ("Write it inline or with one `write` worker."); mode-full-delegation.md Review correction ("One `write` worker writes it, with the corrected findings as its spec and the candidate's paths as its surface."). |
| A worker exhausts its bound | Added "Names the cause", "the new evidence ... or scope" and "A repeated cause blocks the unit" in both. | mode-organic.md and mode-full-delegation.md After a worker exhausts its bound; delegation.md Correction bounds ("A worker that exhausts its bound ends its cycle, not the unit."). |
| Without Orca | Organic: "does everything inline" → "runs each role inline, one unit at a time"; full: "stops that unit" → "for each pending writer unit and stops it". | orca-dispatch.md Without Orca step 1 (subagent); mode-organic.md Without Orca ("the parent runs the role itself, one unit at a time"); mode-full-delegation.md Without Orca ("report the blocker for each pending unit and stop it; never edit a file yourself"). |
| Verify or review with no worker possible | Unchanged. | mode-organic.md Without Orca ("A `verify`, `review` or `refute` run inline is not independent; say so in the close."); mode-full-delegation.md Without Orca ("you run it yourself, since it only reads, and say in the close that it was not independent"). |
| Commits, tracking, close | Added "a small task only when asked", the Engram mirror and the per-mode routes. | odd-protocol.md §4 Small path ("no commits unless asked"), §7 Close; tracking.md Commits and Engram mirror; SKILL.md hard rule 6 ("The parent owns git, commits and scratch cleanup."); mode-organic.md and mode-full-delegation.md Feature-document routes. The worker-rules workstream is changing the close (residual risks). |

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S3-S7 | README section, mode-check pins, CHANGELOG bullet | orca:write (full delegation: every workspace change) | done | RED/GREEN `bash tests/mode-check.sh` 37 → 41 passed (writer); spot check 41 passed, 0 failed; `bash tests/run.sh` 22 passed, 0 failed (parent) |

## Log

- L1 (Max via supervisor, 2026-11-26): "Workstream: modes-doc (branch docs/modes-doc). Max approved it.

Goal: implement GitHub issue alvag/odd-flow#16, "Document a comparison of organic and full-delegation modes". Read it first: `gh issue view 16 -R alvag/odd-flow` and quote it verbatim into your feature document. The issue has a draft table; check every row against the current skills/odd-flow/references/mode-organic.md, mode-full-delegation.md, delegation.md and odd-protocol.md on main, and fix any row the rules do not support. Cite the rule for each row in your feature document, not in the README.

Notes:
- Place it in README.md (a short section near the mode descriptions) unless the README layout makes a linked doc clearly better; if you choose a doc, send me the option first.
- Consider pinning a few table rows in an existing docs check test, so the table cannot drift silently from the mode files; keep it small.
- Another workstream (worker-rules) is changing references/delegation.md, core-block.md and roles/write.md right now (spot check target, residual risks at close, writer report cap). Describe today's rules; when main moves I will tell you what changed so you can update the rows before merge.
- Expected surfaces: README.md, one existing docs check test if you pin rows, CHANGELOG.md (own bullet under [Unreleased] only), odd/tasks/<your feature doc>."
- L2 (issue alvag/odd-flow#16, 2026-11-26, verbatim):

  > The README explains each mode separately, but there is no side-by-side view of what the coordinator does in organic mode versus full delegation. Users ask, for example, whether organic mode still delegates reviews (it does: the verification, review, mapping and named-agent triggers in `references/delegation.md` hold in both modes).
  >
  > Add a short comparison table to the README (or to a doc linked from it), derived from `references/mode-organic.md`, `references/mode-full-delegation.md`, `references/delegation.md` and `references/odd-protocol.md`. Draft:
  >
  > | Moment | Organic: the coordinator... | Full delegation: the coordinator... |
  > |---|---|---|
  > | Authorize and understand | Reads up to 3 calls (~10k tokens); beyond that launches `explore`. | Same; also leaves reading that prepares a writer to that writer's spec. |
  > | Classify (small or large) | Small: works inline, no feature document. Large: creates the feature document. | Size decides tracking only: small still goes to a writer (no feature document); large gets the document before the first writer. |
  > | Write code | Writes it itself by default. | Never; every change goes to a bounded writer with allowed edit surfaces, or the blocker is reported. |
  > | When a writer launches | Only on a trigger: 2+ independent units of several minutes each (several files or ~100+ changed lines) in parallel, or its context passes the `context.py` threshold (lower of 150k tokens or 15% of the window). Never for size, file count or price alone. | Always: one writer per unit of behavior; independent units together, units sharing a file one at a time. |
  > | What it may write | Any workspace file; outside the workspace only after the user names the file and confirms the exact diff. | Only scratch outside the workspace, `odd/tasks/*.md`, Engram, Git operations, and files written by `profile.py` or `init.py` after the user confirms; the parent edit guard denies other edits. |
  > | A writer returns | Re-runs one reported command (spot check) and checks the edit surface. | Same. |
  > | Independent verification (`verify`) | When the change names a high-risk item. | Same. |
  > | Review (`review`, `refute`) | When the user asks (ordinary or dual), or verification passed on a high-risk change. | Same. |
  > | Review corrections | Inline or with one writer. | Always one writer, with the corrected findings as its spec. |
  > | A worker exhausts its bound | Fixes inline when small and understood; otherwise relaunches once with the diagnosis. | Launches one new writer with the diagnosis and a changed hypothesis; never edits. |
  > | Without Orca | Subagents; with no subagent, does everything inline. | Subagents; with no subagent, reports the blocker and stops that unit. |
  > | Verify or review with no worker possible | Runs it itself and says in the close it was not independent. | Same (they only read). |
  > | Commits, tracking, close | Commits, keeps the feature document and Engram, closes with outcome, failed or pending checks and next step. | Same. |
  >
  > Summary line for the README: the modes differ only in who writes and what follows from it; exploring, verifying, reviewing, the spot check and the close follow the same rules.
  >
  > Keep the table in sync with the mode files; consider pinning a few rows in a docs check test if the table is added.

- L3 (2026-11-26): Baseline on `e844437`: `bash tests/run.sh` → "Summary: 22 passed, 0 failed". Draft rows checked; changes and rules in Row evidence. Placement: README section (S4), no linked doc.
- L4 (2026-11-26): T1 writer (orca:write, codex / gpt-6.2-sol / medium) changed README.md, CHANGELOG.md, tests/mode-check.sh, all inside its surface. Its `bash tests/run.sh` reported parent-guard-check.sh failing two setgid worker-token cases inside the Codex sandbox; the parent's rerun outside the sandbox passed all 22 suites. README table matches S3 byte for byte. Next: commit, merge_ready; update the spot check and close rows if worker-rules changes them on main.
