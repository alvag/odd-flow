# odd-flow

Claude Code and Codex plugin for Organic Driven Development (ODD): Engram memory discipline and Orca role workers with per-role agent, model and effort profiles. Each profile runs the orchestrator in one of two peer modes: `organic` (inline by default, delegation for a named reason) or `full-delegation` (bounded writers make workspace changes, in Git or not, except for the [parent's closed write list](skills/odd-flow/references/mode-full-delegation.md#who-writes)). In both modes, the parent writes a user-named file outside the workspace only after the user confirms the exact diff. Outside an Orca terminal, delegated roles run as subagents; in organic mode, inline when no subagent can run.

## Organic and full delegation compared

Compare what the coordinator does in each mode.

| Moment | Organic: the coordinator... | Full delegation: the coordinator... |
|---|---|---|
| Authorize and understand | Keeps investigation, review and planning requests read-only until a change is asked; reads in one batch of up to 3 calls (~10k tokens), and beyond that, or past ~5 sequential lookups, launches `explore`. | Same; also leaves reading that prepares a writer to that writer's spec. |
| Classify (small or large) | Small: works inline, no feature document. Large: creates the feature document before the first write or writer launch. | Size decides tracking and risk only: a small task still goes to a writer (no feature document); a large task gets the document before the first writer. |
| Write code | Writes it itself by default. | Never; every change goes to a bounded writer with allowed edit surfaces, or the blocker is reported. |
| When a writer launches | Only on a trigger: 2+ independent units with disjoint edit surfaces, each several minutes of work (several files or ~100+ changed lines), launched together; or `context.py` reports that the context reached its threshold (the lower of 150k tokens and 15% of the window). Never for size, file count, a large task alone or price. | Always: one writer per unit of behavior, never while a unit it depends on still runs; independent units with disjoint surfaces together, units sharing a file one at a time. |
| What it may write | Any workspace file; outside the workspace only after the user names the file and confirms the exact diff. | Only scratch outside the workspace, `odd/tasks/*.md`, Engram, Git operations, and files written by `profile.py` or `init.py` after the user confirms; outside the workspace, the same named-file rule. In Claude Code, Codex and Antigravity, the parent edit guard denies its other direct workspace edits (not shell writes). |
| A writer returns | Re-runs one reported command (spot check) and checks the changed files against the edit surface. | Same. |
| The user names another agent | Launches the role that matches the request ("have Codex check this"). | Same. |
| Independent verification (`verify`) | When the change's Risk line names a high-risk item. | Same. |
| Review (`review`, `refute`) | When the user asks (ordinary or dual), or verification passed on a high-risk change. | Same. |
| Review corrections | Inline or with one writer. | Always one writer, with the corrected findings as its spec and the candidate's paths as its surface. |
| A worker exhausts its bound | Names the cause; fixes inline when small and understood, otherwise relaunches once with the diagnosis and a new hypothesis. A repeated cause blocks the unit. | Launches one new writer with the diagnosis, the new evidence and a changed hypothesis or scope; never edits. A repeated cause blocks the unit. |
| Without Orca | Subagents; with no subagent, runs each role inline, one unit at a time. | Subagents; with no subagent, reports the blocker for each pending writer unit and stops it. |
| Verify or review with no worker possible | Runs it itself and says in the close it was not independent. | Same (they only read). |
| Commits, tracking, close | Commits large-task units (a small task only when asked), keeps the feature document and its Engram mirror, closes with outcome, failed or pending checks and next step. Routes: `inline`, `orca:<role>`, `subagent:<role>`. | Same; routes: `orca:<role>`, `subagent:<role>`, `blocked`. |

The modes differ only in who writes and what follows from it; exploring, verifying, reviewing, the spot check and the close follow the same rules.

## Contents

| Path | Purpose |
|---|---|
| `skills/odd-flow/` | The `odd-flow` skill (progressive disclosure: `SKILL.md` plus references and assets) |
| [`orca-plugin/`](orca-plugin/README.md) | Orca panel, status item, and commands for switching session profiles and modes |
| `hooks/hooks.json` | Claude Code hooks: `SessionStart` on startup, resume, clear and compact; `UserPromptSubmit` and `PreToolUse` |
| `hooks/codex-hooks.json` | Codex hooks: `SessionStart` on startup, resume, clear and compact; `UserPromptSubmit`; `PreToolUse` for `apply_patch`, `spawn_agent` and `Bash` |
| `scripts/session-start.py` | Injects the core block of the session's mode (`assets/core-block.md` or `assets/core-block-full-delegation.md`) and the active profile into the session |
| `scripts/prompt-submit.py` | Records a per-session parent or worker marker from the first prompt, recognizing known Orca preambles, a first-line role header, or a trailing `odd-flow-worker: <role> <token>` line from the ODD Flow Orca plugin. The hook accepts only a valid, unused token for that role. The hook consumes a valid, unused token even when another rule already identifies the worker. A bare marker does not identify a worker. The hook rejects a relative `ODD_FLOW_STATE_DIR` and requires `worker-tokens` to be a real directory (not a symlink), mode `0700`, owned by the running user. In full delegation, restates the coordinator or worker rules on each prompt. Gives coordinators a one-time notice when the effective mode changes, including a switch to organic. |
| `scripts/pre-tool-use.py` | Checks edit surface declarations for supported writer launches in both modes; guards the parent's direct Claude Code edits and direct Codex `apply_patch` calls in full delegation |
| `.claude-plugin/` | Claude Code plugin manifest and marketplace |
| `.codex-plugin/plugin.json` | Codex plugin manifest pointing to the shared skill and Codex hooks |
| `.agents/plugins/marketplace.json` | Codex marketplace |

In full delegation, the [parent edit guard](skills/odd-flow/references/mode-full-delegation.md#parent-edit-guard) checks Claude Code `Edit`, `Write` and `NotebookEdit` calls and Codex direct local `apply_patch` calls. It does not guard `Bash` writes. Without an appended marker (for example, when the ODD Flow Orca plugin is not installed), a worker whose first prompt has neither a recognized Orca preamble nor a first-line role header is treated as the parent. The guard covers `Edit`, `Write` and `NotebookEdit` with Code Mode on or off. Code Mode REPL `write()` and `edit()` reach the hook as `Write` and `Edit`.

## Compatibility

odd-flow for Claude Code, Codex, and Antigravity is versioned separately from
the ODD Flow Orca plugin. See the [compatibility table](docs/compatibility.md)
for tested combinations and how to run without optional components.

## Install (Claude Code)

```sh
claude plugin marketplace add alvag/odd-flow
claude plugin install odd-flow@odd-flow
```

For development, run `claude plugin marketplace add "$PWD"` from the checkout instead, or try it without installing with `claude --plugin-dir "$PWD"`.

Verified on 2026-11-24 at `bc59916` with a scratch home and Claude config: marketplace add cloned over SSH. With SSH disabled, it printed “SSH clone failed, retrying with HTTPS” and succeeded. Installation reported odd-flow 0.1.0; `diff -rq --exclude=.git` against an extracted `git archive HEAD` found only Claude's `.in_use` marker.

The skill is invoked as `/odd-flow:odd-flow`. A plain `/odd-flow` was not expanded as a skill call in a headless session (2026-11-23) and reached the model only as text; interactive sessions are unchecked.

Profile commands: `/odd-flow:odd-flow --profile <p>` (this session), `--profile-default <p>`, `--profiles` (list, then pick one for the session or as default), `--create-profile <p>` (guided, from the agents and models Orca and Codex report), `--mode <organic|full-delegation>` (this session) and `--profile-mode <p> <organic|full-delegation>` (saved in the profile, after you confirm the diff).

## Install (Codex)

With Codex CLI 0.171.0 and Python 3 available:

```sh
codex plugin marketplace add alvag/odd-flow --ref main
codex plugin add odd-flow@odd-flow
```

For development, run `codex plugin marketplace add "$PWD"` from the checkout instead.

Codex installs a copy in its plugin cache (`~/.codex/plugins/cache/odd-flow/odd-flow/`). Reinstall the plugin after changing the checkout; edits do not reach the cached copy.

Review the odd-flow hooks in Codex with `/hooks` and trust them if you want to enable them.

Verified on 2026-11-24 at `bc59916` with a scratch home and `CODEX_HOME`: the commands above installed odd-flow 0.1.0; `diff -rq --exclude=.git` against an extracted `git archive HEAD` found no differences.

On 2026-11-23, reinstalling odd-flow 0.1.0 with `codex plugin add odd-flow@odd-flow` refreshed its cache without a version bump. A `diff -rq --exclude=.git` against the checkout found seven differing files and a missing `tests/codex-runtime-check.sh` before reinstalling, and no differences afterward. The cache copy also includes untracked files such as `odd/tasks/codex-packaging.md`. With Codex CLI 0.171.0, SessionStart and UserPromptSubmit completed in each live `codex exec --dangerously-bypass-hook-trust` run. Asked to list the short replies under “Authorized work continuity” without using tools, the parent returned “yes”, “go ahead”, and “eso mismo”, which only the core block lists. A `# Role: write` worker wrote `hello.txt` with a single shell command, made no Orca or subagent attempt, answered `ROLE`, and had a `worker` marker.

Codex uses its own `PreToolUse` manifest. In full delegation, it checks every target of a coordinator's direct local `apply_patch` call. In either mode, it checks the allowed edit surfaces of identifiable writer launches through supported native `spawn_agent` and local Orca forms. It does not enforce writer surfaces after launch or inspect shell write targets. See the [parent edit guard](skills/odd-flow/references/mode-full-delegation.md#parent-edit-guard) and [writer surface checks](skills/odd-flow/references/delegation.md#allowed-edit-surfaces).

## Install (Antigravity)

Clone the GitHub repository first: `agy plugin install` needs a local directory for this plugin.

```sh
git clone https://github.com/alvag/odd-flow
agy plugin install ./odd-flow
```

For development, run `agy plugin install "$PWD"` from the checkout instead. Reinstall after changing the checkout, and review the plugin's hook in Antigravity before relying on it.

The package is a native Antigravity CLI plugin for `agy` 1.5.16 (https://antigravity.google/docs/build-plugins). `.antigravity-plugin/plugin.json` selects the shared `skills/odd-flow` skill, and the root `hooks.json` registers a flat `SessionStart` handler (`python3 -I ./scripts/session-start.py --runtime antigravity`), a flat `PreInvocation` handler (`scripts/prompt-submit.py --runtime antigravity`: worker marking and full-delegation reinjection on the first invocation of each turn, `invocationNum == 0`; the counter is 0-indexed in `agy` 1.5.16 and defaults to `0` when omitted) and a grouped `PreToolUse` handler (`scripts/pre-tool-use.py --runtime antigravity`: parent edit guard for the file-edit tools and writer launch admission for `run_command` and `invoke_subagent`). The hook reads the payload's `conversationId`, uses it as `ANTIGRAVITY_CONVERSATION_ID` for profile resolution (an inherited Claude or Codex id never overrides it), and returns the core block and active profile as an `injectSteps` system message.

Validate a checkout without installing it, with a scratch home:

```sh
scratch=$(mktemp -d)
mkdir -p "$scratch/home" "$scratch/config" "$scratch/data"
HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" agy plugin validate --json "$PWD"
```

The expected result is one skill, one hook, no errors, and one warning: `hooks/hooks.json` is never loaded because Antigravity reads plugin hooks only from the root `hooks.json`. That file belongs to Claude Code. A missing logo is informational.

Verified on 2026-11-24 at `bc59916`: `agy plugin validate --json` on a fresh HTTPS clone reported one skill, one hook, the `hooks/hooks.json` warning, and the missing-logo note.

- Validation: `agy plugin validate`, above.
- Hook fixtures: `tests/antigravity-plugin-check.sh`, which runs the hook script directly and needs no `agy` binary.
- Installed-session smoke test: see the live verification below.

Verified live on 2026-11-24 in the installed plugin with `agy` 1.5.16 inside Orca (`main` `4c3d8a2`): `PreInvocation` fired, and `PreToolUse` denied `write_file` (argument `Path`; the file was not created), `invoke_subagent` (argument `Prompt`; missing `## Allowed edit surfaces`) and `run_command` (argument `CommandLine`; unparseable Orca launch). `invocationNum` is 0-indexed: `0` on the first model call of a turn and `1` on the second, after tool calls.

Also verified live on 2026-11-24 (installed odd-flow 0.2.0 matching `main` `edcf3e0`, `agy` 1.5.16 in Orca, default `claude-gpt` full delegation): the guard denied the coordinator's `edit_file` and left the workspace file unchanged. An external, non-temp `write_file` returned `force_ask` and showed a Create file confirmation; declining left the file absent. In a new session, `edit_file` succeeded after a first prompt starting with `# Role: write` in a plain Orca terminal.

Not validated live or promised: `write_to_file`, `replace_file_content` and `multi_replace_file_content`, mode reinjection mid-session, the profile identity of an interactive `agy` session, and Orca worker enforcement for Antigravity, including the Orca dispatch preamble marker.

## Orca profiles panel

The [ODD Flow Orca plugin](orca-plugin/README.md) shows and switches the odd-flow profile and mode of coordinator sessions in the focused workspace without sending a prompt. Follow the [regular installation instructions](orca-plugin/README.md#install-the-plugin) to install it from this checkout, review its access, and approve it.

## Updating

Run `/odd-flow check [--json]` for a read-only install report, or run `python3 -I skills/odd-flow/scripts/install_check.py [--json]` from the checkout you want to compare against. The report lists missing, changed, or extra shipped files and any error reported when the ODD Flow Orca plugin is not running. Neither command reinstalls anything.

The tokened worker marker requires odd-flow 0.4.0 or newer hooks. Update the ODD Flow Orca plugin and the odd-flow hooks for Claude Code, Codex, and Antigravity together. With mixed versions, the hooks do not recognize the marker and identify workers by the Orca preamble or first-line `# Role:` rule instead. An older hook leaves the token record to expire and be pruned. The plugin still works with odd-flow 0.3.0 hooks because those fallback rules remain in place.

Claude Code enables auto-update per marketplace. It defaults to on for official marketplaces and off for third-party GitHub marketplaces like `alvag/odd-flow`. To enable it, run `/plugin`, open **Marketplaces**, select **odd-flow**, and turn on auto-update. See [Install and manage plugins](https://code.claude.com/docs/en/plugins/install.md).

After the first message in an interactive session, Claude Code waits a random delay of up to ten minutes, then refreshes the marketplace and updates installed plugins on disk. Run `/reload-plugins` to apply the update now, or let the next launch load it. Setting `DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1`, or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` disables this pass unless `FORCE_AUTOUPDATE_PLUGINS=1` is also set. See the [Plugin loading reference](https://code.claude.com/docs/en/plugins/loading.md).

Codex and Antigravity do not auto-update; use the manual commands below. Claude Code can also update manually.

- Claude Code: run `claude plugin marketplace update odd-flow`, then `claude plugin update odd-flow@odd-flow` and restart Claude Code.
- Codex: run `codex plugin marketplace upgrade odd-flow`, then `codex plugin add odd-flow@odd-flow`.
- Antigravity: from the parent directory of the clone, run `git -C ./odd-flow pull`, then `agy plugin install ./odd-flow`.

Claude Code detects updates by reading `version` from `plugin.json` first, then from the marketplace entry if the manifest omits it. odd-flow pins its version, so Claude Code users won't receive a push without a version bump, even with auto-update enabled.

For every change published to `main` that users should receive, bump `version` to the same value in `.claude-plugin/plugin.json`, the `odd-flow` entry in `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`, and `.antigravity-plugin/plugin.json`. Add an entry for the new version to [CHANGELOG.md](CHANGELOG.md) and check with `bash tests/version-check.sh`.

## Profiles

File at `~/.config/odd-flow/profiles.json`, edited by hand or through the profile commands (override with `ODD_FLOW_HOME`). See `skills/odd-flow/references/profiles.md` and `skills/odd-flow/assets/profiles.example.json`.

## Other runtimes

For an agent without the plugin, `skills/odd-flow/scripts/init.py` can write the core block into the global instructions file (see `skills/odd-flow/references/init.md`). To validate a writer spec without a supported launch hook, run `python3 -I skills/odd-flow/scripts/surface.py check <spec-file>`.

## Checks

- Run all test suites with `bash tests/run.sh`.
- `claude plugin validate .`
- `echo '{"source":"startup"}' | python3 -I scripts/session-start.py`
