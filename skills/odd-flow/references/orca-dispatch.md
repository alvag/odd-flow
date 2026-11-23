# Orca dispatch

## Before the first launch of a session

1. Resolve the Orca executable as the installed `orchestration` skill says (`ORCA_CLI_COMMAND`, else `orca`).
2. Run `ORCA skills get orchestration` once and follow it for start, wake, send and recovery. This file only adds the ODD layer.

## Launch one worker

1. Resolve the role:
   `python3 <skill-dir>/scripts/profile.py resolve <role> --json`
   Use its `flags` exactly and print its `notice`. On a non-zero exit, stop and report the error; do not launch with guessed flags.
2. Build the spec from `assets/spec-template.md` and `assets/roles/<role>.md`. Write it with the file tool to a scratch file outside the worktree (for example `$TMPDIR/odd-flow/<session>/<task-id>.md`). Never use heredocs.
3. Choose a placement before starting the worker:
   `python3 <skill-dir>/scripts/pane.py open --role <role> --title "<T# role: short title>" --json`
   On a non-zero exit, report the error and do not launch. If the split reply cannot be parsed or has no handle, a pane may have opened; check `terminal list` and close it. Report any `title_error`, but continue with the opened pane.
   - `split-right` or `split-below`: keep the returned `handle` and run terminal steps 1, 3 and 4 below. Skip `terminal create`. Use this path for both Claude and Codex.
   - `tab`: start by the `launch` field of the resolve result.

   A profile entry counts as the user naming the model, so its model and effort are allowed.
   - `worker-start`:
     `ORCA orchestration worker-start --environment local --spec-file <file> --task-title "<T# role: short title>" --worktree current <flags>`
   - Terminal steps: for an opened pane or a tab with `launch: terminal` (Codex). `worker-start --agent codex` starts Codex in a sandbox that blocks the connection to Orca, so the worker could never report. Start it in a terminal instead. For a Codex tab, use the resolve result's `terminal_command`, which already carries the model and effort.
     1. `ORCA orchestration task-create --environment local --spec-file <file> --task-title "<T# role: short title>" --json`, and keep `taskId`.
     2. `ORCA terminal create --worktree current --title "<T# role: short title>" --command "$CMD" --json`, and keep the terminal `handle`. Set `CMD` in the same shell command straight from the resolve JSON (for example `CMD=$(python3 <skill-dir>/scripts/profile.py resolve <role> --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["terminal_command"])')`); never paste its text inside the quotes, because the parent's shell would expand `$`, backticks or `"` in it.
     3. `ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json`.
     4. `ORCA orchestration worker-start --environment local --task <taskId> --terminal <handle> --json`, without `flags`.
     If a step fails, close the pane or terminal you opened (`ORCA terminal close --terminal <handle>`) and report the error with the `taskId` if one exists. The task stays unassigned for a retry with `worker-start --task`; never fall back to `worker-start --agent codex`.
4. End the turn. Orca wakes you; never poll.

## Several workers

Start every independent worker of one parallel batch from a single shell command, as the orchestration guide's `references/parallel-start.md` shows. Serial launches void the parallel writer reason. Run each worker's `pane.py open` and its launch steps in order in that worker's background group. The pane lock orders layout reads and splits.

## When Orca wakes you

- `worker_done`: read the report, check it against the role's Return format, spot-check one reported command, compare a writer's changed files with its surface, then update the feature document.
- After `worker_done` of a terminal or split-pane launch, release it: `ORCA orchestration worker-release --environment local --dispatch <dispatch_id>`. Orca does not close a terminal it did not start (`reason=external_terminal`); if the handle is still in `ORCA terminal list --json`, close it with `ORCA terminal close --terminal <handle>`, unless the user asked to keep it open.
- `question`: answer from the task or the user's instructions. Otherwise relay it to the user unchanged: every option, label and description in original order, and the allowed answers. Return a valid answer to the worker once.
- `escalation` or a lost worker: apply the correction bounds in `delegation.md`; never retry a launch blindly.

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
- Codex workers run with outbound network enabled in their sandbox (`-c sandbox_workspace_write.network_access=true` in `scripts/codex-worker.sh`); that is the only change, and the user's Codex config stays untouched.
- OpenCode takes no effort; agents outside Claude, Codex, Cursor, Antigravity, Grok, Muse, OMP and Pi use their own configured model.
- Workers in `--worktree current` share your tree: give parallel writers disjoint surfaces or use `--worktree new-child`.
- Never equalize pane heights from the skill: Orca has no command for it. Use Orca's “Equalize pane sizes” by hand.
