# Orca dispatch

## Before the first launch of a session

1. Resolve the Orca executable as the installed `orchestration` skill says (`ORCA_CLI_COMMAND`, else `orca`).
2. Run `ORCA skills get orchestration` once and follow it for start, wake, send and recovery. This file only adds the ODD layer.

## Launch one worker

1. Resolve the role:
   `python3 <skill-dir>/scripts/profile.py resolve <role> --json`
   Use its `flags` exactly and print its `notice`. On a non-zero exit, stop and report the error; do not launch with guessed flags.
2. Build the spec from `assets/spec-template.md` and `assets/roles/<role>.md`. Write it with the file tool to a scratch file outside the worktree (for example `$TMPDIR/odd-flow/<session>/<task-id>.md`). Never use heredocs.
3. Start it by the `launch` field of the resolve result. A profile entry counts as the user naming the model, so its model and effort are allowed.
   - `worker-start`:
     `ORCA orchestration worker-start --environment local --spec-file <file> --task-title "<T# role: short title>" --worktree current <flags>`
   - `terminal` (Codex): `worker-start --agent codex` starts Codex in a sandbox that blocks the connection to Orca, so the worker could never report. Start it in a terminal instead, with the resolve result's `terminal_command`, which already carries the model and effort:
     1. `ORCA orchestration task-create --environment local --spec-file <file> --task-title "<T# role: short title>" --json`, and keep `taskId`.
     2. `ORCA terminal create --worktree current --title "<T# role: short title>" --command "$CMD" --json`, and keep the terminal `handle`. Set `CMD` in the same shell command straight from the resolve JSON (for example `CMD=$(python3 <skill-dir>/scripts/profile.py resolve <role> --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["terminal_command"])')`); never paste its text inside the quotes, because the parent's shell would expand `$`, backticks or `"` in it.
     3. `ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json`.
     4. `ORCA orchestration worker-start --environment local --task <taskId> --terminal <handle> --json`, without `flags`.
     If step 2, 3 or 4 fails, close the terminal you created (`ORCA terminal close --terminal <handle>`) and report the error with the `taskId`, which stays unassigned for a retry with `worker-start --task`; never fall back to `worker-start --agent codex`.
4. End the turn. Orca wakes you; never poll.

## Several workers

Start every independent worker of one parallel batch from a single shell command, as the orchestration guide's `references/parallel-start.md` shows. Serial launches void the parallel writer reason. For a `terminal` launch, run its four steps in order as one background group of that command.

## When Orca wakes you

- `worker_done`: read the report, check it against the role's Return format, spot-check one reported command, compare a writer's changed files with its surface, then update the feature document.
- After `worker_done` of a `terminal` launch, release it: `ORCA orchestration worker-release --environment local --dispatch <dispatch_id>`. Orca does not close a terminal it did not start (`reason=external_terminal`); if the handle is still in `ORCA terminal list --json`, close it with `ORCA terminal close --terminal <handle>`, unless the user asked to keep it open.
- `question`: answer from the task or the user's instructions. Otherwise relay it to the user unchanged: every option, label and description in original order, and the allowed answers. Return a valid answer to the worker once.
- `escalation` or a lost worker: apply the correction bounds in `delegation.md`; never retry a launch blindly.

## Orca unavailable

If `ORCA status --json` fails or the start fails at readiness, do not silently run the triggered work inline. Report the blocker, keep existing work, and ask the user whether to continue inline or wait for Orca.

## Limits

- `--effort` requires `--model`; neither combines with `--terminal`. A role with only `effort` is invalid.
- Codex workers run with outbound network enabled in their sandbox (`-c sandbox_workspace_write.network_access=true` in `scripts/codex-worker.sh`); that is the only change, and the user's Codex config stays untouched.
- OpenCode takes no effort; agents outside Claude, Codex, Cursor, Antigravity, Grok, Muse, OMP and Pi use their own configured model.
- Workers in `--worktree current` share your tree: give parallel writers disjoint surfaces or use `--worktree new-child`.
