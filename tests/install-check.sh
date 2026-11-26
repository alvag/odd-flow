#!/usr/bin/env bash
# Exercise the read-only installer diagnosis without the real HOME or CLIs.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python=$(command -v python3)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
cd -L -- "$scratch"
scratch=$PWD
export HOME="$scratch/home" ODD_FLOW_HOME="$scratch/home/odd-state"
export CLAUDE_CONFIG_DIR="$scratch/home/claude-config" CODEX_HOME="$scratch/home/codex-config"
bin="$scratch/bin"
mkdir -p "$bin" "$scratch/empty-bin" "$HOME"

claude="$HOME/claude-folder"
codex="$HOME/.codex/plugins/cache/odd-flow/odd-flow"
agy="$HOME/.gemini/config/plugins/odd-flow"
manifest=.codex-plugin/plugin.json
version=$("$python" -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$root/$manifest")
codex_install="$codex/$version"

copy_install() {
    mkdir -p "$1"
    for item in skills scripts hooks hooks.json .claude-plugin .codex-plugin .antigravity-plugin .agents; do
        cp -R "$root/$item" "$1/"
    done
}

for install in "$claude" "$codex_install" "$agy"; do
    copy_install "$install"
done
codex_path=$(CDPATH= cd -- "$codex_install" && pwd -P)
mkdir -p "$codex_install/.git" "$codex_install/skills/odd-flow/scripts/__pycache__" "$HOME/.odd-flow/worker-tokens"
printf 'ignored\n' > "$codex_install/.git/config"
printf 'ignored\n' > "$codex_install/untracked"
printf 'ignored\n' > "$codex_install/skills/odd-flow/scripts/__pycache__/ignored.pyc"
printf 'worker-token-secret\n' > "$HOME/.odd-flow/worker-tokens/test"

claude_data="$CLAUDE_CONFIG_DIR/plugins/data/odd-flow-test"
claude_default_data="$HOME/.claude/plugins/data/odd-flow-test"
codex_data="$CODEX_HOME/plugins/data/odd-flow-test"
agy_data="$HOME/.gemini/antigravity-cli/plugin_data/odd-flow"
export CLAUDE_PLUGIN_DATA="$HOME/foreign-data" PLUGIN_DATA="$HOME/foreign-data"
record=$(printf '%064d' 1)
mkdir -p "$ODD_FLOW_HOME/sessions" "$claude_data/prompt-sessions" \
    "$claude_default_data/session-modes" "$codex_data/session-modes" \
    "$agy_data/session-modes" "$PLUGIN_DATA/prompt-sessions"
printf '{}\n' > "$ODD_FLOW_HOME/sessions/recent.json"
printf '{}\n' > "$ODD_FLOW_HOME/sessions/old.json"
touch -t 200001010000 "$ODD_FLOW_HOME/sessions/old.json"
printf 'not a binding\n' > "$ODD_FLOW_HOME/sessions/unrelated"
printf 'prompt\n' > "$claude_data/prompt-sessions/$record"
touch -t 200001010000 "$claude_data/prompt-sessions/$record"
ln -s "$record" "$claude_data/prompt-sessions/$(printf '%064d' 2)"
printf 'foreign prompt\n' > "$PLUGIN_DATA/prompt-sessions/$record"
for data in "$claude_default_data" "$codex_data" "$agy_data"; do
    printf 'organic\n' > "$data/session-modes/$record"
    touch -t 200001010000 "$data/session-modes/$record"
done

export CLAUDE_FOLDER="$claude" CLAUDE_VERSION="$version"
export ORCA_VERSION
ORCA_VERSION=$("$python" -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$root/orca-plugin/orca-plugin.json")
cat > "$bin/claude" <<'SH'
#!/bin/bash
[[ "$*" = "plugin list --json" ]] || exit 99
printf '[{"id":"odd-flow@odd-flow","version":"0.3.0","installPath":"/not-used","readFromFolder":"%s","folderVersion":"%s"}]\n' "$CLAUDE_FOLDER" "$CLAUDE_VERSION"
SH
cat > "$bin/orca" <<'SH'
#!/bin/bash
[[ "$*" = "plugin list --json" ]] || exit 99
printf '{"ok":true,"result":{"plugins":[{"pluginKey":"local.odd-flow-profiles","version":"%s","status":"%s","error":"%s"}]}}\n' "$ORCA_VERSION" "${ORCA_STATUS:-running}" "${ORCA_ERROR:-plugin local.odd-flow-profiles is errored after repeated failures}"
SH
chmod +x "$bin/claude" "$bin/orca"

check() {
    label=$1 expected=$2
    shift 2
    result=0
    PATH="$bin" "$python" -I "$root/skills/odd-flow/scripts/install_check.py" "$@" > out 2> err || result=$?
    if [ "$result" -ne "$expected" ]; then
        printf 'FAIL %s: expected exit %s, got %s\n' "$label" "$expected" "$result" >&2
        cat out err >&2
        exit 1
    fi
}

assert_json() {
    "$python" -I - "$1" "$version" "$claude" "$codex_path" "$agy" "$ORCA_VERSION" <<'PY'
import json
from pathlib import Path
import sys

case, version, folder, codex_path, agy, orca_version = sys.argv[1:]
lines = Path("out").read_text().splitlines()
assert len(lines) == 1, lines
assert not Path("err").read_text()
assert "worker-token-secret" not in lines[0]
report = json.loads(lines[0])
assert report["schema"] == "odd-flow.install-check/v1"
rows = {row["runtime"]: row for row in report["installs"]}
assert set(rows) == {"claude", "codex", "antigravity", "orca"}, rows
if case == "sync":
    legacy_report = {key: value for key, value in report.items() if key != "session_state"}
    assert legacy_report == {
        "schema": "odd-flow.install-check/v1",
        "installs": [
            {"runtime": runtime, "status": "in sync", "path": path, "version": version,
             "expected_version": version, "files_differ": []}
            for runtime, path in (("claude", folder), ("codex", codex_path), ("antigravity", agy))
        ] + [
            {"runtime": "orca", "status": "in sync", "version": orca_version,
             "expected_version": orca_version, "plugin_status": "running"}
        ],
        "warnings": [],
    }, legacy_report
    assert report.get("session_state") == {
        "session_bindings": 2, "prompt_sessions": 1, "session_modes": 3,
    }, report
elif case == "unrelated-session-root":
    assert report.get("session_state") == {
        "session_bindings": 2, "prompt_sessions": 0, "session_modes": 3,
    }, report
elif case == "unreadable-session-state":
    assert report.get("session_state") == {
        "status": "unreadable", "reason": "cannot scan session state directories",
    }, report
    assert all(row["status"] == "in sync" for row in rows.values()), rows
    assert "reason" not in report, report
elif case == "marketplace":
    assert rows["claude"]["status"] == "files differ", rows["claude"]
    assert rows["claude"]["path"] == str(Path(folder).with_name("claude-marketplace"))
    assert rows["claude"]["version"] == version
    assert rows["claude"]["files_differ"] == ["hooks.json"]
elif case == "extra-shipped":
    assert rows["codex"]["status"] == "files differ", rows["codex"]
    assert rows["codex"]["files_differ"] == ["skills/stale-skill/SKILL.md"]
elif case == "hostile-claude":
    assert rows["claude"]["status"] == "files differ", rows["claude"]
    assert rows["claude"]["path"] == str(Path(folder).with_name("claude-\u202efolder"))
    assert rows["claude"]["files_differ"] == ["skills/stale\n\u202escript"]
elif case == "shipped-directory-is-file":
    assert rows["codex"]["status"] == "unreadable", rows["codex"]
    assert rows["codex"]["reason"] == "cannot read shipped files", rows["codex"]
    assert "path" not in rows["codex"], rows["codex"]
elif case in ("orca-error", "orca-error-controls"):
    assert rows["orca"]["status"] == "in sync", rows["orca"]
    assert rows["orca"]["plugin_status"] == "errored"
    assert rows["orca"].get("plugin_error") == (
        "plugin local.odd-flow-profiles is errored after repeated failures"
    ), rows["orca"]
elif case == "orca-error-format":
    assert rows["orca"].get("plugin_error") == "plugin\u202e error\u200b", rows["orca"]
elif case == "orca-error-long":
    assert rows["orca"].get("plugin_error") == "x" * 200 + "tail", rows["orca"]
elif case == "cli-timeout":
    for runtime in ("claude", "orca"):
        assert rows[runtime]["status"] == "unreadable", rows[runtime]
        assert "timed out" in rows[runtime]["reason"] and "30" in rows[runtime]["reason"], rows[runtime]
        assert "path" not in rows[runtime]
    assert rows["codex"]["status"] == rows["antigravity"]["status"] == "in sync", rows
elif case == "drift":
    assert rows["claude"]["status"] == "version differs"
    assert rows["codex"]["status"] == "files differ"
    assert rows["codex"]["files_differ"] == ["hooks/codex-hooks.json", "scripts/session-start.py"]
    assert rows["orca"]["status"] == "version differs"
    assert report["warnings"] == [
        "Claude Code 0.3.0: the Orca tokened marker requires odd-flow hooks 0.4.0 or newer."
    ]
elif case == "unreadable":
    assert rows["claude"]["status"] == rows["antigravity"]["status"] == "unreadable", rows
    assert rows["claude"]["reason"] and rows["antigravity"]["reason"]
    reason_text = rows["claude"]["reason"] + rows["antigravity"]["reason"]
    assert str(Path(folder).parent) not in reason_text
    assert "cli-secret" not in lines[0]
    assert "path" not in rows["claude"] and "path" not in rows["antigravity"]
    assert rows["codex"]["status"] == "files differ"
else:
    assert all(row["status"] == "not installed" for row in rows.values()), rows
    assert report.get("session_state") == {
        "session_bindings": 0, "prompt_sessions": 0, "session_modes": 0,
    }, report
PY
}

cp -R "$HOME" "$scratch/before"
check sync 0 --json
assert_json sync
check human 0
grep -Fx "Claude Code: in sync [$claude] (odd-flow $version)" out
grep -Fx "Codex: in sync [$codex_path] (odd-flow $version)" out
grep -Fx "Antigravity: in sync [$agy] (odd-flow $version)" out
grep -Fx "ODD Flow Orca plugin: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: running)" out
grep -F 'ignored' out
grep -Fx 'Session state: 2 session binding(s), 1 prompt-hook record(s), 3 mode-notice record(s)' out
diff -r "$scratch/before" "$HOME"

if [ "$(id -u)" -ne 0 ]; then
    unrelated_config="$HOME/unrelated-config"
    unrelated_data="$unrelated_config/plugins/data"
    mkdir -p "$unrelated_data/other-plugin"
    chmod 400 "$unrelated_data"
    CLAUDE_CONFIG_DIR="$unrelated_config" check unrelated-session-root 0 --json
    chmod 700 "$unrelated_data"
    assert_json unrelated-session-root
fi

printf 'not a directory\n' > "$codex_data/prompt-sessions"
check unreadable-session-state 0 --json
assert_json unreadable-session-state
check human-unreadable-session-state 0
grep -Fx 'Session state: unreadable (cannot scan session state directories)' out
rm "$codex_data/prompt-sessions"

hostile_claude=$(printf '%s/claude-\342\200\256folder' "$HOME")
hostile_name=$(printf 'stale\n\342\200\256script')
cp -R "$claude" "$hostile_claude"
touch "$hostile_claude/skills/$hostile_name"
CLAUDE_FOLDER="$hostile_claude" check hostile-claude 1 --json
assert_json hostile-claude
CLAUDE_FOLDER="$hostile_claude" check human-hostile-claude 1
grep -Fx "Claude Code: files differ [$claude] (odd-flow $version): skills/stale script" out

cp "$bin/claude" "$scratch/claude-folder"
cp -R "$claude" "$HOME/claude-marketplace"
printf '\n' >> "$HOME/claude-marketplace/hooks.json"
cat > "$bin/claude" <<'SH'
#!/bin/bash
[[ "$*" = "plugin list --json" ]] || exit 99
printf '[{"id":"odd-flow@odd-flow","version":"%s","installPath":"%s/claude-marketplace"}]\n' "$CLAUDE_VERSION" "$HOME"
SH
check marketplace 1 --json
assert_json marketplace
cp "$scratch/claude-folder" "$bin/claude"

mkdir -p "$codex_install/skills/stale-skill"
printf -- '---\nname: stale\n---\n' > "$codex_install/skills/stale-skill/SKILL.md"
check extra-shipped 1 --json
assert_json extra-shipped
rm -r "$codex_install/skills/stale-skill"

mv "$codex_install/hooks" "$scratch/codex-hooks"
printf 'not a directory\n' > "$codex_install/hooks"
check shipped-directory-is-file 3 --json
assert_json shipped-directory-is-file
rm "$codex_install/hooks"
mv "$scratch/codex-hooks" "$codex_install/hooks"

export ORCA_STATUS=errored
check orca-error 0 --json
assert_json orca-error
check human-orca-error 0
grep -F 'Orca status: errored; plugin local.odd-flow-profiles is errored after repeated failures' out
export ORCA_ERROR='\nplugin local.odd-flow-profiles is errored\r\n\t after\u001b\u009b repeated\u2028failures\u007f'
check orca-error-controls 0 --json
assert_json orca-error-controls
check human-orca-error-controls 0
grep -Fx "ODD Flow Orca plugin: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: errored; plugin local.odd-flow-profiles is errored after repeated failures)" out
grep -F 'Orca reports its listed version, state, and any error for a non-running plugin.' out
export ORCA_ERROR='plugin\u202e error\u200b'
check orca-error-format 0 --json
assert_json orca-error-format
check human-orca-error-format 0
grep -Fx "ODD Flow Orca plugin: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: errored; plugin error)" out
error_prefix=$(printf '%200s' '' | tr ' ' x)
export ORCA_ERROR="${error_prefix}tail"
check orca-error-long 0 --json
assert_json orca-error-long
check human-orca-error-long 0
grep -Fx "ODD Flow Orca plugin: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: errored; ${error_prefix}...)" out
unset ORCA_ERROR
unset ORCA_STATUS

result=0
PATH="$bin" "$python" -I - "$root/skills/odd-flow/scripts/install_check.py" --json > out 2> err <<'PY' || result=$?
import runpy
import subprocess
import sys
from unittest.mock import patch


def timed_out(command, *, timeout=None, **kwargs):
    assert timeout == 30, (command, timeout)
    raise subprocess.TimeoutExpired(command, timeout)


sys.argv.pop(0)
with patch("subprocess.run", side_effect=timed_out):
    runpy.run_path(sys.argv[0], run_name="__main__")
PY
if [ "$result" -ne 3 ]; then
    printf 'FAIL cli-timeout: expected exit 3, got %s\n' "$result" >&2
    cat out err >&2
    exit 1
fi
assert_json cli-timeout

CLAUDE_VERSION=0.3.0
orca_checkout_version=$ORCA_VERSION
ORCA_VERSION=0.0.1
printf '\n' >> "$codex_install/hooks/codex-hooks.json"
rm "$codex_install/scripts/session-start.py"
check drift 1 --json
assert_json drift
check human-drift 1
grep -Fx "Claude Code: version differs [$claude] (odd-flow $CLAUDE_VERSION; checkout odd-flow $version)" out
grep -Fx "ODD Flow Orca plugin: version differs (ODD Flow Orca plugin $ORCA_VERSION; checkout ODD Flow Orca plugin $orca_checkout_version; Orca status: running)" out
grep -Fx "Warning: Claude Code (odd-flow $CLAUDE_VERSION): the Orca tokened marker requires odd-flow hooks 0.4.0 or newer." out
grep -Fx "Codex: files differ [$codex_path] (odd-flow $version): hooks/codex-hooks.json, scripts/session-start.py" out

cat > "$bin/claude" <<'SH'
#!/bin/bash
printf 'cli-secret\n' >&2
printf 'invalid JSON\n'
SH
rm "$agy/.antigravity-plugin/plugin.json"
mkdir "$agy/.antigravity-plugin/plugin.json"
check unreadable 3 --json
assert_json unreadable

bin="$scratch/empty-bin"
export HOME="$scratch/missing-home" ODD_FLOW_HOME="$scratch/missing-home/odd-state"
export CLAUDE_CONFIG_DIR="$scratch/missing-home/claude-config" CODEX_HOME="$scratch/missing-home/codex-config"
check absent 0 --json
assert_json absent

check usage 2 --unknown
test ! -s out
grep -F 'usage:' err
printf 'install-check: passed\n'
