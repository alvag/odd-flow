# Engram memory

Only the parent orchestrator reads and writes Engram. Workers never call memory tools; save what their reports establish yourself. If Engram tools are missing, skip this file.

## Resolve the project once

Before the first read, call `mem_current_project` with the workspace as `cwd`. Use the returned `project` exactly. When it reports ambiguity, ask the user to pick one value; never guess or search all projects unless asked.

## When to read

| Moment | Calls |
|---|---|
| The user refers to past work ("what did we decide", "remember", "last time") | `mem_context`, then `mem_search` (1-2 keywords), then `mem_get_observation` for the full entry |
| Before redesigning something that may already be decided, or repeating an investigation | `mem_search` for the topic |
| Resuming a large feature | `mem_search` for `odd/<feature>/tasks`, `mem_get_observation`, then read the file itself and reconcile; the file wins |
| After compaction or a context reset | `mem_context` before continuing |

Do not read memory for ordinary code tasks; the source and git history are enough.

## When to write

Save right after one of these, without being asked:

- a decision with its reason;
- a bug fix with its root cause;
- a non-obvious discovery, gotcha or convention;
- a user preference or constraint that will apply again.

Format: short searchable `title`; `type` (`decision`, `bugfix`, `discovery`, `pattern`, `config`, `preference`); `content` as **What / Why / Where / Learned** with repo-relative paths. Search first: when an entry on the same topic exists, update it instead of creating a duplicate. One save per finding, not per event.

Feature-document mirror: see `tracking.md`; pass `capture_prompt: false` for it.

At a significant close or handoff, call `mem_session_summary` (goal, discoveries, accomplished, next steps, relevant files).

## Failures

- A memory call never replaces or delays the answer to the user.
- If a write fails, keep the local file, mark the mirror pending in the feature document Log, and retry at the next transition.
