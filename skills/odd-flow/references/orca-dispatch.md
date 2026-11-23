# Orca dispatch

## Before the first launch of a session

1. Resolve the Orca executable as the installed `orchestration` skill says (`ORCA_CLI_COMMAND`, else `orca`).
2. Run `ORCA skills get orchestration` once and follow it for start, wake, send and recovery. This file only adds the ODD layer.

## Launch one worker

1. Resolve the role:
   `python3 <skill-dir>/scripts/profile.py resolve <role> --json`
   Use its `flags` exactly and print its `notice`. On a non-zero exit, stop and report the error; do not launch with guessed flags.
2. Build the spec from `assets/spec-template.md` and `assets/roles/<role>.md`. Write it with the file tool to a scratch file outside the worktree (for example `$TMPDIR/odd-flow/<session>/<task-id>.md`). Never use heredocs.
3. Start it:
   `ORCA orchestration worker-start --environment local --spec-file <file> --task-title "<T# role: short title>" --worktree current <flags>`
   A profile entry counts as the user naming the model, so `--model` and `--effort` from `flags` are allowed.
4. End the turn. Orca wakes you; never poll.

## Several workers

Start every independent worker of one parallel batch from a single shell command, as the orchestration guide's `references/parallel-start.md` shows. Serial launches void the parallel writer reason.

## When Orca wakes you

- `worker_done`: read the report, check it against the role's Return format, spot-check one reported command, compare a writer's changed files with its surface, then update the feature document.
- `question`: answer from the task or the user's instructions. Otherwise relay it to the user unchanged: every option, label and description in original order, and the allowed answers. Return a valid answer to the worker once.
- `escalation` or a lost worker: apply the correction bounds in `delegation.md`; never retry a launch blindly.

## Orca unavailable

If `ORCA status --json` fails or the start fails at readiness, do not silently run the triggered work inline. Report the blocker, keep existing work, and ask the user whether to continue inline or wait for Orca.

## Limits

- `--effort` requires `--model`; neither combines with `--terminal`. A role with only `effort` is invalid.
- OpenCode takes no effort; agents outside Claude, Codex, Cursor, Antigravity, Grok, Muse, OMP and Pi use their own configured model.
- Workers in `--worktree current` share your tree: give parallel writers disjoint surfaces or use `--worktree new-child`.
