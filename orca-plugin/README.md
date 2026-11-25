# odd-flow profiles

View and switch odd-flow profiles and modes for agent sessions in Orca's focused
workspace. The panel changes session bindings without sending an agent prompt.

## Load the plugin

Use Orca 1.4.259 or newer and odd-flow 0.3.0 or newer. Make `python3` available
to Orca. From this repository's root on the Orca host, load the checkout as a
development folder:

```sh
orca plugin dev load orca-plugin --json
```

Review the access Orca reports. Only if you trust the plugin code and the
Python script it will run, repeat the command with the fingerprint Orca returned:

```sh
orca plugin dev load orca-plugin --json --approve <fingerprint>
```

For a regular install, use `orca plugin install ./orca-plugin --json` and
repeat that command with the returned fingerprint after reviewing the access.
Orca also supports GitHub tree URLs that point to the plugin folder and catalog
entries that set `source.path` to `orca-plugin`.

The manifest requests `agent:read` for agent status events and
`workspace:read` to list agents in the focused workspace and receive
workspace change events. `settings:own` allows the plugin to read and
change its own settings; the plugin uses it to read the values below.
It uses `trusted-worker` execution: Node, the Orca CLI, and the selected Python
script run with your account's access on the Orca host. The status item and
commands add no capability grants. In a live dev-folder run, changing only
worker code put the plugin back into pending approval (`needsReconsent`) with
a new fingerprint, despite Orca's approval text saying later code edits don't
need re-approval. If that happens, review the access again and use the new
fingerprint.

## Settings

Both settings are optional.

- **`profileScript`**: Leave blank to use the installed odd-flow. The plugin
  checks the newest semver directory in the Claude cache, then the newest
  in the Codex cache, then the Antigravity installation under
  `~/.gemini/config/plugins/odd-flow`. The panel shows the path and source
  it selected. To override that choice, set the absolute path to a trusted
  `profile.py` that supports `list --json`, `show --json`, `use`,
  `session-mode`, and `clear`.
- **`pluginKey`**: Set this to the installed key to use when opening the
  panel. When blank, the command looks for exactly one installed entry whose
  key ends in `.odd-flow-profiles` and whose status is a string other than
  `disabled`. If there are no matches or several, find the intended key
  with `orca plugin list --json` and set it explicitly. A local load uses
  `local.odd-flow-profiles`.

## Use the panel

Run **odd-flow: Open profiles panel** from the command palette, press
**Mod+Alt+Shift+O** (Mod is Cmd on macOS and Ctrl elsewhere), or click the
odd-flow status item. All three open the same sidebar panel without
changing a binding.

The panel shows the current profile, mode, and sources for non-worker sessions.
It refreshes on agent status and workspace changes. Use **Refresh** to re-read
values on demand.

The controls below require a non-worker session with a session ID. A live
check confirmed only for Claude that Orca reports the same session ID that
`profile.py` uses. Codex and Antigravity rows are expected to work but have
not been tested live.

| Control | What changes | When it applies |
|---|---|---|
| **Profile** | Binds a saved profile and drops any session mode override, so the new profile's mode applies. | The next worker launch uses the new profile. If the effective mode changes, the agent picks it up on its next prompt. |
| **Mode** | Sets a session-only override to `organic` or `full-delegation` without changing the profile. | The agent picks it up on its next prompt. |
| **Reset to defaults** | Removes both session overrides. The panel shows the file default, or odd-flow's fallback if no default is configured. | The next worker launch uses the resolved profile; any effective mode change reaches the agent on its next prompt. |

An agent launched with `ODD_PROFILE` or `ODD_ORCHESTRATOR_MODE` keeps using
those values after a reset, even though the panel shows the file default.

With the updated odd-flow runtime hooks, the next prompt in a coordinator
session gets a one-time notice when the effective mode differs from the last
recorded mode. The notice tells the agent that the previous mode's rules no
longer apply. Switching does not interrupt a running turn or change an
already launched worker.

Workers appear as a title line only: `<title> — <agent> — <state>`. The
panel uses the task title if Orca provides one, otherwise the terminal
title when available. Orca can leave `agents.list`'s `task` field null for
terminal workers, so the plugin checks the local dispatch list too. Any
matching dispatch terminal counts, regardless of dispatch state. Worker
rows have no profile details or controls. If the dispatch check fails,
the panel shows the error and leaves only the title lines; the worker
blocks profile reads and binding changes rather than guessing.

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
- **odd-flow: Toggle mode** flips the mode only when there is exactly one
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

- If the selected script does not accept `--json` for profile or session
  lookups, the panel and status tooltip report:
  `odd-flow 0.3.0 or newer is required (found <script path>). Update the odd-flow plugin, or set profileScript to a newer profile.py.`
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

## Develop

From the repository root:

```sh
orca plugin validate orca-plugin --json
orca plugin test orca-plugin --json
orca plugin check orca-plugin --json
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
