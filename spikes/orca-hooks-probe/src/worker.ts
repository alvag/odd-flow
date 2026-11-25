import { appendFile, mkdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonValue, PluginHooks } from 'orca/host'
import type { HookContinue, OrcaWorkerApi } from 'orca/worker'

const WORKSPACE_IDS = [
  '/Users/max/orca/workspaces/odd-flow/orca-plugin-hooks-spike',
  '3cf59738-5aaf-4ce3-afb7-94bd109c0106',
  '43553312-15d4-4b4e-af58-4573ad6d2506::/Users/max/orca/workspaces/odd-flow/orca-plugin-hooks-spike'
] as const
const PROMPT_SENTINEL = 'ODD-HOOK-PROBE-PROMPT'
const PROMPT_SUFFIX = '\n\n## ODD hook probe\n\nEnd your final report with the line `probe-ack: ODD-HOOK-PROBE-ACK`.\n'
const DENY_SENTINEL = 'odd-hook-probe-deny'
const REWRITE_SENTINEL = 'odd-hook-probe-rewrite'

type Hook = 'agent.prompt.before' | 'agent.tool.before' | 'agent.tool.after' | 'agent.launch.before'
type Event<H extends Hook> = PluginHooks[H]['event']
type Stop<H extends Hook> = PluginHooks[H]['result']
type Decision<H extends Hook> =
  | { kind: 'pass' }
  | { kind: 'rewrite'; event: Event<H> }
  | { kind: 'deny'; result: Stop<H> }
type Write = (line: string) => Promise<void> | void

function isGated(workspaceId: unknown): boolean {
  return typeof workspaceId === 'string' && workspaceId.length > 0 &&
    WORKSPACE_IDS.some((id) => workspaceId.includes(id))
}

function hasSentinel(input: JsonValue, sentinel: string): boolean {
  if (typeof input === 'string') return input.includes(sentinel)
  if (input === null || typeof input !== 'object') return false
  return Object.values(input).some((value) => hasSentinel(value, sentinel))
}

function mapStrings(input: JsonValue, map: (value: string) => string, excerptsOnly = false): JsonValue {
  if (typeof input === 'string') return map(input)
  if (Array.isArray(input)) return input.map((value) => mapStrings(value, map, excerptsOnly))
  if (input !== null && typeof input === 'object') {
    return Object.fromEntries(Object.entries(input).map(([key, value]) => [key, mapStrings(value, map, excerptsOnly)]))
  }
  return excerptsOnly ? null : input
}

function jsonType(value: JsonValue | undefined): string {
  if (Array.isArray(value)) return 'array'
  return value === null ? 'null' : typeof value
}

function workspaceMetadata(event: {
  workspaceId: string | null
  terminalId?: string
  workspaceKind?: 'worktree' | 'folder' | null
  inputKind?: string
}, gated: boolean) {
  return {
    workspaceId: event.workspaceId,
    gated,
    ...(gated && {
      terminalId: event.terminalId ?? null,
      workspaceKind: event.workspaceKind ?? null,
      inputKind: event.inputKind ?? null
    })
  }
}

function toolDetails(event: Event<'agent.tool.before'>) {
  return {
    tool: event.tool,
    callId: event.callId ?? null,
    inputKeys: event.input !== null && typeof event.input === 'object' ? Object.keys(event.input) : [],
    input: mapStrings(event.input, (value) => value.slice(0, 200), true)
  }
}

async function writeRecord(line: string): Promise<void> {
  console.log(line)
  const directory = join(tmpdir(), 'odd-flow-hooks-probe')
  await mkdir(directory, { recursive: true, mode: 0o700 })
  await appendFile(join(directory, 'events.jsonl'), line + '\n', { encoding: 'utf8', mode: 0o600 })
}

export default function activate(orca: OrcaWorkerApi, write: Write = writeRecord): void {
  async function record(build: () => object): Promise<void> {
    // Keep even record construction off the hook's decision path.
    await Promise.resolve()
    try {
      await write(JSON.stringify(build()))
    } catch {
      // Recording is best effort and never affects the hook decision.
    }
  }

  function register<H extends Hook>(
    hook: H,
    decide: (event: Event<H>, gated: boolean) => Decision<H>,
    details: (event: Event<H>, gated: boolean, decision: Decision<H>) => object
  ): void {
    orca.hooks.on(hook, (event, next) => {
      let gated = false
      let decision: Decision<H> = { kind: 'pass' }
      let result: HookContinue | Stop<H> | undefined
      try {
        gated = isGated('workspaceId' in event ? event.workspaceId : null)
        decision = decide(event, gated)
        if (decision.kind === 'rewrite') result = next(decision.event)
        if (decision.kind === 'deny') result = decision.result
      } catch {
        decision = { kind: 'pass' }
      }
      void record(() => ({
        ts: new Date().toISOString(), hook, decision: decision.kind, agent: event.agent,
        ...details(event, gated, decision)
      }))
      return result
    })
  }

  register('agent.prompt.before', (event) => event.prompt.includes(PROMPT_SENTINEL)
    ? { kind: 'rewrite', event: { ...event, prompt: event.prompt + PROMPT_SUFFIX } }
    : { kind: 'pass' }, (event, _gated, decision) => {
    if (!event.prompt.includes(PROMPT_SENTINEL)) return {}
    const final = decision.kind === 'rewrite' ? decision.event.prompt : event.prompt
    return {
      terminalId: event.terminalId,
      inputKind: event.inputKind,
      promptLength: event.prompt.length,
      promptHead: event.prompt.slice(0, 60),
      promptTail: final.slice(-200)
    }
  })

  register('agent.tool.before', (event, gated) => {
    if (!gated) return { kind: 'pass' }
    if (hasSentinel(event.input, DENY_SENTINEL)) {
      return { kind: 'deny', result: { deny: 'ODD hook probe: denied a test-sentinel path' } }
    }
    if (!hasSentinel(event.input, REWRITE_SENTINEL)) return { kind: 'pass' }
    const input = mapStrings(event.input, (value) => value.replaceAll(REWRITE_SENTINEL, 'odd-hook-probe-rewritten'))
    return { kind: 'rewrite', event: { ...event, input } }
  }, (event, gated) => ({
    ...workspaceMetadata(event, gated),
    ...(gated && toolDetails(event))
  }))

  register('agent.tool.after', () => ({ kind: 'pass' }), (event, gated) => ({
    ...workspaceMetadata(event, gated),
    ...(gated && {
      ...toolDetails(event),
      outputType: jsonType(event.output),
      outputLength: JSON.stringify(event.output)?.length ?? 0
    })
  }))

  register('agent.launch.before', (event, gated) => gated
    ? { kind: 'rewrite', event: { ...event, env: { ...event.env, ODD_HOOK_PROBE: '1' } } }
    : { kind: 'pass' }, (event, gated, decision) => ({
    ...workspaceMetadata(event, gated),
    ...(gated && {
      command: event.command.slice(0, 200),
      envKeys: {
        incoming: Object.keys(event.env),
        final: Object.keys(decision.kind === 'rewrite' ? decision.event.env : event.env)
      }
    })
  }))
}
