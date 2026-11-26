# Changelog

This file tracks notable changes to odd-flow. It follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `/odd-flow check [--json]` reports which installs match the checkout, which shipped files differ, and whether older hooks are installed alongside the ODD Flow Orca plugin. It does not reinstall anything.
- Run `bash tests/orca-plugin-typecheck.sh` to typecheck the ODD Flow Orca plugin with TypeScript 7.0.2 and `@types/node` 26.6.10 installed in a temporary prefix with `--ignore-scripts`. The prompt-hook test imports `test` from `node:test` so it typechecks cleanly. The check skips if `orca`, `npm`, or `node` is missing and is not part of `tests/run.sh`.
- Test coverage confirms that the first-prompt hook rejects a `worker-tokens` directory owned by another user.
- A docs check keeps the README explicit that the first-prompt hook accepts only a valid, unused token for the marker's role.

### Changed

- The Orca dispatch guide explains how dependent specs reference upstream results, how to relay Antigravity's workspace trust prompt to the user, and when to use `--body-file` for messages containing backticks.
- The first-prompt hook accepts only a valid, unused token for the marker's role, issued no more than 15 minutes ago and no more than 60 seconds in the future. The hook removes the record on first use and leaves wrong-role or expired records for pruning.
- Update the ODD Flow Orca plugin and the odd-flow hooks for Claude Code, Codex, and Antigravity together. The tokened marker requires hooks at 0.4.0 or newer. With mixed versions, worker identification falls back to the Orca preamble or first-line `# Role:` rule, so the plugin still works with 0.3.0 hooks. An older hook leaves the record to expire and be pruned.

### Fixed

- The Orca dispatch guide explains why Codex can ask for hook approval again after a reinstall: it hashes the whole plugin bundle, including `.git/`, not just the hooks.
- Before reading worker token records, the first-prompt hook rejects a relative `ODD_FLOW_STATE_DIR` and requires a real `worker-tokens` directory (not a symlink), mode `0700`, owned by the running user.
- The ODD Flow Orca plugin applies the same directory checks before issuing tokens, checking ownership where the platform exposes the user ID. If issuance fails, it leaves the prompt unchanged and logs the role, reason, and directory without including the token.
- Orca terminal calls during worker placement time out after 30 seconds so a hung call does not hold the pane lock indefinitely.
- Orca worker placement timeout errors name the split target and direction or the new tab's worktree, plus the intended title, so coordinators can identify and close late terminals.
- Orca worker placement ignores saved terminal widths with timestamps in the future.
- The Orca terminal dispatch guide explains how to create and reuse an orchestration Run before creating Tasks.
- The Codex plugin check (`tests/codex-plugin-check.sh`) passes when the checkout is reached through a symlinked path, such as a temporary worktree under `/var` on macOS.

## [0.4.0] - 2026-11-25

### Changed

- Orca placement opens a fresh split pane or tab for each Claude, Codex, and Antigravity worker launch, using the current layout and terminal width.
- Orca placement reports the resolved role, agent, model, and effort so coordinators can catch a profile mismatch before dispatching a worker.
- Orca placement can reuse the width measured before a successful right split for up to 10 minutes after that split, when the parent is alone in its tab again but still reports a narrow width.
- Stops and limits apply only to the work they name; independent authorized work continues.
- Writers make only the changes the spec requires, reported bugs are reproduced before fixing, and testable changes need observed local proof before a requested push, pull request or deploy.
- Writers follow the project's conventions, justify additions, use documented build, test and run commands, keep verification proportional, and add only necessary comments. Verifiers use documented commands as written in their probe copy without building a replacement environment.
- The ODD Flow Orca plugin uses `agent.prompt.before` to append a worker marker to orchestration dispatches, so workers can still be identified if the Orca preamble changes. Reinstalling the plugin requires a new approval.
- The Orca plugin issues worker token records under `~/.odd-flow/worker-tokens/` by default, or under `$ODD_FLOW_STATE_DIR/worker-tokens/` when set and non-empty. The token must match the marker's role. The first-prompt hook in Claude Code, Codex, and Antigravity removes the record on first use, even when another rule already identifies the worker. Bare markers no longer identify workers.
- When Engram `mem_save` or `mem_session_summary` fails, the parent saves the same entry with the `engram` CLI and reports a failed save if the CLI is missing.

## [0.3.0] - 2026-11-25

### Added

- `profile.py list --json` and `profile.py show --json` for tools that read saved profiles and effective session settings.
- A one-time notice on the next coordinator prompt when the effective mode changes, so the previous mode's rules no longer apply.
- An [Orca profiles plugin](orca-plugin/README.md) with a sidebar panel for switching session profiles and modes, a status bar item, and commands to open the panel or toggle a sole coordinator's mode. Worker rows are read-only and show only their title line.
- **Reset to defaults** in the Orca panel removes a session's profile and mode overrides.
- The Orca commands log their outcomes, and the status item keeps its text and tooltip within Orca's length limits.
- The Orca panel, status tooltip, and **Toggle mode** command explain how to update an installed odd-flow script that lacks the JSON flags.

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
