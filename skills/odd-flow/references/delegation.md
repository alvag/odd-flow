# Delegation triggers

No trigger holds by default. When in doubt, work inline. Each trigger is mandatory only when its condition truly holds; record the reason in one line before launching.

| Trigger | Condition | Role |
|---|---|---|
| Mapping | Understanding needs more than the inline budget (3 calls, ~10k tokens) or more than ~5 sequential lookups | `explore` |
| Writer: parallel | Two or more independent units with disjoint edit surfaces, each several minutes of work (several files or ~100+ changed lines), launched together in one turn | `write`, one per unit |
| Writer: context | The parent context is near ~150k tokens; delegate the next bounded unit | `write` |
| Verification | The change's Risk line names a high-risk item | `verify` |
| Review | The user asks for review, or verification passed on a change that names a high-risk item and the user accepted the review forecast | `review`, `refute` |
| Named agent | The user explicitly asks for another agent ("have Codex check this") | role that matches the request |

Never delegate for size, file count, a large task alone, or price. Units of ~100 changed lines or less run inline.

## Units

- A unit is one independent behavior with its code, tests and docs together. Never split one behavior into test, docs and code workers.
- A delivery that depends on another is not independent: run them in order.
- Each writer prompt names the existing helpers it must reuse for shared state and the invariants they keep.

## Allowed edit surfaces

Every `write` launch carries `## Allowed edit surfaces`:

- repo-relative paths or narrow globs, one per line; never `.`, the repo root or absolute paths;
- the section ends at the next heading, and every non-empty line inside it is an entry;
- pre-existing untracked targets listed explicitly; directories for new files only when the task needs them;
- nothing wider than the task.

A writer that needs another path returns it with a reason. Add it yourself when it serves the authorized objective; ask the user only for new scope, another repository or a destructive operation. Parallel writers in one worktree must have disjoint surfaces; units that need the same file run in order or in separate worktrees.

This is a prompt rule: nothing enforces it at write time. After each writer returns, compare `git diff --name-only` against its surface and reject out-of-surface edits.

## What the parent passes

- `Spec: odd/tasks/<feature>.md, T<n>, S<a>-S<b>` and "read until `## Log`", or the user's request verbatim when there is no document.
- `## Allowed edit surfaces` (writers), `## Skills to load before work` with exact `SKILL.md` paths that match the task, `## Verification` with exact commands, optional `## Known environmental failures`.
- The test-first policy and runner.

## Correction bounds

- Worker: one correction per failing check; a second only when the same check still fails; then `partial` with the diagnosed cause.
- Verifier blockers: one correction batch that fixes every blocker, one recheck limited to those blockers, a second correction only for the same blocker still failing. A new finding never earns another round.
- A worker that exhausts its bound ends its cycle, not the unit. Name the cause; fix inline when small and understood, otherwise relaunch once with the diagnosis and a new hypothesis. A repeated cause blocks the unit.
- Spot check: re-run one command a worker reported before accepting its result.
