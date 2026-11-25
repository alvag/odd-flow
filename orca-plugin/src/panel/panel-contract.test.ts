import { assert, test } from 'orca/testing'
import type { MutationResult, State } from '../protocol'
import { render, type RenderUi } from './render'
import { mountPanel, type FrameHost } from './main'

const P = 'X<b>"\'&Y'
const E = 'X&lt;b&gt;&quot;&#39;&amp;Y'
const now = Date.UTC(2026, 10, 25, 16, 0)
const t0 = now - 125_000

function ui(o: Partial<RenderUi> = {}): RenderUi { return { pending: false, feedback: null, error: null, now, ...o } }

function odd(extra: Record<string, unknown> = {}) {
  return { profile: 'p' + P, source: 'file default', mode: 'organic', mode_source: 'profile x', session_key: 'K', agent: 'claude', orca_terminal: null, roles: {}, rules: 'r', ...extra } as never
}

function evil(): State {
  return {
    script: { path: '/s/profile.py', source: 'setting' },
    profiles: { path: null, default: 'p' + P, profiles: [
      { name: 'p' + P, default: true, mode: 'organic', roles: {
        explore: { agent: 'a' + P, model: 'm' + P, effort: 'e' + P },
        ['r' + P]: { agent: 'codex', model: 'x', effort: 'y' } } as never }
    ] },
    workerCheckError: 'wce' + P,
    agents: [
      { terminalId: 't' + P, title: 'title' + P, agent: 'claude', sessionId: 's' + P, state: 'blocked', stateStartedAt: t0, odd: odd() } as never,
      { terminalId: 'u2', title: 'reason' , agent: 'claude', sessionId: 's2', state: 'working', odd: null, reason: 'why' + P } as never,
      { terminalId: 'u3', title: 'oddstr', agent: 'claude', sessionId: 's3', state: 'working', odd: 'odderr' + P } as never
    ],
    dashboards: {
      ['t' + P]: {
        terminalId: 't' + P,
        attention: [{ label: 'att' + P, since: t0 }],
        feature: { title: 'ft' + P, path: 'odd/tasks/' + P + '.md', branch: 'br' + P, tasks: [
          { id: 'T1' + P, specs: '', work: 'w' + P, route: '', status: 'pending', evidence: '' },
          { id: 'T2', specs: '', work: 'done' + P, route: '', status: 'done', evidence: '' }
        ] },
        current: null,
        git: null,
        workers: [{ dispatchId: 'd', taskId: 'k', title: 'wt' + P, agent: 'ag' + P, state: 'dispatched', active: true, needsYou: false, startedAt: t0, endedAt: null } as never],
        errors: { workers: 'we' + P, feature: 'fe' + P, git: 'ge' + P }
      } as never
    }
  } as State
}

test('contract: escapes every State string', () => {
  // workerCheckError hides dashboards per row; render both with and without it, across all sessions
  const a = render(evil(), ui({ feedback: { row: 't' + P + ':claude:s' + P, text: 'fb' + P, failed: true } }))
  const s = evil(); delete (s as { workerCheckError?: string }).workerCheckError
  const b1 = render(s, ui({ selectedSession: 't' + P, feedback: { row: 't' + P + ':claude:s' + P, text: 'fb' + P, failed: true } }))
  const b2 = render(s, ui({ selectedSession: 'u2' }))
  const b3 = render(s, ui({ selectedSession: 'u3' }))
  const c = render(null, ui({ error: 'err' + P }))
  const d = render({ ...s, script: { error: 'se' + P } as never, profiles: 'pe' + P as never }, ui())
  for (const out of [a, b1, b2, b3, c, d]) {
    assert.ok(!out.includes('<b>'), 'raw tag leaked')
    assert.ok(!out.includes('"\'&Y'), 'raw quote leaked')
  }
  for (const want of ['wce', 'title']) assert.ok(a.includes(want + E), 'a missing ' + want)
  for (const want of ['title', 'att', 'ft', 'odd/tasks/', 'br', 'T1', 'w', 'done', 'wt', 'ag', 'we', 'fe', 'ge', 'p', 'a', 'm', 'e', 'r', 'fb']) assert.ok(b1.includes(want + E), 'b1 missing ' + want)
  assert.ok(b2.includes('why' + E), 'b2 missing why')
  assert.ok(b3.includes('odderr' + E), 'b3 missing odderr')
  assert.ok(b1.includes('data-row="t' + E + ':claude:s' + E + '"'), 'data-row attr')
  assert.ok(b1.includes('<option value="p' + E + '" selected>'), 'option attr')
  assert.ok(c.includes('err' + E))
  assert.ok(d.includes('se' + E) && d.includes('pe' + E))
})

class TimeEl {
  textContent: string
  constructor(private readonly since: string, text: string) { this.textContent = text }
  getAttribute(name: string) { return name === 'data-time-since' ? this.since : null }
}

class El {
  private html = ''
  writes = 0
  timeNodes: TimeEl[] = []
  ls = new Map<string, ((e: unknown) => void)[]>()
  get innerHTML() { return this.html }
  set innerHTML(v: string) {
    this.html = v
    this.writes++
    this.timeNodes = [...v.matchAll(/data-time-since="([^"]+)"[^>]*>([^<]*)</g)].map(([, since, text]) => new TimeEl(since, text))
  }
  querySelectorAll(sel: string) { return sel === '[data-time-since]' ? this.timeNodes : [] }
  addEventListener(t: string, l: (e: unknown) => void) { this.ls.set(t, [...(this.ls.get(t) ?? []), l]) }
  removeEventListener(t: string, l: (e: unknown) => void) { this.ls.set(t, (this.ls.get(t) ?? []).filter((x) => x !== l)) }
  fire(t: string, target: unknown) { for (const l of this.ls.get(t) ?? []) l({ target }) }
}

function base(): State {
  return {
    script: { path: '/s/profile.py', source: 'setting' },
    profiles: { path: null, default: 'team', profiles: [
      { name: 'team', default: true, mode: 'full-delegation', roles: {} },
      { name: 'solo', default: false, mode: 'organic', roles: {} }] },
    agents: [{ terminalId: 'one', title: 'Coord', agent: 'claude', sessionId: 'sid', state: 'working', stateStartedAt: Date.now() - 60_000,
      odd: odd({ profile: 'team' }) } as never]
  } as State
}

function host(h: Record<string, (i: unknown) => unknown>) {
  const calls: [string, unknown][] = []
  const subs = new Map<string, Set<(p: unknown) => unknown>>()
  const fh: FrameHost = {
    on: ((e: string, fn: (p: unknown) => unknown) => { const s = subs.get(e) ?? new Set(); s.add(fn); subs.set(e, s); return { dispose: () => s.delete(fn) } }) as FrameHost['on'],
    plugin: { request: (async (n: string, i?: unknown) => { calls.push([n, i]); return h[n](i) }) as FrameHost['plugin']['request'] } as FrameHost['plugin']
  }
  return { fh, calls, subs, emit: async (e: string, p: unknown) => { for (const f of subs.get(e) ?? []) await f(p) } }
}
const tgt = (ds: Record<string, string>, extra: Record<string, unknown> = {}) => ({ ...extra, closest: (sel: string) => sel.startsWith('[data-action') ? { dataset: ds, ...extra } : null })

test('contract: mutations payloads, disabled while saving, feedback', async () => {
  let release!: (r: MutationResult) => void
  const h = host({ state: () => base(), use: () => new Promise((r) => { release = r }), sessionMode: () => new Promise((r) => { release = r }), clear: () => new Promise((r) => { release = r }) })
  const root = new El()
  const p = mountPanel(root as never, h.fh, { intervalMs: 0 })
  await p.settled()
  const row = 'one:claude:sid'
  const checkDisabled = () => {
    const html = root.innerHTML
    assert.match(html, /<select[^>]*data-action="use"[^>]*disabled/)
    assert.equal((html.match(/class="seg-btn[^"]*"[^>]*disabled/g) ?? []).length, 2)
    assert.match(html, /class="btn-reset"[^>]*disabled/)
    assert.match(html, /class="btn-refresh"[^>]*disabled/)
  }
  root.fire('change', { closest: (s: string) => s === '[data-action="use"]' ? { dataset: { row }, value: 'solo' } : null })
  checkDisabled()
  release({ state: base() } as MutationResult); await p.settled()
  assert.match(root.innerHTML, /Profile switched\./)
  root.fire('click', tgt({ action: 'sessionMode', row, mode: 'organic' }))
  checkDisabled()
  release({ state: base() } as MutationResult); await p.settled()
  assert.match(root.innerHTML, /Mode switched\./)
  assert.ok(!/Profile switched/.test(root.innerHTML))
  root.fire('click', tgt({ action: 'clear', row }))
  release({ error: 'nope <x>' } as MutationResult); await p.settled()
  assert.match(root.innerHTML, /class="error-text" data-tone="danger">nope &lt;x&gt;</)
  root.fire('click', tgt({ action: 'clear', row }))
  release({ state: base() } as MutationResult); await p.settled()
  assert.match(root.innerHTML, /Session choices reset\./)
  root.fire('click', tgt({ action: 'sessionMode', row, mode: 'bogus' }))
  root.fire('click', tgt({ action: 'clear', row: 'nope:claude:x' }))
  assert.deepEqual(h.calls.filter(([n]) => n !== 'state'), [
    ['use', { agent: 'claude', sessionId: 'sid', profile: 'solo' }],
    ['sessionMode', { agent: 'claude', sessionId: 'sid', mode: 'organic' }],
    ['clear', { agent: 'claude', sessionId: 'sid' }],
    ['clear', { agent: 'claude', sessionId: 'sid' }]])
  p.dispose()
})

test('contract: host events and theme', async () => {
  const h = host({ state: () => base() })
  const root = new El()
  const p = mountPanel(root as never, h.fh, { intervalMs: 0 })
  await p.settled()
  const n = () => h.calls.filter(([x]) => x === 'state').length
  assert.equal(n(), 1)
  await h.emit('agent.status.changed', {}); await p.settled(); assert.equal(n(), 2)
  await h.emit('workspace.changed', {}); await p.settled(); assert.equal(n(), 3)
  const w = root.writes
  await h.emit('theme', { colorScheme: 'light' }); assert.equal(n(), 3); assert.ok(root.writes > w, 'theme redraws')
  assert.deepEqual([...h.subs.keys()].sort(), ['agent.status.changed', 'theme', 'workspace.changed'])
  p.dispose()
  assert.equal([...h.subs.values()].reduce((a, s) => a + s.size, 0), 0)
  assert.equal(root.ls.get('click')?.length ?? 0, 0)
})

test('contract: live time refresh, hidden, dispose, default 15 s', async () => {
  const g = globalThis as unknown as Record<string, unknown>
  const realSet = g.setInterval as typeof setInterval, realClear = g.clearInterval as typeof clearInterval
  const seen: number[] = [], cleared: unknown[] = []
  g.setInterval = ((fn: () => void, ms: number) => { seen.push(ms); return realSet(fn, ms) }) as never
  g.clearInterval = ((id: unknown) => { cleared.push(id); return realClear(id as never) }) as never
  try {
    const h = host({ state: () => base() })
    const r0 = new El(); const p0 = mountPanel(r0 as never, h.fh); await p0.settled(); p0.dispose()
    assert.deepEqual(seen, [15_000]); assert.equal(cleared.length, 1)
  } finally { g.setInterval = realSet; g.clearInterval = realClear }
  const h = host({ state: () => base() })
  const root = new El()
  const realNow = Date.now
  const p = mountPanel(root as never, h.fh, { intervalMs: 20 })
  await p.settled()
  assert.equal(root.timeNodes[0]?.textContent, '1m')
  const writesAfterMount = root.writes
  Date.now = () => realNow() + 10 * 60_000
  await new Promise((r) => setTimeout(r, 70))
  assert.equal(root.timeNodes[0]?.textContent, '11m', 'time text refreshed')
  assert.equal(root.writes, writesAfterMount, 'tick does not rewrite innerHTML')
  g.document = { visibilityState: 'hidden' }
  Date.now = () => realNow() + 20 * 60_000
  await new Promise((r) => setTimeout(r, 70))
  assert.equal(root.timeNodes[0]?.textContent, '11m', 'no time update while hidden')
  g.document = { visibilityState: 'visible' }
  await new Promise((r) => setTimeout(r, 70))
  assert.equal(root.timeNodes[0]?.textContent, '21m', 'time updates when visible again')
  delete g.document
  p.dispose()
  Date.now = () => realNow() + 30 * 60_000
  await new Promise((r) => setTimeout(r, 70))
  assert.equal(root.timeNodes[0]?.textContent, '21m', 'no update after dispose')
  Date.now = realNow
})

function st(state: string): State {
  const s = base(); (s.agents[0] as { state: string }).state = state; (s.agents[0] as { stateStartedAt: number }).stateStartedAt = t0; return s
}
test('contract: session header badges, tooltips, refresh icon', () => {
  for (const s of ['done', 'waiting']) {
    const out = render(st(s), ui())
    assert.match(out, /<div class="row-inline"><span class="bd badge-neutral">claude<\/span><span class="bd badge-neutral">waiting for you<\/span><span class="mu"[^>]*>2m<\/span><\/div>/)
    assert.ok(!/badge-success/.test(out)); assert.ok(!/class="callout"/.test(out))
  }
  const b = render(st('blocked'), ui())
  assert.match(b, /class="callout" role="alert"/); assert.match(b, /badge-warning">needs you</)
  assert.match(render(st('working'), ui()), /badge-accent">working</)
  const o = render(st('working'), ui())
  assert.match(o, /<button[^>]*data-action="clear"[^>]*title="[^"]+"/)
  assert.match(o, /<select[^>]*data-action="use"[^>]*title="[^"]+"/)
  assert.match(o, /role="group" aria-label="Mode" title="[^"]+"/)
  assert.ok(!/The default profile and its mode apply again|drops the session mode override|A mode switch reaches/.test(o))
  assert.match(o, /<button type="button" class="btn-refresh" data-action="refresh" aria-label="Refresh" title="Refresh"><svg/)
  assert.ok(!/>Refresh</.test(o.replace(/aria-label="Refresh" title="Refresh"/, '')))
})

test('contract: section errors stay in their section; workspace error keeps workers', () => {
  const s = evil(); delete (s as { workerCheckError?: string }).workerCheckError
  const out = render(s, ui({ selectedSession: 't' + P }))
  const wi = out.indexOf('<h4><span>Workers'), fi = out.indexOf('<h4>Feature tasks')
  assert.ok(out.indexOf('we' + E) > wi && wi > 0)
  assert.ok(out.indexOf('fe' + E) < wi && out.indexOf('ge' + E) < wi && out.indexOf('ge' + E) > fi)
  const d = (s.dashboards as Record<string, { errors: Record<string, string> }>)['t' + P]
  d.errors = { workspace: 'Workspace path unavailable' }
  const o2 = render(s, ui({ selectedSession: 't' + P }))
  assert.match(o2, /<div class="mu">Workspace path unavailable<\/div>/); assert.match(o2, /Workers/)
})
