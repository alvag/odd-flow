# Profiles

A profile maps roles to an Orca agent, model and effort. Profiles live in one file shared by every agent runtime:

`~/.config/odd-flow/profiles.json` (override the directory with `ODD_FLOW_HOME`).

Template: `assets/profiles.example.json`. The user writes it by hand; the skill never creates it without being asked.

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

- Roles: `explore`, `write`, `verify`, `review`, `refute`. `review-risk`, `review-resilience`, `review-readability` and `review-reliability` override `review` for one lens.
- Every field is optional. `effort` requires `model`.
- A role missing from the profile runs with the current session's agent and that agent's own configured model (no `--model`, no `--effort`).
- No file at all behaves the same way for every role.

## Which profile applies

`profile.py` resolves it again on every call, in this order:

1. Session binding written by `/odd-flow <profile>`.
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

| User says | Run |
|---|---|
| `/odd-flow B` | `profile.py use B` |
| `/odd-flow profiles` | `profile.py list`, then `profile.py show` |
| "back to the default profile" | `profile.py clear` |
| check agents exist in Orca | `profile.py check` |
| remove old session bindings | `profile.py prune --days 30` |

## Errors

- Unknown profile name, invalid file, or `effort` without `model`: the script exits non-zero. Report the message and stop; never fall back to another profile silently.
- For a large task, also write `Profile: <name>` in the feature document header, and run `use <name>` again when the feature resumes in a new session.
