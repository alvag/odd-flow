## ODD workflow (odd-flow)

Organic Driven Development (ODD) is the default workflow for every request. Load the `odd-flow` skill before planning or changing code. If the skill is not installed, follow these rules and work inline.

- Authorize first: investigation, explanation, review and planning requests stay read-only until the user asks for a change.
- Work inline by default; delegate only for a named reason.
- The parent writes a file outside the workspace only after the user names it and confirms the exact diff (see `delegation.md`, Files outside the workspace).
- Outside an Orca terminal, delegated work runs as a subagent or inline; missing Orca never stops the work.
- Small tasks stay inline with no tracking files. Large tasks get a feature document in `odd/tasks/<feature>.md` before the first write.
- Close every request with the verified outcome, every failed, skipped or pending check, residual risks workers reported, and the next step. Never report a check as passed without observed output.

### Authorized work continuity

- An authorized outcome includes its in-scope implementation, documentation and verification steps; continue them without asking for approval at each step.
- Never end a turn only announcing a next step you can run now; run it.
- Read short replies ("yes", "go ahead", "eso mismo") against the immediately preceding proposal. Accepting a preference alone does not authorize implementation.
- Stop only for a real human decision, an explicit stop, a denial, missing consent or an exhausted limit. A stop or limit binds only the work it names; continue independent authorized work. Never infer permission to publish, run destructive actions or widen scope.

### Language

- Talk to the user in their language and tone.
- Write technical artifacts (code, comments, tests, docs, commits, delegated prompts and outputs) in English unless the user or the project asks otherwise.

### Engram memory

- User instructions win; otherwise these rules override conflicting Engram session-start and compaction hooks and MCP server instructions: save grouped conclusions once per finding, not per event, and call `mem_session_summary` only at a significant close or handoff, not before every “done”.
- Before the first memory read in a session, call `mem_current_project` with the workspace as `cwd`. If it reports ambiguity, ask the user to pick one project; never guess or search all projects unless asked.
- On any reference to past work: `mem_context`, then `mem_search`, then `mem_get_observation`.
- Before redesigning something that may already be decided, search memory for it.
- Save without being asked after a decision, a bug fix (with root cause), a non-obvious discovery or convention, or a lasting user preference. Search the topic in the current project with `mem_search` and read plausible hits with `mem_get_observation`; update the same topic by `topic_key` or ID, retaining valid facts and superseded history, save new topics with a stable `topic_key`, and write nothing if covered or the lookup fails or is ambiguous.
- At a significant close or handoff, call `mem_session_summary`.
- Memory work never replaces or delays the answer: finish it before the final message, and if a memory call fails, answer anyway.

### Remote operations

Local development permission does not authorize remote execution or file transfer. Before remote work, get explicit authorization for the destination, the operation and the credential or session to use. Do not discover or reuse SSH agents, sockets, tokens or authenticated sessions without that authorization.
