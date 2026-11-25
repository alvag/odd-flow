import type { OrcaFrameApi } from 'orca/frame'
import { isAgentKind, isMode, type AgentKind, type MutationResult, type State } from '../protocol'
import { render, type Feedback } from './render'
import { styles } from './styles'

export type FrameHost = Pick<OrcaFrameApi, 'on' | 'plugin'>

export type PanelHandle = {
  settled: () => Promise<void>
  dispose: () => void
}

type Target = { agent: AgentKind; sessionId: string }

export function mountPanel(
  root: HTMLElement,
  host: FrameHost,
  options: { intervalMs?: number } = {}
): PanelHandle {
  let currentState: State | null = null
  let requestError: string | null = null
  let pending = false
  let feedback: Feedback | null = null
  const expanded = new Set<string>()

  let activeRequest: AbortController | undefined
  let activeMutation: AbortController | undefined
  let refreshQueued = false
  let disposed = false
  let inFlight: Promise<void> = Promise.resolve()

  function draw(): void {
    if (disposed) return
    root.innerHTML = render(currentState, {
      pending,
      feedback,
      error: requestError,
      now: Date.now(),
      expanded
    })
  }

  function showState(answer: State): void {
    currentState = answer.error ? null : answer
    requestError = answer.error ?? null
  }

  function targetForRow(rowId: string): Target | null {
    if (!currentState || !('path' in currentState.script)) return null
    for (let index = 0; index < currentState.agents.length; index++) {
      const row = currentState.agents[index]
      const id = `${row.terminalId ?? index}:${row.agent}:${row.sessionId}`
      if (id !== rowId) continue
      if (isAgentKind(row.agent) && row.sessionId?.trim()) {
        return { agent: row.agent, sessionId: row.sessionId }
      }
      return null
    }
    return null
  }

  function refresh(): Promise<void> {
    if (disposed) return Promise.resolve()
    if (activeMutation) {
      refreshQueued = true
      return inFlight
    }
    activeRequest?.abort()
    const controller = new AbortController()
    activeRequest = controller
    pending = true
    draw()

    const run = (async () => {
      try {
        const answer = await host.plugin.request('state', undefined, { signal: controller.signal })
        if (!controller.signal.aborted && !disposed) showState(answer)
      } catch (error) {
        if (!controller.signal.aborted && !disposed) {
          currentState = null
          requestError = error instanceof Error ? error.message : String(error)
        }
      } finally {
        if (activeRequest === controller) {
          activeRequest = undefined
          pending = false
          draw()
        }
      }
    })()

    inFlight = run
    return run
  }

  function apply(
    row: string,
    success: string,
    request: (signal: AbortSignal) => Promise<MutationResult>
  ): Promise<void> {
    if (disposed || activeRequest || activeMutation) return inFlight
    const controller = new AbortController()
    activeMutation = controller
    pending = true
    feedback = null
    draw()

    const run = (async () => {
      try {
        const answer = await request(controller.signal)
        if (controller.signal.aborted || disposed) return
        if (answer.state) {
          showState(answer.state)
          feedback = { row, text: success, failed: false }
        } else if (answer.workerCheckUnavailable) {
          if (currentState) showState({ ...currentState, workerCheckError: answer.error })
        } else {
          feedback = { row, text: answer.error, failed: true }
        }
      } catch (error) {
        if (!controller.signal.aborted && !disposed) {
          feedback = { row, text: error instanceof Error ? error.message : String(error), failed: true }
        }
      } finally {
        if (activeMutation === controller) {
          activeMutation = undefined
          if (refreshQueued) {
            refreshQueued = false
            await refresh()
          } else {
            pending = false
            draw()
          }
        }
      }
    })()

    inFlight = run
    return run
  }

  const onClick = (event: Event) => {
    const rawTarget = event.target as { closest?: (selector: string) => HTMLElement | null } | null
    const fold = rawTarget?.closest?.('summary.fold')
    if (fold) {
      const details = fold.closest?.('details[data-fold]') as { dataset?: { fold?: string }; open?: boolean } | null
      const key = details?.dataset?.fold
      if (key) {
        if (details.open) expanded.delete(key)
        else expanded.add(key)
      }
      return
    }

    const actionEl = rawTarget?.closest?.('[data-action]') as
      | (HTMLElement & { dataset: Record<string, string | undefined> })
      | null
    if (!actionEl) return
    const action = actionEl.dataset.action
    if (action === 'refresh') {
      void refresh()
      return
    }
    const rowId = actionEl.dataset.row
    if (!rowId) return
    const target = targetForRow(rowId)
    if (!target) return

    if (action === 'sessionMode') {
      const mode = actionEl.dataset.mode
      if (!isMode(mode)) return
      void apply(rowId, 'Mode switched.', (signal) =>
        host.plugin.request('sessionMode', { ...target, mode }, { signal })
      )
    } else if (action === 'clear') {
      void apply(rowId, 'Session choices reset.', (signal) =>
        host.plugin.request('clear', target, { signal })
      )
    }
  }

  const onChange = (event: Event) => {
    const rawTarget = event.target as (HTMLSelectElement & { closest?: (selector: string) => HTMLElement | null }) | null
    const select = rawTarget?.closest?.('[data-action="use"]') as
      | (HTMLSelectElement & { dataset: Record<string, string | undefined> })
      | null
    if (!select) return
    const rowId = select.dataset.row
    const profile = select.value
    if (!rowId || !profile) return
    const target = targetForRow(rowId)
    if (!target) return
    void apply(rowId, 'Profile switched.', (signal) =>
      host.plugin.request('use', { ...target, profile }, { signal })
    )
  }

  root.addEventListener('click', onClick)
  root.addEventListener('change', onChange)

  const subs = [
    host.on('agent.status.changed', () => refresh()),
    host.on('workspace.changed', () => refresh()),
    host.on('theme', () => draw())
  ]

  const intervalMs = options.intervalMs ?? 15_000
  const timer =
    intervalMs > 0
      ? setInterval(() => {
          if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
          if (currentState) draw()
        }, intervalMs)
      : undefined

  void refresh()

  return {
    settled: () => inFlight,
    dispose: () => {
      disposed = true
      activeRequest?.abort()
      activeMutation?.abort()
      activeRequest = undefined
      activeMutation = undefined
      if (timer !== undefined) clearInterval(timer)
      root.removeEventListener('click', onClick)
      root.removeEventListener('change', onChange)
      for (const sub of subs) sub.dispose()
    }
  }
}

if (typeof document !== 'undefined' && typeof (globalThis as { orca?: OrcaFrameApi }).orca !== 'undefined') {
  const styleEl = document.createElement('style')
  styleEl.textContent = styles
  document.head.appendChild(styleEl)

  const root = document.createElement('div')
  document.body.appendChild(root)

  const api = (globalThis as { orca: OrcaFrameApi }).orca
  mountPanel(root, api)
}
