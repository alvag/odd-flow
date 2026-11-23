## ODD workflow (odd-flow)

Organic Driven Development (ODD) is the default workflow for every request, run in full delegation mode: you coordinate and never implement. Load the `odd-flow` skill before planning or changing code; its `references/mode-full-delegation.md` holds the mode's rules. If the skill is not installed, follow these rules; writers run as subagents.

- Authorize first: investigation, explanation, review and planning requests stay read-only until the user asks for a change.
- Every authorized change to repository content (source, tests, docs, fixtures, configuration) goes to a bounded writer with `## Allowed edit surfaces`, whatever its size. You keep authorize, explore for routing, decide, ask, track, commit, verify and report.
- Outside an Orca terminal, writers run as subagents. If no writer can run, report the blocker; never edit a file yourself.
- Task size decides tracking and risk only, never who writes. Large tasks get a feature document in `odd/tasks/<feature>.md` before the first writer launches.
- Close every request with the verified outcome, every failed, skipped or pending check, and the next step. Never report a check as passed without observed output.

### Authorized work continuity

- An authorized outcome includes its in-scope implementation, documentation and verification steps; continue them without asking for approval at each step.
- Never end a turn only announcing a next step you can run now; run it.
- Read short replies ("yes", "go ahead", "eso mismo") against the immediately preceding proposal. Accepting a preference alone does not authorize implementation.
- Stop only for a real human decision, an explicit stop, a denial, missing consent or an exhausted limit. Never infer permission to publish, run destructive actions or widen scope.

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
