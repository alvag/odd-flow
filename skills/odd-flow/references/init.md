# /odd-flow init

Fallback for runtimes where the odd-flow plugin's SessionStart hook does not run. Installs the core block for the resolved orchestrator mode into the agent's global instructions file: `assets/core-block.md` for organic mode or `assets/core-block-full-delegation.md` for full delegation. Mode resolution uses `profile.py mode --json` unless you pass `--mode organic|full-delegation`. When the plugin hook already injects the block, do not also install it: the rules would load twice.

| Runtime | File |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| Codex | `~/.codex/AGENTS.md` |
| Antigravity | `~/.gemini/GEMINI.md` (shared with Gemini CLI; unconfirmed that `agy` reads it) |

The runtime is detected from the session variables; pass `--runtime` or `--target` to override.

## Steps

1. Run `python3 <skill-dir>/scripts/init.py plan` (add `--runtime <name>` when the user names another runtime).
2. Show the user the target file, mode line, any installed-mode line or warning, and the diff exactly as printed.
3. Wait for an explicit yes. Then run the apply command printed by the plan, including `--mode` and any `--runtime` or `--target` arguments. Report the backup path it prints.
4. To uninstall, run `init.py remove` with the same runtime or target arguments, without `--mode`.

The installed block is static. Re-run init after a lasting mode change, such as `/odd-flow --profile-mode` or a profile default change that selects a different mode. A session-only `/odd-flow --mode` is not a reason to re-run init.

## Rules

- The script only changes text between `<!-- odd-flow:core -->` and `<!-- /odd-flow:core -->`. Re-running replaces the block; it never duplicates it.
- It refuses files with more than one block or unbalanced markers, and symlinked targets. Report the error; do not edit the file by hand to work around it.
- Personal preferences outside the block belong to the user. Never move, rewrite or delete them.
- Edit the asset for the mode you want to change (`assets/core-block.md` or `assets/core-block-full-delegation.md`), then re-run init in each affected runtime.
