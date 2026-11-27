# Worker spec template

Fill every `<...>`. Delete sections that do not apply to the role. Keep the headings exactly as written: the role prompts refer to them.

```markdown
# Role: <explore | write | verify | review | refute>

<paste the body of assets/roles/<role>.md here>

## Task

Spec: odd/tasks/<feature>.md, T<n>, S<a>-S<b>. Read the document until "## Log".
<or, without a feature document: the user's request, verbatim>

<one or two lines of task-specific instruction from the parent>

## Repository

Path: <absolute repo path>
Base commit: <sha>          # verify, review, refute
Candidate commit: <sha>     # verify, review, refute

## Allowed edit surfaces

<repo-relative path or narrow glob, one per line>

## Reuse and invariants

<existing helpers to reuse for shared state, and the invariants they keep>

## Skills to load before work

<exact SKILL.md paths that match this task, one per line>

## Verification

<exact commands to run, one per line>

## Known environmental failures

<exact test names or command lines already failing on the base>

## Reporting

When reporting (`worker_done`) or asking (`question`) through `orca orchestration send`, write the message body with your file tool (never heredocs) to a scratch file in the OS temp directory outside the repository (`$TMPDIR` or `/tmp` on macOS/Linux, `%TEMP%` on Windows) and pass its literal path with `--body-file`; never put report or question text in `--body` (double-quoted backticks trigger shell command substitution and break Antigravity permission matching). This scratch file is allowed even under a no-edit rule.

## Language

Write every artifact (code, comments, tests, docs, reports) in English unless this spec says otherwise.
```
