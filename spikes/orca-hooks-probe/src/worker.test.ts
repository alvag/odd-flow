import { setImmediate } from 'node:timers/promises'
import { assert, mountWorker, test } from 'orca/testing'
import activate from './worker'

const workspace = '/Users/max/orca/workspaces/odd-flow/orca-plugin-hooks-spike'
const tool = { agent: 'claude', terminalId: 't1', workspaceId: workspace, tool: 'Write', callId: 'call-1' }
const launch = { agent: 'claude', terminalId: 't1', workspaceId: workspace, workspaceKind: 'worktree' as const }
const prompt = { agent: 'codex', terminalId: 't1', inputKind: 'orchestration' as const }

async function fixture(rejectWrite = false) {
  const lines: string[] = []
  const worker = await mountWorker({
    default: (orca) => activate(orca, async (line: string) => {
      lines.push(line)
      if (rejectWrite) throw new Error('Simulated recording failure')
    })
  })
  return {
    worker,
    records: async () => {
      await setImmediate()
      return lines.map((line) => JSON.parse(line))
    }
  }
}

test('appends the acknowledgement without changing the start of a sentinel prompt', async () => {
  const { worker, records } = await fixture()
  try {
    const original = '# Role: explore\n\n' + 'a'.repeat(300) + 'ODD-HOOK-PROBE-PROMPT'
    const event = { ...prompt, prompt: original }
    const final = original + '\n\n## ODD hook probe\n\nEnd your final report with the line `probe-ack: ODD-HOOK-PROBE-ACK`.\n'
    assert.deepEqual(await worker.hooks.fire('agent.prompt.before', event), {
      kind: 'continue', event: { ...event, prompt: final }
    })
    const [{ ts, ...record }] = await records()
    assert.ok(Number.isFinite(Date.parse(ts)))
    assert.deepEqual(record, {
      hook: 'agent.prompt.before', decision: 'rewrite', ...prompt,
      promptLength: original.length, promptHead: original.slice(0, 60), promptTail: final.slice(-200)
    })
  } finally {
    await worker.deactivate()
  }
})

test('denies a gated tool call containing the deep deny sentinel even when rewrite also matches', async () => {
  const { worker, records } = await fixture()
  try {
    const event = {
      ...tool, workspaceId: '3cf59738-5aaf-4ce3-afb7-94bd109c0106',
      input: { nested: [{ path: '/test/odd-hook-probe-deny' }], path: 'odd-hook-probe-rewrite' }
    }
    assert.deepEqual(await worker.hooks.fire('agent.tool.before', event), {
      kind: 'deny', reason: 'ODD hook probe: denied a test-sentinel path'
    })
    const [record] = await records()
    assert.equal(record.decision, 'deny')
  } finally {
    await worker.deactivate()
  }
})

test('rewrites every gated occurrence, leaving event metadata and non-string input unchanged', async () => {
  const { worker, records } = await fixture()
  try {
    const event = {
      ...tool, workspaceId: 'prefix::43553312-15d4-4b4e-af58-4573ad6d2506::' + workspace,
      input: {
        nested: ['odd-hook-probe-rewrite/odd-hook-probe-rewrite', { path: 'odd-hook-probe-rewrite.txt' }],
        long: 'x'.repeat(201),
        untouched: [true, null, 7]
      }
    }
    assert.deepEqual(await worker.hooks.fire('agent.tool.before', event), {
      kind: 'continue',
      event: {
        ...event,
        input: { ...event.input, nested: ['odd-hook-probe-rewritten/odd-hook-probe-rewritten',
          { path: 'odd-hook-probe-rewritten.txt' }] }
      }
    })
    const [record] = await records()
    assert.equal(record.decision, 'rewrite')
    assert.deepEqual(record.inputKeys, ['nested', 'long', 'untouched'])
    assert.equal(record.input.long, 'x'.repeat(200))
  } finally {
    await worker.deactivate()
  }
})

test('adds only the gated launch variable even if recording fails', async () => {
  const { worker, records } = await fixture(true)
  try {
    const event = { ...launch, command: 'claude ' + 'x'.repeat(200), env: { EXISTING: 'not-for-logs' } }
    assert.deepEqual(await worker.hooks.fire('agent.launch.before', event), {
      kind: 'continue', event: { ...event, env: { ...event.env, ODD_HOOK_PROBE: '1' } }
    })
    const [{ ts, ...record }] = await records()
    assert.deepEqual(record, {
      hook: 'agent.launch.before', decision: 'rewrite', gated: true, ...launch, inputKind: null,
      command: event.command.slice(0, 200), envKeys: { incoming: ['EXISTING'], final: ['EXISTING', 'ODD_HOOK_PROBE'] }
    })
  } finally {
    await worker.deactivate()
  }
})

test('passes ungated tools and launches and non-sentinel prompts unchanged', async () => {
  const { worker, records } = await fixture()
  try {
    const unrecognized = { ...tool, workspaceId: 'other-workspace', input: 'odd-hook-probe-deny' }
    assert.deepEqual(await worker.hooks.fire('agent.tool.before', unrecognized), {
      kind: 'continue', event: unrecognized
    })
    const elsewhere = { ...launch, workspaceId: null, command: 'claude', env: { EXISTING: 'keep' } }
    assert.deepEqual(await worker.hooks.fire('agent.launch.before', elsewhere), {
      kind: 'continue', event: elsewhere
    })
    const ordinary = { ...prompt, prompt: 'Do not modify this prompt.' }
    assert.deepEqual(await worker.hooks.fire('agent.prompt.before', ordinary), {
      kind: 'continue', event: ordinary
    })
    const [toolRecord, launchRecord] = (await records()).map(({ ts, ...record }) => record)
    const common = { decision: 'pass', agent: 'claude', gated: false }
    assert.deepEqual(toolRecord, { ...common, hook: 'agent.tool.before', workspaceId: 'other-workspace' })
    assert.deepEqual(launchRecord, { ...common, hook: 'agent.launch.before', workspaceId: null })
  } finally {
    await worker.deactivate()
  }
})

test('records only basic metadata for non-sentinel prompts', async () => {
  const { worker, records } = await fixture()
  try {
    await worker.hooks.fire('agent.prompt.before', { ...prompt, prompt: 'Do not record this text.' })
    const [{ ts, ...record }] = await records()
    assert.ok(Number.isFinite(Date.parse(ts)))
    assert.deepEqual(record, { hook: 'agent.prompt.before', decision: 'pass', agent: 'codex' })
  } finally {
    await worker.deactivate()
  }
})
