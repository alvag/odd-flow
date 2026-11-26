# Orca stability

Objective: find and, where the evidence supports it, fix the causes of the ODD Flow Orca plugin going to "errored after repeated failures" and of Orca split placements that time out and leave the pane outside the layout. Branch: `fix/orca-stability`. Delivery: `ask-on-risk` (investigation findings go to the supervisor bot before any writer). Runner: `bash tests/orca-plugin-typecheck.sh` and `orca plugin test orca-plugin` for plugin changes; `bash tests/pane-check.sh` for pane.py changes.
Profile: `claude-gpt`.

## Specs

- S1 (user, verbatim): "Read each first with `gh issue view <n> -R alvag/odd-flow --comments` and quote the bodies and comments verbatim into your feature document"
- S2 (user, verbatim, #6): "#6 \"ODD Flow Orca plugin went to errored after repeated failures; cause unknown\". It happened again twice on 2026-11-26: once found at 14:33 UTC and fixed by `orca plugin restart`, then errored again about two hours later (first log line 17:00 UTC). Each time `orca plugin logs local.odd-flow-profiles` kept only \"dropped\" lines, because Orca keeps 200 lines."
- S3 (user, verbatim, #27): "#27 \"Orca split placements time out and leave the pane outside the layout\"."
- S4 (user, verbatim): "Investigate first, read-only: read orca-plugin/ (its worker, hooks and event handlers), Orca's plugin host behavior for \"errored after repeated failures\" (what counts as a failure, how many, any timeouts; the installed Orca 1.4.278 app bundle and `orca plugin --help` are fair sources), and Orca's split/leaf handling. Then send me the findings for each issue as a question with options (no change / document / the fix the evidence supports, with cost and risk) before any writer changes code. Say whether the two issues are related."
- S5 (user, verbatim): "A plugin fix changes code that every session loads. It needs an independent verify, tests/orca-plugin-typecheck.sh and `orca plugin test orca-plugin` before merge_ready, and a reload that Max approves."
- S6 (user, verbatim): "odd-flow must keep working without Orca, without the Orca plugin and without an Orca bot."
- S8 (user via supervisor bot msg_644277c57800, 2026-11-26, verbatim): "Max's answer, verbatim: \"vamos con tus recomendaciones\" (\"go with your recommendations\"). My recommendations were your recommended options: #6 option 3 \"Capture first\", #27 option 3 \"Tab fallback in pane.py\"." / "#6: keep the read-only capture running; when the plugin fails (or after 5 h without a failure), send the exit code and the fix the evidence supports as a new question. Do not restart or reload the plugin." / "#27: go ahead. You may edit skills/odd-flow/scripts/pane.py, tests/pane-check.sh (I am telling test-hygiene to leave that file to you) and skills/odd-flow/references/orca-dispatch.md step 3, plus CHANGELOG.md. Independent verify before merge_ready." / "Max also approved reporting the orphan-pane behavior to Orca upstream; I file that issue myself. Do not file it."
- S9 (#27 option 3 as proposed in question msg_fc0c47dd2a74, verbatim): "when a split times out and `--retry-split` also fails, pane.py opens the worker in a tab instead (`orca terminal create` worked every time). It returns that handle plus the orphan leaf ID, so the coordinator closes the orphan. orca-dispatch.md step 3 is updated to match."
- S10 (assumption): the tab fallback applies only when Orca's split reply is the pending timeout (`splitMayStillComplete: true` with a valid leaf ID) and the single `--retry-split` wait also ends with that pending timeout. Every other split error, the pane.py subprocess timeout, and a successful retry keep today's behavior.
- S11 (user via supervisor bot msg_772926be4379, 2026-11-26, verbatim): "#6, the plugin dies when too many events are pending: which option? → 3: fix the two event handlers" / "Should I restart the plugin now, while the fix is built? → Yes, restart it now"
- S12 (supervisor bot review requirement, msg_772926be4379, verbatim): "when the handlers stop awaiting `refreshStatus()`, attach a rejection handler (for example `void refreshStatus().catch(...)` logging through the existing diagnostics), so an unexpected error in the background refresh cannot become an unhandled rejection that kills the worker. readState already catches its own errors, but statusFor and the logging path are outside that try. Cover it in the regression test if it is cheap. Then independent verify, tests/orca-plugin-typecheck.sh, `orca plugin test orca-plugin`; do not reload the plugin yourself, list the reload in merge_ready."
- S13 (#6 option 3 as proposed in question msg_d8ea476afc0e, verbatim): "the two event handlers return immediately and leave the existing coalesced refresh running in the background, so each event is answered at once. Refresh errors are already caught inside it. Add a regression test showing that the handler resolves while a refresh is still in flight, a README troubleshooting note and one CHANGELOG bullet."
- S7 (user, verbatim): "Expected surfaces: orca-plugin/ (code, tests, README), docs/compatibility.md if behavior per Orca version changes, CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>. skills/odd-flow/scripts/pane.py, tests/pane-check.sh and skills/odd-flow/references/orca-dispatch.md only if the #27 fix needs them; tell me first."

### Issue text (S1)

`gh issue view <n> -R alvag/odd-flow --comments` prints only the comments; the bodies below come from `gh issue view <n> -R alvag/odd-flow --json title,body,comments` on 2026-11-26.

Issue #6 "ODD Flow Orca plugin went to errored after repeated failures; cause unknown" (opened by alvag, 2026-11-26T12:57:07Z), body verbatim:

> On 2026-11-25 `/odd-flow check` found the ODD Flow Orca plugin (`local.odd-flow-profiles`) in an errored state after repeated failures. While errored, Orca skipped its `agent.prompt.before` hook, so no worker tokens were issued (the preamble and `# Role:` fallback rules kept identifying workers). `orca plugin restart` fixed it.
>
> The cause is unknown: `orca plugin logs` keeps only the last 200 lines, and they no longer held the first failure.
>
> Next time it happens, capture `orca plugin logs <key> --json` before restarting. Orca 1.4.278 retries transient transpile timeouts instead of caching them (stablyai/orca#48910, for panel frames); that may be related but is unproven. Consider whether the plugin should log enough on failure to diagnose it from the retained lines.

Comment by alvag, 2026-11-26T14:41:33Z, verbatim:

> Seen again on 2026-11-26: the plugin was errored ("errored after repeated failures") at the latest at 14:33 UTC. `orca plugin logs` held only 200 "agent.status.changed dropped" warnings, and Orca's own logs (main.trace, daemon.log) had no plugin error lines, so the cause was lost again. This points to a log that keeps the first failure, or to the plugin logging its own failures somewhere that does not roll over.

Comment by alvag, 2026-11-26T17:08:21Z, verbatim:

> Seen again on 2026-11-26, about two hours after an `orca plugin restart` at 14:42 UTC: errored again, with the first logged line at 17:00 UTC (`agent.status.changed dropped`) and `hook agent.prompt.before skipped` at 17:03. The cause was lost again. Split placements had also been timing out since 16:29 UTC (#27); whether the two are related is unknown.

Issue #27 "Orca split placements time out and leave the pane outside the layout" (opened by alvag, 2026-11-26T17:08:16Z), body verbatim:

> On 2026-11-26, with Orca 1.4.278, `pane.py open` failed four times in one workstream with:
>
> > Orca terminal split: Timed out waiting for split pane handle: pane <leaf> in tab <tab> may still open and run its command
>
> The `--retry-split <leafId>` retry failed the same way. Each time the pane did open and ran its command (Claude Code or Codex), but it was left outside the tab's visual layout. The coordinator found each one by its leaf ID and closed it.
>
> | Time (UTC) | Worker agent | Result |
> |---|---|---|
> | 16:29 | Claude | timeout, orphan pane closed |
> | 16:41 | Codex | timeout, orphan pane closed |
> | 16:42 | Codex | timeout, orphan pane closed |
> | 16:49 | Claude | timeout, orphan pane closed |
>
> Context:
> - The worktree held the coordinator's terminal plus at most one stale worker pane at the time.
> - The first failure ran the 30 s `pane.py` from before the split limit was raised to 40 s. The later ones ran the 40 s version. So the timeouts do not come from that change.
> - Opening the workers in a tab (`orca terminal create`) worked every time.
> - The same afternoon the ODD Flow Orca plugin went to `errored after repeated failures` again (#6), first logged at 17:00 UTC. Whether the two are related is unknown.
>
> To investigate:
> - [ ] Reproduce a split in a worktree whose tab already holds a coordinator and one worker pane, and check whether Orca's host waits time out because the PTY starts late or because the leaf is never attached to the layout.
> - [ ] Check Orca's own logs around a failing split for layout or PTY errors.
> - [ ] Decide whether `pane.py` should fall back to a tab when a split times out and the pane is not in the layout, and report the orphan for the coordinator to close.
> - [ ] Report to Orca upstream if the pane opens but never joins the layout.

Comments: none at 2026-11-26T17:30Z.

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T1 | S2, S4 | Map the plugin host's "errored after repeated failures" rule and the plugin's failure paths | orca:explore (mapping: Orca bundle and 965-line worker exceed the parent budget; parallel with T2) | done | run_15a7193f2406, task_2e7b64999fad + correction task_1babcf1604ad; L7 |
| T2 | S3, S4 | Map Orca's split/leaf handling and pane.py's timeout path | orca:explore (mapping; parallel with T1) | done | task_f82909693ef3 + correction task_13030623d4dd; L7 |
| T3 | S4 | Send findings with options per issue to the supervisor bot | parent | done | question msg_fc0c47dd2a74; answer msg_644277c57800 (S8) |
| T4 | S8-S10 | pane.py tab fallback after a pending split timeout and failed retry, tests, orca-dispatch.md step 3, CHANGELOG | orca:write (authorized change) | done | commit 7f575b2; task_cf69e9cc7daf; RED 76/2 → GREEN 78/0 (writer); parent spot check `bash tests/pane-check.sh`: passed=78 failed=0; surface matches; candidate 4c1bcdb |
| T5 | S8 | Independent verify of T4 | orca:verify (S8 asks for it; Risk item 3: pane.py JSON output consumed by coordinators) | done | task_6d7da41c62f8 (term_51abd460, claude / claude-opus-5-5 / high), base 937c405, candidate 4c1bcdb: S8 met, S10 met (35 non-fallback scenarios byte-identical to base), S9 unmet in text mode (B1: orphan leaf missing without --json); advisory A1 (missing separator before "Orphan split leaf"). Correction task_93a8d8a78752 done (writer 82/0; parent spot check `bash tests/pane-check.sh`: passed=82 failed=0); candidate f11650c; recheck task_300662b55743: B1 fixed, A1 fixed, 35 non-fallback scenarios byte-identical to base, pane-check 82/0, no blockers. Done. Unverified: real-Orca orphan in `terminal list` (needs a live split) |
| T4R | S8-S10 | Resilience review of T4 (verification passed on a Risk item 3 change) | orca:review (lens resilience) | done | task_3b5cccd3cac6; no BLOCKER/CRITICAL, so no refute or correction; follow-ups R4-001 (WARNING: orphan cleanup is one leafId match with no re-check before the next launch), R4-002 (SUGGESTION: worst-case pane-lock hold about 170 s), R4-003 (SUGGESTION: fallback result drops split target, direction and Orca tabId) |
| T7 | S11-S13 | Plugin event handlers answer at once; background refresh with a rejection handler; regression test; README troubleshooting note; CHANGELOG bullet | orca:write (authorized change) | done | task_bbfecf5e0200; writer RED→GREEN on both regressions; parent spot checks: `orca plugin test orca-plugin` 141 pass 0 fail, `bash tests/orca-plugin-typecheck.sh` exit 0, `bash tests/orca-plugin-docs-check.sh` exit 0; surface matches; candidate 24cf270 |
| T8 | S5, S11-S13 | Independent verify of T7, plus tests/orca-plugin-typecheck.sh and `orca plugin test orca-plugin` | orca:verify (S5; Risk item 4: async event ordering, item 3: code every session loads) | done | task_47707babdfed: S11-S13 met, no blockers; burst of 200 events against a blocked refresh settles 200/200 (base 0/200), coalescing 2 reads, identical status sequence, 0 unhandled rejections; `orca plugin test orca-plugin` 141/0, docs check exit 0; typecheck observed only by the parent (exit 0); advisories A1 (pre-existing: 15 s timer and mutate background refreshes have no rejection handler), A2 (environment-dependent plugin tests), A3 (README omits the 300 s event kill) |
| T7R | S11-S13 | Resilience review of T7 (verification passed on a Risk item 4 change) | orca:review (lens resilience) | done | task_4e742c33c739; no BLOCKER/CRITICAL, so no refute or correction; follow-ups R4-001 (WARNING, pre-existing: the 15 s timer and mutate background refreshes have no rejection handler, so a rejecting timer refresh can still exit the worker; fix: catch inside refreshStatus), R4-002 (SUGGESTION, introduced: each joined event logs its own copy of the generic failure line), R4-003 (SUGGESTION, pre-existing: under a sustained event stream the coalescing loop has no cap, so openPanel's await can wait without bound) |
| T6 | S8 | #6: keep the capture running; on failure or after 5 h, send exit code and evidence-backed fix as a new question | parent | done | capture caught the failure at 17:46 UTC (L9); question msg_d8ea476afc0e sent 17:49 UTC |

## Log

- L1 (user, 2026-11-26, verbatim):

> You are the main session for one odd-flow workstream. Work under odd-flow as usual: load the odd-flow skill, follow your profile and mode, and launch workers as it says.
> Max does not read this terminal. Every question for Max, every approval, every merge request and every coordination need goes to the supervisor bot (ODDFlow Bot):
>   orca orchestration send --to bot:755c7294-67d8-4837-89e5-347221fceab7 --type question --subject "<topic>" --body-file <scratch file> --json
> Use --type question whenever you need an answer, merge requests included; the bot replies by mail. Use --type status only for information that needs no answer. Start the subject with your workstream name. Write the body to a scratch file first; do not use heredocs. Then wait for the reply: run orca orchestration check --wait, or end the turn and resume when the reply wakes you. Send each question once: an unanswered question is still open, so never resend it because your turn ended; only resend if the bot asks you to.
> - question: anything that needs Max's decision. Use a closed set of options, each with a label and a description of why.
> - Merge request (subject starts with "merge_ready:"): Max approved the result. Include the branch, commits, files touched and the verification you observed. Never merge into main or push yourself.
> - Before reinstalling or reloading the odd-flow plugin in Claude Code, Codex or Antigravity, or the ODD Flow Orca plugin, ask the bot and wait. The same applies to loading any Orca plugin, because plugins act on every session.
> - Before a writer touches files another workstream may edit, tell the bot which files.
> Commits (Max's default): commit each unit on your branch after its spot check; do not ask the bot about commits. Merging into main still needs merge_ready.
> Do not send progress updates unless asked.
>
> Follow-ups and new findings outside your scope: list them in merge_ready (or send them as status); the bot files them as GitHub issues in alvag/odd-flow. Do not open, edit or close issues yourself.
>
> Workstream: orca-stability (branch fix/orca-stability). Max approved it.
>
> Goal: two GitHub issues about Orca integration failures. Read each first with `gh issue view <n> -R alvag/odd-flow --comments` and quote the bodies and comments verbatim into your feature document:
> - #6 "ODD Flow Orca plugin went to errored after repeated failures; cause unknown". It happened again twice on 2026-11-26: once found at 14:33 UTC and fixed by `orca plugin restart`, then errored again about two hours later (first log line 17:00 UTC). Each time `orca plugin logs local.odd-flow-profiles` kept only "dropped" lines, because Orca keeps 200 lines.
> - #27 "Orca split placements time out and leave the pane outside the layout".
>
> Investigate first, read-only: read orca-plugin/ (its worker, hooks and event handlers), Orca's plugin host behavior for "errored after repeated failures" (what counts as a failure, how many, any timeouts; the installed Orca 1.4.278 app bundle and `orca plugin --help` are fair sources), and Orca's split/leaf handling. Then send me the findings for each issue as a question with options (no change / document / the fix the evidence supports, with cost and risk) before any writer changes code. Say whether the two issues are related.
>
> Notes:
> - The ODD Flow Orca plugin is errored right now. Do not restart, reload, reinstall or dev-load it, or any Orca plugin, without asking me: plugins act on every session. Reading `orca plugin logs` and `orca plugin list` is fine.
> - Do not run mutating Orca calls against other workspaces. A split or create test in your own worktree is fine if you close what you open; say what you ran.
> - A plugin fix changes code that every session loads. It needs an independent verify, tests/orca-plugin-typecheck.sh and `orca plugin test orca-plugin` before merge_ready, and a reload that Max approves.
> - odd-flow must keep working without Orca, without the Orca plugin and without an Orca bot.
> - Expected surfaces: orca-plugin/ (code, tests, README), docs/compatibility.md if behavior per Orca version changes, CHANGELOG.md (own bullets under [Unreleased] only), odd/tasks/<your feature doc>. skills/odd-flow/scripts/pane.py, tests/pane-check.sh and skills/odd-flow/references/orca-dispatch.md only if the #27 fix needs them; tell me first.
>
> Parallel workstreams (do not edit their files; tell me if you must):
> - test-hygiene (#2, #3, #4): tests/*.sh (scratch handling in most of them, parent-guard-check sandbox assertions) and tests/orca-plugin-typecheck.sh pins.
> - Commit messages may reference the issues ("Refs #6"); code and comments must not mention issue numbers, specs or tasks. Do not push and do not touch the GitHub issues; I close them after the push.

- L2 (2026-11-26 17:31 UTC): state at start. `orca plugin list --json`: `local.odd-flow-profiles` loaded from `/Users/max/Personal/repos/odd-flow/orca-plugin` (local-path, contentHash `0b6d5e90...`), `restarts: 3`, hooks `agent.prompt.before`. `orca plugin logs local.odd-flow-profiles --json` holds only "event agent.status.changed dropped: plugin local.odd-flow-profiles is errored after repeated failures" warnings. Orca app 1.4.278. Orca logs: `~/Library/Application Support/Orca/logs/daemon.log` and `daemon.log.1`. app.asar extracted read-only to scratch for the explorers.
- L3 (2026-11-26 17:31 UTC, supervisor bot status msg_76a780b345bf, verbatim leads, unverified): "stablyai/orca#17297 (closed): `orca terminal split` against a tab that is parked (backgrounded long enough that the renderer unmounted its TerminalPane) reliably times out with \"Timed out waiting for split pane handle\"; the same tab succeeds right after creation or after focusing it." / "stablyai/orca#32169 (closed): split reports the timeout but the pane is created and the command runs." / "PR stablyai/orca#30563 and #30439 (merged, \"dark, layout-owner build only\"): a timed-out CLI split leaves no pane, and a split whose pane closes early answers at once. Both only in builds where main owns the layout." / "PR stablyai/orca#30861 (OPEN): turns the layout-owner path on for shipped desktop builds. Until it ships, released builds (1.4.278 is still the latest) keep the window-owned layout, where a timed-out split can leave the pane outside the layout, which is what we saw." / "For #6 I found nothing upstream about plugins going errored after repeated failures, apart from #40722/PR #40729 (a dev-load hash mismatch, fixed 2026-11-11)."
- L4 (2026-11-26 17:32 UTC): launched T1 and T2 explorers (codex / gpt-6-luna / medium). Both placements were splits of this worktree's tab and succeeded without a timeout: T1 split-right of the coordinator term_086a31b4, T2 split-below of term_2ecf31fe; `terminal wait --for tui-idle` satisfied for both. The coordinator's tab was likely not focused by Max at the time (he does not watch this terminal), so this is one data point against "any background tab times out".
- L5 (2026-11-26 17:33 UTC, supervisor bot status msg_7690684bf0b8): Max approved a restart; the bot ran `orca plugin restart local.odd-flow-profiles` at 17:33 UTC (status running) and saved the pre-restart logs. The parent started a read-only capture (background task bsrkrim9v, scratch `plugin-capture/logs.jsonl` and `status.jsonl`) that polls `orca plugin logs` and `orca plugin list` every 20 s for up to 5 h, to keep the first failure before the 200-line ring rolls it over.
- L6 (2026-11-26 17:34 UTC): T1 and T2 sent worker_done with a one-paragraph summary only, no Return-format sections or citations; backticks in T1's `--body` were shell-expanded. One correction each (follow-ups ctx_4eeecfd95d14 / task_1babcf1604ad and ctx_cda509536680 / task_13030623d4dd, same terminals) asks for the full cited report via `--body-file` plus named gaps. Summary claims so far: T1, the supervisor escalates to errored after three failed restarts (fourth crash), only worker exit counts as evidenced, no daemon.log plugin lines in the windows; T2, the split waits for a renderer-produced pane handle, the 1.4.278 layout is window-owned, consistent with the parked-tab lead, no CLI call focuses a tab or attaches an orphan, no causal link to the plugin found.

- L7 (2026-11-26 17:36 UTC): findings, T1/T2 corrected reports (msg_1129ea0b2d14, msg_0ad48edbdaee) plus parent spot checks in the extracted bundle `out/main/index.js`.
  - #6 (verified by parent): the plugin supervisor is `o5i={maxRestarts:3,backoffMs:[500,2e3,5e3]}` with no time window. Only two things count as a failure: `worker exited unexpectedly (code ${n})` (`handleUnexpectedExit`) and `worker failed to start` (activation error). Each failure logs `warn` "<reason>; restart <k> in <ms>ms" to the plugin log; the fourth logs `error` "<reason>; marked errored after repeated failures". `markRunning` after a restart keeps the counter; it returns to 0 only on `ensureActive` of a new spec, `deactivate` (`orca plugin restart`: observed `restarts: 0` at 17:33:50 UTC) or an idle reap (`markExited(...,{crashed:!1})`), and the idle reaper skips a worker that keeps getting traffic. So four worker crashes over any span with steady `agent.status.changed` traffic make the plugin errored. After that every `agent.status.changed` event logs "event agent.status.changed dropped: ... is errored after repeated failures", which pushes the four failure lines (with the exit code) out of the 200-line ring within minutes. No event, hook or request timeout counts toward the counter in the code found. The plugin's own handlers catch their errors (`orca-plugin/src/worker.ts:720-790`, `prompt-hook.ts:34-39,72-74`); no `process.exit` or top-level throw found. Crash cause still unknown: the exit code is the missing fact. The manifest has no `storage:own` capability.
  - #27 (verified by parent): the issue's message comes from the renderer split path (`mGi`), taken when the target handle has no main-tracked live PTY. Main records a new leaf ID, notifies the renderer, then `waitForLeafInTab` waits for the renderer's graph sync to report the leaf (10 s, `appearMs`) and its PTY (30 s total, `startMs`). A pane whose PTY runs but whose leaf never reaches the synced graph times out and stays outside the layout. `--retry-split` repeats the same wait. T2's "2,000 ms" figure is wrong (`_Gi=2e3` belongs to the next class). No CLI call focuses a tab or attaches an orphan leaf. The renderer receiver was not located, so the parked-tab lead stays unproven; it fits the 1.4.278 code (graph sync owned by the window). daemon.log has no split or layout events.
  - Relation: no shared code path found. The split path does not call plugin hooks or events, and the first split timeout (16:29 UTC) came while the plugin was running (it errored at about 17:00 UTC).
  - Explorer panes closed (term_2ecf31fe, term_5676599b); dispatches released (retained, external_terminal).
- L8 (2026-11-26 17:38 UTC): Orca notice msg_a6d895408200 says the bot ended its turn without answering msg_fc0c47dd2a74. The question stays open (not resent, per the workstream rules); no option is assumed. The read-only plugin capture keeps running.
- L9 (2026-11-26 17:48 UTC): #6 root cause captured. Capture (logs.jsonl, status.jsonl in the parent's scratch) shows the plugin `running, restarts 0` at 17:33:50 UTC, `restarting, restarts 3` at 17:46:40 and `errored` at 17:47:00. Plugin log lines, verbatim: 17:46:35.876 error "[plugin:local.odd-flow-profiles] exceeded the pending event limit"; 17:46:35.881 warn "worker exited unexpectedly (code null); restart 3 in 5000ms"; 17:46:41.009 error "[plugin:local.odd-flow-profiles] exceeded the pending event limit"; 17:46:41.014 error "worker exited unexpectedly (code null); marked errored after repeated failures". No plugin log line at all between 17:33:14 and 17:46:35, so the "restart 1" and "restart 2" lines that the counter implies are absent (unexplained). Parent-verified mechanism: main `deliverEvent` in `out/main/index.js` keeps each delivered event pending until the worker replies, SIGKILLs the worker when 64 events are pending (`b5i=64`, "exceeded the pending event limit") or one event takes over 300 s (`eventTimeoutMs??y5i`, `y5i=3e5`); the worker side (`app.asar.unpacked/out/main/plugin-host-entry.js`) replies only after `await`ing each handler. The plugin's handlers `orca.events.on('agent.status.changed', () => refreshStatus())` and the same for `workspace.changed` (`orca-plugin/src/worker.ts:943-944`) return the shared in-flight refresh promise, which keeps looping while `refreshAgain` is set (`worker.ts:761-787`). So during an event burst every event waits for the whole refresh (profile.py per agent, Orca worker-list CLI), 64 pile up and the host kills the worker; with backoffs of 0.5, 2 and 5 s the burst kills each restart too. Exit code null = SIGKILL from the host. The plugin is errored again since 17:46:41 UTC; not restarted.
- L10 (2026-11-26 17:49 UTC): Orca notice msg_a9e58033dc55 says the bot ended its turn without answering msg_d8ea476afc0e; the question stays open, not resent, no option assumed.
- L11 (2026-11-26 17:53 UTC): bot msg_772926be4379 relays Max's choice (S11) and the review requirement (S12); the bot restarted the plugin at 17:53:48 UTC.
- L12 (2026-11-26 17:58 UTC): merge_ready for #27 sent (msg_a9bd3e1634e1); Orca notice msg_b9b0611d5ac0 says the bot ended its turn without answering; it stays open, not resent.
- L13 (2026-11-26 18:03 UTC, bot msg_2834465f6c56): 7f575b2 merged into main as a28296c and pushed (main 6ca867d); #27 closed; follow-ups R4-001..003 filed as #29. Next for #6: commit T7 after T8 verify, then rebase fix/orca-stability onto main 6ca867d before its merge_ready.
