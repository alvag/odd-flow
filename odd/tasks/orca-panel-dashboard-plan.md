# Orca panel dashboard Implementation Plan

> **For agentic workers:** this plan runs under odd-flow full delegation: the coordinator launches one bounded `write` worker per task below, in order, each with its task text, `## Allowed edit surfaces` and `## Verification`. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** turn the odd-flow Orca panel into a layout-A dashboard (attention, session, tasks or current work, workers) with a status bar attention signal.

**Architecture:** pure parsing and derivation functions live in a new `orca-plugin/src/dashboard.ts`; `worker.ts` gathers the raw sources (agents, Orca CLI lists, feature documents, git) and attaches one `Dashboard` per coordinator to `State`; `panel.tsx` renders it with Orca kit components. The status bar reuses only the data its 15 s refresh already reads.

**Tech Stack:** TypeScript, Orca plugin API 1 (`trusted-worker`, `ui: components`), `orca/testing` (`mockHost`, `mount`, `mountWorker`), Node child processes for `orca` and `git`.

**Spec:** `odd/tasks/orca-panel-dashboard.md` (read it whole; Design and Builder-check calls are binding).

## Global Constraints

- Components only from `orca-plugin/.orca/types/orca/index.d.ts`; `Tone` = `neutral | accent | success | warning | danger`; no custom CSS.
- Live times use `RelativeTime` (`format: 'duration'`) with epoch milliseconds; never a panel timer.
- Manifest capabilities stay `agent:read`, `workspace:read`, `settings:own`; execution stays `trusted-worker`.
- Status item text <= 64 and tooltip <= 256 UTF-16 code units (`worker.ts:31-32`); status refresh never runs `task-list`, `run-list` or `git`.
- Orca CLI calls run with `isolatedEnv()` so the calling pane's Run binding never scopes them (`worker.ts:306`, `worker.ts:328`).
- Worker spec text never reaches the panel or the logs.
- Existing texts stay: "Reset to defaults", the reset note, "Session choices reset.", the profile and mode switch hints, Toggle mode and Open profiles behavior.
- Badge tones: working → accent; needs you / blocked agent → warning; done / succeeded → success; failed / lost / blocked task → danger; pending / other → neutral.
- Artifacts in English.

## Review Focus

- Orca timestamps come in two shapes: `created_at: "2026-11-25 15:56:54"` (UTC, no zone) and `completed_at: "2026-11-25T16:00:15.238Z"`; both must parse as UTC epoch ms, and an unparseable value gives `null`, never `NaN` (Task 1 test `parses both Orca timestamp shapes`).
- A terminal that hosted several dispatches: a `blocked` agent state marks only the newest still-active dispatch on that terminal (Task 1 test `attributes a blocked terminal only to its newest active dispatch`).
- One failing source (git outside a repo, Orca CLI timeout, unreadable `odd/tasks`) shows a danger line in its own section and leaves the others rendered (Task 2 test `keeps other sections when one source fails`; Task 4 test `shows section errors without hiding other sections`).
- A feature document with no `## Tasks` table, a header-only table, or `\|` inside a Work cell never throws; no table → no match, escaped pipes stay in the text (Task 1 tests `ignores documents without a task table`, `keeps escaped pipes in work text`).
- A coordinator with no Runs, no workers and no feature document (organic inline work) shows the git line only, with no empty headings (Task 4 test `shows only the git line when there is no work data`).

---

### Task 1: Dashboard derivations (pure)

**Files:**
- Create: `orca-plugin/src/dashboard.ts`, `orca-plugin/src/dashboard.test.ts`
- Modify: `orca-plugin/src/protocol.ts` (new exported types below; `Agent` gains `stateStartedAt?: number`)

**Interfaces:**
- Produces (in `protocol.ts`):
  - `type TaskStatus = 'pending' | 'in_progress' | 'done' | 'blocked' | 'dropped'`
  - `type FeatureTask = { id: string; work: string; status: TaskStatus | 'unknown' }`
  - `type FeatureDoc = { path: string; title: string; branch: string; tasks: FeatureTask[] }`
  - `type WorkerRow = { dispatchId: string; title: string; agent: string | null; state: string; active: boolean; needsYou: boolean; startedAt: number | null; endedAt: number | null }`
  - `type CurrentWork = { objective: string; startedAt: number | null; tasks: { title: string; status: string; startedAt: number | null; endedAt: number | null }[]; lastResult: { title: string; subject: string } | null }`
  - `type GitSummary = { branch: string | null; changedFiles: number; lastCommit: { hash: string; at: number } | null }`
  - `type Attention = { label: string; since: number | null }`
  - `type Dashboard = { terminalId: string; attention: Attention[]; feature: FeatureDoc | null; current: CurrentWork | null; git: GitSummary | null; workers: WorkerRow[]; errors: Partial<Record<'workers' | 'feature' | 'git' | 'workspace', string>> }`
  - `State` gains `dashboards?: Record<string, Dashboard>` keyed by coordinator `terminalId`.
- Produces (in `dashboard.ts`, raw input types exported alongside):
  - `parseOrcaTime(value: unknown): number | null`
  - `parseFeatureDoc(path: string, markdown: string): FeatureDoc | null` — title from the first `# ` line; branch from the first `Branch: \`<b>\`` in the header; tasks from the `## Tasks` table by header names `ID`, `Work`, `Status`; null without a parseable table.
  - `selectFeatureDoc(docs: { path: string; mtimeMs: number; text: string }[], branch: string): FeatureDoc | null` — branch match, newest `mtimeMs` wins.
  - `workerRows(input: { dispatches: RawDispatch[]; tasks: RawTask[]; agents: Agent[]; coordinator: string; runs: RawRun[] }): WorkerRow[]` — scope and precedence exactly as the spec's Builder-check calls; order: active first, then newest `startedAt`.
  - `attentionItems(coordinator: Agent, workers: WorkerRow[]): Attention[]`
  - `currentWork(runs: RawRun[], tasks: RawTask[], coordinator: string): CurrentWork | null` — newest Run with `coordinator_handle === coordinator`; `lastResult.subject` from the newest completed task's `result` JSON `subject`.
  - `parseGit(branch: string, porcelain: string, log: string): GitSummary` — `log` is `%h%x00%ct`.

- [ ] **Step 1: Write failing tests in `dashboard.test.ts`**: `parses both Orca timestamp shapes` (`"2026-11-25 15:56:54"` → `Date.UTC(2026,10,25,15,56,54)`; `"2026-11-25T16:00:15.238Z"` → its epoch; `"x"` → `null`); `parses the feature task table` (fixture: the `## Tasks` table of `odd/tasks/orca-profile-plugin.md` trimmed to 3 rows → ids, statuses, title "Orca profile and mode panel plugin", branch `feat/orca-profile-plugin`); `ignores documents without a task table`; `keeps escaped pipes in work text`; `selects the newest document for the branch`; `attributes a blocked terminal only to its newest active dispatch`; `never alerts on unverifiable or root_completion attention`; `maps worker agent from the dispatch agent field` (`codex/gpt-6-luna`); `orders active workers first then newest`; `builds current work from the coordinator's newest run`; `raises attention for a blocked coordinator and blocked active workers only`; `parses git summary` (3 porcelain lines → `changedFiles: 3`).
- [ ] **Step 2: Run `cd orca-plugin && orca plugin test .`** — expected: the new tests FAIL (missing module).
- [ ] **Step 3: Implement the functions and types above.**
- [ ] **Step 4: Run `cd orca-plugin && orca plugin test .`** — expected: all pass (65 existing + new).
- [ ] **Step 5: Parent commits** `feat: add dashboard derivations for the profile panel`.

### Task 2: Worker gathers dashboard sources

**Files:**
- Modify: `orca-plugin/src/worker.ts`, `orca-plugin/src/worker.test.ts`

**Interfaces:**
- Consumes: Task 1 functions and types.
- Produces: `state(signal, includeProfiles)` returns `State` whose `agents[]` carry `stateStartedAt` and, when `includeProfiles` is true (the panel's `state` request and mutations), `dashboards` for each coordinator row. The status path (`includeProfiles === false`) skips `task-list`, `run-list`, git and file reads.

- [ ] **Step 1: Write failing tests in `worker.test.ts`**: `attaches a dashboard per coordinator` (fake `runExecutable` answers `worker-list` with full rows, `task-list --json --full`, `run-list --json --full`, and `git`; the fake host's `workspace.list` returns the path); `keeps other sections when one source fails` (git throws → `errors.git` set, `workers` present); `hides tasks and git when the workspace path is unknown` (`errors.workspace` set, `feature`/`git` null); `never sends task specs to the panel` (no `spec` string anywhere in the serialized State); `status refresh runs no task-list, run-list or git` (assert the argv log after `tick()`).
- [ ] **Step 2: Run `cd orca-plugin && orca plugin test .`** — expected: new tests FAIL.
- [ ] **Step 3: Implement**: keep today's unscoped dispatch scan for worker detection unchanged; add `run-list --environment local --json --full`, then for the coordinator's newest 10 Runs (`coordinator_handle` equal to its `terminalId`) `task-list --run <id> --json --full` and `worker-list --run <id> --json` (isolated env, `TIMEOUT_MS` each, skip `run_not_found`, strip `spec` on parse); resolve the workspace root per the spec (P5 call); read `<root>/odd/tasks/*.md` and run the three git commands with `TIMEOUT_MS`; build `Dashboard` with Task 1 functions.
- [ ] **Step 4: Run `cd orca-plugin && orca plugin test .`** and `bash tests/run.sh` — expected: all pass.
- [ ] **Step 5: Parent commits** `feat: gather workers, tasks and git state for the profile panel`.

### Task 3: Status bar attention

**Files:**
- Modify: `orca-plugin/src/worker.ts` (`statusFor`), `orca-plugin/src/worker.test.ts`

**Interfaces:**
- Consumes: `attentionItems` (Task 1); agent rows and worker-list rows already read by the status refresh.

- [ ] **Step 1: Write failing tests**: `shows needs you when the coordinator is blocked` (text `odd: ⚠ needs you`, tooltip contains "This session is blocked"); `shows needs you for a blocked active worker` (tooltip names the worker title from `agents.list` `task.title` or terminal title, and its agent); `keeps today's text when nothing needs the user` (existing expectations unchanged); `bounds the attention tooltip` (many workers → tooltip <= 256 units).
- [ ] **Step 2: Run tests** — expected: new tests FAIL.
- [ ] **Step 3: Implement** in `statusFor`; use a warning tone only if `statusBar.update` params accept one.
- [ ] **Step 4: Run `cd orca-plugin && orca plugin test .`** — expected: all pass.
- [ ] **Step 5: Parent commits** `feat: signal attention in the odd-flow status item`.

### Task 4: Layout A panel

**Files:**
- Modify: `orca-plugin/src/panel.tsx`, `orca-plugin/src/panel.test.tsx`, `orca-plugin/README.md`

**Interfaces:**
- Consumes: `State.dashboards`, `Agent.stateStartedAt`, `ProfileList.profiles[].roles`.

- [ ] **Step 1: Write failing tests in `panel.test.tsx`**: `renders the attention callout only when needed`; `shows the session state with its live time` (`waiting` → muted "Waiting for you" + `RelativeTime`, no callout); `shows the role routing under the profile select` (`explore → codex · gpt-6-luna · medium`); `switches mode with a two-option toggle` (same `sessionMode` request as today); `renders feature tasks with progress and folded done tasks` (`8 of 11 done`-style counts line); `renders current work without a feature document` (objective, task rows, "Last result", git line); `shows only the git line when there is no work data`; `renders worker rows in two lines` (line 1 badge + title, line 2 `agent · time`; finished beyond 3 folded); `shows section errors without hiding other sections`; existing tests keep passing (worker rows still show no controls).
- [ ] **Step 2: Run tests** — expected: new tests FAIL.
- [ ] **Step 3: Implement** layout A per the spec's Design items 1-4 with `Callout`, `Card`, `Badge`, `Progress`, `Collapsible`, `RelativeTime`; README panel section updated.
- [ ] **Step 4: Run** `cd orca-plugin && orca plugin test .`, `orca plugin check .`, `bash tests/run.sh` — expected: all pass; `check` renders the panel with no errors.
- [ ] **Step 5: Parent commits** `feat: show a layout A dashboard in the profile panel`.

### Task 5: Verify and live check

- [ ] **Step 1:** one independent `verify` worker on the candidate (Tasks 1-4) against the spec and this plan (Risk: trusted-worker now reads files and runs git).
- [ ] **Step 2:** parent live check after the user re-approves the plugin: `orca plugin shot` of the panel; P4 (a blocked agent reports `blocked` and raises the callout and status text) and P6 (RelativeTime and Progress render); record results in the feature document.

### Task 7: HTML panel (S13, S14)

**Files:**
- Create: `orca-plugin/src/panel/main.ts`, `orca-plugin/src/panel/render.ts`, `orca-plugin/src/panel/styles.ts`, `orca-plugin/src/panel/render.test.ts`, `orca-plugin/src/panel/main.test.ts`
- Modify: `orca-plugin/orca-plugin.json` (panel `ui: "html"`, `entry: "src/panel/main.ts"`), `orca-plugin/README.md`, `orca-plugin/src/worker.ts` only if the panel entry path is referenced there
- Delete: `orca-plugin/src/panel.tsx`, `orca-plugin/src/panel.test.tsx`, `orca-plugin/src/panel.check.ts` after their behaviors are covered

**Interfaces:**
- Consumes: `State`, `Dashboard`, `MutationResult` (`protocol.ts`); worker handlers `state`, `use`, `sessionMode`, `clear` through `window.orca.plugin.request`; host events through `window.orca.on`.
- Produces: `render(state: State | null, ui: { pending: boolean; feedback: { row: string; text: string; failed: boolean } | null; error: string | null; now: number }): string` (escaped HTML), `styles: string`.

- [ ] **Step 1:** port every behavior test of `panel.test.tsx` to `render.test.ts` (pure HTML assertions) and `main.test.ts` (request payloads, disabled-while-saving, feedback, refresh on events); add tests for the S13 look: badge classes per tone, segmented mode with the active side marked, explore/write/verify routes plus "<n> more roles", one source line, attention callout class, escaping of titles.
- [ ] **Step 2:** run `orca plugin test .` — new tests FAIL.
- [ ] **Step 3:** implement; CSS from the approved mockups (`mockup-layout-A.html` option A, `mockup-layout-v2.html`) with Orca theme variables for base colors and fixed status colors per `html.dark` / `html.light`.
- [ ] **Step 4:** `orca plugin test .`, `orca plugin validate .`, typecheck (below), `bash tests/run.sh` — all pass; then `orca plugin shot` dark and light after the parent approves the build.
- [ ] **Step 5:** parent commits `feat: render the profile panel dashboard as html`.

Typecheck: node /Users/max/.npm/_npx/1ac1eddd0355a233/node_modules/typescript/bin/tsc --noEmit -p /Users/max/Personal/repos/odd-flow/orca-plugin 2>&1 | grep "error TS" | grep -vE "TS2591|TS7006|TS2339: Property 'unref'"   (expect no output: those three codes are missing @types/node noise)
