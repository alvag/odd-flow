# ODD Flow Orca plugin 0.2.1 catalog release

Objective: publish ODD Flow Orca plugin 0.2.1 through the in-repo catalog so catalog installs get the Windows APPDATA fix. Branch: `release/orca-plugin-0.2.1`. Delivery: commit each unit after its spot check; merge only via merge_ready to the supervisor bot (`--no-ff`). Runner: `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

- S1 (supervisor, verbatim): "Goal: publish ODD Flow Orca plugin 0.2.1 through the in-repo catalog, so catalog installs get the Windows APPDATA fix merged in PR #52 (main 4225593; `gh pr view 52 -R alvag/odd-flow`). Follow \"Publishing an ODD Flow Orca plugin release\" in docs/compatibility.md exactly. Today `bash tests/orca-catalog-check.sh` on main prints its NOTE about unreleased changes; after this release it must pass with no NOTE."
- S2 (supervisor, verbatim): "orca-plugin/orca-plugin.json: version 0.2.0 to 0.2.1 only. No capability, command, hook, panel or execution change."
- S3 (supervisor, verbatim): "orca-plugin/README.md: the catalog install section now says it was verified live on Orca 1.4.278 (evidence: the comment on issue #8, `gh issue view 8 -R alvag/odd-flow --comments`), including what was not exercised (an auto-update to a newer release; the Settings toggle for manual updates). Rename its heading so it no longer says \"not yet verified live\", and update every link to the old anchor, at least README.md's `#install-from-the-github-catalog-not-yet-verified-live` (see the comments on issue #43, `gh issue view 43 -R alvag/odd-flow --comments`). Check with `git grep -n \"not-yet-verified-live\"` that no link is left."
- S4 (supervisor, verbatim): "Commit those, then generate the release entry with `orca plugin release-entry orca-plugin --json` from a clean clone of the commit that holds the final 0.2.1 plugin folder, and prepend it to orca-catalog.json (newest first). Show that the clean-clone output deep-equals the catalog entry and that `git diff --stat <pinned commit> HEAD -- orca-plugin` is empty."
- S5 (supervisor, verbatim): "CHANGELOG.md: under [Unreleased], your own bullet for the 0.2.1 catalog release (do not rewrite others' bullets). docs/compatibility.md: a row for plugin 0.2.1 in the table's existing style, status \"tests only\" until it is verified live."
- S6 (supervisor, verbatim): "Notes: odd-flow must keep working without Orca, without the Orca plugin and without an Orca bot." / "Code and docs must not mention issue numbers, specs or tasks, except existing evidence links in docs/compatibility.md."
- S7 (assumption): `tests/version-check.sh` requires the `**Current checkout**` row of docs/compatibility.md to name the manifest's plugin version, so T1 changes that row's plugin column to 0.2.1 in the same commit as the bump; T2 adds the separate 0.2.1 release row (S5).
- S8 (evidence, issue #8 comment, verbatim): "Live test on Orca 1.4.278 after merging 273b1b3: `orca plugin catalog add alvag/odd-flow` (approved), `orca plugin install alvag.odd-flow-profiles` (approved) installed 0.2.0 from commit 6e12f88 with the catalog's contentHash; the plugin ran with 0 restarts and no log errors, the panel opened and showed the session, profile and mode, and `orca plugin update alvag.odd-flow-profiles` reported up-to-date. Then uninstalled, removed the catalog and returned to the folder install. Not exercised: an auto-update to a newer release (none exists yet)."

- S9 (supervisor, 2026-11-26, verbatim): "Scope extension from Max: release odd-flow itself in the same branch, together with plugin 0.2.1. Doing it here avoids two branches editing CHANGELOG.md and docs/compatibility.md at once."
- S10 (supervisor, verbatim): "odd-flow version 0.4.0 to 0.5.0 (minor: [Unreleased] has about 49 entries, with new features under Added and no 1.0 commitment yet) in every manifest that tests/version-check.sh reads: .claude-plugin/plugin.json, .claude-plugin/marketplace.json (the odd-flow entry), .codex-plugin/plugin.json, .antigravity-plugin/plugin.json. Version field only. Grep for any other place that states the current odd-flow version (README, docs) and update it only where it names the current release."
- S11 (supervisor, verbatim): "CHANGELOG.md: turn [Unreleased] into [0.5.0] with today's date, in the style of the earlier sections, and leave a new empty [Unreleased] on top. Your plugin 0.2.1 bullet goes in the 0.5.0 section. Do not rewrite other bullets."
- S12 (supervisor, verbatim): "docs/compatibility.md: the new row reads odd-flow 0.5.0 / ODD Flow Orca plugin 0.2.1, status \"tests only\", until verified live."
- S13 (supervisor, verbatim): "Order: commit the odd-flow and plugin version bumps and docs first, then generate the catalog entry from a clean clone of the commit that holds the final 0.2.1 plugin folder, as already planned. The odd-flow manifests are outside orca-plugin/, so they do not change the plugin's hash, but keep the pinned commit at or after the final plugin-folder change."
- S14 (supervisor, verbatim): "Extra checks: bash tests/version-check.sh, and python3 skills/odd-flow/scripts/install_check.py (read-only), which after the bump should report Codex and Antigravity as differing from the checkout until I reinstall them. Report its output." / "Same hard limits: no plugin, catalog or install actions, no reinstall in Codex or Antigravity (I batch those after the merge with Max's OK), no push, no tags."
- S15 (assumption): S11 supersedes S5's "under [Unreleased]" for the plugin bullet; S12 fixes the odd-flow column of S5's 0.2.1 row. The pinned commit is the T2 commit (latest before the catalog commit, same orca-plugin/ tree as T1).

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S3, S6, S7 | Version bump, plugin README catalog section and heading, old-anchor links, Current checkout plugin column | orca:write (full delegation: every workspace change goes to a writer) | done | see commit in L6 |
| T2 | S9-S11, S14 | odd-flow 0.5.0: four manifests, other current-version mentions, CHANGELOG [0.5.0] section, Current checkout odd-flow column | orca:write (after T1: shares docs/compatibility.md) | pending | |
| T3 | S1, S4-S6, S11-S13, S15 | Prepend the clean-clone release entry to orca-catalog.json; plugin 0.2.1 bullet in [0.5.0]; compatibility 0.5.0 / 0.2.1 row | orca:write (after T2 commit: pinned) | pending | |
| T4 | S1-S15 | Bounded independent verify of the release entry and docs | orca:verify (Risk item 5: release) | pending | |

## Log

- L1 (supervisor, 2026-11-26): workstream brief "plugin-release-0-2-1" (goal, scope 1-4, checks, hard limits, notes), quoted in S1-S6.
- L2 (supervisor, 2026-11-26): scope extension msg_043064ebaca2 (odd-flow 0.5.0 release in the same branch), quoted in S9-S14. T1 already running (dispatch ctx_afd983c1a1a5); odd-flow bump added as T2 after it.
- L3 (parent, 2026-11-26): baseline on main 4225593 clean clone: `orca plugin test orca-plugin` exit 1, the long-scratch-path tooltip test fails by truncation (actual tooltip ends with an ellipsis); `bash tests/orca-catalog-check.sh` exit 0 with NOTE about unreleased orca-plugin/ changes.
- L4 (parent, 2026-11-26): baseline counts on main (clean clone in scratch): `orca plugin test orca-plugin` 158 tests, 157 pass, 1 fail ("status refresh reads only Show and warns about an outdated script for one or several coordinators", tooltip truncated by the long scratch path). T2 Task created up front: task_d265bd575102 (deps T1 task_097c4624f44a).
- L5 (parent, 2026-11-26): T1 worker_done (ctx_afd983c1a1a5), files within surface. Spot check: `bash tests/version-check.sh` exit 0; `git grep -n "not-yet-verified-live"` only odd/tasks/catalog-verified.md:17 (historical assumption text, not a link). Writer residual risk: 0.2.1 not exercised live; auto-update and the Settings toggle unexercised.
