import {
  atom, Badge, Box, Button, Callout, Card, Collapsible, EmptyState, Heading, on, plugin,
  Progress, read, RelativeTime, Row, Select, set, Stack, Text, type PanelContext, type Tone
} from 'orca'
import { attentionItems, isActiveDispatch } from './dashboard'
import {
  isAgentKind, MODES, type Agent, type Attention, type CurrentWork, type Dashboard, type FeatureDoc,
  type FeatureTask, type GitSummary, type MutationResult, type State, type WorkerRow
} from './protocol'

const state = atom<State | null>(null)
const requestError = atom<string | null>(null)
const pending = atom(false)
const feedback = atom<{ row: string; text: string; failed: boolean } | null>(null)
let activeRequest: AbortController | undefined
let activeMutation: AbortController | undefined
let refreshQueued = false

function showState(answer: State) {
  set(state, answer.error ? null : answer)
  set(requestError, answer.error ?? null)
}

async function refresh(): Promise<void> {
  if (activeMutation) {
    refreshQueued = true
    return
  }
  activeRequest?.abort()
  const controller = new AbortController()
  activeRequest = controller
  set(pending, true)
  try {
    const answer = await plugin.request('state', undefined, { signal: controller.signal })
    if (!controller.signal.aborted) showState(answer)
  } catch (error) {
    if (!controller.signal.aborted) {
      set(state, null)
      set(requestError, error instanceof Error ? error.message : String(error))
    }
  } finally {
    if (activeRequest === controller) {
      activeRequest = undefined
      set(pending, false)
    }
  }
}

async function apply(
  row: string, success: string, request: (signal: AbortSignal) => Promise<MutationResult>
): Promise<void> {
  if (activeRequest || activeMutation) return
  const controller = new AbortController()
  activeMutation = controller
  set(pending, true)
  set(feedback, null)
  try {
    const answer = await request(controller.signal)
    if (controller.signal.aborted) return
    if (answer.state) {
      showState(answer.state)
      set(feedback, { row, text: success, failed: false })
    } else if (answer.workerCheckUnavailable) {
      const current = read(state)
      if (current) showState({ ...current, workerCheckError: answer.error })
    } else {
      set(feedback, { row, text: answer.error, failed: true })
    }
  } catch (error) {
    if (!controller.signal.aborted) {
      set(feedback, { row, text: error instanceof Error ? error.message : String(error), failed: true })
    }
  } finally {
    if (activeMutation === controller) {
      activeMutation = undefined
      if (refreshQueued) {
        refreshQueued = false
        void refresh()
      } else {
        set(pending, false)
      }
    }
  }
}

export function setup(ctx: PanelContext): () => void {
  ctx.subscriptions.push(on('agent.status.changed', refresh), on('workspace.changed', refresh))
  void refresh()
  return () => {
    activeRequest?.abort()
    activeMutation?.abort()
    activeRequest = undefined
    activeMutation = undefined
    refreshQueued = false
  }
}

function statusTone(status: string, task = false): Tone {
  switch (status) {
    case 'working':
    case 'in_progress': return 'accent'
    case 'needs you': return 'warning'
    case 'blocked': return task ? 'danger' : 'warning'
    case 'done':
    case 'completed':
    case 'succeeded': return 'success'
    case 'failed':
    case 'lost': return 'danger'
    default: return 'neutral'
  }
}

function OrcaWorkBadge({ status, working, needsYou = false }: { status: string; working: boolean; needsYou?: boolean }) {
  if (needsYou) return <Badge tone="warning">needs you</Badge>
  if (working) return <Badge tone="accent">working</Badge>
  switch (status) {
    case 'completed':
    case 'succeeded': return <Badge tone="success">done</Badge>
    case 'failed':
    case 'stopped':
    case 'abandoned':
    case 'lost': return <Badge tone="danger">{status}</Badge>
    case 'blocked': return <Badge tone="warning">{status}</Badge>
    default: return <Badge tone="neutral">{status}</Badge>
  }
}

function SessionState({ state, stateStartedAt }: Pick<Agent, 'state' | 'stateStartedAt'>) {
  if (state === 'waiting') {
    return (
      <Text muted>
        Waiting for you
        {stateStartedAt != null && <> · <RelativeTime at={stateStartedAt} format="duration" muted /></>}
      </Text>
    )
  }
  return (
    <>
      <Badge tone={statusTone(state)}>{state}</Badge>
      {stateStartedAt != null && <RelativeTime at={stateStartedAt} format="duration" muted />}
    </>
  )
}

function SessionAttention({ items }: { items: Attention[] }) {
  if (items.length === 0) return null
  return (
    <Callout title="Needs you" tone="warning">
      <Stack gap="xs">
        {items.map(({ label, since }, index) => (
          <Text key={index}>
            {label}{since !== null && <> · <RelativeTime at={since} format="duration" /></>}
          </Text>
        ))}
      </Stack>
    </Callout>
  )
}

function elapsed(start: number, end: number): string {
  const seconds = Math.max(0, Math.floor((end - start) / 1000))
  const minutes = Math.floor(seconds / 60)
  const hours = Math.floor(minutes / 60)
  if (hours > 0) return `${hours}h${minutes % 60 ? ` ${minutes % 60}m` : ''}`
  return minutes > 0 ? `${minutes}m` : `${seconds}s`
}

function RunTime({ start, end, active, agent }: {
  start: number | null; end: number | null; active: boolean; agent?: string | null
}) {
  return (
    <Text muted size="sm" truncate>
      {agent && `${agent} · `}
      {start === null ? 'Time unavailable'
        : active ? <RelativeTime at={start} format="duration" muted />
        : end !== null ? `took ${elapsed(start, end)}` : 'Time unavailable'}
    </Text>
  )
}

function TaskLine({ task }: { task: FeatureTask }) {
  return (
    <Row gap="xs" align="center">
      <Badge tone={statusTone(task.status, true)}>{task.status === 'in_progress' ? 'working' : task.status}</Badge>
      <Text truncate muted={task.status === 'dropped'}>{task.id} · {task.work}</Text>
    </Row>
  )
}

function FeatureSection({ feature }: { feature: FeatureDoc }) {
  const { title, path, branch, tasks } = feature
  const done = tasks.filter(({ status }) => status === 'done')
  const working = tasks.filter(({ status }) => status === 'in_progress').length
  const blocked = tasks.filter(({ status }) => status === 'blocked').length
  const pending = tasks.filter(({ status }) => status === 'pending').length
  return (
    <Stack gap="xs">
      <Heading level={2}>Feature tasks</Heading>
      <Text weight="semibold">{title}</Text>
      <Text muted truncate>{path} · {branch}</Text>
      <Progress label="Feature task progress" labelHidden value={tasks.length ? done.length / tasks.length * 100 : 0} />
      <Text>{done.length} of {tasks.length} done · {working} working · {blocked} blocked · {pending} pending</Text>
      {tasks.filter(({ status }) => status !== 'done').map((task) => <TaskLine key={task.id} task={task} />)}
      {done.length > 0 && (
        <Collapsible title={`${done.length} done`}>
          <Stack gap="xs">{done.map((task) => <TaskLine key={task.id} task={task} />)}</Stack>
        </Collapsible>
      )}
    </Stack>
  )
}

function CurrentSection({ current }: { current: CurrentWork }) {
  return (
    <Stack gap="xs">
      <Heading level={2}>Current work</Heading>
      <Text weight="semibold">{current.objective}</Text>
      <Text muted>No feature document</Text>
      {current.tasks.map((task, index) => (
        <Stack gap="none" key={index}>
          <Row gap="xs" align="center">
            <OrcaWorkBadge status={task.status} working={task.status === 'dispatched'} />
            <Text truncate>{task.title}</Text>
          </Row>
          <RunTime start={task.startedAt} end={task.endedAt} active={task.status === 'dispatched'} />
        </Stack>
      ))}
      {current.lastResult && (
        <Stack gap="none">
          <Heading level={3}>Last result</Heading>
          <Text>{current.lastResult.title} · {current.lastResult.subject}</Text>
        </Stack>
      )}
    </Stack>
  )
}

function GitLine({ git }: { git: GitSummary }) {
  return (
    <Text muted size="sm">
      {git.branch ?? 'Detached HEAD'} · {git.changedFiles} changed {git.changedFiles === 1 ? 'file' : 'files'}
      {git.lastCommit && <> · {git.lastCommit.hash} · <RelativeTime at={git.lastCommit.at} format="short" muted /></>}
    </Text>
  )
}

function WorkSection({ dashboard }: { dashboard: Dashboard }) {
  const { feature, current, git, errors } = dashboard
  if (errors.workspace) return <Text muted>{errors.workspace}</Text>
  if (!feature && !current && !git && !errors.feature && !errors.git) return null
  return (
    <Stack gap="xs">
      {errors.feature && <Text tone="danger">{errors.feature}</Text>}
      {feature ? <FeatureSection feature={feature} /> : current && <CurrentSection current={current} />}
      {errors.git && <Text tone="danger">{errors.git}</Text>}
      {!feature && git && <GitLine git={git} />}
    </Stack>
  )
}

function WorkerLine({ worker }: { worker: WorkerRow }) {
  return (
    <Stack gap="none">
      <Box direction="row" gap="xs" align="center" wrap={false}>
        <Box shrink={false}>
          <OrcaWorkBadge status={worker.state} working={isActiveDispatch(worker.state)} needsYou={worker.needsYou} />
        </Box>
        <Box grow minWidth={0}><Text truncate>{worker.title}</Text></Box>
      </Box>
      <RunTime agent={worker.agent} start={worker.startedAt} end={worker.endedAt} active={worker.active} />
    </Stack>
  )
}

function WorkersSection({ dashboard }: { dashboard: Dashboard }) {
  const { workers, errors } = dashboard
  if (!workers.length && !errors.workers) return null
  const active = workers.filter((worker) => worker.active)
  const finished = workers.filter((worker) => !worker.active)
  const earlier = finished.slice(3)
  return (
    <Stack gap="xs">
      <Row justify="between" align="center">
        <Heading level={2}>Workers</Heading>
        <Text muted>{active.length} active</Text>
      </Row>
      {errors.workers && <Text tone="danger">{errors.workers}</Text>}
      {[...active, ...finished.slice(0, 3)].map((worker) => <WorkerLine key={worker.dispatchId} worker={worker} />)}
      {earlier.length > 0 && (
        <Collapsible title={`${earlier.length} finished earlier`}>
          <Stack gap="xs">{earlier.map((worker) => <WorkerLine key={worker.dispatchId} worker={worker} />)}</Stack>
        </Collapsible>
      )}
    </Stack>
  )
}

export default function Panel() {
  const answer = read(state)
  const error = read(requestError)
  const busy = read(pending)
  const result = read(feedback)
  const profiles = typeof answer?.profiles === 'object' ? answer.profiles?.profiles ?? [] : []
  const dashboards = Object.values(answer?.dashboards ?? {})
  const hasWorkerDashboards = dashboards.length > 0 && dashboards.every(({ errors }) => !errors.workers)
  return (
    <Stack gap="md">
      <Row justify="between" wrap>
        <Heading>odd-flow profiles</Heading>
        <Button onPress={refresh} disabled={busy}>Refresh</Button>
      </Row>
      {error !== null && <Text tone="danger">Could not load workspace state: {error}</Text>}
      {answer === null && error === null && <Text muted>Loading workspace state…</Text>}
      {answer !== null && (
        <Stack gap="md">
          {'error' in answer.script && <Text tone="danger">{answer.script.error}</Text>}
          {typeof answer.profiles === 'string' && <Text tone="danger">{answer.profiles}</Text>}
          <Stack gap="sm">
            <Heading level={2}>Workspace agents</Heading>
            {answer.workerCheckError && <Text tone="danger">{answer.workerCheckError}</Text>}
            {answer.agents.length === 0 && <EmptyState title="No agents in the focused workspace" />}
            {answer.agents.map((row, index) => {
              const { agent, sessionId } = row
              const id = `${row.terminalId ?? index}:${agent}:${sessionId}`
              const title = row.task?.title ?? row.title ?? row.terminalId ?? 'Untitled'
              if (row.isWorker || answer.workerCheckError) {
                if (row.isWorker && hasWorkerDashboards && !answer.workerCheckError) return null
                return <Text key={id} weight="semibold">{title} — {agent ?? 'unknown'} — {row.state}</Text>
              }
              const dashboard = row.terminalId ? answer.dashboards?.[row.terminalId] : undefined
              const current = typeof row.odd === 'object' ? row.odd : null
              const profile = profiles.find(({ name }) => name === current?.profile)
              const target = isAgentKind(agent) && sessionId?.trim() && 'path' in answer.script
                ? { agent, sessionId } : null
              return (
                <Stack key={id} gap="sm">
                  <SessionAttention items={dashboard?.attention ?? attentionItems(row, [])} />
                  <Card title={title}>
                    <Stack gap="xs">
                      <Row gap="xs" align="center" wrap>
                        <Badge tone="neutral">{agent ?? 'unknown'}</Badge>
                        <SessionState state={row.state} stateStartedAt={row.stateStartedAt} />
                      </Row>
                      {row.odd === null ? <Text muted>{row.reason}</Text>
                        : typeof row.odd === 'string' ? <Text tone="danger">{row.odd}</Text>
                        : (
                          <Stack gap="xs">
                            <Text muted>Profile: {row.odd.profile ?? 'none'} ({row.odd.source})</Text>
                            <Text muted>Mode: {row.odd.mode} ({row.odd.mode_source})</Text>
                          </Stack>
                        )}
                      {isAgentKind(agent) && (
                        <Stack gap="xs">
                          <Select label="Profile" value={current?.profile ?? ''}
                            placeholder="Choose a profile"
                            options={profiles.map(({ name }) => ({ value: name, label: name }))}
                            disabled={busy || !target || profiles.length === 0}
                            onChange={(profile) => {
                              if (!target) return
                              return apply(id, 'Profile switched.', (signal) =>
                                plugin.request('use', { ...target, profile }, { signal }))
                            }} />
                          {profile && Object.entries(profile.roles).map(([role, routing]) => (
                            <Text key={role} muted size="sm">
                              {role} → {[routing.agent, routing.model, routing.effort].filter(Boolean).join(' · ')}
                            </Text>
                          ))}
                          <Text weight="medium">Mode</Text>
                          <Row gap="xs" wrap>
                            {MODES.map((mode) => (
                              <Button key={mode} size="sm" variant={current?.mode === mode ? 'solid' : 'outline'}
                                disabled={busy || !target} onPress={() => {
                                  if (!target) return
                                  return apply(id, 'Mode switched.', (signal) =>
                                    plugin.request('sessionMode', { ...target, mode }, { signal }))
                                }}>{mode}</Button>
                            ))}
                          </Row>
                          <Button disabled={busy || !target} onPress={() => {
                            if (!target) return
                            return apply(id, 'Session choices reset.', (signal) =>
                              plugin.request('clear', target, { signal }))
                          }}>Reset to defaults</Button>
                          <Text muted>Removes this session's profile and mode choice. The default profile and its mode apply again.</Text>
                          <Text muted>A profile switch applies to the next worker launch and drops the session mode override.</Text>
                          <Text muted>A mode switch reaches the agent on its next prompt.</Text>
                          {result?.row === id && <Text tone={result.failed ? 'danger' : undefined}>{result.text}</Text>}
                        </Stack>
                      )}
                    </Stack>
                  </Card>
                  {dashboard && <WorkSection dashboard={dashboard} />}
                  {dashboard && <WorkersSection dashboard={dashboard} />}
                </Stack>
              )
            })}
          </Stack>
        </Stack>
      )}
    </Stack>
  )
}
