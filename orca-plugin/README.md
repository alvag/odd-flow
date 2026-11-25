# odd-flow profiles

This read-only Orca sidebar panel shows the agents in the focused workspace and
each agent's effective odd-flow profile and mode, including where each value came
from. It also lists saved profiles. Use **Refresh** to re-read the values at any
time. The panel also refreshes when agent status or the focused workspace changes.
It does not switch profiles or modes or edit odd-flow files.

## Profile script

By default the worker looks for `profile.py` in the newest semver directory in the
Claude odd-flow cache, then the Codex cache, then the Antigravity plugin directory
under `~/.gemini/config/plugins/odd-flow`. In the plugin's Orca settings, set
`profileScript` to the **absolute path** of a trusted `profile.py` to override
discovery. The script must support `list --json` and `show --json`, and
`python3` must be available on the Orca host. The worker runs neither command
through a shell.

## Develop

From the repository root:

```sh
orca plugin validate orca-plugin --json
orca plugin test orca-plugin --json
orca plugin check orca-plugin --json
orca plugin dev watch orca-plugin --json
```

`dev watch` loads the plugin and needs your approval. It asks for **trusted
worker** execution, which runs Node and the configured Python script with your
user account's access on the Orca host, plus `agent:read` and `workspace:read`
for the focused workspace's agents and events, and `settings:own` for its own
setting. Only approve code and script paths you trust. Press Ctrl-C to end the
watch. Orca generates local typings under `.orca/`; do not commit them.
