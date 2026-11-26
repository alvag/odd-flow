# Profiles

A profile maps roles to an Orca agent, model and effort. Profiles live in one file shared by every agent runtime:

`~/.config/odd-flow/profiles.json` (override the directory with `ODD_FLOW_HOME`).

Template: `assets/profiles.example.json`. The user may edit it by hand or through `--create-profile` and `--profile-default`; the skill never writes it without being asked, and only through `scripts/profile.py`.

## Format

```json
{
  "default": "A",
  "profiles": {
    "A": {
      "write":  { "agent": "claude", "model": "claude-sonnet-5-5", "effort": "medium" },
      "verify": { "agent": "codex",  "model": "gpt-6.2-sol",       "effort": "high" }
    }
  }
}
```

- Roles: `explore`, `write`, `verify`, `review`, `refute`. `review-risk`, `review-resilience`, `review-readability` and `review-reliability` override `review` for one lens. The optional `review-second` role selects the second reviewer for dual review and falls back to `review` if omitted.
- Every field is optional. `effort` requires `model`.
- A role missing from the profile runs with the current session's agent and that agent's own configured model (no `--model`, no `--effort`).
- No file at all behaves the same way for every role.

## Orchestrator mode

Each profile runs the parent in one of two peer modes; neither is the lesser one:

- `organic` (default): the parent makes changes itself and delegates for a named reason (`mode-organic.md`).
- `full-delegation`: the parent coordinates and never edits; a bounded writer makes every change, whatever its size (`mode-full-delegation.md`).

The mode lives in a top-level `workflow` map beside `profiles`, because a profile's keys are roles only:

```json
{
  "profiles": { "A": { "write": { "agent": "codex" } } },
  "workflow": {
    "A": { "orchestratorMode": "full-delegation" }
  }
}
```

A profile with no `workflow` entry is `organic`. A `workflow` entry for an undefined profile, an unknown field or an unknown mode makes the file invalid.

`profile.py` resolves the mode on every call, in this order:

1. `ODD_ORCHESTRATOR_MODE` in the environment (`organic` or `full-delegation`; any other value is an error).
2. Session mode written by `/odd-flow --mode <m>` (`profile.py session-mode`).
3. The selected profile's `workflow` entry.
4. `organic`.

`show`, `use`, `session-mode` and `mode` print `mode: <mode> (<source>); rules: references/mode-<mode>.md`; `list` shows each profile's saved mode. Binding a profile with `use` drops a session mode, so the new profile's own mode applies. `clear` removes both.

`profile.py list --json` prints one object with `path`, `default`, and `profiles`. Each profile has a `name`, a boolean `default` marker, its saved `mode`, and its configured `roles`. Role entries omit fields absent from the file. If the file is missing, `path` and `default` are null and `profiles` is empty.

`profile.py show --json` prints one object with `profile`, `source`, `session_key` (the variable name, not its value), `agent`, `mode`, `mode_source`, `rules`, `roles`, and `orca_terminal`. It reports the same base roles as text output, with resolved `agent`, `model`, and `effort` for each; an unset model or effort is null. Both JSON commands are read-only. A profile error goes to stderr and exits with status 2.

A switch applies from the next request, with no new session: load the mode file the latest `mode:` line names. In Claude Code the plugin's `UserPromptSubmit` hook restates the mode on every prompt of a full delegation session; organic sessions get no per-prompt line. Runtimes that receive the core block through `init` keep the organic block: there, the mode file is the only source of full delegation rules.

## Which profile applies

`profile.py` resolves it again on every call, in this order:

1. Session binding written by `/odd-flow --profile <p>`.
2. `ODD_PROFILE` in the environment.
3. `default` in the file.
4. None: every role uses the current agent and its own model.

The session binding is keyed by the first variable present:

1. `CLAUDE_CODE_SESSION_ID` (Claude Code)
2. `CODEX_THREAD_ID`, then `CODEX_SESSION_ID` (Codex)
3. `ANTIGRAVITY_CONVERSATION_ID` (Antigravity)
4. `ORCA_PANE_KEY` (any agent in an Orca pane; binds the pane, not the conversation)

With none present, `use` fails; pass `ODD_PROFILE` at launch instead.

## Commands

| User says | Do |
|---|---|
| `/odd-flow --profile B` | `profile.py use B`; report the bound line and the `mode:` line, and load the mode file it names |
| `/odd-flow --profile-default B` | `profile.py default B` (dry run), show its diff, ask to confirm; on yes, `profile.py default B --yes` |
| `/odd-flow --profiles` | `profile.py list` and `profile.py show`, which include each profile's mode; then ask one question: which profile, and whether for this session (`use`), as the default (the `--profile-default` flow), or neither |
| `/odd-flow --create-profile B` | the creation flow below |
| `/odd-flow --mode full-delegation` | `profile.py session-mode full-delegation`; report its lines and load the mode file it names. This session only; the file is untouched |
| `/odd-flow --profile-mode B full-delegation` | `profile.py set-mode B full-delegation` (dry run), show its diff, ask to confirm; on yes, the same command with `--yes`. Then run `profile.py mode` and load the mode file it names |
| "back to the default profile" | `profile.py clear` |
| check agents exist in Orca | `profile.py check` |
| remove old session bindings, prompt-hook records, and mode-notice records | `profile.py prune --days 30` |

`prune` uses file modification time (30 days by default). It scans the session
bindings and the plugin data directories for Claude Code, Codex, and Antigravity.
Resuming a pruned session uses the default profile and mode unless another override applies.

SessionStart also removes records and bindings older than 30 days. It checks
only session bindings and the current runtime's plugin data directory, at most
once every 24 hours per data directory. Without a plugin data directory, it skips
automatic cleanup. Both forms continue past failures; the hook stays silent,
while `prune` reports partial counts and errors and exits with status 2.

A bare profile name (`/odd-flow B`) is not a command: ask whether the user meant `--profile B`.

In Claude Code the plugin skill is invoked as `/odd-flow:odd-flow <command>`. In a headless session (2026-11-23) a plain `/odd-flow <command>` was not expanded as a skill call and reached the model as text; interactive sessions are unchecked. When such text arrives, treat it as the matching command.

## Creating a profile

1. Run `profile.py discover --json`. Use only the agents and models it reports. A model from a source with `verified: false` is a suggestion; say so. An agent with no models runs with its own configured model (no `model`, no `effort`).
2. Ask role by role, one question per role, in this order: `explore`, `write`, `verify`, `review`, `refute`. Each question lists the discovered agent and model options with their efforts and marks one suggested value as recommended: `explore` on a fast, low-cost model with low or medium effort; `write` on a capable mid-cost model with medium effort; `verify`, `review` and `refute` on the strongest model with high effort. Prefer an agent for `verify` that differs from `write` when more than one is available, so the verifier is independent. Offer the four `review-<lens>` overrides and `review-second` only if the user asks for them. For `review-second`, recommend an agent or model different from `review` so the two reviewers differ.
3. Never write a model the discovery did not list without saying it is unverified. Before saving, show the accepted roles in one table.
4. Write the accepted roles with the file tool to a scratch file outside the worktree, as a JSON object of role -> `{ "agent", "model", "effort" }`.
5. Run `profile.py save B --roles-file <file>` (dry run) and show the diff. If the profile exists, ask before adding `--replace`.
6. On confirmation, run the same command with `--yes`.
7. Ask one last question: the orchestrator mode, `organic` (recommended, the default) or `full-delegation`, with one line on what each does. For `full-delegation`, run `profile.py set-mode B full-delegation` (dry run), show the diff, and on confirmation the same command with `--yes`.
8. Offer `--profile B` for this session or `--profile-default B`.

## Errors

- Unknown profile name, invalid file, unknown mode, or `effort` without `model`: the script exits non-zero. Report the message and stop; never fall back to another profile silently.
- For a large task, also write `Profile: <name>` in the feature document header, and run `use <name>` again when the feature resumes in a new session.
