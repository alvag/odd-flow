# odd-flow

Claude Code plugin for Organic Driven Development (ODD): inline-by-default work, Engram memory discipline, and Orca role workers with per-role agent, model and effort profiles.

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

The skill is invoked as `/odd-flow:odd-flow`.

## Profiles

Hand-written file at `~/.config/odd-flow/profiles.json` (override with `ODD_FLOW_HOME`). See `skills/odd-flow/references/profiles.md` and `skills/odd-flow/assets/profiles.example.json`.

## Other runtimes

Codex and Antigravity packaging is not done yet. Until then, `skills/odd-flow/scripts/init.py` can write the core block into their global instructions file (see `skills/odd-flow/references/init.md`).

## Checks

- `bash tests/profile-check.sh` (20 checks) and `bash tests/init-check.sh` (13 checks)
- `claude plugin validate .`
- `echo '{"source":"startup"}' | python3 -I scripts/session-start.py`
