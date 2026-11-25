import type { Agent, Attention, CurrentWork, FeatureDoc, FeatureTask, GitSummary, WorkerRow } from './protocol'

export type RawTask = {
  id: string
  task_title: string
  status: string
  created_at: string
  completed_at: string | null
  created_by_terminal_handle: string | null
  run_id: string | null
  result: string | null
  spec?: string | null
}

export type RawFeatureDoc = { path: string; mtimeMs: number; text: string }

export type FeatureOwnership = {
  bySession: Map<string, FeatureDoc>
  ownedPaths: Set<string>
}

export type RawRun = {
  id: string
  objective: string
  coordinator_handle?: string | null
  created_at: string
}

export type RawDispatch = {
  dispatchId: string
  taskId: string
  state: string
  agent?: string | null
  terminal?: string | null
  workspace?: string | null
  attention?: string[]
}

export function parseOrcaTime(value: unknown): number | null {
  if (typeof value !== 'string') return null
  const input = value.trim()
  const utc = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(input)
    ? input.replace(' ', 'T') + 'Z'
    : input
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(utc)) return null
  const at = Date.parse(utc)
  return Number.isFinite(at) ? at : null
}

const taskStatuses = ['pending', 'in_progress', 'done', 'blocked', 'dropped'] as const
const activeDispatchStates = new Set(['ready', 'dispatched', 'running'])
type DashboardWorker = WorkerRow & { attentionSince?: number }

export function isActiveDispatch(state: string): boolean {
  return activeDispatchStates.has(state)
}

function tableCells(line: string): string[] {
  return line.trim().replace(/^\||(?<!\\)\|$/g, '')
    .split(/(?<!\\)\|/).map((cell) => cell.trim().replace(/\\\|/g, '|'))
}

export function parseFeatureDoc(path: string, markdown: string): FeatureDoc | null {
  const lines = markdown.split(/\r?\n/)
  const title = lines.find((line) => line.startsWith('# '))?.slice(2).trim()
  const firstSection = lines.findIndex((line) => /^#{2,6}\s/.test(line))
  const header = (firstSection < 0 ? lines : lines.slice(0, firstSection)).join('\n')
  const branch = /\bBranch:\s*`([^`\r\n]+)`/.exec(header)?.[1]
  const section = lines.findIndex((line) => /^## Tasks\s*$/.test(line))
  if (!title || !branch || section < 0) return null

  for (let i = section + 1; i < lines.length && !/^#{1,2}\s/.test(lines[i]); i++) {
    if (!lines[i].includes('|') || !lines[i + 1]?.includes('|')) continue
    const columns = tableCells(lines[i])
    const idColumn = columns.indexOf('ID')
    const workColumn = columns.indexOf('Work')
    const statusColumn = columns.indexOf('Status')
    if ([idColumn, workColumn, statusColumn].includes(-1)) continue
    const separator = tableCells(lines[i + 1])
    if (separator.length !== columns.length || !separator.every((cell) => /^:?-{3,}:?$/.test(cell))) continue

    const tasks: FeatureTask[] = []
    for (let j = i + 2; j < lines.length && lines[j].includes('|') && !/^#{1,2}\s/.test(lines[j]); j++) {
      const cells = tableCells(lines[j])
      if (cells.length !== columns.length || !cells[idColumn]) continue
      const statusWord = cells[statusColumn].split(/\s+/, 1)[0]
      tasks.push({
        id: cells[idColumn],
        work: cells[workColumn],
        status: taskStatuses.find((status) => status === statusWord) ?? 'unknown'
      })
    }
    return { path, title, branch, tasks }
  }
  return null
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function specCitesPath(spec: string, path: string): boolean {
  if (!spec.includes(path)) return false
  return new RegExp(
    `(?<![A-Za-z0-9_./-])${escapeRegExp(path)}(?![A-Za-z0-9_/-]|\\.[A-Za-z0-9_/-])`
  ).test(spec)
}

function compareCitationOrder(
  a: { createdAt: number | null; completedAt: number | null; session: string },
  b: { createdAt: number | null; completedAt: number | null; session: string }
): number {
  return newestFirst(a.createdAt, b.createdAt)
    || newestFirst(a.completedAt, b.completedAt)
    || (a.session < b.session ? -1 : a.session > b.session ? 1 : 0)
}

export function featureOwners(input: {
  docs: RawFeatureDoc[]
  tasks: RawTask[]
  runs: RawRun[]
  openSessions: Iterable<string>
}): FeatureOwnership {
  const open = new Set(input.openSessions)
  const runCoordinator = new Map(
    input.runs.filter((run) => run.coordinator_handle != null)
      .map((run) => [run.id, run.coordinator_handle!])
  )
  const openTasks: { spec: string; session: string; createdAt: number | null; completedAt: number | null }[] = []
  for (const task of input.tasks) {
    if (typeof task.spec !== 'string' || !task.spec) continue
    const session = (task.created_by_terminal_handle && open.has(task.created_by_terminal_handle))
      ? task.created_by_terminal_handle
      : (task.run_id ? runCoordinator.get(task.run_id) : undefined)
    if (!session || !open.has(session)) continue
    openTasks.push({
      spec: task.spec,
      session,
      createdAt: parseOrcaTime(task.created_at),
      completedAt: parseOrcaTime(task.completed_at)
    })
  }

  const ownedPaths = new Set<string>()
  const bestPerSession = new Map<string, {
    feature: FeatureDoc
    mtimeMs: number
    createdAt: number | null
    completedAt: number | null
  }>()

  for (const doc of input.docs) {
    const feature = parseFeatureDoc(doc.path, doc.text)
    if (!feature) continue
    let winner: (typeof openTasks)[number] | null = null
    for (const candidate of openTasks) {
      if (!specCitesPath(candidate.spec, doc.path)) continue
      if (!winner || compareCitationOrder(candidate, winner) < 0) winner = candidate
    }
    if (!winner) continue
    ownedPaths.add(doc.path)
    const current = bestPerSession.get(winner.session)
    if (!current || (
      newestFirst(winner.createdAt, current.createdAt)
      || newestFirst(winner.completedAt, current.completedAt)
      || newestFirst(doc.mtimeMs, current.mtimeMs)
    ) < 0) {
      bestPerSession.set(winner.session, {
        feature,
        mtimeMs: doc.mtimeMs,
        createdAt: winner.createdAt,
        completedAt: winner.completedAt
      })
    }
  }

  const bySession = new Map<string, FeatureDoc>()
  for (const [session, entry] of bestPerSession) bySession.set(session, entry.feature)
  return { bySession, ownedPaths }
}

export function selectFeatureDoc(
  docs: RawFeatureDoc[],
  branch: string,
  ownership?: { owners: FeatureOwnership; session: string }
): FeatureDoc | null {
  const owned = ownership?.owners.bySession.get(ownership.session)
  if (owned) return owned
  for (const doc of [...docs].sort((a, b) => b.mtimeMs - a.mtimeMs)) {
    if (ownership?.owners.ownedPaths.has(doc.path)) continue
    const feature = parseFeatureDoc(doc.path, doc.text)
    if (feature?.branch === branch) return feature
  }
  return null
}

function newestFirst(a: number | null, b: number | null): number {
  if (a === b) return 0
  if (a === null) return 1
  if (b === null) return -1
  return b - a
}

export function workerRows(input: {
  dispatches: RawDispatch[]; tasks: RawTask[]; agents: Agent[]; coordinator: string; runs: RawRun[]
}): DashboardWorker[] {
  const { dispatches, tasks, agents, coordinator, runs } = input
  const runIds = new Set(runs.filter((run) => run.coordinator_handle === coordinator).map((run) => run.id))
  const taskById = new Map(tasks.map((task) => [task.id, task]))
  const blockedTerminals = new Map(agents.filter((agent) => agent.state === 'blocked')
    .map((agent) => [agent.terminalId, agent]))
  const candidates = dispatches.map((dispatch) => {
    const task = taskById.get(dispatch.taskId)
    return { dispatch, task, active: isActiveDispatch(dispatch.state), startedAt: parseOrcaTime(task?.created_at) }
  }).sort((a, b) => Number(b.active) - Number(a.active) || newestFirst(a.startedAt, b.startedAt))

  const activeTerminals = new Set<string>()
  const workers: DashboardWorker[] = []
  for (const { dispatch, task, active, startedAt } of candidates) {
    const terminal = dispatch.terminal
    const newestActive = active && !!terminal && !activeTerminals.has(terminal)
    if (active && terminal) activeTerminals.add(terminal)
    if (!task || !(task.created_by_terminal_handle === coordinator || (task.run_id && runIds.has(task.run_id)))) continue

    const blocked = newestActive ? blockedTerminals.get(terminal ?? null) : undefined
    // Orca projects pending questions as input, not as a question category.
    const needsYou = active && (!!blocked || (dispatch.attention?.some((item) => item === 'input' || item === 'escalation') ?? false))
    workers.push({
      dispatchId: dispatch.dispatchId,
      title: task.task_title,
      agent: dispatch.agent ?? null,
      state: blocked ? 'blocked' : dispatch.state,
      active,
      needsYou,
      startedAt,
      endedAt: active ? null : parseOrcaTime(task.completed_at),
      ...(blocked?.stateStartedAt != null ? { attentionSince: blocked.stateStartedAt } : {})
    })
  }
  return workers
}

export function attentionItems(coordinator: Agent, workers: DashboardWorker[]): Attention[] {
  const attention: Attention[] = []
  if (coordinator.state === 'blocked') {
    attention.push({ label: 'This session is blocked', since: coordinator.stateStartedAt ?? null })
  }
  for (const worker of workers) {
    if (!worker.active || !worker.needsYou) continue
    attention.push({
      label: worker.agent ? `${worker.title} — ${worker.agent}` : worker.title,
      since: worker.attentionSince ?? worker.startedAt
    })
  }
  return attention
}

function resultSubject(result: string | null): string | null {
  if (result === null) return null
  try {
    const subject: unknown = JSON.parse(result)?.subject
    return typeof subject === 'string' && subject.trim() ? subject : null
  } catch {
    return null
  }
}

export function currentWork(runs: RawRun[], tasks: RawTask[], coordinator: string): CurrentWork | null {
  const run = runs.filter((item) => item.coordinator_handle === coordinator)
    .map((item) => ({ item, startedAt: parseOrcaTime(item.created_at) }))
    .sort((a, b) => newestFirst(a.startedAt, b.startedAt))[0]
  if (!run) return null

  const work: CurrentWork = { objective: run.item.objective, startedAt: run.startedAt, tasks: [], lastResult: null }
  let latest: { task: RawTask; endedAt: number } | null = null
  for (const task of tasks) {
    if (task.run_id !== run.item.id) continue
    const endedAt = parseOrcaTime(task.completed_at)
    work.tasks.push({ title: task.task_title, status: task.status, startedAt: parseOrcaTime(task.created_at), endedAt })
    if (endedAt !== null && (latest === null || endedAt > latest.endedAt)) latest = { task, endedAt }
  }
  if (latest) {
    const subject = resultSubject(latest.task.result)
    if (subject !== null) work.lastResult = { title: latest.task.task_title, subject }
  }
  return work
}

export function parseGit(branch: string, porcelain: string, log: string): GitSummary {
  const [hash, seconds] = log.trim().split('\x00')
  const at = /^\d+$/.test(seconds ?? '') ? Number(seconds) * 1000 : NaN
  return {
    branch: branch.trim() || null,
    changedFiles: porcelain.split('\n').filter((line) => line.trim()).length,
    lastCommit: hash && Number.isFinite(at) ? { hash, at } : null
  }
}
