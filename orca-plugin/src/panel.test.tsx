import { assert, mockHost, mount, test, type MockHostOptions, type TestPanel } from 'orca/testing'
import * as panel from './panel'
import type { Agent, Dashboard, State, WorkerRow } from './protocol'

test('shows the focused agents, profile sources, errors, and refreshes on demand and host events', async () => {
  let requests = 0
  const host = mockHost({
    capabilities: ['agent:read', 'workspace:read'],
    requests: {
      state: () => {
        requests++
        return {
          script: { path: '/settings/profile.py', source: 'profileScript setting' },
          profiles: {
            path: '/profiles.json', default: 'team',
            profiles: [{ name: 'team', mode: 'full-delegation', default: true, roles: {} }]
          },
          agents: [{
            terminalId: 'one', title: 'Runner', agent: 'codex', state: 'working', sessionId: 'sid',
            odd: {
              profile: 'team', source: 'session (CODEX_THREAD_ID)', mode: 'full-delegation',
              mode_source: 'profile team', session_key: 'CODEX_THREAD_ID', agent: 'codex',
              orca_terminal: null, roles: {}, rules: 'references/mode-full-delegation.md'
            }
          }, {
            terminalId: 'two', title: 'Other runner', agent: 'claude', state: 'waiting', sessionId: null,
            odd: null, reason: 'No session ID reported.'
          }]
        }
      }
    }
  })
  const view = await mount(panel, { host })
  try {
    assert.equal(view.find({ text: /settings\/profile\.py/ }), null)
    assert.equal(view.find({ text: 'Profiles' }), null)
    assert.equal(view.find({ text: /team \(default\)/ }), null)
    assert.ok(view.findAll({ type: 'Card' }).some(({ props }) => props.title === 'Runner'))
    assert.ok(view.find({ type: 'Badge', text: 'codex' }))
    assert.ok(view.find({ type: 'Badge', text: 'working' }))
    for (const text of [/team.*session \(CODEX_THREAD_ID\)/, /full-delegation.*profile team/, /No session ID/]) {
      assert.ok(view.find({ text }), String(text))
    }
    const before = requests
    await view.press({ text: 'Refresh' })
    assert.equal(requests, before + 1)
    await view.emit('agent.status.changed', {
      workspaceId: null, terminalId: 'one', paneKey: 'one', state: 'waiting', receivedAt: 0
    })
    assert.equal(requests, before + 2)
    await view.emit('workspace.changed', { context: null })
    assert.equal(requests, before + 3)
    assert.deepEqual(view.errors, [])
    assert.deepEqual(view.refusals, [])
  } finally {
    await view.unmount()
  }
})

test('shows state request failures and preserves per-row, script and profile error messages', async () => {
  let failure = 1
  const host = mockHost({ requests: { state: () => {
    if (failure === 1) throw new Error('worker offline')
    if (failure === 2) return {
      script: { error: 'agent list offline' }, profiles: null, agents: [], error: 'agent list offline'
    }
    return {
      script: { error: 'No installed profile.py was found. Set profileScript in Orca Settings.' },
      profiles: 'profile.py list failed: boom',
      agents: [{
        terminalId: 'a', title: 'Alpha', agent: 'claude', state: 'working', sessionId: 's',
        odd: 'profile.py show failed: boom'
      }, {
        terminalId: 'b', title: 'Beta', agent: 'pi', state: 'done', sessionId: 's2',
        odd: null, reason: 'Unsupported agent kind.'
      }]
    }
  } } })
  const view = await mount(panel, { host })
  try {
    assert.ok(view.find({ text: /Could not load workspace state: worker offline/ }))
    failure = 0
    await view.press({ text: 'Refresh' })
    for (const text of [/No installed profile\.py.*profileScript/, /list failed: boom/,
      /show failed: boom/, /Unsupported agent kind/]) {
      assert.ok(view.find({ text }), String(text))
    }
    assert.deepEqual(view.findAll({ type: 'Card' }).map(({ props }) => props.title), ['Alpha', 'Beta'])
    for (const text of ['claude', 'working', 'pi', 'done']) {
      assert.ok(view.find({ type: 'Badge', text }), text)
    }
    assert.ok(!view.find({ text: /worker offline/ }))
    failure = 2
    await view.press({ text: 'Refresh' })
    assert.ok(view.find({ text: /Could not load workspace state: agent list offline/ }))
    assert.deepEqual(view.errors, [])
  } finally {
    await view.unmount()
  }
})

test('shows the upgrade instructions without disabling Mode or Reset to defaults', async () => {
  const path = '/installed/profile.py'
  const upgrade = `odd-flow 0.3.0 or newer is required (found ${path}). Update the odd-flow plugin, or set profileScript to a newer profile.py.`
  const host = mockHost({ requests: { state: () => ({
    script: { path, source: 'Claude cache' },
    profiles: upgrade,
    agents: [{
      terminalId: 'a', title: 'Alpha', agent: 'claude', state: 'working', sessionId: 's', odd: upgrade
    }]
  }) } })
  const view = await mount(panel, { host })
  try {
    assert.ok(view.find({ text: upgrade }))
    assert.equal(view.find({ label: 'Profile' })?.props.disabled, true)
    for (const text of ['organic', 'full-delegation']) {
      assert.equal(view.find({ type: 'Button', text })?.props.disabled, false)
    }
    assert.equal(view.find({ text: 'Reset to defaults' })?.props.disabled, false)
  } finally {
    await view.unmount()
  }
})

test('renders a worker as only its task title, agent and state', async () => {
  const host = mockHost({ requests: { state: () => ({
    script: { path: '/settings/profile.py', source: 'profileScript setting' },
    profiles: null,
    agents: [{
      terminalId: 'one', title: 'Generic terminal title', agent: 'claude', state: 'working',
      sessionId: 'sid', task: { title: 'T5 verify: panel session switching' }, isWorker: true,
      odd: null, reason: 'Dispatched worker.'
    }]
  }) } })
  const view = await mount(panel, { host })
  try {
    const line = 'T5 verify: panel session switching — claude — working'
    const texts = view.findAll({ type: 'Text' })
    assert.equal(texts.length, 1) // The worker title.
    assert.equal(texts.at(-1)?.text, line)
    assert.equal(view.find({ label: 'Profile' }), null)
    for (const text of ['organic', 'full-delegation']) {
      assert.equal(view.find({ type: 'Button', text }), null)
    }
    assert.equal(view.find({ text: 'Reset to defaults' }), null)
  } finally {
    await view.unmount()
  }
})

test('renders a dispatch-only worker using its terminal title and no details or controls', async () => {
  const host = mockHost({ requests: { state: () => ({
    script: { path: '/settings/profile.py', source: 'profileScript setting' },
    profiles: null,
    agents: [{
      terminalId: 'one', title: 'T5 verify: panel session switching', agent: 'claude', state: 'working',
      sessionId: 'sid', task: null, isWorker: true, odd: null, reason: 'Dispatched worker.'
    }]
  }) } })
  const view = await mount(panel, { host })
  try {
    const texts = view.findAll({ type: 'Text' })
    assert.equal(texts.length, 1)
    assert.equal(texts.at(-1)?.text, 'T5 verify: panel session switching — claude — working')
    assert.equal(view.findAll({ type: 'Select' }).length, 0)
    assert.equal(view.find({ text: 'Reset to defaults' }), null)
  } finally {
    await view.unmount()
  }
})

test('shows a dispatch check failure once and keeps every row visible without controls', async () => {
  const workerCheckError = 'Could not check dispatched workers: Orca executable not found.'
  let unavailable = true
  const host = mockHost({ requests: {
    clear: () => ({ error: workerCheckError, workerCheckUnavailable: true }),
    state: () => ({
      script: { path: '/settings/profile.py', source: 'profileScript setting' },
      profiles: null,
      ...(unavailable ? { workerCheckError } : {}),
      agents: [{
        terminalId: 'one', title: 'First', agent: 'claude', state: 'working',
        sessionId: 's1', odd: null, reason: 'Worker check unavailable.'
      }, {
        terminalId: 'two', title: 'Second', agent: 'codex', state: 'waiting',
        sessionId: 's2', odd: null, reason: 'Worker check unavailable.'
      }]
    })
  } })
  const view = await mount(panel, { host })
  try {
    function assertNoControls() {
      assert.equal(view.findAll({ text: workerCheckError }).length, 1)
      assert.ok(view.find({ text: 'First — claude — working' }))
      assert.ok(view.find({ text: 'Second — codex — waiting' }))
      assert.equal(view.findAll({ type: 'Select' }).length, 0)
      assert.equal(view.find({ text: 'Reset to defaults' }), null)
    }
    assertNoControls()
    unavailable = false
    await view.press({ text: 'Refresh' })
    assert.equal(view.findAll({ text: workerCheckError }).length, 0)
    await view.press(view.findAll({ text: 'Reset to defaults' })[0])
    assertNoControls()
  } finally {
    await view.unmount()
  }
})

test('switches the selected row, displays saved or failed results, and prevents overlapping controls', async () => {
  const base = {
    script: { path: '/settings/profile.py', source: 'profileScript setting' },
    profiles: {
      path: '/profiles.json', default: 'team',
      profiles: [
        { name: 'team', mode: 'full-delegation', default: true, roles: {} },
        { name: 'solo', mode: 'organic', default: false, roles: {} }
      ]
    },
    agents: [{
      terminalId: 'one', title: 'Runner', agent: 'codex', state: 'working', sessionId: 'sid',
      odd: {
        profile: 'team', source: 'file default', mode: 'full-delegation', mode_source: 'profile team',
        session_key: 'CODEX_THREAD_ID', agent: 'codex', orca_terminal: null, roles: {},
        rules: 'references/mode-full-delegation.md'
      }
    }]
  } satisfies import('./protocol').State
  const changed = {
    ...base, agents: [{ ...base.agents[0], odd: {
      ...base.agents[0].odd, profile: 'solo', source: 'session (CODEX_THREAD_ID)'
    } }]
  }
  const calls: unknown[] = []
  let finish!: () => void
  const wait = new Promise<void>((resolve) => { finish = resolve })
  const host = mockHost({ requests: {
    state: () => base,
    use: async (input) => { calls.push(input); await wait; return { state: changed } },
    sessionMode: (input) => { calls.push(input); return { error: 'could not set mode' } },
    clear: (input) => { calls.push(input); return { state: base } }
  } })
  let afterRender: (() => void) | undefined
  const view = await mount({
    ...panel,
    default: () => {
      const tree = panel.default()
      afterRender?.()
      afterRender = undefined
      return tree
    }
  }, { host })
  const profile = { label: 'Profile' }
  const organic = { type: 'Button', text: 'organic' } as const
  const full = { type: 'Button', text: 'full-delegation' } as const
  const clear = { text: 'Reset to defaults' }
  try {
    assert.equal(view.valueOf(profile), 'team')
    assert.equal(view.find(full)?.props.variant, 'solid')
    assert.equal(view.find(organic)?.props.variant, 'outline')
    for (const text of [/next worker launch/i, /next prompt/i, /drops.*mode override/i]) {
      assert.ok(view.find({ text }), String(text))
    }
    assert.ok(view.find({
      text: "Removes this session's profile and mode choice. The default profile and its mode apply again."
    }))
    const rendered = new Promise<void>((resolve) => { afterRender = resolve })
    const select = view.select(profile, 'solo')
    try {
      // Observe the render without awaiting the selection, which waits for the request to settle.
      await Promise.race([rendered, select])
      for (const target of [profile, organic, full, clear]) {
        assert.equal(view.find(target)?.props.disabled, true)
      }
    } finally {
      finish()
      await select
    }
    assert.equal(view.valueOf(profile), 'solo')
    assert.ok(view.find({ text: /Profile switched/ }))
    await view.press(organic)
    assert.ok(view.find({ text: /could not set mode/ }))
    assert.equal(view.find(full)?.props.variant, 'solid')
    assert.equal(view.find(organic)?.props.variant, 'outline')
    await view.press(clear)
    assert.equal(view.valueOf(profile), 'team')
    assert.ok(view.find({ text: 'Session choices reset.' }))
    assert.deepEqual(calls, [
      { agent: 'codex', sessionId: 'sid', profile: 'solo' },
      { agent: 'codex', sessionId: 'sid', mode: 'organic' },
      { agent: 'codex', sessionId: 'sid' }
    ])
    assert.deepEqual(view.errors, [])
  } finally {
    await view.unmount()
  }
})

const started = Date.UTC(2026, 10, 25, 15, 56)
const git = { branch: 'feat/dashboard', changedFiles: 2, lastCommit: { hash: 'abc1234', at: started } }

function dashboardFixture(overrides: Partial<Dashboard> = {}, state: Agent['state'] = 'working'): State {
  return {
    script: { path: '/installed/profile.py', source: 'setting' },
    profiles: { path: null, default: 'team', profiles: [
      { name: 'team', default: true, mode: 'organic', roles: {
        explore: { agent: 'codex', model: 'gpt-6-luna', effort: 'medium' }
      } }
    ] },
    agents: [{
      terminalId: 'coordinator', title: 'Coordinator', agent: 'codex', sessionId: 'session', state,
      stateStartedAt: started,
      odd: {
        profile: 'team', source: 'file default', session_key: 'CODEX_THREAD_ID', agent: 'codex',
        mode: 'organic', mode_source: 'profile team', rules: 'references/mode-organic.md', roles: {},
        orca_terminal: null
      }
    }],
    dashboards: { coordinator: {
      terminalId: 'coordinator', attention: [], feature: null, current: null, git: null,
      workers: [], errors: {}, ...overrides
    } }
  }
}

async function withDashboard(
  answer: State, check: (view: TestPanel) => void | Promise<void>,
  requests: Pick<NonNullable<MockHostOptions['requests']>, 'sessionMode'> = {}
) {
  const view = await mount(panel, { host: mockHost({ requests: { state: () => answer, ...requests } }) })
  try {
    await check(view)
    assert.deepEqual(view.errors, [])
    assert.deepEqual(view.warnings, [])
  } finally {
    await view.unmount()
  }
}

test('renders the attention callout only when needed', async () => {
  await withDashboard(dashboardFixture(), (view) => assert.equal(view.find({ type: 'Callout' }), null))
  await withDashboard(dashboardFixture({ attention: [
    { label: 'This session is blocked', since: started },
    { label: 'Review task — claude/opus', since: started + 1000 }
  ] }, 'blocked'), (view) => {
    const callout = view.find({ type: 'Callout' })
    assert.equal(callout?.props.title, 'Needs you')
    assert.equal(callout?.props.tone, 'warning')
    assert.ok(view.find({ text: /This session is blocked/ }))
    assert.ok(view.find({ text: /Review task — claude\/opus/ }))
    assert.ok(view.findAll({ type: 'RelativeTime' }).some(({ props }) => props.at === started + 1000))
  })
})

test('shows the session state with its live time', async () => {
  await withDashboard(dashboardFixture({}, 'waiting'), (view) => {
    assert.equal(view.find({ type: 'Card' })?.props.title, 'Coordinator')
    assert.ok(view.find({ type: 'Badge', text: 'codex' }))
    assert.equal(view.find({ type: 'Text', text: /Waiting for you/ })?.props.muted, true)
    assert.equal(view.find({ type: 'RelativeTime' })?.props.at, started)
    assert.equal(view.find({ type: 'Callout' }), null)
  })
})

test('shows the role routing under the profile select', async () => {
  await withDashboard(dashboardFixture(), (view) => {
    assert.equal(view.valueOf({ label: 'Profile' }), 'team')
    assert.equal(view.find({ type: 'Text', text: 'explore → codex · gpt-6-luna · medium' })?.props.muted, true)
  })
})

test('switches mode with a two-option toggle', async () => {
  const base = dashboardFixture()
  const changed = dashboardFixture()
  const odd = changed.agents[0].odd
  assert.ok(odd && typeof odd === 'object')
  odd.mode = 'full-delegation'
  const calls: unknown[] = []
  await withDashboard(base, async (view) => {
    const organic = { type: 'Button', text: 'organic' } as const
    const full = { type: 'Button', text: 'full-delegation' } as const
    assert.equal(view.find(organic)?.props.variant, 'solid')
    assert.equal(view.find(full)?.props.variant, 'outline')
    await view.press(full)
    assert.deepEqual(calls, [{ agent: 'codex', sessionId: 'session', mode: 'full-delegation' }])
    assert.equal(view.find(organic)?.props.variant, 'outline')
    assert.equal(view.find(full)?.props.variant, 'solid')
    assert.ok(view.find({ text: 'Mode switched.' }))
  }, { sessionMode: (input) => { calls.push(input); return { state: changed } } })
})

test('renders feature tasks with progress and folded done tasks', async () => {
  await withDashboard(dashboardFixture({ git, feature: {
    title: 'Build a dashboard', path: 'odd/tasks/dashboard.md', branch: 'feat/dashboard',
    tasks: [
      { id: 'T1', status: 'done', work: 'Land the data layer' },
      { id: 'T2', status: 'in_progress', work: 'Build the panel' },
      { id: 'T3', status: 'blocked', work: 'Verify with approval' },
      { id: 'T4', status: 'pending', work: 'Update the guide' }
    ]
  } }), async (view) => {
    assert.ok(view.find({ text: 'Feature tasks' }))
    assert.ok(view.find({ text: 'Build a dashboard' }))
    assert.equal(view.find({ text: 'odd/tasks/dashboard.md · feat/dashboard' })?.props.muted, true)
    assert.equal(view.find({ type: 'Progress' })?.props.value, 25)
    assert.ok(view.find({ text: '1 of 4 done · 1 working · 1 blocked · 1 pending' }))
    assert.equal(view.find({ type: 'Badge', text: 'blocked' })?.props.tone, 'danger')
    assert.equal(view.find({ type: 'Text', text: /Build the panel/ })?.props.truncate, true)
    const folded = view.find({ type: 'Collapsible' })
    assert.equal(folded?.props.title, '1 done')
    assert.equal(view.find({ type: 'Text', text: /Land the data layer/ }), null)
    await view.toggle(folded!)
    assert.ok(view.find({ type: 'Text', text: /Land the data layer/ }))
  })
})

test('renders current work without a feature document', async () => {
  await withDashboard(dashboardFixture({ git, current: {
    objective: 'Review the panel', startedAt: started,
    tasks: [
      { title: 'Collect evidence', status: 'completed', startedAt: started, endedAt: started + 120000 },
      { title: 'Inspect the panel', status: 'in_progress', startedAt: started + 120000, endedAt: null }
    ],
    lastResult: { title: 'Collect evidence', subject: 'Evidence collected' }
  } }), (view) => {
    for (const text of ['Current work', 'Review the panel', 'No feature document', 'Collect evidence',
      'Inspect the panel', 'Last result', /Evidence collected/, /feat\/dashboard · 2 changed files · abc1234/,
      'took 2m']) assert.ok(view.find({ text }), String(text))
    assert.equal(view.find({ type: 'Badge', text: 'completed' })?.props.tone, 'success')
    assert.ok(view.findAll({ type: 'RelativeTime' }).some(({ props }) =>
      props.at === started + 120000 && props.format === 'duration'))
  })
})

test('shows only the git line when there is no work data', async () => {
  await withDashboard(dashboardFixture({ git }), (view) => {
    assert.ok(view.find({ text: /feat\/dashboard · 2 changed files · abc1234/ }))
    for (const text of ['Feature tasks', 'Current work', 'Workers']) assert.equal(view.find({ text }), null)
  })
})

test('renders worker rows in two lines', async () => {
  const active = { dispatchId: 'active', title: 'Long title for the active worker', agent: 'codex/gpt-6-luna',
    state: 'working', active: true, needsYou: true, startedAt: started + 1000, endedAt: null }
  const finished: WorkerRow[] = Array.from({ length: 4 }, (_, index) => ({
    ...active, dispatchId: String(index), title: `Finished ${index + 1}`, agent: null,
    state: 'succeeded', active: false, needsYou: false, startedAt: started, endedAt: started + 120000
  }))
  await withDashboard(dashboardFixture({ workers: [active, ...finished] }), async (view) => {
    assert.ok(view.find({ text: 'Workers' }))
    assert.ok(view.find({ text: '1 active' }))
    assert.equal(view.find({ type: 'Badge', text: 'needs you' })?.props.tone, 'warning')
    assert.equal(view.find({ type: 'Text', text: active.title })?.props.truncate, true)
    assert.equal(view.find({ type: 'Text', text: /codex\/gpt-6-luna ·/ })?.props.muted, true)
    assert.ok(view.findAll({ type: 'RelativeTime' }).some(({ props }) =>
      props.at === started + 1000 && props.format === 'duration'))
    assert.ok(view.find({ text: 'took 2m' }))
    assert.ok(view.find({ text: 'Finished 3' }))
    const folded = view.find({ type: 'Collapsible' })
    assert.equal(folded?.props.title, '1 finished earlier')
    assert.equal(view.find({ text: 'Finished 4' }), null)
    await view.toggle(folded!)
    assert.ok(view.find({ text: 'Finished 4' }))
  })
})

test('shows section errors without hiding other sections', async () => {
  await withDashboard(dashboardFixture({ git, errors: {
    feature: 'Could not read feature documents.',
    workers: 'Could not load all Orca work.'
  } }), (view) => {
    for (const text of ['Could not read feature documents.', 'Could not load all Orca work.']) {
      assert.equal(view.find({ type: 'Text', text })?.props.tone, 'danger')
    }
    assert.ok(view.find({ text: /feat\/dashboard · 2 changed files · abc1234/ }))
  })
})
