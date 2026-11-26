# Engram memory

Only the parent orchestrator reads and writes Engram. Workers never call memory tools; save what their reports establish yourself. If Engram tools are missing, skip this file.

Worker launches disable the Engram plugin where the runtime allows it. See [Orca dispatch limits](orca-dispatch.md#limits) for the paths that cannot be isolated.

User instructions win; otherwise these rules override conflicting Engram session-start and compaction hooks and MCP server instructions: save grouped conclusions once per finding, not per event, and call `mem_session_summary` only at a significant close or handoff, not before every “done”.

## Resolve the project once

Before the first read, call `mem_current_project` with the workspace as `cwd`. Use the returned `project` exactly. When it reports ambiguity, ask the user to pick one value; never guess or search all projects unless asked.

## When to read

| Moment | Calls |
|---|---|
| The user refers to past work ("what did we decide", "remember", "last time") | `mem_context`, then `mem_search` (1-2 keywords), then `mem_get_observation` for the full entry |
| Before redesigning something that may already be decided | `mem_review` with `action: list` and the resolved `project`, then `mem_search` for the topic |
| Before repeating an investigation | `mem_search` for the topic |
| Resuming a large feature | `mem_search` for `odd/<feature>/tasks`, `mem_get_observation`, then read the file itself and reconcile; the file wins |
| After compaction or a context reset | `mem_context` before continuing |

Do not read memory for ordinary code tasks; the source and git history are enough.

Engram gives each observation a `review_after` date. `mem_review` with `action: list` returns observations past that date. Run it only before a redesign as described above, not at session start. Never call `mem_review` without the resolved `project`.

Treat any observation past its `review_after` date or returned by `mem_review list` as possibly stale context, not a trusted fact. Tell the user it was stale and verify it against current code or docs before relying on it. Call `mem_review` with `action: mark_reviewed` only after the user confirms the memory still holds.

## When to write

Save right after one of these, without being asked:

- a decision with its reason;
- a bug fix with its root cause;
- a non-obvious discovery, gotcha or convention;
- a user preference or constraint that will apply again.

Format: short searchable `title`; `type` (`decision`, `architecture`, `bugfix`, `pattern`, `config`, `discovery`, `learning`; use `decision` or `learning` for preferences); stable `topic_key`; `content` as **What / Why / Where / Learned** with repo-relative paths.

1. Use `mem_search` for the topic in the current project and intended scope.
2. Read plausible hits in full with `mem_get_observation`; snippets cannot establish topic identity.
3. For the same topic, use `mem_save` with the existing `topic_key` (Engram upserts on project + scope + topic_key), or `mem_update` by ID with the required `expected_project`. Load `mem_update` first if the runtime defers it. Keep every still-valid fact and record superseded facts as history in the content.
4. For a new topic, use `mem_save` with a deliberate, stable `topic_key`. If the fact is already covered, write nothing.
5. A failed or ambiguous lookup does not establish absence. Do not overwrite blindly or fall back to a new save.

After accepting a worker report, save its `learnings` using this topic workflow. Drop entries without evidence.

Feature-document mirror: see `tracking.md`; pass `capture_prompt: false` for it.

When a code-execution tool is available (for example, Claude Code's Code Mode REPL), refresh the mirror in one script: read the file and pass its text directly to `mem_save` so the model never retypes the document in the call or emits it as output tokens. Use the same `topic_key` each time. After an uncertain acknowledgement, check whether the write applied before retrying; never replay an applied write.

At a significant close or handoff, call `mem_session_summary` (goal, discoveries, accomplished, next steps, relevant files).

## When `mem_save` fails

If `mem_save` or `mem_session_summary` fails, for example with "multiple active runtime sessions match" while a Claude worker with the Engram plugin is live, save the same entry with the `engram` CLI:

1. Do the topic lookup above with `mem_search` and `mem_get_observation`; they take no `session_id`, so the failure does not affect them. `engram search` prints only previews and cannot replace `mem_get_observation`.
2. Write the full entry to a scratch file outside the workspace. `engram save` on an existing `topic_key` replaces the whole content, so the file holds the merged text with every still-valid fact.
3. Run `engram save "<title>" "$(cat <scratch file>)" --project <project> --type <type> --topic <topic_key>`. Put only the file read inside `$(...)`: an `engram` command there can write the CLI usage text into the record. For a session summary, use `--type session_summary` without `--topic`.
4. The CLI returns no `judgment_required` and records no conflict candidates, so the lookup in step 1 is the only overlap check.
5. If the `engram` CLI is missing or its save fails, report that the save failed; do not try another path.

## Conflicts after a save

A save can return `judgment_required` with `candidates`, existing entries that may overlap the new one. Resolve them before the final message:

- Judge each candidate by its own `candidates[].judgment_id`; never reuse the top-level `judgment_id` for all of them. Prefer the batch call (`mem_judge_many`) when there are several.
- Ask the user, in one question, when you are unsure of the relation, or when it would be `supersedes` or `conflicts_with` on a `decision`, `architecture` or `policy` entry. Otherwise record `related`, `compatible`, `scoped` or `not_conflict` yourself, with a one-line reason.
- When the new entry replaces an old one, update or supersede the old entry instead of leaving two live versions.
- Use the Engram server's instructions for details not covered here.

## Failures

- A memory call never replaces or delays the answer to the user.
- If a mirror write fails, keep the local file, mark the mirror pending in the feature document Log, and retry at the next transition only if the write did not apply.
