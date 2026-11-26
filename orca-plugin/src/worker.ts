import { execFile } from 'node:child_process'
import { constants } from 'node:fs'
import { access, readFile, readdir, realpath, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, delimiter, isAbsolute, join, resolve } from 'node:path'
import type { HostMethods } from 'orca/host'
import type { OrcaWorkerApi } from 'orca/worker'
import { attentionItems, currentWork, featureOwners, hiddenDashboardWork, isActiveDispatch, parseGit, parseOrcaTime, selectFeatureDoc,
  workerRows, type FeatureOwnership, type RawDispatch, type RawRun, type RawTask } from './dashboard'
import { promptWithWorkerMarker } from './prompt-hook'
import { isAgentKind, isMode, type Agent, type AgentRow, type Dashboard, type OddState, type ProfileList,
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
const RUN_LIST = ['orchestration', 'run-list', '--environment', 'local', '--json', '--full']
const DASHBOARD_TIMEOUT_MS = 15_000
const DASHBOARD_RUN_LIMIT = 10
const PANEL_ID = 'odd-flow-profiles'
const STATUS_ID = 'odd-flow-status'
const STATUS_REFRESH_MS = 15_000
// Orca's statusBar.update schema measures these limits in UTF-16 code units.
const STATUS_TEXT_LIMIT = 64
const STATUS_TOOLTIP_LIMIT = 256
const LOG_KEY_LIMIT = 128
const LOG_HOST_REASON_LIMIT = 256
const SESSION_UUID = /[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}/i
const PROFILE_UPGRADE_PREFIX = 'odd-flow 0.3.0 or newer is required (found '
type Env = Record<string, string | undefined>
type Mutation = 'use' | 'session-mode' | 'clear'
type Status = Omit<HostMethods['statusBar.update']['params'], 'id'> & { text: string; tooltip: string }
type StatusDispatch = {
  dispatchId: string
  terminal?: string | null
  state?: string
  agent?: string | null
  attention?: string[]
}
type StatusSnapshot = { snapshot: State; activeDispatches?: StatusDispatch[] }
type MutationOutcome = MutationResult | { openPanel: true }
type CommandResult = string | { error: string }
type CommandTrace = {
  branch?: string
  fallback?: string
  panel?: { source?: 'setting' | 'detected'; key?: string; error?: string }
}

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
      const program = executable === 'python3' ? 'Python' : executable === 'git' ? 'Git' : 'Orca CLI'
      reject(new Error(`${program} timed out after ${TIMEOUT_MS / 1000} seconds.`))
    } else if (error) reject(Object.assign(error, { stdout, stderr }))
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
  workers: StatusDispatch[]
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

function cliErrorCode(stdout: unknown): string | undefined {
  if (typeof stdout !== 'string') return
  try {
    return JSON.parse(stdout)?.error?.code
  } catch {
    return undefined
  }
}

async function dashboardList<T>(
  runList: (argv: readonly string[]) => Promise<{ stdout: string }>, argv: readonly string[],
  key: 'runs' | 'tasks' | 'workers', runId?: string
): Promise<{ rows: T[]; cursor?: string | number } | null> {
  let stdout: string
  try {
    ({ stdout } = await runList(argv))
  } catch (error) {
    // Some CLI commands return the structured error on stdout and exit nonzero.
    if (runId && error && typeof error === 'object' &&
        (('stdout' in error && cliErrorCode(error.stdout) === 'run_not_found') ||
          message(error) === 'run_not_found')) return null
    throw error
  }
  const parsed = JSON.parse(stdout)
  if (runId && parsed?.error?.code === 'run_not_found') return null
  const { result } = parsed ?? {}
  if (parsed?.ok !== true || !Array.isArray(result?.[key]) || (runId &&
      (key === 'workers' && result.scope && (result.scope.source !== 'flag' || result.scope.run !== runId) ||
       key === 'tasks' && result.runId != null && result.runId !== runId))) {
    throw new Error('Unexpected dashboard list response.')
  }
  return { rows: result[key], cursor: result.nextCursor ?? undefined }
}

async function featureDocs(root: string, signal: AbortSignal) {
  let directory: string
  try {
    const canonicalRoot = await realpath(root)
    const expected = join(canonicalRoot, 'odd', 'tasks')
    directory = await realpath(expected)
    if (directory !== expected) throw new Error('Feature document directory is a symbolic link.')
  } catch (error) {
    if (error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT') return []
    throw error
  }
  const docs = []
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    signal.throwIfAborted()
    if (!entry.isFile() || !entry.name.endsWith('.md')) continue
    const path = join(directory, entry.name)
    const { mtimeMs } = await stat(path)
    docs.push({ path: `odd/tasks/${entry.name}`, text: await readFile(path, { encoding: 'utf8', signal }), mtimeMs })
  }
  return docs
}

function dispatchRoot(workspace: string | null | undefined) {
  if (typeof workspace !== 'string') return
  const separator = workspace.indexOf('::')
  if (separator < 1) return
  const path = workspace.slice(separator + 2)
  if (isAbsolute(path)) return path
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

function ellipsize(value: string, limit: number): string {
  return value.length <= limit ? value : value.slice(0, limit - 1).replace(/[\uD800-\uDBFF]$/u, '') + '…'
}

function tooltipLines(first: string, second?: string, limit = STATUS_TOOLTIP_LIMIT): string {
  if (!second) return first
  const budget = limit - 1 // Reserve the newline between the two details.
  if (first.length + second.length <= budget) return `${first}\n${second}`
  const firstLimit = Math.min(first.length, Math.max(Math.ceil(budget / 2), budget - second.length))
  return `${ellipsize(first, firstLimit)}\n${ellipsize(second, budget - firstLimit)}`
}

function blockedDuration(since: number | undefined): string {
  if (!Number.isFinite(since) || !since) return ''
  const seconds = Math.max(0, Math.floor((Date.now() - since) / 1000))
  if (seconds < 60) return ` ${seconds}s`
  if (seconds < 3600) return ` ${Math.floor(seconds / 60)}m`
  if (seconds < 86400) return ` ${Math.floor(seconds / 3600)}h`
  return ` ${Math.floor(seconds / 86400)}d`
}

function statusAttention(rows: Agent[], agents: Agent[], activeDispatches: StatusDispatch[]): string[] {
  const labels = rows.flatMap((row) => attentionItems(row, []).map(({ label }) => label))
  const byTerminal = new Map(agents.map((agent) => [agent.terminalId, agent]))
  const seenTerminals = new Set<string>()
  for (const { terminal, agent, attention } of activeDispatches) {
    if (!terminal) continue
    const row = byTerminal.get(terminal)
    if (!row) continue
    const blocked = !seenTerminals.has(terminal) && row.state === 'blocked'
    seenTerminals.add(terminal)
    if (!blocked && !(Array.isArray(attention) &&
        attention.some((item) => item === 'input' || item === 'escalation'))) continue
    const title = row.task?.title || row.title || 'Worker'
    const provider = typeof agent === 'string' && agent ? agent : row.agent
    labels.push(`${title}${provider ? ` — ${provider}` : ''}${blocked ? `, blocked${blockedDuration(row.stateStartedAt)}` : ''}`)
  }
  return labels
}

function statusFor({ snapshot, activeDispatches = [] }: StatusSnapshot, panelOpenError?: string): Status {
  const warning = (text: string, tooltip: string, tone: 'warning' | 'danger' = 'warning'): Status =>
    ({ visible: true, text, tooltip, tone })
  if (snapshot.workerCheckError) {
    const detail = tooltipLines(snapshot.workerCheckError, panelOpenError)
    return warning('odd: worker check failed', detail, 'danger')
  }
  if (snapshot.error) return warning('odd: status unavailable', snapshot.error, 'danger')
  const rows = coordinators(snapshot)
  if (!rows.length) return { visible: false, tone: 'neutral', text: '', tooltip: '' }
  const attention = statusAttention(rows, snapshot.agents, activeDispatches)
  if (attention.length) {
    const scriptError = 'error' in snapshot.script ? snapshot.script.error : undefined
    // When both warnings are present, reserve enough room for both inside the second part.
    const detail = scriptError && panelOpenError
      ? tooltipLines(scriptError, panelOpenError, Math.floor((STATUS_TOOLTIP_LIMIT - 1) / 2))
      : scriptError || panelOpenError
    return warning('odd: ⚠ needs you', tooltipLines(attention.join('\n'), detail))
  }
  if ('error' in snapshot.script) return warning('odd: script unavailable', snapshot.script.error)
  if (panelOpenError) return warning('odd: panel unavailable', panelOpenError)
  if (rows.length > 1) {
    const outdatedShow = rows.map(({ odd }) => odd)
      .find((odd): odd is string => typeof odd === 'string' && odd.startsWith(PROFILE_UPGRADE_PREFIX))
    if (outdatedShow) return warning('odd: show failed', outdatedShow)
    return { visible: true, tone: 'neutral', text: `odd: ${rows.length} sessions`, tooltip: 'Open the ODD Flow panel' }
  }
  const odd = readableShow(rows[0].odd)
  if ('error' in odd) return warning('odd: show failed', odd.error)
  return {
    visible: true, tone: 'neutral', text: `odd: ${odd.profile ?? '(no profile)'} · ${odd.mode}`,
    tooltip: tooltipLines(`Profile source: ${odd.source}`, `Mode source: ${odd.mode_source}`)
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
    const stderr = error && typeof error === 'object' && 'stderr' in error ? error.stderr : undefined
    if (typeof stderr === 'string' && stderr.startsWith('usage: ') &&
        stderr.split(/\r?\n/).reverse().find((line) => line.trim()) ===
          `${basename(path)}: error: unrecognized arguments: --json`) {
      return `${PROFILE_UPGRADE_PREFIX}${path}). Update the odd-flow plugin, or set profileScript to a newer profile.py.`
    }
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
    function logDiagnostic(format: () => string) {
      try {
        orca.log(format())
      } catch {
        // Diagnostics must not affect the command or the status bar.
      }
    }

    function containsPrivateValue(text: string): boolean {
      return SESSION_UUID.test(text) ||
        Object.values(env).some((value) => value && (text === value || (value.length >= 8 && text.includes(value))))
    }

    function loggedPluginKey(key: string | undefined): string {
      if (!key) return 'unresolved'
      if (!/^[a-z0-9._-]+$/i.test(key) || containsPrivateValue(key)) return '[redacted]'
      return ellipsize(key, LOG_KEY_LIMIT)
    }

    async function loggedCommand(
      id: string, signal: AbortSignal, execute: (trace: CommandTrace) => Promise<CommandResult>
    ): Promise<CommandResult> {
      logDiagnostic(() => `${id} started`)
      const trace: CommandTrace = {}
      let outcome = 'error'
      try {
        const result = await execute(trace)
        if (typeof result === 'string') outcome = 'success'
        return result
      } finally {
        logDiagnostic(() => {
          const aborted = signal.aborted
          const details = [`${id} ended: ${outcome}${aborted ? ' (aborted)' : ''}`]
          if (!aborted && trace.branch) details.push(trace.branch)
          if (!aborted && trace.fallback) {
            details.push(`${outcome === 'success' ? 'opened panel' : 'could not open panel'} (${trace.fallback})`)
          }
          if (trace.panel) {
            const { source, key, error } = trace.panel
            details.push(`keySource=${source ?? 'unresolved'}`, `key=${loggedPluginKey(key)}`)
            if (!aborted && error) details.push(error)
          }
          if (aborted) details.push('Command signal was aborted.')
          return details.join('; ')
        })
      }
    }

    function isolatedEnv(): Env {
      const cleanEnv = { ...env }
      for (const key of SESSION_KEYS) delete cleanEnv[key]
      return cleanEnv
    }

    const terminalSessions = new Map<string, { sessionId: string; lastSeen: number; boundary?: number }>()
    const getAgents = async (signal: AbortSignal) => {
      const { agents } = await orca.host.call('agents.list', undefined, { signal })
      const now = Date.now()
      const sessionBoundaries = new Map<string, number>()
      for (const { terminalId, sessionId } of agents) {
        if (!terminalId || !sessionId?.trim()) continue
        const previous = terminalSessions.get(terminalId)
        const boundary = previous?.sessionId === sessionId ? previous.boundary : previous?.lastSeen
        terminalSessions.set(terminalId, { sessionId, lastSeen: now, boundary })
        if (boundary !== undefined) sessionBoundaries.set(terminalId, boundary)
      }
      return { agents, sessionBoundaries }
    }
    const getScript = async () => resolveScript(home, await orca.settings.get('profileScript'))
    const cachedDispatchIds = new Set<string>()
    const cachedTerminals = new Set<string>()
    let cachedActiveDispatchIds = new Set<string>()
    let statusHead = new Set<string>()

    async function getDispatches(signal: AbortSignal, includeAttention = false) {
      try {
        const knownIds = includeAttention ? statusHead : cachedDispatchIds
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
        const activeDispatches = new Map<string, StatusDispatch>()
        const head = new Set<string>()
        // A known page can precede an active dispatch whose state has changed.
        const unseenActive = includeAttention ? new Set(cachedActiveDispatchIds) : new Set<string>()
        const seenCursors = new Set<string>()
        let cursor: string | null | undefined
        let reachedKnownPage = false
        do {
          const timeout = Math.min(TIMEOUT_MS, remainingBudget())
          const argv = cursor ? [...WORKER_LIST, '--cursor', cursor] : WORKER_LIST
          const { stdout } = await runExecutable(executable, argv, cliEnv, signal, timeout)
          const page = dispatchPage(stdout)
          for (const row of page.workers) {
            const { dispatchId, terminal, state } = row
            if (knownIds.has(dispatchId)) reachedKnownPage = true
            dispatchIds.add(dispatchId)
            if (terminal != null) terminals.add(terminal)
            if (includeAttention) {
              if (!cursor) head.add(dispatchId)
              unseenActive.delete(dispatchId)
              if (terminal && typeof state === 'string' && isActiveDispatch(state)) activeDispatches.set(dispatchId, row)
            }
          }
          cursor = page.nextCursor
          if (cursor) {
            if (seenCursors.has(cursor)) throw new Error('Orca CLI repeated a dispatch cursor.')
            seenCursors.add(cursor)
          }
        } while (cursor && (!reachedKnownPage || unseenActive.size > 0))
        remainingBudget()
        for (const id of dispatchIds) cachedDispatchIds.add(id)
        for (const terminal of terminals) cachedTerminals.add(terminal)
        if (includeAttention) {
          cachedActiveDispatchIds = new Set(activeDispatches.keys())
          statusHead = head
        }
        return { terminals: cachedTerminals, activeDispatches: [...activeDispatches.values()] }
      } catch (error) {
        return `Could not check dispatched workers: ${message(error)}`
      }
    }

    const runCache = new Map<string, { tasks: RawTask[]; dispatches: RawDispatch[] }>()

    function formatWorkerError(command: string | null, error: unknown): string {
      const cleaned = message(error)
        .replace(new RegExp(SESSION_UUID.source, 'gi'), '[session]')
        .replace(/\btask_[a-z0-9]+\b/gi, '[task]')
        .replace(/[\p{Cc}\p{Zl}\p{Zp}\s]+/gu, ' ')
        .trim() || 'Unknown error.'
      return ellipsize(command ? `${command}: ${cleaned}` : cleaned, 160)
    }

    async function dashboardRuns(coordinatorIds: Set<string>, signal: AbortSignal) {
      const runs: RawRun[] = []
      const tasks: RawTask[] = []
      const dispatches: RawDispatch[] = []
      const failed = new Map<string, string>()
      let listError: string | undefined
      let command: string | null = null
      try {
        const cliEnv = isolatedEnv()
        const executable = await resolveOrca(cliEnv)
        if (!executable) throw new Error('Orca executable not found.')
        const runCli = (argv: readonly string[]) => {
          signal.throwIfAborted()
          return runExecutable(executable, argv, cliEnv, signal, TIMEOUT_MS)
        }
        command = 'run-list'
        const listed: RawRun[] = []
        const cursors = new Set<string>()
        let args = RUN_LIST
        while (true) {
          const page = await dashboardList<RawRun>(runCli, args, 'runs')
          if (!page) break
          for (const row of page.rows) {
            if (typeof row?.id !== 'string' || !row.id || row.id.startsWith('-')) continue
            listed.push({ id: row.id, objective: row.objective, created_at: row.created_at,
              coordinator_handle: row.coordinator_handle })
          }
          if (page.cursor == null) break
          const cursor = String(page.cursor)
          if (cursors.has(cursor)) throw new Error('Orca CLI repeated a run cursor.')
          cursors.add(cursor)
          args = [...RUN_LIST, '--cursor', cursor]
        }
        const selected = new Set<string>()
        const owned = [...new Map(listed.filter(({ coordinator_handle }) =>
          coordinator_handle != null && coordinatorIds.has(coordinator_handle)).map((row) => [row.id, row])).values()]
          .sort((a, b) => (parseOrcaTime(b.created_at) ?? -Infinity) - (parseOrcaTime(a.created_at) ?? -Infinity))
        for (const coordinator of coordinatorIds) {
          for (const row of owned.filter((run) => run.coordinator_handle === coordinator).slice(0, DASHBOARD_RUN_LIMIT)) {
            selected.add(row.id)
          }
        }

        const refreshed = await Promise.all(owned.filter(({ id }) => selected.has(id)).map(async (row) => {
          const id = row.id
          const [taskResult, workerResult] = await Promise.allSettled([
            dashboardList<RawTask>(runCli, ['orchestration', 'task-list', '--environment', 'local',
              '--run', id, '--json', '--full'], 'tasks', id).then((page) =>
              // Keep only the fields the pure derivations consume; never expose spec text in State or logs.
              page && page.rows.map(({ id, task_title, status, created_at, completed_at,
                created_by_terminal_handle, run_id, result, spec }) =>
                ({ id, task_title, status, created_at, completed_at, created_by_terminal_handle, run_id, result, spec }))),
            scopedDispatches(runCli, id, runCache.get(id)?.dispatches ?? [])
          ])
          const runTasks = taskResult.status === 'fulfilled' ? taskResult.value : undefined
          const runWorkers = workerResult.status === 'fulfilled' ? workerResult.value : undefined
          if (runTasks === null || runWorkers === null) {
            runCache.delete(id)
            return null
          }
          const data = { tasks: runTasks ?? [], dispatches: runWorkers ?? [] }
          if (runTasks && runWorkers) runCache.set(id, data)
          else if (row.coordinator_handle && !failed.has(row.coordinator_handle)) {
            const detail = taskResult.status === 'rejected'
              ? formatWorkerError('task-list', taskResult.reason)
              : workerResult.status === 'rejected'
                ? formatWorkerError('worker-list', workerResult.reason)
                : 'Unknown error.'
            failed.set(row.coordinator_handle, detail)
          }
          return { row, data }
        }))
        for (const item of refreshed) {
          if (!item) continue
          runs.push(item.row)
          tasks.push(...item.data.tasks)
          dispatches.push(...item.data.dispatches)
        }
        for (const row of owned) {
          if (selected.has(row.id)) continue
          const cached = runCache.get(row.id)
          if (!cached) continue
          runs.push(row)
          tasks.push(...cached.tasks)
          dispatches.push(...cached.dispatches.filter(({ state }) => !isActiveDispatch(state)))
        }
        const listedIds = new Set(listed.map(({ id }) => id))
        for (const id of runCache.keys()) if (!listedIds.has(id)) runCache.delete(id)
      } catch (error) {
        listError = formatWorkerError(command, error)
      }
      return { runs, tasks, dispatches, failed, listError }
    }

    async function scopedDispatches(
      runCli: (argv: readonly string[]) => Promise<{ stdout: string }>, id: string, cached: RawDispatch[]
    ): Promise<RawDispatch[] | null> {
      const known = new Set(cached.map(({ dispatchId }) => dispatchId))
      const stillActive = new Set(cached.filter(({ state }) => isActiveDispatch(state)).map(({ dispatchId }) => dispatchId))
      const argv = ['orchestration', 'worker-list', '--environment', 'local', '--run', id, '--json']
      const cursors = new Set<string>()
      const fresh = new Map<string, RawDispatch>()
      let cursor: string | undefined
      let reachedKnown = false
      do {
        const page = await dashboardList<RawDispatch>(runCli, cursor ? [...argv, '--cursor', cursor] : argv, 'workers', id)
        if (!page) return null
        for (const { dispatchId, taskId, state, agent, terminal, workspace, attention } of page.rows) {
          if (typeof dispatchId !== 'string' || typeof taskId !== 'string' || typeof state !== 'string' ||
              (attention != null && !Array.isArray(attention))) throw new Error('Invalid dashboard dispatch row.')
          if (known.has(dispatchId)) reachedKnown = true
          stillActive.delete(dispatchId)
          fresh.set(dispatchId, { dispatchId, taskId, state, agent, terminal, workspace, attention })
        }
        cursor = typeof page.cursor === 'string' && page.cursor ? page.cursor : undefined
        if (cursor) {
          if (cursors.has(cursor)) throw new Error('Orca CLI repeated a dispatch cursor.')
          cursors.add(cursor)
        }
      } while (cursor && (!reachedKnown || stillActive.size > 0))
      // Only reuse older settled rows when an incremental cutoff was reached.
      if (cursor) for (const row of cached) if (!fresh.has(row.dispatchId)) fresh.set(row.dispatchId, row)
      return [...fresh.values()]
    }

    async function workspaceRoot(signal: AbortSignal) {
      try {
        const context = await orca.host.call('workspace.readContext', undefined, { signal })
        if (context?.workspaceId) {
          const { workspaces } = await orca.host.call('workspace.list', undefined, { signal })
          const matched = workspaces.find(({ id }) => id === context.workspaceId)
          if (matched?.hostId && matched.hostId !== 'local') return { remote: true }
          if (matched && isAbsolute(matched.path)) return { root: matched.path, branch: context.branch }
        }
      } catch {
        // A scoped dispatch may still identify the local workspace.
      }
      return {}
    }

    async function workspaceData(root: string, fallbackBranch: string | undefined, signal: AbortSignal) {
      const gitEnv = { ...isolatedEnv(), GIT_OPTIONAL_LOCKS: '0',
        GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'core.fsmonitor', GIT_CONFIG_VALUE_0: 'false' }
      const git = async (...argv: string[]) => {
        signal.throwIfAborted()
        return (await runExecutable('git', ['-C', root, ...argv], gitEnv, signal, TIMEOUT_MS)).stdout
      }
      const branch = git('branch', '--show-current')
      const [summary, featureSource] = await Promise.allSettled([
        Promise.all([branch, git('status', '--porcelain'), git('log', '-1', '--format=%h%x00%ct')])
          .then(([name, porcelain, log]) => parseGit(name, porcelain, log)),
        Promise.all([featureDocs(root, signal), branch.catch(() => fallbackBranch ?? '')])
          .then(([docs, name]) => ({ docs, branch: name.trim() }))
      ])
      return { summary, featureSource }
    }

    async function dashboardsFor(
      snapshot: State, sessionBoundaries: ReadonlyMap<string, number>, signal: AbortSignal
    ): Promise<Record<string, Dashboard>> {
      const rows = coordinators(snapshot).filter((row): row is typeof row & { terminalId: string } => !!row.terminalId)
      if (!rows.length) return {}
      const deadline = AbortSignal.any([signal, AbortSignal.timeout(DASHBOARD_TIMEOUT_MS)])
      const workspaces = new Map<string, ReturnType<typeof workspaceData>>()
      const ownershipByRoot = new Map<string, FeatureOwnership>()
      function loadWorkspace(root: string, branch?: string) {
        let data = workspaces.get(root)
        if (!data) {
          data = workspaceData(root, branch, deadline)
          workspaces.set(root, data)
        }
        return data
      }
      const [workspace, sources] = await Promise.all([
        workspaceRoot(deadline).then((workspace) => {
          if (workspace.root) void loadWorkspace(workspace.root, workspace.branch)
          return workspace
        }),
        dashboardRuns(new Set(rows.map(({ terminalId }) => terminalId)), deadline)
      ])
      const { runs, tasks, dispatches, failed, listError } = sources
      const hidden = hiddenDashboardWork(runs, tasks, dispatches, Date.now())
      const openSessions = rows.map(({ terminalId }) => terminalId)
      const entries = await Promise.all(rows.map(async (row): Promise<[string, Dashboard]> => {
        const terminalId = row.terminalId
        const sessionBoundary = sessionBoundaries.get(terminalId)
        const { workers, workspaceCandidates } = workerRows({
          dispatches, tasks, agents: snapshot.agents, coordinator: terminalId, runs, hidden, sessionBoundary
        })
        const dashboard: Dashboard = {
          terminalId, workers, attention: attentionItems(row, workers), feature: null, current: null, git: null, errors: {}
        }
        const workerError = listError ?? failed.get(terminalId)
        if (workerError) dashboard.errors.workers = `Could not load all Orca work for this session: ${workerError}`
        const root = workspace.root ?? (!workspace.remote ? [...workspaceCandidates]
          .map(dispatchRoot).find((path) => path !== undefined) : undefined)
        if (!root) {
          dashboard.errors.workspace = 'Workspace path is unavailable.'
          return [terminalId, dashboard]
        }
        const { summary, featureSource } = await loadWorkspace(root, workspace.branch)
        if (summary.status === 'fulfilled') dashboard.git = summary.value
        else dashboard.errors.git = 'Could not read Git status for this workspace.'
        if (featureSource.status === 'fulfilled') {
          let owners = ownershipByRoot.get(root)
          if (!owners) {
            owners = featureOwners({
              docs: featureSource.value.docs, tasks, runs, openSessions, hiddenRunIds: hidden.runs, sessionBoundaries
            })
            ownershipByRoot.set(root, owners)
          }
          dashboard.feature = selectFeatureDoc(featureSource.value.docs, featureSource.value.branch, {
            owners, session: terminalId
          })
        } else {
          dashboard.errors.feature = 'Could not read feature documents for this workspace.'
        }
        if (!dashboard.feature) dashboard.current = currentWork(runs, tasks, terminalId, hidden.runs, sessionBoundary)
        return [terminalId, dashboard]
      }))
      return Object.fromEntries(entries)
    }

    async function readState(
      signal: AbortSignal, includeProfiles: boolean, includeDashboards: boolean, includeAttention: boolean
    ): Promise<StatusSnapshot> {
      try {
        const [listed, script] = await Promise.all([getAgents(signal), getScript()])
        const cleanEnv = isolatedEnv()
        const dispatches = await getDispatches(signal, includeAttention)
        const workerCheckError = typeof dispatches === 'string' ? dispatches : undefined
        const [profiles, agents] = await Promise.all([
          includeProfiles && !workerCheckError && 'path' in script
            ? readJson<ProfileList>(run, script.path, 'list', cleanEnv, signal) : null,
          Promise.all(listed.agents.map(({ terminalId, title, agent, state, stateStartedAt, sessionId, task }) =>
            agentRow({
              terminalId, title, agent, state, stateStartedAt, sessionId: sessionId ?? null,
              ...(task != null ? { task: { title: task.title } } : {})
            }, typeof dispatches === 'string' ? dispatches : dispatches.terminals, script, cleanEnv, run, signal)
          ))
        ])
        const snapshot: State = { script, profiles, agents, ...(workerCheckError ? { workerCheckError } : {}) }
        if (includeDashboards && !workerCheckError) {
          snapshot.dashboards = await dashboardsFor(snapshot, listed.sessionBoundaries, signal)
        }
        return { snapshot, activeDispatches: typeof dispatches === 'string' ? undefined : dispatches.activeDispatches }
      } catch (cause) {
        const error = message(cause)
        return { snapshot: { script: { error }, profiles: null, agents: [], error } }
      }
    }

    async function state(signal: AbortSignal, includeProfiles = true): Promise<State> {
      return (await readState(signal, includeProfiles, includeProfiles, false)).snapshot
    }

    const lifetime = new AbortController()
    let panelOpenError: string | undefined
    let refreshing: Promise<void> | undefined
    let refreshAgain = false

    function refreshStatus(snapshot?: StatusSnapshot): Promise<void> {
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
            const current = await (snapshot ?? readState(signal, false, false, true))
            snapshot = undefined
            if (signal.aborted) return
            const status = statusFor(current, panelOpenError)
            try {
              await orca.host.call('statusBar.update', {
                id: STATUS_ID, ...status,
                text: ellipsize(status.text, STATUS_TEXT_LIMIT), tooltip: ellipsize(status.tooltip, STATUS_TOOLTIP_LIMIT)
              }, { signal })
            } catch (error) {
              if (!signal.aborted) logDiagnostic(() => {
                // Use the host message, not the subprocess-oriented stderr fallback.
                const reason = (error instanceof Error ? error.message : String(error)).replace(/[\p{Cc}\p{Zl}\p{Zp}]/gu, '')
                const privateReason = containsPrivateValue(reason) ||
                  current.snapshot.agents.some(({ sessionId }) => sessionId && reason.includes(sessionId))
                return `Could not update odd-flow status: ${privateReason ? '[redacted]' : ellipsize(reason, LOG_HOST_REASON_LIMIT)}`
              })
            }
          } while (refreshAgain)
        } catch {
          if (!signal.aborted) logDiagnostic(() => 'Could not refresh odd-flow status.')
        } finally {
          refreshing = undefined
        }
      })()
      return refreshing
    }

    async function openPanel(signal: AbortSignal, trace: CommandTrace) {
      const panel: NonNullable<CommandTrace['panel']> = {}
      trace.panel = panel
      // External errors can contain child output or secrets. Keep them in the
      // command result and status bar, but log only the failed step or a local validation error.
      let diagnostic = 'Could not resolve the Orca executable.'
      function fail(detail: string): never {
        diagnostic = detail
        throw new Error(detail)
      }
      try {
        const cliEnv = isolatedEnv()
        delete cliEnv.ORCA_ENVIRONMENT
        delete cliEnv.ORCA_PAIRING_CODE
        const executable = await resolveOrca(cliEnv)
        if (!executable) fail('Orca executable not found.')
        diagnostic = 'Could not read the pluginKey setting.'
        const configured = await orca.settings.get('pluginKey')
        panel.source = configured === undefined ? 'detected' : 'setting'
        if (configured !== undefined && typeof configured !== 'string') {
          fail('The pluginKey setting must be a string.')
        }
        let key = configured?.trim()
        panel.source = key ? 'setting' : 'detected'
        if (!key) {
          diagnostic = 'Could not list installed plugins with the Orca CLI.'
          const { stdout } = await runExecutable(executable, ['plugin', 'list', '--json'], cliEnv, signal)
          const { plugins } = pluginResult(stdout)
          if (!Array.isArray(plugins)) fail('Orca CLI returned an invalid plugin list.')
          const matches = plugins.filter((entry) => typeof entry?.pluginKey === 'string' &&
            entry.pluginKey.endsWith(`.${PANEL_ID}`) && typeof entry.status === 'string' && entry.status !== 'disabled')
          if (matches.length !== 1) {
            fail(`Found ${matches.length} enabled ODD Flow plugins. Set pluginKey in Orca Settings.`)
          }
          key = matches[0].pluginKey as string
        }
        if (!key || key.startsWith('-')) fail('The pluginKey setting must name an installed plugin, not an option.')
        panel.key = key
        signal.throwIfAborted()
        diagnostic = 'The Orca CLI could not open the panel.'
        const { stdout } = await runExecutable(executable, ['plugin', 'open', key, '--panel', PANEL_ID, '--json'], cliEnv, signal)
        pluginResult(stdout)
        if (panelOpenError) {
          panelOpenError = undefined
          await refreshStatus()
        }
        return 'Opened the ODD Flow panel.'
      } catch (error) {
        panel.error = diagnostic
        const detail = `Could not open the ODD Flow panel: ${message(error)}`
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
        if (matches.some((row) => isWorker(row, dispatches.terminals))) {
          return soleCoordinator ? { openPanel: true } : { error: 'Dispatched worker sessions cannot be changed.' }
        }
        if (soleCoordinator && agents.filter((row) => hasSession(row) && !isWorker(row, dispatches.terminals)).length !== 1) {
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
        const current = await readState(signal, true, !soleCoordinator, true)
        void refreshStatus(signal.aborted ? undefined : current)
        return { state: current.snapshot }
      } catch (cause) {
        return { error: `Could not run ${command}: ${message(cause)}` }
      }
    }

    orca.panels.handle('state', (_input, { signal }) => state(signal))
    orca.panels.handle('use', (input, { signal }) => mutate('use', input, signal))
    orca.panels.handle('sessionMode', (input, { signal }) => mutate('session-mode', input, signal))
    orca.panels.handle('clear', (input, { signal }) => mutate('clear', input, signal))
    orca.commands.register('odd-flow.openProfiles', (_args, { signal }) =>
      loggedCommand('odd-flow.openProfiles', signal, (trace) => openPanel(signal, trace)))
    orca.commands.register('odd-flow.toggleMode', (_args, { signal }) =>
      loggedCommand('odd-flow.toggleMode', signal, async (trace) => {
        const fallback = (reason: string) => {
          trace.branch = undefined
          trace.fallback = reason
          return openPanel(signal, trace)
        }
        trace.branch = 'could not read workspace state'
        const snapshot = await state(signal, false)
        if (snapshot.error) return { error: snapshot.error }
        const rows = coordinators(snapshot)
        if (snapshot.workerCheckError) return fallback('worker check unavailable')
        if (rows.length !== 1) return fallback(rows.length ? 'several coordinators' : 'zero coordinators')
        const { agent, sessionId } = rows[0]
        trace.branch = 'could not read current mode'
        const odd = readableShow(rows[0].odd)
        if ('error' in odd) return odd
        const mode = odd.mode === 'organic' ? 'full-delegation' : 'organic'
        trace.branch = `could not switch to ${mode}`
        const result = await mutate('session-mode', { agent, sessionId, mode }, signal, true)
        if ('openPanel' in result) return fallback('coordinator re-check')
        if (result.error) return { error: result.error }
        trace.branch = `switched to ${mode}`
        return `Switched odd-flow mode to ${mode}.`
      }))
    const refreshOnEvent = () => {
      void refreshStatus()
    }
    orca.events.on('agent.status.changed', refreshOnEvent)
    orca.events.on('workspace.changed', refreshOnEvent)
    const stopRefresh = scheduleRefresh(refreshStatus)
    return () => {
      lifetime.abort()
      stopRefresh()
    }
  }
}

let stop: (() => void) | undefined
export default function activate(orca: OrcaWorkerApi): void {
  orca.hooks.on('agent.prompt.before', (event, next) => {
    const prompt = promptWithWorkerMarker(event, { stateDir: process.env.ODD_FLOW_STATE_DIR, log: (message) => orca.log(message) })
    if (prompt !== undefined) return next({ ...event, prompt })
  })
  stop = createWorker()(orca)
}

export function deactivate(): void {
  stop?.()
  stop = undefined
}
