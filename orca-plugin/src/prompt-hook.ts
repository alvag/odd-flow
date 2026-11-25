import type { PluginHooks } from 'orca/host'

type PromptEvent = PluginHooks['agent.prompt.before']['event']
const ROLE_LINE = /^# Role: (explore|write|verify|review|refute)$/i
const MARKER_LINE = /^odd-flow-worker: (explore|write|verify|review|refute)$/i

export function promptWithWorkerMarker({ inputKind, prompt }: PromptEvent): string | undefined {
  if (inputKind !== 'orchestration') return

  const lines = prompt.trimEnd().split(/\r?\n/)
  if (MARKER_LINE.test(lines[lines.length - 1].trim())) return

  for (const line of lines) {
    const match = ROLE_LINE.exec(line.trimEnd())
    if (match) return prompt + `\n\nodd-flow-worker: ${match[1].toLowerCase()}\n`
  }
}
