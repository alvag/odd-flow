# ODD Flow Orca plugin

Use the ODD Flow panel to view and switch profiles and modes for agent sessions
in Orca's focused workspace without sending an agent prompt.

The ODD Flow Orca plugin requires odd-flow and does not work on its own.
Install odd-flow for Claude Code, Codex, or Antigravity.

The ODD Flow Orca plugin is versioned separately from odd-flow. See the
[compatibility table](../docs/compatibility.md) for tested combinations.

## Install the plugin

First install odd-flow 0.3.0 or newer for
[Claude Code](../README.md#install-claude-code),
[Codex](../README.md#install-codex), or
[Antigravity](../README.md#install-antigravity). The Orca plugin cannot
work without it. Use Orca 1.4.259 or newer and make `python3` available to Orca.

To install from GitHub, clone the repository on the Orca host and enter it:

```sh
git clone https://github.com/alvag/odd-flow.git
cd odd-flow
```

From the root of that clone or an existing checkout, run:

```sh
orca plugin install ./orca-plugin --json
```

Review the access Orca reports. Only if you trust the plugin code and the
Python script it will run, repeat the command below, replacing
`<fingerprint>` with the fingerprint Orca returned:

```sh
orca plugin install ./orca-plugin --json --approve <fingerprint>
```

A regular folder install uses the plugin key `local.odd-flow-profiles`.
On 2026-11-26, `orca plugin list --json` showed that key with `isDev` set to
`false` and source kind `local-path`.

Installing directly from a GitHub URL to the `orca-plugin/` folder
does not work in Orca 1.4.277. The observed command was:

```sh
orca plugin install https://github.com/alvag/odd-flow/tree/main/orca-plugin --json
```

It exited with code 1 and error code `plugin_not_found`:

> https://github.com/alvag/odd-flow has no tag or branch named main/orca-plugin.

The manifest requests `agent:read` for agent status events and
`workspace:read` to list agents in the focused workspace and receive
workspace change events. `settings:own` allows the plugin to read and
change its own settings; the plugin uses it to read the values below.
It uses `trusted-worker` execution: Node, the Orca CLI, and the selected Python
script run with your account's access on the Orca host. The status item and
commands add no capability grants.

## Develop the plugin from a checkout

When editing the plugin, use a development folder instead of a regular
install so Orca can reload it as files change. From this repository's root
on the Orca host, run:

```sh
orca plugin dev load orca-plugin --json
```

Review the access Orca reports. If you approve it, rerun with the returned
fingerprint:

```sh
orca plugin dev load orca-plugin --json --approve <fingerprint>
```

Even a change to worker code alone can return the development plugin to
pending approval (`needsReconsent`). If that happens, review the access again
and use the new fingerprint.

## Worker dispatch prompts

For Orca orchestration prompts, the `agent.prompt.before` hook takes the first
matching `# Role: <role>` line and appends `odd-flow-worker: <role> <token>` on
its own line. The role is lowercase and the token is 32 lowercase hexadecimal
characters. Appending leaves the start of the prompt intact, and the trailing
marker lets odd-flow still recognize a worker if the Orca preamble or role
line changes.

Before adding the marker, the hook writes a private record under
`$ODD_FLOW_STATE_DIR/worker-tokens/` (default: `~/.odd-flow/worker-tokens/`).
The plugin reads `ODD_FLOW_STATE_DIR` from the Orca app's environment; the
hooks read it from the agent process's environment, not necessarily a shell.
Set the same absolute directory in both environments or leave it unset in both
to use `~/.odd-flow`.
When issuing a new token, the plugin makes a best-effort attempt to remove
digest-named records whose numeric `issuedAt` is older than 15 minutes. Records
it cannot read or parse, records without a numeric `issuedAt`, and other files
stay.

Both the ODD Flow Orca plugin and the odd-flow prompt hook reject a
relative `ODD_FLOW_STATE_DIR`. The `worker-tokens` directory must be a real
directory (not a symlink), mode `0700`, and owned by the running user.
The ODD Flow Orca plugin checks ownership on platforms that expose the user ID.
If the plugin cannot issue a token, it leaves the prompt unchanged and logs
the role, reason, and directory, but not the token.

The plugin also leaves prompts unchanged outside orchestration, without a
matching role, or when the last non-empty line already has a tokened marker.
A bare marker does not stop issuance. If the hook fails or times out, Orca
passes the original prompt through (the default `onError`, `"pass"`).

The tokened marker requires odd-flow 0.4.0 or newer hooks.
Update the ODD Flow Orca plugin and the odd-flow hooks together
for Claude Code, Codex, and Antigravity. With mixed versions, the marker is
not recognized and worker identification
falls back to the Orca preamble or first-line `# Role:` rule.
An older hook leaves the record to expire and be pruned. The plugin still
works with odd-flow 0.3.0 hooks because those fallback rules remain in place.

Orca may ask for approval again when the plugin's code changes. Get the
user's approval before reloading or reinstalling the plugin.

## Settings

Both settings are optional.

- **`profileScript`**: Leave blank to find `skills/odd-flow/scripts/profile.py`
  in this order:
  1. The newest semantic-version directory in the Claude Code cache
     (`~/.claude/plugins/cache/odd-flow/odd-flow`).
  2. The newest semantic-version directory in the Codex cache
     (`~/.codex/plugins/cache/odd-flow/odd-flow`).
  3. The Antigravity installation (`~/.gemini/config/plugins/odd-flow`).

  The plugin picks the newest version within each cache, not across caches.
  If that directory has no script, it checks the next location rather than
  an older directory. The panel shows the selected path and source. To
  override the choice, set the absolute path to a trusted
  `profile.py` that supports `list --json`, `show --json`, `use`,
  `session-mode`, and `clear`.
- **`pluginKey`**: Set this to the installed key to use when opening the
  ODD Flow panel. When blank, the command looks for exactly one installed entry
  whose key ends in `.odd-flow-profiles` and whose status is a string other than
  `disabled`. If there are no matches or several, find the intended key
  with `orca plugin list --json` and set it explicitly. A local load uses
  `local.odd-flow-profiles`.

## Use the panel

Run **ODD Flow: Open panel** from the command palette, press
**Mod+Alt+Shift+O** (Mod is Cmd on macOS and Ctrl elsewhere), or click the
odd-flow status item. All three open the same sidebar panel without
changing a binding.

When multiple coordinator sessions are open in the focused workspace, the
panel shows one session at a time with a selector at the top. By default
it follows the session whose agent most recently became `working`, and
you can pin a specific session until you switch back to **Follow active
session** or that session closes. **Needs you** still lists attention
items across all sessions so blocked agents in other tabs remain visible.

Each coordinator's dashboard starts with **Needs you** when the session is
blocked or an active worker is blocked, has a pending question, or has
escalated. An idle or turn-finished session instead shows **waiting for you** on its session
card. The card also shows the effective profile, role routing, and mode, with
their sources. It refreshes on agent status and workspace changes. Use
**Refresh** to re-read values on demand.

**Feature tasks** shows progress for the feature document owned by the
session (whose tasks most recently cite it), or an unowned document on the
current branch as a fallback, with completed tasks folded. Hidden runs do not
establish document ownership, but the branch fallback can still show their
documents. Without a matching feature document, **Current work** shows the
newest visible Orca run for that coordinator, its tasks, and the latest result.
A run is hidden when all its tasks have a completion timestamp, none has an
active dispatch, and the newest of the run's creation time and its tasks'
creation and completion times is more than 12 hours old.
**Current work** also shows a Git summary;
when there is no feature document or run, only the Git summary appears. If the
workspace path is unavailable, the panel shows a note rather than guessing.

The controls below require a non-worker session with a session ID. A live
check confirmed only for Claude that Orca reports the same session ID that
`profile.py` uses. Codex and Antigravity rows are expected to work but have
not been tested live.

| Control | What changes | When it applies |
|---|---|---|
| **Profile** | Binds a saved profile and drops any session mode override, so the new profile's mode applies. | The next worker launch uses the new profile. If the effective mode changes, the agent picks it up on its next prompt. |
| **Mode toggle** | Sets a session-only override to `organic` or `full-delegation` without changing the profile. | The agent picks it up on its next prompt. |
| **Reset to defaults** | Removes both session overrides. The panel shows the file default, or odd-flow's fallback if no default is configured. | The next worker launch uses the resolved profile; any effective mode change reaches the agent on its next prompt. |

An agent launched with `ODD_PROFILE` or `ODD_ORCHESTRATOR_MODE` keeps using
those values after a reset, even though the panel shows the file default.

With the updated odd-flow runtime hooks, the next prompt in a coordinator
session gets a one-time notice when the effective mode differs from the last
recorded mode. The notice tells the agent that the previous mode's rules no
longer apply. Switching does not interrupt a running turn or change an
already launched worker.

**Workers** shows the coordinator's dispatches, active first. It excludes
dispatches from hidden runs and dispatches for tasks without a run that
completed more than 12 hours ago and have no active dispatch. Each worker
has a status badge and a one-line title, followed by its agent/model and live
elapsed time or final duration. Finished workers beyond the newest three are
folded. Worker rows have no profile details or controls.

Without a dispatch dashboard, worker agent rows fall back to a title line
using the task title or, when absent, the terminal title. Orca can leave
`agents.list`'s `task` field null for terminal workers, so the plugin checks
the local dispatch list too. Any matching dispatch terminal counts when
deciding whether to allow profile controls, regardless of dispatch state.
If that check fails, the panel shows the error and leaves only the title
lines; the worker blocks profile reads and binding changes rather than
guessing.

The plugin revalidates the target session and dispatches before a write.
It changes odd-flow bindings only through `profile.py use`,
`profile.py session-mode`, and `profile.py clear`. It never edits
`profiles.json`, creates or changes saved profiles, sets the file default,
sends a prompt, or launches an agent.

## Status bar and mode shortcut

- With one coordinator in the focused workspace, the status shows
  `odd: <profile> · <mode>`; hover to see the sources. With several it
  shows `odd: <n> sessions`. With none it is hidden unless a workspace
  read or worker check fails. It can also show script, profile lookup, and
  panel-open errors. Agent and workspace events, binding changes, and a
  15-second fallback refresh the item.
- **ODD Flow: Toggle mode** flips the mode only when there is exactly one
  supported non-worker session with a session ID in the focused workspace.
  It switches the session override, so the same next-prompt timing applies.
  With zero or several eligible sessions, an unavailable worker check, or
  a target that no longer qualifies on re-check, it opens the panel
  instead. A workspace read or current-mode lookup error is reported
  rather than changing the mode. Pick profiles in the panel.
- Orca caps status text at 64 UTF-16 code units and tooltips at 256. The
  plugin truncates longer values with an ellipsis. Orca displays line
  breaks in both fields as spaces.

## Troubleshoot

- If no installed script is found with `profileScript` blank, the panel
  reports: `No installed profile.py was found. Set profileScript to its absolute path in Orca Settings.`
  The status item normally shows `odd: script unavailable` with the same
  message in its tooltip.
- If the selected script does not accept `--json` for profile or session
  lookups, the panel and status tooltip report:
  `odd-flow 0.3.0 or newer is required (found <script path>). Update the odd-flow plugin, or set profileScript to a newer profile.py.`
  The status item normally shows `odd: show failed`.
  See [Updating odd-flow](../README.md#updating) for the runtime update steps.
- For a worker-check error, inspect the panel error or status tooltip.
  The worker looks for `orca` at an absolute file path in `ORCA_CLI_COMMAND`,
  on `PATH`, then at
  `/Applications/Orca.app/Contents/Resources/bin/orca`. It runs the read-only
  `orca orchestration worker-list --environment local --json`. Missing,
  invalid, Run-scoped, or timed-out results block profile reads and changes.
- If the command or shortcut appears to do nothing, check the worker logs
  for the local install (substitute the installed key if different):

  ```sh
  orca plugin logs local.odd-flow-profiles --json
  ```

  `odd-flow.openProfiles started` or `odd-flow.toggleMode started` means
  the worker received the command. The matching `ended: success` or
  `ended: error` line reports its result; `(aborted)` marks cancellation.
  - For **Toggle mode**, `switched to <mode>` reports a successful mode
    write. `opened panel (<reason>)` and `could not open panel (<reason>)`
    report whether a fallback opened the panel, not a mode switch.
  - `could not read workspace state`, `could not read current mode`, and
    `could not switch to <mode>` identify the failed toggle step.
  - Panel-open attempts log `keySource=setting` for an explicit key,
    `keySource=detected` for discovery, or `keySource=unresolved` if the
    command failed before choosing a source. The key field is `key=<key>`
    (shortened if needed), `key=unresolved` if no key was selected, or
    `key=[redacted]` if the key is unsafe to log. Failures report a stage or
    local validation error, not raw CLI output.
  - `Command signal was aborted.` confirms cancellation; the log omits the
    branch, fallback reason, and panel error in that case.

  You can also try opening the local panel directly to see the CLI result:

  ```sh
  orca plugin open local.odd-flow-profiles --panel odd-flow-profiles --json
  ```

  `Could not update odd-flow status:` means Orca rejected a status update,
  not that the command itself failed. The reason is shortened or redacted
  when needed.
- Orca kills the worker when 64 events are pending (`exceeded the pending
  event limit`) or one event runs for more than 300 seconds
  (`did not finish within 300000ms`). Orca counts any unexpected worker
  exit or failed start, not just these event failures. It retries up to
  three times with backoff, then marks the plugin errored if the worker
  fails again. Run `orca plugin restart <key>` to clear the error state,
  using the installed plugin key.

## Develop

From the repository root:

```sh
orca plugin validate orca-plugin --json
orca plugin test orca-plugin --json
```

Use the development load and approval steps above to try the panel live.
For a stream of reloads and logs, use `orca plugin dev watch orca-plugin --json`
with the same approval procedure if Orca asks. Press Ctrl-C to stop the watch.
Orca generates local typings under `.orca/`; do not commit them.

The worker invokes Orca and Python directly with argument arrays, without
a shell. The dispatch cache lives in the worker process. A cold scan reads
all pages; later scans start at the newest page and stop after processing a
page with a known dispatch ID. Each page has up to five seconds, with a
60-second cap per scan. Failed scans do not advance the cache; restarting
the worker clears it.
