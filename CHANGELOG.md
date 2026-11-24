# Changelog

This file tracks notable changes to odd-flow. It follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
