# Orca dispatch

## Before the first launch of a session

1. Resolve the Orca executable as the installed `orchestration` skill says (`ORCA_CLI_COMMAND`, else `orca`).
2. Run `ORCA skills get orchestration` once and follow it for start, wake, send and recovery. This file only adds the ODD layer.

## Launch one worker

1. Resolve the role:
   `python3 <skill-dir>/scripts/profile.py resolve <role> --json`
   Use its `flags` exactly and print its `notice`. On a non-zero exit, stop and report the error; do not launch with guessed flags.
2. Build the spec from `assets/spec-template.md` and `assets/roles/<role>.md`. Write it with the file tool to a scratch file outside the worktree (for example `$TMPDIR/odd-flow/<session>/<task-id>.md`). Never use heredocs. In `task-create` and `worker-start`, pass the resolved literal path to `--spec-file`, quoted if needed, not a variable (such as `$SPEC`), command substitution, or glob. In Claude Code, a guard denial means the launch did not run: fix the spec or pass a readable literal path and retry; do not bypass the guard. The hook checks the declaration at launch, not subsequent edits.
3. For a writer in a folder without Git, use Project folders without Git below. Otherwise run placement for this launch:
   `python3 <skill-dir>/scripts/pane.py open --role <role> --title "<T# role: short title>" --json`
   A handle starts one worker. Run `pane.py open` again for every launch; never reuse a placement result or handle.
   On a non-zero exit, report the error and do not launch. If the split or create reply cannot be parsed or has no handle, a terminal may have opened; check `terminal list` and close it. Report any `title_error`, but continue with the opened terminal.
   - A returned `handle` (Claude, Codex and Antigravity): use it for terminal steps 1, 3 and 4 below, whether it is a split pane or a tab. Skip step 2.
   - Only when `handle` is `null`: start by the `launch` field of the resolve result.

   A profile entry counts as the user naming the model, so its model and effort are allowed.
   - `worker-start`:
     `ORCA orchestration worker-start --environment local --spec-file <file> --task-title "<T# role: short title>" --worktree current <flags>`
     For a dependent unit, create the Task up front with terminal step 1. Once it can launch (see When Orca wakes you), use `ORCA orchestration worker-start --environment local --task <taskId> --worktree current <flags>` instead, without `--spec-file` or `--task-title`.
   - Terminal steps: use the handle from placement when available. `worker-start --agent codex` starts Codex in a sandbox that blocks the connection to Orca, so the worker could never report. Start it in a terminal instead.
     1. `ORCA orchestration task-create --environment local --spec-file <file> --task-title "<T# role: short title>" --json`, and keep `taskId`.
        Only for a [unit](delegation.md#units) that depends on another unit of this request, add `--deps '<JSON array of dependency taskIds>'` when creating the Task up front. Use IDs from the same Run and record the new `taskId`. Defer placement and the remaining terminal steps until it can launch; resume at the applicable terminal step without creating the Task again. Launch independent units as usual.
     2. Only for paths that still need to open a terminal (such as Project folders without Git), run `ORCA terminal create --worktree current --title "<T# role: short title>" --command "$CMD" --json`, and keep the terminal `handle`. Set `CMD` in the same shell command straight from the resolve JSON (for example `CMD=$(python3 <skill-dir>/scripts/profile.py resolve <role> --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["terminal_command"])')`); never paste its text inside the quotes, because the parent's shell would expand `$`, backticks or `"` in it.
     3. `ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json`.
        With Codex CLI 0.171.0 and the odd-flow Codex plugin (verified 2026-11-23), new interactive Codex sessions, including Orca workers, showed `Hooks need review` after the first install and after a reinstall that changed a hook script. Codex runs a cached copy of the plugin: local edits do not change the installed hooks until reinstall, and trust persists until the hooks change again.

        The wait exits 1 with `"satisfied": false` and `"blockedReason": "agent-hooks-review-prompt"`. This blocked wait is not a step failure under the rule below. Keep the terminal open and do not run step 4 yet. Read the menu with `ORCA terminal read --terminal <handle> --screen` and relay it and its options to the user unchanged. Only the user decides what to select, unless they already chose for this install. Expect this menu:

        ```text
        Hooks need review
        2 hooks are new or changed
        Hooks can run outside the sandbox after you trust them.
        1. Review hooks
        2. Trust all and continue
        3. Continue without trusting (hooks won't run)
        ```

        If the user declines or does not answer, close the pane and report the `taskId` as described below. With the user's choice, run `ORCA terminal send --terminal <handle> --text <n>` and confirm with `ORCA terminal send --terminal <handle> --text '' --enter`. This input answers Codex's startup menu, not an agent prompt. Option 1 opens a review screen these steps do not cover; with option 3, the odd-flow hooks do not run in that worker. Re-run the wait and continue to step 4 only once it succeeds.
     4. `ORCA orchestration worker-start --environment local --task <taskId> --terminal <handle> --json`, without `flags`.
     If a step fails, close the pane or terminal you opened (`ORCA terminal close --terminal <handle>`) and report the error with the `taskId` if one exists. The task stays unassigned for a retry with `worker-start --task`; never fall back to `worker-start --agent codex`.
4. End the turn. Orca wakes you; never poll.

## Project folders without Git

In either mode, get the folder's real path (`pwd -P` in the folder). If it is not registered, register it with `orca repo add --path "$folder" --kind folder`. Take the pre-launch snapshot in `delegation.md` (Shadow snapshots).

Skip pane placement: a split runs in the parent's workspace. For Codex use terminal step 2 with `--worktree "path:$folder"` instead of `--worktree current`. For other agents replace that step with `ORCA agent launch --surface terminal --worktree "path:$folder" <flags> --json` and keep `outcome.handle`. Use the other terminal steps unchanged.

At task close, if you registered the folder for this task, wait until the writer's terminal is closed, then run `orca project setup-delete --setup <id> --force` using the setup whose `path` in `orca project setups --json` matches the folder's real path. Leave any pre-existing entry in place.

## Several workers

Start every independent worker of one parallel batch from a single shell command, as the orchestration guide's `references/parallel-start.md` shows. Serial launches void the parallel writer reason. Run each worker's `pane.py open` and its launch steps in order in that worker's background group. The pane lock orders width reads, layout reads and splits.

## When Orca wakes you

- `worker_done`: read the report, check it against the role's Return format, spot-check one reported command, compare a writer's changed files with its surface, then update the feature document.
- After `worker_done` of a terminal or split-pane launch, release it: `ORCA orchestration worker-release --environment local --dispatch <dispatch_id>`. Orca does not close a terminal it did not start (`reason=external_terminal`); if the handle is still in `ORCA terminal list --json`, close it with `ORCA terminal close --terminal <handle>`, unless the user asked to keep it open.
- To correct a Codex writer whose split pane or tab has closed, follow [Launch one worker](#launch-one-worker), including pane placement in step 3 and the terminal steps. Use the original spec plus the correction. The relaunch continues the same unit and counts as the correction against the original worker's [correction bound](delegation.md#correction-bounds). Do not send a follow-up with `ORCA orchestration send --to dispatch:<dispatch_id>`: Orca can return `"delivery": "reopened"` and start Codex in its own terminal, not through `scripts/codex-worker.sh`, so the launcher's sandbox and network pins are not guaranteed (Codex CLI 0.171.0, observed 2026-11-23). If a reopened dispatch shows a folder or workspace trust prompt, never answer it for the user. Stop the dispatch with `ORCA orchestration worker-stop --environment local --dispatch <dispatch_id>`, or relay the screen unchanged if the user wants to answer it.
- `question`: answer from the task or the user's instructions. Otherwise relay it to the user unchanged: every option, label and description in original order, and the allowed answers. Return a valid answer to the worker once.
- An Antigravity worker that pauses with `stopReason=needs-input` when it first runs `orca orchestration send` (verified 2026-11-24, `agy` 1.5.16) is waiting for `orca` command permission, not failing. Relay it to the user: only they decide whether to persist `orca` permission in Antigravity `settings.json`. Once persisted, later Antigravity workers send `worker_done` without escalation. Do not answer the prompt for them.
- `escalation` or a lost worker: apply the correction bounds in `delegation.md`; never retry a launch blindly.
- If a dependency unit fails or exhausts its correction bound, follow the active mode. Cancel each pending dependent with `ORCA orchestration task-update --environment local --id <task_id> --status failed --result cancelled`, or keep it pending for a relaunch that continues the unit. Do not leave dependents pending silently.
- On every wake, after handling the message and any `worker_done` checks above, run `ORCA orchestration task-list --environment local --ready --brief` and start the ready Tasks of this request. A successful outcome makes dependents ready before you check the report. Start a dependent only after every dependency's report passes the checks above.

## Without Orca

The session knows from its start whether it runs in an Orca terminal: the `orca:` line of `profile.py show`, injected at session start, and `orca_terminal` in the resolve result. Orca addresses worker reports to the launching terminal's mailbox, so a session outside an Orca terminal cannot start workers (`worker-start` fails with `no_active_sender_terminal`).

Missing Orca never stops ODD. Use the fallback without asking when `orca_terminal` is null, the `orca` executable is missing, `ORCA status --json` fails, or a start fails with `no_active_sender_terminal` or at readiness:

1. Subagent, when the runtime offers one (Claude Code: the Agent tool). Pass the same spec and role prompt; the subagent returns its report, in the role's Return format, as its final message. It obeys hard rule 6: no commits, no staging, no scratch deletion, no further workers. Parallel writers start as subagents in one message.
2. No subagent: the active mode file (Without Orca) says what runs instead.

The fallback runs on the session agent. Pass the profile's model and effort only when its agent is the session agent and the subagent tool accepts them (Claude Code's Agent tool takes `model` and `effort`); otherwise the subagent uses its defaults. Print the notice with the fallback the active mode file names and every part of the profile entry that was not applied.

After a fallback, the Orca messaging steps under "When Orca wakes you" (release, `question`, `escalation`) do not apply. The checks on the report still do: compare it with the role's Return format, spot-check one reported command, compare a writer's changed files with its surface, then update the feature document. Record the route in the feature document as the active mode file says.

The Named agent trigger is the one exception: the user asked for that agent. Use any path in the runtime that runs that agent: a subagent (for example a Codex subagent from a Codex plugin) or that agent's own CLI or plugin runtime, read-only when the request is read-only. When none exists, say the named agent is unreachable without Orca and ask whether to run the work on the session agent.

A launch that fails because of the agent or the model is not an Orca outage: report it under hard rule 3 and do not fall back.

## Limits

- `--effort` requires `--model`; neither combines with `--terminal`. A role with only `effort` is invalid.
- `scripts/codex-worker.sh` pins `--sandbox workspace-write` and `-c sandbox_workspace_write.network_access=true`, even in untrusted folders or with a configured read-only sandbox. It overrides no other Codex config and leaves the config file untouched.
- OpenCode takes no effort; agents outside Claude, Codex, Cursor, Antigravity, Grok, Muse, OMP and Pi use their own configured model.
- Workers in `--worktree current` share your tree: give parallel writers disjoint surfaces or use `--worktree new-child`.
- Never equalize pane heights from the skill: Orca has no command for it. Use Orca's “Equalize pane sizes” by hand.
