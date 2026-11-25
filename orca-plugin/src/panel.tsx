import {
  atom, Button, EmptyState, Heading, on, plugin, read, Row, Select, set, Stack, Text,
  type PanelContext
} from 'orca'
import { isAgentKind, isMode, MODES, type MutationResult, type State } from './protocol'

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

export default function Panel() {
  const answer = read(state)
  const error = read(requestError)
  const busy = read(pending)
  const result = read(feedback)
  const profiles = typeof answer?.profiles === 'object' ? answer.profiles?.profiles ?? [] : []
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
          {'path' in answer.script
            ? <Text>Script: {answer.script.path} ({answer.script.source})</Text>
            : <Text tone="danger">{answer.script.error}</Text>}
          <Stack gap="xs">
            <Heading level={2}>Profiles</Heading>
            {typeof answer.profiles === 'string'
              ? <Text tone="danger">{answer.profiles}</Text>
              : answer.profiles?.profiles.length
                ? answer.profiles.profiles.map((profile) => (
                    <Text key={profile.name}>{profile.name}{profile.default ? ' (default)' : ''} — {profile.mode}</Text>
                  ))
                : <Text muted>{answer.profiles === null ? 'Profiles unavailable.' : 'No saved profiles.'}</Text>}
          </Stack>
          <Stack gap="sm">
            <Heading level={2}>Workspace agents</Heading>
            {answer.workerCheckError && <Text tone="danger">{answer.workerCheckError}</Text>}
            {answer.agents.length === 0 && <EmptyState title="No agents in the focused workspace" />}
            {answer.agents.map((row, index) => {
              const { agent, sessionId } = row
              const id = `${row.terminalId ?? index}:${agent}:${sessionId}`
              const title = row.task?.title ?? row.title ?? row.terminalId ?? 'Untitled'
              const header = <Text weight="semibold">{title} — {agent ?? 'unknown'} — {row.state}</Text>
              if (row.isWorker || answer.workerCheckError) return <Stack key={id} gap="xs">{header}</Stack>
              const current = typeof row.odd === 'object' ? row.odd : null
              const target = isAgentKind(agent) && sessionId?.trim() && 'path' in answer.script
                ? { agent, sessionId } : null
              return (
                <Stack key={id} gap="xs">
                  {header}
                  {row.odd === null ? <Text muted>{row.reason}</Text>
                    : typeof row.odd === 'string' ? <Text tone="danger">{row.odd}</Text>
                    : (
                      <Stack gap="xs">
                        <Text>Profile: {row.odd.profile ?? 'none'} ({row.odd.source})</Text>
                        <Text>Mode: {row.odd.mode} ({row.odd.mode_source})</Text>
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
                      <Select label="Mode" value={current?.mode ?? ''}
                        placeholder="Choose a mode"
                        options={MODES.map((mode) => ({ value: mode, label: mode }))}
                        disabled={busy || !target}
                        onChange={(mode) => {
                          if (!target || !isMode(mode)) return
                          return apply(id, 'Mode switched.', (signal) =>
                            plugin.request('sessionMode', { ...target, mode }, { signal }))
                        }} />
                      <Button disabled={busy || !target} onPress={() => {
                        if (!target) return
                        return apply(id, 'Session binding cleared.', (signal) =>
                          plugin.request('clear', target, { signal }))
                      }}>Clear session binding</Button>
                      <Text muted>A profile switch applies to the next worker launch and drops the session mode override.</Text>
                      <Text muted>A mode switch reaches the agent on its next prompt.</Text>
                      {result?.row === id && <Text tone={result.failed ? 'danger' : undefined}>{result.text}</Text>}
                    </Stack>
                  )}
                </Stack>
              )
            })}
          </Stack>
        </Stack>
      )}
    </Stack>
  )
}
