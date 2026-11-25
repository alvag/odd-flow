import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { assert, mockHost, mountWorker } from 'orca/testing'
import * as main from './worker'
import type { Agent } from './protocol'

const keys = {
  CLAUDE_CODE_SESSION_ID: 'parent-claude',
  CODEX_THREAD_ID: 'parent-codex',
  CODEX_SESSION_ID: 'parent-codex-legacy',
  ANTIGRAVITY_CONVERSATION_ID: 'parent-antigravity',
  ORCA_PANE_KEY: 'parent-orca'
}
const env = { ...keys, ODD_FLOW_HOME: '/keep' }
const list = { path: null, default: null, profiles: [] }
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

async function fixture(
  settings: Record<string, string>,
  agents: ReturnType<typeof agent>[],
  options: Partial<import('./worker').WorkerOptions> = {}
) {
  const host = mockHost({
    capabilities: ['agent:read', 'settings:own'],
    settings,
    results: { 'agents.list': { agents } }
  })
  return mountWorker({ default: main.createWorker({ env, run: fakeRun, ...options }) }, { host })
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
  const script = fileURLToPath(new URL('../../skills/odd-flow/scripts/profile.py', import.meta.url))
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
  const script = fileURLToPath(new URL('../../skills/odd-flow/scripts/profile.py', import.meta.url))
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

test('keeps nonzero-exit and malformed-JSON failures in their own rows and retains stderr', async () => {
  const script = fileURLToPath(new URL('../../skills/odd-flow/scripts/profile.py', import.meta.url))
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

test('reads the real profile.py Show JSON against isolated profile and session data', async (t) => {
  const home = await temp(t)
  const script = fileURLToPath(new URL('../../skills/odd-flow/scripts/profile.py', import.meta.url))
  await writeFile(join(home, 'profiles.json'), JSON.stringify({
    default: 'fallback',
    profiles: { fallback: {}, bound: {} },
    workflow: { bound: { orchestratorMode: 'full-delegation' } }
  }))
  await mkdir(join(home, 'sessions'))
  await writeFile(join(home, 'sessions/codex.json'), JSON.stringify({ profile: 'bound' }))
  const worker = await fixture({ profileScript: script }, [agent('codex')], {
    env: { ...keys, PATH: process.env.PATH, ODD_FLOW_HOME: home }, run: main.runPython
  })
  const { profiles, agents } = await worker.request('state')
  assert.ok(profiles && typeof profiles === 'object')
  assert.equal(profiles.default, 'fallback')
  const { odd } = agents[0]
  assert.ok(odd && typeof odd === 'object')
  assert.deepEqual([odd.profile, odd.source, odd.mode, odd.mode_source, odd.session_key, odd.agent],
    ['bound', 'session (CODEX_THREAD_ID)', 'full-delegation', 'profile bound', 'CODEX_THREAD_ID', 'codex'])
  await worker.deactivate()
})
