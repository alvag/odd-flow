# Worker rules: spot check, residual risks, writer report cap, explore handoff

Objective: tighten how the coordinator accepts and reports worker results (targeted spot check, residual risks at close, writer report size cap) and investigate how explore findings reach the writer. Branch: `feat/worker-rules`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim, issue "Verification evidence: targeted spot check and residual risks at close", body):
  > Two small gaps in how the coordinator accepts and reports work (from a review of odd-flow's verification rules).
  >
  > - [ ] **Spot check picks the command that proves the result.** `skills/odd-flow/references/delegation.md` says: "Spot check: re-run one command a worker reported before accepting its result." Any reported command qualifies, including the cheapest one (for example a lint). Require the coordinator to re-run the command that proves the main acceptance criterion; when the writer worked test-first, its RED-to-GREEN test.
  > - [ ] **Close lists residual risks.** The close rule (`skills/odd-flow/assets/core-block.md:10` and `references/odd-protocol.md` §7) asks for the verified outcome, every failed, skipped or pending check, and the next step. It does not ask the coordinator to carry forward what the writer put under `risks:` (things it judged missing) or the verifier's `advisories` and `unverified` items, so these can be lost between the worker report and the user. The close should name behavior achieved, evidence, and pending risks.
  >
  > Already in place and to keep: verify and review are separate roles; observed output is required for any passed check; the verifier derives its own probes and treats unverified as unmet; independent verify and review run only for high-risk items, not for every change.
  >
  > Cost note: the second item changes `core-block.md`, which every session loads; `tests/full-delegation-check.sh` pins its sha256.
- S2 (user, verbatim, issue "Cap the size of writer reports", body):
  > The explore and verify roles cap their reports at about 2000 tokens (`skills/odd-flow/assets/roles/explore.md`, `verify.md`). The writer role (`skills/odd-flow/assets/roles/write.md`) has a fixed format but no size limit: `validation`, `additions` and `learnings` can grow without bound, and every writer report lands in the coordinator's context.
  >
  > Proposal:
  > - Add a size cap to the writer's return block, similar to the other roles (for example about 1500-2000 tokens).
  > - State that the report carries no diffs, file dumps or full command output: name the path, the command and the observed result line; long output goes to a scratch file whose path is reported.
  >
  > Goal: the coordinator receives enough to decide, not a transcript of the worker's run. Check the role contract tests that pin `write.md` (`tests/role-prompts-check.sh`) when changing it.
- S3 (user, verbatim, issue "Investigate how explore findings reach the writer", body):
  > When the coordinator delegates mapping to an `explore` worker (more than its read budget is needed), no rule says how the explorer's map reaches the writer. `skills/odd-flow/references/delegation.md` (*What the parent passes*) lists the spec reference, allowed edit surfaces, skills, verification commands and known environmental failures, but not the explore result.
  >
  > Two failure modes to check against real sessions:
  > - The coordinator pastes the explore report into the writer spec, so the same content travels twice and stays in the coordinator's context.
  > - The coordinator passes nothing, so the writer re-explores the same files.
  >
  > Investigate what coordinators actually do (feature documents under `odd/tasks/` and recent dispatches). If duplication or re-exploration is confirmed, the likely fix is a reference: the spec points to the explore report (or the feature document records its key findings once) and names the files the writer should start from. Keep the existing rules: "Never explore files that will be read anyway before the write" and "Reading that prepares a writer belongs in that writer's spec, not in your context".
- S4 (user, verbatim): "the spot check re-runs the command that proves the main acceptance criterion (the RED-to-GREEN test when the writer worked test-first), and the close carries forward residual risks (the writer's `risks:`, the verifier's advisories and unverified items)."
- S5 (user, verbatim): "a size cap on the writer's return block like the explore and verify roles, and no diffs, file dumps or full command output in it."
- S6 (user, verbatim): "investigate first, read-only, against real feature documents under odd/tasks/ and the current rules. Send me the findings as a question with options (no change / the fix the evidence supports) before any writer changes rules for it."
- S7 (user, verbatim): "Do not implement #11 (per-criterion evidence in writer reports): it is an undecided idea. Keep test minimalism and proportional review unchanged."
- S8 (user, verbatim): "These are prompt and contract texts that every session loads. Keep each rule change minimal and exact; compare every removed or rewritten sentence and report each lost qualifier. tests/full-delegation-check.sh pins the sha256 of core-block.md; update the pin in the same unit that changes the block."
- S9 (user, verbatim): "Commit messages may reference the issues (\"Refs #10\"); code, rules and comments must not mention issue numbers, specs or tasks."
- S10 (assumption): `assets/core-block-full-delegation.md` carries the same close sentence as `assets/core-block.md`; the close change applies to both so the two modes stay consistent. Only `core-block.md` has a sha256 pin.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S5, S7-S9 | Writer return block: size cap, no diffs, file dumps or full command output (`roles/write.md`, `tests/role-prompts-check.sh`, CHANGELOG) | orca:write (full delegation) | done | dispatch `ctx_d399867e064e`; 3 files within surface; writer: RED→GREEN `bash tests/role-prompts-check.sh`, run.sh 21/22 (parent-guard-check S8/S12 setgid cases fail only in the writer sandbox); parent spot check: new `role-prompts-check.sh` exit 1 on base copy (2 FAIL), exit 0 on candidate; `parent-guard-check.sh` setgid cases PASS in parent env on base and candidate; commit COMMIT_T1 |
| T2 | S3, S6 | Read-only investigation: how explore findings reach the writer, against `odd/tasks/` and current rules | orca:explore (mapping trigger: 30 feature documents exceed the parent read budget) | in_progress | dispatch `ctx_4c10d6d53297` (task `task_3f7c9c26f992`): report outside the Return format (no `path:line` evidence, no counts), verdict "inconclusive"; correction follow-up `ctx_0932bb12b881` |
| T3 | S1, S4, S7-S10 | Targeted spot check (`delegation.md`) and residual risks at close (core blocks, `odd-protocol.md` §7, pin, CHANGELOG) | orca:write (full delegation; after T1, shares CHANGELOG and tests) | pending | |
| T4 | S3, S6 | Fix for the explore handoff, only if Max picks one | pending decision | pending | |
| T5 | S1-S10 | Independent verification, prompt/contract text kind (Risk item 6: no test catches a prompt regression) | orca:verify (verification trigger) | pending | |

## Log

- L1 (user via supervisor bot, 2026-11-26): "You are the main session for one odd-flow workstream. [...] Workstream: worker-rules (branch feat/worker-rules). Max approved it.

Goal: three GitHub issues on how the coordinator accepts and reports worker results. Read each first with `gh issue view <n> -R alvag/odd-flow` and quote their bodies verbatim into your feature document as the requirements:
- #10 \"Verification evidence: targeted spot check and residual risks at close\": the spot check re-runs the command that proves the main acceptance criterion (the RED-to-GREEN test when the writer worked test-first), and the close carries forward residual risks (the writer's `risks:`, the verifier's advisories and unverified items).
- #12 \"Cap the size of writer reports\": a size cap on the writer's return block like the explore and verify roles, and no diffs, file dumps or full command output in it.
- #14 \"Investigate how explore findings reach the writer\": investigate first, read-only, against real feature documents under odd/tasks/ and the current rules. Send me the findings as a question with options (no change / the fix the evidence supports) before any writer changes rules for it.

Do not implement #11 (per-criterion evidence in writer reports): it is an undecided idea. Keep test minimalism and proportional review unchanged.

Notes:
- These are prompt and contract texts that every session loads. Keep each rule change minimal and exact; compare every removed or rewritten sentence and report each lost qualifier. tests/full-delegation-check.sh pins the sha256 of core-block.md; update the pin in the same unit that changes the block.
- After merge, Codex and Antigravity need a reinstall and open sessions only see core-block changes after a restart; do not reinstall anything, list it in merge_ready.
- Expected surfaces: skills/odd-flow/references/delegation.md, skills/odd-flow/assets/core-block.md, skills/odd-flow/assets/roles/write.md, skills/odd-flow/references/odd-protocol.md, tests/role-prompts-check.sh, tests/full-delegation-check.sh (pin), CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>. Tell me before touching README.md (another workstream edits it).

Parallel workstreams (do not edit their files; tell me if you must):
- session-cleanup (#15): profile.py, references/profiles.md, tests/profile-check.sh, scripts/session-start.py, install_check.py, tests/install-check.sh, a new hook test.
- pane-placement-followups (#1): pane.py, tests/pane-check.sh, references/orca-dispatch.md.
- modes-doc (#16): README.md.
- Commit messages may reference the issues (\"Refs #10\"); code, rules and comments must not mention issue numbers, specs or tasks. Do not push and do not touch the GitHub issues; I close them after the push."
