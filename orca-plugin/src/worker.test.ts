import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test, type TestContext } from 'node:test'
import { setImmediate as nextTurn, setTimeout as delay } from 'node:timers/promises'
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
  assert.deepEqual(state.agents, agents.map((identity) => ({ ...identity, odd: show })))
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
      if (argv[1] === 'run-list') return cliOk({ runs: [] })
      if (argv.includes('--cursor')) return dispatches([terminalOnly.terminalId])
      return dispatchResult([{ dispatchId: 'null-terminal', terminal: null }, { dispatchId: 'without-terminal' }], 'next')
    }
  })
  try {
    const state = await worker.request('state')
    assert.deepEqual(dispatchArgv, [workerListArgv, [...workerListArgv, '--cursor', 'next'], runListArgv])
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
      if (argv[1] === 'run-list') return cliOk({ runs: [] })
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
      if (argv[1] === 'run-list') return cliOk({ runs: [] })
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

const upgradeError = (path: string) =>
  `odd-flow 0.3.0 or newer is required (found ${path}). Update the odd-flow plugin, or set profileScript to a newer profile.py.`

test('replaces old argparse errors in profile and row reads with upgrade instructions', async (t) => {
  const home = await temp(t)
  const worker = await fixture({ profileScript: oldScript }, [agent('claude'), agent('codex')], {
    env: { PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  try {
    const { profiles, agents } = await worker.request('state')
    assert.deepEqual([profiles, ...agents.map(({ odd }) => odd)], Array(3).fill(upgradeError(oldScript)))
  } finally {
    await worker.deactivate()
  }
})

test('keeps the raw failure when a traceback line ends in the argparse phrase', async (t) => {
  const home = await temp(t)
  const script = join(home, 'trace.py')
  await writeFile(script, 'import sys\nsys.stderr.write("Traceback (most recent call last):\\nRuntimeError: helper: error: unrecognized arguments: --json\\n")\nsys.exit(1)\n')
  const worker = await fixture({ profileScript: script }, [agent('claude')], {
    env: { PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  try {
    const { profiles, agents } = await worker.request('state')
    assert.match(String(profiles), /^profile\.py list failed: Traceback/)
    assert.match(String(agents[0].odd), /^profile\.py show failed: Traceback/)
  } finally {
    await worker.deactivate()
  }
})

test('keeps the raw failure when the script path contains the argparse phrase and stderr is empty', async (t) => {
  const home = await temp(t)
  const script = await scriptAt(join(home, 'path\nhelper: error: unrecognized arguments: --json\n', 'profile.py'))
  await writeFile(script, 'raise SystemExit(1)\n')
  const worker = await fixture({ profileScript: script }, [agent('claude')], {
    env: { PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  try {
    const { profiles, agents } = await worker.request('state')
    assert.match(String(profiles), /^profile\.py list failed: Command failed:/)
    assert.match(String(agents[0].odd), /^profile\.py show failed: Command failed:/)
  } finally {
    await worker.deactivate()
  }
})

test('preserves nonzero exits, invalid JSON and bounded timeouts in list and rows', async (t) => {
  const home = await temp(t)
  for (const [filename, content, expected] of [
    ['exit.py', 'import sys\nsys.stderr.write("boom-stderr: unrecognized arguments: --json-extra\\n")\nsys.exit(3)\n',
      /^profile\.py (list|show) failed: boom-stderr: unrecognized arguments: --json-extra$/],
    ['garbage.py', 'print("not JSON")\n', /invalid JSON/],
    ['wrong-shape.py', 'print("[1,2]")\n', /invalid JSON/],
    ['sleep.py', 'import time\ntime.sleep(20)\n', /timed out/i]
  ] as const) {
    const script = join(home, filename)
    await writeFile(script, content)
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
      runExecutable: async (_executable, argv) => {
        if (argv[1] === 'run-list') return cliOk({ runs: [] })
        checks++
        return dispatches(dispatchedNow ? [terminalOnly.terminalId] : [])
      }
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
    commandSignal?: AbortSignal
    log?: (line: string) => void
    updateStatus?: () => HostMethods['statusBar.update']['result']
  } = {}
) {
  const host = mockHost({
    capabilities: ['agent:read', 'workspace:read', 'settings:own'],
    settings: { profileScript: currentScript, ...options.settings },
    results: {
      ...statusHostResults, 'agents.list': () => ({ agents: agents() }),
      ...(options.updateStatus ? { 'statusBar.update': options.updateStatus } : {})
    }
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
  const worker = await mountWorker({ default: (orca) => {
    const signal = options.commandSignal
    stop = activate({
      ...orca,
      log: options.log ?? ((line) => orca.log(line)),
      commands: signal ? {
        register: (id, handler) => orca.commands.register(id, (args, ctx) => handler(args, { ...ctx, signal }))
      } : orca.commands
    })
  }, deactivate: () => stop?.() }, {
    host, events: ['agent.status.changed', 'workspace.changed'], commands: [openCommand, toggleCommand]
  })
  return {
    worker,
    tick: () => tick?.(),
    status: () => host.callsOf('statusBar.update').at(-1) as HostMethods['statusBar.update']['params'] | undefined
  }
}

test('status bar follows the focused coordinator count on agent and workspace events', { timeout: 5000 }, async () => {
  let rows = [dispatched, agent('pi'), agent('codex', null)]
  let markUpdated: () => void
  const fixture = await controlsFixture(() => rows, {
    updateStatus: () => { markUpdated(); return { ok: true } }
  })
  async function expectUpdate(emit: () => Promise<void>) {
    const updated = new Promise<void>((resolve) => { markUpdated = resolve })
    await Promise.all([emit(), updated])
  }
  try {
    await expectUpdate(() => fixture.worker.emit('workspace.changed', workspaceEvent))
    assert.equal(fixture.status()?.visible, false)
    rows = [agent('codex'), dispatched]
    await expectUpdate(() => fixture.worker.emit('agent.status.changed', agentEvent))
    assert.deepEqual(fixture.status(), {
      id: 'odd-flow-status', visible: true, text: 'odd: test · organic', tone: 'neutral',
      tooltip: 'Profile source: file default\nMode source: default'
    })
    rows = [agent('codex'), agent('antigravity'), dispatched]
    await expectUpdate(() => fixture.worker.emit('workspace.changed', workspaceEvent))
    assert.equal(fixture.status()?.visible, true)
    assert.equal(fixture.status()?.tone, 'neutral')
    assert.equal(fixture.status()?.text, 'odd: 2 sessions')
    assert.equal(fixture.status()?.tooltip, 'Open the ODD Flow panel')
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

test('status refresh reads only Show and warns about an outdated script for one or several coordinators', async (t) => {
  const home = await temp(t)
  for (const rows of [[agent('codex')], [agent('codex'), agent('claude')]]) {
    const calls: string[] = []
    const fixture = await controlsFixture(() => rows, {
      settings: { profileScript: oldScript },
      env: { PATH: process.env.PATH, ODD_FLOW_HOME: home },
      run: (argv, env) => { calls.push(argv[2]); return main.runPython(argv, env) }
    })
    try {
      await fixture.tick()
      assert.deepEqual(fixture.status(), {
        id: 'odd-flow-status', visible: true, text: 'odd: show failed', tone: 'warning',
        tooltip: upgradeError(oldScript)
      })
      assert.deepEqual(calls, rows.map(() => 'show'))
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('acknowledges overlapping events before the refresh completes and coalesces them into one trailing read', async () => {
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
    const events = Promise.all([
      fixture.worker.emit('agent.status.changed', agentEvent),
      fixture.worker.emit('workspace.changed', workspaceEvent)
    ])
    const timer = fixture.tick()
    const acknowledged = await Promise.race([events.then(() => true), nextTurn(false)])
    release()
    await Promise.all([first, events, timer])
    assert.equal(acknowledged, true, 'both event handlers must settle while the read is blocked')
    assert.equal(reads, 2)
    assert.equal(maxActive, 1)
    assert.equal(fixture.status()?.text, 'odd: 2 sessions')
  } finally {
    release()
    await fixture.worker.deactivate()
  }
})

test('logs a background refresh rejection without rejecting the event or leaking error details', async () => {
  const failure = Object.defineProperty(new Error('Host read failed.'), 'stderr', {
    get: () => { throw new Error('Private refresh failure details.') }
  })
  const fixture = await controlsFixture(() => { throw failure })
  try {
    const rejection = await fixture.worker.emit('agent.status.changed', agentEvent).catch((error) => error)
    await nextTurn()
    assert.deepEqual(fixture.worker.logs, ['Could not refresh odd-flow status.'])
    assert.equal(rejection, undefined)
  } finally {
    await fixture.worker.deactivate()
  }
})

test('handles a non-Error throw from a fire-and-forget timer refresh', async () => {
  const failure = Object.defineProperty({}, 'stderr', {
    get: () => { throw 'Private refresh failure details.' }
  })
  const fixture = await controlsFixture(() => { throw failure })
  try {
    void fixture.tick()
    await nextTurn()
    assert.deepEqual(fixture.worker.logs, ['Could not refresh odd-flow status.'])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Open ODD Flow panel discovers one enabled key at command time or uses the override, always with argv', async () => {
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
      assert.equal(await fixture.worker.command(openCommand), 'Opened the ODD Flow panel.')
      assert.deepEqual(calls, override ? [openArgv(override)] : [pluginListArgv, openArgv('git.odd-flow-profiles')])
      assert.deepEqual(fixture.worker.logs, [
        `${openCommand} started`,
        `${openCommand} ended: success; keySource=${override ? 'setting' : 'detected'}; key=${override || 'git.odd-flow-profiles'}`
      ])
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('Open ODD Flow panel refuses zero or multiple discovered keys and names the setting', async () => {
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
      const detail = `Found ${plugins.length} enabled ODD Flow plugins. Set pluginKey in Orca Settings.`
      assert.deepEqual(await fixture.worker.command(openCommand), { error: `Could not open the ODD Flow panel: ${detail}` })
      assert.deepEqual(calls, [pluginListArgv])
      assert.match(fixture.status()?.tooltip ?? '', /pluginKey/)
      assert.deepEqual(fixture.worker.logs, [
        `${openCommand} started`, `${openCommand} ended: error; keySource=detected; key=unresolved; ${detail}`
      ])
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('Open ODD Flow panel logs an aborted command without changing its result or status', async () => {
  const controller = new AbortController()
  const calls: (readonly string[])[] = []
  const key = 'custom.odd-flow-profiles'
  const fixture = await controlsFixture(() => [agent('codex')], {
    commandSignal: controller.signal,
    settings: { pluginKey: key },
    runExecutable: async (_executable, argv) => { calls.push(argv); return cliOk() }
  })
  try {
    controller.abort(new Error('cancelled'))
    assert.deepEqual(await fixture.worker.command(openCommand), {
      error: 'Could not open the ODD Flow panel: cancelled'
    })
    assert.deepEqual(calls, [])
    assert.equal(fixture.status(), undefined)
    assert.deepEqual(fixture.worker.logs, [
      `${openCommand} started`, `${openCommand} ended: error (aborted); keySource=setting; key=${key}; Command signal was aborted.`
    ])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Command diagnostics omit private data from subprocess errors and output', async () => {
  const sessionId = 'a1202c3b-732e-4d6e-9681-0589d57b3c0a'
  const envValue = 'env-secret-sentinel'
  const privateDetail = `${sessionId} ${envValue}`
  const fixture = await controlsFixture(() => [agent('codex', sessionId)], {
    env: { ...env, SAMPLE_SECRET: envValue },
    settings: { pluginKey: 'custom.odd-flow-profiles' },
    run: async (argv, env) => {
      if (argv[2] === 'session-mode') throw new Error(`profile.py output: ${privateDetail}`)
      return fakeRun(argv, env)
    },
    runExecutable: async (_executable, argv) => argv[0] === 'orchestration' ? dispatches() : {
      stdout: JSON.stringify({ ok: false, error: { message: `CLI output: ${privateDetail}` } }), stderr: ''
    }
  })
  try {
    assert.deepEqual(await fixture.worker.command(openCommand), {
      error: `Could not open the ODD Flow panel: CLI output: ${privateDetail}`
    })
    assert.deepEqual(await fixture.worker.command(toggleCommand), {
      error: `Could not run session-mode: profile.py output: ${privateDetail}`
    })
    assert.equal(fixture.worker.logs.length, 4)
    for (const line of fixture.worker.logs) {
      for (const value of [sessionId, envValue, 'CLI output:', 'profile.py output:']) assert.ok(!line.includes(value))
    }
  } finally {
    await fixture.worker.deactivate()
  }
})

test('A throwing logger does not change either command result, status, or subprocess calls', async () => {
  const key = 'custom.odd-flow-profiles'
  const calls: (readonly string[])[] = []
  let attempts = 0
  const fixture = await controlsFixture(() => [], {
    settings: { pluginKey: key },
    log: () => { attempts++; throw new Error('logger unavailable') },
    run: async (argv, env) => { calls.push(argv); return fakeRun(argv, env) },
    runExecutable: async (_executable, argv) => {
      calls.push(argv)
      return argv[0] === 'orchestration' ? dispatches() : cliOk()
    }
  })
  try {
    for (const command of [openCommand, toggleCommand]) {
      assert.equal(await fixture.worker.command(command), 'Opened the ODD Flow panel.')
    }
    assert.equal(fixture.status(), undefined)
    assert.deepEqual(calls, [openArgv(key), workerListArgv, openArgv(key)])
    assert.equal(attempts, 4)
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Toggle mode flips a sole coordinator using the mutation path, and panel mutations refresh status', async () => {
  let mode = 'organic'
  const mutations: { argv: readonly string[]; env: Record<string, string | undefined> }[] = []
  const cliCalls: (readonly string[])[] = []
  const fixture = await controlsFixture(() => [agent('codex'), dispatched], {
    runExecutable: async (_executable, argv) => {
      cliCalls.push(argv)
      return argv[1] === 'run-list' ? cliOk({ runs: [] }) : dispatches()
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
    assert.equal(await fixture.worker.command(toggleCommand), 'Switched odd-flow mode to full-delegation.')
    assert.equal(fixture.status()?.text, 'odd: test · full-delegation')
    assert.equal(await fixture.worker.command(toggleCommand), 'Switched odd-flow mode to organic.')
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
    assert.deepEqual(cliCalls, [...Array(8).fill(workerListArgv), runListArgv])
    assert.equal(fixture.worker.host.callsOf('agents.list').length, 8)
    assert.deepEqual(fixture.worker.logs, [
      `${toggleCommand} started`, `${toggleCommand} ended: success; switched to full-delegation`,
      `${toggleCommand} started`, `${toggleCommand} ended: success; switched to organic`
    ])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Toggle mode gives upgrade instructions without mutating an outdated script', async (t) => {
  const home = await temp(t)
  const calls: string[] = []
  const fixture = await controlsFixture(() => [agent('codex')], {
    settings: { profileScript: oldScript },
    env: { PATH: process.env.PATH, ODD_FLOW_HOME: home },
    run: (argv, env) => { calls.push(argv[2]); return main.runPython(argv, env) }
  })
  try {
    assert.deepEqual(await fixture.worker.command(toggleCommand), { error: upgradeError(oldScript) })
    assert.deepEqual(calls, ['show'])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Toggle mode opens the panel for no or several coordinators, workers, or unavailable worker checks', async () => {
  for (const { rows, reason, unavailable = false, dispatchScanChanges = false } of [
    { rows: [], reason: 'zero coordinators' },
    { rows: [agent('codex'), agent('antigravity')], reason: 'several coordinators' },
    { rows: [dispatched, terminalOnly], reason: 'zero coordinators' },
    { rows: [agent('codex')], reason: 'worker check unavailable', unavailable: true },
    { rows: [terminalOnly], reason: 'coordinator re-check', dispatchScanChanges: true }
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
      assert.equal(await fixture.worker.command(toggleCommand), 'Opened the ODD Flow panel.')
      assert.deepEqual(pluginCalls, [pluginListArgv, openArgv()])
      assert.ok(python.every((cmd) => cmd === 'list' || cmd === 'show'))
      if (unavailable) assert.deepEqual(python, [])
      assert.deepEqual(fixture.worker.logs, [
        `${toggleCommand} started`, `${toggleCommand} ended: success; opened panel (${reason}); keySource=detected; key=local.odd-flow-profiles`
      ])
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('truncates status fields to host limits and retains the start of both errors', async () => {
  const profile = 'profile-' + 'p'.repeat(80)
  const dispatchError = 'dispatch offline: ' + 'd'.repeat(300)
  const panelError = 'panel offline: ' + 'p'.repeat(300)
  let dispatchOffline = false
  const fixture = await controlsFixture(() => [agent('codex')], {
    settings: { pluginKey: 'local.odd-flow-profiles' },
    run: async () => ({ stdout: JSON.stringify({ ...show, profile }), stderr: '' }),
    runExecutable: async (_executable, argv) => {
      if (argv[0] !== 'orchestration') throw new Error(panelError)
      if (dispatchOffline) throw new Error(dispatchError)
      return dispatches()
    }
  })
  try {
    await fixture.tick()
    assert.equal(fixture.status()?.text, ('odd: ' + profile).slice(0, 63) + '…')
    assert.equal(fixture.status()?.tooltip, 'Profile source: file default\nMode source: default')

    dispatchOffline = true
    assert.deepEqual(await fixture.worker.command(openCommand), {
      error: 'Could not open the ODD Flow panel: ' + panelError
    })
    const status = fixture.status()
    assert.equal(status?.text, 'odd: worker check failed')
    assert.equal(status?.tooltip?.length, 256)
    const [dispatchLine, panelLine] = status?.tooltip?.split('\n') ?? []
    assert.match(dispatchLine, /^Could not check dispatched workers: dispatch offline: d+…$/u)
    assert.match(panelLine, /^Could not open the ODD Flow panel: panel offline: p+…$/u)
  } finally {
    await fixture.worker.deactivate()
  }
})

test('status refresh logs a bounded, single-line host reason without private values', async () => {
  const envValue = 'env-secret-sentinel'
  const sessionId = 'test-agent-session'
  let reason = 'host rejected\u0000\r\n\u0085\u2028\u2029 status: ' + 'x'.repeat(300)
  const fixture = await controlsFixture(() => [agent('codex', sessionId)], {
    env: { ...env, SAMPLE_SECRET: envValue },
    updateStatus: () => { throw hostError('unavailable', reason) }
  })
  try {
    await fixture.tick()
    assert.deepEqual(fixture.worker.logs, [
      'Could not update odd-flow status: ' + ('host rejected status: ' + 'x'.repeat(300)).slice(0, 255) + '…'
    ])
    reason = 'host rejected: ' + envValue
    await fixture.tick()
    reason = 'host rejected: ' + sessionId
    await fixture.tick()
    assert.deepEqual(fixture.worker.logs.slice(1), [
      'Could not update odd-flow status: [redacted]',
      'Could not update odd-flow status: [redacted]'
    ])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Open ODD Flow panel bounds the logged plugin key but sends it unchanged', async () => {
  const pluginKey = 'local.' + 'x'.repeat(300)
  const calls: (readonly string[])[] = []
  const fixture = await controlsFixture(() => [], {
    settings: { pluginKey },
    runExecutable: async (_executable, argv) => { calls.push(argv); return cliOk() }
  })
  try {
    assert.equal(await fixture.worker.command(openCommand), 'Opened the ODD Flow panel.')
    assert.deepEqual(calls, [openArgv(pluginKey)])
    assert.deepEqual(fixture.worker.logs, [
      `${openCommand} started`,
      `${openCommand} ended: success; keySource=setting; key=${pluginKey.slice(0, 127)}…`
    ])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Toggle mode logs the abort instead of a worker-check fallback', async () => {
  const controller = new AbortController()
  const key = 'custom.odd-flow-profiles'
  const fixture = await controlsFixture(() => [agent('codex')], {
    commandSignal: controller.signal, settings: { pluginKey: key }
  })
  try {
    controller.abort(new Error('cancelled'))
    assert.deepEqual(await fixture.worker.command(toggleCommand), {
      error: 'Could not open the ODD Flow panel: cancelled'
    })
    assert.deepEqual(fixture.worker.logs, [
      `${toggleCommand} started`,
      `${toggleCommand} ended: error (aborted); keySource=setting; key=${key}; Command signal was aborted.`
    ])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('a hostile pluginKey cannot forge log lines', async () => {
  for (const pluginKey of ['x.odd-flow-profiles\nodd-flow.openProfiles ended: success; key=forged',
    'x\rforged', 'x\u{2028}forged', 'x\u{1b}[1Aforged']) {
    const fixture = await controlsFixture(() => [agent('codex')], { settings: { pluginKey } })
    try {
      await fixture.worker.command(openCommand)
      assert.equal(fixture.worker.logs.length, 2)
      assert.ok(fixture.worker.logs[1].includes('key=[redacted]'))
      for (const line of fixture.worker.logs) assert.ok(!/[\p{Cc}\p{Zl}\p{Zp}]/u.test(line))
    } finally {
      await fixture.worker.deactivate()
    }
  }
})

test('Toggle mode logs the coordinator re-check fallback', async () => {
  let calls = 0
  const fixture = await controlsFixture(() => (++calls === 1 ? [agent('codex')] : [agent('codex'), agent('antigravity')]))
  try {
    assert.equal(await fixture.worker.command(toggleCommand), 'Opened the ODD Flow panel.')
    assert.deepEqual(fixture.worker.logs, [`${toggleCommand} started`,
      `${toggleCommand} ended: success; opened panel (coordinator re-check); keySource=detected; key=local.odd-flow-profiles`])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('Toggle mode logs a state read error without host text', async () => {
  const fixture = await controlsFixture(() => { throw new Error('agents host down') })
  try {
    assert.deepEqual(await fixture.worker.command(toggleCommand), { error: 'agents host down' })
    assert.deepEqual(fixture.worker.logs, [`${toggleCommand} started`, `${toggleCommand} ended: error; could not read workspace state`])
  } finally {
    await fixture.worker.deactivate()
  }
})

const runListArgv = ['orchestration', 'run-list', '--environment', 'local', '--json', '--full']
const taskSpecMarker = 'private-task-spec-not-for-the-panel'

async function dashboardFixture(
  root: string | null, { failGit = false, matchWorkspace = true, finished = false } = {}
) {
  const started = finished ? '2020-11-25T16:00:00Z' : '2026-11-25T16:00:00Z'
  const timestamp = Date.parse(started)
  const coordinator = { ...agent('codex'), state: 'blocked' as const, stateStartedAt: timestamp }
  const agents = [coordinator, agent('claude'), dispatched]
  const calls: string[][] = []
  const worker = await fixture({ profileScript: currentScript }, agents, {
    runExecutable: async (executable, argv, childEnv, _signal, timeout) => {
      calls.push([...argv])
      assert.deepEqual(childEnv, executable === 'git'
        ? { ODD_FLOW_HOME: '/keep', GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_COUNT: '1',
            GIT_CONFIG_KEY_0: 'core.fsmonitor', GIT_CONFIG_VALUE_0: 'false' } : { ODD_FLOW_HOME: '/keep' })
      const run = argv[argv.indexOf('--run') + 1]
      if (argv[1] === 'worker-list') {
        return cliOk({ workers: [{
          dispatchId: 'dispatch-1', taskId: 'task-1', state: finished ? 'succeeded' : 'ready', terminal: 'worker-terminal',
          agent: 'codex/gpt-6-luna', attention: ['input'], workspace: root && `workspace::${root}`,
          spec: taskSpecMarker
        }] })
      }
      assert.equal(timeout, 5000)
      if (argv[1] === 'run-list') {
        assert.deepEqual(argv, runListArgv)
        return cliOk({ runs: [
          { id: 'run-1', objective: 'Build dashboard', coordinator_handle: 'codex', created_at: started },
          { id: 'removed', objective: 'Deleted Run', coordinator_handle: 'codex', created_at: '2026-11-25T16:05:00Z' },
          { id: 'unrelated', objective: 'Other session', coordinator_handle: 'other', created_at: started }
        ] })
      }
      if (argv[1] === 'task-list') {
        assert.deepEqual(argv, ['orchestration', 'task-list', '--environment', 'local', '--run', run, '--json', '--full'])
        if (run === 'removed') {
          throw Object.assign(new Error('run unavailable'), {
            stdout: JSON.stringify({ ok: false, error: { code: 'run_not_found' } })
          })
        }
        assert.equal(run, 'run-1')
        return cliOk({ tasks: [{
          id: 'task-1', task_title: 'Gather data', status: finished ? 'completed' : 'dispatched', created_at: started,
          completed_at: finished ? started : null, created_by_terminal_handle: 'codex', run_id: 'run-1', result: null,
          spec: taskSpecMarker
        }] })
      }
      assert.equal(executable, 'git')
      assert.deepEqual(argv.slice(0, 2), ['-C', root])
      if (argv.includes('branch')) return { stdout: 'feature/dashboard\n', stderr: '' }
      if (failGit) throw new Error('git status failed')
      return { stdout: argv.includes('status') ? ' M changed\n' : 'abc123\x001764086400\n', stderr: '' }
    }
  }, {
    'agents.list': { agents },
    'workspace.readContext': {
      workspaceId: 'focus', branch: 'feature/dashboard', displayName: 'Dashboard',
      terminals: [{ id: 'codex' }, { id: 'claude' }]
    },
    'workspace.list': {
      workspaces: root && matchWorkspace ? [{
        id: 'focus', kind: 'worktree', name: 'Dashboard', path: root, branch: 'feature/dashboard', hostId: 'local'
      }] : [],
      truncated: false
    }
  })
  return { worker, calls, timestamp }
}

test('attaches a dashboard per coordinator', async (t) => {
  const root = await temp(t)
  const doc = await scriptAt(join(root, 'odd/tasks/dashboard.md'))
  await writeFile(doc, '# Dashboard\n\nBranch: `feature/dashboard`\n\n## Tasks\n| ID | Work | Status |\n| --- | --- | --- |\n| T2 | Gather sources | in_progress |\n')
  const { worker, calls, timestamp } = await dashboardFixture(root)
  try {
    const state = await worker.request('state')
    assert.deepEqual(Object.keys(state.dashboards ?? {}).sort(), ['claude', 'codex'])
    assert.equal(state.agents[0].stateStartedAt, timestamp)
    const dashboard = state.dashboards?.codex
    assert.equal(dashboard?.terminalId, 'codex')
    assert.equal(dashboard?.feature?.path, 'odd/tasks/dashboard.md')
    assert.deepEqual(dashboard?.feature?.tasks, [{ id: 'T2', work: 'Gather sources', status: 'in_progress' }])
    assert.equal(dashboard?.current, null)
    assert.equal(dashboard?.git?.changedFiles, 1)
    assert.equal(dashboard?.git?.lastCommit?.hash, 'abc123')
    assert.deepEqual(dashboard?.workers.map(({ title, agent, needsYou }) => [title, agent, needsYou]),
      [['Gather data', 'codex/gpt-6-luna', true]])
    assert.deepEqual(dashboard?.attention, [
      { label: 'This session is blocked', since: timestamp },
      { label: 'Gather data — codex/gpt-6-luna', since: timestamp }
    ])
    assert.deepEqual(dashboard?.errors, {})
    assert.deepEqual(state.dashboards?.claude.workers, [])
    assert.deepEqual(calls.filter((argv) => argv[1] === 'worker-list' && argv.includes('--run')), [
      [...workerListArgv.slice(0, 4), '--run', 'removed', '--json'],
      [...workerListArgv.slice(0, 4), '--run', 'run-1', '--json']
    ])
  } finally {
    await worker.deactivate()
  }
})

test('keeps other sections when one source fails', async (t) => {
  const { worker } = await dashboardFixture(await temp(t), { failGit: true, matchWorkspace: false })
  try {
    const { dashboards } = await worker.request('state')
    assert.ok(dashboards?.codex.errors.git)
    assert.equal(dashboards?.codex.errors.workspace, undefined)
    assert.equal(dashboards?.codex.git, null)
    assert.equal(dashboards?.codex.current?.objective, 'Build dashboard')
    assert.equal(dashboards?.codex.current?.tasks[0].title, 'Gather data')
    assert.equal(dashboards?.codex.workers[0].title, 'Gather data')
  } finally {
    await worker.deactivate()
  }
})

test('keeps the Git summary when only a hidden worker supplies the workspace path', async (t) => {
  const root = await temp(t)
  const { worker } = await dashboardFixture(root, { matchWorkspace: false, finished: true })
  try {
    const { dashboards } = await worker.request('state')
    assert.deepEqual(dashboards?.codex.workers, [])
    assert.equal(dashboards?.codex.current, null)
    assert.equal(dashboards?.codex.errors.workspace, undefined)
    assert.equal(dashboards?.codex.git?.lastCommit?.hash, 'abc123')
  } finally {
    await worker.deactivate()
  }
})

test('hides tasks and git when the workspace path is unknown', async () => {
  const { worker, calls } = await dashboardFixture(null)
  try {
    const { dashboards } = await worker.request('state')
    assert.ok(dashboards?.codex.errors.workspace)
    assert.equal(dashboards?.codex.feature, null)
    assert.equal(dashboards?.codex.current, null)
    assert.equal(dashboards?.codex.git, null)
    assert.equal(dashboards?.codex.workers[0].title, 'Gather data')
    assert.equal(calls.some((argv) => argv[0] === '-C'), false)
  } finally {
    await worker.deactivate()
  }
})

test('never sends task specs to the panel', async (t) => {
  const { worker } = await dashboardFixture(await temp(t))
  try {
    const state = await worker.request('state')
    assert.equal(state.dashboards?.codex.workers[0].title, 'Gather data')
    assert.equal(JSON.stringify(state).includes(taskSpecMarker), false)
    assert.equal(JSON.stringify(state).includes('"spec":'), false)
    assert.equal(worker.logs.some((line) => line.includes(taskSpecMarker)), false)
  } finally {
    await worker.deactivate()
  }
})

test('assigns a cited feature doc only to its owning session while keeping specs out of state', async (t) => {
  const root = await temp(t)
  const doc = await scriptAt(join(root, 'odd/tasks/dashboard.md'))
  await writeFile(doc, '# Dashboard\n\nBranch: `feature/dashboard`\n\n## Tasks\n| ID | Work | Status |\n| --- | --- | --- |\n| T1 | Build | in_progress |\n')
  const started = new Date().toISOString()
  const worker = await fixture({ profileScript: currentScript }, [agent('codex'), agent('claude')], {
    runExecutable: async (executable, argv) => {
      if (executable === 'git') {
        return { stdout: argv.includes('branch') ? 'feature/dashboard\n' : argv.includes('status') ? '' : 'abc123\x001764086400\n', stderr: '' }
      }
      if (argv[1] === 'worker-list' && !argv.includes('--run')) return cliOk({ workers: [] })
      if (argv[1] === 'run-list') {
        return cliOk({ runs: [
          { id: 'run-codex', objective: 'Codex work', coordinator_handle: 'codex', created_at: started },
          { id: 'run-claude', objective: 'Research work', coordinator_handle: 'claude', created_at: started }
        ] })
      }
      const run = argv[argv.indexOf('--run') + 1]
      if (argv[1] === 'task-list') {
        return cliOk({
          runId: run,
          tasks: run === 'run-codex'
            ? [{
                id: 'task-1', task_title: 'Implement', status: 'dispatched', created_at: started,
                completed_at: null, created_by_terminal_handle: 'codex', run_id: 'run-codex', result: null,
                spec: `Spec: odd/tasks/dashboard.md ${taskSpecMarker}`
              }]
            : [{
                id: 'task-2', task_title: 'Research', status: 'completed', created_at: started,
                completed_at: started, created_by_terminal_handle: 'claude', run_id: 'run-claude', result: null,
                spec: 'Investigate unrelated topic'
              }]
        })
      }
      return cliOk({ workers: [], scope: { run, source: 'flag' } })
    }
  }, {
    'agents.list': { agents: [agent('codex'), agent('claude')] },
    'workspace.readContext': {
      workspaceId: 'focus', branch: 'feature/dashboard', displayName: 'Dashboard',
      terminals: [{ id: 'codex' }, { id: 'claude' }]
    },
    'workspace.list': {
      workspaces: [{ id: 'focus', kind: 'worktree', name: 'Dashboard', path: root, branch: 'feature/dashboard', hostId: 'local' }],
      truncated: false
    }
  })
  try {
    const state = await worker.request('state')
    assert.equal(state.dashboards?.codex.feature?.path, 'odd/tasks/dashboard.md')
    assert.equal(state.dashboards?.claude.feature, null)
    assert.equal(state.dashboards?.claude.current?.objective, 'Research work')
    assert.equal(JSON.stringify(state).includes(taskSpecMarker), false)
    assert.equal(JSON.stringify(state).includes('"spec":'), false)
  } finally {
    await worker.deactivate()
  }
})

test('reloads dashboard workers across repeated state requests and cached older runs', async (t) => {
  const root = await temp(t)
  const started = new Date().toISOString()
  const runs = Array.from({ length: 10 }, (_, index) => ({
    id: `run_${index}`,
    objective: `Run ${index}`,
    coordinator_handle: 'codex',
    created_at: new Date(Date.parse(started) + index * 60_000).toISOString()
  }))
  let includeNewRun = false
  const worker = await fixture({ profileScript: currentScript }, [agent('codex')], {
    runExecutable: async (executable, argv) => {
      if (executable === 'git') {
        return { stdout: argv.includes('branch') ? 'feature/dashboard\n' : argv.includes('status') ? '' : 'abc123\x001764086400\n', stderr: '' }
      }
      if (argv[1] === 'worker-list' && !argv.includes('--run')) {
        return cliOk({ workers: [{ dispatchId: 'd_0', terminal: 't_0', state: 'succeeded', liveness: 'unverifiable' }], nextCursor: null })
      }
      if (argv[1] === 'run-list') {
        const all = includeNewRun
          ? [{ id: 'run_new', objective: 'Newest', coordinator_handle: 'codex', created_at: new Date(Date.parse(started) + 60 * 60_000).toISOString() }, ...runs]
          : runs
        return cliOk({ runs: all, nextCursor: null })
      }
      const run = argv[argv.indexOf('--run') + 1]
      if (argv[1] === 'task-list') {
        return cliOk({
          runId: run,
          tasks: [{
            id: `task_${run}`, parent_id: null, created_by_terminal_handle: 'codex',
            task_title: `Task ${run}`, display_name: `Task ${run}`, spec: taskSpecMarker,
            status: 'completed', created_at: started, completed_at: started, run_id: run, result: null
          }]
        })
      }
      return cliOk({
        workers: [{
          dispatchId: `ctx_${run}`, taskId: `task_${run}`, state: 'succeeded', liveness: 'unverifiable',
          terminal: 't_0', terminalState: 'retained', workspace: `ws::${root}`, host: 'local',
          attention: ['unverifiable']
        }],
        scope: { run, source: 'flag' }
      })
    }
  }, {
    'agents.list': { agents: [agent('codex')] },
    'workspace.readContext': { workspaceId: 'focus', branch: 'feature/dashboard', displayName: 'Dashboard', terminals: [{ id: 'codex' }] },
    'workspace.list': {
      workspaces: [{ id: 'focus', kind: 'worktree', name: 'Dashboard', path: root, branch: 'feature/dashboard', hostId: 'local' }],
      truncated: false
    }
  })
  try {
    const first = await worker.request('state')
    assert.deepEqual(first.dashboards?.codex.errors, {})
    assert.equal(first.dashboards?.codex.workers.length, 10)

    includeNewRun = true
    const second = await worker.request('state')
    assert.deepEqual(second.dashboards?.codex.errors, {})
    assert.equal(second.dashboards?.codex.workers.length, 11)
  } finally {
    await worker.deactivate()
  }
})

test('names the failing command and reason in dashboard workers error without private values', async (t) => {
  const root = await temp(t)
  const started = '2026-11-25T16:00:00Z'
  const sessionUuid = '12345678-1234-1234-1234-1234567890ab'
  const worker = await fixture({ profileScript: currentScript }, [agent('codex')], {
    runExecutable: async (executable, argv) => {
      if (executable === 'git') {
        return { stdout: argv.includes('branch') ? 'feature/dashboard\n' : argv.includes('status') ? '' : 'abc123\x001764086400\n', stderr: '' }
      }
      if (argv[1] === 'worker-list' && !argv.includes('--run')) {
        return cliOk({ workers: [] })
      }
      if (argv[1] === 'run-list') {
        return cliOk({ runs: [{ id: 'run_1', objective: 'Build', coordinator_handle: 'codex', created_at: started }] })
      }
      if (argv[1] === 'task-list') {
        throw Object.assign(new Error('ignored'), {
          stderr: `boom on task_deadbeef\nfor session ${sessionUuid} ` + 'x'.repeat(200)
        })
      }
      return cliOk({ workers: [], scope: { run: 'run_1', source: 'flag' } })
    }
  }, {
    'agents.list': { agents: [agent('codex')] },
    'workspace.readContext': { workspaceId: 'focus', branch: 'feature/dashboard', displayName: 'Dashboard', terminals: [{ id: 'codex' }] },
    'workspace.list': {
      workspaces: [{ id: 'focus', kind: 'worktree', name: 'Dashboard', path: root, branch: 'feature/dashboard', hostId: 'local' }],
      truncated: false
    }
  })
  try {
    const { dashboards } = await worker.request('state')
    const err = dashboards?.codex.errors.workers ?? ''
    assert.match(err, /^Could not load all Orca work for this session: task-list: boom on/)
    assert.equal(/[\r\n]/.test(err), false)
    assert.equal(err.includes('task_deadbeef'), false)
    assert.equal(err.includes(sessionUuid), false)
    assert.ok(err.length <= 220)
  } finally {
    await worker.deactivate()
  }
})

const sessionSighting = Date.parse('2026-11-26T16:00:00Z')
const sessionWorkTime = (seconds: number) => new Date(sessionSighting + seconds * 1000).toISOString()

async function sessionDashboardFixture(
  t: TestContext,
  runSeconds: number,
  tasks: { id: string; seconds: number; spec?: string }[] = []
) {
  const root = await temp(t)
  let now = sessionSighting - 10_000
  let sessionId: string | null = 'session-a'
  let refresh: (() => Promise<void>) | undefined
  t.mock.method(Date, 'now', () => now)
  const worker = await fixture({ profileScript: currentScript }, [], {
    scheduleRefresh: (callback) => {
      refresh = callback
      return () => {}
    },
    runExecutable: async (executable, argv) => {
      if (executable === 'git') {
        return { stdout: argv.includes('branch') ? 'main\n' : argv.includes('status') ? '' : 'abc123\x001764086400\n', stderr: '' }
      }
      if (argv[1] === 'run-list') return cliOk({ runs: [
        { id: 'run', objective: 'Dashboard work', coordinator_handle: 'codex', created_at: sessionWorkTime(runSeconds) }
      ] })
      if (argv[1] === 'task-list') return cliOk({ tasks: tasks.map(({ id, seconds, spec }) => ({
        id, task_title: id, status: 'dispatched', created_at: sessionWorkTime(seconds), completed_at: null,
        created_by_terminal_handle: 'codex', run_id: 'run', result: null, spec
      })) })
      return cliOk({ workers: argv.includes('--run') ? tasks.map(({ id }) => ({
        dispatchId: id, taskId: id, state: 'running'
      })) : [] })
    }
  }, {
    'agents.list': () => ({ agents: [agent('codex', sessionId)] }),
    'workspace.readContext': { workspaceId: 'focus', branch: 'main', displayName: 'Dashboard', terminals: [{ id: 'codex' }] },
    'workspace.list': {
      workspaces: [{ id: 'focus', kind: 'worktree', name: 'Dashboard', path: root, branch: 'main', hostId: 'local' }],
      truncated: false
    }
  })
  t.after(() => worker.deactivate())
  return {
    root,
    dashboard: async () => (await worker.request('state')).dashboards?.codex,
    switchSession: async () => {
      await worker.request('state')
      now = sessionSighting + 500
      await refresh?.()
      now += 10_000
      sessionId = ''
      await refresh?.()
      sessionId = null
      await refresh?.()
      now += 10_000
      sessionId = 'session-b'
    }
  }
}

test('hides a run created before the old session was last seen by a status refresh', async (t) => {
  const session = await sessionDashboardFixture(t, -1)
  await session.switchSession()
  assert.equal((await session.dashboard())?.current, null)
})

test('keeps a run created in the same second as the last sighting', async (t) => {
  const session = await sessionDashboardFixture(t, 0)
  await session.switchSession()
  assert.equal((await session.dashboard())?.current?.objective, 'Dashboard work')
})

test('scopes worker dispatches by task creation, keeping work started before the switch was noticed', async (t) => {
  const session = await sessionDashboardFixture(t, -2, [
    { id: 'previous', seconds: -1 }, { id: 'same-second', seconds: 0 }, { id: 'not-yet-seen', seconds: 1 }
  ])
  await session.switchSession()
  assert.deepEqual((await session.dashboard())?.workers.map(({ dispatchId }) => dispatchId), ['not-yet-seen', 'same-second'])
})

test('excludes previous-session task citations from feature ownership', async (t) => {
  const path = 'odd/tasks/previous.md'
  const session = await sessionDashboardFixture(t, 0, [{ id: 'previous', seconds: -1, spec: path }])
  const doc = await scriptAt(join(session.root, path))
  await writeFile(doc, '# Dashboard\n\nBranch: `feature/previous`\n\n## Tasks\n| ID | Work | Status |\n| --- | --- | --- |\n| 1 | Gather sources | in_progress |\n')
  assert.equal((await session.dashboard())?.feature?.path, path)
  await session.switchSession()
  assert.equal((await session.dashboard())?.feature, null)
})

test('sets no session boundary on first sight of a terminal', async (t) => {
  const session = await sessionDashboardFixture(t, -20, [{ id: 'existing', seconds: -20 }])
  const dashboard = await session.dashboard()
  assert.equal(dashboard?.current?.objective, 'Dashboard work')
  assert.deepEqual(dashboard?.workers.map(({ dispatchId }) => dispatchId), ['existing'])
})

test('status refresh runs no task-list, run-list or git', async () => {
  const calls: [string, ...string[]][] = []
  const fixture = await controlsFixture(() => [agent('codex')], {
    runExecutable: async (executable, argv) => {
      calls.push([executable, ...argv])
      return dispatches()
    }
  })
  try {
    await fixture.tick()
    assert.deepEqual(calls, [[fakeOrca, ...workerListArgv]])
    assert.equal(fixture.status()?.text, 'odd: test · organic')
  } finally {
    await fixture.worker.deactivate()
  }
})

test('shows needs you when a coordinator in the focused workspace is blocked', async () => {
  const fixture = await controlsFixture(() => [agent('codex'), { ...agent('claude'), state: 'blocked' }])
  try {
    await fixture.tick()
    assert.equal(fixture.status()?.text, 'odd: ⚠ needs you')
    assert.equal(fixture.status()?.tone, 'warning')
    assert.match(fixture.status()?.tooltip ?? '', /This session is blocked/)
  } finally {
    await fixture.worker.deactivate()
  }
})

test('alerts for a blocked worker terminal in the focused workspace', async () => {
  const timestamp = Date.now() - 120_000
  const worker = { ...dispatched, state: 'blocked' as const, stateStartedAt: timestamp }
  const fixture = await controlsFixture(() => [agent('codex'), worker], {
    runExecutable: async () => cliOk({ workers: [
      { dispatchId: 'settled', terminal: worker.terminalId, state: 'succeeded', agent: 'claude/settled' },
      { dispatchId: 'newest-active', terminal: worker.terminalId, state: 'ready', agent: 'claude/newest' },
      { dispatchId: 'older-active', terminal: worker.terminalId, state: 'ready', agent: 'claude/older' }
    ] })
  })
  try {
    await fixture.tick()
    assert.equal(fixture.status()?.text, 'odd: ⚠ needs you')
    assert.equal(fixture.status()?.tooltip, `${task.title} — claude/newest, blocked 2m`)
  } finally {
    await fixture.worker.deactivate()
  }
})

test('alerts for pending worker attention until the existing scan reports it resolved', async () => {
  const workers = [agent('input'), agent('escalation')]
  const cursors: (string | undefined)[] = []
  let complete = false
  const fixture = await controlsFixture(() => [agent('codex'), ...workers], {
    runExecutable: async (_executable, argv) => {
      cursors.push(argv[6])
      return argv[6] ? cliOk({ workers: workers.map(({ terminalId }, index) => ({
        dispatchId: terminalId, terminal: terminalId, state: complete ? 'succeeded' : 'ready', agent: 'claude',
        attention: [index === 0 ? 'input' : 'escalation']
      })) }) : dispatchResult([{ dispatchId: 'newest' }], 'older')
    }
  })
  try {
    await fixture.tick()
    assert.equal(fixture.status()?.text, 'odd: ⚠ needs you')
    assert.equal(fixture.status()?.tooltip, 'input — claude\nescalation — claude')
    complete = true
    await fixture.tick()
    assert.deepEqual(cursors, [undefined, 'older', undefined, 'older'])
    assert.equal(fixture.status()?.text, 'odd: test · organic')
  } finally {
    await fixture.worker.deactivate()
  }
})

test("keeps today's status when nothing needs the user", async () => {
  const fixture = await controlsFixture(() => [agent('codex'), dispatched], {
    runExecutable: async () => cliOk({ workers: [
      { dispatchId: 'other-workspace', terminal: 'elsewhere', state: 'ready', attention: ['input'] },
      { dispatchId: 'active', terminal: dispatched.terminalId, state: 'ready',
        attention: ['unverifiable', 'root_completion'] },
      ...['succeeded', 'failed', 'cancelled', 'lost'].map((state) => ({
        dispatchId: state, terminal: dispatched.terminalId, state, attention: ['input']
      }))
    ] })
  })
  try {
    await fixture.tick()
    assert.deepEqual(fixture.status(), {
      id: 'odd-flow-status', visible: true, text: 'odd: test · organic', tone: 'neutral',
      tooltip: 'Profile source: file default\nMode source: default'
    })
  } finally {
    await fixture.worker.deactivate()
  }
})

test('bounds the attention tooltip in UTF-16 without splitting a surrogate pair', async () => {
  const workers = Array.from({ length: 25 }, (_, index) => ({
    ...agent(`worker-${index}`), title: '😀'.repeat(20), state: 'blocked' as const
  }))
  const fixture = await controlsFixture(() => [agent('codex'), ...workers], {
    runExecutable: async () => cliOk({ workers: workers.map(({ terminalId }) => ({
      dispatchId: terminalId, terminal: terminalId, state: 'ready', agent: 'claude'
    })) })
  })
  try {
    await fixture.tick()
    const status = fixture.status()
    assert.equal(status?.text, 'odd: ⚠ needs you')
    const tooltip = status?.tooltip ?? ''
    assert.ok(tooltip.length <= 256 && tooltip.endsWith('…'))
    assert.ok(!/[\uD800-\uDFFF]/u.test(tooltip))
  } finally {
    await fixture.worker.deactivate()
  }
})

test('status refresh reads one page once settled dispatches are known', async () => {
  const calls: string[][] = []
  const fixture = await controlsFixture(() => [agent('codex')], { runExecutable: async (_e, argv) => {
    calls.push([...argv])
    return argv.includes('--cursor') ? cliOk({ workers: [{ dispatchId: 'old', terminal: 'x', state: 'stopped' }] })
      : cliOk({ workers: [{ dispatchId: 'new', terminal: 'y', state: 'succeeded' }], nextCursor: 'c1' })
  } })
  try {
    await fixture.tick()
    assert.deepEqual(calls.splice(0), [workerListArgv, [...workerListArgv, '--cursor', 'c1']])
    await fixture.tick()
    assert.deepEqual(calls, [workerListArgv])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('keeps the scan open only until older active dispatches settle', async () => {
  let state = 'ready'
  const calls: string[][] = []
  const fixture = await controlsFixture(() => [agent('codex'), { ...dispatched, state: 'blocked' }], {
    runExecutable: async (_executable, argv) => {
      calls.push([...argv])
      return argv.includes('--cursor') ? cliOk({ workers: [{
        dispatchId: 'old', terminal: dispatched.terminalId, state, attention: ['input']
      }] }) : cliOk({ workers: [{ dispatchId: 'new', state: 'succeeded' }], nextCursor: 'older' })
    }
  })
  try {
    await fixture.tick()
    assert.deepEqual(calls.splice(0), [workerListArgv, [...workerListArgv, '--cursor', 'older']])
    assert.equal(fixture.status()?.text, 'odd: ⚠ needs you')
    state = 'abandoned'
    await fixture.tick()
    assert.deepEqual(calls.splice(0), [workerListArgv, [...workerListArgv, '--cursor', 'older']])
    assert.equal(fixture.status()?.text, 'odd: test · organic')
    await fixture.tick()
    assert.deepEqual(calls, [workerListArgv])
  } finally {
    await fixture.worker.deactivate()
  }
})

test('keeps script and panel warnings in the needs-you tooltip', async () => {
  const fixture = await controlsFixture(() => [{ ...agent('codex'), state: 'blocked' }], {
    settings: { profileScript: 'not-absolute' },
    runExecutable: async (_executable, argv) =>
      argv[0] === 'orchestration' ? dispatches() : cliOk({ plugins: [] })
  })
  try {
    await fixture.tick()
    assert.equal(fixture.status()?.text, 'odd: ⚠ needs you')
    assert.match(fixture.status()?.tooltip ?? '', /^This session is blocked\n[^\n]*profileScript/)
    assert.ok(typeof await fixture.worker.command(openCommand) === 'object')
    assert.equal(fixture.status()?.text, 'odd: ⚠ needs you')
    assert.match(fixture.status()?.tooltip ?? '', /^This session is blocked\n[^\n]*profileScript[^\n]*\nCould not open the ODD Flow panel:/)
  } finally {
    await fixture.worker.deactivate()
  }
})
