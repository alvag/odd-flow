import { test } from 'node:test'
import { assert } from 'orca/testing'
import {
  attentionItems, currentWork, featureOwners, hiddenDashboardWork, parseFeatureDoc, parseGit, parseOrcaTime, selectFeatureDoc, workerRows
} from './dashboard'
import type { RawDispatch, RawTask } from './dashboard'
import type { Agent } from './protocol'

const created = '2026-11-25 15:56:54'
const completed = '2026-11-25T16:00:15.238Z'
const noneHidden = { runs: new Set<string>(), standaloneTasks: new Set<string>() }
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
    dispatches, tasks, agents, coordinator: 'coordinator', hidden: noneHidden,
    runs: [{ id: 'run', objective: 'Our work', coordinator_handle: 'coordinator', created_at: completed }]
  }).workers
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
  ], 'coordinator', noneHidden.runs)
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

const stale = '2026-11-25T15:00:00Z'
const cutoff = Date.parse(completed)
const now = cutoff + 12 * 60 * 60 * 1000

function run(id: string, created_at = stale) {
  return { id, objective: id, coordinator_handle: 'coordinator', created_at }
}

test('selects the newest visible run, ignoring bookkeeping updates to stale finished runs', () => {
  const staleRun = { ...run('stale'), updated_at: new Date(now).toISOString() }
  const olderOpenRun = run('older-open', '2026-11-25T14:00:00Z')
  const runs = [staleRun, olderOpenRun]
  const tasks = [
    task('finished', { run_id: 'stale', status: 'completed', created_at: stale, completed_at: stale }),
    task('open', { run_id: 'older-open', status: 'dispatched' })
  ]
  const dispatches = [dispatch('finished', { state: 'succeeded' })]
  const hidden = hiddenDashboardWork(runs, tasks, dispatches, now)
  assert.equal(currentWork(runs, tasks, 'coordinator', hidden.runs)?.objective, 'older-open')
  assert.equal(currentWork([staleRun], tasks, 'coordinator', hidden.runs), null)
})

test('keeps an old run with an unfinished ready task and no dispatch in Current work', () => {
  const runs = [run('old')]
  const tasks = [task('queued', { run_id: 'old', status: 'ready', created_at: stale, completed_at: null })]
  const hidden = hiddenDashboardWork(runs, tasks, [], now)
  assert.equal(currentWork(runs, tasks, 'coordinator', hidden.runs)?.objective, 'old')
})

test('keeps runs with unfinished tasks, active dispatches or activity at the cutoff', () => {
  const runs = ['dispatched', 'active-dispatch', 'task-ended'].map((id) => run(id))
  runs.push(run('run-started', completed), run('expired', new Date(cutoff - 1).toISOString()))
  const tasks = [
    task('dispatched', { run_id: 'dispatched', status: 'dispatched' }),
    task('active-dispatch', { run_id: 'active-dispatch', status: 'completed', completed_at: stale }),
    task('task-ended', { run_id: 'task-ended', status: 'completed', completed_at: completed })
  ]
  const dispatches = [dispatch('active-dispatch', { state: 'running' })]
  assert.deepEqual([...hiddenDashboardWork(runs, tasks, dispatches, now).runs], ['expired'])
})

test('omits workers of hidden runs and old runless tasks with no active dispatch', () => {
  const runs = [run('stale'), run('recent', completed)]
  const tasks = [
    task('stale-run', { run_id: 'stale', status: 'completed', completed_at: stale }),
    task('recent-run', { run_id: 'recent', status: 'completed', completed_at: stale }),
    task('stale-runless', { run_id: null, status: 'completed', completed_at: stale }),
    task('recent-runless', { run_id: null, status: 'completed', completed_at: completed }),
    task('active-runless', { run_id: null, status: 'completed', completed_at: stale })
  ]
  const dispatches = tasks.map(({ id }) => dispatch(id, { state: 'succeeded' }))
  dispatches.push(dispatch('active', { taskId: 'active-runless', state: 'ready' }))
  const hidden = hiddenDashboardWork(runs, tasks, dispatches, now)
  const { workers } = workerRows({ dispatches, tasks, agents: [], coordinator: 'coordinator', runs, hidden })
  assert.deepEqual(workers.map(({ dispatchId }) => dispatchId), ['active', 'recent-run', 'recent-runless', 'active-runless'])
})

test('does not assign ownership from a hidden run and preserves the branch fallback', () => {
  const doc = { path: 'odd/tasks/stale.md', mtimeMs: 1, text: `${header}
${table}` }
  const runs = [run('stale')]
  const tasks = [task('finished', {
    run_id: 'stale', status: 'completed', completed_at: stale, spec: `Spec: ${doc.path}`
  })]
  const hidden = hiddenDashboardWork(runs, tasks, [], now)
  const owners = featureOwners({ docs: [doc], tasks, runs, openSessions: ['coordinator'], hiddenRunIds: hidden.runs })
  assert.equal(selectFeatureDoc([doc], 'main', { owners, session: 'coordinator' }), null)
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners, session: 'coordinator' })?.path, doc.path)
})

test('raises attention for a blocked coordinator and blocked active workers only', () => {
  const workers = rows([
    dispatch('active', { agent: 'codex/gpt-6-luna' }), dispatch('settled', { state: 'cancelled' })
  ], [task('active'), task('settled')], [agent('active', 'blocked'), agent('settled', 'blocked')])
  const alerts = attentionItems(agent('coordinator', 'blocked'), workers)
  assert.deepEqual(alerts, [
    { label: 'This session is blocked', since: 123 },
    { label: 'Task active — codex/gpt-6-luna', since: 123 }
  ])
  assert.deepEqual(attentionItems(agent('coordinator', 'waiting'), workers), alerts.slice(1))
})

test('parses git summary', () => {
  assert.deepEqual(parseGit('main\n', ' M one\n?? two\nR  old -> three\n', 'a1b2345\x001764087654\n'), {
    branch: 'main', changedFiles: 3, lastCommit: { hash: 'a1b2345', at: 1764087654000 }
  })
})

test('treats stopped, abandoned and unsupervised dispatches as finished', () => {
  const states = ['stopped', 'abandoned', 'unsupervised']
  const workers = rows(
    states.map((state) => dispatch(state, { state })),
    states.map((state) => task(state, { status: 'failed', completed_at: completed }))
  )
  assert.deepEqual(workers.map(({ active }) => active), [false, false, false])
})

test('counts only ready, dispatched and running dispatches as active', () => {
  const activeStates = ['ready', 'dispatched', 'running']
  const settledStates = ['succeeded', 'failed', 'cancelled', 'lost', 'stopped', 'abandoned', 'unsupervised', 'unknown']
  const states = [...activeStates, ...settledStates]
  const workers = rows(
    states.map((state) => dispatch(state, { state, attention: ['input'] })),
    states.map((state) => task(state, { completed_at: completed }))
  )
  assert.deepEqual(workers.filter(({ active }) => active).map(({ state }) => state), activeStates)
  assert.deepEqual(workers.filter(({ needsYou }) => needsYou).map(({ state }) => state), activeStates)
  assert.deepEqual(workers.filter(({ endedAt }) => endedAt === Date.parse(completed)).map(({ state }) => state), settledStates)
})

test('parses the first word of a feature task status cell', () => {
  const body = [
    '| T1 | S1 | Done | inline | done (commit 6a01080) | |',
    '| T2 | S1 | Working | inline | in_progress — follow-up | |',
    '| T3 | S1 | Unknown | inline | doneish | |'
  ].join('\n')
  assert.deepEqual(parseFeatureDoc('annotated', `${header}\n${table}\n${body}`)?.tasks.map(({ status }) => status),
    ['done', 'in_progress', 'unknown'])
})

test('uses the blocked time for a blocked worker and the work start for other attention', () => {
  const workers = rows([
    dispatch('blocked'), dispatch('without-time'), dispatch('input', { attention: ['input'] })
  ], [
    task('blocked'), task('without-time'), task('input')
  ], [
    agent('blocked', 'blocked'), { ...agent('without-time', 'blocked'), stateStartedAt: undefined }
  ])
  assert.deepEqual(attentionItems(agent('coordinator', 'waiting'), workers), [
    { label: 'Task blocked', since: 123 },
    { label: 'Task without-time', since: Date.UTC(2026, 10, 25, 15, 56, 54) },
    { label: 'Task input', since: Date.UTC(2026, 10, 25, 15, 56, 54) }
  ])
  assert.equal(workers[0].startedAt, Date.UTC(2026, 10, 25, 15, 56, 54))
})

test('newest citing session owns the doc', () => {
  const doc = { path: 'odd/tasks/a.md', mtimeMs: 1, text: `${header}\n${table}` }
  const runs = [
    { id: 'r1', objective: 'One', coordinator_handle: 's1', created_at: '2026-11-25T15:00:00Z' },
    { id: 'r2', objective: 'Two', coordinator_handle: 's2', created_at: '2026-11-25T15:00:00Z' }
  ]
  const tasks = [
    task('t1', { created_by_terminal_handle: 's1', run_id: 'r1', created_at: '2026-11-25T15:10:00Z', spec: 'Spec: odd/tasks/a.md, S1' }),
    task('t2', { created_by_terminal_handle: 's2', run_id: 'r2', created_at: '2026-11-25T15:20:00Z', spec: 'Spec: odd/tasks/a.md, S2' })
  ]
  const owners = featureOwners({ docs: [doc], tasks, runs, openSessions: ['s1', 's2'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners, session: 's2' })?.path, 'odd/tasks/a.md')
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners, session: 's1' }), null)
})

test('a second session that cites nothing gets no card while the owner is open', () => {
  const doc = { path: 'odd/tasks/a.md', mtimeMs: 1, text: `${header}\n${table}` }
  const runs = [{ id: 'r1', objective: 'One', coordinator_handle: 'owner', created_at: '2026-11-25T15:00:00Z' }]
  const tasks = [
    task('t1', { created_by_terminal_handle: 'owner', run_id: 'r1', created_at: '2026-11-25T15:10:00Z', spec: 'Spec: odd/tasks/a.md' })
  ]
  const owners = featureOwners({ docs: [doc], tasks, runs, openSessions: ['owner', 'research'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners, session: 'owner' })?.path, 'odd/tasks/a.md')
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners, session: 'research' }), null)
})

test('ownership moves when another session creates a newer citing task', () => {
  const doc = { path: 'odd/tasks/a.md', mtimeMs: 1, text: `${header}\n${table}` }
  const runs = [
    { id: 'r1', objective: 'One', coordinator_handle: 'claude', created_at: '2026-11-25T15:00:00Z' },
    { id: 'r2', objective: 'Two', coordinator_handle: 'codex', created_at: '2026-11-25T15:30:00Z' }
  ]
  const initialTasks = [
    task('t1', { created_by_terminal_handle: 'claude', run_id: 'r1', created_at: '2026-11-25T15:10:00Z', spec: 'odd/tasks/a.md' })
  ]
  const before = featureOwners({ docs: [doc], tasks: initialTasks, runs, openSessions: ['claude', 'codex'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners: before, session: 'claude' })?.path, 'odd/tasks/a.md')
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners: before, session: 'codex' }), null)

  const afterTasks = [
    ...initialTasks,
    task('t2', { created_by_terminal_handle: 'codex', run_id: 'r2', created_at: '2026-11-25T15:40:00Z', spec: 'odd/tasks/a.md' })
  ]
  const after = featureOwners({ docs: [doc], tasks: afterTasks, runs, openSessions: ['claude', 'codex'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners: after, session: 'codex' })?.path, 'odd/tasks/a.md')
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners: after, session: 'claude' }), null)
})

test('when the owner closes the doc falls back to the branch rule for remaining sessions', () => {
  const doc = { path: 'odd/tasks/a.md', mtimeMs: 1, text: `${header}\n${table}` }
  const runs = [{ id: 'r1', objective: 'One', coordinator_handle: 'closed-owner', created_at: '2026-11-25T15:00:00Z' }]
  const tasks = [
    task('t1', { created_by_terminal_handle: 'closed-owner', run_id: 'r1', created_at: '2026-11-25T15:10:00Z', spec: 'odd/tasks/a.md' })
  ]
  const owners = featureOwners({ docs: [doc], tasks, runs, openSessions: ['remaining'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc([doc], 'feat/orca-profile-plugin', { owners, session: 'remaining' })?.path, 'odd/tasks/a.md')
})

test('a session owning one doc does not also get a branch-fallback doc', () => {
  const ownedOtherBranch = {
    path: 'odd/tasks/owned.md', mtimeMs: 1,
    text: `${header.replace('feat/orca-profile-plugin', 'other-branch')}\n${table}`
  }
  const unownedCurrentBranch = { path: 'odd/tasks/fallback.md', mtimeMs: 2, text: `${header}\n${table}` }
  const docs = [ownedOtherBranch, unownedCurrentBranch]
  const runs = [{ id: 'r1', objective: 'One', coordinator_handle: 's1', created_at: '2026-11-25T15:00:00Z' }]
  const tasks = [
    task('t1', { created_by_terminal_handle: 's1', run_id: 'r1', created_at: '2026-11-25T15:10:00Z', spec: 'odd/tasks/owned.md' })
  ]
  const owners = featureOwners({ docs, tasks, runs, openSessions: ['s1', 's2'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc(docs, 'feat/orca-profile-plugin', { owners, session: 's1' })?.path, 'odd/tasks/owned.md')
  assert.equal(selectFeatureDoc(docs, 'feat/orca-profile-plugin', { owners, session: 's2' })?.path, 'odd/tasks/fallback.md')
})

test('a cited path that is only a prefix of another path does not match', () => {
  const shortDoc = { path: 'odd/tasks/a.md', mtimeMs: 1, text: `${header}\n${table}` }
  const longDoc = { path: 'odd/tasks/a.md-plan.md', mtimeMs: 2, text: `${header}\n${table}` }
  const docs = [shortDoc, longDoc]
  const runs = [{ id: 'r1', objective: 'One', coordinator_handle: 's1', created_at: '2026-11-25T15:00:00Z' }]
  const tasks = [
    task('t1', { created_by_terminal_handle: 's1', run_id: 'r1', created_at: '2026-11-25T15:10:00Z', spec: 'See odd/tasks/a.md-plan.md for details' })
  ]
  const owners = featureOwners({ docs, tasks, runs, openSessions: ['s1', 's2'], hiddenRunIds: noneHidden.runs })
  assert.equal(selectFeatureDoc(docs, 'feat/orca-profile-plugin', { owners, session: 's1' })?.path, 'odd/tasks/a.md-plan.md')
  assert.equal(selectFeatureDoc(docs, 'feat/orca-profile-plugin', { owners, session: 's2' })?.path, 'odd/tasks/a.md')
})
