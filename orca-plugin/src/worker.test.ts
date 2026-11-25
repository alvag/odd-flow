import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import type { HostMethods } from 'orca/host'
import { assert, hostError, mockHost, mountWorker, type MockHostOptions } from 'orca/testing'
import * as main from './worker'
import type { Agent } from './protocol'

const keys = {
  CLAUDE_CODE_SESSION_ID: 'parent-claude',
  CODEX_THREAD_ID: 'parent-codex',
  CODEX_SESSION_ID: 'parent-codex-legacy',
  ANTIGRAVITY_CONVERSATION_ID: 'parent-antigravity',
  ORCA_PANE_KEY: 'parent-orca',
  ODD_PROFILE: 'parent-profile',
  ODD_ORCHESTRATOR_MODE: 'organic',
  ODD_FLOW_AGENT: 'parent-agent',
  ORCA_TERMINAL_HANDLE: 'parent-terminal'
}
const env = { ...keys, ODD_FLOW_HOME: '/keep' }
const list = {
  path: null, default: null, profiles: [{ name: 'test', default: false, mode: 'organic', roles: {} }]
}
const currentScript = fileURLToPath(new URL('../../skills/odd-flow/scripts/profile.py', import.meta.url))
const oldScript = fileURLToPath(new URL('./fixtures/old-profile.py', import.meta.url))
const show = {
  profile: 'test', source: 'file default', session_key: null, agent: null,
  mode: 'organic', mode_source: 'default', rules: 'references/mode-organic.md',
  roles: {}, orca_terminal: null
}
const fakeRun: import('./worker').Runner = async (argv) => ({
  stdout: JSON.stringify(argv[2] === 'list' ? list : show),
  stderr: ''
})

function agent(kind: string, sessionId: string | null = kind): Agent & { stateStartedAt: number } {
  return { terminalId: kind, title: kind, agent: kind, sessionId, state: 'waiting', stateStartedAt: 0 }
}

const task = { title: 'T5 verify: panel session switching' }
const dispatched = { ...agent('claude', 'worker-sid'), task }
const terminalOnly = { ...dispatched, task: null }
const workerListArgv = ['orchestration', 'worker-list', '--environment', 'local', '--json']
const fakeOrca = '/fake/orca'
const statusHostResults = {
  // Drive status events explicitly instead of delivering the automatic initial snapshot.
  'workspace.readContext': () => { throw hostError('unavailable', 'No initial snapshot in this fixture.') },
  'statusBar.update': { ok: true as const }
}

function dispatches(terminals: (string | null)[] = [], nextCursor?: string) {
  return dispatchResult(terminals.map((terminal, index) => ({ dispatchId: `dispatch-${terminal}-${index}`, terminal })),
    nextCursor)
}

function dispatchResult(workers: { dispatchId: string; terminal?: string | null }[], nextCursor?: string) {
  return {
    stdout: JSON.stringify({ ok: true, result: {
      workers: workers.map((row) => ({ ...row, state: 'succeeded', liveness: 'exited' })),
      nextCursor
    } }),
    stderr: ''
  }
}

async function fixture(
  settings: MockHostOptions['settings'],
  agents: ReturnType<typeof agent>[],
  options: Partial<import('./worker').WorkerOptions> = {},
  results: MockHostOptions['results'] = { 'agents.list': { agents } }
) {
  const host = mockHost({
    capabilities: ['agent:read', 'workspace:read', 'settings:own'],
    settings,
    results: { ...statusHostResults, ...results }
  })
  const defaults = {
    env, run: fakeRun, resolveOrca: async () => fakeOrca, runExecutable: async () => dispatches(),
    scheduleRefresh: () => () => {}
  }
  let stop: (() => void) | undefined
  const activate = main.createWorker({ ...defaults, ...options })
  return mountWorker({
    default: (api) => { stop = activate(api) },
    deactivate: () => stop?.()
  }, { host })
}

async function temp(t: { after: (cleanup: () => Promise<void>) => void }): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'odd-flow-orca-test-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  return dir
}

async function scriptAt(path: string): Promise<string> {
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, '')
  return path
}

test('uses the focused workspace and maps Claude, Codex and Antigravity to one clean session variable each', async () => {
  const script = currentScript
  const agents = [agent('claude'), agent('codex'), agent('antigravity')]
  const calls: { argv: readonly string[]; env: Record<string, string | undefined> }[] = []
  const worker = await fixture({ profileScript: script }, agents, {
    run: async (argv, childEnv) => { calls.push({ argv, env: childEnv }); return fakeRun(argv, childEnv) }
  })
  const state = await worker.request('state')
  assert.deepEqual(state.profiles, list)
  assert.deepEqual(state.agents.map(({ odd, ...identity }) => ({ odd, ...identity })), agents.map(
    ({ stateStartedAt, ...identity }) => ({ ...identity, odd: show })
  ))
  assert.deepEqual(worker.host.callsOf('agents.list'), [undefined])
  assert.deepEqual(calls, [
    { argv: ['-I', script, 'list', '--json'], env: { ODD_FLOW_HOME: '/keep' } },
    { argv: ['-I', script, 'show', '--json'], env: { ODD_FLOW_HOME: '/keep', CLAUDE_CODE_SESSION_ID: 'claude' } },
    { argv: ['-I', script, 'show', '--json'], env: { ODD_FLOW_HOME: '/keep', CODEX_THREAD_ID: 'codex' } },
    { argv: ['-I', script, 'show', '--json'], env: { ODD_FLOW_HOME: '/keep', ANTIGRAVITY_CONVERSATION_ID: 'antigravity' } }
  ])
  assert.deepEqual(worker.refusals, [])
  await worker.deactivate()
})

test('skips Show for unsupported agents and agents with no session id, with a reason', async () => {
  const script = currentScript
  const commands: string[] = []
  const worker = await fixture({ profileScript: script }, [agent('pi'), agent('codex', null)], {
    run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) }
  })
  const { agents } = await worker.request('state')
  assert.deepEqual(commands, ['list'])
  assert.deepEqual(agents.map((row) => row.odd), [null, null])
  assert.match(agents[0].reason ?? '', /unsupported/i)
  assert.match(agents[1].reason ?? '', /session id/i)
  await worker.deactivate()
})

test('reports the worker task without running a process for its row', async () => {
  const commands: string[] = []
  const worker = await fixture({ profileScript: currentScript }, [dispatched], {
    run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) }
  })
  const { agents } = await worker.request('state')
  assert.deepEqual(commands, ['list'])
  assert.deepEqual(agents.map(({ task, isWorker, odd }) => ({ task, isWorker, odd })),
    [{ task, isWorker: true, odd: null }])
  await worker.deactivate()
})

test('marks a taskless row from a later dispatch page and skips its show without changing other rows', async () => {
  const python: string[][] = []
  const dispatchArgv: string[][] = []
  const worker = await fixture({ profileScript: currentScript }, [terminalOnly, agent('codex')], {
    run: async (argv, childEnv) => {
      python.push([...argv])
      return fakeRun(argv, childEnv)
    },
    runExecutable: async (executable, argv) => {
      assert.equal(executable, fakeOrca)
      dispatchArgv.push([...argv])
      if (argv.includes('--cursor')) return dispatches([terminalOnly.terminalId])
      return dispatchResult([{ dispatchId: 'null-terminal', terminal: null }, { dispatchId: 'without-terminal' }], 'next')
    }
  })
  try {
    const state = await worker.request('state')
    assert.deepEqual(dispatchArgv, [workerListArgv, [...workerListArgv, '--cursor', 'next']])
    assert.deepEqual(state.agents.map(({ isWorker, odd }) => [isWorker, odd]), [[true, null], [undefined, show]])
    assert.deepEqual(python.map((argv) => argv[2]), ['list', 'show'])
  } finally {
    await worker.deactivate()
  }
})

test('stops at the page with a known dispatch ID and rebuilds the full cache on restart', async () => {
  const cursors: (string | undefined)[] = []
  let newPage = false
  const options: Partial<main.WorkerOptions> = {
    runExecutable: async (_executable, argv) => {
      const cursor = argv[6]
      cursors.push(cursor)
      if (cursor === 'older') return dispatches([terminalOnly.terminalId])
      if (!cursor && newPage) return dispatches(['new-terminal'], 'known')
      return dispatchResult([{ dispatchId: 'known-without-terminal' }], 'older')
    }
  }
  const mount = () => fixture({ profileScript: currentScript }, [terminalOnly], options)
  const worker = await mount()
  try {
    assert.equal((await worker.request('state')).agents[0].isWorker, true)
    assert.deepEqual(cursors.splice(0), [undefined, 'older'])
    newPage = true
    assert.equal((await worker.request('state')).agents[0].isWorker, true)
    assert.deepEqual(cursors.splice(0), [undefined, 'known'])
  } finally {
    await worker.deactivate()
  }
  const restarted = await mount()
  try {
    assert.equal((await restarted.request('state')).agents[0].isWorker, true)
    assert.deepEqual(cursors, [undefined, 'known', 'older'])
  } finally {
    await restarted.deactivate()
  }
})

test('marks a newly dispatched row on the next state read and skips its show', async () => {
  let added = false
  const commands: string[] = []
  const cursors: (string | undefined)[] = []
  const worker = await fixture({ profileScript: currentScript }, [terminalOnly], {
    run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) },
    runExecutable: async (_executable, argv) => {
      cursors.push(argv[6])
      if (argv[6]) return dispatches(['older-terminal'])
      return dispatchResult([
        ...(added ? [{ dispatchId: 'new-dispatch', terminal: terminalOnly.terminalId }] : []),
        { dispatchId: 'known', terminal: 'unrelated-terminal' }
      ], 'older')
    }
  })
  try {
    assert.equal((await worker.request('state')).agents[0].isWorker, undefined)
    assert.deepEqual(commands.splice(0), ['list', 'show'])
    assert.deepEqual(cursors.splice(0), [undefined, 'older'])
    added = true
    const { agents } = await worker.request('state')
    assert.deepEqual([agents[0].isWorker, agents[0].odd], [true, null])
    assert.deepEqual(commands, ['list'])
    assert.deepEqual(cursors, [undefined])
  } finally {
    await worker.deactivate()
  }
})

test('gives each page five seconds and does not cache IDs or terminals from a timed-out read', async () => {
  let phase: 'seed' | 'timeout' | 'recover' = 'seed'
  const commands: string[] = []
  const timeoutBudgets: (number | undefined)[] = []
  const existing = { dispatchId: 'existing' }
  const worker = await fixture({ profileScript: currentScript }, [terminalOnly, agent('codex')], {
    run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) },
    runExecutable: async (_executable, argv, _env, _signal, timeout) => {
      if (phase === 'seed') return dispatchResult([existing])
      if (phase === 'timeout') timeoutBudgets.push(timeout)
      if (!argv[6]) return dispatchResult(
        [{ dispatchId: 'tentative', terminal: phase === 'timeout' ? 'codex' : null }], 'next'
      )
      if (phase === 'timeout') throw new Error('Orca CLI timed out.')
      return dispatchResult([{ dispatchId: 'another', terminal: terminalOnly.terminalId }, existing])
    }
  })
  try {
    await worker.request('state')
    commands.length = 0
    phase = 'timeout'
    const failed = await worker.request('state')
    assert.match(failed.workerCheckError ?? '', /timed out/)
    assert.deepEqual(failed.agents.map((row) => row.odd), [null, null])
    assert.deepEqual(commands, [])
    phase = 'recover'
    const recovered = await worker.request('state')
    assert.equal(recovered.workerCheckError, undefined)
    assert.deepEqual(recovered.agents.map(({ isWorker, odd }) => [isWorker, odd]), [[true, null], [undefined, show]])
    assert.deepEqual(timeoutBudgets, [5000, 5000])
  } finally {
    await worker.deactivate()
  }
})

test('loads many pages on a cold read even when their elapsed time exceeds five seconds', async () => {
  let pages = 0
  const worker = await fixture({ profileScript: currentScript }, [terminalOnly], {
    runExecutable: async (_executable, _argv, _env, _signal, timeout) => {
      const page = ++pages
      const elapsed = page === 1 ? 4800 : 350
      if (timeout === undefined || timeout < elapsed) throw new Error('Orca CLI timed out.')
      if (page <= 2) await delay(elapsed)
      return page === 36
        ? dispatches([terminalOnly.terminalId])
        : dispatchResult([{ dispatchId: `dispatch-${page}` }], String(page + 1))
    }
  })
  try {
    const { agents, workerCheckError } = await worker.request('state')
    assert.equal(workerCheckError, undefined)
    assert.equal(agents[0].isWorker, true)
    assert.equal(pages, 36)
  } finally {
    await worker.deactivate()
  }
})

test('resolves an absolute configured file, then an executable on PATH, then the bundled file', async (t) => {
  const home = await temp(t)
  const configured = await scriptAt(join(home, 'configured'))
  const first = join(home, 'first')
  const second = join(home, 'second')
  const installed = join(second, 'orca')
  const bundled = await scriptAt(join(home, 'bundled/orca'))
  await scriptAt(join(first, 'orca'))
  await mkdir(second)
  await writeFile(installed, '', { mode: 0o755 })
  const PATH = [first, second].join(':')
  assert.equal(await main.resolveOrcaExecutable({ ORCA_CLI_COMMAND: configured, PATH }, bundled), configured)
  for (const invalid of ['orca', join(home, 'missing'), first]) {
    assert.equal(await main.resolveOrcaExecutable({ ORCA_CLI_COMMAND: invalid, PATH }, bundled), installed)
  }
  assert.equal(await main.resolveOrcaExecutable({ PATH: first }, bundled), bundled)
  assert.equal(await main.resolveOrcaExecutable({}, join(home, 'missing')), undefined)
})

test('executes the Orca file directly and passes the dispatch list argv unchanged', async (t) => {
  const home = await temp(t)
  const executable = join(home, 'orca literal; $(printf marker)')
  await writeFile(executable, `#!/bin/sh
[ "$#" -eq 5 ] && [ "$1" = orchestration ] && [ "$2" = worker-list ] &&
[ "$3" = --environment ] && [ "$4" = local ] && [ "$5" = --json ] || exit 9
printf '%s\\n' '${dispatches([terminalOnly.terminalId]).stdout}'
`, { mode: 0o755 })
  const worker = await fixture({ profileScript: currentScript }, [terminalOnly], {
    env: { ORCA_CLI_COMMAND: executable }, resolveOrca: undefined, runExecutable: undefined
  })
  try {
    const state = await worker.request('state')
    assert.equal(state.agents[0].isWorker, true)
  } finally {
    await worker.deactivate()
  }
})

test('keeps nonzero-exit and malformed-JSON failures in their own rows and retains stderr', async () => {
  const script = currentScript
  const worker = await fixture({ profileScript: script }, [agent('claude'), agent('codex'), agent('antigravity')], {
    run: async (argv, childEnv) => {
      if (childEnv.CLAUDE_CODE_SESSION_ID) throw Object.assign(new Error('exit 2'), { stderr: 'unsupported flag' })
      if (childEnv.CODEX_THREAD_ID) return { stdout: 'not JSON', stderr: 'bad response detail' }
      return fakeRun(argv, childEnv)
    }
  })
  const { agents } = await worker.request('state')
  assert.match(String(agents[0].odd), /unsupported flag/)
  assert.match(String(agents[1].odd), /bad response detail/)
  assert.deepEqual(agents[2].odd, show)
  await worker.deactivate()
})

test('uses the setting first, then the newest semver directory of each cache in order, then Gemini', async (t) => {
  const home = await temp(t)
  const suffix = 'skills/odd-flow/scripts/profile.py'
  const claudeCache = join(home, '.claude/plugins/cache/odd-flow/odd-flow')
  const codexCache = join(home, '.codex/plugins/cache/odd-flow/odd-flow')
  const setting = await scriptAt(join(home, 'explicit/profile.py'))
  for (const version of ['1.9.9', '1.10.0-rc.1', 'invalid']) await scriptAt(join(claudeCache, version, suffix))
  const claude = await scriptAt(join(claudeCache, '1.10.0', suffix))
  const codex = await scriptAt(join(codexCache, '2.0.0', suffix))
  const gemini = await scriptAt(join(home, '.gemini/config/plugins/odd-flow', suffix))
  for (const [profileScript, path, source] of [
    [setting, setting, 'profileScript setting'],
    ['', claude, 'Claude cache'],
    ['', codex, 'Codex cache'],
    ['', gemini, 'Gemini config']
  ]) {
    const worker = await fixture({ profileScript }, [], { home })
    assert.deepEqual((await worker.request('state')).script, { path, source })
    await worker.deactivate()
    if (path === claude) await rm(claudeCache, { recursive: true })
    if (path === codex) await rm(codexCache, { recursive: true })
  }
})

test('reports a missing script and names the setting without running a process', async (t) => {
  const home = await temp(t)
  let calls = 0
  const worker = await fixture({}, [agent('claude')], {
    home,
    run: async (argv, childEnv) => { calls++; return fakeRun(argv, childEnv) }
  })
  const state = await worker.request('state')
  assert.equal(calls, 0)
  assert.match('error' in state.script ? state.script.error : '', /profileScript/)
  assert.equal(state.profiles, null)
  assert.equal(state.agents.length, 1)
  assert.match(String(state.agents[0].odd), /profileScript/)
  await worker.deactivate()
})

test('reads the real profile.py JSON for each kind without writing to the isolated home', async (t) => {
  const home = await temp(t)
  const profilePath = join(home, 'profiles.json')
  await writeFile(profilePath, JSON.stringify({
    default: 'base', profiles: { base: {}, a: {}, b: {}, c: {} },
    workflow: { b: { orchestratorMode: 'full-delegation' } }
  }))
  const sessions = join(home, 'sessions')
  await mkdir(sessions)
  for (const [sid, profile] of [['sc', 'a'], ['sx', 'b'], ['sg', 'c'],
    ['parent-claude', 'base'], ['parent-codex', 'base'], ['parent-antigravity', 'base']]) {
    await writeFile(join(sessions, sid + '.json'), JSON.stringify({ profile }))
  }
  const names = (await readdir(sessions)).sort()
  const snapshot = () => Promise.all([readFile(profilePath),
    ...names.map((name) => readFile(join(sessions, name)))])
  const before = await snapshot()
  const worker = await fixture({ profileScript: currentScript }, [
    agent('claude', 'sc'), agent('codex', 'sx'), agent('antigravity', 'sg'),
    agent('pi'), agent('claude', null)
  ], { env: { ...keys, PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython })
  const { profiles, agents } = await worker.request('state')
  assert.ok(profiles && typeof profiles === 'object')
  assert.equal(profiles.default, 'base')
  assert.deepEqual(agents.map(({ odd }) => odd && typeof odd === 'object'
    ? [odd.profile, odd.source, odd.session_key, odd.mode, odd.orca_terminal] : odd), [
    ['a', 'session (CLAUDE_CODE_SESSION_ID)', 'CLAUDE_CODE_SESSION_ID', 'organic', null],
    ['b', 'session (CODEX_THREAD_ID)', 'CODEX_THREAD_ID', 'full-delegation', null],
    ['c', 'session (ANTIGRAVITY_CONVERSATION_ID)', 'ANTIGRAVITY_CONVERSATION_ID', 'organic', null],
    null, null
  ])
  assert.deepEqual((await readdir(home)).sort(), ['profiles.json', 'sessions'])
  assert.deepEqual((await readdir(sessions)).sort(), names)
  assert.deepEqual(await snapshot(), before)
  await worker.deactivate()
})

test('reports old scripts, nonzero exits, invalid JSON and bounded timeouts in list and rows', async (t) => {
  const home = await temp(t)
  for (const [filename, content, expected] of [
    ['old-profile.py', null, /unrecognized arguments: --json/],
    ['exit.py', 'import sys\nsys.stderr.write("boom-stderr\\n")\nsys.exit(3)\n', /boom-stderr/],
    ['garbage.py', 'print("not JSON")\n', /invalid JSON/],
    ['wrong-shape.py', 'print("[1,2]")\n', /invalid JSON/],
    ['sleep.py', 'import time\ntime.sleep(20)\n', /timed out/i]
  ] as const) {
    const script = content === null ? oldScript : join(home, filename)
    if (content !== null) await writeFile(script, content)
    const worker = await fixture({ profileScript: script }, [agent('claude'), agent('codex')], {
      env: { PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
    })
    const started = Date.now()
    const { profiles, agents } = await worker.request('state')
    assert.match(String(profiles), expected)
    for (const row of agents) assert.match(String(row.odd), expected)
    if (filename === 'sleep.py') assert.ok(Date.now() - started < 8000)
    await worker.deactivate()
  }
})

test('passes a script path containing shell metacharacters as a single literal argument', async (t) => {
  const home = await temp(t)
  const filename = 'profile a; $(printf marker) `printf marker`.py'
  const script = join(home, filename)
  await writeFile(script, 'import json,sys\nprint(json.dumps({"profiles":[]} if sys.argv[1]=="list" else {"mode":"organic"}))\n')
  const worker = await fixture({ profileScript: script }, [agent('claude')], {
    env: { PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  const { agents } = await worker.request('state')
  assert.deepEqual(agents[0].odd, { mode: 'organic' })
  assert.deepEqual(await readdir(home), [filename])
  await worker.deactivate()
})

test('does not fall back to a cache for a bad explicit script setting', async (t) => {
  const home = await temp(t)
  const cached = await scriptAt(join(home, '.claude/plugins/cache/odd-flow/odd-flow/0.10.0/skills/odd-flow/scripts/profile.py'))
  for (const profileScript of ['profile.py', './profile.py', '~/profile.py', home, join(home, 'missing.py'), '  ', 5]) {
    let calls = 0
    const worker = await fixture({ profileScript }, [agent('claude')], {
      home, run: async (argv, childEnv) => { calls++; return fakeRun(argv, childEnv) }
    })
    const { script } = await worker.request('state')
    assert.match('error' in script ? script.error : '', typeof profileScript === 'number' ? /string/ : /profileScript/)
    assert.equal(calls, 0)
    await worker.deactivate()
  }
  const worker = await fixture({ profileScript: cached }, [], { home })
  assert.deepEqual((await worker.request('state')).script, { path: cached, source: 'profileScript setting' })
  await worker.deactivate()
})

test('falls through when the newest Claude version has no script rather than using an older one', async (t) => {
  const home = await temp(t)
  const suffix = 'skills/odd-flow/scripts/profile.py'
  const claude = join(home, '.claude/plugins/cache/odd-flow/odd-flow')
  await scriptAt(join(claude, '0.1.0', suffix))
  await mkdir(join(claude, '0.3.0'))
  const codex = await scriptAt(join(home, '.codex/plugins/cache/odd-flow/odd-flow/0.2.0', suffix))
  const worker = await fixture({}, [], { home })
  assert.deepEqual((await worker.request('state')).script, { path: codex, source: 'Codex cache' })
  await worker.deactivate()
})

test('returns an agents.list failure without throwing or starting Python', async () => {
  const worker = await fixture({ profileScript: currentScript }, [], {
    run: async () => { assert.fail('unexpected process') }
  }, { 'agents.list': () => { throw hostError('unavailable', 'agent list offline') } })
  assert.match((await worker.request('state')).error ?? '', /agent list offline/)
  assert.match((await worker.request('clear', { agent: 'codex', sessionId: 'x' })).error ?? '', /agent list offline/)
  await worker.deactivate()
})

test('runs each matching mutation with isolated argv and session env, then returns fresh state', async () => {
  const agents = [agent('claude'), agent('codex'), agent('antigravity')]
  const calls: { argv: readonly string[]; env: Record<string, string | undefined> }[] = []
  let last = ''
  const worker = await fixture({ profileScript: currentScript }, agents, {
    run: async (argv, childEnv) => {
      calls.push({ argv, env: childEnv })
      if (argv[2] === 'list') return fakeRun(argv, childEnv)
      if (argv[2] === 'show') return { stdout: JSON.stringify({ ...show, source: last }), stderr: '' }
      last = argv[2]
      return { stdout: '', stderr: '' }
    }
  })
  for (const [request, command, kind, variable, args] of [
    ['use', 'use', 'claude', 'CLAUDE_CODE_SESSION_ID', ['--', 'test']],
    ['sessionMode', 'session-mode', 'codex', 'CODEX_THREAD_ID', ['full-delegation']],
    ['clear', 'clear', 'antigravity', 'ANTIGRAVITY_CONVERSATION_ID', []]
  ] as const) {
    calls.length = 0
    const beforeRefresh = worker.host.callsOf('statusBar.update').length
    const input = { agent: kind, sessionId: kind }
    const result = request === 'use' ? await worker.request('use', { ...input, profile: 'test' })
      : request === 'sessionMode' ? await worker.request('sessionMode', { ...input, mode: 'full-delegation' })
      : await worker.request('clear', input)
    assert.ok(result.state)
    assert.equal(worker.host.callsOf('statusBar.update').length, beforeRefresh + 1)
    assert.deepEqual(result.state.agents.map(({ odd }) => odd), agents.map(() => ({ ...show, source: command })))
    assert.deepEqual(calls.map(({ argv }) => argv[2]),
      [...(request === 'use' ? ['list'] : []), command, 'list', 'show', 'show', 'show'])
    assert.deepEqual(calls.find(({ argv }) => argv[2] === command), {
      argv: ['-I', currentScript, command, ...args], env: { ODD_FLOW_HOME: '/keep', [variable]: kind }
    })
  }
  await worker.deactivate()
})

test('rejects malformed or unreported targets and invalid values before a mutation', async () => {
  const commands: string[] = []
  const worker = await fixture({ profileScript: currentScript }, [agent('codex', 'live')], {
    run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) }
  })
  assert.match((await worker.request('use', { agent: 'pi' as never, sessionId: 'live', profile: 'test' })).error ?? '', /agent/i)
  assert.match((await worker.request('clear', { agent: 'codex', sessionId: ' ' })).error ?? '', /session/i)
  assert.match((await worker.request('clear', { agent: 'claude', sessionId: 'live' })).error ?? '', /session/i)
  assert.match((await worker.request('clear', { agent: 'codex', sessionId: 'gone' })).error ?? '', /session/i)
  assert.match((await worker.request('sessionMode', { agent: 'codex', sessionId: 'live', mode: 'invalid' as never })).error ?? '', /mode/i)
  assert.match((await worker.request('use', { agent: 'codex', sessionId: 'live', profile: '' })).error ?? '', /profile/i)
  assert.deepEqual(commands, [])
  assert.match((await worker.request('use', { agent: 'codex', sessionId: 'live', profile: 'unknown' })).error ?? '', /profile/i)
  assert.deepEqual(commands, ['list'])
  await worker.deactivate()
})

test('surfaces the failing command stderr without reading success state', async () => {
  const commands: string[] = []
  const worker = await fixture({ profileScript: currentScript }, [agent('codex', 'live')], {
    run: async (argv) => {
      commands.push(argv[2])
      throw Object.assign(new Error('exit 1'), { stderr: 'binding failed' })
    }
  })
  assert.match((await worker.request('clear', { agent: 'codex', sessionId: 'live' })).error ?? '', /binding failed/)
  assert.deepEqual(commands, ['clear'])
  await worker.deactivate()
})

const workerTarget = { agent: 'claude', sessionId: 'worker-sid' } as const
for (const [name, request] of [
  ['use', (worker: Awaited<ReturnType<typeof fixture>>) => worker.request('use', { ...workerTarget, profile: 'test' })],
  ['session-mode', (worker: Awaited<ReturnType<typeof fixture>>) =>
    worker.request('sessionMode', { ...workerTarget, mode: 'organic' })],
  ['clear', (worker: Awaited<ReturnType<typeof fixture>>) => worker.request('clear', workerTarget)]
] as const) {
  test(`rejects ${name} for a worker session without running a process`, async () => {
    const commands: string[] = []
    const worker = await fixture({ profileScript: currentScript }, [dispatched], {
      run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) }
    })
    const result = await request(worker)
    assert.deepEqual(commands, [])
    assert.match(result.error ?? '', /worker/i)
    await worker.deactivate()
  })

  test(`re-reads dispatches before ${name} and rejects a newly dispatched session without Python`, async () => {
    let dispatchedNow = false
    let checks = 0
    const commands: string[] = []
    const worker = await fixture({ profileScript: currentScript }, [terminalOnly], {
      run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) },
      runExecutable: async () => { checks++; return dispatches(dispatchedNow ? [terminalOnly.terminalId] : []) }
    })
    try {
      assert.equal((await worker.request('state')).agents[0].isWorker, undefined)
      commands.length = 0
      dispatchedNow = true
      assert.match((await request(worker)).error ?? '', /worker/i)
      assert.deepEqual(commands, [])
      assert.equal(checks, 2)
    } finally {
      await worker.deactivate()
    }
  })
}

for (const [name, result, expected] of [
  ['missing executable', null, /executable.*not found/i],
  ['non-zero exit', Object.assign(new Error('exit 2'), { stderr: 'Orca RPC failed' }), /Orca RPC failed/],
  ['timeout', new Error('Orca CLI timed out'), /timed out/i],
  ['bad JSON', { stdout: 'not JSON', stderr: '' }, /invalid JSON/i],
  ['invalid payload', { stdout: '{"ok":true,"result":{"workers":[{}]}}', stderr: '' }, /invalid dispatch list/i],
  ['ok false', { stdout: '{"ok":false}', stderr: '' }, /reported failure/i]
] as const) {
  test(`fails closed on dispatch-list ${name}, preserving rows and rejecting every mutation before Python`, async (t) => {
    const commands: string[] = []
    if (name === 'timeout') {
      const executable = join(await temp(t), 'sleeping-orca')
      await writeFile(executable, '#!/bin/sh\nexec /bin/sleep 20\n', { mode: 0o755 })
      const native = await fixture({ profileScript: currentScript }, [terminalOnly], {
        run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) },
        resolveOrca: async () => executable,
        runExecutable: undefined
      })
      try {
        const start = Date.now()
        const state = await native.request('state')
        assert.match(state.workerCheckError ?? '', expected)
        assert.equal(state.agents.length, 1)
        assert.ok(Date.now() - start < 8000)
      } finally {
        await native.deactivate()
      }
    }
    const worker = await fixture({ profileScript: currentScript }, [terminalOnly], {
      run: async (argv, childEnv) => { commands.push(argv[2]); return fakeRun(argv, childEnv) },
      resolveOrca: async () => result === null ? undefined : fakeOrca,
      runExecutable: async () => {
        if (result instanceof Error) throw result
        return result ?? dispatches()
      }
    })
    try {
      const state = await worker.request('state')
      assert.deepEqual(state.agents.map((row) => row.terminalId), [terminalOnly.terminalId])
      const unavailable = state.workerCheckError ?? ''
      assert.match(unavailable, expected)
      assert.equal((await worker.request('use', { ...workerTarget, profile: 'test' })).error, unavailable)
      assert.equal((await worker.request('sessionMode', { ...workerTarget, mode: 'organic' })).error, unavailable)
      assert.equal((await worker.request('clear', workerTarget)).error, unavailable)
      assert.deepEqual(commands, [])
    } finally {
      await worker.deactivate()
    }
  })
}

test('use, session-mode, and clear change only session files with the real profile.py', async (t) => {
  const home = await temp(t)
  const file = join(home, 'profiles.json')
  const before = Buffer.from(JSON.stringify({
    default: 'base', profiles: { base: {}, bound: {} },
    workflow: { bound: { orchestratorMode: 'full-delegation' } }
  }, null, 2) + '\n')
  await writeFile(file, before)
  const worker = await fixture({ profileScript: currentScript }, [agent('codex')], {
    env: { ...keys, PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  const target = { agent: 'codex', sessionId: 'codex' } as const
  const use = await worker.request('use', { ...target, profile: 'bound' })
  assert.ok(use.state)
  const bound = use.state.agents[0].odd
  assert.ok(bound && typeof bound === 'object')
  assert.deepEqual([bound.profile, bound.source, bound.mode], ['bound', 'session (CODEX_THREAD_ID)', 'full-delegation'])
  const mode = await worker.request('sessionMode', { ...target, mode: 'organic' })
  assert.ok(mode.state)
  const overridden = mode.state.agents[0].odd
  assert.ok(overridden && typeof overridden === 'object')
  assert.deepEqual([overridden.mode, overridden.mode_source], ['organic', 'session (CODEX_THREAD_ID)'])
  assert.deepEqual(await readdir(join(home, 'sessions')), ['codex.json'])
  const rebound = await worker.request('use', { ...target, profile: 'bound' })
  assert.ok(rebound.state)
  const reset = rebound.state.agents[0].odd
  assert.ok(reset && typeof reset === 'object')
  assert.deepEqual([reset.mode, reset.mode_source], ['full-delegation', 'profile bound'])
  const clear = await worker.request('clear', target)
  assert.ok(clear.state)
  const cleared = clear.state.agents[0].odd
  assert.ok(cleared && typeof cleared === 'object')
  assert.deepEqual([cleared.profile, cleared.source, cleared.mode], ['base', 'file default', 'organic'])
  assert.deepEqual(await readdir(join(home, 'sessions')), [])
  assert.deepEqual((await readdir(home)).sort(), ['profiles.json', 'sessions'])
  assert.deepEqual(await readFile(file), before)
  await worker.deactivate()
})

test('binds a listed profile whose name looks like an option', async (t) => {
  const home = await temp(t)
  await writeFile(join(home, 'profiles.json'), JSON.stringify({
    default: 'base', profiles: { base: {}, '-h': {}, '--yes': {} }
  }))
  const worker = await fixture({ profileScript: currentScript }, [agent('claude', 'sid')], {
    env: { ...keys, PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  for (const profile of ['-h', '--yes']) {
    const result = await worker.request('use', { agent: 'claude', sessionId: 'sid', profile })
    assert.equal(result.error, undefined)
    const odd = result.state?.agents[0].odd
    assert.ok(odd && typeof odd === 'object')
    assert.deepEqual([odd.profile, odd.source], [profile, 'session (CLAUDE_CODE_SESSION_ID)'])
  }
  await worker.deactivate()
})

const openCommand = 'odd-flow.openProfiles'
const toggleCommand = 'odd-flow.toggleMode'
const pluginListArgv = ['plugin', 'list', '--json']
const openArgv = (key = 'local.odd-flow-profiles') =>
  ['plugin', 'open', key, '--panel', 'odd-flow-profiles', '--json']
const cliOk = (result: unknown = {}) => ({ stdout: JSON.stringify({ ok: true, result }), stderr: '' })
const installed = (pluginKey: string, status = 'running') => ({ pluginKey, status })
const workspaceEvent = { context: null }
const agentEvent = { workspaceId: null, paneKey: 'pane', state: 'waiting', receivedAt: 1 } as const

async function controlsFixture(
  agents: () => ReturnType<typeof agent>[],
  options: {
    settings?: MockHostOptions['settings']
    env?: main.WorkerOptions['env']
    run?: main.Runner
    runExecutable?: main.WorkerOptions['runExecutable']
  } = {}
) {
  const host = mockHost({
    capabilities: ['agent:read', 'workspace:read', 'settings:own'],
    settings: { profileScript: currentScript, ...options.settings },
    results: { ...statusHostResults, 'agents.list': () => ({ agents: agents() }) }
  })
  const runExecutable: main.WorkerOptions['runExecutable'] = async (_executable, argv) => {
    if (argv[0] === 'orchestration') return dispatches()
    if (argv[1] === 'list') return cliOk({ plugins: [installed('local.odd-flow-profiles')] })
    return cliOk()
  }
  let stop: (() => void) | undefined
  let tick: (() => void | Promise<void>) | undefined
  const activate = main.createWorker({
    env: options.env ?? env,
    resolveOrca: async () => fakeOrca,
    run: options.run ?? fakeRun,
    runExecutable: options.runExecutable ?? runExecutable,
    scheduleRefresh: (refresh) => {
      tick = refresh
      return () => { tick = undefined }
    }
  })
  const worker = await mountWorker({ default: (orca) => { stop = activate(orca) }, deactivate: () => stop?.() }, {
    host, events: ['agent.status.changed', 'workspace.changed'], commands: [openCommand, toggleCommand]
  })
  return {
    worker,
    tick: () => tick?.(),
    status: () => host.callsOf('statusBar.update').at(-1) as HostMethods['statusBar.update']['params'] | undefined
  }
}

test('status bar follows the focused coordinator count on agent and workspace events', async () => {
  let rows = [dispatched, agent('pi'), agent('codex', null)]
  const fixture = await controlsFixture(() => rows)
  try {
    await fixture.worker.emit('workspace.changed', workspaceEvent)
    assert.equal(fixture.status()?.visible, false)
    rows = [agent('codex'), dispatched]
    await fixture.worker.emit('agent.status.changed', agentEvent)
    assert.deepEqual(fixture.status(), {
      id: 'odd-flow-status', visible: true, text: 'odd: test · organic', tone: 'neutral',
      tooltip: 'Profile source: file default\nMode source: default'
    })
    rows = [agent('codex'), agent('antigravity'), dispatched]
    await fixture.worker.emit('workspace.changed', workspaceEvent)
    assert.equal(fixture.status()?.visible, true)
    assert.equal(fixture.status()?.tone, 'neutral')
    assert.equal(fixture.status()?.text, 'odd: 2 sessions')
  } finally {
    await fixture.worker.deactivate()
  }
})

test('status bar reports failed dispatch checks, missing scripts and Show errors, then clears the error tone', async () => {
  for (const [options, label, tone, detail] of [
    [{ runExecutable: async () => { throw new Error('dispatch offline') } },
      'odd: worker check failed', 'danger', /dispatch offline/],
    [{ settings: { profileScript: 'not-absolute' } },
      'odd: script unavailable', 'warning', /profileScript/],
    [{ run: async (argv: readonly string[], env: Record<string, string | undefined>) => {
      if (argv[2] === 'show') throw new Error('show offline')
      return fakeRun(argv, env)
    } }, 'odd: show failed', 'warning', /show offline/]
  ] as const) {
    let rows = [agent('codex')]
    const fixture = await controlsFixture(() => rows, options)
    try {
      await fixture.tick()
      assert.equal(fixture.status()?.visible, true)
      assert.equal(fixture.status()?.text, label)
      assert.equal(fixture.status()?.tone, tone)
      assert.match(fixture.status()?.tooltip ?? '', detail)
      if (tone === 'warning') {
        rows = []
        await fixture.tick()
        assert.equal(fixture.status()?.visible, false)
        assert.equal(fixture.status()?.tone, 'neutral')
      }
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('coalesces overlapping event and timer refreshes into one trailing read', async () => {
  let reads = 0
  let active = 0
  let maxActive = 0
  let rows = [agent('codex')]
  let started!: () => void
  let release!: () => void
  const startedRead = new Promise<void>((resolve) => { started = resolve })
  const gate = new Promise<void>((resolve) => { release = resolve })
  const fixture = await controlsFixture(() => rows, {
    runExecutable: async () => {
      maxActive = Math.max(maxActive, ++active)
      if (++reads === 1) {
        started()
        await gate
      }
      active--
      return dispatches()
    }
  })
  try {
    const first = fixture.tick()
    assert.ok(first, 'the worker registered a fallback timer')
    await startedRead
    rows = [agent('codex'), agent('antigravity')]
    const followups = [
      fixture.worker.emit('agent.status.changed', agentEvent),
      fixture.worker.emit('workspace.changed', workspaceEvent),
      fixture.tick()
    ]
    release()
    await Promise.all([first, ...followups])
    assert.equal(reads, 2)
    assert.equal(maxActive, 1)
    assert.equal(fixture.status()?.text, 'odd: 2 sessions')
  } finally {
    release()
    await fixture.worker.deactivate()
  }
})

test('Open profiles panel discovers one enabled key at command time or uses the override, always with argv', async () => {
  for (const override of ['', 'custom.odd-flow-profiles']) {
    const calls: (readonly string[])[] = []
    const fixture = await controlsFixture(() => [], {
      settings: { pluginKey: override },
      env: { ...env, ORCA_ENVIRONMENT: 'paired', ORCA_PAIRING_CODE: 'fake' },
      runExecutable: async (executable, argv, childEnv) => {
        assert.equal(executable, fakeOrca)
        assert.deepEqual(childEnv, { ODD_FLOW_HOME: '/keep' })
        calls.push(argv)
        return argv[1] === 'list'
          ? cliOk({ plugins: [
            installed('disabled.odd-flow-profiles', 'disabled'),
            installed('unrelated.other'), installed('git.odd-flow-profiles', 'idle')
          ] })
          : cliOk()
      }
    })
    try {
      assert.deepEqual(calls, [])
      await fixture.worker.command(openCommand)
      assert.deepEqual(calls, override ? [openArgv(override)] : [pluginListArgv, openArgv('git.odd-flow-profiles')])
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('Open profiles panel refuses zero or multiple discovered keys and names the setting', async () => {
  for (const plugins of [[], [installed('dev.odd-flow-profiles'), installed('git.odd-flow-profiles')]]) {
    const calls: (readonly string[])[] = []
    const fixture = await controlsFixture(() => [agent('codex')], {
      runExecutable: async (_executable, argv) => {
        if (argv[0] === 'orchestration') return dispatches()
        calls.push(argv)
        return cliOk({ plugins })
      }
    })
    try {
      assert.match(JSON.stringify(await fixture.worker.command(openCommand)), /pluginKey/)
      assert.deepEqual(calls, [pluginListArgv])
      assert.match(fixture.status()?.tooltip ?? '', /pluginKey/)
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('Toggle mode flips a sole coordinator using the mutation path, and panel mutations refresh status', async () => {
  let mode = 'organic'
  const mutations: { argv: readonly string[]; env: Record<string, string | undefined> }[] = []
  let scans = 0
  const fixture = await controlsFixture(() => [agent('codex'), dispatched], {
    runExecutable: async (_executable, argv) => {
      assert.deepEqual(argv, workerListArgv)
      scans++
      return dispatches()
    },
    run: async (argv, env) => {
      if (argv[2] === 'list') return fakeRun(argv, env)
      if (argv[2] === 'show') return { stdout: JSON.stringify({ ...show, mode }), stderr: '' }
      mutations.push({ argv, env })
      mode = argv[3]
      return { stdout: '', stderr: '' }
    }
  })
  try {
    await fixture.worker.command(toggleCommand)
    assert.equal(fixture.status()?.text, 'odd: test · full-delegation')
    await fixture.worker.command(toggleCommand)
    assert.equal(fixture.status()?.text, 'odd: test · organic')
    const result = await fixture.worker.request('sessionMode', {
      agent: 'codex', sessionId: 'codex', mode: 'full-delegation'
    })
    assert.ok(result.state)
    assert.equal(fixture.status()?.text, 'odd: test · full-delegation')
    assert.deepEqual(mutations, ['full-delegation', 'organic', 'full-delegation'].map((mode) => ({
      argv: ['-I', currentScript, 'session-mode', mode],
      env: { ODD_FLOW_HOME: '/keep', CODEX_THREAD_ID: 'codex' }
    })))
    assert.equal(scans, 8)
    assert.equal(fixture.worker.host.callsOf('agents.list').length, 8)
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Toggle mode opens the panel for no or several coordinators, workers, or unavailable worker checks', async () => {
  for (const { rows, unavailable = false, dispatchScanChanges = false } of [
    { rows: [] }, { rows: [agent('codex'), agent('antigravity')] },
    { rows: [dispatched, terminalOnly] }, { rows: [agent('codex')], unavailable: true },
    { rows: [terminalOnly], dispatchScanChanges: true }
  ]) {
    const pluginCalls: (readonly string[])[] = []
    const python: string[] = []
    let scans = 0
    const fixture = await controlsFixture(() => rows, {
      run: async (argv, env) => { python.push(argv[2]); return fakeRun(argv, env) },
      runExecutable: async (_executable, argv) => {
        if (argv[0] === 'orchestration') {
          if (unavailable) throw new Error('dispatch offline')
          return dispatches(!dispatchScanChanges || ++scans > 1 ? [terminalOnly.terminalId] : [])
        }
        pluginCalls.push(argv)
        return argv[1] === 'list' ? cliOk({ plugins: [installed('local.odd-flow-profiles')] }) : cliOk()
      }
    })
    try {
      await fixture.worker.command(toggleCommand)
      assert.deepEqual(pluginCalls, [pluginListArgv, openArgv()])
      assert.ok(python.every((cmd) => cmd === 'list' || cmd === 'show'))
      if (unavailable) assert.deepEqual(python, [])
    } finally {
      await fixture.worker.deactivate()
    }
  }
})
