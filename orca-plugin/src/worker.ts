import { execFile } from 'node:child_process'
import { constants } from 'node:fs'
import { access } from 'node:fs/promises'
import { homedir } from 'node:os'
import { delimiter, isAbsolute, resolve } from 'node:path'
import type { OrcaWorkerApi } from 'orca/worker'
import { isAgentKind, isMode, type Agent, type AgentRow, type OddState, type ProfileList,
  type Script, type SessionTarget, type State } from './protocol'
import { isFile, resolveScript } from './script'

const SESSION_VARIABLE = {
  claude: 'CLAUDE_CODE_SESSION_ID',
  codex: 'CODEX_THREAD_ID',
  antigravity: 'ANTIGRAVITY_CONVERSATION_ID'
} as const

// Clear all of profile.py's SESSION_VARS and any inherited profile, mode or agent hints.
const SESSION_KEYS = [
  ...Object.values(SESSION_VARIABLE), 'CODEX_SESSION_ID', 'ORCA_PANE_KEY',
  'ODD_PROFILE', 'ODD_ORCHESTRATOR_MODE', 'ODD_FLOW_AGENT', 'ORCA_TERMINAL_HANDLE'
]
const TIMEOUT_MS = 5000
const DISPATCH_SCAN_TIMEOUT_MS = 60_000
const BUNDLED_ORCA = '/Applications/Orca.app/Contents/Resources/bin/orca'
const WORKER_LIST = ['orchestration', 'worker-list', '--environment', 'local', '--json']
type Env = Record<string, string | undefined>
type Mutation = 'use' | 'session-mode' | 'clear'

export type Runner = (
  argv: readonly string[], env: Env, signal?: AbortSignal
) => Promise<{ stdout: string; stderr: string }>

type ExecutableRunner = (
  executable: string, argv: readonly string[], env: Env, signal?: AbortSignal, timeout?: number
) => ReturnType<Runner>

export type WorkerOptions = {
  run: Runner
  runExecutable: ExecutableRunner
  resolveOrca: (env: Env) => Promise<string | undefined>
  env: Env
  home: string
}

const exec: ExecutableRunner = (executable, argv, env, signal, timeout = TIMEOUT_MS) => new Promise((resolve, reject) => {
  execFile(executable, [...argv], {
    env, signal, timeout, killSignal: 'SIGKILL', encoding: 'utf8', windowsHide: true, shell: false
  }, (error, stdout, stderr) => {
    if (error?.killed && error.signal === 'SIGKILL' && error.code == null && !signal?.aborted) {
      const program = executable === 'python3' ? 'Python' : 'Orca CLI'
      reject(new Error(`${program} timed out after ${TIMEOUT_MS / 1000} seconds.`))
    } else if (error) reject(Object.assign(error, { stderr }))
    else resolve({ stdout, stderr })
  })
})

export const runPython: Runner = (argv, env, signal) => exec('python3', argv, env, signal)

export async function resolveOrcaExecutable(env: Env, bundled = BUNDLED_ORCA): Promise<string | undefined> {
  const configured = env.ORCA_CLI_COMMAND
  if (configured && isAbsolute(configured) && await isFile(configured)) return configured
  const name = process.platform === 'win32' ? 'orca.exe' : 'orca'
  for (const directory of (env.PATH ?? env.Path)?.split(delimiter) ?? []) {
    const candidate = resolve(directory, name)
    if (await isFile(candidate) && await access(candidate, constants.X_OK).then(() => true, () => false)) {
      return candidate
    }
  }
  if (await isFile(bundled)) return bundled
}

function message(error: unknown): string {
  if (error && typeof error === 'object' && 'stderr' in error &&
      typeof error.stderr === 'string' && error.stderr.trim()) return error.stderr.trim()
  return error instanceof Error ? error.message : String(error)
}

function dispatchPage(stdout: string): {
  workers: { dispatchId: string; terminal?: string | null }[]
  nextCursor?: string | null
} {
  let parsed
  try {
    parsed = JSON.parse(stdout)
  } catch {
    throw new Error('Orca CLI returned invalid JSON.')
  }
  if (parsed?.ok === false) throw new Error('Orca CLI reported failure.')
  const result = parsed?.result
  // A concise dispatch record can omit terminal when it never had one.
  if (parsed?.ok !== true || !Array.isArray(result?.workers) ||
      result.workers.some((row: { terminal?: unknown; dispatchId?: unknown } | null) => {
        if (typeof row?.dispatchId !== 'string' || !row.dispatchId.trim()) return true
        return row.terminal != null && (typeof row.terminal !== 'string' || !row.terminal.trim())
      }) ||
      (result.nextCursor != null && (typeof result.nextCursor !== 'string' || !result.nextCursor.trim()))) {
    throw new Error('Orca CLI returned an invalid dispatch list.')
  }
  if (result.scope?.source === 'bound') throw new Error('Orca CLI returned a Run-scoped dispatch list.')
  return result
}

function isWorker(row: Pick<Agent, 'task' | 'terminalId'>, terminals?: ReadonlySet<string>): boolean {
  return row.task != null || (row.terminalId != null && terminals?.has(row.terminalId) === true)
}

async function readJson<T>(
  run: Runner, path: string, command: 'list' | 'show', env: Env, signal: AbortSignal
): Promise<T | string> {
  try {
    const { stdout, stderr } = await run(['-I', path, command, '--json'], env, signal)
    try {
      const parsed = JSON.parse(stdout)
      if (command === 'list'
        ? !Array.isArray(parsed?.profiles) || parsed.profiles.some(
            (item: { name?: unknown } | null) => typeof item?.name !== 'string')
        : typeof parsed?.mode !== 'string') {
        throw new Error('Unexpected profile.py response')
      }
      return parsed as T
    } catch {
      const detail = stderr.trim()
      return `profile.py ${command} returned invalid JSON output.${detail ? ` ${detail}` : ''}`
    }
  } catch (error) {
    return `profile.py ${command} failed: ${message(error)}`
  }
}

function sessionEnv(env: Env, { agent, sessionId }: SessionTarget): Env {
  return { ...env, [SESSION_VARIABLE[agent]]: sessionId }
}

async function agentRow(
  row: Agent, dispatches: ReadonlySet<string> | string, script: Script, env: Env, run: Runner, signal: AbortSignal
): Promise<AgentRow> {
  if (isWorker(row, typeof dispatches === 'string' ? undefined : dispatches)) {
    return { ...row, isWorker: true, odd: null, reason: 'Dispatched worker.' }
  }
  if (typeof dispatches === 'string') return { ...row, odd: null, reason: 'Worker check unavailable.' }
  const kind = row.agent
  if (!isAgentKind(kind)) {
    return { ...row, odd: null, reason: 'Unsupported agent kind.' }
  }
  if (!row.sessionId?.trim()) return { ...row, odd: null, reason: 'No session ID reported.' }
  if ('error' in script) return { ...row, odd: script.error }
  const odd = await readJson<OddState>(run, script.path, 'show',
    sessionEnv(env, { agent: kind, sessionId: row.sessionId }), signal)
  return { ...row, odd }
}

export function createWorker({
  run = runPython, runExecutable = exec, resolveOrca = resolveOrcaExecutable, env = process.env, home = homedir()
}: Partial<WorkerOptions> = {}) {
  return (orca: OrcaWorkerApi): void => {
    function isolatedEnv(): Env {
      const cleanEnv = { ...env }
      for (const key of SESSION_KEYS) delete cleanEnv[key]
      return cleanEnv
    }

    const getAgents = (signal: AbortSignal) => orca.host.call('agents.list', undefined, { signal })
    const getScript = async () => resolveScript(home, await orca.settings.get('profileScript'))
    const cachedDispatchIds = new Set<string>()
    const cachedTerminals = new Set<string>()

    async function getDispatches(signal: AbortSignal): Promise<ReadonlySet<string> | string> {
      try {
        const incremental = cachedDispatchIds.size > 0
        const deadline = performance.now() + DISPATCH_SCAN_TIMEOUT_MS
        function remainingBudget() {
          signal.throwIfAborted()
          const remaining = Math.floor(deadline - performance.now())
          if (remaining <= 0) throw new Error('Orca CLI dispatch scan timed out after 60 seconds.')
          return remaining
        }
        // Do not let the calling pane bind the CLI's list to a single Run.
        const cliEnv = isolatedEnv()
        const executable = await resolveOrca(cliEnv)
        if (!executable) throw new Error('Orca executable not found.')
        // Publish only complete scans. A failed page must not advance the next scan's cutoff.
        const dispatchIds = new Set<string>()
        const terminals = new Set<string>()
        const seenCursors = new Set<string>()
        let cursor: string | null | undefined
        let reachedKnownPage = false
        do {
          const timeout = Math.min(TIMEOUT_MS, remainingBudget())
          const argv = cursor ? [...WORKER_LIST, '--cursor', cursor] : WORKER_LIST
          const { stdout } = await runExecutable(executable, argv, cliEnv, signal, timeout)
          const page = dispatchPage(stdout)
          for (const { dispatchId, terminal } of page.workers) {
            if (incremental && cachedDispatchIds.has(dispatchId)) reachedKnownPage = true
            dispatchIds.add(dispatchId)
            if (terminal != null) terminals.add(terminal)
          }
          cursor = page.nextCursor
          if (cursor) {
            if (seenCursors.has(cursor)) throw new Error('Orca CLI repeated a dispatch cursor.')
            seenCursors.add(cursor)
          }
        } while (cursor && !reachedKnownPage)
        remainingBudget()
        for (const id of dispatchIds) cachedDispatchIds.add(id)
        for (const terminal of terminals) cachedTerminals.add(terminal)
        return cachedTerminals
      } catch (error) {
        return `Could not check dispatched workers: ${message(error)}`
      }
    }

    async function state(signal: AbortSignal): Promise<State> {
      try {
        const [listed, script] = await Promise.all([getAgents(signal), getScript()])
        const cleanEnv = isolatedEnv()
        const dispatches = await getDispatches(signal)
        const workerCheckError = typeof dispatches === 'string' ? dispatches : undefined
        const [profiles, agents] = await Promise.all([
          !workerCheckError && 'path' in script ? readJson<ProfileList>(run, script.path, 'list', cleanEnv, signal) : null,
          Promise.all(listed.agents.map(({ terminalId, title, agent, state, sessionId, task }) =>
            agentRow({
              terminalId, title, agent, state, sessionId: sessionId ?? null,
              ...(task != null ? { task: { title: task.title } } : {})
            }, dispatches, script, cleanEnv, run, signal)
          ))
        ])
        return { script, profiles, agents, ...(workerCheckError ? { workerCheckError } : {}) }
      } catch (cause) {
        const error = message(cause)
        return { script: { error }, profiles: null, agents: [], error }
      }
    }

    async function mutate(command: Mutation, input: unknown, signal: AbortSignal) {
      if (!input || typeof input !== 'object') return { error: 'Invalid session request.' }
      const { agent, sessionId, profile, mode } = input as Record<string, unknown>
      if (!isAgentKind(agent)) return { error: 'Unsupported agent kind.' }
      if (typeof sessionId !== 'string' || !sessionId.trim()) {
        return { error: 'A session ID is required.' }
      }
      const args: string[] = []
      if (command === 'session-mode') {
        if (!isMode(mode)) return { error: 'Mode must be organic or full-delegation.' }
        args.push(mode)
      } else if (command === 'use') {
        if (typeof profile !== 'string' || !profile.trim()) return { error: 'A profile name is required.' }
        args.push('--', profile)
      }

      async function targetError() {
        const { agents } = await getAgents(signal)
        const matches = agents.filter((row) => row.agent === agent && row.sessionId === sessionId)
        if (!matches.length) return { error: 'This agent session is not reported in the focused workspace.' }
        const dispatches = await getDispatches(signal)
        if (typeof dispatches === 'string') return { error: dispatches, workerCheckUnavailable: true as const }
        if (matches.some((row) => isWorker(row, dispatches))) {
          return { error: 'Dispatched worker sessions cannot be changed.' }
        }
      }
      try {
        const error = await targetError()
        if (error) return error
        const script = await getScript()
        if ('error' in script) return script
        const cleanEnv = isolatedEnv()
        if (command === 'use') {
          const profiles = await readJson<ProfileList>(run, script.path, 'list', cleanEnv, signal)
          if (typeof profiles === 'string') return { error: profiles }
          if (!profiles.profiles.some(({ name }) => name === profile)) {
            return { error: `Unknown profile: ${profile}.` }
          }
          // A workspace or session can change while Python reads the profile list.
          const error = await targetError()
          if (error) return error
        }
        await run(['-I', script.path, command, ...args], sessionEnv(cleanEnv, { agent, sessionId }), signal)
        return { state: await state(signal) }
      } catch (cause) {
        return { error: `Could not run ${command}: ${message(cause)}` }
      }
    }

    orca.panels.handle('state', (_input, { signal }) => state(signal))
    orca.panels.handle('use', (input, { signal }) => mutate('use', input, signal))
    orca.panels.handle('sessionMode', (input, { signal }) => mutate('session-mode', input, signal))
    orca.panels.handle('clear', (input, { signal }) => mutate('clear', input, signal))
  }
}

export default createWorker()
