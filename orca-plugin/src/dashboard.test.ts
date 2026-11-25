import { test } from 'node:test'
import { assert } from 'orca/testing'
import { attentionItems, currentWork, parseFeatureDoc, parseGit, parseOrcaTime, selectFeatureDoc, workerRows } from './dashboard'
import type { RawDispatch, RawTask } from './dashboard'
import type { Agent } from './protocol'

const created = '2026-11-25 15:56:54'
const completed = '2026-11-25T16:00:15.238Z'
const header = '# Orca profile and mode panel plugin\n\nObjective: control profiles. Branch: `feat/orca-profile-plugin`.\n'
const table = [
  '## Tasks',
  '',
  '| ID | Specs | Work | Route | Status | Evidence |',
  '|---|---|---|---|---|---|'
].join('\n')

function agent(terminalId: string, state: Agent['state']): Agent {
  return { terminalId, state, stateStartedAt: 123, sessionId: null, title: null, agent: null }
}

function task(id: string, fields: Partial<RawTask> = {}): RawTask {
  return {
    id, task_title: `Task ${id}`, status: 'pending', created_at: created, completed_at: null,
    created_by_terminal_handle: 'coordinator', run_id: 'run', result: null, ...fields
  }
}

function dispatch(id: string, fields: Partial<RawDispatch> = {}): RawDispatch {
  return { dispatchId: id, taskId: id, state: 'ready', terminal: id, workspace: 'workspace', ...fields }
}

function rows(dispatches: RawDispatch[], tasks: RawTask[], agents: Agent[] = []) {
  return workerRows({
    dispatches, tasks, agents, coordinator: 'coordinator',
    runs: [{ id: 'run', objective: 'Our work', coordinator_handle: 'coordinator', created_at: completed }]
  })
}

test('parses both Orca timestamp shapes', () => {
  assert.equal(parseOrcaTime(created), Date.UTC(2026, 10, 25, 15, 56, 54))
  assert.equal(parseOrcaTime(completed), Date.UTC(2026, 10, 25, 16, 0, 15, 238))
  assert.equal(parseOrcaTime('x'), null)
})

test('parses the feature task table', () => {
  const path = 'odd/tasks/orca-profile-plugin.md'
  const body = [
    '| T1 | S7 | `profile.py list --json` and `show --json` (machine-readable output for the plugin), tests and `references/profiles.md` | orca:write (parallel with T2; disjoint surfaces) | done | commit 39bbb76 |',
    '| T2 | S2, S6 | One-time mode-change notice: `session-start.py` records the injected mode, tests and mode docs | orca:write (parallel with T1; disjoint surfaces) | done | commit 03b1287 |',
    '| T5 | S1, S2, S4, S8 | Panel switching: profile select, mode select, clear binding, refresh on agent and workspace events | orca:write (after T4) | in_progress | |'
  ].join('\n')
  const feature = parseFeatureDoc(path, `${header}\n${table}\n${body}`)
  assert.equal(feature?.path, path)
  assert.equal(feature?.title, 'Orca profile and mode panel plugin')
  assert.equal(feature?.branch, 'feat/orca-profile-plugin')
  assert.deepEqual(feature?.tasks.map(({ id, status }) => [id, status]), [
    ['T1', 'done'], ['T2', 'done'], ['T5', 'in_progress']
  ])
})

test('ignores documents without a task table', () => {
  assert.equal(parseFeatureDoc('no-table', `${header}\n## Tasks\nNo table here.\n## Log\n${table.replace('## Tasks', '')}`), null)
  assert.deepEqual(parseFeatureDoc('header-only', `${header}\n${table}`)?.tasks, [])
})

test('keeps escaped pipes in work text', () => {
  const text = header + '\n## Tasks\n| Status | Work | ID |\n|---|---|---|\n| blocked | A \\| B | T1 |'
  assert.deepEqual(parseFeatureDoc('escaped', text)?.tasks, [{ id: 'T1', status: 'blocked', work: 'A | B' }])
})

test('selects the newest document for the branch', () => {
  const text = `${header}\n${table}`
  assert.equal(selectFeatureDoc([
    { path: 'older', mtimeMs: 1, text },
    { path: 'other-branch', mtimeMs: 4, text: text.replace('feat/orca-profile-plugin', 'main') },
    { path: 'no-table', mtimeMs: 3, text: header },
    { path: 'newer', mtimeMs: 2, text }
  ], 'feat/orca-profile-plugin')?.path, 'newer')
})

test('attributes a blocked terminal only to its newest active dispatch', () => {
  const workers = rows([
    dispatch('old', { terminal: 'shared' }),
    dispatch('new', { terminal: 'shared' }),
    dispatch('settled', { terminal: 'shared', state: 'succeeded' })
  ], [
    task('old'), task('new', { created_at: '2026-11-25 15:58:00' }),
    task('settled', { created_at: '2026-11-25 15:59:00', completed_at: completed })
  ], [agent('shared', 'blocked')])
  assert.deepEqual(workers.map(({ dispatchId, state, needsYou }) => [dispatchId, state, needsYou]), [
    ['new', 'blocked', true], ['old', 'ready', false], ['settled', 'succeeded', false]
  ])
})

test('never alerts on unverifiable or root_completion attention', () => {
  const workers = rows([
    dispatch('noise', { attention: ['unverifiable', 'root_completion'] }),
    dispatch('question', { attention: ['input'] }),
    dispatch('escalation', { attention: ['escalation'] }),
    dispatch('settled', { state: 'lost', attention: ['escalation'] })
  ], ['noise', 'question', 'escalation', 'settled'].map((id) => task(id)))
  assert.deepEqual(workers.map(({ needsYou }) => needsYou), [false, true, true, false])
})

test('maps worker agent from the dispatch agent field', () => {
  const workers = rows([
    dispatch('tagged', { agent: 'codex/gpt-6-luna' }), dispatch('no-agent')
  ], [task('tagged'), task('no-agent')], [
    { ...agent('tagged', 'working'), agent: 'claude' },
    { ...agent('no-agent', 'working'), agent: 'claude' }
  ])
  assert.deepEqual(workers.map(({ agent }) => agent), ['codex/gpt-6-luna', null])
})

test('orders active workers first then newest', () => {
  const workers = rows([
    dispatch('older'), dispatch('done', { state: 'succeeded' }),
    dispatch('newer'), dispatch('outsider')
  ], [
    task('older', { run_id: 'legacy' }),
    task('done', { created_at: completed, completed_at: completed }),
    task('newer', { created_at: '2026-11-25 15:58:00', created_by_terminal_handle: 'other' }),
    task('outsider', { run_id: 'elsewhere', created_by_terminal_handle: 'other' })
  ])
  assert.deepEqual(workers.map(({ dispatchId, active, endedAt }) => [dispatchId, active, endedAt]), [
    ['newer', true, null], ['older', true, null], ['done', false, Date.parse(completed)]
  ])
})

test("builds current work from the coordinator's newest run", () => {
  const result = currentWork([
    { id: 'newest-overall', objective: 'Other work', created_at: '2026-11-25T16:30:00Z' },
    { id: 'old', objective: 'Old work', created_at: '2026-11-25T15:00:00Z', coordinator_handle: 'coordinator' },
    { id: 'run', objective: 'Current work', created_at: '2026-11-25T15:30:00Z', coordinator_handle: 'coordinator' }
  ], [
    task('old-result', { run_id: 'old', status: 'completed', result: '{"subject":"Other run"}', completed_at: completed }),
    task('first', { status: 'completed', completed_at: '2026-11-25T15:58:00Z', result: '{"subject":"First result"}' }),
    task('last', { status: 'completed', completed_at: completed, result: '{"subject":"Latest result","spec":"Not panel data"}' })
  ], 'coordinator')
  assert.deepEqual(result, {
    objective: 'Current work',
    startedAt: Date.parse('2026-11-25T15:30:00Z'),
    tasks: [
      { title: 'Task first', status: 'completed', startedAt: Date.UTC(2026, 10, 25, 15, 56, 54), endedAt: Date.parse('2026-11-25T15:58:00Z') },
      { title: 'Task last', status: 'completed', startedAt: Date.UTC(2026, 10, 25, 15, 56, 54), endedAt: Date.parse(completed) }
    ],
    lastResult: { title: 'Task last', subject: 'Latest result' }
  })
})

test('raises attention for a blocked coordinator and blocked active workers only', () => {
  const workers = rows([
    dispatch('active', { agent: 'codex/gpt-6-luna' }), dispatch('settled', { state: 'cancelled' })
  ], [task('active'), task('settled')], [agent('active', 'blocked'), agent('settled', 'blocked')])
  const alerts = attentionItems(agent('coordinator', 'blocked'), workers)
  assert.deepEqual(alerts, [
    { label: 'This session is blocked', since: 123 },
    { label: 'Task active — codex/gpt-6-luna', since: Date.UTC(2026, 10, 25, 15, 56, 54) }
  ])
  assert.deepEqual(attentionItems(agent('coordinator', 'waiting'), workers), alerts.slice(1))
})

test('parses git summary', () => {
  assert.deepEqual(parseGit('main\n', ' M one\n?? two\nR  old -> three\n', 'a1b2345\x001764087654\n'), {
    branch: 'main', changedFiles: 3, lastCommit: { hash: 'a1b2345', at: 1764087654000 }
  })
})
