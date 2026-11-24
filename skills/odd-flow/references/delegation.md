# Delegation triggers

Who writes, and the writer triggers, are the active mode file's rule (`mode-organic.md` or `mode-full-delegation.md`, named by the `mode:` line of `profile.py show`). The triggers below hold in both modes. Each is mandatory only when its condition truly holds; record the reason in one line before launching.

| Trigger | Condition | Role |
|---|---|---|
| Mapping | Understanding needs more than the parent's read budget (3 calls, ~10k tokens) or more than ~5 sequential lookups | `explore` |
| Verification | The change's Risk line names a high-risk item | `verify` |
| Review | The user asks for review, or verification passed on a change that names a high-risk item and the user accepted the review forecast | `review`, `refute` |
| Named agent | The user explicitly asks for another agent ("have Codex check this") | role that matches the request |

A trigger names a role, not a runtime. Outside an Orca terminal the role runs as `orca-dispatch.md` (Without Orca) and the active mode file say; a trigger never stops the work because Orca is missing.

## Units

- A unit is one independent behavior with its code, tests and docs together. Never split one behavior into test, docs and code workers.
- A delivery that depends on another is not independent: run them in order.
- Each writer prompt names the existing helpers it must reuse for shared state and the invariants they keep.

## Allowed edit surfaces

Every `write` launch carries `## Allowed edit surfaces`:

- paths or narrow globs relative to the workspace root, one per line; never `.`, `./`, the repo root or non-Git folder root, an absolute path, a drive-qualified path, a `~` path, or a path with a `..` segment;
- no wildcard in the first path segment, no unfilled template placeholder, and no empty entries or sections;
- one optional `- ` or `* ` bullet and one pair of surrounding backticks are stripped; any remaining backtick, dollar sign, brace, comma, leading list marker or quote marker is rejected;
- outside fenced code blocks, the section ends at the next heading and every non-empty line inside it is an entry; all declarations are checked;
- pre-existing untracked targets listed explicitly; directories for new files only when the task needs them;
- nothing wider than the task.

A writer that needs another path returns it with a reason. Add it yourself when it serves the authorized objective; ask the user only for new scope, another repository or a destructive operation. Parallel writers in one worktree must have disjoint surfaces; units that need the same file run in order or in separate worktrees.

In Claude Code and Codex, `PreToolUse` checks that the surface is present and well-formed for supported writer launches, in either mode. It recognizes a writer by the `# Role: write` brief, not by the selected model or native agent type. For Codex 0.171.0, it checks native `spawn_agent` plaintext `message` and v1 text in `items`, and literal local Orca `task-create` and `worker-start` specs in `Bash`. Relative literal `--spec-file` paths use the hook's reported cwd. A `worker-start --task` references an existing task and does not recheck its spec.

The Codex launch check cannot validate opaque native payloads, non-text briefs, remote spec paths, or launches that do not reach these hooks. It does not evaluate shell expressions to recover a spec. Where no supported hook runs, the rule is prompt-only. To check a spec manually, run `python3 -I skills/odd-flow/scripts/surface.py check <spec-file>` from the plugin root. The hook does not constrain what the writer edits. After each writer returns, compare `git diff --name-only` (or the shadow status below) against its surface and reject out-of-surface edits.

The separate [parent edit guard](mode-full-delegation.md#parent-edit-guard) checks `Edit`, `Write` and `NotebookEdit` in Claude Code full delegation and direct `apply_patch` in Codex full delegation. Neither guard covers `Bash` writes. See that section for how Claude Code Mode edits reach the guard and when an unrecognized Orca preamble leaves a worker classified as the parent.

## Files outside the workspace

In both modes, only the parent may write a file outside the workspace: the user must name the file, see the exact diff and confirm it before the write. Never delegate it. The workspace root is the Git top level, or the session's project directory without Git. Surfaces are workspace-relative; the surface parser rejects absolute and `~` paths by design. An auto-approved Codex escalation can allow a write outside the workspace, but it does not satisfy the user's exact-diff confirmation requirement.

## Shadow snapshots

In either mode, before launching a writer for a project folder without Git, set `folder` to its real path and create `G=$(mktemp -d)` outside the folder. Run `git --git-dir="$G/.git" --work-tree="$folder" init -q`, then with the same Git options run `add -A -f` and `commit --allow-empty -m "Writer baseline"` (add `-c user.name=... -c user.email=...` before `commit` if identity is missing). Use that commit as the writer's base.

The forced baseline hashes and stores every ignored file, including dependency and build files, which can be slow and take up substantial space; it also copies ignored secrets such as `.env` into the scratch Git directory that the parent removes at close.

A folder containing nested Git repositories is out of scope for shadow checks; dispatch each nested repository as its own Git workspace.

On return, compare `git --git-dir="$G/.git" --work-tree="$folder" status --porcelain --untracked-files=all --ignored` with the writer's surface; every listed path counts against the surface. A file ignored at baseline now shows as ` M` if modified, ` D` if deleted, or ` T` if its type changes (for example, if a symlink replaces the file); `!!` lists only ignored files created after the baseline. Build the candidate commit as below with the same Git options; for a shadow candidate, the parent adds the writer's paths to the temporary index with `git add -A -f -- <paths>` because plain `git add` exits 1 for a deletion inside an ignored directory and for a new `!!` file. Give `verify` the shadow Git directory with both commit pins. The parent removes `G` at close.

## What the parent passes

- `Spec: odd/tasks/<feature>.md, T<n>, S<a>-S<b>` and "read until `## Log`", or the user's request verbatim when there is no document.
- `## Allowed edit surfaces` (writers), `## Skills to load before work` with exact `SKILL.md` paths that match the task, `## Verification` with exact commands, optional `## Known environmental failures`.
- The test-first policy and runner.
- For `verify`, the parent pins and passes `Base commit` and `Candidate commit` before launch. Take the paths from the writer's report, check them against its allowed edit surface and `git status`, and use the writer's starting commit as the base, or `HEAD` if the parent committed in between. Build the candidate from the base in a temporary Git index, add only the writer's changed paths (including new files and deletions), and use `git commit-tree` to create an unreferenced commit. Do not change the real index or move a branch.

## Correction bounds

- Worker: one correction per failing check; a second only when the same check still fails; then `partial` with the diagnosed cause.
- Verifier code blockers: one correction batch that fixes every blocker, one recheck limited to those blockers, a second correction only for the same blocker still failing. A new finding never earns another round. Setup blockers return to the parent outside this bound; do not send them to a writer as code fixes.
- A worker that exhausts its bound ends its cycle, not the unit. What follows is in the active mode file (After a worker exhausts its bound).
- Spot check: re-run one command a worker reported before accepting its result.
