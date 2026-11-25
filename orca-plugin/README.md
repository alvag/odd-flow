# odd-flow profiles

This Orca sidebar panel shows the active odd-flow profile and mode for non-worker
sessions in the focused workspace, including where each value came from. It also
lists saved profiles. Use **Refresh** to re-read the values. The panel also
refreshes when agent status or the focused workspace changes.

Dispatched workers appear as `<title> — <agent> — <state>`, using the task title
when Orca provides one and the terminal title otherwise. A row is a worker if
Orca reports a task or any local dispatch matches its terminal, regardless of
dispatch state. The panel does not read profile details for worker rows or let
you change their bindings. If the dispatch list is unavailable, the panel shows
the error and keeps the agent titles visible without controls.

For a non-worker Claude, Codex, or Antigravity row with a reported session ID:

- **Profile** switches the profile for the next worker launch. Binding a profile
  also drops the session's mode override.
- **Mode** sets the session to `organic` or `full-delegation`. The agent picks up
  the change on its next prompt.
- **Clear session binding** removes both overrides, so the row returns to the
  file default or to odd-flow's fallback if no default is configured.

The panel does not send an agent prompt. It changes only session bindings, not
`profiles.json`, saved profiles, or the file default.

## Status bar and commands

- The status bar shows `odd: <profile> · <mode>` for a single coordinator
  (hover to see where both values came from), or `odd: <n> sessions` for
  several. It is hidden when there are no coordinators and reports dispatch,
  script, and profile lookup errors. Agent and workspace events, panel changes,
  and a 15-second fallback keep it current.
- **odd-flow: Open profiles panel** opens the panel from the command palette,
  the status bar, or **Mod+Alt+Shift+O** (Cmd on macOS, Ctrl elsewhere). The
  command looks up the single enabled plugin with a key ending in
  `.odd-flow-profiles`. If none or more than one match, set `pluginKey` in the
  plugin's Orca settings to the installed key you want to open.
- **odd-flow: Toggle mode** switches the active mode for a single coordinator.
  If there are zero or several coordinators, or the worker check is unavailable,
  it opens the panel instead. Pick a different profile in the panel.

## Profile script

By default the worker looks for `profile.py` in the newest semver directory in the
Claude odd-flow cache, then the Codex cache, then the Antigravity plugin directory
under `~/.gemini/config/plugins/odd-flow`. In the plugin's Orca settings, set
`profileScript` to the **absolute path** of a trusted `profile.py` to override
discovery. The script must support `list --json`, `show --json`, `use`,
`session-mode`, and `clear`. The worker validates the target against Orca's
current agent list and rechecks local dispatches before running Python for a
mutation. The worker looks for the Orca executable at `ORCA_CLI_COMMAND` (an
absolute file path), on `PATH`, then in
`/Applications/Orca.app/Contents/Resources/bin/orca`. It runs the read-only
`orca orchestration worker-list --environment local --json` command with a
five-second timeout per page and a 60-second cap per scan. The first scan
reads all pages. Later scans start at the newest page and stop after reading
a page with a known dispatch ID. The cache stays in the worker process's
memory and is rebuilt on restart. A failed scan leaves the cache unchanged
and blocks profile reads and mutations for that request. The worker invokes
both Orca and `python3` directly with argument arrays, without a shell.

## Develop

From the repository root:

```sh
orca plugin validate orca-plugin --json
orca plugin test orca-plugin --json
orca plugin check orca-plugin --json
orca plugin dev watch orca-plugin --json
```

`dev watch` loads the plugin and needs your approval. It asks for **trusted
worker** execution, which runs Node, the Orca CLI, and the configured Python
script with your user account's access on the Orca host, plus `agent:read` and `workspace:read`
for the focused workspace's agents and events, and `settings:own` for its own
settings. This version adds commands, a shortcut, status bar and event
subscriptions, so Orca requires a new approval. Only approve code and script
paths you trust. Press Ctrl-C to end the
watch. Orca generates local typings under `.orca/`; do not commit them.
