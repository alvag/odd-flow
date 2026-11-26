# Session state cleanup

Objective: remove odd-flow's accumulated per-session state files automatically and on demand, and report their counts. Branch: `feat/session-cleanup`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh` (one suite: `bash tests/<name>-check.sh`).
Profile: `claude-gpt`.

## Specs

Source: GitHub issue alvag/odd-flow#15, "Clean up accumulated per-session state files automatically". The issue body wins over any summary.

- S1 (issue, verbatim, proposal item 1):
> 1. **Automatic cleanup at session start.** The SessionStart hook removes session bindings and the prompt-hook and mode-notice records older than 30 days, at most once per day (a stamp file avoids rescanning on every session start). It runs in Claude Code, Codex and Antigravity alike and needs neither Orca nor a supervisor bot. It must never fail or slow the session start: on any error, skip silently and log nothing user-facing beyond what the hook already prints.
- S2 (issue, verbatim, proposal item 2):
> 2. **`profile.py prune --days N` also covers the prompt-hook and mode-notice records**, so a user can clean up manually with another cutoff. Document it next to the existing row in `references/profiles.md`.
- S3 (issue, verbatim, proposal item 3):
> 3. **`/odd-flow check` reports the counts** of these files (read-only, no deletion), so clutter is visible without opening folders.
- S4 (issue, verbatim, risks and edge cases):
> - A session resumed more than 30 days later loses its profile or mode override and falls back to the default profile.
> - A worker session alive for more than 30 days would lose its worker record and be treated as the coordinator by the parent edit guard. Unlikely; the cutoff is the knob.
> - Only remove files odd-flow wrote, by name pattern and inside its own directories; never follow symlinks out of them.
> - Keep the 30-day default unless there is a reason to change it; consider an environment variable only if a real need appears.
- S5 (issue, verbatim, test notes):
> Approved direction by the maintainer; needs a feature document and tests (`tests/profile-check.sh` already covers `prune` failures; the hook needs a test for the once-per-day stamp and for leaving recent records).
- S6 (workstream brief, verbatim): "`/odd-flow check` (install_check.py) reports the counts of these files, read-only. Keep its JSON schema backward compatible (add fields, do not change existing ones) and keep its exit codes."
- S7 (workstream brief, verbatim, constraints):
> - Only remove files odd-flow wrote, by name pattern, inside its own directories; never follow symlinks out of them. Never touch worker-tokens (the Orca plugin prunes those) or pane width records in TMPDIR (out of scope).
> - odd-flow must keep working without Orca, without the ODD Flow Orca plugin, and without Codex or Antigravity installed.
> - Hooks change, so after the merge Codex and Antigravity need a reinstall; do not reinstall anything yourself, list it in merge_ready.
> - tests/full-delegation-check.sh pins the sha256 of core-block.md; avoid changing core-block.md unless the issue requires it.
> - Commit messages may reference the issue ("Refs #15"); code and comments must not mention issue numbers, specs or tasks.
> - Do not push and do not touch the GitHub issue; I close it after the push.
- S8 (assumption): Outside a hook, `profile.py prune` and `install_check.py` find the runtime plugin data dirs by the runtimes' own layouts, never by an inherited `CLAUDE_PLUGIN_DATA`/`PLUGIN_DATA` (an interactive shell can carry another plugin's value: this session's shell has `CLAUDE_PLUGIN_DATA` pointing at `codex-openai-codex`). Observed layouts on this machine: Claude Code `<config>/plugins/data/odd-flow-<marketplace>/` where `<config>` is `$CLAUDE_CONFIG_DIR` when set (Orca sets it to a per-profile home) and `~/.claude` (both are scanned, deduplicated); Codex `${CODEX_HOME:-~/.codex}/plugins/data/odd-flow-<marketplace>/`; Antigravity `~/.gemini/antigravity-cli/plugin_data/odd-flow/`. Only real directories (not symlinks) count; a missing runtime is skipped silently.
- S9 (assumption): Records eligible for removal are regular files (checked with `lstat`, never followed) named by the prompt hook's key format (64 lowercase hex characters, the sha256 of the session id) directly inside `prompt-sessions/` or `session-modes/`; session bindings are regular `*.json` files directly in `$ODD_FLOW_HOME/sessions/`. Age is the file's mtime. Everything else is left alone.
- S10 (assumption): At session start, each runtime's hook cleans the shared session bindings and its own plugin data dir only (the one its runtime passes in `CLAUDE_PLUGIN_DATA`/`PLUGIN_DATA`), with a 30-day cutoff. The once-per-day stamp file lives in that plugin data dir; without a plugin data dir the hook skips the automatic cleanup. The cleanup never changes the hook's output or exit code.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S4, S5, S7-S9 | `profile.py`: shared expired-state helper (bindings + prompt-hook + mode-notice records, discovered data dirs); `prune --days N` covers all; `references/profiles.md`; `tests/profile-check.sh`; CHANGELOG | orca:write (unit; shared helper first, T2/T3 reuse it) | done | RED profile-check 71/1 → GREEN 72/0 (writer); parent spot check `bash tests/profile-check.sh` 72/0; alias differential matches base; symlinked `session-modes` not followed; correction 1 (ctx_77c8d67690e4) |
| T2 | S1, S4, S5, S7, S9-S10 | SessionStart hook: once-per-day cleanup with stamp, reusing the T1 helper; hook test for the stamp and for recent records; docs; CHANGELOG | orca:write (depends on T1) | done | task_41b03be36fb6; writer RED 5 failing → GREEN 4 tests; parent spot check `bash tests/session-cleanup-check.sh` OK (4 tests), `codex-runtime-check.sh` ok |
| T3 | S3, S6-S9 | `install_check.py`: read-only counts in text and JSON (added fields only, exit codes kept); `tests/install-check.sh`; docs; CHANGELOG | orca:write (depends on T1; after T2 for CHANGELOG) | done | task_ff0a52a9ce66; writer RED (no session_state) → GREEN; parent spot check `bash tests/install-check.sh` passed; real read-only run: 15 bindings, 287 prompt-hook, 204 mode-notice records, schema v1 kept |
| T4 | S1-S10 | Independent verification of T1-T3 (Risk item 1: deletes stored files) | orca:verify (Verification trigger) | done | task_f8fc76ae2805; base e844437, candidate 0bdf751: S1-S10 met, run.sh 23/0, 1 blocker (prune errno text basename) fixed in 03e9864; recheck: byte-identical to base, run.sh 23/0 |
| T5 | S1-S10 | Review and refute after verification | orca:review, orca:refute (Review trigger) | pending | |

## Log

- L1 (user via supervisor brief, 2026-11-26): "Workstream: session-cleanup (branch feat/session-cleanup). Max approved it. Goal: implement GitHub issue alvag/odd-flow#15, \"Clean up accumulated per-session state files automatically\". Read it first: `gh issue view 15 -R alvag/odd-flow`. Treat the issue body as the spec (its three proposal items, risks and test notes), and quote it verbatim into your feature document as the requirements." (constraints quoted in S6-S7)
- L2 (2026-11-26): Classified large (brief asks for a feature document; three deliverables). Risk: item 1 (removes stored files), item 3 not touched (JSON fields added only). Base commit `e844437`.
- L4 (2026-11-26): T1 first report: profile-check 72/0; full suite 21/1 (parent-guard-check.sh S8/S12 setgid failures, reproduced by the writer on base e844437, environmental). Parent differential check found a regression: a symlinked ODD_FLOW_HOME ancestor made prune print "no session bindings" and keep an expired binding (base removed it). Correction 1 sent to the same writer (dispatch ctx_77c8d67690e4).
- L5 (2026-11-26): T1 correction GREEN. `parent-guard-check.sh` S8/S12 fail only inside the Codex writer sandbox (setgid); in the parent shell the suite passes on both base e844437 (exit 0) and the candidate. Treat as environmental for Codex writers.
- L3 (2026-11-26): Follow-up finding, out of scope: `~/.claude/plugins/data/codex-openai-codex/prompt-sessions/` exists, so some odd-flow prompt hook run wrote its record under another plugin's data dir (likely an inherited `CLAUDE_PLUGIN_DATA`). The cleanup does not touch it (S8).
