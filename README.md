# odd-flow

Claude Code plugin for Organic Driven Development (ODD): inline-by-default work, Engram memory discipline, and Orca role workers with per-role agent, model and effort profiles. Outside an Orca terminal, delegated roles run as subagents or inline.

## Contents

| Path | Purpose |
|---|---|
| `skills/odd-flow/` | The `odd-flow` skill (progressive disclosure: `SKILL.md` plus references and assets) |
| `hooks/hooks.json` | `SessionStart` hook on startup, resume, clear and compact |
| `scripts/session-start.py` | Injects `skills/odd-flow/assets/core-block.md` and the active profile into the session |
| `.claude-plugin/` | Plugin manifest and a local marketplace |

## Install (Claude Code)

```sh
claude plugin marketplace add /Users/max/Personal/repos/odd-flow
claude plugin install odd-flow@odd-flow
```

Try it without installing: `claude --plugin-dir /Users/max/Personal/repos/odd-flow`.

The skill is invoked as `/odd-flow:odd-flow`. A plain `/odd-flow` was not expanded as a skill call in a headless session (2026-11-23) and reached the model only as text; interactive sessions are unchecked.

Profile commands: `/odd-flow:odd-flow --profile <p>` (this session), `--profile-default <p>`, `--profiles` (list, then pick one for the session or as default), `--create-profile <p>` (guided, from the agents and models Orca and Codex report).

## Profiles

File at `~/.config/odd-flow/profiles.json`, edited by hand or through the profile commands (override with `ODD_FLOW_HOME`). See `skills/odd-flow/references/profiles.md` and `skills/odd-flow/assets/profiles.example.json`.

## Other runtimes

Codex and Antigravity packaging is not done yet. Until then, `skills/odd-flow/scripts/init.py` can write the core block into their global instructions file (see `skills/odd-flow/references/init.md`).

## Checks

- `bash tests/profile-check.sh` (20 checks), `bash tests/init-check.sh` (13 checks), `bash tests/codex-launch-check.sh` (25 checks), `bash tests/profile-commands-check.sh` (44 checks) and `bash tests/context-check.sh` (11 checks)
- `claude plugin validate .`
- `echo '{"source":"startup"}' | python3 -I scripts/session-start.py`
