# odd-flow draft notes

Not loaded by the plugin. Decisions and open items for the next iteration.

## Decisions

- Methodology replicated from Gentle Shell v5 (ODD, verify, review core); topology uses Orca workers, not in-process subagents.
- Work inline by default; Orca workers only on named triggers (mapping, parallel writers, context backstop, named high-risk verify, review, user-named agent).
- Progressive disclosure: `SKILL.md` holds rules and the gate table; everything else loads by condition.
- Profiles: one file at `~/.config/odd-flow/profiles.json`, shared by every agent runtime. No Gentle Shell dependency, no import. Revised 2026-11-23: the user asked for profile commands and a guided creation flow; `profile.py` stays the only writer (`save`, `default`, dry run unless `--yes`), and the skill shows the diff before every write.
- Profile precedence: session binding, then `ODD_PROFILE`, then file `default`, then none (current agent, its own model).
- Session binding key: agent session id first (`CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID`/`CODEX_SESSION_ID`, `ANTIGRAVITY_CONVERSATION_ID`), `ORCA_PANE_KEY` as fallback. Verified on 2026-11-23 that all three agents expose their variable to shell commands (Codex and Antigravity in non-interactive mode only).
- Profiles are resolved by `scripts/profile.py` before every launch so a choice survives compaction.
- A failed launch never switches model or agent silently.

## Open items

- Tested 2026-11-23 with profile `claude-gpt`: Orca accepts `--agent`, `--model` and `--effort` for `claude` and `codex` (flags seen in each worker's argv). Claude workers report normally. A Codex worker started by `worker-start --agent codex` cannot report: `orca orchestration send` fails with `runtime_access_denied` (EPERM) from the Codex sandbox. Fixed by the `terminal` launch path (`scripts/codex-worker.sh`, `-c sandbox_workspace_write.network_access=true`); verified with one Codex worker that sent `worker_done`. Codex plugin manifests cannot set config or sandbox, so this cannot be done at install time. Antigravity model ids and effort are still untested.
- `scripts/codex-worker.sh` runs the `codex` binary directly, not Orca's shell `codex` function. It always passes `--no-daemon` (Codex 0.155 and older exit 2 on it; 0.171 is installed) and drops Orca's KITTY_WINDOW_ID, remote-viewer SSH_CONNECTION and WSL hook handling. It does not pin `--sandbox`: a Codex config with `sandbox_mode = "read-only"` makes the network override useless and the worker cannot report again.
- Codex workers on the `terminal` path have outbound network open in their sandbox. A narrower allowance (Codex `permissions.<name>.network.unix_sockets`) works through Codex's network proxy and is untested.
- With `--terminal`, Orca does not record the effort in the dispatch, so the worker cannot read it there; the argv still applies it. Orca does not close terminals it did not start (`worker-release` returns `reason=external_terminal`).
- A Claude worker with the Engram plugin registers its own Engram runtime session for the same project; while workers are live, the parent's `mem_save` needs `session_id` or fails as ambiguous.
- Codex model ids: `~/.codex/models_cache.json` lists the valid slugs.
- Resolved 2026-11-23: the user uninstalled the standalone gentle-ai. `~/.claude/CLAUDE.md` has no gentle-ai blocks and no gentle-ai hooks remain in Claude Code, Codex or OpenCode. `~/.codex/AGENTS.md` no longer exists, so Codex has no global instructions. `~/.gemini/GEMINI.md` still has one gentle-ai block.
- `~/.local/bin/gentle-ai` is now a wrapper to Gentle Shell's pinned binary with Gentle Shell's home. Do not run `gentle-ai sync` through it; whether it would write to `~/.claude` is unverified.
- Always-on mode, plugin (2026-11-23): `hooks/hooks.json` SessionStart (startup|resume|clear|compact) runs `scripts/session-start.py`, which injects the core block and `profile.py show`. Verified with `claude --plugin-dir` (source startup seen). Claude Code only; Codex (`.codex-plugin/`, `${PLUGIN_ROOT}`) and Antigravity (`agy plugin`) packaging pending.
- Installed 2026-11-23 via local marketplace (odd-flow@odd-flow, user scope). Removed the CLAUDE.md block (backup CLAUDE.md.bak-odd-flow-20261123-101400) and moved standalone skill to ~/.claude/skills-backup-odd-flow-20261123-101400.
- Always-on mode, fallback: `/odd-flow init` (scripts/init.py) writes `assets/core-block.md` between `<!-- odd-flow:core -->` markers in the runtime's global file. 13 scratch checks pass. Applied to ~/.claude/CLAUDE.md on 2026-11-23 (backup CLAUDE.md.bak-odd-flow-20261123-093846). Antigravity target `~/.gemini/GEMINI.md` is unconfirmed. The skill is only installed for Claude Code; Codex and Antigravity still need it in their skills folder.
- Session id behavior after `/clear` and after resuming Codex or Antigravity sessions.
- Write-surface enforcement is prompt-only; the parent checks `git diff --name-only` after each writer.
- No hook captures tool output passively into Engram as gentle-engram does; memory discipline is prompt-only here.
- Judgment Day is not replicated (Gentle Shell v5 `jd-judge-a`, `jd-judge-b`, `jd-fix-agent`): two blind judges, no refuter, a fix agent for confirmed findings, at most two rounds, survivors escalate. It runs only on explicit request and is separate from ordinary review. Deferred on 2026-11-23 until real Orca workers are validated. Other Gentle Shell agents map to odd-flow roles: explore, verify, worker -> write, the four `review-*` agents -> one `review` role with a lens, `review-refuter` -> refute.
