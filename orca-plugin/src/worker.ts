import { execFile } from 'node:child_process'
import { homedir } from 'node:os'
import type { OrcaWorkerApi } from 'orca/worker'
import type { Agent, AgentRow, OddState, ProfileList, Script, State } from './protocol'
import { resolveScript } from './script'

const SESSION_VARIABLE = {
  claude: 'CLAUDE_CODE_SESSION_ID',
  codex: 'CODEX_THREAD_ID',
  antigravity: 'ANTIGRAVITY_CONVERSATION_ID'
} as const

// Keep in sync with profile.py's SESSION_VARS: every inherited session key is cleared.
const SESSION_KEYS = [...Object.values(SESSION_VARIABLE), 'CODEX_SESSION_ID', 'ORCA_PANE_KEY']
type Env = Record<string, string | undefined>

export type Runner = (
  argv: readonly string[], env: Env, signal?: AbortSignal
) => Promise<{ stdout: string; stderr: string }>

export type WorkerOptions = { run: Runner; env: Env; home: string }

export const runPython: Runner = (argv, env, signal) => new Promise((resolve, reject) => {
  execFile('python3', [...argv], {
    env, signal, timeout: 5000, killSignal: 'SIGKILL', encoding: 'utf8', windowsHide: true
  }, (error, stdout, stderr) => {
    if (error) reject(Object.assign(error, { stderr }))
    else resolve({ stdout, stderr })
  })
})

function message(error: unknown): string {
  if (error && typeof error === 'object' && 'stderr' in error &&
      typeof error.stderr === 'string' && error.stderr.trim()) return error.stderr.trim()
  return error instanceof Error ? error.message : String(error)
}

async function readJson<T>(
  run: Runner, path: string, command: 'list' | 'show', env: Env, signal: AbortSignal
): Promise<T | string> {
  try {
    const { stdout, stderr } = await run(['-I', path, command, '--json'], env, signal)
    try {
      const parsed = JSON.parse(stdout)
      if (command === 'list' ? !Array.isArray(parsed?.profiles) : typeof parsed?.mode !== 'string') {
        throw new Error('Unexpected profile.py response')
      }
      return parsed as T
    } catch {
      const detail = stderr.trim()
      return `profile.py ${command} returned invalid JSON output.${detail ? ` ${detail}` : ''}`
    }
  } catch (error) {
    return `profile.py ${command} failed: ${message(error)}`
  }
}

async function agentRow(
  row: Agent, script: Script, env: Env, run: Runner, signal: AbortSignal
): Promise<AgentRow> {
  const kind = row.agent
  if (kind !== 'claude' && kind !== 'codex' && kind !== 'antigravity') {
    return { ...row, odd: null, reason: 'Unsupported agent kind.' }
  }
  if (!row.sessionId?.trim()) return { ...row, odd: null, reason: 'No session ID reported.' }
  if ('error' in script) return { ...row, odd: script.error }
  const odd = await readJson<OddState>(run, script.path, 'show', {
    ...env, [SESSION_VARIABLE[kind]]: row.sessionId
  }, signal)
  return { ...row, odd }
}

export function createWorker({
  run = runPython, env = process.env, home = homedir()
}: Partial<WorkerOptions> = {}) {
  return (orca: OrcaWorkerApi): void => {
    orca.panels.handle('state', async (_input, { signal }): Promise<State> => {
      const cleanEnv = { ...env }
      for (const key of SESSION_KEYS) delete cleanEnv[key]

      const [listed, script] = await Promise.all([
        orca.host.call('agents.list', undefined, { signal }),
        orca.settings.get('profileScript').then((setting) => resolveScript(home, setting))
      ])
      const [profiles, agents] = await Promise.all([
        'path' in script ? readJson<ProfileList>(run, script.path, 'list', cleanEnv, signal) : null,
        Promise.all(listed.agents.map(({ terminalId, title, agent, state, sessionId }) =>
          agentRow({ terminalId, title, agent, state, sessionId: sessionId ?? null },
            script, cleanEnv, run, signal)
        ))
      ])
      return { script, profiles, agents }
    })
  }
}

export default createWorker()
