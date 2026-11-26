# Compatibility

The odd-flow plugin for Claude Code, Codex, and Antigravity is versioned
separately from the ODD Flow Orca plugin. The table records specific checks,
not supported version ranges. “Verified live” applies only to the behavior
named in the evidence. “Tests only” means checks passed but no live worker
run was recorded.

| odd-flow | ODD Flow Orca plugin | Orca | Claude Code | Codex | Antigravity (agy) | Status | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Current checkout** 0.4.0 | 0.2.0 | 1.4.278 | 2.1.332 | 0.172.0 | 1.5.18 | tests only | 2026-11-26: installed CLI versions from `orca --version`, `claude --version`, `codex --version`, and `agy --version`. `orca plugin validate orca-plugin --json` reported valid. `orca plugin test orca-plugin --json` passed 157/157. `bash tests/orca-plugin-typecheck.sh`, `bash tests/orca-plugin-docs-check.sh`, and `bash tests/version-check.sh` passed. `bash tests/run.sh` reported 23 passed, 0 failed. The catalog install is not yet verified live. |
| 0.4.0 | 0.1.0 | 1.4.278 | 2.1.332 | 0.172.0 | 1.5.17 | verified live | 2026-11-26, installed code at `9801950`: Claude Code, Codex, and Antigravity write workers dispatched through Orca reported `worker_done`; the ODD Flow Orca plugin appended the tokened marker, the prompt hook removed each token record on first use and recorded each session as a worker, and the parent edit guard allowed each worker's edit and denied the parent ([live check log, L3](../odd/tasks/orca-1-4-278-check.md#log)). Native `worker-start --agent codex` returned, but its worker could not reach Orca from the Codex sandbox (`runtime_access_denied`), so Codex workers still start through `scripts/codex-worker.sh` ([L4](../odd/tasks/orca-1-4-278-check.md#log)). `/odd-flow check` reported in sync; `orca plugin test orca-plugin` passed 140/140. |
| 0.4.0 | 0.1.0 | 1.4.274 | not recorded | not recorded | 1.5.17 | verified live | 2026-11-25: the worker prompt hook ran live with Claude Code, Codex, and Antigravity workers ([workstream brief](../odd/tasks/version-compat.md#log); [worker token log, L20](../odd/tasks/worker-marker-token.md#log), installed code at `04130c5`). The [parent edit guard reference](../skills/odd-flow/references/mode-full-delegation.md#parent-edit-guard) names the Antigravity and Orca versions for live worker marking; the [Orca hooks spike log, L5](../odd/tasks/orca-plugin-hooks-spike.md#log) also records the Antigravity version. |
| 0.3.0 | 0.1.0 | not recorded | not recorded | not recorded | not recorded | verified live | 2026-11-25: the live panel found the installed Claude Code copy of odd-flow with no `profileScript` override ([profiles panel log, L39–L41](../odd/tasks/orca-profile-plugin.md#log)). The ODD Flow Orca plugin shipped in this release (`6167aea`, `8a7c4d7`). |
| 0.2.0 | not shipped | not recorded | not recorded | not recorded | 1.5.16 | verified live | 2026-11-24, `edcf3e0`: [Antigravity parent edit guard and first-line worker role](../README.md#install-antigravity) checked live in Orca. |
| 0.1.0 | not shipped | not recorded | not recorded | 0.171.0 | not recorded | verified live | 2026-11-23: [Codex install refresh and live hooks](../README.md#install-codex). 2026-11-24, `bc59916`: [Claude Code install](../README.md#install-claude-code) and [Codex install](../README.md#install-codex) checked. |
| not recorded | not needed | not installed | not recorded | not recorded | not recorded | not verified | Documented [native subagent fallback](../skills/odd-flow/references/orca-dispatch.md#without-orca); no versioned live check of this setup recorded here. |
| not recorded | not installed | not recorded | not recorded | not recorded | not recorded | not verified | Documented [worker prompt fallback](../skills/odd-flow/references/mode-full-delegation.md#worker-prompt-context); no versioned live check of this setup recorded here. |
| not recorded | not needed | not needed | not recorded | not installed | not installed | not verified | Documented [profile defaults](../skills/odd-flow/references/profiles.md#format) let a Claude Code session use Claude Code for every role; no versioned live check of this setup recorded here. |

ODD Flow Orca plugin 0.1.0 covered different code in different odd-flow
releases. It first shipped with odd-flow 0.3.0 (`6167aea`, `8a7c4d7`).
It gained the worker prompt hook in odd-flow 0.4.0 (`699b0ec`, `a471ef7`).
The code changed again (for example, `4f471f3`) without a plugin version
bump, so compare the shipped files when checking a 0.1.0 install. ODD Flow
Orca plugin 0.2.0 is the first version published through the catalog and
identifies the plugin code at its catalog release commit.

The `0.1.0-draft` value in [SKILL.md](../skills/odd-flow/SKILL.md) is skill
metadata, not an odd-flow or ODD Flow Orca plugin release version.

## Without optional components

- **Without Orca:** Delegated roles run as native subagents of the current
  runtime. See [Without Orca](../skills/odd-flow/references/orca-dispatch.md#without-orca).
- **Without the ODD Flow Orca plugin:** The odd-flow prompt hook identifies
  workers by the recognized Orca preamble or a first-line `# Role:` header.
  See [Worker prompt context](../skills/odd-flow/references/mode-full-delegation.md#worker-prompt-context).
- **Without Codex or Antigravity:** Start in Claude Code and use a Claude-only
  profile with no role assigned to Codex or Antigravity. Roles omitted from
  the profile use the current agent, so they also use Claude Code.
  See [Profiles](../skills/odd-flow/references/profiles.md#format).
