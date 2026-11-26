# Mark the Orca catalog install as verified live

Objective: docs outside `orca-plugin/` stop calling the in-repo Orca catalog route "not yet verified live" and record the live result. Branch: `docs/catalog-verified`. Delivery: commit each unit after its spot check; merge only via merge_ready to the supervisor bot. Runner: `bash tests/run.sh`.
Profile: `claude-gpt` (full-delegation).

## Specs

- S1 (supervisor, verbatim): "the in-repo Orca catalog route for the ODD Flow Orca plugin is now verified live, so the docs outside the plugin folder must stop calling it "not yet verified live"."
- S2 (supervisor, verbatim): "README.md: the catalog install lines say the route was verified live on Orca 1.4.278. Keep the migration step and the clone plus folder install."
- S3 (supervisor, verbatim): "docs/compatibility.md: record the live result for the 0.2.0 catalog release (Orca version, date, what was and was not exercised), in the table's existing style."
- S4 (supervisor, verbatim): "CHANGELOG.md: own bullet under [Unreleased] only, if the existing catalog bullet calls it unverified; adjust that wording."
- S5 (supervisor, verbatim): "Do not touch anything under orca-plugin/ (its README is in the hashed plugin folder and changes with the next plugin release; I tracked that). Do not touch orca-catalog.json."
- S6 (supervisor, verbatim): "What was verified (Orca 1.4.278, 2026-11-26): `orca plugin catalog add alvag/odd-flow` with its approval; `orca plugin install alvag.odd-flow-profiles` with its approval, which installed 0.2.0 from the pinned commit with the catalog's contentHash; the plugin ran with 0 restarts and no log errors; the panel opened and showed the session, profile and mode; `orca plugin update alvag.odd-flow-profiles` reported up-to-date; uninstall and `orca plugin catalog rm` worked. Not exercised: an auto-update to a newer release (none exists yet), and the Settings toggle for manual updates."
- S7 (supervisor, verbatim): "Checks before merge_ready: bash tests/run.sh, bash tests/orca-catalog-check.sh (must stay exit 0 with no NOTE), bash tests/orca-plugin-docs-check.sh."
- S8 (evidence, issue alvag/odd-flow#8 comment by alvag, verbatim): "Live test on Orca 1.4.278 after merging 273b1b3: `orca plugin catalog add alvag/odd-flow` (approved), `orca plugin install alvag.odd-flow-profiles` (approved) installed 0.2.0 from commit 6e12f88 with the catalog's contentHash; the plugin ran with 0 restarts and no log errors, the panel opened and showed the session, profile and mode, and `orca plugin update alvag.odd-flow-profiles` reported up-to-date. Then uninstalled, removed the catalog and returned to the folder install. Not exercised: an auto-update to a newer release (none exists yet). The docs still mark the route as not verified live; that wording is the remaining step before closing.
--"
- S9 (assumption): the README link to `orca-plugin/README.md#install-from-the-github-catalog-not-yet-verified-live` keeps its anchor, because the plugin README heading stays unchanged until the next plugin release (S5); only the link text and surrounding sentence change.
- S10 (assumption): "the existing catalog bullet" in S4 is the first `### Added` bullet under `[Unreleased]` ("ODD Flow Orca plugin 0.2.0: Install and update from GitHub through an Orca catalog without cloning (not yet verified live)."); only its wording changes.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S1-S10 | README.md, docs/compatibility.md, CHANGELOG.md wording and live-result row | orca:write (full delegation: every workspace write goes to a writer) | done | task `task_1f657a447daa`, dispatch `ctx_6fea3caf2eea`; parent spot check L2; commit `aff3aeb` |

## Log

- L1 (supervisor, 2026-11-26, verbatim except the omitted routing preamble): "You are the main session for one odd-flow workstream. [...supervisor preamble on routing questions, approvals and merge requests to the bot omitted here...]

Workstream: catalog-verified (branch docs/catalog-verified). Max approved it. Small, docs only.

Goal: the in-repo Orca catalog route for the ODD Flow Orca plugin is now verified live, so the docs outside the plugin folder must stop calling it "not yet verified live". Read the live result in the comment on issue #8: `gh issue view 8 -R alvag/odd-flow --comments`. Quote that comment verbatim into your feature document as the evidence.

What was verified (Orca 1.4.278, 2026-11-26): `orca plugin catalog add alvag/odd-flow` with its approval; `orca plugin install alvag.odd-flow-profiles` with its approval, which installed 0.2.0 from the pinned commit with the catalog's contentHash; the plugin ran with 0 restarts and no log errors; the panel opened and showed the session, profile and mode; `orca plugin update alvag.odd-flow-profiles` reported up-to-date; uninstall and `orca plugin catalog rm` worked. Not exercised: an auto-update to a newer release (none exists yet), and the Settings toggle for manual updates.

Change:
- README.md: the catalog install lines say the route was verified live on Orca 1.4.278. Keep the migration step and the clone plus folder install.
- docs/compatibility.md: record the live result for the 0.2.0 catalog release (Orca version, date, what was and was not exercised), in the table's existing style.
- CHANGELOG.md: own bullet under [Unreleased] only, if the existing catalog bullet calls it unverified; adjust that wording.

Do not touch anything under orca-plugin/ (its README is in the hashed plugin folder and changes with the next plugin release; I tracked that). Do not touch orca-catalog.json.

Checks before merge_ready: bash tests/run.sh, bash tests/orca-catalog-check.sh (must stay exit 0 with no NOTE), bash tests/orca-plugin-docs-check.sh. A verify is optional for a docs-only change: a self-review of the diff against the evidence is enough; say which you did.

Notes:
- No other workstream is open.
- Commit messages may reference the issue ("Refs #8"). Do not push and do not touch the GitHub issue; I close it after the push.
- No plugin, catalog or install actions of any kind."
- L2 (parent, 2026-11-26): T1 writer reported `worker_done` (README.md, docs/compatibility.md, CHANGELOG.md; within surface). Parent spot check: `bash tests/run.sh` → "Summary: 25 passed, 0 failed" (exit 0); `bash tests/orca-catalog-check.sh` → exit 0, no output, no NOTE; `bash tests/orca-plugin-docs-check.sh` → exit 0; `git grep -n -i "not yet verified live" -- README.md docs/compatibility.md CHANGELOG.md` → no match. Self-review of the diff against S6 and S8 (no independent verify): every claim matches the evidence; release commit `6e12f88` matches `orca-catalog.json`; README keeps the anchor (S9), the migration step and the folder install.
- L3 (parent, 2026-11-26): T1 committed as `aff3aeb` on `docs/catalog-verified`. Next: merge_ready to the supervisor bot; no push.
