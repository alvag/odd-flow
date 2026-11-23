# Tracking a large task

## Feature document

Create `odd/tasks/<feature-name>.md` in the repository before the first source write, from `assets/feature-doc-template.md`. Use a descriptive, filename-safe name; never overwrite another feature's document.

Fixed section order:

1. Header, 2-4 lines: objective, branch, delivery strategy, test runner, `Profile: <name>`.
2. `## Specs`: numbered `S1..Sn`. Quote the user's exact strings, messages, commands and examples verbatim, in the user's language. Add no unrequested requirement; mark assumptions as assumptions.
3. `## Tasks`: one line per task: stable ID, linked `S#`, route (`inline` or `orca:<role>` plus trigger reason), status (`pending`, `in_progress`, `done`, `blocked`, `dropped`), commit or RED/GREEN evidence.
4. `## Log`, last: `L1` is the user's original request verbatim; later corrections verbatim with their date; evidence, decisions and next step appended.

## Changes

- A requirement change appends its verbatim Log entry, rewrites only the affected `S#`, and reopens only its task.
- Edit the document with targeted edits, never whole-file rewrites.
- Check a task off only after its outcome and checks were observed. A dropped task is never marked done.

## Engram mirror

Mirror the full document plus its repo-relative path to Engram with `topic_key: odd/<feature-name>/tasks`, at each task transition (start, done, blocked, reopened, dropped), on a material plan change, and at close. Log entries between transitions go to the file only. Load `memory.md` for the call details.

## Commits

- Work on a feature branch; create one first when on the default branch.
- Commit reviewable work units of about 400 authored changed lines with their tests and docs, as Conventional Commits that follow the repository's own rules. This is a heuristic, not a gate.
- A unit whose Risk line names a high-risk item gets its own commit.
- Record each task's commit in the document.
- Load `commit.md` for the commit procedure itself.
- Push, pull requests and merge stay with the user.
