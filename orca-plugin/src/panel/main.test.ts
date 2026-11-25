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

class FakeElement {
  innerHTML = ''
  listeners = new Map<string, Listener[]>()
  attrs = new Map<string, string>()

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

  querySelectorAll(): FakeElement[] {
    return []
  }

  dispatch(type: string, target: Record<string, unknown>): void {
    for (const listener of this.listeners.get(type) ?? []) {
      listener({ target })
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
