import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { PluginHooks } from 'orca/host'
import { assert, hostError, mockHost, mountWorker, test } from 'orca/testing'
import { promptWithWorkerMarker } from './prompt-hook'
import * as main from './worker'

type PromptEvent = PluginHooks['agent.prompt.before']['event']
const TOKEN = '0123456789abcdef'.repeat(2)
const NOW = 1_800_000_000_000
const LIFETIME = 15 * 60 * 1000

function promptEvent(prompt: string, inputKind: PromptEvent['inputKind'] = 'orchestration'): PromptEvent {
  return { agent: null, terminalId: 't1', inputKind, prompt }
}

function fixture(t: { after: (cleanup: () => void) => void }) {
  const stateDir = mkdtempSync(join(tmpdir(), 'odd-flow-prompt-test-'))
  t.after(() => rmSync(stateDir, { recursive: true, force: true }))
  const dir = join(stateDir, 'worker-tokens')
  const issue = (prompt: string) => promptWithWorkerMarker(promptEvent(prompt), {
    stateDir, now: () => NOW, randomBytes: (size: number) => Buffer.from(TOKEN.slice(0, size * 2), 'hex')
  })
  return { stateDir, dir, issue }
}

function recordName(token: string) {
  return createHash('sha256').update(token, 'ascii').digest('hex')
}

async function firePrompt(stateDir: string, prompt: string, inputKind?: PromptEvent['inputKind']) {
  const event = promptEvent(prompt, inputKind)
  const host = mockHost({
    results: { 'workspace.readContext': () => { throw hostError('unavailable', 'No workspace for this test.') } }
  })
  const previous = process.env.ODD_FLOW_STATE_DIR
  process.env.ODD_FLOW_STATE_DIR = stateDir
  try {
    const worker = await mountWorker(main, { host })
    try {
      return { event, decision: await worker.hooks.fire('agent.prompt.before', event) }
    } finally {
      await worker.deactivate()
    }
  } finally {
    if (previous === undefined) delete process.env.ODD_FLOW_STATE_DIR
    else process.env.ODD_FLOW_STATE_DIR = previous
  }
}

test('appends the lowercase first matching role and token after writing its private record', async (t) => {
  const { stateDir, dir } = fixture(t)
  const original = 'Orca dispatch\r\n# Role: explore extra\r\n# rOlE: WrItE \t\r\n# Role: verify\r\nTask body\r\n'
  const before = Date.now()
  const { event, decision } = await firePrompt(stateDir, original)
  if (decision.kind !== 'continue') throw new Error(`Expected continue, got ${decision.kind}`)
  const token = /\nodd-flow-worker: write ([0-9a-f]{32})\n$/.exec(decision.event.prompt)?.[1]
  if (token === undefined) throw new Error('Expected a 32-digit lowercase hexadecimal token')
  assert.deepEqual(decision, {
    kind: 'continue', event: { ...event, prompt: original + `\n\nodd-flow-worker: write ${token}\n` }
  })
  const name = recordName(token)
  assert.deepEqual(readdirSync(dir), [name])
  assert.equal(statSync(dir).mode & 0o777, 0o700)
  const path = join(dir, name)
  assert.equal(statSync(path).mode & 0o777, 0o600)
  const record = JSON.parse(readFileSync(path, 'utf8'))
  assert.deepEqual(record, { role: 'write', issuedAt: record.issuedAt })
  assert.equal(Number.isInteger(record.issuedAt) && record.issuedAt >= before && record.issuedAt <= Date.now(), true)
})

test('passes unchanged and creates no record when the record write fails', (t) => {
  const { dir, issue } = fixture(t)
  mkdirSync(dir, { mode: 0o700 })
  mkdirSync(join(dir, recordName(TOKEN)))
  assert.equal(issue('# Role: write\nTask body'), undefined)
  assert.equal(statSync(join(dir, recordName(TOKEN))).isDirectory(), true)
  assert.deepEqual(readdirSync(dir), [recordName(TOKEN)])
})

test('passes an orchestration prompt with no matching role line unchanged', async (t) => {
  const { stateDir, dir } = fixture(t)
  const { event, decision } = await firePrompt(stateDir, ' # Role: write\n# Role: deploy\nTask says # Role: explore')
  assert.deepEqual(decision, { kind: 'continue', event })
  assert.equal(existsSync(dir), false)
})

test('passes a non-orchestration prompt unchanged even with a matching role line', async (t) => {
  const { stateDir, dir } = fixture(t)
  const { event, decision } = await firePrompt(stateDir, '# Role: write\nTask body', 'driving')
  assert.deepEqual(decision, { kind: 'continue', event })
  assert.equal(existsSync(dir), false)
})

test('passes an orchestration prompt unchanged when its last non-empty line is already a tokened marker', async (t) => {
  const { stateDir, dir } = fixture(t)
  const { event, decision } = await firePrompt(stateDir, `# Role: write\nTask body\n  ODD-FLOW-WORKER: ReViEw ${TOKEN} \n \t\n`)
  assert.deepEqual(decision, { kind: 'continue', event })
  assert.equal(existsSync(dir), false)
})

test('passes unknown roles and malformed role lines unchanged', async (t) => {
  const { stateDir } = fixture(t)
  for (const prompt of ['x\n# Role: write now', 'x\n# Role: coordinator', 'x\n# Role:write']) {
    const { event, decision } = await firePrompt(stateDir, prompt)
    assert.deepEqual(decision, { kind: 'continue', event }, prompt)
  }
})

test('still appends when a tokened marker is not on the last non-empty line', (t) => {
  const original = `# Role: write\nodd-flow-worker: write ${'a'.repeat(32)}\nTask body`
  const { issue } = fixture(t)
  assert.equal(issue(original), original + `\n\nodd-flow-worker: write ${TOKEN}\n`)
})

test('appends a tokened marker even when a bare marker is already last', (t) => {
  const original = '# Role: write\nTask body\nodd-flow-worker: write'
  const { issue } = fixture(t)
  assert.equal(issue(original), original + `\n\nodd-flow-worker: write ${TOKEN}\n`)
})

test('prunes older numeric timestamps on issuance but keeps cutoff and malformed records', (t) => {
  const { dir, issue } = fixture(t)
  mkdirSync(dir, { mode: 0o700 })
  const expired = recordName('a'.repeat(32))
  const cutoff = recordName('b'.repeat(32))
  const malformed = recordName('c'.repeat(32))
  for (const [name, issuedAt] of [
    [expired, NOW - LIFETIME - 1],
    [cutoff, NOW - LIFETIME],
    [malformed, String(NOW - LIFETIME - 1)]
  ] as const) {
    writeFileSync(join(dir, name), JSON.stringify({ role: 'write', issuedAt }), { mode: 0o600 })
  }
  issue('# Role: write\nTask body')
  assert.deepEqual(readdirSync(dir).sort(), [cutoff, malformed, recordName(TOKEN)].sort())
})
