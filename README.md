# odd-flow

Claude Code and Codex plugin for Organic Driven Development (ODD): Engram memory discipline and Orca role workers with per-role agent, model and effort profiles. Each profile runs the orchestrator in one of two peer modes: `organic` (inline by default, delegation for a named reason) or `full-delegation` (bounded writers make workspace changes, in Git or not, except for the [parent's closed write list](skills/odd-flow/references/mode-full-delegation.md#who-writes)). In both modes, the parent writes a user-named file outside the workspace only after the user confirms the exact diff. Outside an Orca terminal, delegated roles run as subagents; in organic mode, inline when no subagent can run.

## Contents

| Path | Purpose |
|---|---|
| `skills/odd-flow/` | The `odd-flow` skill (progressive disclosure: `SKILL.md` plus references and assets) |
| `hooks/hooks.json` | Claude Code hooks: `SessionStart` on startup, resume, clear and compact; `UserPromptSubmit` and `PreToolUse` |
| `hooks/codex-hooks.json` | Codex hooks: `SessionStart` on startup, resume, clear and compact; `UserPromptSubmit` |
| `scripts/session-start.py` | Injects the core block of the session's mode (`assets/core-block.md` or `assets/core-block-full-delegation.md`) and the active profile into the session |
| `scripts/prompt-submit.py` | Records a per-session parent or worker marker from the first prompt. On each prompt, restates full delegation to the coordinator or gives the worker role context. Adds no context in organic mode. |
| `scripts/pre-tool-use.py` | Checks writer edit surface declarations at launch in both modes; guards the parent's direct Claude Code edits in full delegation |
| `.claude-plugin/` | Claude Code plugin manifest and local marketplace |
| `.codex-plugin/plugin.json` | Codex plugin manifest pointing to the shared skill and Codex hooks |
| `.agents/plugins/marketplace.json` | Local Codex marketplace |

In full delegation, the [parent edit guard](skills/odd-flow/references/mode-full-delegation.md#parent-edit-guard) checks `Edit`, `Write` and `NotebookEdit`. It does not guard `Bash` writes. If Orca changes its preamble and no recognized `# Role:` header starts the prompt, a Claude worker is treated as the parent. The guard covers `Edit`, `Write` and `NotebookEdit` with Code Mode on or off. Code Mode REPL `write()` and `edit()` reach the hook as `Write` and `Edit`.

## Install (Claude Code)

```sh
claude plugin marketplace add /Users/max/Personal/repos/odd-flow
claude plugin install odd-flow@odd-flow
```

Try it without installing: `claude --plugin-dir /Users/max/Personal/repos/odd-flow`.

The skill is invoked as `/odd-flow:odd-flow`. A plain `/odd-flow` was not expanded as a skill call in a headless session (2026-11-23) and reached the model only as text; interactive sessions are unchecked.

Profile commands: `/odd-flow:odd-flow --profile <p>` (this session), `--profile-default <p>`, `--profiles` (list, then pick one for the session or as default), `--create-profile <p>` (guided, from the agents and models Orca and Codex report), `--mode <organic|full-delegation>` (this session) and `--profile-mode <p> <organic|full-delegation>` (saved in the profile, after you confirm the diff).

## Install (Codex)

From your checkout, run these commands with Codex CLI 0.171.0 and Python 3 available:

```sh
codex plugin marketplace add "$PWD"
codex plugin add odd-flow@odd-flow
```

Codex installs a copy in its plugin cache (`~/.codex/plugins/cache/odd-flow/odd-flow/`). Reinstall the plugin after changing the checkout; edits do not reach the cached copy.

Review and trust the two odd-flow hooks in Codex with `/hooks`.

On 2026-11-23, running `codex plugin add odd-flow@odd-flow` at the same version refreshed the `0.1.0` cache. A `diff -rq --exclude=.git` against the checkout found seven differing files and a missing `tests/codex-runtime-check.sh` before reinstalling, and no differences afterward. The cache copy also includes untracked files such as `odd/tasks/codex-packaging.md`. With Codex CLI 0.171.0, SessionStart and UserPromptSubmit completed in each live `codex exec --dangerously-bypass-hook-trust` run. Asked to list the short replies under “Authorized work continuity” without using tools, the parent returned “yes”, “go ahead”, and “eso mismo”, which only the core block lists. A `# Role: write` worker wrote `hello.txt` with a single shell command, made no Orca or subagent attempt, answered `ROLE`, and had a `worker` marker.

Codex does not load odd-flow's Claude Code `PreToolUse` hooks. Parent edit guarding and automatic writer surface checks are pending in Codex.

## Profiles

File at `~/.config/odd-flow/profiles.json`, edited by hand or through the profile commands (override with `ODD_FLOW_HOME`). See `skills/odd-flow/references/profiles.md` and `skills/odd-flow/assets/profiles.example.json`.

## Other runtimes

Antigravity packaging is pending. For an agent without the plugin, `skills/odd-flow/scripts/init.py` can write the core block into the global instructions file (see `skills/odd-flow/references/init.md`). To validate a writer spec without the Claude Code hook, run `python3 -I skills/odd-flow/scripts/surface.py check <spec-file>`.

## Checks

- Run all test suites with `bash tests/run.sh`.
- `claude plugin validate .`
- `echo '{"source":"startup"}' | python3 -I scripts/session-start.py`
