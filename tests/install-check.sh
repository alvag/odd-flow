#!/usr/bin/env bash
# Exercise the read-only installer diagnosis without the real HOME or CLIs.
set -eu
unset ODD_ORCHESTRATOR_MODE ODD_FLOW_PROFILE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID \
    CODEX_SESSION_ID ANTIGRAVITY_CONVERSATION_ID
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
source_field=${ORCA_SOURCE-',"source":{"kind":"local-path","resolvedCommit":null}'}
printf '{"ok":true,"result":{"plugins":[{"pluginKey":"local.odd-flow-profiles","version":"%s","status":"%s","error":"%s"%s}%s]}}\n' "$ORCA_VERSION" "${ORCA_STATUS:-running}" "${ORCA_ERROR:-plugin local.odd-flow-profiles is errored after repeated failures}" "$source_field" "${ORCA_EXTRA:-}"
SH
chmod +x "$bin/claude" "$bin/orca"

check() {
    label=$1 expected=$2
    shift 2
    result=0
    PATH="$bin" "$python" -I "${check_root:-$root}/skills/odd-flow/scripts/install_check.py" "$@" > out 2> err || result=$?
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
if case in ("orca-catalog", "orca-duplicate", "orca-commit-diff"):
    orca = {row["plugin_key"]: row for row in report["installs"] if row["runtime"] == "orca"}
    _, catalog_version, catalog_commit = Path("catalog-release").read_text().split()
    local_key = "local.odd-flow-profiles"
    catalog_key = "mirror.odd-flow-profiles" if case == "orca-duplicate" else "alvag.odd-flow-profiles"
    assert set(orca) == {local_key, catalog_key}, orca
    assert orca[local_key]["source"] == "folder", orca
    assert orca[local_key]["version"] == orca[local_key]["expected_version"] == "9.8.7", orca
    assert orca[local_key]["status"] == "in sync", orca
    assert orca[catalog_key]["source"] == "catalog", orca
    assert orca[catalog_key]["source_commit"] == (
        catalog_commit if case == "orca-catalog" else "different-commit"
    ), orca
    assert orca[catalog_key]["plugin_status"] == "idle", orca
    assert orca[catalog_key]["expected_version"] == catalog_version, orca
    if case == "orca-catalog":
        assert orca[local_key]["plugin_status"] == "disabled", orca
        assert orca[catalog_key]["version"] == catalog_version, orca
        assert orca[catalog_key]["status"] == "in sync", orca
        assert report["warnings"] == [], report
    elif case == "orca-commit-diff":
        assert orca[catalog_key]["version"] == catalog_version, orca
        assert orca[catalog_key]["expected_commit"] == catalog_commit, orca
        assert orca[catalog_key]["status"] == "commit differs", orca
    else:
        assert orca[catalog_key]["version"] == "0.0.1", orca
        assert orca[catalog_key]["status"] == "version differs", orca
        assert report["warnings"] == [
            "More than one ODD Flow Orca plugin copy is enabled; each copy runs a worker and a prompt hook."
        ], report
elif case == "sync":
    legacy_report = {key: value for key, value in report.items()
                     if key not in ("session_state", "init_blocks")}
    assert report.get("init_blocks") == {
        "expected_mode": "organic", "mode_source": "default",
        "runtimes": [{"runtime": runtime, "status": "not installed"}
                     for runtime in ("claude", "codex", "antigravity")],
    }, report
    assert rows["orca"]["plugin_key"] == "local.odd-flow-profiles", rows["orca"]
    assert rows["orca"]["source"] == "folder", rows["orca"]
    legacy_report["installs"] = [
        {key: value for key, value in row.items() if key not in ("plugin_key", "source")}
        for row in report["installs"]
    ]
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
    assert [row["status"] for row in report["init_blocks"]["runtimes"]] == ["not installed"] * 3, report
PY
}

assert_init() {
    "$python" -I - "$1" <<'PY'
import json
import os
from pathlib import Path
import sys

case = sys.argv[1]
assert not Path("err").read_text()
report = json.loads(Path("out").read_text())
blocks, warnings = report["init_blocks"], report["warnings"]
home = Path(os.environ["HOME"])
codex_file = str(home / ".codex/AGENTS.md")
rerun = "re-run /odd-flow init: python3 skills/odd-flow/scripts/init.py plan --runtime codex"
absent = [{"runtime": runtime, "status": "not installed"} for runtime in ("claude", "codex", "antigravity")]
if case == "mode-unreadable":
    assert blocks == {"status": "unreadable", "reason": "cannot resolve orchestrator mode"}, blocks
    assert warnings == [], warnings
elif case == "unreadable":
    reasons = {
        "claude": "instructions file is a symlink",
        "codex": "the file has an unbalanced odd-flow marker; fix it by hand first",
        "antigravity": "cannot read instructions file",
    }
    assert blocks["runtimes"] == [
        {"runtime": runtime, "status": "unreadable", "reason": reason}
        for runtime, reason in reasons.items()
    ], blocks
    assert len(warnings) == 3, warnings
    for (runtime, reason), warning in zip(reasons.items(), warnings):
        assert reason in warning and warning.endswith(f"--runtime {runtime}"), warning
        assert str(home) not in warning, warning
else:
    mode = "full-delegation" if case == "in-sync" else "organic"
    assert blocks["expected_mode"] == mode, blocks
    assert blocks["mode_source"] == ("default" if case == "none" else "profile p"), blocks
    row = {"runtime": "codex", "path": codex_file}
    if case == "none":
        row = absent[1]
        expected_warnings = []
    elif case == "in-sync":
        row.update(status="in sync", installed_mode="full-delegation")
        expected_warnings = []
    elif case == "mode-differs":
        row.update(status="mode differs", installed_mode="full-delegation", expected_mode="organic")
        expected_warnings = [
            "Codex init block: installed for full-delegation mode, but the resolved mode is organic; " + rerun
        ]
    else:
        row.update(status="block differs", installed_mode="unknown", expected_mode="organic")
        expected_warnings = [
            "Codex init block: matches no mode asset, and the resolved mode is organic; " + rerun
        ]
    assert blocks["runtimes"] == [absent[0], row, absent[2]], blocks
    assert warnings == expected_warnings, warnings
PY
}

assert_session() {
    "$python" -I - "$1" "$2" <<'PY'
import json
import os
from pathlib import Path
import sys

case, source = sys.argv[1:]
assert not Path("err").read_text()
report = json.loads(Path("out").read_text())
blocks, warnings = report["init_blocks"], report["warnings"]
row = {"runtime": "codex", "path": str(Path(os.environ["HOME"]) / ".codex/AGENTS.md")}
expected = {"session_only": True, "session_mode": "organic", "session_mode_source": source}
expected_warnings = []
if case == "unresolved":
    expected["persistent_mode_error"] = "cannot resolve persistent orchestrator mode"
    row.update(status="installed", installed_mode="full-delegation")
else:
    expected.update(expected_mode="full-delegation", mode_source="profile p")
    if case == "in-sync":
        row.update(status="in sync", installed_mode="full-delegation")
    elif case == "mode-differs":
        row.update(status="mode differs", installed_mode="organic", expected_mode="full-delegation")
        expected_warnings = [
            "Codex init block: installed for organic mode, but the persistent mode is full-delegation; "
            "the current organic mode is session-only"
        ]
    else:
        row.update(status="block differs", installed_mode="unknown", expected_mode="full-delegation")
        expected_warnings = [
            "Codex init block: matches no mode asset, and the persistent mode is full-delegation; "
            "the current organic mode is session-only"
        ]
runtimes = blocks.pop("runtimes")
assert blocks == expected, blocks
assert runtimes == [
    {"runtime": "claude", "status": "not installed"}, row,
    {"runtime": "antigravity", "status": "not installed"},
], runtimes
assert warnings == expected_warnings, warnings
PY
}

refute_output() {
    if grep -E "$1" out; then
        printf 'FAIL unexpected output: %s\n' "$1" >&2
        exit 1
    fi
}

# The checkout and the catalog intentionally disagree about the newest version.
check_root="$scratch/orca-checkout"
copy_install "$check_root"
mkdir -p "$check_root/orca-plugin"
printf '{"version":"9.8.7"}\n' > "$check_root/orca-plugin/orca-plugin.json"
cp "$root/orca-catalog.json" "$check_root/orca-catalog.json"
"$python" -I - "$check_root/orca-catalog.json" > catalog-release <<'PYTHON'
import json
import sys

plugin, = json.load(open(sys.argv[1]))["plugins"]
release = plugin["releases"][0]
print(plugin["id"], release["version"], release["commit"])
PYTHON
read -r catalog_key catalog_version catalog_commit < catalog-release
ORCA_VERSION="$catalog_version" ORCA_SOURCE= check human-orca-no-source 1
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: version differs (ODD Flow Orca plugin $catalog_version; checkout ODD Flow Orca plugin 9.8.7; Orca status: running; source: folder)" out
catalog_row=',{"pluginKey":"%s","version":"%s","status":"idle","source":{"kind":"marketplace","resolvedCommit":"%s","marketplace":{"resolvedCommit":"different-commit"}}},{"pluginKey":"example.unrelated","version":"0.0.1","status":"running"}'
ORCA_VERSION=9.8.7 ORCA_STATUS=disabled ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" "$catalog_commit") check orca-catalog 0 --json
assert_json orca-catalog
ORCA_VERSION=9.8.7 ORCA_STATUS=disabled ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" different-commit) check orca-commit-diff 1 --json
assert_json orca-commit-diff
ORCA_VERSION=9.8.7 ORCA_STATUS=disabled ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" different-commit) check human-orca-commit-diff 1
grep -Fx "ODD Flow Orca plugin [$catalog_key]: commit differs (ODD Flow Orca plugin $catalog_version; Orca status: idle; source: catalog; commit: different-commit; catalog commit: $catalog_commit)" out
cp "$check_root/orca-catalog.json" "$scratch/catalog-original.json"
"$python" -I - "$check_root/orca-catalog.json" <<'PYTHON'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
catalog = json.loads(path.read_bytes())
del catalog["plugins"][0]["releases"][0]["commit"]
path.write_text(json.dumps(catalog))
PYTHON
ORCA_VERSION=9.8.7 ORCA_STATUS=disabled ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" "$catalog_commit") check human-orca-no-release-commit 0
grep -Fx "ODD Flow Orca plugin [$catalog_key]: in sync (ODD Flow Orca plugin $catalog_version; Orca status: idle; source: catalog; commit: unknown)" out || { cat out >&2; exit 1; }
mv "$scratch/catalog-original.json" "$check_root/orca-catalog.json"
ORCA_VERSION=9.8.7 ORCA_STATUS=disabled ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" '') check human-orca-no-installed-commit 0
grep -Fx "ODD Flow Orca plugin [$catalog_key]: in sync (ODD Flow Orca plugin $catalog_version; Orca status: idle; source: catalog; commit: unknown)" out
ORCA_VERSION=9.8.7 ORCA_EXTRA=$(printf "$catalog_row" mirror.odd-flow-profiles 0.0.1 different-commit) check orca-duplicate 1 --json
assert_json orca-duplicate
ORCA_VERSION=9.8.7 ORCA_EXTRA=$(printf "$catalog_row" mirror.odd-flow-profiles 0.0.1 different-commit) check human-orca-duplicate 1
grep -Fx "ODD Flow Orca plugin [mirror.odd-flow-profiles]: version differs (ODD Flow Orca plugin 0.0.1; catalog ODD Flow Orca plugin $catalog_version; Orca status: idle; source: catalog; commit: different-commit)" out
grep -Fx 'Warning: More than one ODD Flow Orca plugin copy is enabled; each copy runs a worker and a prompt hook.' out
ORCA_VERSION=9.8.7 ORCA_STATUS=errored ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" "$catalog_commit") check human-orca-errored-dup 0
grep -Fx 'Warning: More than one ODD Flow Orca plugin copy is enabled; each copy runs a worker and a prompt hook.' out
ORCA_VERSION=9.8.7 ORCA_STATUS=invalid_status ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" "$catalog_commit") check human-orca-invalid-status 3
grep -F '[local.odd-flow-profiles]: unreadable (invalid Orca plugin status)' out
if grep -F 'More than one ODD Flow Orca plugin copy' out; then
    exit 1
fi

mv "$check_root/orca-catalog.json" "$scratch/catalog-original.json"
ORCA_VERSION=9.8.7 ORCA_STATUS=disabled ORCA_ERROR=' ' ORCA_EXTRA=$(printf "$catalog_row" "$catalog_key" "$catalog_version" "$catalog_commit") check human-orca-no-catalog 3
grep -F "[$catalog_key]: unreadable (cannot read newest release from orca-catalog.json)" out
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: in sync (ODD Flow Orca plugin 9.8.7; Orca status: disabled; source: folder)" out
mv "$scratch/catalog-original.json" "$check_root/orca-catalog.json"
unset check_root

cp -R "$HOME" "$scratch/before"
check sync 0 --json
assert_json sync
check human 0
grep -Fx "Claude Code: in sync [$claude] (odd-flow $version)" out
grep -Fx "Codex: in sync [$codex_path] (odd-flow $version)" out
grep -Fx "Antigravity: in sync [$agy] (odd-flow $version)" out
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: running; source: folder)" out
grep -F 'ignored' out
grep -Fx 'Session state: 2 session binding(s), 1 prompt-hook record(s), 3 mode-notice record(s)' out
diff -r "$scratch/before" "$HOME"

ORCA_EXTRA=',5,{"pluginKey":123,"version":"0.0.1","status":"running"}' check orca-malformed-entry 0 --json
assert_json sync
ORCA_EXTRA=',5,{"pluginKey":123,"version":"0.0.1","status":"running"}' check human-orca-malformed-entry 0
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: running; source: folder)" out

cp "$bin/orca" "$scratch/orca-fake"
cp "$bin/claude" "$scratch/claude-fake"
cat > "$bin/orca" <<'SH'
#!/bin/bash
printf '%s\n' "$ORCA_RESPONSE"
SH
ORCA_RESPONSE='{"ok":true,"result":{"plugins":[5,{"pluginKey":123}]}}' check human-orca-only-malformed 0
grep -Fx 'ODD Flow Orca plugin: not installed' out
for response in '{"ok":true,"result":{"plugins":{}}}' '{"ok":false,"result":{"plugins":[]}}'; do
    ORCA_RESPONSE="$response" check human-orca-invalid-list 3
    grep -Fx 'ODD Flow Orca plugin: unreadable (cannot read plugin list)' out
done
cp "$scratch/orca-fake" "$bin/orca"
cat > "$bin/claude" <<'SH'
#!/bin/bash
printf '[{"id":"odd-flow@odd-flow"},5]\n'
SH
check human-claude-malformed-entry 3
grep -Fx 'Claude Code: unreadable (cannot read plugin list)' out
cp "$scratch/claude-fake" "$bin/claude"

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
grep -F 'Orca status: errored; source: folder; plugin local.odd-flow-profiles is errored after repeated failures' out
export ORCA_ERROR='\nplugin local.odd-flow-profiles is errored\r\n\t after\u001b\u009b repeated\u2028failures\u007f'
check orca-error-controls 0 --json
assert_json orca-error-controls
check human-orca-error-controls 0
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: errored; source: folder; plugin local.odd-flow-profiles is errored after repeated failures)" out
grep -F 'Orca reports its listed version, state, and any error for a non-running plugin.' out
export ORCA_ERROR='plugin\u202e error\u200b'
check orca-error-format 0 --json
assert_json orca-error-format
check human-orca-error-format 0
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: errored; source: folder; plugin error)" out
error_prefix=$(printf '%200s' '' | tr ' ' x)
export ORCA_ERROR="${error_prefix}tail"
check orca-error-long 0 --json
assert_json orca-error-long
check human-orca-error-long 0
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: in sync (ODD Flow Orca plugin $ORCA_VERSION; Orca status: errored; source: folder; ${error_prefix}...)" out
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
grep -Fx "ODD Flow Orca plugin [local.odd-flow-profiles]: version differs (ODD Flow Orca plugin $ORCA_VERSION; checkout ODD Flow Orca plugin $orca_checkout_version; Orca status: running; source: folder)" out
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

export HOME=$(printf '%s/init-\342\200\256home' "$scratch")
export ODD_FLOW_HOME="$HOME/odd-state"
export CLAUDE_CONFIG_DIR="$HOME/claude-config" CODEX_HOME="$HOME/codex-config"
mkdir -p "$HOME/.claude" "$ODD_FLOW_HOME"
printf 'My own rules.\n' > "$HOME/.claude/CLAUDE.md"
shown_codex_file="$scratch/init-home/.codex/AGENTS.md"

check init-none 0 --json
assert_init none
check human-init-none 0
grep -Fx 'Init blocks: none installed' out

set_mode() {
    printf '{"default":"p","profiles":{"p":{}},"workflow":{"p":{"orchestratorMode":"%s"}}}\n' "$1" \
        > "$ODD_FLOW_HOME/profiles.json"
}
set_mode full-delegation
"$python" -I "$root/skills/odd-flow/scripts/init.py" apply --runtime codex > /dev/null
check init-in-sync 0 --json
assert_init in-sync
check human-init-in-sync 0
grep -Fx "  Codex: in sync [$shown_codex_file] (installed mode: full-delegation)" out
if grep -F 'Warning:' out; then
    exit 1
fi

set_mode organic
cp -R "$HOME" "$scratch/init-before"
check init-mode-differs 0 --json
assert_init mode-differs
check human-init-mode-differs 0
grep -Fx "  Codex: mode differs [$shown_codex_file] (installed mode: full-delegation; expected mode: organic)" out
grep -Fx 'Warning: Codex init block: installed for full-delegation mode, but the resolved mode is organic; re-run /odd-flow init: python3 skills/odd-flow/scripts/init.py plan --runtime codex' out
diff -r "$scratch/init-before" "$HOME"

printf '<!-- odd-flow:core -->\nedited by hand\n<!-- /odd-flow:core -->\n' > "$HOME/.codex/AGENTS.md"
check init-block-differs 0 --json
assert_init block-differs
check human-init-block-differs 0
grep -Fx "  Codex: block differs [$shown_codex_file] (installed mode: unknown; expected mode: organic)" out
grep -Fx 'Warning: Codex init block: matches no mode asset, and the resolved mode is organic; re-run /odd-flow init: python3 skills/odd-flow/scripts/init.py plan --runtime codex' out

# Session-only overrides are compared against the persistent mode and never suggest init.
set_mode full-delegation
"$python" -I "$root/skills/odd-flow/scripts/init.py" apply --runtime codex > /dev/null
cp -R "$HOME" "$scratch/session-before"
env_source='env ODD_ORCHESTRATOR_MODE'
ODD_ORCHESTRATOR_MODE=organic check session-env-in-sync 0 --json
assert_session in-sync "$env_source"
ODD_ORCHESTRATOR_MODE=organic check human-session-env-in-sync 0
grep -Fx "  Current mode: organic ($env_source) is session-only" out
grep -Fx "  Codex: in sync [$shown_codex_file] (installed mode: full-delegation)" out
refute_output 'Warning:|re-run|init\.py'
diff -r "$scratch/session-before" "$HOME"

CLAUDE_CODE_SESSION_ID=s1 "$python" -I "$root/skills/odd-flow/scripts/profile.py" session-mode organic > /dev/null
CLAUDE_CODE_SESSION_ID=s1 check session-binding-in-sync 0 --json
assert_session in-sync 'session (CLAUDE_CODE_SESSION_ID)'
CLAUDE_CODE_SESSION_ID=s1 check human-session-binding-in-sync 0
grep -Fx '  Current mode: organic (session (CLAUDE_CODE_SESSION_ID)) is session-only' out
grep -Fx "  Codex: in sync [$shown_codex_file] (installed mode: full-delegation)" out
refute_output 'Warning:|re-run|init\.py'

"$python" -I "$root/skills/odd-flow/scripts/init.py" apply --runtime codex --mode organic > /dev/null
ODD_ORCHESTRATOR_MODE=organic check session-mode-differs 0 --json
assert_session mode-differs "$env_source"
CLAUDE_CODE_SESSION_ID=s1 check session-binding-mode-differs 0 --json
assert_session mode-differs 'session (CLAUDE_CODE_SESSION_ID)'
ODD_ORCHESTRATOR_MODE=organic check human-session-mode-differs 0
grep -Fx "  Current mode: organic ($env_source) is session-only" out
grep -Fx "  Codex: mode differs [$shown_codex_file] (installed mode: organic; expected mode: full-delegation)" out
grep -Fx 'Warning: Codex init block: installed for organic mode, but the persistent mode is full-delegation; the current organic mode is session-only' out
refute_output 're-run|init\.py'

printf '<!-- odd-flow:core -->\nedited by hand\n<!-- /odd-flow:core -->\n' > "$HOME/.codex/AGENTS.md"
ODD_ORCHESTRATOR_MODE=organic check session-block-differs 0 --json
assert_session block-differs "$env_source"

"$python" -I "$root/skills/odd-flow/scripts/init.py" apply --runtime codex > /dev/null
printf 'not json\n' > "$ODD_FLOW_HOME/profiles.json"
ODD_ORCHESTRATOR_MODE=organic check session-unresolved 0 --json
assert_session unresolved "$env_source"
ODD_ORCHESTRATOR_MODE=organic check human-session-unresolved 0
grep -Fx "  Current mode: organic ($env_source) is session-only; persistent mode could not be resolved" out
grep -Fx "  Codex: installed [$shown_codex_file] (installed mode: full-delegation)" out
refute_output 'Warning:|re-run|init\.py'
set_mode organic

mkdir -p "$HOME/.gemini"
ln -sf "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md"
printf '<!-- odd-flow:core -->\n' > "$HOME/.codex/AGENTS.md"
printf '\377\n' > "$HOME/.gemini/GEMINI.md"
check init-unreadable 0 --json
assert_init unreadable
check human-init-unreadable 0
grep -Fx '  Claude Code: unreadable (instructions file is a symlink)' out
grep -F 'Warning: Claude Code init block: unreadable (instructions file is a symlink)' out
set_mode full-delegation
ODD_ORCHESTRATOR_MODE=organic check human-session-unreadable 0
grep -Fx 'Warning: Claude Code init block: unreadable (instructions file is a symlink); fix the file' out
refute_output 're-run|init\.py'

printf 'not json\n' > "$ODD_FLOW_HOME/profiles.json"
check init-mode-unreadable 0 --json
assert_init mode-unreadable
check human-init-mode-unreadable 0
grep -Fx 'Init blocks: unreadable (cannot resolve orchestrator mode)' out

check usage 2 --unknown
test ! -s out
grep -F 'usage:' err
printf 'install-check: passed\n'
