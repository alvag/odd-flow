import { execFile } from 'node:child_process'
import { constants } from 'node:fs'
import { access } from 'node:fs/promises'
import { homedir } from 'node:os'
import { delimiter, isAbsolute, resolve } from 'node:path'
import type { HostMethods } from 'orca/host'
import type { OrcaWorkerApi } from 'orca/worker'
import { isAgentKind, isMode, type Agent, type AgentRow, type OddState, type ProfileList,
  type MutationResult, type Script, type SessionTarget, type State } from './protocol'
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
const PANEL_ID = 'odd-flow-profiles'
const STATUS_ID = 'odd-flow-status'
const STATUS_REFRESH_MS = 15_000
type Env = Record<string, string | undefined>
type Mutation = 'use' | 'session-mode' | 'clear'
type Status = Omit<HostMethods['statusBar.update']['params'], 'id'>
type MutationOutcome = MutationResult | { openPanel: true }

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
  scheduleRefresh: (refresh: () => Promise<void>) => () => void
}

const scheduleStatusRefresh: WorkerOptions['scheduleRefresh'] = (refresh) => {
  void refresh()
  const timer = setInterval(() => { void refresh() }, STATUS_REFRESH_MS)
  timer.unref()
  return () => clearInterval(timer)
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

function hasSession<T extends Pick<Agent, 'agent'> & Partial<Pick<Agent, 'sessionId'>>>(row: T): row is T & SessionTarget {
  return isAgentKind(row.agent) && !!row.sessionId?.trim()
}

function coordinators({ agents }: State) {
  return agents.filter((row): row is AgentRow & SessionTarget => !row.isWorker && hasSession(row))
}

function readableShow(odd: AgentRow['odd']): OddState | { error: string } {
  if (typeof odd === 'string') return { error: odd }
  if (!odd || !isMode(odd.mode) || (odd.profile !== null && typeof odd.profile !== 'string') ||
      typeof odd.source !== 'string' || typeof odd.mode_source !== 'string') {
    return { error: 'profile.py show did not return a readable profile and mode.' }
  }
  return odd
}

function statusFor(snapshot: State, panelOpenError?: string): Status {
  const warning = (text: string, tooltip: string, tone: 'warning' | 'danger' = 'warning'): Status =>
    ({ visible: true, text, tooltip, tone })
  if (snapshot.workerCheckError) {
    const detail = [snapshot.workerCheckError, panelOpenError].filter(Boolean).join('\n')
    return warning('odd: worker check failed', detail, 'danger')
  }
  if (snapshot.error) return warning('odd: status unavailable', snapshot.error, 'danger')
  const rows = coordinators(snapshot)
  if (!rows.length) return { visible: false, tone: 'neutral', text: '', tooltip: '' }
  if ('error' in snapshot.script) return warning('odd: script unavailable', snapshot.script.error)
  if (panelOpenError) return warning('odd: panel unavailable', panelOpenError)
  if (rows.length > 1) {
    return { visible: true, tone: 'neutral', text: `odd: ${rows.length} sessions`, tooltip: 'Open the odd-flow profiles panel' }
  }
  const odd = readableShow(rows[0].odd)
  if ('error' in odd) return warning('odd: show failed', odd.error)
  return {
    visible: true, tone: 'neutral', text: `odd: ${odd.profile ?? '(no profile)'} · ${odd.mode}`,
    tooltip: `Profile source: ${odd.source}\nMode source: ${odd.mode_source}`
  }
}

function pluginResult(stdout: string): { plugins?: unknown } {
  let parsed
  try {
    parsed = JSON.parse(stdout)
  } catch {
    throw new Error('Orca CLI returned invalid JSON.')
  }
  if (parsed?.ok !== true) {
    throw new Error(typeof parsed?.error?.message === 'string' ? parsed.error.message : 'Orca CLI reported failure.')
  }
  return parsed.result ?? {}
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
  run = runPython, runExecutable = exec, resolveOrca = resolveOrcaExecutable, env = process.env, home = homedir(),
  scheduleRefresh = scheduleStatusRefresh
}: Partial<WorkerOptions> = {}) {
  return (orca: OrcaWorkerApi): (() => void) => {
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

    async function state(signal: AbortSignal, includeProfiles = true): Promise<State> {
      try {
        const [listed, script] = await Promise.all([getAgents(signal), getScript()])
        const cleanEnv = isolatedEnv()
        const dispatches = await getDispatches(signal)
        const workerCheckError = typeof dispatches === 'string' ? dispatches : undefined
        const [profiles, agents] = await Promise.all([
          includeProfiles && !workerCheckError && 'path' in script
            ? readJson<ProfileList>(run, script.path, 'list', cleanEnv, signal) : null,
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

    const lifetime = new AbortController()
    let panelOpenError: string | undefined
    let refreshing: Promise<void> | undefined
    let refreshAgain = false

    function refreshStatus(snapshot?: State): Promise<void> {
      const { signal } = lifetime
      if (signal.aborted) return Promise.resolve()
      if (refreshing) {
        // Focus or a binding might have changed after the current read began.
        refreshAgain = true
        return refreshing
      }
      refreshing = (async () => {
        try {
          do {
            refreshAgain = false
            const current = snapshot ?? await state(signal, false)
            snapshot = undefined
            if (signal.aborted) return
            try {
              await orca.host.call('statusBar.update', { id: STATUS_ID, ...statusFor(current, panelOpenError) }, { signal })
            } catch (error) {
              if (!signal.aborted) orca.log(`Could not update odd-flow status: ${message(error)}`)
            }
          } while (refreshAgain)
        } finally {
          refreshing = undefined
        }
      })()
      return refreshing
    }

    async function openPanel(signal: AbortSignal) {
      try {
        const cliEnv = isolatedEnv()
        delete cliEnv.ORCA_ENVIRONMENT
        delete cliEnv.ORCA_PAIRING_CODE
        const executable = await resolveOrca(cliEnv)
        if (!executable) throw new Error('Orca executable not found.')
        const configured = await orca.settings.get('pluginKey')
        if (configured !== undefined && typeof configured !== 'string') {
          throw new Error('The pluginKey setting must be a string.')
        }
        let key = configured?.trim()
        if (!key) {
          const { stdout } = await runExecutable(executable, ['plugin', 'list', '--json'], cliEnv, signal)
          const { plugins } = pluginResult(stdout)
          if (!Array.isArray(plugins)) throw new Error('Orca CLI returned an invalid plugin list.')
          const matches = plugins.filter((entry) => typeof entry?.pluginKey === 'string' &&
            entry.pluginKey.endsWith(`.${PANEL_ID}`) && typeof entry.status === 'string' && entry.status !== 'disabled')
          if (matches.length !== 1) {
            throw new Error(`Found ${matches.length} enabled odd-flow profiles plugins. Set pluginKey in Orca Settings.`)
          }
          key = matches[0].pluginKey as string
        }
        if (!key || key.startsWith('-')) throw new Error('The pluginKey setting must name an installed plugin, not an option.')
        signal.throwIfAborted()
        const { stdout } = await runExecutable(executable, ['plugin', 'open', key, '--panel', PANEL_ID, '--json'], cliEnv, signal)
        pluginResult(stdout)
        if (panelOpenError) {
          panelOpenError = undefined
          await refreshStatus()
        }
        return 'Opened the odd-flow profiles panel.'
      } catch (error) {
        const detail = `Could not open the odd-flow profiles panel: ${message(error)}`
        if (!signal.aborted) {
          panelOpenError = detail
          await refreshStatus()
        }
        return { error: detail }
      }
    }

    async function mutate(command: Mutation, input: unknown, signal: AbortSignal): Promise<MutationResult>
    async function mutate(command: Mutation, input: unknown, signal: AbortSignal, soleCoordinator: true): Promise<MutationOutcome>
    async function mutate(
      command: Mutation, input: unknown, signal: AbortSignal, soleCoordinator = false
    ): Promise<MutationOutcome> {
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

      async function targetError(): Promise<MutationOutcome | undefined> {
        const { agents } = await getAgents(signal)
        const matches = agents.filter((row) => row.agent === agent && row.sessionId === sessionId)
        if (!matches.length) return soleCoordinator ? { openPanel: true }
          : { error: 'This agent session is not reported in the focused workspace.' }
        const dispatches = await getDispatches(signal)
        if (typeof dispatches === 'string') return soleCoordinator ? { openPanel: true }
          : { error: dispatches, workerCheckUnavailable: true }
        if (matches.some((row) => isWorker(row, dispatches))) {
          return soleCoordinator ? { openPanel: true } : { error: 'Dispatched worker sessions cannot be changed.' }
        }
        if (soleCoordinator && agents.filter((row) => hasSession(row) && !isWorker(row, dispatches)).length !== 1) {
          return { openPanel: true }
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
        const snapshot = await state(signal)
        void refreshStatus(signal.aborted ? undefined : snapshot)
        return { state: snapshot }
      } catch (cause) {
        return { error: `Could not run ${command}: ${message(cause)}` }
      }
    }

    orca.panels.handle('state', (_input, { signal }) => state(signal))
    orca.panels.handle('use', (input, { signal }) => mutate('use', input, signal))
    orca.panels.handle('sessionMode', (input, { signal }) => mutate('session-mode', input, signal))
    orca.panels.handle('clear', (input, { signal }) => mutate('clear', input, signal))
    orca.commands.register('odd-flow.openProfiles', (_args, { signal }) => openPanel(signal))
    orca.commands.register('odd-flow.toggleMode', async (_args, { signal }) => {
      const snapshot = await state(signal, false)
      if (snapshot.error) return { error: snapshot.error }
      const rows = coordinators(snapshot)
      if (snapshot.workerCheckError || rows.length !== 1) return openPanel(signal)
      const { agent, sessionId } = rows[0]
      const odd = readableShow(rows[0].odd)
      if ('error' in odd) return odd
      const mode = odd.mode === 'organic' ? 'full-delegation' : 'organic'
      const result = await mutate('session-mode', { agent, sessionId, mode }, signal, true)
      if ('openPanel' in result) return openPanel(signal)
      return result.error ? { error: result.error } : `Switched odd-flow mode to ${mode}.`
    })
    orca.events.on('agent.status.changed', () => refreshStatus())
    orca.events.on('workspace.changed', () => refreshStatus())
    const stopRefresh = scheduleRefresh(refreshStatus)
    return () => {
      lifetime.abort()
      stopRefresh()
    }
  }
}

let stop: (() => void) | undefined
export default function activate(orca: OrcaWorkerApi): void {
  stop = createWorker()(orca)
}

export function deactivate(): void {
  stop?.()
  stop = undefined
}
