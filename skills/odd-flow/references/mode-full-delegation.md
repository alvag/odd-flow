# Full delegation mode

Load this file when the `mode:` line of `profile.py show` says `full-delegation`. It is the only mode file a session loads; the latest `mode:` line wins over the rules injected at session start.

You are a coordinator: you never implement.

## Who writes

- Every authorized change inside the workspace goes to a bounded writer, whether the workspace is a Git repository or a project folder without Git. The root is the Git top level, or the session's project directory without Git. If no writer can run, report that blocker; never edit a file yourself.
- The parent writes only: scratch files outside the workspace (specs, messages, temporary indexes); `odd/tasks/*.md`; Engram; Git operations (stage, commit, merge, candidate commits); files written by `scripts/profile.py` or `scripts/init.py` after the user confirms their diff; scratch cleanup. Delegate all other workspace writes.
- For a requested file outside the workspace, the parent follows `delegation.md` (Files outside the workspace), never delegates it.
- You authorize, explore for routing, decide, ask, track (the feature document and its Engram mirror), commit, verify and report. Reads, `git` state checks and the spot check are yours.
- Task size decides tracking and risk only, never who writes. A small task gets a writer and no feature document; a large task also gets the feature document before the first writer launches.
- One writer per unit of behavior (`delegation.md`, Units), never launched while a unit it depends on still runs. Every launch carries `## Allowed edit surfaces`.
- Independent units with disjoint surfaces launch together in one turn; units that need the same file run one at a time.
- Fixes within a worker's correction bound continue the same worker (an Orca reply, or a message to the same subagent), never a new worker per fix. The exception is a closed Codex writer terminal: follow [When Orca wakes you](orca-dispatch.md#when-orca-wakes-you); the relaunch counts as the correction against the original worker's bound.
- Reading that prepares a writer belongs in that writer's spec, not in your context.

## Worker prompt context

In Claude Code, Codex and Antigravity, the prompt hook marks a session as a worker when its first prompt starts with a known Orca dispatch preamble or a recognized `# Role:` header, or when its last non-empty line is a valid `odd-flow-worker: <role> <token>` marker. If the prompt ends with a `</pasted_content id="...">` closing tag (an unquoted ID is also accepted), the hook skips that one line and checks the previous non-empty line instead.

The ODD Flow Orca plugin issues a token and appends the marker when an orchestration dispatch contains a recognized `# Role:` line anywhere in the prompt. The hook strips surrounding whitespace from the marker line, matches roles using ASCII case folding (`explore`, `write`, `verify`, `review`, `refute`), and requires exactly 32 lowercase hexadecimal characters for the token. The record must match the role, be no more than 15 minutes old and no more than 60 seconds in the future, and be removed successfully by the hook. The hook consumes a valid token on the first prompt even when the preamble or first-line role header already identifies the worker. Records live under `~/.odd-flow/worker-tokens/` by default, or under `$ODD_FLOW_STATE_DIR/worker-tokens/` when the variable is non-empty and absolute. The hook reads no record if `ODD_FLOW_STATE_DIR` is relative or if `worker-tokens` is not a real directory (not a symlink) owned by the running user with permissions exactly `0700`. Bare markers and invalid or already-used tokens do not identify a worker.

Starting with that prompt, full-delegation workers get a reminder to follow their spec's role rules instead of the coordinator rules from session start. Parent sessions and sessions without a marker keep the coordinator reminder. Organic sessions get no context except the one-time mode-change notice for parents. In Antigravity, the `PreInvocation` hook reads `conversationId` and `lastUserInput`, stores the marker under `PLUGIN_DATA`, and injects context only on the first invocation of each turn (`invocationNum == 0`; the counter is 0-indexed in `agy` 1.5.16, and the default is `0` when `invocationNum` is omitted or `None`); other invocations (1, 2, ...) and malformed input get an empty `injectSteps`.

## Parent edit guard

In Claude Code, the guard checks the parent's `Edit`, `Write` and `NotebookEdit` targets in full delegation only. After resolving symlinks, it allows workspace Markdown files directly under `odd/tasks/` and denies other workspace targets. It leaves targets in system temp directories outside the workspace alone and asks for confirmation on any other external target. The confirmation rule above still applies.

Native subagent calls and marked worker sessions are exempt. The prompt hook records the [first-prompt decision](#worker-prompt-context) under `CLAUDE_PLUGIN_DATA` in Claude Code. A valid token appended by the ODD Flow Orca plugin can identify a worker even when the Orca preamble changes. Without a valid token, including when the plugin is not installed, a worker whose first prompt has neither a recognized Orca preamble nor a first-line role header is treated as the parent.

The guard does not cover writes through `Bash`, including `sed -i` and shell redirection. The guard covers `Edit`, `Write` and `NotebookEdit` with Code Mode on or off. Code Mode REPL `write()` and `edit()` reach the hook as `Write` and `Edit`.

In Codex 0.171.0, the guard checks the coordinator's direct local `apply_patch` calls in full delegation. It uses the same path rules, checking every hunk, both endpoints of a move, and both a final symlink and its referent. One prohibited or unclassifiable target denies the entire invocation. A direct patch outside the workspace and system temp is denied with the named-file and exact-diff requirement: Codex `PreToolUse` does not support `ask`. If the hook cannot resolve the mode, it denies the parent's direct patch. An invalid `profiles.json`, for example, can trigger this denial even in a session intended to run in organic mode.

Codex reads the recorded first-prompt decision under `PLUGIN_DATA` for Orca workers. The tagged runtime also supplies `agent_id` for native `ThreadSpawn` calls; those children are exempt when the hook delivers that field. Without a first-prompt decision that records the session as a worker or a runtime-supplied native `agent_id`, the guard treats an Orca Codex child as the parent. The guard does not infer worker identity from model, agent type or shell environment.

In Antigravity 1.5.16, the `PreToolUse` guard checks the parent's `write_file`, `edit_file`, `write_to_file`, `replace_file_content` and `multi_replace_file_content` targets (`Path` or `TargetFile`) in full delegation, with the same path rules as Claude Code and both a final symlink and its referent checked. Workspace `odd/tasks/*.md` and system temp are allowed, other workspace targets are denied, and an external target returns `force_ask` with the named-file and exact-diff requirement. Marked workers are exempt through the `PLUGIN_DATA` marker; an unresolved mode denies the edit. Shell writes (`run_command`) are not covered. Live checks on 2026-11-24 (installed odd-flow 0.2.0 matching `main` `edcf3e0`, interactive `agy` 1.5.16 in Orca) denied the coordinator's workspace `edit_file` without changing the file and showed a Create file confirmation for an external non-temp `write_file` (`force_ask`); declining left the file absent. In a new session, a first prompt starting with `# Role: write` in a plain Orca terminal exempted the worker's `edit_file`. The tool names `write_to_file`, `replace_file_content` and `multi_replace_file_content` come from the contract and remain untested live. On 2026-11-25, the `PreInvocation` hook marked an Orca-dispatched Antigravity worker as a worker with `agy` 1.5.17 and Orca 1.4.274.

The Codex guard does not cover shell writes, including patches executed through the shell, and does not claim coverage of remote execution or specialized paths that do not dispatch these hooks. The manifest's `Bash` and `spawn_agent` matchers are for [writer launch admission](delegation.md#allowed-edit-surfaces), not write enforcement.

## Writer spec

- Pass the user's request verbatim, or `Spec: odd/tasks/<feature>.md, T<n>, S<a>-S<b>`, as `delegation.md` (What the parent passes) says.
- The writer runs the checks under `## Verification` and reports `<command>: <observed result>`, observing RED before it writes when a test applies.
- For folders without Git, follow `orca-dispatch.md` (Project folders without Git) and `delegation.md` (Shadow snapshots).
- After it returns: re-run one reported command as a spot check and check the surface as `delegation.md` says. Its Verification trigger still adds one independent `verify` when the Risk line names a high-risk item.

## Without Orca

- The writer runs as a subagent (`orca-dispatch.md`, Without Orca, step 1).
- When no subagent can run, report the blocker for each pending unit and stop it; never edit a file yourself.
- A `verify`, `review` or `refute` with no subagent: you run it yourself, since it only reads, and say in the close that it was not independent.
- Print the notice with `fallback: subagent` or `fallback: blocked`, and record the route as `subagent:<role>` or `blocked` in the feature document.

## Feature-document routes

A task's route is `orca:<role>`, `subagent:<role>` or `blocked`.

## After a worker exhausts its bound

Launch one new bounded writer with the diagnosis, the new evidence and a changed hypothesis or scope; never edit. A repeated cause blocks the unit.

## Review correction

One `write` worker writes it, with the corrected findings as its spec and the candidate's paths as its surface.

## Switching mode

The user switches with `/odd-flow --mode organic` (this session only) or `/odd-flow --profile-mode <p> organic` (saved in the profile). On the next prompt, the hook sends the parent a one-time notice that the previous rules no longer apply. Load `mode-organic.md` instead of this file; no new session is needed.
