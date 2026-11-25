type Mode = 'organic' | 'full-delegation'
type Role = Partial<Record<'agent' | 'model' | 'effort', string | null>>

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
}

export type AgentRow = Agent & (
  | { odd: OddState | string; reason?: never }
  | { odd: null; reason: string }
)

export type Script = { path: string; source: string } | { error: string }

export type State = {
  script: Script
  profiles: ProfileList | string | null
  agents: AgentRow[]
}

declare module 'orca' {
  interface PluginRequests {
    state: { output: State }
  }
}
