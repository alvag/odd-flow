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
- S5 (Max, via the supervisor bot, 2026-11-26, verbatim): "A, adjusted: run the spec's Verification command, say it was missing from the report". Bot's reading, verbatim: "When the worker did not report that command, the coordinator runs that `## Verification` command itself (instead of re-running the closest reported one), and says in the close that the worker's report did not include it. Keep the sentence minimal; for example: \"If the worker did not report that command, run it yourself from the spec's `## Verification` and say in the close that the report left it out.\""
- S8 (Max via bot, 2026-11-26, verbatim): "Fix the README row first, then merge and push; reinstall with install-hardening". Bot, verbatim: "You may now edit README.md, only the \"A writer returns\" row (your follow-up 1): align it with the new spot-check rule and its fallback, keeping the row short. If an existing docs check pins that row (tests/mode-check.sh or another), update the pin in the same commit. Commit it on docs/rules-wording, run bash tests/run.sh, and send a new merge_ready with the new HEAD and the observed results."
- S6 (assumption): the #22 rule goes in `references/odd-protocol.md` §7 only; the core-block close line already says "residual risks workers reported", so the core blocks and their sha256 pin stay unchanged.
- S7 (superseded by S8): `README.md` row "A writer returns" was out of scope until Max approved touching it.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S3, S4, S6 | odd-protocol §7: judged-missing items count as residual risks; pin in role-prompts-check; CHANGELOG bullet | orca:write (all changes go to a writer in full delegation) | done | RED/GREEN `bash tests/role-prompts-check.sh` (worker); parent spot check exit 0; commit below |
| T2 | S1, S4, S5 | delegation.md spot-check sentence and fallback; align orca-dispatch (two places) and mode-full-delegation; pins; CHANGELOG bullet | orca:write (after T1: shares role-prompts-check.sh and CHANGELOG.md) | done | task_f82ffb79ccf8; correction task_e2781daadc4b |
| T3 | S8 | README "A writer returns" row aligned with the spot-check rule and fallback; pin; CHANGELOG bullet names the README | orca:write | done | task_1855269d676e; RED/GREEN `bash tests/role-prompts-check.sh` (worker); parent spot check exit 0 |

## Log

- L1 (user, 2026-11-26, workstream brief, verbatim): "Workstream: rules-wording (branch docs/rules-wording). Max approved it. Goal: two GitHub issues on the coordinator's acceptance and close rules. Read each first with `gh issue view <n> -R alvag/odd-flow` and quote the bodies verbatim into your feature document as the requirements: #21 \"Spot check rule: clearer wording, a fallback when the command was not reported, and aligned references\". #22 \"Writer report: separate residual risks from items the writer judged missing\". Max chose option (a): keep the writer's single `risks:` field and make the close rule say that the items the writer judged missing count as residual risks. Do not split the field and do not change the writer's return format."
- L2 (2026-11-26): base commit `fda7253`. Pins of the changed text live only in `tests/role-prompts-check.sh` (grep of `tests/` for spot/reported command/residual); `full-delegation-check.sh` and `mode-check.sh` pin none of it. Fallback wording for S5 sent to the bot as a question; T1 does not depend on it and starts first.
- L3 (2026-11-26): T1 launched (orca:write, codex gpt-6.2-sol medium, task_7ae6266aa7b4). Bot reply to the S5 question: "ODDFlow Bot ended its turn without answering your question". Not resent (resend only on the bot's request). S5 recorded as an unconfirmed assumption; T2 uses it and merge_ready asks Max to confirm.
- L4 (2026-11-26): T1 worker_done (status partial): diff matches the spec on its three surfaces; RED only on the new pin, GREEN after. Worker's `bash tests/run.sh`: 22 passed, 1 failed (parent-guard-check S8/S12 setgid worker-token checks). Parent spot check `bash tests/role-prompts-check.sh`: exit 0. Parent `bash tests/parent-guard-check.sh`: exit 0 on the candidate and exit 0 on a `git archive` copy of base `fda7253`, so the failure is specific to the worker's sandbox, not the change.
- L5 (2026-11-26): T2 worker_done (task_f82ffb79ccf8): diff matches the spec on its five surfaces. Parent spot check `bash tests/role-prompts-check.sh`: exit 0; `bash tests/full-delegation-check.sh`: exit 0; `bash tests/run.sh`: "Summary: 23 passed, 0 failed". Not committed yet.
- L6 (Max via bot, 2026-11-26, verbatim): "A, adjusted: run the spec's Verification command, say it was missing from the report". S5 rewritten; T2 reopened. Its Codex terminal is closed, so the correction relaunches the writer with the original spec plus the correction (counts as T2's correction).
- L7 (2026-11-26): T2 correction worker_done (task_e2781daadc4b): RED only on the new pin, GREEN after; worker's `bash tests/run.sh` failed only on the known sandbox S8/S12 checks. Parent spot check `bash tests/role-prompts-check.sh`: exit 0; parent `bash tests/run.sh`: "Summary: 23 passed, 0 failed". Committed with T2.
- L8 (2026-11-26): merge_ready sent (msg_11edeef401e2). Bot status: "ODDFlow Bot ended its turn without answering your question". Not resent; waiting for Max's answer. Nothing merged or pushed.
- L9 (Max via bot, 2026-11-26, verbatim): "Fix the README row first, then merge and push; reinstall with install-hardening". No existing test pins the README row (grep of tests/ for README); T3 adds one in tests/role-prompts-check.sh.
- L10 (2026-11-26): T3 worker_done (task_1855269d676e): diff matches the spec on its three surfaces. Parent: `bash tests/role-prompts-check.sh` exit 0; `bash tests/mode-check.sh` "passed=41 failed=0"; `bash tests/run.sh` "Summary: 23 passed, 0 failed". Committed; new merge_ready sent.
