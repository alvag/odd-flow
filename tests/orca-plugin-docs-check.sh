#!/usr/bin/env bash
set -eu
cd -- "$(dirname -- "$0")/.."

readme=orca-plugin/README.md
worker=orca-plugin/src/worker.ts
manifest=orca-plugin/orca-plugin.json
failed=0

require_text() {
    if ! grep -qF -- "$2" "$1"; then
        printf 'FAIL %s: missing %s\n' "$1" "$2" >&2
        failed=1
    fi
}

for fragment in ' started' ' ended: ' ' (aborted)' 'switched to ' \
    'opened panel' 'could not open panel' 'could not read workspace state' \
    'could not read current mode' 'could not switch to ' 'keySource=' 'key=' \
    'Command signal was aborted.' 'Could not update odd-flow status:'; do
    require_text "$worker" "$fragment"
done

for fragment in 'odd-flow.openProfiles started' 'odd-flow.toggleMode started' \
    'ended: success' 'ended: error' '(aborted)' 'switched to ' 'opened panel (' \
    'could not open panel (' 'could not read workspace state' \
    'could not read current mode' 'could not switch to ' 'keySource=setting' \
    'keySource=detected' 'keySource=unresolved' 'key=<key>' 'key=unresolved' \
    'key=[redacted]' 'Command signal was aborted.' 'Could not update odd-flow status:' \
    'Mod+Alt+Shift+O' 'profileScript' 'pluginKey'; do
    require_text "$readme" "$fragment"
done

require_text "$readme" '| **Reset to defaults** |'
require_text "$readme" 'An agent launched with `ODD_PROFILE` or `ODD_ORCHESTRATOR_MODE` keeps using'
require_text "$readme" 'those values after a reset, even though the panel shows the file default.'
require_text "$readme" 'The ODD Flow Orca plugin requires odd-flow and does not work on its own.'
require_text "$readme" 'orca plugin install ./orca-plugin --json --approve <fingerprint>'
require_text "$readme" "Orca may ask for approval again when the plugin's code changes."
require_text "$readme" 'the default `onError`, `"pass"`'
require_text "$readme" 'The tokened marker requires odd-flow 0.4.0 or newer hooks.'
require_text "$readme" 'Update the ODD Flow Orca plugin and the odd-flow hooks together'
require_text "$readme" 'falls back to the Orca preamble or first-line `# Role:` rule.'
require_text "$readme" 'An older hook leaves the record to expire and be pruned.'
require_text "$readme" 'relative `ODD_FLOW_STATE_DIR`'
require_text "$readme" 'directory (not a symlink), mode `0700`, and owned by the running user.'

require_text "$manifest" '"key": "Mod+Alt+Shift+O"'
if grep -nE '(^|[^[:alnum:]_])[TSL][0-9]+([^[:alnum:]_]|$)' "$readme" README.md CHANGELOG.md; then
    printf 'FAIL docs: internal task identifiers\n' >&2
    failed=1
fi

exit "$failed"
