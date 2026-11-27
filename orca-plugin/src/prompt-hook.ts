import { execFileSync } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { closeSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, rmSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import type { PluginHooks } from 'orca/host'

type PromptEvent = PluginHooks['agent.prompt.before']['event']
type TokenOptions = {
  stateDir?: string; now?: () => number; randomBytes?: (size: number) => Buffer; log?: (message: string) => void
}
export type WindowsDaclVerdict = { ok: true } | { ok: false; reason: string }
const ROLE_LINE = /^# Role: (explore|write|verify|review|refute)$/i
const MARKER_LINE = /^odd-flow-worker: (?:explore|write|verify|review|refute) ([0-9a-f]{32})$/i
const TOKEN_LIFETIME_MS = 15 * 60 * 1000
const WINDOWS_CMD_TIMEOUT_MS = 5000

export function evaluateWindowsDaclSddl(sddl: string, userSid: string): WindowsDaclVerdict {
  const dIndex = sddl.indexOf('D:')
  const sIndex = sddl.indexOf('S:')
  if (dIndex === -1 || (sIndex !== -1 && sIndex < dIndex)) {
    return { ok: false, reason: 'worker-tokens DACL is missing' }
  }

  const afterD = sddl.slice(dIndex + 2)
  const flags = /^((?:P|AI|AR)*)/i.exec(afterD)?.[1] ?? ''
  const afterFlags = afterD.slice(flags.length)
  if (afterFlags === 'NO_ACCESS_CONTROL' || afterFlags.startsWith('NO_ACCESS_CONTROL' + 'S:')) {
    return { ok: false, reason: 'worker-tokens has a null DACL (D:NO_ACCESS_CONTROL)' }
  }

  const allowedSids = new Set(['SY', 'S-1-5-18', 'BA', 'S-1-5-32-544', userSid.toUpperCase()])
  let pos = flags.length
  while (pos < afterD.length) {
    if (afterD.startsWith('S:', pos)) break
    if (afterD[pos] !== '(') {
      return { ok: false, reason: 'worker-tokens has an unparsable DACL' }
    }

    let depth = 0
    let end = pos
    while (end < afterD.length) {
      if (afterD[end] === '(') depth++
      else if (afterD[end] === ')') {
        depth--
        if (depth === 0) break
      }
      end++
    }
    if (depth !== 0 || end >= afterD.length) {
      return { ok: false, reason: 'worker-tokens has an unparsable DACL' }
    }

    const parts = afterD.slice(pos + 1, end).split(';')
    pos = end + 1
    if (parts.length < 6) {
      return { ok: false, reason: 'worker-tokens has an unparsable DACL' }
    }

    const aceType = parts[0].toUpperCase()
    if (aceType === 'D') {
      if (parts.length !== 6) {
        return { ok: false, reason: 'worker-tokens has an unparsable DACL' }
      }
      continue
    }
    if (aceType !== 'A') {
      return { ok: false, reason: `worker-tokens DACL contains unsupported ACE type ${parts[0]}` }
    }
    if (parts.length !== 6 || !parts[5]) {
      return { ok: false, reason: 'worker-tokens has an unparsable DACL' }
    }
    if (!allowedSids.has(parts[5].toUpperCase())) {
      return { ok: false, reason: `worker-tokens DACL grants access to ${parts[5]}` }
    }
  }

  return { ok: true }
}

function checkWindowsTokenDirectory(dir: string): WindowsDaclVerdict {
  const systemRoot = process.env.SystemRoot
  if (!systemRoot || !isAbsolute(systemRoot)) {
    return { ok: false, reason: 'SystemRoot is not set' }
  }

  let userSid: string
  try {
    const whoamiOutput = execFileSync(
      join(systemRoot, 'System32', 'whoami.exe'),
      ['/user', '/fo', 'csv', '/nh'],
      { encoding: 'utf8', windowsHide: true, timeout: WINDOWS_CMD_TIMEOUT_MS }
    )
    const match = /^"[^"]*","(S-1-[0-9-]+)"$/i.exec(whoamiOutput.trim())
    if (!match) {
      return { ok: false, reason: 'could not determine current user SID' }
    }
    userSid = match[1]
  } catch {
    return { ok: false, reason: 'could not determine current user SID' }
  }

  const aclTempDir = mkdtempSync(join(dir, 'odd-flow-acl-'))
  try {
    const aclFile = join(aclTempDir, 'dacl.txt')
    execFileSync(
      join(systemRoot, 'System32', 'icacls.exe'),
      [dir, '/save', aclFile],
      { encoding: 'utf8', windowsHide: true, timeout: WINDOWS_CMD_TIMEOUT_MS }
    )
    const content = readFileSync(aclFile, 'utf16le').replace(/^\uFEFF/, '')
    const lines = content.split(/\r?\n/)
    const sddl = lines[1]?.trim()
    if (!sddl) {
      return { ok: false, reason: 'could not read worker-tokens DACL' }
    }
    return evaluateWindowsDaclSddl(sddl, userSid)
  } catch {
    return { ok: false, reason: 'could not read worker-tokens DACL' }
  } finally {
    try {
      rmSync(aclTempDir, { recursive: true, force: true })
    } catch {
      // Best-effort cleanup of temporary icacls output.
    }
  }
}

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
    if (process.platform === 'win32') {
      const verdict = checkWindowsTokenDirectory(dir)
      if (!verdict.ok) return fail(verdict.reason)
    } else {
      if ((directory.mode & 0o7777) !== 0o700) return fail('worker-tokens must have mode 0700')
      if (typeof process.getuid === 'function' && directory.uid !== process.getuid()) {
        return fail('worker-tokens must be owned by the running user')
      }
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
