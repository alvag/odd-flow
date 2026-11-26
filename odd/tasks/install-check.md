# Install check

Objective: a read-only odd-flow command that reports whether each install matches its checkout. Branch: `feat/install-check`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim): "a read-only odd-flow command that reports whether each install matches the checkout it was installed from, and why not."
- S2 (user, verbatim): "Claude Code: `claude plugin list` shows odd-flow read from a folder; report that folder and its version."
- S3 (user, verbatim): "Codex: cache under ~/.codex/plugins/cache/odd-flow/odd-flow/<version>/ (from `codex plugin add odd-flow@odd-flow`)."
- S4 (user, verbatim): "Antigravity: ~/.gemini/config/plugins/odd-flow/ (from `agy plugin install <checkout>`)."
- S5 (user, verbatim): "ODD Flow Orca plugin (local.odd-flow-profiles): read its installed state with `orca plugin list --json` only. NEVER run `orca plugin install` (it reloads at once when capabilities are unchanged)."
- S6 (user, verbatim): "Installs to cover (each only when present; report \"not installed\" otherwise)"
- S7 (user, verbatim): "Compare the version and the hashes of the shipped files (skills/, scripts/, hooks/, the runtime manifests) with the checkout. Report per install: in sync, version differs, files differ (list them), or not installed. Mixed plugin and hook versions matter: the tokened worker marker needs matching Orca plugin and odd-flow hooks (see the upgrade note in README.md / orca-plugin/README.md)."
- S8 (user, verbatim): "Shape: follow gentle-shell's idea (human output plus --json with a schema name, an exit code for \"needs reinstall\", a distinct exit code with a reason when something cannot be read, no secrets or tokens in output)."
- S9 (user, verbatim): "It must be read-only: no install, no reinstall, no writes outside system temp."
- S10 (user, verbatim): "Note: the Codex cache also holds .git and untracked files because the marketplace path is \"./\" (see NOTES.md, Codex hooks trust); compare only the shipped files that matter and say how you treat the rest."
- S11 (user, verbatim): "odd-flow must work for people without an Orca bot, without the Orca plugin, and without Codex or Antigravity installed."
- S12 (user, verbatim): "Tests: a test with fake install trees (in sync, drifted, missing, unreadable), wired into tests/run.sh if it needs no network."
- S13 (decision, parent): lives in `skills/odd-flow/scripts/install_check.py`, run as `python3 <skill-dir>/scripts/install_check.py [--json]` and exposed as `/odd-flow check [--json]` in SKILL.md. Test: `tests/install-check.sh` (matches the `*-check.sh` glob of tests/run.sh). Exit codes follow gentle-shell: 0 every present install in sync (or none present), 1 at least one needs reinstall, 2 usage error, 3 something could not be read (wins over 1; the report still lists every install). JSON: one object with `"schema": "odd-flow.install-check/v1"`.
- S14 (decision, parent): the checkout compared against is the repository holding the running script. The shipped set is the checkout's files under `skills/`, `scripts/`, `hooks/`, plus `hooks.json` and the runtime manifests (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`, `.antigravity-plugin/plugin.json`, `.agents/plugins/marketplace.json`). Everything else in an install (`.git/`, `odd/`, `tests/`, docs, untracked extras outside the shipped paths, Python bytecode caches) is ignored and the human output says so once.
- S15 (assumption): a missing CLI (`claude`, `orca`) or a missing install directory means "not installed", never an error; a present CLI or directory that cannot be read or parsed is "unreadable" with a short reason.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1-S15 | install_check.py, tests/install-check.sh, SKILL.md command, README line, CHANGELOG | orca:write (full delegation: every workspace change goes to a writer) | done | task_4536d36c17bb, base e72b4c2; RED/GREEN `bash tests/install-check.sh` (worker); spot check exit 0 `install-check: passed` (parent) |
| T2 | S1-S15 | independent verify of T1 | orca:verify (brief asks for an independent verify: reads several homes) | pending | |

## Log

- L1 (user, 2026-11-25): "Goal (Max approved, idea from gentle-shell fa13f2540, a read-only `setup --check [--json]`): a read-only odd-flow command that reports whether each install matches the checkout it was installed from, and why not." Full brief: the workstream message from the supervisor (install-check), quoted in S1-S12.
- L2 (2026-11-25): surfaces and location (S13-S14) sent to the bot as status before T1 launches.
- L3 (2026-11-25): T1 done. Parent spot check `bash tests/install-check.sh` exit 0. Live run exit 1: Claude Code, Codex and Antigravity report files differ against this worktree (new uncommitted script and SKILL.md, plus orca-dispatch.md in the Codex and Antigravity copies); Orca plugin 0.1.0 in sync, Orca status errored. Worker reports `bash tests/run.sh` 21 passed, 1 failed (`parent-guard-check.sh` setgid worker-tokens assertions), same failure on a clean `git archive HEAD`. Next: T2 verify.
