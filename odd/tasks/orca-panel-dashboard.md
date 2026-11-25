# Orca panel dashboard

Objective: turn the odd-flow Orca panel into a dashboard that shows what the coordinator and its workers are doing, what needs the user, the feature's tasks and a better profile and mode selector, without looking at terminals. Branch: `feat/orca-profile-plugin` (design call: the plugin is not merged yet). Delivery: `ask-on-risk`. Runner: `cd orca-plugin && orca plugin test .` and `bash tests/run.sh`.
Profile: `claude-gpt`.

## Specs

### User requirements (verbatim, Spanish)

- S1 (user): "me gustaria adoptar algunos elementos que se muestran en la imagen, por ejemplo que tenga colores, ver si es posible listar las tareas del flujo, ir lancandolas como completadas, ir listando los workers activos, el tiempo que levan corriendo, entre otros datos que podrian ser de utilidad" (reference image: orca-pitwall agent cards, https://github.com/sonthh/orca-pitwall).
- S2 (user, the why): "saber qué está pasando sin mirar las terminales, enterarte cuando algo necesita tu atención"
- S3 (user): "ver un listado de las tareas, cualestan hechas, pendientes, trabajando, bloqueadas, todo sacado desde el archivo de ODD o desde engram"
- S4 (user): "ver en un listado los workers que se van lanzando y el tiempo que lle van corriendo"
- S5 (user): "un mejor UI del selector de perfil y mode"
- S6 (user, layout): "si me gusta la A" — layout A, everything stacked: attention, session, tasks, workers. Mockup: visual companion `layout.html`, option A.
- S7 (user, later, out of scope now): "La B la dejariamos cuando quizas mas adelante implementemos unas tabs como en Pitwall que digan this - all ... ahi se muestra de todas las sesiones y no solo de la sesion seleccionada"
- S8 (user): "'Necesita tu atención' podriamos aplicarlo al agente principal tambien?" — answered yes.
- S9 (user, worker rows): "en este bloque no se ve bien cuando pasa a una segunda linea" — fixed by the two-line row in `layout-v2.html` (accepted with S10).
- S10 (user): "si, me convence, sigue con eso" — accepting "Current work" for flows without a feature document (below).
- S11 (user): "si, vamos con la 1" — approach 1.
- S12 (user, 2026-11-25): "si, agrega el aviso en la barra de estado" — the status bar also signals attention (Design item 5).
- S13 (user, 2026-11-25, after the live check): "no se ve para nada como se venia en lo que me mostraste en el navegador" then "pasemos a HTML propio como Pitwall." — the panel moves to an HTML panel (approach 2) that reproduces the approved mockup (`layout.html` option A, `layout-v2.html`); the worker data layer (worker.ts, dashboard.ts) stays.
- S14 (user, 2026-11-25): approved the HTML panel design ("1. Si") and authorized the parent to approve development builds of the plugin while their grants stay exactly as today ("2. Si"); any new grant goes back to the user.
- S15 (user, 2026-11-25): "el panel debería mostrar solo la sesión de la pestaña activa". Orca 1.4.274 exposes no focused tab or terminal to plugins (workspace.readContext/workspace.changed list the focused workspace's terminals without focus; agents.list and orca terminal list --json carry no focus field). Approved approach ("si, me sirve"): show one session at a time; follow the session whose agent last changed status to working (agent.status.changed), with a compact session selector to pin another; "no comitees hasta ver como queda en funcionamiento" — no commit until the user checks it live.
- S16 (user, 2026-11-25): "Feature tasks" shows the same doc in every session on the branch. Approved ("si, implementalo así"): a feature doc belongs to the open session whose Orca tasks most recently cite it (task spec text contains the doc path, newest task created_at wins); a doc no open session cites falls back to today's branch rule (shown to sessions on that branch). A session that neither owns a doc nor gets one by fallback shows no Feature tasks card (its own Current work if any). Handoff (Claude to Codex): closing the old session or launching the first worker from the new one moves the doc. User concern: a second session opened for research must not show or take the doc unless it launches a worker citing it.

### Goals, non-goals, anti-goals

- Goals: one glance at the panel tells the user (a) whether the coordinator or any worker needs them, and since when; (b) which workers were launched, their state, agent and model, and how long they ran or have run; (c) the feature's task list by status; (d) the current profile, its role routing and the mode, switchable with clearer controls.
- Non-goals: context usage, cost, tool-call or subagent feeds (Pitwall reads Claude transcripts and tool hooks for those; the user can install Pitwall alongside). The "This / All sessions" tabs (S7). Writing to `odd/tasks` or Engram from the plugin. Reading Engram. Notifications or sounds outside Orca.
- Anti-goals: a panel that confidently shows stale or wrong status; slowing Orca with heavy polling; breaking today's selector, Reset, status bar or Toggle mode behavior; exposing worker spec text in the panel.

### Constraints

- Orca components kit only (`orca-plugin/.orca/types/orca/index.d.ts`): `Tone` is `neutral | accent | success | warning | danger` (line 193); no custom CSS. `RelativeTime` keeps a time current with no polling (line 680; `format: 'duration'` reads "5m").
- `agents.list` returns `state: working | blocked | waiting | done` and `stateStartedAt` (line 114); `agent.status.changed` carries the same (line 127).
- Execution stays `trusted-worker` with today's capabilities (`agent:read`, `workspace:read`, `settings:own`). A feature that needs a new capability (for example `workspace:write` to focus a terminal) is out of scope. Any manifest change needs the user's re-approval in Orca.
- Orca sends no orchestration or task events to plugins: the worker refreshes on `agent.status.changed`, `workspace.changed` and its existing 15 s timer (`orca-plugin/src/worker.ts:29`).

### Approaches

1. Extend the current component panel: the worker gathers more data and the panel draws it with kit components. Picked (S11): reuses the selector, tests and worker detection; live times for free; no new capability. Trade-off: five tones, no custom styling; refresh by agent events and timer.
2. Rewrite as an HTML panel like Pitwall: full visual freedom, but a rewrite of panel and tests, loses native theming; mostly aesthetic gain.
3. Install Pitwall alongside and add only tasks and workers here: two panels to watch, works against S2; still needs the tasks and workers work. Compatible with 1 later.

### Design

Layout A (S6), top to bottom, per coordinator session in the focused workspace (a non-worker agent row, as today):

1. Attention callout (`Callout tone="warning"`), shown only when something needs the user:
   - the coordinator's `state === 'blocked'` → "Needs you" + `RelativeTime` since `stateStartedAt`;
   - any of its workers with agent `state === 'blocked'`, or a non-empty `attention` in `worker-list` → one line each: worker title, agent, time.
   - The coordinator's `state === 'waiting'` is not an alert: the session card shows "Waiting for you" muted with its time.
2. Session card: title, agent badge, state badge with `RelativeTime`; Profile select (as today) with a muted role summary under it (`<role> → <agent> · <model> · <effort>` from the selected profile's roles); Mode as a two-option toggle (organic / full-delegation) instead of a select; Reset to defaults and its note (texts unchanged); source lines (session or default) kept, muted.
3. Work section, one of:
   - Feature tasks, when a feature document matches (S3): title (document H1), path and branch muted; `Progress` with done / total; a counts line ("8 of 11 done · 1 working · 1 blocked · 1 pending"); open tasks listed with a status badge (pending neutral, in_progress accent, blocked danger, dropped neutral muted) and their Work text truncated; done tasks folded in a `Collapsible` ("8 done").
   - Current work, when no document matches (S10): the newest Orca Run created by this coordinator's terminal: its objective as title, "No feature document" muted; its tasks with status badge and duration; "Last result": the newest completed task's result summary; a git line: branch, number of changed files, last commit short hash and its `RelativeTime`.
   - Neither (organic inline work, no Runs): the git line alone.
4. Workers (S4, S9): header "Workers" with "<n> active"; rows for workers dispatched by this coordinator, newest first, active first; each row two lines: line 1 status badge + title truncated with ellipsis, never wrapping; line 2 muted `agent · model · time` where time is `RelativeTime` (duration) since start while active, or "took <duration>" once finished; finished rows beyond the newest few folded ("6 finished earlier").

5. Status bar (S12): while any attention item from item 1 exists for a coordinator in the focused workspace, the existing status item reads `odd: ⚠ needs you` and its tooltip names what is waiting (for example "T11 explore — codex, blocked 2m" or "This session is blocked"); otherwise its text and tooltip stay exactly as today. Clicking still opens the panel. It reuses the 15 s refresh and the data that refresh already reads (`agents.list` and `worker-list`); it never runs `task-list` or git. Keep today's UTF-16 length limits (`orca-plugin/src/worker.ts:30`).

Status badges map to tones: working → accent, needs you / blocked → warning, done / succeeded → success, failed / lost / blocked task → danger, pending / other → neutral.

Data sources (worker side):

- Agents: `agents.list` (already used), adding `stateStartedAt` to `Agent` in `protocol.ts`.
- Workers: `orca orchestration worker-list --environment local --json` (already run for worker detection) joined by `taskId` with `orca orchestration task-list --environment local --json --full` for title, status, `created_at`, `completed_at`, `created_by_terminal_handle`, `run_id` and result. Filter to tasks whose `created_by_terminal_handle` equals the coordinator row's `terminalId`. Never send `spec` to the panel.
- Feature document: in the coordinator's workspace root, `odd/tasks/*.md` whose header line names the workspace's current branch (`Branch: \`<branch>\``); several matches → newest modification time. Parse the `## Tasks` table (`| ID | Specs | Work | Route | Status | Evidence |`, `skills/odd-flow/references/tracking.md`). A document without a parseable table counts as no match.
- Git: `git -C <workspace root> branch --show-current`, `status --porcelain`, `log -1 --format=%h%x00%ct`.

### Builder-check calls (parent, 2026-11-25)

- Attention for workers: only dispatches that are still active (dispatch `state` not terminal: not succeeded, failed, cancelled or lost) count, when the agent on their terminal reports `blocked` or the dispatch has a pending question or escalation. `attention` values `unverifiable` and `root_completion` never alert (every settled dispatch carries them).
- Worker agent and model: from `worker-list`'s `agent` field (observed as `codex/gpt-6-luna`); effort is not shown. When the field is missing, line 2 shows only the time.
- Worker badge precedence: the dispatch `state` from `worker-list` decides the badge and "active". The `agents.list` state of the dispatch's terminal overlays it (`blocked` → needs you) only while the dispatch is active and is the newest dispatch on that terminal (terminals can host several dispatches).
- Workspace root (P5): match `workspace.readContext` against `workspace.list` for `path`; if that fails, use the path part of the `<id>::<path>` workspace id that `worker-list` reports for this coordinator's dispatches; if neither resolves, hide the tasks and git parts with one muted line saying the workspace path is unavailable.
- P3 result (T0): from a Run-bound shell, `task-list` and `worker-list` without `--run` stay scoped to the bound Run even with pane variables removed; `--run <id>` reads any Run; `run-list --environment local --json --full` lists all Runs with `coordinator_handle` (missing on older Runs) and `created_at` (ISO). So the worker never relies on binding: `run-list` → Runs whose `coordinator_handle` is the coordinator terminal, newest 10 → per Run `task-list --run <id> --json --full` and `worker-list --run <id> --json`. A `run_not_found` Run is skipped.
- Workers scope: dispatches of every Run whose `coordinator_handle` (`run-list --full`) or task `created_by_terminal_handle` is this coordinator's terminal, cached incrementally like today's dispatch scan; active first, then newest.

### HTML panel (S13, supersedes the component rendering of Design items 1-4)

- Manifest: the panel keeps `id`, `title` and `icon`; `ui` becomes `"html"` and `entry` a TS frame entry (`src/panel/main.ts`), transpiled by Orca, no bundler (Pitwall pattern). Commands, keybinding, events, status item, settings and capabilities stay; Orca will ask for re-approval because the panel entry changes.
- Files: `src/panel/main.ts` (mount, `orca.plugin.request` for `state`/`use`/`sessionMode`/`clear`, `orca.on` for `agent.status.changed`/`workspace.changed`/`theme`, delegated clicks and change events), `src/panel/render.ts` (pure, escaped HTML-string renderer from `State`), `src/panel/styles.ts` (CSS string), `src/panel/render.test.ts`. The old `src/panel.tsx`, `src/panel.test.tsx` and `src/panel.check.ts` are removed once their behaviors are covered by render and main tests.
- Look: reproduce the approved mockups (`layout.html` option A and `layout-v2.html`, visual companion): dark cards with a 1 px border and 8 px radius, filled pill badges in five colors (neutral gray, accent blue, success green, warning amber, danger red) with readable text, an amber-bordered attention callout, uppercase muted section headers with a right-aligned count, the two-line worker rows, a thin green progress bar, a segmented mode control with the active side filled blue, and the profile select. Base colors and fonts come from Orca's theme variables (`--orca-background`, `--orca-card`, `--orca-border`, `--orca-foreground`, `--orca-muted`, `--orca-font-sans`, `--orca-radius`); the five status colors are fixed per theme (`html.dark` / `html.light`) so they read in both.
- Session card trimmed: under the profile select, show the explore, write and verify routes; the other roles fold behind "<n> more roles". The source lines ("session (CLAUDE_CODE_SESSION_ID)", "profile claude-gpt") collapse into one muted line ("Session choice" or "Default profile").
- Live times: the renderer prints durations from epoch ms; `main.ts` refreshes the time text every 15 s while the panel is visible (no host RelativeTime in HTML).
- Behaviors kept from the component panel: immediate apply, controls disabled while saving, feedback lines ("Profile switched…", errors, "Session choices reset."), "Reset to defaults" and its note, worker rows without controls, section errors inside their section, everything in Design items 1-4.
- Approval check: the first build ships with real data, and the parent shows the user `orca plugin shot` captures in dark and light before polishing.

### Left to the builder

- A warning tone for the status item if `statusBar.update` supports one; otherwise text only.
- Exact kit components for the mode toggle (a segmented control if the kit has one, otherwise two `Button`s with solid / outline variants) and for folded lists.
- How many finished workers stay unfolded (suggested 3) and the truncation width.
- Caching and timeouts for the extra commands, as long as one refresh stays bounded and a failure in one source shows a danger line in its section without hiding the others.
- Unit structure of the code (new modules are fine).

### Open premises (probe before building)

- P3: `task-list --environment local --json --full` run from the plugin worker (no bound Run) returns tasks across Runs with the fields above, including a result summary for completed tasks.
- P4: an agent waiting on a permission or startup prompt (for example Codex "Hooks need review") reports `state: 'blocked'` in `agents.list`.
- P5: `workspace:read` gives the focused workspace's root path and branch to the worker.
- P6: `RelativeTime` and `Progress` render in the installed Orca (`ui.catalog` 3, Orca >= 1.4.247).

## Tasks

| ID | Specs | Work | Route | Status | Evidence |
|---|---|---|---|---|---|
| T0 | P3 | Probe `task-list`/`run-list --full` with an isolated env (no Run binding): fields and timestamps | parent (read-only probe) | done | Bound shell keeps Run scope without `--run`; `--run` reads other Runs; `run-list` global with `coordinator_handle`; design and plan T2 updated to per-Run reads |
| T1 | S3, S4, S8-S10 | Pure dashboard derivations and types (`dashboard.ts`, `protocol.ts`) | orca:write | done | commit c44b2d7; ctx_bb4a0de49c37 (codex/gpt-6.2-sol): RED missing module, GREEN orca plugin test 77/77, validate ok; parent spot check 77/0; exports and test names match the plan. Note: worker-list exposes a pending question as input, no standalone escalation category |
| T2 | S2-S4, S10 | Worker gathers workers, tasks, runs, feature doc and git into `State.dashboards` | orca:write (after T1) | done | commit a2e1262; ctx_0ad843e0901c: RED 4 dashboard assertions failed, GREEN orca plugin test 82/0, validate ok (capabilities unchanged), run.sh 20/0, Open profiles and Toggle mode outputs matched base; parent spot check 82/0. Cold cache reads only the newest 10 coordinator Runs. A deleted Run's task-list exits 1 with run_not_found on stdout; skipped |
| T3 | S2, S12 | Status bar attention text and tooltip | orca:write (after T2) | done | commit 44b8e02; ctx_543e9b0c6125: RED 4 failed, GREEN orca plugin test 87/87, validate ok, Open profiles and Toggle mode match base; parent spot check 87/0. Alerts on a blocked coordinator, a blocked worker terminal or an active dispatch with attention input/escalation (L5) |
| T4 | S5, S6, S9, S10 | Layout A panel: attention, session selector, tasks or current work, workers | orca:write (after T3) | done | commit 46cf8ed; ctx_548882ec266a: RED 9 new panel tests failed, GREEN orca plugin test 96/0, check ok (3 scenarios), validate ok (grants unchanged), run.sh 20/0; adapted only Mode/header queries (L6); parent spot check 96/0. Badge accepts only text children |
| T5 | all | Independent verify; live check of P4-P6 after re-approval | orca:verify, then parent | done | verify ctx_6857e57bdbae on f664c20..46cf8ed: S3, S5-S9, S11, S12 met; blockers B1 settled states stopped/abandoned/unsupervised counted active, B2 status scan reads all pages each tick, B3 real ready/dispatched values get neutral badges and no time, B4 worker attention since = dispatch start; advisories A1-A7; typecheck and P4/P6 unverified . Closed: B1-B4 fixed in T5c (re-check met); typecheck now runs (T6 on); P5 confirmed live (feature doc and branch shown); P6 moot after S13 (HTML panel renders its own times and bar); full verify of the HTML panel in T8 (met). P4 (blocked state from a permission prompt) still unverified live |
| T5c | S1, S2, S4, S10 | Correction batch for B1-B4, A1, A3 | orca:write | done | commit 0c0c9a6 (tree identical to candidate 17715f7); ctx_96d4f14421ba: RED 9 failed, GREEN orca plugin test 105/0, check ok, validate ok, preservation probe matched; parent spot check 105/0; candidate 17715f7 (base 46cf8ed); re-check ctx_050407655661 ; re-check ctx_050407655661: B1-B4 met, no blockers (real orca 1.4.274 status ticks [3,1,1] vs base [3,3,3]); A1 script warning kept, A3 annotated cells parse; unverified: tsc, A1 panel-open-error branch |
| T6 | S4 | Live check finding: Workers shows "Could not load all Orca work for this session." for this coordinator; diagnose and fix, and name the cause in the error | orca:write | done | commit d1caca1. Root cause: T5c renamed the active-state helper to isActiveDispatch but two cached-run paths still called the undefined ACTIVE_DISPATCH, so the second state request threw a ReferenceError that dashboardRuns swallowed into the generic error; tests missed it (no repeat request with a warm cache) and no typecheck ran. ctx_764508c30289: 107/107, live state --json 14 workers, errors {}; parent spot check 107/0, live state 14 workers no errors; tsc 7.0.2 (npx cache) shows only missing @types/node noise. Section errors now name the command and cause |
| T7 | S13, S14 | HTML panel per "HTML panel (S13)" (plan Task 7) | orca:write | done | commit 4f8d5e2. task task_945446925e09, dispatch ctx_4fa561f53472 (antigravity/gemini-4-hydrogen, profile claude-gemini) ; worker_done: 103/103, validate ok, tsc clean, run.sh 20/20; parent spot check 103/0 and filtered tsc clean; manifest diff only ui/entry; dark shot matches the mockup; light shot not captured (Orca kept the dark theme). Awaiting user review before commit ; follow-ups L8 (waiting-for-you badge, reset/profile/mode notes as tooltips), L9 (icon refresh) and header time on one line; parent spot check 103/0, tsc clean; dark shot v3 reviewed |
| T8 | S1-S14 | Independent verify of d1caca1..4f8d5e2 (HTML panel) | orca:verify | done | task task_e09d9249b055, dispatch ctx_e064da7f7e83 (claude/claude-opus-5-5/high) : met, no blockers (S13, L8, L9 all met; light theme by static CSS review; live light shot unverified). Advisories: A1 full innerHTML redraw every 15 s and on each agent.status.changed closes an open profile select and drops focus (spec says refresh the time text); A2 tooltips dropped the mode-override qualifier (shortening requested in L8, kept); A3 unknown session profile shows the first option as active; A4 blocked badge text "needs you" (per design); A5 worker.test.ts:889 fails in long checkout paths, pre-existing; A6 no redraw on unhide. Report /private/tmp/claude-501/-Users-max-Personal-repos-odd-flow/7fabb1c6-2490-48b8-8933-03cecc54072c/scratchpad/T8-report.md |
| T9 | S13 | Fix T8 A1, A3, A6 and keep the verifier's contract probes as a test | orca:write | done | commit 24ae4ff. task task_037d35c5c8b8, dispatch ctx_3fb184286468 (antigravity/gemini-4-hydrogen) : time-only 15 s tick, redraw deferred while a control has focus, details state kept, unknown profile "(not found)", update on unhide, panel-contract.test.ts added; 113/113, tsc clean, run.sh 20/20; parent spot check 113/0, tsc clean; dark shot reviewed |
| T10 | S15 | One session at a time: follow the last active session, selector to pin | orca:write | done | commit 8291edf. task task_cd3a4050c4bc, dispatch ctx_8fcbbd2966ec (antigravity/gemini-4-hydrogen) ; worker_done: follow/pin selection, dimmed controls were a background refresh disabling them (fixed), ODD Flow rename; 118/118, validate, tsc, run.sh 20/20. Live shot pending the user's approval of the renamed build; no commit until the user checks it live ; live checked by the user with two sessions |
| T11 | S16 | Feature doc ownership by the newest citing session, branch fallback | orca:write | done | commit bb64508. task task_cc3e62039cd8, dispatch ctx_956b503b94b5 (antigravity/gemini-4-hydrogen) ; worker_done: featureOwners + selectFeatureDoc, 125/125, validate, tsc, run.sh 20/20. Awaiting the user's live check; no commit yet ; live: this session owns the doc, the second Claude tab shows none; user: "se ve bien, comitea" |
| T12 | L11 | Rename the remaining "odd-flow profiles" texts to ODD Flow | orca:write | done | commit c120929. task task_30ae9836b39c, dispatch ctx_b2cd9924c132 (codex/gpt-6.2-sol) ; worker_done: ids, grants and key-based discovery unchanged; 125/125, validate, tsc, run.sh 20/20, no old-label matches; live: status tooltip "Open the ODD Flow panel", status click opened the panel. Parent spot check 125/0, rg clean |

## Log

- L1 (user, 2026-11-25): "Funcionalmente parece ir bienn. Pero me gustaria mejorar algunos aspectos de la UI. La siguiente image nes referncial [...] me gustaria adoptar algunos elementos que se muestran en la imagen, por ejemplo que tenga colores, ver si es posible listar las tareas del flujo, ir lancandolas como completadas, ir listando los workers activos, el tiempo que levan corriendo, entre otros datos que podrian ser de utilidad. revisa este repo para isnpirarte https://github.com/sonthh/orca-pitwall"
- L2 (parent, 2026-11-25): explore E1 (ctx_088d5ba5fc02 + follow-up ctx_640ba5d2eaf6, codex/gpt-6-luna) mapped Pitwall (MIT, trusted-worker, data from Claude transcripts and agent.tool hooks), the kit, worker-list fields and the tracking format. Parent corrected one claim: the kit has `RelativeTime` (live, no polling), and `agents.list` has `blocked` and `stateStartedAt`.
- L3 (parent, 2026-11-25): brainstorming with the visual companion: layout A chosen; two-line worker rows; "Current work" for small flows; approach 1. Design written here; builder check next, then user approval, then the plan.
- L4 (parent, 2026-11-25): builder check (general-purpose subagent) raised 5 questions; 4 settled as parent calls (Builder-check calls); status bar question went to the user → S12. User: "si, aprobado" (design approved). Plan written to `odd/tasks/orca-panel-dashboard-plan.md`; tasks T0-T5 above.
- L5 (parent, 2026-11-25): T3 writer asked how to tie workers to a coordinator in the status path (agents.list and the concise worker-list carry no owner). Parent answered A: the status item is focused-workspace-wide; alert for a blocked coordinator row, or an active dispatch whose terminal is a blocked agents.list row in the focused workspace; no ownership lookup, no task-list/run-list/git in the status path.
- L6 (parent, 2026-11-25): T4 writer asked to adapt existing panel tests that query the Mode Select and the old combined header, both replaced by layout A. Parent answered A: adapt only those queries, keep behavior and assertion intent, list each adapted assertion.
- L7 (parent, 2026-11-25): live check after T5c: kit Badge tone="accent" (panel.tsx:115) and Button variant solid render near-neutral in Orca 1.4.274 (orca plugin shot, themeApplied false); the session card is crowded (10 role lines). Parent admitted the mockup used free CSS never checked against kit rendering. User chose approach 2 (S13). Next: recon of Orca HTML panels and Pitwall's panel, then design update, plan and writers.
- L8 (user, 2026-11-25, reviewing the T7 dark shot): "si, corrige el badge" (coordinator 'done' shown as green done → neutral "waiting for you") and, about the three lines under Reset to defaults, "creo que esto tampoco iria o dejar un texto menos extenso". Parent call: remove the three lines, keep them as short hover tooltips on Reset, Profile and Mode; this supersedes the visible reset note kept since L35. Sent to the T7 writer as a follow-up.
- L9 (user, 2026-11-25): "el refresh dejalo como un icono". Sent to the T7 writer: icon-only refresh button with aria-label and title "Refresh".
- L10 (user, 2026-11-25): "ya lo probé en tema claro, se ve bien" — light theme of the HTML panel checked live by the user; the T8 unverified light-theme item is closed. Remaining unverified: P4 (blocked state from a permission prompt).
- L11 (user, 2026-11-25): panel title "ODD Flow" and "cambia también el comando". Parent call: commands "ODD Flow: Open panel" and "ODD Flow: Toggle mode"; all ids unchanged. Manifest added to T10's surfaces. The new approval text differs from S14's standing authorization, so this reload goes to the user.
- L12 (user, 2026-11-25): "si, aprueba" — approved the renamed build (panel "ODD Flow", commands "ODD Flow: Open panel" and "ODD Flow: Toggle mode", same grants); its approval text is the new baseline for the standing authorization of S14.
- L13 (user, 2026-11-25): "si, lánzalo" — rename the remaining "odd-flow profiles" texts (manifest name, status tooltip, open-panel command messages and tests, README intro) to ODD Flow.
