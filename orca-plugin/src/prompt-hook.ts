import { createHash, randomBytes } from 'node:crypto'
import { closeSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import type { PluginHooks } from 'orca/host'

type PromptEvent = PluginHooks['agent.prompt.before']['event']
type TokenOptions = {
  stateDir?: string; now?: () => number; randomBytes?: (size: number) => Buffer; log?: (message: string) => void
}
const ROLE_LINE = /^# Role: (explore|write|verify|review|refute)$/i
const MARKER_LINE = /^odd-flow-worker: (?:explore|write|verify|review|refute) ([0-9a-f]{32})$/i
const TOKEN_LIFETIME_MS = 15 * 60 * 1000

function pruneRecords(dir: string, cutoff: number): void {
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isFile() || !/^[0-9a-f]{64}$/.test(entry.name)) continue
      const path = join(dir, entry.name)
      try {
        const record = JSON.parse(readFileSync(path, 'utf8'))
        if (typeof record?.issuedAt === 'number' && record.issuedAt < cutoff) unlinkSync(path)
      } catch {
        // A consumer may already have removed the record. Pruning is best-effort.
      }
    }
  } catch {
    // Failure to list old records does not invalidate the newly issued record.
  }
}

function issueToken(role: string, options: TokenOptions): string | undefined {
  let dir: string | undefined
  function fail(reason: string): undefined {
    try {
      options.log?.(`Worker token issuance failed: role=${role}; ${reason}; directory=${JSON.stringify(dir ?? '~/.odd-flow/worker-tokens')}`)
    } catch {
      // Diagnostics must not affect prompt delivery.
    }
  }

  try {
    const stateDir = options.stateDir || join(homedir(), '.odd-flow')
    dir = join(stateDir, 'worker-tokens')
    if (!isAbsolute(stateDir)) return fail('state directory must be absolute')

    mkdirSync(dir, { recursive: true, mode: 0o700 })
    const directory = lstatSync(dir)
    if (!directory.isDirectory()) return fail('worker-tokens must be a real directory')
    if ((directory.mode & 0o7777) !== 0o700) return fail('worker-tokens must have mode 0700')
    if (typeof process.getuid === 'function' && directory.uid !== process.getuid()) {
      return fail('worker-tokens must be owned by the running user')
    }

    const issuedAt = (options.now ?? Date.now)()
    const token = (options.randomBytes ?? randomBytes)(16).toString('hex')
    const path = join(dir, createHash('sha256').update(token, 'ascii').digest('hex'))
    const fd = openSync(path, 'wx', 0o600)
    try {
      try {
        writeFileSync(fd, JSON.stringify({ role, issuedAt }))
      } finally {
        closeSync(fd)
      }
    } catch (error) {
      // Only remove a partial record that this call created exclusively.
      try { unlinkSync(path) } catch { /* best-effort cleanup */ }
      throw error
    }
    pruneRecords(dir, issuedAt - TOKEN_LIFETIME_MS)
    return token
  } catch {
    return fail('could not save token record')
  }
}

export function promptWithWorkerMarker({ inputKind, prompt }: PromptEvent, options: TokenOptions = {}): string | undefined {
  if (inputKind !== 'orchestration') return

  const lines = prompt.trimEnd().split(/\r?\n/)
  const existingToken = MARKER_LINE.exec(lines[lines.length - 1].trim())?.[1]
  if (existingToken && existingToken === existingToken.toLowerCase()) return

  for (const line of lines) {
    const match = ROLE_LINE.exec(line.trimEnd())
    if (!match) continue
    const role = match[1].toLowerCase()
    const token = issueToken(role, options)
    return token === undefined ? undefined : prompt + `\n\nodd-flow-worker: ${role} ${token}\n`
  }
}
