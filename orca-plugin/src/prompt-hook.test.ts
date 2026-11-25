import type { PluginHooks } from 'orca/host'
import { assert, hostError, mockHost, mountWorker, test } from 'orca/testing'
import * as main from './worker'

type PromptEvent = PluginHooks['agent.prompt.before']['event']

async function firePrompt(prompt: string, inputKind: PromptEvent['inputKind'] = 'orchestration') {
  const event: PromptEvent = { agent: null, terminalId: 't1', inputKind, prompt }
  const host = mockHost({
    results: { 'workspace.readContext': () => { throw hostError('unavailable', 'No workspace for this test.') } }
  })
  const worker = await mountWorker(main, { host })
  try {
    return { event, decision: await worker.hooks.fire('agent.prompt.before', event) }
  } finally {
    await worker.deactivate()
  }
}

test('appends the lowercase first matching worker role without changing the original prompt', async () => {
  const original = 'Orca dispatch\r\n# Role: explore extra\r\n# rOlE: WrItE \t\r\n# Role: verify\r\nTask body\r\n'
  const { event, decision } = await firePrompt(original)
  assert.deepEqual(decision, {
    kind: 'continue', event: { ...event, prompt: original + '\n\nodd-flow-worker: write\n' }
  })
})

test('passes an orchestration prompt with no matching role line unchanged', async () => {
  const { event, decision } = await firePrompt(' # Role: write\n# Role: deploy\nTask says # Role: explore')
  assert.deepEqual(decision, { kind: 'continue', event })
})

test('passes a non-orchestration prompt unchanged even with a matching role line', async () => {
  const { event, decision } = await firePrompt('# Role: write\nTask body', 'driving')
  assert.deepEqual(decision, { kind: 'continue', event })
})

test('passes an orchestration prompt unchanged when its last non-empty line is already a marker', async () => {
  const { event, decision } = await firePrompt('# Role: write\nTask body\n  ODD-FLOW-WORKER: ReViEw \n \t\n')
  assert.deepEqual(decision, { kind: 'continue', event })
})

test('passes unknown roles and malformed role lines unchanged', async () => {
  for (const prompt of ['x\n# Role: write now', 'x\n# Role: coordinator', 'x\n# Role:write']) {
    const { event, decision } = await firePrompt(prompt)
    assert.deepEqual(decision, { kind: 'continue', event }, prompt)
  }
})

test('still appends when a marker is not on the last non-empty line', async () => {
  const original = '# Role: write\nodd-flow-worker: write\nTask body'
  const { event, decision } = await firePrompt(original)
  assert.deepEqual(decision, {
    kind: 'continue', event: { ...event, prompt: original + '\n\nodd-flow-worker: write\n' }
  })
})
