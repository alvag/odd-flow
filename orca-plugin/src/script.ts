import { readdir, stat } from 'node:fs/promises'
import { isAbsolute, join } from 'node:path'
import type { Script } from './protocol'

const SCRIPT = 'skills/odd-flow/scripts/profile.py'
const NUMBER = /^(0|[1-9][0-9]*)$/
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/

function version(name: string) {
  const match = VERSION.exec(name)
  if (!match) return null
  const prerelease = match[4]?.split('.')
  if (prerelease?.some((id) => /^0[0-9]+$/.test(id))) return null
  return { name, core: match.slice(1, 4), prerelease }
}

type Version = NonNullable<ReturnType<typeof version>>

function compareIdentifier(a: string, b: string): number {
  if (a === b) return 0
  const aNumber = NUMBER.test(a)
  const bNumber = NUMBER.test(b)
  if (aNumber !== bNumber) return aNumber ? -1 : 1
  if (aNumber && a.length !== b.length) return a.length - b.length
  return a < b ? -1 : 1
}

function compareVersion(a: Version, b: Version): number {
  for (let i = 0; i < a.core.length; i++) {
    const comparison = compareIdentifier(a.core[i], b.core[i])
    if (comparison) return comparison
  }
  if (!a.prerelease || !b.prerelease) return Number(!a.prerelease) - Number(!b.prerelease)
  for (let i = 0; i < Math.min(a.prerelease.length, b.prerelease.length); i++) {
    const comparison = compareIdentifier(a.prerelease[i], b.prerelease[i])
    if (comparison) return comparison
  }
  return a.prerelease.length - b.prerelease.length
}

async function newestVersion(cache: string): Promise<string | undefined> {
  const entries = await readdir(cache, { withFileTypes: true }).catch(() => [])
  const versions = entries.filter((entry) => entry.isDirectory())
    .map((entry) => version(entry.name)).filter((entry) => entry !== null)
  return versions.sort((a, b) => compareVersion(b, a) || compareIdentifier(a.name, b.name))[0]?.name
}

export async function isFile(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isFile() ?? false
}

export async function resolveScript(home: string, configured: unknown): Promise<Script> {
  if (configured !== undefined && typeof configured !== 'string') {
    return { error: 'The profileScript setting must be a string.' }
  }
  if (typeof configured === 'string' && configured !== '') {
    if (!isAbsolute(configured)) return { error: 'The profileScript setting must be an absolute path.' }
    return await isFile(configured)
      ? { path: configured, source: 'profileScript setting' }
      : { error: `The profileScript setting is not a file: ${configured}` }
  }

  for (const [cache, source] of [
    ['.claude/plugins/cache/odd-flow/odd-flow', 'Claude cache'],
    ['.codex/plugins/cache/odd-flow/odd-flow', 'Codex cache']
  ]) {
    const root = join(home, cache)
    const latest = await newestVersion(root)
    if (latest) {
      const path = join(root, latest, SCRIPT)
      if (await isFile(path)) return { path, source }
    }
  }
  const path = join(home, '.gemini/config/plugins/odd-flow', SCRIPT)
  if (await isFile(path)) return { path, source: 'Gemini config' }
  return { error: 'No installed profile.py was found. Set profileScript to its absolute path in Orca Settings.' }
}
