# Install hardening

Objective: harden `/odd-flow check` human output and close the session-state cleanup follow-ups. Branch: `fix/install-hardening`. Delivery: `ask-on-risk`. Runner: `bash tests/run.sh` (one suite: `bash tests/<name>-check.sh`).
Profile: `claude-gpt`. Base commit: `fda7253`. Orca run: `run_41727f01b90a`.

## Specs

Sources: GitHub issues alvag/odd-flow#5 and #25, quoted verbatim. The issue bodies win over any summary.

- S1 (issue #5, "install-check: harden human output sanitizing", verbatim body):
> Advisories left by the install-check verify (`odd/tasks/install-check.md` L10):
>
> - [ ] U+202E (right-to-left override) and other non-whitespace Unicode format characters pass the Orca error sanitizer, so a crafted plugin error can reorder the printed line.
> - [ ] Claude Code install paths and `files differ` names are printed raw in the human output.
> - [ ] `plugin_error` has no length cap.
>
> Also unverified there: S18 against a real GitHub-marketplace Claude Code install, and S17 against a real Orca CLI hang. `--json` output is out of scope unless a fix needs it.
- S2 (issue #25, "Session state cleanup: follow-ups from review", verbatim body):
> Follow-ups from the review and verification of automatic session state cleanup (#15). None blocked the merge.
>
> Risk:
> - [ ] Pruning a `prompt-sessions` record lets a coordinator that is resumed after 30 days be marked as a worker again if its next prompt starts with an Orca preamble or `# Role:`. `references/profiles.md` documents only the reverse case. Document it, or decide whether the prune should keep coordinator records.
> - [ ] `profile.py prune` and `/odd-flow check` match any plugin data dir named `odd-flow-*`, so another plugin named `odd-flow-<x>` would match. The SessionStart hook is not affected.
>
> Resilience and edge cases:
> - [ ] A stamp file dated in the future blocks automatic cleanup until the clock passes that date.
> - [ ] The SessionStart scan has no time or count limit (4000 expired files: 0.58 s against 0.29 s on base; the hook timeout is 10 s).
> - [ ] `install_check.py` reports `{"status": "unreadable"}` for session state without a reason.
> - [ ] On platforms without `O_DIRECTORY` or `dir_fd` support, the prune CLI raises a traceback instead of an odd-flow error.
> - [ ] With an unreadable Claude `plugins/data` root, prune prints one "cannot discover plugin data" line per `odd-flow-*` entry instead of one per root.
> - [ ] Already on main before this change: `profile.py use` with an unwritable sessions dir exits 1 with a raw `PermissionError` traceback.
>
> Found while mapping:
> - [ ] `<claude config>/plugins/data/codex-openai-codex/prompt-sessions/` exists, so some odd-flow prompt hook run wrote its record under another plugin's data dir, likely through an inherited `CLAUDE_PLUGIN_DATA`. Cleanup neither causes nor removes it. Find how the variable leaks and whether the hook should check that the data dir belongs to odd-flow.
>
> Not verified live yet: a real Claude Code, Codex or Antigravity session running the new SessionStart cleanup.
- S3 (workstream brief, verbatim, goal):
> Goal: two GitHub issues on /odd-flow check and session state. Read each first with `gh issue view <n> -R alvag/odd-flow` and quote the bodies verbatim into your feature document as the spec:
> - #5 "install-check: harden human output sanitizing".
> - #25 "Session state cleanup: follow-ups from review". Background: odd/tasks/session-cleanup.md and odd/tasks/install-check.md.
- S4 (workstream brief, verbatim, constraints):
> Notes:
> - #25's first risk item (a coordinator resumed after 30 days can be marked as a worker again) and its last item (an odd-flow record under another plugin's data dir, likely an inherited CLAUDE_PLUGIN_DATA) need investigation first. Send me each finding as a question with options (document only, or the fix the evidence supports, with cost and risk) before a writer changes behavior for it.
> - The SessionStart and prompt hooks run in Claude Code, Codex and Antigravity on every session: keep hook output and exit codes byte-identical where the issue does not ask for a change, and prove it per runtime as the session-cleanup verify did. Get an independent verify before merge_ready.
> - After merge, Codex and Antigravity need a reinstall (hooks change); do not reinstall anything, list it in merge_ready.
> - odd-flow must keep working without Orca, without an Orca bot, and without Codex or Antigravity.
> - Expected surfaces: skills/odd-flow/scripts/install_check.py, skills/odd-flow/scripts/profile.py, scripts/session-start.py, scripts/prompt-submit.py, skills/odd-flow/references/profiles.md, tests/install-check.sh, tests/profile-check.sh, tests/session-cleanup-check.sh, CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>. Tell me before touching README.md.
>
> Parallel workstreams (do not edit their files; tell me if you must):
> - rules-wording (#21, #22): references/delegation.md, mode-full-delegation.md, orca-dispatch.md, odd-protocol.md, the core blocks, tests/role-prompts-check.sh, tests/full-delegation-check.sh, tests/mode-check.sh.
> - pane-recovery (#24): skills/odd-flow/scripts/pane.py, tests/pane-check.sh.
> - Commit messages may reference the issues ("Refs #5"); code and comments must not mention issue numbers, specs or tasks. Do not push and do not touch the GitHub issues; I close them after the push.
- S5 (decision, parent, after T3): `/odd-flow check` human output passes every untrusted string it prints (Orca plugin error, Claude install path, `files differ` names, reasons) through one human-output sanitizer that also removes Unicode format characters (category Cf, such as U+202E) besides the controls it handles today. The printed plugin error is capped at 200 characters plus a `...` marker. `--json` stays byte-identical to base except one added field: a short `reason` next to `{"status": "unreadable"}` for session state (human line gets the same reason, sanitized).
- S6 (decision, parent, after T3): `profile.py` turns the platform-capability failure (no `O_DIRECTORY`/`dir_fd`) and the `use` write failure (`PermissionError` and other `OSError` on the sessions dir) into odd-flow errors with the existing error exit, no traceback. An unreadable plugin data root reports one "cannot discover plugin data" line per root (reproduce first: a root readable but not searchable, mode r without x, is the likely case).
- S7 (decision, parent, after T3): the SessionStart hook treats a stamp dated in the future as stale (runs the cleanup and refreshes the stamp). Its automatic cleanup gets a wall-clock budget of 1 second; when the budget runs out it stops, keeps what it removed, and does not refresh the stamp, so the next session start resumes. `profile.py prune` stays unbounded. Hook output and exit code stay byte-identical.
- S9 (user via supervisor, 2026-11-26, verbatim, answer to all three questions msg_9d131061c294, msg_0b0b4311e5b3, msg_0b6ebd2e1124): "vamos con tus recomendaciones" — option A, document only, for: the pruned coordinator record (a coordinator resumed after the cutoff whose next prompt looks like a worker dispatch is marked as a worker), the inherited CLAUDE_PLUGIN_DATA (the Claude Code Codex plugin exports its own data dir through CLAUDE_ENV_FILE, so odd-flow hooks run by hand from a Claude Code shell write there unless CLAUDE_PLUGIN_DATA is set explicitly; stray records are harmless and can be deleted by hand), and odd-flow-* matching (prune and the check treat every odd-flow-* data dir as odd-flow's, and remove only 64-hex regular files directly in prompt-sessions/ and session-modes/).
- S8 (decision, parent): parallel writers do not touch CHANGELOG.md or references/profiles.md; one docs unit writes the CHANGELOG bullets and doc lines after the code units and the open questions settle.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2 (risk item 1), S4 | Investigate: pruned `prompt-sessions` record lets a resumed coordinator be marked as a worker; options with cost and risk | orca:explore (brief asks for investigation before any behavior change) | done | task_900a51f1299e; parent verified prompt-submit.py:94-107 (records hold "parent"/"worker", explorer said indistinguishable: corrected); question msg_9d131061c294 open |
| T2 | S2 (found-while-mapping item), S4 | Investigate: odd-flow record under `codex-openai-codex` plugin data; how `CLAUDE_PLUGIN_DATA` leaks; options with cost and risk | orca:explore (brief asks for investigation before any behavior change) | done | task_54f8cccd38d1; parent confirmed leak source: Codex plugin session-lifecycle-hook.mjs:80 exports CLAUDE_PLUGIN_DATA via CLAUDE_ENV_FILE; question msg_0b0b4311e5b3 open |
| T3 | S1, S2 (other items), S4 | Routing map: owner `path:line`, current behavior and smallest fix for each remaining item; shared helpers; how the session-cleanup verify proved hook output per runtime | orca:explore (mapping trigger: more than the parent read budget) | done | task_5d070d276cc5 + follow-up task_6603d3fd7d7b (full map) |
| T4 | S1, S2 (unreadable reason), S5 | install_check.py human-output sanitizer, plugin error cap, session-state reason; tests/install-check.sh | orca:write (parallel with T5, disjoint surface) | done | task_554792520514; writer RED 4 rules → GREEN; JSON differential = base except added reason; parent spot check `bash tests/install-check.sh` passed; commit 7c5c4d5 |
| T5 | S2 (O_DIRECTORY, root lines, use PermissionError), S6 | profile.py odd-flow errors instead of tracebacks; tests/profile-check.sh | orca:write (parallel with T4, disjoint surface) | done | task_6de60a305be5; writer RED profile-check 73/4 → GREEN 77/0; differential 115 profile + 12 SessionStart + 6 install cases identical; parent spot check profile-check 77/0; commit ee35557 |
| T6 | S2 (future stamp, scan limit), S7 | session-start.py stamp and 1 s budget; tests/session-cleanup-check.sh | orca:write (after T5: may touch profile.py helper) | done | task_b14bbb886652; writer RED 2 new tests → GREEN 7; differential 12 hook + prune + check cases = base; parent spot check session-cleanup-check OK (7 tests); commit 106c42a |
| T7 | S2 (risk items 1-2, found-while-mapping), S9 | document only: folded into T8 | - | dropped | merged into T8 (S9) |
| T8 | S1-S9 | CHANGELOG bullets, profiles.md lines for S9 and settled items | orca:write (answers in; disjoint from T6, parallel) | done | task_0516d7187de4; docs only; parent read the diff (S9 a-c and S7 present, no issue refs); commit ede4b00 |
| T9 | S1-S8 | independent verify incl. per-runtime hook byte identity | orca:verify (brief asks; Risk items 1, 2, 5) | pending | |

## Log

- L1 (user via supervisor brief, 2026-11-26): "Workstream: install-hardening (branch fix/install-hardening). Max approved it." Goal and constraints quoted verbatim in S3-S4.
- L5 (2026-11-26): supervisor status msg_754a8f841c8e: main moved to 6daba16 (rules-wording merged); rebase onto main before merge_ready, CHANGELOG.md may conflict (keep both sides). Rebase after T6 returns, before T9 verify.
- L4 (2026-11-26): Orca auto-status msg_604fe2449cfc and msg_b9058045130b: the bot ended its turn without answering either question. An unanswered question is not consent: no writer touches those two items until Max decides. Questions stay open; not resent. Independent items continue.
- L3 (2026-11-26): T1/T2 reports came back as summaries only; parent checked the key claims read-only. Findings sent to the bot as questions with options A document-only / B fix / C defer (msg_9d131061c294, msg_0b0b4311e5b3); recommendation A for both. T3 asked for its full report (follow-up ctx_fde7a6d946e9).
- L2 (2026-11-26): Classified large (two issues, many items, investigations that wait on Max). Base `fda7253` (= main). Next: T1-T3 explore in parallel.
