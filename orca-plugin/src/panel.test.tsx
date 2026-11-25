import { assert, mockHost, mount, test } from 'orca/testing'
import * as panel from './panel'

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
    for (const text of [/profile\.py.*profileScript setting/, /Runner.*codex.*working/,
      /team.*session \(CODEX_THREAD_ID\)/, /full-delegation.*profile team/, /team.*default/, /No session ID/]) {
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
      profiles: 'profile.py list failed: unrecognized arguments: --json',
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
    for (const text of [/No installed profile\.py.*profileScript/, /unrecognized arguments: --json/,
      /Alpha.*claude.*working/, /show failed: boom/, /Beta.*pi.*done/, /Unsupported agent kind/]) {
      assert.ok(view.find({ text }), String(text))
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
    assert.equal(texts.length, 3) // Script, profiles availability, and the worker title.
    assert.equal(texts.at(-1)?.text, line)
    assert.equal(view.find({ label: 'Profile' }), null)
    assert.equal(view.find({ label: 'Mode' }), null)
    assert.equal(view.find({ text: 'Clear session binding' }), null)
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
    assert.equal(texts.length, 3)
    assert.equal(texts.at(-1)?.text, 'T5 verify: panel session switching — claude — working')
    assert.equal(view.findAll({ type: 'Select' }).length, 0)
    assert.equal(view.find({ text: 'Clear session binding' }), null)
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
      assert.equal(view.find({ text: 'Clear session binding' }), null)
    }
    assertNoControls()
    unavailable = false
    await view.press({ text: 'Refresh' })
    assert.equal(view.findAll({ text: workerCheckError }).length, 0)
    await view.press(view.findAll({ text: 'Clear session binding' })[0])
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
  const view = await mount(panel, { host })
  const profile = { label: 'Profile' }
  const mode = { label: 'Mode' }
  const clear = { text: 'Clear session binding' }
  try {
    assert.equal(view.valueOf(profile), 'team')
    assert.equal(view.valueOf(mode), 'full-delegation')
    for (const text of [/next worker launch/i, /next prompt/i, /drops.*mode override/i]) {
      assert.ok(view.find({ text }), String(text))
    }
    const select = view.select(profile, 'solo')
    await new Promise((resolve) => setTimeout(resolve, 0))
    for (const target of [profile, mode, clear]) {
      assert.equal(view.find(target)?.props.disabled, true)
    }
    finish()
    await select
    assert.equal(view.valueOf(profile), 'solo')
    assert.ok(view.find({ text: /Profile switched/ }))
    await view.select(mode, 'organic')
    assert.ok(view.find({ text: /could not set mode/ }))
    assert.equal(view.valueOf(mode), 'full-delegation')
    await view.press(clear)
    assert.equal(view.valueOf(profile), 'team')
    assert.ok(view.find({ text: /Session binding cleared/ }))
    assert.deepEqual(calls, [
      { agent: 'codex', sessionId: 'sid', profile: 'solo' },
      { agent: 'codex', sessionId: 'sid', mode: 'organic' },
      { agent: 'codex', sessionId: 'sid' }
    ])
    assert.deepEqual(view.errors, [])
  } finally {
    finish()
    await view.unmount()
  }
})
