import { attentionItems, isActiveDispatch } from '../dashboard'
import {
  isAgentKind,
  MODES,
  type Agent,
  type Attention,
  type CurrentWork,
  type Dashboard,
  type FeatureDoc,
  type FeatureTask,
  type GitSummary,
  type OddState,
  type ProfileList,
  type State,
  type WorkerRow
} from '../protocol'

export type Feedback = { row: string; text: string; failed: boolean }

export type RenderUi = {
  pending: boolean
  feedback: Feedback | null
  error: string | null
  now: number
  expanded?: ReadonlySet<string>
  selectedSession?: string | null
  pinnedSession?: string | null
}

export type SessionRef = {
  row: State['agents'][number]
  key: string
}

export function sessionKey(row: State['agents'][number], index: number): string {
  return row.terminalId ?? `${index}:${row.agent}:${row.sessionId}`
}

function sessionTitle(row: State['agents'][number]): string {
  return row.task?.title ?? row.title ?? row.terminalId ?? 'Untitled'
}

export function pickFollowSession(
  sessions: readonly SessionRef[],
  lastWorkingAt?: ReadonlyMap<string, { at: number; seq: number }>
): string | null {
  if (sessions.length === 0) return null
  if (lastWorkingAt && lastWorkingAt.size > 0) {
    let bestKey: string | null = null
    let bestAt = -Infinity
    let bestSeq = -Infinity
    for (const { key } of sessions) {
      const entry = lastWorkingAt.get(key)
      if (!entry) continue
      if (entry.at > bestAt || (entry.at === bestAt && entry.seq > bestSeq)) {
        bestKey = key
        bestAt = entry.at
        bestSeq = entry.seq
      }
    }
    if (bestKey !== null) return bestKey
  }

  const working = sessions.filter(({ row }) => row.state === 'working')
  const pool = working.length > 0 ? working : sessions
  let best = pool[0]
  let bestAt = best.row.stateStartedAt ?? -Infinity
  for (let i = 1; i < pool.length; i++) {
    const at = pool[i].row.stateStartedAt ?? -Infinity
    if (at > bestAt) {
      best = pool[i]
      bestAt = at
    }
  }
  return best.key
}

type Tone = 'neutral' | 'accent' | 'success' | 'warning' | 'danger'

const PRIMARY_ROLES = ['explore', 'write', 'verify'] as const

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

export function elapsed(start: number, end: number): string {
  const seconds = Math.max(0, Math.floor((end - start) / 1000))
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  if (hours > 0) return `${hours}h${minutes % 60 ? ` ${minutes % 60}m` : ''}`
  return minutes > 0 ? `${minutes}m` : `${seconds}s`
}

function renderLiveTime(since: number, now: number, className?: string): string {
  const cls = className ? ` class="${className}"` : ''
  return `<span${cls} data-time-since="${since}">${escapeHtml(elapsed(since, now))}</span>`
}

function badge(label: string, tone: Tone): string {
  return `<span class="bd badge-${tone}">${escapeHtml(label)}</span>`
}

function statusTone(status: string, task = false): Tone {
  switch (status) {
    case 'working':
    case 'in_progress':
      return 'accent'
    case 'needs you':
      return 'warning'
    case 'blocked':
      return task ? 'danger' : 'warning'
    case 'done':
    case 'completed':
    case 'succeeded':
      return 'success'
    case 'failed':
    case 'lost':
      return 'danger'
    default:
      return 'neutral'
  }
}

function orcaWorkBadge(status: string, working: boolean, needsYou = false): string {
  if (needsYou) return badge('needs you', 'warning')
  if (working) return badge('working', 'accent')
  switch (status) {
    case 'completed':
    case 'succeeded':
      return badge('done', 'success')
    case 'failed':
    case 'stopped':
    case 'abandoned':
    case 'lost':
      return badge(status, 'danger')
    case 'blocked':
      return badge(status, 'warning')
    default:
      return badge(status, 'neutral')
  }
}

function formatRunTime(start: number | null, end: number | null, active: boolean, now: number): string {
  if (start === null) return 'Time unavailable'
  if (active) return renderLiveTime(start, now)
  if (end !== null) return escapeHtml(`took ${elapsed(start, end)}`)
  return 'Time unavailable'
}

type CalloutItem = Attention & { sessionKey: string; sessionTitle: string }

function renderAttention(items: CalloutItem[], now: number, multiSession: boolean): string {
  if (items.length === 0) return ''
  const lines = items
    .map(({ sessionKey: key, sessionTitle: title, label, since }) => {
      const time = since !== null ? ` · ${renderLiveTime(since, now)}` : ''
      if (multiSession) {
        return `<button type="button" class="callout-item callout-link" data-action="selectSession" data-session="${escapeHtml(key)}">${escapeHtml(title)}: ${escapeHtml(label)}${time}</button>`
      }
      return `<div class="callout-item">${escapeHtml(label)}${time}</div>`
    })
    .join('')
  return `<div class="callout" role="alert"><div class="callout-title">⚠ Needs you</div>${lines}</div>`
}

function renderSessionState(state: Agent['state'], stateStartedAt: number | undefined, now: number): string {
  const time = stateStartedAt != null ? renderLiveTime(stateStartedAt, now, 'mu') : ''
  if (state === 'waiting' || state === 'done') {
    return `${badge('waiting for you', 'neutral')}${time}`
  }
  if (state === 'blocked') {
    return `${badge('needs you', 'warning')}${time}`
  }
  return `${badge(state, statusTone(state))}${time}`
}

function renderRoleLine(role: string, routing: OddState['roles'][string]): string {
  const parts = [routing.agent, routing.model, routing.effort].filter(Boolean).join(' · ')
  return `<div class="role-line">${escapeHtml(role)} → ${escapeHtml(parts)}</div>`
}

function renderRoles(profile: ProfileList['profiles'][number] | undefined, id: string, expanded?: ReadonlySet<string>): string {
  if (!profile) return ''
  const entries = Object.entries(profile.roles)
  if (entries.length === 0) return ''
  const primary = PRIMARY_ROLES.flatMap((name) => (profile.roles[name] ? [[name, profile.roles[name]] as const] : []))
  const rest = entries.filter(([name]) => !PRIMARY_ROLES.includes(name as (typeof PRIMARY_ROLES)[number]))
  const primaryHtml = primary.map(([name, routing]) => renderRoleLine(name, routing)).join('')
  if (rest.length === 0) return `<div class="roles-list">${primaryHtml}</div>`
  const key = `roles:${id}`
  const openAttr = expanded?.has(key) ? ' open' : ''
  const restHtml = rest.map(([name, routing]) => renderRoleLine(name, routing)).join('')
  const label = `${rest.length} more ${rest.length === 1 ? 'role' : 'roles'}`
  return `<div class="roles-list">${primaryHtml}<details data-fold="${escapeHtml(key)}"${openAttr}><summary class="fold">${escapeHtml(label)}</summary>${restHtml}</details></div>`
}

function sourceSummary(odd: OddState): string {
  if (odd.source.startsWith('session') || odd.mode_source.startsWith('session')) {
    return 'Session choice'
  }
  return 'Default profile'
}

function renderFeature(feature: FeatureDoc, id: string, expanded?: ReadonlySet<string>): string {
  const { title, path, branch, tasks } = feature
  const done = tasks.filter(({ status }) => status === 'done')
  const working = tasks.filter(({ status }) => status === 'in_progress').length
  const blocked = tasks.filter(({ status }) => status === 'blocked').length
  const pending = tasks.filter(({ status }) => status === 'pending').length
  const pct = tasks.length ? Math.round((done.length / tasks.length) * 100) : 0
  const openTasks = tasks
    .filter(({ status }) => status !== 'done')
    .map((task) => renderTaskLine(task))
    .join('')
  const doneKey = `done:${id}`
  const doneOpen = expanded?.has(doneKey) ? ' open' : ''
  const doneBlock =
    done.length > 0
      ? `<details data-fold="${escapeHtml(doneKey)}"${doneOpen}><summary class="fold">${done.length} done</summary>${done.map(renderTaskLine).join('')}</details>`
      : ''

  return [
    '<h4>Feature tasks</h4>',
    '<div class="cd">',
    `<div class="row"><strong>${escapeHtml(title)}</strong></div>`,
    `<div class="mu truncate">${escapeHtml(path)} · ${escapeHtml(branch)}</div>`,
    `<div class="pg" role="progressbar" aria-label="Feature task progress" aria-valuenow="${pct}" aria-valuemin="0" aria-valuemax="100"><i style="width:${pct}%"></i></div>`,
    `<div class="mu">${done.length} of ${tasks.length} done · ${working} working · ${blocked} blocked · ${pending} pending</div>`,
    openTasks,
    doneBlock,
    '</div>'
  ].join('')
}

function renderTaskLine(task: FeatureTask): string {
  const label = task.status === 'in_progress' ? 'working' : task.status
  const textClass = task.status === 'dropped' ? 't mu' : 't'
  return `<div class="it"><div class="l1">${badge(label, statusTone(task.status, true))}<span class="${textClass}">${escapeHtml(task.id)} · ${escapeHtml(task.work)}</span></div></div>`
}

function renderCurrentWork(current: CurrentWork, git: GitSummary | null, now: number): string {
  const tasksHtml = current.tasks
    .map((task) => {
      const working = task.status === 'dispatched'
      const time = formatRunTime(task.startedAt, task.endedAt, working, now)
      return `<div class="it"><div class="l1">${orcaWorkBadge(task.status, working)}<span class="t">${escapeHtml(task.title)}</span></div><div class="l2">${time}</div></div>`
    })
    .join('')
  const lastResult = current.lastResult
    ? `<div class="sum"><strong>Last result</strong> · ${escapeHtml(current.lastResult.title)}<br>${escapeHtml(current.lastResult.subject)}</div>`
    : ''
  const gitHtml = git ? renderGitLine(git, now) : ''
  return [
    '<h4>Current work</h4>',
    '<div class="cd">',
    `<div class="row"><strong>${escapeHtml(current.objective)}</strong></div>`,
    '<div class="mu">No feature document</div>',
    tasksHtml,
    lastResult,
    gitHtml,
    '</div>'
  ].join('')
}

function renderGitLine(git: GitSummary, now: number): string {
  const branch = git.branch ?? 'Detached HEAD'
  const files = `${git.changedFiles} changed ${git.changedFiles === 1 ? 'file' : 'files'}`
  const commit = git.lastCommit ? ` · ${escapeHtml(git.lastCommit.hash)} · ${renderLiveTime(git.lastCommit.at, now)} ago` : ''
  return `<div class="mu git-line">⎇ ${escapeHtml(branch)} · ${escapeHtml(files)}${commit}</div>`
}

function renderWorkSection(dashboard: Dashboard, id: string, ui: RenderUi): string {
  const { feature, current, git, errors } = dashboard
  if (errors.workspace) return `<div class="mu">${escapeHtml(errors.workspace)}</div>`
  if (!feature && !current && !git && !errors.feature && !errors.git) return ''
  const parts: string[] = []
  if (errors.feature) parts.push(`<div class="error-text" data-tone="danger">${escapeHtml(errors.feature)}</div>`)
  if (feature) {
    parts.push(renderFeature(feature, id, ui.expanded))
  } else if (current) {
    parts.push(renderCurrentWork(current, errors.git ? null : git, ui.now))
  }
  if (errors.git) parts.push(`<div class="error-text" data-tone="danger">${escapeHtml(errors.git)}</div>`)
  if (!feature && !current && git) parts.push(renderGitLine(git, ui.now))
  return parts.join('')
}

function renderWorkerLine(worker: WorkerRow, now: number): string {
  const time = formatRunTime(worker.startedAt, worker.endedAt, worker.active, now)
  const line2 = worker.agent ? `${escapeHtml(worker.agent)} · ${time}` : time
  return [
    '<div class="it">',
    `<div class="l1">${orcaWorkBadge(worker.state, isActiveDispatch(worker.state), worker.needsYou)}<span class="t">${escapeHtml(worker.title)}</span></div>`,
    `<div class="l2">${line2}</div>`,
    '</div>'
  ].join('')
}

function renderWorkersSection(dashboard: Dashboard, id: string, ui: RenderUi): string {
  const { workers, errors } = dashboard
  if (!workers.length && !errors.workers) return ''
  const active = workers.filter((worker) => worker.active)
  const finished = workers.filter((worker) => !worker.active)
  const visible = [...active, ...finished.slice(0, 3)]
  const earlier = finished.slice(3)
  const key = `workers:${id}`
  const openAttr = ui.expanded?.has(key) ? ' open' : ''
  const earlierHtml =
    earlier.length > 0
      ? `<details data-fold="${escapeHtml(key)}"${openAttr}><summary class="fold">${earlier.length} finished earlier</summary>${earlier.map((w) => renderWorkerLine(w, ui.now)).join('')}</details>`
      : ''

  return [
    `<h4><span>Workers</span><span>${active.length} active</span></h4>`,
    '<div class="cd">',
    errors.workers ? `<div class="error-text" data-tone="danger">${escapeHtml(errors.workers)}</div>` : '',
    visible.map((w) => renderWorkerLine(w, ui.now)).join(''),
    earlierHtml,
    '</div>'
  ].join('')
}

function renderSessionCard(
  row: State['agents'][number],
  id: string,
  title: string,
  profiles: ProfileList['profiles'],
  target: { agent: string; sessionId: string } | null,
  ui: RenderUi
): string {
  const current = typeof row.odd === 'object' && row.odd !== null ? row.odd : null
  const profile = profiles.find(({ name }) => name === current?.profile)

  let oddInfo = ''
  if (row.odd === null) {
    oddInfo = `<div class="mu">${escapeHtml(row.reason)}</div>`
  } else if (typeof row.odd === 'string') {
    oddInfo = `<div class="error-text" data-tone="danger">${escapeHtml(row.odd)}</div>`
  }

  let controls = ''
  if (isAgentKind(row.agent)) {
    const selectDisabled = ui.pending || !target || profiles.length === 0 ? ' disabled' : ''
    const actionDisabled = ui.pending || !target ? ' disabled' : ''
    const placeholder = `<option value=""${!current?.profile ? ' selected' : ''} disabled>Choose a profile</option>`
    const missingOption =
      current?.profile && !profile
        ? `<option value="${escapeHtml(current.profile)}" selected disabled>${escapeHtml(current.profile)} (not found)</option>`
        : ''
    const options = profiles
      .map(({ name }) => `<option value="${escapeHtml(name)}"${current?.profile === name ? ' selected' : ''}>${escapeHtml(name)}</option>`)
      .join('')
    const modeButtons = MODES.map((mode) => {
      const active = current?.mode === mode ? ' active' : ''
      return `<button type="button" class="seg-btn${active}" data-action="sessionMode" data-row="${escapeHtml(id)}" data-mode="${mode}"${actionDisabled}>${mode}</button>`
    }).join('')
    const sourceLine = current ? `<div class="mu" style="margin-top:6px">${escapeHtml(sourceSummary(current))}</div>` : ''
    const feedbackHtml =
      ui.feedback?.row === id
        ? `<div class="${ui.feedback.failed ? 'error-text' : 'mu'}"${ui.feedback.failed ? ' data-tone="danger"' : ''}>${escapeHtml(ui.feedback.text)}</div>`
        : ''

    controls = [
      `<label class="field-label">Profile<select class="select" data-action="use" data-row="${escapeHtml(id)}" title="Applies to the next worker launch"${selectDisabled}>${placeholder}${missingOption}${options}</select></label>`,
      renderRoles(profile, id, ui.expanded),
      '<div class="field-label">Mode</div>',
      `<div class="seg" role="group" aria-label="Mode" title="Reaches the agent on its next prompt">${modeButtons}</div>`,
      sourceLine,
      `<button type="button" class="btn-reset" data-action="clear" data-row="${escapeHtml(id)}" title="Removes this session&#39;s profile and mode choice"${actionDisabled}>Reset to defaults</button>`,
      feedbackHtml
    ].join('')
  }

  return [
    '<h4>Session</h4>',
    '<div class="cd">',
    `<div class="row"><strong class="session-title">${escapeHtml(title)}</strong><div class="row-inline">${badge(row.agent ?? 'unknown', 'neutral')}${renderSessionState(row.state, row.stateStartedAt, ui.now)}</div></div>`,
    oddInfo,
    controls,
    '</div>'
  ].join('')
}

const REFRESH_ICON = '<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13.5 8a5.5 5.5 0 1 1-1.4-3.65"/><path d="M13.5 2.5v2.75h-2.75"/></svg>'

export function render(state: State | null, ui: RenderUi): string {
  const header = `<div class="hdr"><h1>ODD Flow</h1><button type="button" class="btn-refresh" data-action="refresh" aria-label="Refresh" title="Refresh"${ui.pending ? ' disabled' : ''}>${REFRESH_ICON}</button></div>`
  if (ui.error !== null) {
    return `<div class="pn">${header}<div class="error-text" data-tone="danger">Could not load workspace state: ${escapeHtml(ui.error)}</div></div>`
  }
  if (state === null) {
    return `<div class="pn">${header}<div class="mu">Loading workspace state…</div></div>`
  }

  const profiles = typeof state.profiles === 'object' && state.profiles !== null ? state.profiles.profiles : []
  const dashboards = Object.values(state.dashboards ?? {})
  const hasWorkerDashboards = dashboards.length > 0 && dashboards.every(({ errors }) => !errors.workers)

  const topErrors = [
    'error' in state.script ? `<div class="error-text" data-tone="danger">${escapeHtml(state.script.error)}</div>` : '',
    typeof state.profiles === 'string' ? `<div class="error-text" data-tone="danger">${escapeHtml(state.profiles)}</div>` : '',
    state.workerCheckError ? `<div class="error-text" data-tone="danger">${escapeHtml(state.workerCheckError)}</div>` : ''
  ].join('')

  if (state.agents.length === 0) {
    return `<div class="pn">${header}${topErrors}<div class="empty-state">No agents in the focused workspace</div></div>`
  }

  if (state.workerCheckError) {
    const fallbacks = state.agents
      .map((row) => `<div class="worker-fallback">${escapeHtml(sessionTitle(row))} — ${escapeHtml(row.agent ?? 'unknown')} — ${escapeHtml(row.state)}</div>`)
      .join('')
    return `<div class="pn">${header}${topErrors}${fallbacks}</div>`
  }

  const indexed = state.agents.map((row, index) => ({
    row,
    index,
    key: sessionKey(row, index),
    id: `${row.terminalId ?? index}:${row.agent}:${row.sessionId}`,
    title: sessionTitle(row)
  }))
  const sessions = indexed.filter(({ row }) => !row.isWorker)

  if (sessions.length === 0) {
    const workerFallbacks = hasWorkerDashboards
      ? ''
      : indexed
          .map(({ row, title }) => `<div class="worker-fallback">${escapeHtml(title)} — ${escapeHtml(row.agent ?? 'unknown')} — ${escapeHtml(row.state)}</div>`)
          .join('')
    const empty = workerFallbacks || '<div class="empty-state">No agents in the focused workspace</div>'
    return `<div class="pn">${header}${topErrors}${empty}</div>`
  }

  const multiSession = sessions.length > 1
  const allAttention: CalloutItem[] = sessions.flatMap(({ row, key, title }) => {
    const dashboard = row.terminalId ? state.dashboards?.[row.terminalId] : undefined
    const items = dashboard?.attention ?? attentionItems(row, [])
    return items.map((item) => ({ ...item, sessionKey: key, sessionTitle: title }))
  })

  const selectorHtml = multiSession
    ? [
        '<div class="session-bar"><select class="select session-select" data-action="selectSession" aria-label="Session">',
        `<option value=""${!ui.pinnedSession ? ' selected' : ''}>Follow active session</option>`,
        ...sessions.map(
          ({ row, key, title }) =>
            `<option value="${escapeHtml(key)}"${ui.pinnedSession === key ? ' selected' : ''}>${escapeHtml(title)} · ${escapeHtml(row.agent ?? 'unknown')} · ${escapeHtml(row.state)}</option>`
        ),
        '</select></div>'
      ].join('')
    : ''

  const chosenKey =
    ui.selectedSession && sessions.some(({ key }) => key === ui.selectedSession)
      ? ui.selectedSession
      : pickFollowSession(sessions)
  const chosen = sessions.find(({ key }) => key === chosenKey) ?? sessions[0]
  const dashboard = chosen.row.terminalId ? state.dashboards?.[chosen.row.terminalId] : undefined
  const target =
    isAgentKind(chosen.row.agent) && chosen.row.sessionId?.trim() && 'path' in state.script
      ? { agent: chosen.row.agent, sessionId: chosen.row.sessionId }
      : null

  const body = [
    selectorHtml,
    renderAttention(allAttention, ui.now, multiSession),
    renderSessionCard(chosen.row, chosen.id, chosen.title, profiles, target, ui),
    dashboard ? renderWorkSection(dashboard, chosen.id, ui) : '',
    dashboard ? renderWorkersSection(dashboard, chosen.id, ui) : ''
  ].join('')

  return `<div class="pn">${header}${topErrors}${body}</div>`
}
