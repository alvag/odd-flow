import {
  atom, Button, EmptyState, Heading, on, plugin, read, Row, set, Stack, Text,
  type PanelContext
} from 'orca'
import type { State } from './protocol'

const state = atom<State | null>(null)
const requestError = atom<string | null>(null)
let activeRequest: AbortController | undefined

async function refresh(): Promise<void> {
  activeRequest?.abort()
  const controller = new AbortController()
  activeRequest = controller
  try {
    const answer = await plugin.request('state', undefined, { signal: controller.signal })
    if (!controller.signal.aborted) {
      set(state, answer)
      set(requestError, null)
    }
  } catch (error) {
    if (!controller.signal.aborted) {
      set(state, null)
      set(requestError, error instanceof Error ? error.message : String(error))
    }
  }
}

export function setup(ctx: PanelContext): () => void {
  ctx.subscriptions.push(on('agent.status.changed', refresh), on('workspace.changed', refresh))
  void refresh()
  return () => activeRequest?.abort()
}

export default function Panel() {
  const answer = read(state)
  const error = read(requestError)
  return (
    <Stack gap="md">
      <Row justify="between" wrap>
        <Heading>odd-flow profiles</Heading>
        <Button onPress={refresh}>Refresh</Button>
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
            {answer.agents.length === 0 && <EmptyState title="No agents in the focused workspace" />}
            {answer.agents.map((row, index) => (
              <Stack key={row.terminalId ?? `${row.agent}:${row.sessionId}:${index}`} gap="xs">
                <Text weight="semibold">{row.title ?? row.terminalId ?? 'Untitled'} — {row.agent ?? 'unknown'} — {row.state}</Text>
                {row.odd === null ? <Text muted>{row.reason}</Text>
                  : typeof row.odd === 'string' ? <Text tone="danger">{row.odd}</Text>
                  : (
                    <Stack gap="xs">
                      <Text>Profile: {row.odd.profile ?? 'none'} ({row.odd.source})</Text>
                      <Text>Mode: {row.odd.mode} ({row.odd.mode_source})</Text>
                    </Stack>
                  )}
              </Stack>
            ))}
          </Stack>
        </Stack>
      )}
    </Stack>
  )
}
