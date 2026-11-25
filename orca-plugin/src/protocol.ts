export const MODES = ['organic', 'full-delegation'] as const
type Mode = (typeof MODES)[number]
export function isMode(mode: unknown): mode is Mode {
  return mode === 'organic' || mode === 'full-delegation'
}

type Role = Partial<Record<'agent' | 'model' | 'effort', string | null>>

export type AgentKind = 'claude' | 'codex' | 'antigravity'
export function isAgentKind(kind: unknown): kind is AgentKind {
  return kind === 'claude' || kind === 'codex' || kind === 'antigravity'
}

export type ProfileList = {
  path: string | null
  default: string | null
  profiles: { name: string; default: boolean; mode: Mode; roles: Record<string, Role> }[]
}

export type OddState = {
  profile: string | null
  source: string
  session_key: string | null
  agent: string | null
  mode: Mode
  mode_source: string
  rules: string
  roles: Record<string, Role>
  orca_terminal: string | null
}

export type Agent = {
  terminalId: string | null
  title: string | null
  agent: string | null
  state: 'working' | 'blocked' | 'waiting' | 'done'
  sessionId: string | null
  task?: { title: string } | null
}

export type AgentRow = Agent & { isWorker?: boolean } & (
  | { odd: OddState | string; reason?: never }
  | { odd: null; reason: string }
)

export type Script = { path: string; source: string } | { error: string }

export type State = {
  script: Script
  profiles: ProfileList | string | null
  agents: AgentRow[]
  error?: string
  workerCheckError?: string
}

export type SessionTarget = { agent: AgentKind; sessionId: string }
export type MutationResult =
  | { state: State; error?: never }
  | { error: string; state?: never; workerCheckUnavailable?: true }

declare module 'orca' {
  interface PluginRequests {
    state: { output: State }
    use: { input: SessionTarget & { profile: string }; output: MutationResult }
    sessionMode: { input: SessionTarget & { mode: Mode }; output: MutationResult }
    clear: { input: SessionTarget; output: MutationResult }
  }
}
