import { assert, test } from 'orca/testing'
import type { MutationResult, State } from '../protocol'
import { mountPanel, type FrameHost } from './main'

function baseState(): State {
  return {
    script: { path: '/settings/profile.py', source: 'profileScript setting' },
    profiles: {
      path: '/profiles.json',
      default: 'team',
      profiles: [
        { name: 'team', mode: 'full-delegation', default: true, roles: {} },
        { name: 'solo', mode: 'organic', default: false, roles: {} }
      ]
    },
    agents: [
      {
        terminalId: 'one',
        title: 'Runner',
        agent: 'codex',
        state: 'working',
        stateStartedAt: 1_000,
        sessionId: 'sid',
        odd: {
          profile: 'team',
          source: 'file default',
          mode: 'full-delegation',
          mode_source: 'profile team',
          session_key: 'CODEX_THREAD_ID',
          agent: 'codex',
          orca_terminal: null,
          roles: {},
          rules: 'references/mode-full-delegation.md'
        }
      }
    ]
  }
}

type Listener = (payload: unknown) => void

class FakeTimeNode {
  textContent: string
  constructor(
    private readonly since: string,
    initial: string
  ) {
    this.textContent = initial
  }
  getAttribute(name: string): string | null {
    return name === 'data-time-since' ? this.since : null
  }
}

class FakeDetailsNode {
  open: boolean
  constructor(
    private readonly fold: string,
    open: boolean
  ) {
    this.open = open
  }
  getAttribute(name: string): string | null {
    return name === 'data-fold' ? this.fold : null
  }
}

class FakeElement {
  private html = ''
  writes = 0
  listeners = new Map<string, Listener[]>()
  attrs = new Map<string, string>()
  timeNodes: FakeTimeNode[] = []
  detailsNodes: FakeDetailsNode[] = []
  contained = new Set<unknown>()

  get innerHTML(): string {
    return this.html
  }

  set innerHTML(value: string) {
    this.html = value
    this.writes++
    this.timeNodes = [...value.matchAll(/data-time-since="([^"]+)"[^>]*>([^<]*)</g)].map(
      ([, since, text]) => new FakeTimeNode(since, text)
    )
    this.detailsNodes = [...value.matchAll(/<details data-fold="([^"]+)"([^>]*)>/g)].map(
      ([, fold, attrs]) => new FakeDetailsNode(fold, /\bopen\b/.test(attrs))
    )
  }

  contains(node: unknown): boolean {
    return this.contained.has(node)
  }

  addEventListener(type: string, listener: Listener): void {
    const list = this.listeners.get(type) ?? []
    list.push(listener)
    this.listeners.set(type, list)
  }

  removeEventListener(type: string, listener: Listener): void {
    const list = this.listeners.get(type)
    if (!list) return
    this.listeners.set(
      type,
      list.filter((item) => item !== listener)
    )
  }

  querySelectorAll(selector?: string): unknown[] {
    if (selector === '[data-time-since]') return this.timeNodes
    if (selector === 'details[data-fold]') return this.detailsNodes
    return []
  }

  dispatch(type: string, target: Record<string, unknown>, extra: Record<string, unknown> = {}): void {
    for (const listener of this.listeners.get(type) ?? []) {
      listener({ target, ...extra })
    }
  }
}

function makeHost(handlers: {
  state: () => State | Promise<State>
  use?: (input: unknown) => MutationResult | Promise<MutationResult>
  sessionMode?: (input: unknown) => MutationResult | Promise<MutationResult>
  clear?: (input: unknown) => MutationResult | Promise<MutationResult>
}) {
  const listeners = new Map<string, Set<(payload: unknown) => unknown>>()
  const host: FrameHost = {
    on: ((event: string, handler: (payload: unknown) => unknown) => {
      const set = listeners.get(event) ?? new Set()
      set.add(handler)
      listeners.set(event, set)
      return { dispose: () => set.delete(handler) }
    }) as FrameHost['on'],
    plugin: {
      request: (async (name: string, input?: unknown) => {
        if (name === 'state') return handlers.state()
        if (name === 'use') return handlers.use!(input)
        if (name === 'sessionMode') return handlers.sessionMode!(input)
        if (name === 'clear') return handlers.clear!(input)
        throw new Error(`Unexpected request: ${name}`)
      }) as FrameHost['plugin']['request']
    } as FrameHost['plugin']
  }
  return {
    host,
    async emit(event: string, payload: unknown) {
      for (const handler of listeners.get(event) ?? []) {
        await handler(payload)
      }
    }
  }
}

function fakeTarget(dataset: Record<string, string>, extra: Record<string, unknown> = {}) {
  return {
    dataset,
    closest(selector: string) {
      if (selector.startsWith('[data-action') && dataset.action) return { dataset, ...extra }
      return null
    },
    ...extra
  }
}

test('loads state on mount, refreshes on host events and button click, and cleans up on dispose', async () => {
  let states = 0
  const root = new FakeElement()
  const { host, emit } = makeHost({
    state: () => {
      states++
      return baseState()
    }
  })
  const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 0 })
  await handle.settled()
  assert.equal(states, 1)
  assert.match(root.innerHTML, /Runner/)

  await emit('agent.status.changed', { terminalId: 'one', state: 'waiting' })
  await handle.settled()
  assert.equal(states, 2)

  await emit('workspace.changed', { context: null })
  await handle.settled()
  assert.equal(states, 3)

  root.dispatch('click', fakeTarget({ action: 'refresh' }))
  await handle.settled()
  assert.equal(states, 4)

  handle.dispose()
  await emit('workspace.changed', { context: null })
  assert.equal(states, 4)
})

test('sends use, sessionMode, and clear requests, disables controls while saving, and shows feedback', async () => {
  const base = baseState()
  const baseOdd = base.agents[0].odd
  assert.ok(baseOdd && typeof baseOdd === 'object')
  const changed: State = {
    ...base,
    agents: [
      {
        ...base.agents[0],
        odd: { ...baseOdd, profile: 'solo', source: 'session (CODEX_THREAD_ID)' }
      }
    ]
  }
  const calls: unknown[] = []
  let finish!: () => void
  const wait = new Promise<void>((resolve) => {
    finish = resolve
  })
  const root = new FakeElement()
  const { host } = makeHost({
    state: () => base,
    use: async (input) => {
      calls.push(input)
      await wait
      return { state: changed }
    },
    sessionMode: (input) => {
      calls.push(input)
      return { error: 'could not set mode' }
    },
    clear: (input) => {
      calls.push(input)
      return { state: base }
    }
  })

  const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 0 })
  await handle.settled()

  root.dispatch('change', fakeTarget({ action: 'use', row: 'one:codex:sid' }, { value: 'solo' }))
  assert.match(root.innerHTML, /<select[^>]*disabled/)
  finish()
  await handle.settled()
  assert.match(root.innerHTML, /Profile switched\./)

  root.dispatch('click', fakeTarget({ action: 'sessionMode', row: 'one:codex:sid', mode: 'organic' }))
  await handle.settled()
  assert.match(root.innerHTML, /could not set mode/)

  root.dispatch('click', fakeTarget({ action: 'clear', row: 'one:codex:sid' }))
  await handle.settled()
  assert.match(root.innerHTML, /Session choices reset\./)

  assert.deepEqual(calls, [
    { agent: 'codex', sessionId: 'sid', profile: 'solo' },
    { agent: 'codex', sessionId: 'sid', mode: 'organic' },
    { agent: 'codex', sessionId: 'sid' }
  ])
  handle.dispose()
})

test('A1: 15s tick updates only time text nodes without replacing root.innerHTML', async () => {
  const realNow = Date.now
  const baseNow = Date.UTC(2026, 10, 25, 16, 0)
  Date.now = () => baseNow
  try {
    const state = baseState()
    state.agents[0].stateStartedAt = baseNow - 60_000
    const root = new FakeElement()
    const { host } = makeHost({ state: () => state })
    const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 20 })
    await handle.settled()

    const writesAfterMount = root.writes
    assert.equal(root.timeNodes.length, 1)
    assert.equal(root.timeNodes[0].textContent, '1m')

    Date.now = () => baseNow + 10 * 60_000
    await new Promise((resolve) => setTimeout(resolve, 60))

    assert.equal(root.writes, writesAfterMount, '15s tick must not replace innerHTML')
    assert.equal(root.timeNodes[0].textContent, '11m', 'time node textContent must update')
    handle.dispose()
  } finally {
    Date.now = realNow
  }
})

test('A1: defers full redraw while a panel control has focus and applies on blur; preserves details open state', async () => {
  const g = globalThis as unknown as Record<string, unknown>
  const prevDoc = g.document
  let title = 'Initial'
  const state = () => {
    const s = baseState()
    s.agents[0].title = title
    const profiles = typeof s.profiles === 'object' && s.profiles !== null ? s.profiles.profiles : []
    profiles[0].roles = {
      explore: { agent: 'codex', model: 'm1', effort: 'low' },
      write: { agent: 'codex', model: 'm2', effort: 'medium' },
      verify: { agent: 'claude', model: 'm3', effort: 'high' },
      review: { agent: 'claude', model: 'm4', effort: 'high' }
    }
    return s
  }

  const root = new FakeElement()
  const selectEl = { tagName: 'SELECT' }
  root.contained.add(selectEl)
  const docListeners = new Map<string, Listener[]>()
  const fakeDoc = {
    visibilityState: 'visible',
    activeElement: null as unknown,
    addEventListener(type: string, listener: Listener) {
      docListeners.set(type, [...(docListeners.get(type) ?? []), listener])
    },
    removeEventListener(type: string, listener: Listener) {
      docListeners.set(
        type,
        (docListeners.get(type) ?? []).filter((item) => item !== listener)
      )
    }
  }
  g.document = fakeDoc

  try {
    const { host, emit } = makeHost({ state })
    const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 0 })
    await handle.settled()
    assert.match(root.innerHTML, /Initial/)
    assert.equal(root.detailsNodes.length, 1)

    // Open <details> and focus <select>
    root.detailsNodes[0].open = true
    fakeDoc.activeElement = selectEl

    title = 'Updated'
    const writesBeforeRefresh = root.writes
    await emit('agent.status.changed', {})
    await handle.settled()

    assert.equal(root.writes, writesBeforeRefresh, 'redraw must be deferred while control has focus')
    assert.ok(!/Updated/.test(root.innerHTML))

    // Blur the control -> deferred redraw applies and preserves <details open>
    fakeDoc.activeElement = null
    root.dispatch('focusout', selectEl)

    assert.ok(root.writes > writesBeforeRefresh, 'deferred redraw must apply on blur')
    assert.match(root.innerHTML, /Updated/)
    assert.match(root.innerHTML, /<details data-fold="roles:one:codex:sid" open>/)

    handle.dispose()
  } finally {
    if (prevDoc === undefined) delete g.document
    else g.document = prevDoc
  }
})

test('A6: visibilitychange to visible updates times immediately', async () => {
  const g = globalThis as unknown as Record<string, unknown>
  const prevDoc = g.document
  const realNow = Date.now
  const baseNow = Date.UTC(2026, 10, 25, 16, 0)
  Date.now = () => baseNow

  const docListeners = new Map<string, Listener[]>()
  const fakeDoc = {
    visibilityState: 'hidden',
    activeElement: null,
    addEventListener(type: string, listener: Listener) {
      docListeners.set(type, [...(docListeners.get(type) ?? []), listener])
    },
    removeEventListener(type: string, listener: Listener) {
      docListeners.set(
        type,
        (docListeners.get(type) ?? []).filter((item) => item !== listener)
      )
    }
  }
  g.document = fakeDoc

  try {
    const state = baseState()
    state.agents[0].stateStartedAt = baseNow - 60_000
    const root = new FakeElement()
    const { host } = makeHost({ state: () => state })
    const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 0 })
    await handle.settled()

    assert.equal(root.timeNodes[0].textContent, '1m')
    const writesBefore = root.writes

    Date.now = () => baseNow + 10 * 60_000
    fakeDoc.visibilityState = 'visible'
    for (const listener of docListeners.get('visibilitychange') ?? []) {
      listener({})
    }

    assert.equal(root.writes, writesBefore, 'visibilitychange must not replace innerHTML')
    assert.equal(root.timeNodes[0].textContent, '11m', 'times must update immediately on becoming visible')

    handle.dispose()
    assert.equal(docListeners.get('visibilitychange')?.length ?? 0, 0, 'visibilitychange listener cleaned up')
  } finally {
    Date.now = realNow
    if (prevDoc === undefined) delete g.document
    else g.document = prevDoc
  }
})

function twoSessionState(overrides: {
  oneState?: 'working' | 'waiting' | 'blocked' | 'done'
  oneAt?: number
  twoState?: 'working' | 'waiting' | 'blocked' | 'done'
  twoAt?: number
  dropOne?: boolean
  dropTwo?: boolean
} = {}): State {
  const one = {
    terminalId: 'one',
    title: 'Session One',
    agent: 'codex',
    state: overrides.oneState ?? 'working',
    stateStartedAt: overrides.oneAt ?? 2_000,
    sessionId: 'sid1',
    odd: {
      profile: 'team',
      source: 'file default',
      mode: 'full-delegation' as const,
      mode_source: 'profile team',
      session_key: 'CODEX_THREAD_ID',
      agent: 'codex',
      orca_terminal: null,
      roles: {},
      rules: 'references/mode-full-delegation.md'
    }
  }
  const two = {
    terminalId: 'two',
    title: 'Session Two',
    agent: 'claude',
    state: overrides.twoState ?? 'waiting',
    stateStartedAt: overrides.twoAt ?? 1_000,
    sessionId: 'sid2',
    odd: {
      profile: 'solo',
      source: 'file default',
      mode: 'organic' as const,
      mode_source: 'profile solo',
      session_key: 'CLAUDE_CODE_SESSION_ID',
      agent: 'claude',
      orca_terminal: null,
      roles: {},
      rules: 'references/mode-organic.md'
    }
  }
  const agents = [
    ...(overrides.dropOne ? [] : [one]),
    ...(overrides.dropTwo ? [] : [two])
  ]
  return {
    script: { path: '/settings/profile.py', source: 'profileScript setting' },
    profiles: {
      path: '/profiles.json',
      default: 'team',
      profiles: [
        { name: 'team', mode: 'full-delegation', default: true, roles: {} },
        { name: 'solo', mode: 'organic', default: false, roles: {} }
      ]
    },
    agents
  }
}

test('S15: follows agent.status.changed working events, supports pin/unpin, and falls back when shown session disappears', async () => {
  let state = twoSessionState()
  const root = new FakeElement()
  const { host, emit } = makeHost({ state: () => state })
  const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 0 })
  await handle.settled()

  assert.match(root.innerHTML, /class="session-title">Session One<\/strong>/)
  assert.ok(!/class="session-title">Session Two<\/strong>/.test(root.innerHTML))

  // Switching another session to working follows it
  state = twoSessionState({ oneState: 'waiting', twoState: 'working', twoAt: 3_000 })
  await emit('agent.status.changed', { terminalId: 'two', state: 'working', receivedAt: 3_000 })
  await handle.settled()
  assert.match(root.innerHTML, /class="session-title">Session Two<\/strong>/)

  // Non-working status change on another session does not steal follow
  state = twoSessionState({ oneState: 'waiting', twoState: 'waiting', twoAt: 3_000 })
  await emit('agent.status.changed', { terminalId: 'one', state: 'waiting', receivedAt: 4_000 })
  await handle.settled()
  assert.match(root.innerHTML, /class="session-title">Session Two<\/strong>/)

  // Pin Session One
  root.dispatch('change', {
    value: 'one',
    dataset: { action: 'selectSession' },
    closest: (sel: string) => (sel === '[data-action="selectSession"]' ? { value: 'one', dataset: { action: 'selectSession' } } : null)
  })
  assert.match(root.innerHTML, /class="session-title">Session One<\/strong>/)
  assert.match(root.innerHTML, /<option value="one" selected>/)

  // Working event on Session Two does not override a pin
  state = twoSessionState({ oneState: 'waiting', twoState: 'working', twoAt: 5_000 })
  await emit('agent.status.changed', { terminalId: 'two', state: 'working', receivedAt: 5_000 })
  await handle.settled()
  assert.match(root.innerHTML, /class="session-title">Session One<\/strong>/)

  // Unpin back to Follow active session
  root.dispatch('change', {
    value: '',
    dataset: { action: 'selectSession' },
    closest: (sel: string) => (sel === '[data-action="selectSession"]' ? { value: '', dataset: { action: 'selectSession' } } : null)
  })
  assert.match(root.innerHTML, /<option value="" selected>Follow active session<\/option>/)
  assert.match(root.innerHTML, /class="session-title">Session Two<\/strong>/)

  // Pin Session Two, then Session Two disappears -> falls back to Session One and unpins
  root.dispatch('change', {
    value: 'two',
    dataset: { action: 'selectSession' },
    closest: (sel: string) => (sel === '[data-action="selectSession"]' ? { value: 'two', dataset: { action: 'selectSession' } } : null)
  })
  state = twoSessionState({ dropTwo: true })
  await emit('workspace.changed', { context: null })
  await handle.settled()
  assert.match(root.innerHTML, /class="session-title">Session One<\/strong>/)
  assert.ok(!/data-action="selectSession"/.test(root.innerHTML))

  handle.dispose()
})

test('does not disable session controls during a background refresh when no mutation is pending', async () => {
  let releaseRefresh!: (s: State) => void
  let initial = true
  const root = new FakeElement()
  const { host, emit } = makeHost({
    state: () => {
      if (initial) {
        initial = false
        return twoSessionState()
      }
      return new Promise((resolve) => {
        releaseRefresh = resolve
      })
    }
  })
  const handle = mountPanel(root as unknown as HTMLElement, host, { intervalMs: 0 })
  await handle.settled()

  const refreshPromise = emit('agent.status.changed', { terminalId: 'one', state: 'working', receivedAt: 5_000 })
  assert.ok(!/<select[^>]*data-action="use"[^>]*disabled/.test(root.innerHTML), 'profile select must not be disabled during background refresh')
  assert.ok(!/data-action="sessionMode"[^>]*disabled/.test(root.innerHTML), 'mode buttons must not be disabled during background refresh')
  assert.ok(!/data-action="clear"[^>]*disabled/.test(root.innerHTML), 'reset button must not be disabled during background refresh')

  releaseRefresh(twoSessionState())
  await refreshPromise
  await handle.settled()
  handle.dispose()
})
