import { defineCheck } from 'orca/testing'

export default defineCheck({
  empty: {},
  workspace: {
    results: {
      'agents.list': {
        agents: [{
          terminalId: 't1', title: 'Codex', agent: 'codex',
          state: 'waiting', stateStartedAt: 0, sessionId: null
        }]
      }
    }
  },
  missingScript: { settings: { profileScript: 'not-an-absolute-path' } }
})
