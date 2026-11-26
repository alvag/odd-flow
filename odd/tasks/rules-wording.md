# Rules wording: spot check and residual risks

Objective: clarify the coordinator's spot-check rule (wording, a fallback when the command was not reported, aligned references) and make the close rule count the items a writer judged missing as residual risks. Branch: `docs/rules-wording`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh` (one suite: `bash tests/<name>-check.sh`).
Profile: `claude-gpt`.

## Specs

Sources: GitHub issues alvag/odd-flow#21 and #22, quoted verbatim. The issue bodies win over any summary.

- S1 (issue #21, "Spot check rule: clearer wording, a fallback when the command was not reported, and aligned references", verbatim):
> Follow-up from the targeted spot check rule (#10).
>
> `skills/odd-flow/references/delegation.md` now says:
>
> > - Spot check: re-run one command a worker reported before accepting its result: the command that proves the main acceptance criterion, or the RED-to-GREEN test when the writer worked test-first.
>
> - [ ] The sentence has two colons and reads awkwardly. Suggested wording: "Spot check: before accepting a worker result, re-run the reported command that proves the main acceptance criterion (the RED-to-GREEN test when the writer worked test-first)."
> - [ ] Say what the coordinator does when the worker did not report the command that proves the main criterion (for example: re-run the closest reported command and say the main criterion was not spot-checked, or ask the worker for it).
> - [ ] `references/orca-dispatch.md` (two places) and `references/mode-full-delegation.md` still say "one reported command". They defer to `delegation.md`, but align them so the targeted rule is not read as "any command".
>
> Keep the change minimal; `tests/role-prompts-check.sh` and `tests/full-delegation-check.sh` may pin the affected text.
- S2 (issue #22, "Writer report: separate residual risks from items the writer judged missing", verbatim):
> Decision needed before any change: this alters the writer's return contract.
>
> In `skills/odd-flow/assets/roles/write.md` the `risks:` field holds both the `Risk:` line and the items the writer judged missing. The close rule now carries forward "residual risks workers reported" (the writer's `risks:`, the verifier's `advisories` and `unverified` items). When a writer reports `Risk: none` but lists judged-missing items in the same field, a coordinator can read the field as empty and drop those items from the close.
>
> Options to weigh:
> - Keep one field and say in the close rule that judged-missing items count as residual risks.
> - Split the field (for example `risks:` and `missing:`), and update the close rule, the README row, and the pins in `tests/role-prompts-check.sh`.
>
> Codex and Antigravity need a reinstall after any change to role prompts.
- S3 (workstream brief, verbatim): "Max chose option (a): keep the writer's single `risks:` field and make the close rule say that the items the writer judged missing count as residual risks. Do not split the field and do not change the writer's return format."
- S4 (workstream brief, verbatim, notes):
> - These are prompt and contract texts that every session loads. Keep each change minimal and exact; compare every removed or rewritten sentence and report each lost qualifier.
> - Put the #22 rule where the residual-risk sources are already named (references/odd-protocol.md §7) unless the close line in the core blocks needs it to be followed; if you change core-block.md or core-block-full-delegation.md, update the sha256 pin in tests/full-delegation-check.sh in the same unit and say so in merge_ready (open sessions need a restart).
> - After merge, Codex and Antigravity need a reinstall; do not reinstall anything, list it in merge_ready.
> - Expected surfaces: skills/odd-flow/references/delegation.md, skills/odd-flow/references/mode-full-delegation.md, skills/odd-flow/references/orca-dispatch.md (only the spot-check wording; another workstream may need its step 3), skills/odd-flow/references/odd-protocol.md, optionally the core blocks, tests/role-prompts-check.sh, tests/full-delegation-check.sh, tests/mode-check.sh if they pin the changed text, CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>. Tell me before touching README.md.
> - Commit messages may reference the issues ("Refs #21"); rules, code and comments must not mention issue numbers, specs or tasks. Do not push and do not touch the GitHub issues; I close them after the push.
- S5 (assumption, unconfirmed): when the worker did not report the command that proves the main acceptance criterion, the coordinator re-runs the closest reported command and says in the close that the main criterion was not spot-checked (the first example in S1). The bot ended its turn without answering; flag it in merge_ready for Max to confirm or change.
- S6 (assumption): the #22 rule goes in `references/odd-protocol.md` §7 only; the core-block close line already says "residual risks workers reported", so the core blocks and their sha256 pin stay unchanged.
- S7 (assumption): `README.md` row "A writer returns" is out of scope unless Max approves touching it; listed as a follow-up.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S3, S4, S6 | odd-protocol §7: judged-missing items count as residual risks; pin in role-prompts-check; CHANGELOG bullet | orca:write (all changes go to a writer in full delegation) | done | RED/GREEN `bash tests/role-prompts-check.sh` (worker); parent spot check exit 0; commit below |
| T2 | S1, S4, S5 | delegation.md spot-check sentence and fallback; align orca-dispatch (two places) and mode-full-delegation; pins; CHANGELOG bullet | orca:write (after T1: shares role-prompts-check.sh and CHANGELOG.md) | pending | |

## Log

- L1 (user, 2026-11-26, workstream brief, verbatim): "Workstream: rules-wording (branch docs/rules-wording). Max approved it. Goal: two GitHub issues on the coordinator's acceptance and close rules. Read each first with `gh issue view <n> -R alvag/odd-flow` and quote the bodies verbatim into your feature document as the requirements: #21 \"Spot check rule: clearer wording, a fallback when the command was not reported, and aligned references\". #22 \"Writer report: separate residual risks from items the writer judged missing\". Max chose option (a): keep the writer's single `risks:` field and make the close rule say that the items the writer judged missing count as residual risks. Do not split the field and do not change the writer's return format."
- L2 (2026-11-26): base commit `fda7253`. Pins of the changed text live only in `tests/role-prompts-check.sh` (grep of `tests/` for spot/reported command/residual); `full-delegation-check.sh` and `mode-check.sh` pin none of it. Fallback wording for S5 sent to the bot as a question; T1 does not depend on it and starts first.
- L3 (2026-11-26): T1 launched (orca:write, codex gpt-6.2-sol medium, task_7ae6266aa7b4). Bot reply to the S5 question: "ODDFlow Bot ended its turn without answering your question". Not resent (resend only on the bot's request). S5 recorded as an unconfirmed assumption; T2 uses it and merge_ready asks Max to confirm.
- L4 (2026-11-26): T1 worker_done (status partial): diff matches the spec on its three surfaces; RED only on the new pin, GREEN after. Worker's `bash tests/run.sh`: 22 passed, 1 failed (parent-guard-check S8/S12 setgid worker-token checks). Parent spot check `bash tests/role-prompts-check.sh`: exit 0. Parent `bash tests/parent-guard-check.sh`: exit 0 on the candidate and exit 0 on a `git archive` copy of base `fda7253`, so the failure is specific to the worker's sandbox, not the change.
