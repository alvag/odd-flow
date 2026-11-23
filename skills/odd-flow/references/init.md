# /odd-flow init

Fallback for runtimes where the odd-flow plugin's SessionStart hook does not run. Installs the always-on core block (`assets/core-block.md`) into the agent's global instructions file. When the plugin hook already injects the block, do not also install it: the rules would load twice.

| Runtime | File |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| Codex | `~/.codex/AGENTS.md` |
| Antigravity | `~/.gemini/GEMINI.md` (shared with Gemini CLI; unconfirmed that `agy` reads it) |

The runtime is detected from the session variables; pass `--runtime` or `--target` to override.

## Steps

1. Run `python3 <skill-dir>/scripts/init.py plan` (add `--runtime <name>` when the user names another runtime).
2. Show the user the target file and the diff exactly as printed.
3. Wait for an explicit yes. Then run `python3 <skill-dir>/scripts/init.py apply` with the same arguments and report the backup path it prints.
4. To uninstall, run `init.py remove` with the same arguments.

## Rules

- The script only changes text between `<!-- odd-flow:core -->` and `<!-- /odd-flow:core -->`. Re-running replaces the block; it never duplicates it.
- It refuses files with more than one block or unbalanced markers, and symlinked targets. Report the error; do not edit the file by hand to work around it.
- Personal preferences outside the block belong to the user. Never move, rewrite or delete them.
- Edit `assets/core-block.md` to change the block, then re-run init in each runtime.
