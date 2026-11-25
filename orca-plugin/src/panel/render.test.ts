import { assert, test } from 'orca/testing'
import type { Agent, Dashboard, State, WorkerRow } from '../protocol'
import { render, type RenderUi } from './render'

const started = Date.UTC(2026, 10, 25, 15, 56)
const now = started + 120_000
const git = { branch: 'feat/dashboard', changedFiles: 2, lastCommit: { hash: 'abc1234', at: started } }

function ui(overrides: Partial<RenderUi> = {}): RenderUi {
  return {
    pending: false,
    feedback: null,
    error: null,
    now,
    ...overrides
  }
}

function dashboardFixture(overrides: Partial<Dashboard> = {}, state: Agent['state'] = 'working'): State {
  return {
    script: { path: '/installed/profile.py', source: 'setting' },
    profiles: {
      path: null,
      default: 'team',
      profiles: [
        {
          name: 'team',
          default: true,
          mode: 'organic',
          roles: {
            explore: { agent: 'codex', model: 'gpt-6-luna', effort: 'medium' },
            write: { agent: 'codex', model: 'gpt-6.2-sol', effort: 'medium' },
            verify: { agent: 'claude', model: 'claude-opus-5-5', effort: 'high' },
            review: { agent: 'claude', model: 'claude-opus-5-5', effort: 'high' },
            refute: { agent: 'claude', model: 'claude-opus-5-5', effort: 'high' }
          }
        },
        {
          name: 'solo',
          default: false,
          mode: 'full-delegation',
          roles: {}
        }
      ]
    },
    agents: [
      {
        terminalId: 'coordinator',
        title: 'Coordinator',
        agent: 'codex',
        sessionId: 'session',
        state,
        stateStartedAt: started,
        odd: {
          profile: 'team',
          source: 'file default',
          session_key: 'CODEX_THREAD_ID',
          agent: 'codex',
          mode: 'organic',
          mode_source: 'profile team',
          rules: 'references/mode-organic.md',
          roles: {},
          orca_terminal: null
        }
      }
    ],
    dashboards: {
      coordinator: {
        terminalId: 'coordinator',
        attention: [],
        feature: null,
        current: null,
        git: null,
        workers: [],
        errors: {},
        ...overrides
      }
    }
  }
}

test('renders loading, state request failure messages, and icon-only refresh button', () => {
  const loading = render(null, ui())
  assert.match(loading, /Loading workspace state…/)
  assert.match(loading, /<button[^>]*class="btn-refresh"[^>]*aria-label="Refresh"[^>]*title="Refresh"[^>]*><svg/)
  assert.ok(!/>Refresh<\/button>/.test(loading))

  const failed = render(null, ui({ error: 'worker offline' }))
  assert.match(failed, /Could not load workspace state: worker offline/)
  assert.match(failed, /data-tone="danger"/)
})

test('renders focused agents, collapsed source line, empty state, and per-row/script/profile errors', () => {
  const emptyHtml = render(
    { script: { path: '/p.py', source: 'setting' }, profiles: null, agents: [] },
    ui()
  )
  assert.match(emptyHtml, /No agents in the focused workspace/)

  const state: State = {
    script: { error: 'No installed profile.py was found. Set profileScript in Orca Settings.' },
    profiles: 'profile.py list failed: boom',
    agents: [
      {
        terminalId: 'one',
        title: 'Runner',
        agent: 'codex',
        state: 'working',
        sessionId: 'sid',
        odd: {
          profile: 'team',
          source: 'session (CODEX_THREAD_ID)',
          mode: 'full-delegation',
          mode_source: 'profile team',
          session_key: 'CODEX_THREAD_ID',
          agent: 'codex',
          orca_terminal: null,
          roles: {},
          rules: 'references/mode-full-delegation.md'
        }
      },
      {
        terminalId: 'two',
        title: 'Other runner',
        agent: 'claude',
        state: 'waiting',
        sessionId: null,
        odd: null,
        reason: 'No session ID reported.'
      },
      {
        terminalId: 'three',
        title: 'Broken',
        agent: 'pi',
        state: 'done',
        sessionId: 's3',
        odd: 'profile.py show failed: boom'
      }
    ]
  }
  const html = render(state, ui())
  assert.ok(!/settings\/profile\.py/.test(html))
  assert.match(html, /No installed profile\.py.*profileScript/)
  assert.match(html, /list failed: boom/)
  assert.match(html, /show failed: boom/)
  assert.match(html, /No session ID reported\./)
  assert.match(html, /Session choice/)
  assert.match(html, /badge-accent[^>]*>working</)
  assert.match(html, /badge-neutral[^>]*>codex</)
})

test('shows the upgrade instructions without disabling Mode or Reset to defaults', () => {
  const path = '/installed/profile.py'
  const upgrade = `odd-flow 0.3.0 or newer is required (found ${path}). Update the odd-flow plugin, or set profileScript to a newer profile.py.`
  const html = render(
    {
      script: { path, source: 'Claude cache' },
      profiles: upgrade,
      agents: [{ terminalId: 'a', title: 'Alpha', agent: 'claude', state: 'working', sessionId: 's', odd: upgrade }]
    },
    ui()
  )
  assert.match(html, new RegExp(upgrade.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  assert.match(html, /<select[^>]*disabled/)
  assert.ok(!/data-action="sessionMode"[^>]*disabled/.test(html))
  assert.ok(!/data-action="clear"[^>]*disabled/.test(html))
})

test('renders worker fallback rows without controls and hides them when dashboards succeed', () => {
  const workerOnly = render(
    {
      script: { path: '/settings/profile.py', source: 'profileScript setting' },
      profiles: null,
      agents: [
        {
          terminalId: 'one',
          title: 'Generic terminal title',
          agent: 'claude',
          state: 'working',
          sessionId: 'sid',
          task: { title: 'T5 verify: panel session switching' },
          isWorker: true,
          odd: null,
          reason: 'Dispatched worker.'
        }
      ]
    },
    ui()
  )
  assert.match(workerOnly, /T5 verify: panel session switching — claude — working/)
  assert.ok(!/<select/.test(workerOnly))
  assert.ok(!/Reset to defaults/.test(workerOnly))

  const workerCheckError = 'Could not check dispatched workers: Orca executable not found.'
  const withError = render(
    {
      script: { path: '/settings/profile.py', source: 'profileScript setting' },
      profiles: null,
      workerCheckError,
      agents: [
        {
          terminalId: 'one',
          title: 'First',
          agent: 'claude',
          state: 'working',
          sessionId: 's1',
          odd: null,
          reason: 'Worker check unavailable.'
        }
      ]
    },
    ui()
  )
  assert.match(withError, /Could not check dispatched workers: Orca executable not found\./)
  assert.match(withError, /First — claude — working/)
  assert.ok(!/<select/.test(withError))
})

test('renders the attention callout only when needed', () => {
  const clean = render(dashboardFixture(), ui())
  assert.ok(!/class="callout"/.test(clean))

  const alerted = render(
    dashboardFixture(
      {
        attention: [
          { label: 'This session is blocked', since: started },
          { label: 'Review task — claude/opus', since: started + 60_000 }
        ]
      },
      'blocked'
    ),
    ui()
  )
  assert.match(alerted, /class="callout"/)
  assert.match(alerted, /Needs you/)
  assert.match(alerted, /This session is blocked · <span[^>]*>2m<\/span>/)
  assert.match(alerted, /Review task — claude\/opus · <span[^>]*>1m<\/span>/)
})

test('shows the session state badges (waiting/done -> waiting for you, blocked -> needs you), trimmed role routes, segmented mode with tooltips, source line, and feedback', () => {
  const waitingHtml = render(dashboardFixture({}, 'waiting'), ui({ feedback: { row: 'coordinator:codex:session', text: 'Profile switched.', failed: false } }))
  assert.match(waitingHtml, /<div class="row-inline"><span class="bd badge-neutral">codex<\/span><span class="bd badge-neutral">waiting for you<\/span><span class="mu"[^>]*>2m<\/span><\/div>/)
  assert.match(waitingHtml, /badge-neutral[^>]*>waiting for you</)
  assert.match(waitingHtml, /2m/)
  assert.match(waitingHtml, /explore → codex · gpt-6-luna · medium/)
  assert.match(waitingHtml, /write → codex · gpt-6\.2-sol · medium/)
  assert.match(waitingHtml, /verify → claude · claude-opus-5-5 · high/)
  assert.match(waitingHtml, /2 more roles/)
  assert.match(waitingHtml, /Default profile/)
  assert.match(waitingHtml, /class="seg-btn active"[^>]*data-mode="organic"/)
  assert.ok(!/class="seg-btn active"[^>]*data-mode="full-delegation"/.test(waitingHtml))
  assert.match(waitingHtml, /<select[^>]*title="Applies to the next worker launch"/)
  assert.match(waitingHtml, /class="seg"[^>]*title="Reaches the agent on its next prompt"/)
  assert.match(waitingHtml, /data-action="clear"[^>]*title="Removes this session&#39;s profile and mode choice"/)
  assert.match(waitingHtml, /Reset to defaults/)
  assert.ok(!/The default profile and its mode apply again/.test(waitingHtml))
  assert.ok(!/drops the session mode override/.test(waitingHtml))
  assert.ok(!/A mode switch reaches the agent on its next prompt/.test(waitingHtml))
  assert.match(waitingHtml, /Profile switched\./)

  const doneHtml = render(dashboardFixture({}, 'done'), ui())
  assert.match(doneHtml, /badge-neutral[^>]*>waiting for you</)
  assert.ok(!/badge-success[^>]*>done</.test(doneHtml))

  const blockedHtml = render(dashboardFixture({}, 'blocked'), ui())
  assert.match(blockedHtml, /badge-warning[^>]*>needs you</)
})

test('disables all controls while pending', () => {
  const html = render(dashboardFixture(), ui({ pending: true }))
  assert.match(html, /class="btn-refresh"[^>]*disabled/)
  assert.match(html, /<select[^>]*disabled/)
  assert.match(html, /data-mode="organic"[^>]*disabled/)
  assert.match(html, /data-mode="full-delegation"[^>]*disabled/)
  assert.match(html, /data-action="clear"[^>]*disabled/)
})

test('renders feature tasks with progress bar and folded done tasks', () => {
  const html = render(
    dashboardFixture({
      git,
      feature: {
        title: 'Build a dashboard',
        path: 'odd/tasks/dashboard.md',
        branch: 'feat/dashboard',
        tasks: [
          { id: 'T1', status: 'done', work: 'Land the data layer' },
          { id: 'T2', status: 'in_progress', work: 'Build the panel' },
          { id: 'T3', status: 'blocked', work: 'Verify with approval' },
          { id: 'T4', status: 'pending', work: 'Update the guide' }
        ]
      }
    }),
    ui()
  )
  assert.match(html, /Feature tasks/)
  assert.match(html, /Build a dashboard/)
  assert.match(html, /odd\/tasks\/dashboard\.md · feat\/dashboard/)
  assert.match(html, /style="width:25%"/)
  assert.match(html, /1 of 4 done · 1 working · 1 blocked · 1 pending/)
  assert.match(html, /badge-danger[^>]*>blocked</)
  assert.match(html, /badge-accent[^>]*>working</)
  assert.match(html, /1 done/)
  assert.match(html, /Land the data layer/)
})

test('renders current work without a feature document and git-only fallback', () => {
  const currentHtml = render(
    dashboardFixture({
      git,
      current: {
        objective: 'Review the panel',
        startedAt: started,
        tasks: [
          { title: 'Collect evidence', status: 'completed', startedAt: started, endedAt: started + 120_000 },
          { title: 'Inspect the panel', status: 'dispatched', startedAt: started + 60_000, endedAt: null }
        ],
        lastResult: { title: 'Collect evidence', subject: 'Evidence collected' }
      }
    }),
    ui()
  )
  assert.match(currentHtml, /Current work/)
  assert.match(currentHtml, /Review the panel/)
  assert.match(currentHtml, /No feature document/)
  assert.match(currentHtml, /badge-success[^>]*>done</)
  assert.match(currentHtml, /badge-accent[^>]*>working</)
  assert.match(currentHtml, /took 2m/)
  assert.match(currentHtml, /1m/)
  assert.match(currentHtml, /Last result/)
  assert.match(currentHtml, /Evidence collected/)
  assert.match(currentHtml, /feat\/dashboard · 2 changed files · abc1234 · <span[^>]*>2m<\/span> ago/)

  const gitOnly = render(dashboardFixture({ git }), ui())
  assert.match(gitOnly, /feat\/dashboard · 2 changed files · abc1234/)
  assert.ok(!/Feature tasks/.test(gitOnly))
  assert.ok(!/Current work/.test(gitOnly))
  assert.ok(!/Workers/.test(gitOnly))
})

test('renders two-line worker rows, badge tones, and folded finished workers', () => {
  const active: WorkerRow = {
    dispatchId: 'active',
    title: 'Long title for the active worker',
    agent: 'codex/gpt-6-luna',
    state: 'ready',
    active: true,
    needsYou: true,
    startedAt: started + 60_000,
    endedAt: null
  }
  const finished: WorkerRow[] = Array.from({ length: 4 }, (_, index) => ({
    ...active,
    dispatchId: String(index),
    title: `Finished ${index + 1}`,
    agent: null,
    state: 'succeeded',
    active: false,
    needsYou: false,
    startedAt: started,
    endedAt: started + 120_000
  }))
  const html = render(dashboardFixture({ workers: [active, ...finished] }), ui())
  assert.match(html, /Workers/)
  assert.match(html, /1 active/)
  assert.match(html, /badge-warning[^>]*>needs you</)
  assert.match(html, /codex\/gpt-6-luna · <span[^>]*>1m<\/span>/)
  assert.match(html, /took 2m/)
  assert.match(html, /1 finished earlier/)
})

test('shows section errors without hiding other sections', () => {
  const html = render(
    dashboardFixture({
      git,
      errors: {
        feature: 'Could not read feature documents.',
        workers: 'Could not load all Orca work.'
      }
    }),
    ui()
  )
  assert.match(html, /data-tone="danger">Could not read feature documents\.</)
  assert.match(html, /data-tone="danger">Could not load all Orca work\.</)
  assert.match(html, /feat\/dashboard · 2 changed files · abc1234/)
})

test('escapes untrusted strings from State before inserting into HTML', () => {
  const xss = '<img src=x onerror="alert(1)">'
  const html = render(
    dashboardFixture({
      attention: [{ label: xss, since: started }],
      feature: {
        title: xss,
        path: 'odd/tasks/x.md',
        branch: xss,
        tasks: [{ id: 'T1', status: 'pending', work: xss }]
      },
      workers: [
        {
          dispatchId: 'd1',
          title: xss,
          agent: xss,
          state: 'running',
          active: true,
          needsYou: false,
          startedAt: started,
          endedAt: null
        }
      ]
    }),
    ui({ error: null })
  )
  assert.ok(!/<img src=x/.test(html))
  assert.match(html, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/)
})

test('A3: renders a selected disabled option when session profile is missing from profiles list', () => {
  const state = dashboardFixture()
  const odd = state.agents[0].odd
  assert.ok(odd && typeof odd === 'object')
  odd.profile = 'missing<profile>'
  const html = render(state, ui())
  assert.match(
    html,
    /<option value="missing&lt;profile&gt;" selected disabled>missing&lt;profile&gt; \(not found\)<\/option>/
  )
  assert.ok(!/<option value=""[^>]*selected/.test(html))
  assert.ok(!/<option value="team"[^>]*selected/.test(html))
})
