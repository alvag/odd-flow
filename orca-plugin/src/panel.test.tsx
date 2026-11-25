import { assert, mockHost, mount, test } from 'orca/testing'
import * as panel from './panel'

test('shows the focused agents, profile sources, errors, and refreshes on demand and host events', async () => {
  let requests = 0
  const host = mockHost({
    capabilities: ['agent:read', 'workspace:read'],
    requests: {
      state: () => {
        requests++
        return {
          script: { path: '/settings/profile.py', source: 'profileScript setting' },
          profiles: {
            path: '/profiles.json', default: 'team',
            profiles: [{ name: 'team', mode: 'full-delegation', default: true, roles: {} }]
          },
          agents: [{
            terminalId: 'one', title: 'Runner', agent: 'codex', state: 'working', sessionId: 'sid',
            odd: {
              profile: 'team', source: 'session (CODEX_THREAD_ID)', mode: 'full-delegation',
              mode_source: 'profile team', session_key: 'CODEX_THREAD_ID', agent: 'codex',
              orca_terminal: null, roles: {}, rules: 'references/mode-full-delegation.md'
            }
          }, {
            terminalId: 'two', title: 'Other runner', agent: 'claude', state: 'waiting', sessionId: null,
            odd: null, reason: 'No session ID reported.'
          }]
        }
      }
    }
  })
  const view = await mount(panel, { host })
  try {
    for (const text of [/profile\.py.*profileScript setting/, /Runner.*codex.*working/,
      /team.*session \(CODEX_THREAD_ID\)/, /full-delegation.*profile team/, /team.*default/, /No session ID/]) {
      assert.ok(view.find({ text }), String(text))
    }
    const before = requests
    await view.press({ text: 'Refresh' })
    assert.equal(requests, before + 1)
    await view.emit('agent.status.changed', {
      workspaceId: null, terminalId: 'one', paneKey: 'one', state: 'waiting', receivedAt: 0
    })
    assert.equal(requests, before + 2)
    await view.emit('workspace.changed', { context: null })
    assert.equal(requests, before + 3)
    assert.deepEqual(view.errors, [])
    assert.deepEqual(view.refusals, [])
  } finally {
    await view.unmount()
  }
})
