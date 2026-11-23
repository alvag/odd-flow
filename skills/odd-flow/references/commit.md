# Committing

Load before creating, amending or proposing a commit. Only the parent commits (Hard Rule 6); workers never stage or commit.

## Precedence

1. The user's instructions, including a commit skill of their own: when the runtime lists one, follow it instead of this file.
2. The repository's rules: contributing guide, commitlint or hook config, recent history.
3. This file.

## Steps

1. Run `git diff --staged`. If it is empty, show `git status`, ask which paths to stage, and stage exactly those paths. Never run `git add -A`, `git add .` or `git commit -a` on your own. Keep existing staging as it is; never add files to it.
2. Scope: a ticket the user named, else the first match of `[A-Z][A-Z0-9]+-\d+` in `git branch --show-current`. None found: ask once whether to add one; otherwise omit the scope.
3. Read `git log --oneline -5` and follow the repository's style when it has history.
4. Compose the message (format below).
5. Show the staged files and the proposed message, and ask for confirmation. Commit only after approval. When the user already approved this commit ("commit directly"), show the summary and commit without asking again.
6. Write the message with the file tool to a scratch file outside the worktree, then run `git commit -F <file>`. Never pass a multi-line message through a heredoc or here-string: some agent shells and Orca terminals hang on them, and a delimiter inside the text ends them early. Verify with `git log -1 --format='%h %s'` and `git status --porcelain`, and report the hash.

## Message format

- Header: `type(SCOPE): subject`, or `type: subject` without a scope; under 72 characters.
- Types: feat, fix, docs, style, refactor, test, chore, perf, ci, build, revert.
- Subject: imperative present ("add", not "added"), lowercase, no trailing period.
- Body: only when the change spans several concerns; one bullet per concern.
- Trailers (`Co-Authored-By`, sign-off, attribution lines): add only what the user's or repository's rules ask for; when they forbid trailers, add none.
- Language: English unless the user or the repository asks otherwise.

## Failures

- A pre-commit hook fails: show the error and stop. Never retry with `--no-verify` unless the user asks.
- A failed hook created no commit: after the fix, re-stage and create a new commit. Never `--amend`, which would rewrite the previous commit.

## Amend

- First check whether `HEAD` is published: `git branch -r --contains HEAD`. Non-empty output means amending rewrites shared history; warn and get explicit confirmation.
- `--amend`: read `git log -1 --format=%B` and `git diff --staged`, propose a message that covers the old and new changes, confirm, then write it to a scratch file and run `git commit --amend -F <file>`.
- `--amend --no-edit`: show the staged files and the current message, confirm, then run `git commit --amend --no-edit`.

## Scope of this file

Branching, unit size and recording commits in the feature document live in `tracking.md`. Push, pull requests and merge stay with the user.
