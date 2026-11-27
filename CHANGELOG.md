# Changelog

This file tracks notable changes to odd-flow. It follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release headings are odd-flow versions. The ODD Flow Orca plugin is versioned
separately; see the [compatibility table](docs/compatibility.md).

## [Unreleased]

## [0.5.0] - 2026-11-26

### Added

- ODD Flow Orca plugin 0.2.0: Install and update from GitHub through an Orca catalog without cloning. The catalog install was verified live on Orca 1.4.278. Before switching from a folder install, run `orca plugin uninstall local.odd-flow-profiles --json`.
- `orca-catalog.json` lists the ODD Flow Orca plugin and pins its 0.2.0 release to the commit containing the final plugin folder.
- `bash tests/orca-catalog-check.sh` checks catalog release history offline, compares versions by SemVer precedence, and reports unreleased plugin changes or version bumps without failing. When Orca is available, it also validates the catalog and regenerates the newest entry for comparison.
- `bash tests/orca-catalog-paths-check.sh` tests catalog notices and failures in temporary Git repositories, including a changed release hash when Orca is available.
- `/odd-flow check [--json]` reports which installs match the checkout, including missing, changed, or extra shipped files and older hooks installed alongside the ODD Flow Orca plugin. It includes Orca's error for a non-running plugin when available and marks CLI calls that exceed 30 seconds as unreadable. It does not reinstall anything.
- Run `bash tests/orca-plugin-typecheck.sh` to typecheck the ODD Flow Orca plugin with TypeScript 7.0.2 and `@types/node` 26.6.10 installed in a temporary prefix with `--ignore-scripts`. The prompt-hook test imports `test` from `node:test` so it typechecks cleanly. The check skips if `orca`, `npm`, or `node` is missing and is not part of `tests/run.sh`.
- Test coverage confirms that the first-prompt hook rejects a `worker-tokens` directory owned by another user.
- A docs check keeps the README explicit that the first-prompt hook accepts only a valid, unused token for the marker's role.
- The README compares organic and full delegation side by side. Four mode-check pins tie key rows to their source rules.

### Changed

- Catalog installs now get ODD Flow Orca plugin 0.2.1, which includes the Windows APPDATA fix listed under **Fixed** below.
- Orca worker placement falls back to a tab when the split and its single retry both report the same pending timeout, and reports the orphan leaf so the coordinator can close it.
- Before accepting a worker result, the coordinator re-runs the reported command that proves the main acceptance criterion, or the RED-to-GREEN test when the writer worked test-first.
- When a worker did not report the command that proves the main acceptance criterion, the coordinator runs it from the spec's `## Verification` section and says in the close that the report left it out. The Orca dispatch and full delegation references and the README now name that command instead of any reported command.
- The close includes residual risks workers reported.
- The close counts the items a writer judged missing as residual risks, even when its `risks:` field also says `Risk: none`.
- Writer reports are capped at about 2000 tokens and cite paths, commands, and observed result lines instead of including diffs, file dumps, or full command output. Long output stays in a listed scratch file.
- `/odd-flow check` reports read-only counts of session bindings, prompt-hook records, and mode-notice records in text and JSON without changing its exit codes.
- `profile.py prune --days N` removes expired prompt-hook and mode-notice records from Claude Code, Codex, and Antigravity plugin data directories as well as expired session bindings. The default remains 30 days.
- SessionStart silently removes session bindings and the current runtime's prompt-hook and mode-notice records older than 30 days, at most once a day per plugin data directory.
- ODD Flow Orca plugin: The guide explains the odd-flow dependency and script lookup, shows how to clone from GitHub and install from the checkout, records why the direct folder URL fails in Orca 1.4.277, and keeps development loading in a separate section.
- The Orca dispatch guide explains how dependent specs reference upstream results, how to relay Antigravity's workspace trust prompt to the user, and when to use `--body-file` for messages containing backticks.
- The first-prompt hook accepts only a valid, unused token for the marker's role, issued no more than 15 minutes ago and no more than 60 seconds in the future. The hook removes the record on first use and leaves wrong-role or expired records for pruning.
- Update the ODD Flow Orca plugin and the odd-flow hooks for Claude Code, Codex, and Antigravity together. The tokened marker requires odd-flow 0.4.0 or newer hooks. With mixed versions, worker identification falls back to the Orca preamble or first-line `# Role:` rule, so the plugin still works with odd-flow 0.3.0 hooks. An older hook leaves the record to expire and be pruned.
- Install-check text: Runtime rows print `(odd-flow <installed>` instead of `(version <installed>`, and a mismatch adds `; checkout odd-flow <expected>`. The Orca row prints `(ODD Flow Orca plugin <installed>`, and a mismatch adds `; checkout ODD Flow Orca plugin <expected>`. The older-hooks warning prints `<Runtime label> (odd-flow <version>): the Orca tokened marker requires odd-flow hooks 0.4.0 or newer.` See **Fixed** below for text sanitization and the unreadable session state reason in text and JSON.
- The profiles guide explains how cleanup can reclassify a resumed coordinator as a worker, which plugin data directories and files `prune` and `/odd-flow check` match, and how to set `CLAUDE_PLUGIN_DATA` when running hooks by hand.
- `tests/orca-plugin-typecheck.sh` uses `npm ci` with a committed lockfile to pin direct and transitive dependencies.

### Fixed

- Disable Engram for Claude split and tab workers and for Codex workers, without changing user settings or requiring Engram to be installed.
- The ODD Flow Orca panel hides finished runs after 12 hours without activity. It keeps runs with open tasks, active dispatches, or tasks it could not load.
- When a terminal changes sessions, the ODD Flow Orca panel uses an in-memory cutoff to hide earlier finished runs and dispatches and exclude earlier finished tasks from feature document ownership. Active workers and their attention items remain visible.
- The ODD Flow Orca plugin acknowledges agent and workspace events without waiting for the status refresh, so event bursts no longer pile up behind it.
- The ODD Flow Orca plugin sets `APPDATA` to `<home>\AppData\Roaming` for its child processes on Windows when Orca starts it with `APPDATA` missing or empty, so the Orca CLI can find its data folder and the panel no longer reports `APPDATA is not set`. An existing value is kept, and other platforms are unchanged.
- When an Orca CLI, Python, or Git call made by the ODD Flow Orca plugin times out, the message now reports the limit actually applied, such as `0.25 seconds` near the 60-second dispatch scan cap, instead of always saying 5 seconds.
- `orca plugin test orca-plugin` passes on Windows. Tests that depend on POSIX behavior (0700 token directories, setgid and sticky bits, directory symlinks, the executable bit, shell-script fixtures, and newlines in file names) are skipped on Windows with the reason, and the token-issuance log assertions compare the JSON-escaped directory so they also hold for Windows paths.
- `/odd-flow check` sanitizes paths, file names, reasons, and Orca plugin errors in text output, stripping Unicode format characters and truncating plugin errors longer than 200 characters with `...`. Unreadable session state now includes a reason in text and JSON; other JSON output is unchanged.
- `profile.py` reports an odd-flow error instead of a traceback when `prune` lacks directory descriptor support or when `use` or `session-mode` cannot write session state. `prune` reports an unreadable plugin data root once per root.
- SessionStart treats future-dated cleanup stamps as stale and limits automatic cleanup to 1 second. If it reaches the limit, it leaves the stamp unchanged so cleanup resumes at the next session start.
- The Orca dispatch guide explains why Codex can ask for hook approval again after a reinstall: it hashes the whole plugin bundle, including `.git/`, not just the hooks.
- Before reading worker token records, the first-prompt hook rejects a relative `ODD_FLOW_STATE_DIR` and requires a real `worker-tokens` directory (not a symlink), mode `0700`, owned by the running user.
- The ODD Flow Orca plugin applies the same directory checks before issuing tokens, checking ownership where the platform exposes the user ID. If issuance fails, it leaves the prompt unchanged and logs the role, reason, and directory without including the token.
- Orca terminal calls during worker placement time out after 30 seconds so a hung call does not hold the pane lock indefinitely.
- During worker placement, the initial Orca split and its single retry time out after 40 seconds so Orca can finish its own 30-second wait; other placement calls keep the 30-second limit.
- Orca worker placement timeout errors name the split target and direction or the new tab's worktree, plus the intended title, so coordinators can identify and close late terminals.
- Unparseable Orca placement replies and replies without a handle now include the same placement context as timeouts.
- When Orca reports a split timeout with a pending leaf ID, worker placement waits once for that pane under the same lock instead of starting another split.
- If that split retry fails, the placement error keeps the original leaf ID and Orca message so the late pane can be identified.
- Uncertain Orca tab creation errors include the pre-create terminal handles so late tabs can be recovered without relying on titles.
- Orca lists up to 1,000 terminals in the current worktree before creating a worker tab, reducing incomplete baselines without guessing when the list is unavailable.
- Orca worker placement ignores saved terminal widths with timestamps in the future.
- The Orca terminal dispatch guide explains how to create and reuse an orchestration Run before creating Tasks.
- The Codex plugin check (`tests/codex-plugin-check.sh`) passes when the checkout is reached through a symlinked path, such as a temporary worktree under `/var` on macOS.
- Tests that create scratch directories honor `TMPDIR` and remove those directories on exit.
- `tests/parent-guard-check.sh` prints `SKIP` with the reason when `chmod` cannot set setgid on the worker-token directory, as can happen in the Codex workspace-write sandbox. When setgid is retained, the test still checks that the guard rejects the directory.

## [0.4.0] - 2026-11-25

### Changed

- Orca placement opens a fresh split pane or tab for each Claude, Codex, and Antigravity worker launch, using the current layout and terminal width.
- Orca placement reports the resolved role, agent, model, and effort so coordinators can catch a profile mismatch before dispatching a worker.
- Orca placement can reuse the width measured before a successful right split for up to 10 minutes after that split, when the parent is alone in its tab again but still reports a narrow width.
- Stops and limits apply only to the work they name; independent authorized work continues.
- Writers make only the changes the spec requires, reported bugs are reproduced before fixing, and testable changes need observed local proof before a requested push, pull request or deploy.
- Writers follow the project's conventions, justify additions, use documented build, test and run commands, keep verification proportional, and add only necessary comments. Verifiers use documented commands as written in their probe copy without building a replacement environment.
- The ODD Flow Orca plugin uses `agent.prompt.before` to append a worker marker to orchestration dispatches, so workers can still be identified if the Orca preamble changes. Reinstalling the plugin requires a new approval.
- ODD Flow Orca plugin: Issues worker token records under `~/.odd-flow/worker-tokens/` by default, or under `$ODD_FLOW_STATE_DIR/worker-tokens/` when set and non-empty. The token must match the marker's role. The first-prompt hook in Claude Code, Codex, and Antigravity removes the record on first use, even when another rule already identifies the worker. Bare markers no longer identify workers.
- When Engram `mem_save` or `mem_session_summary` fails, the parent saves the same entry with the `engram` CLI and reports a failed save if the CLI is missing.

## [0.3.0] - 2026-11-25

### Added

- `profile.py list --json` and `profile.py show --json` for tools that read saved profiles and effective session settings.
- A one-time notice on the next coordinator prompt when the effective mode changes, so the previous mode's rules no longer apply.
- [ODD Flow Orca plugin](orca-plugin/README.md): Adds a sidebar panel for switching session profiles and modes, a status bar item, and commands to open the panel or toggle a sole coordinator's mode. Worker rows are read-only and show only their title line.
- ODD Flow Orca plugin: **Reset to defaults** in the Orca panel removes a session's profile and mode overrides.
- ODD Flow Orca plugin: The commands log their outcomes, and the status item keeps its text and tooltip within Orca's length limits.
- ODD Flow Orca plugin: The panel, status tooltip, and **Toggle mode** command explain how to update an installed odd-flow script that lacks the JSON flags.

## [0.2.0] - 2026-11-24

### Added

- Dual review on explicit request: “revisión dual”, “dual review”, “doble revisión”, “sométela a juicio”, or “ponla a juicio”. Two blind generalist reviewers assess the same change. Blockers and critical findings both reviewers identify skip refutation. Re-checks cover only corrected findings, with at most two correction rounds. The close reports `Review: done (dual)`.
- Optional `review-second` profile role to select the second reviewer. It falls back to `review` when unset.

## [0.1.0] - 2026-11-24

### Added

- Native plugins for Claude Code, Codex, and Antigravity, with shared workflow instructions and GitHub installation steps.
- Per-role agent, model, and effort profiles, with commands to create, list, and switch profiles and workflow modes.
- Organic and full-delegation modes, with context-aware delegation, bounded writer scopes, and supported launch and parent edit guards.
- Orca worker dispatch in tabs or split panes, with subagent fallback outside Orca and inline work in organic mode when subagents are unavailable.
- Engram memory rules and role-specific instructions for writing, verification, and review. High-risk verified changes trigger review without a second prompt, and the close reports the review status.

### Fixed

- Apply worker role instructions instead of coordinator rules in dispatched Codex sessions, and run Antigravity's turn hook on its first invocation.
- Wait for Orca pane width to settle before choosing a tab or split.
- Report unreadable profile and session files explicitly, and remove global workflow instructions with an atomic file update.
