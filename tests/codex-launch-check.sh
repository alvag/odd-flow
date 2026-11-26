#!/usr/bin/env bash
# Behavioral checks for the Codex worker launch path: scripts/codex-worker.sh and
# the launch fields of `profile.py resolve`. A fake `codex` on PATH records its argv.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/skills/odd-flow/scripts/codex-worker.sh"
P="$ROOT/skills/odd-flow/scripts/profile.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
expect() { # name, expected substring, actual, expected exit, actual exit, [exact]
  if [[ "$4" == "$5" && ( "$3" == "$2" || ( "${6:-}" != exact && "$3" == *"$2"* ) ) ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $4 and: $2"; echo "  got  exit $5: $3"; fi
}
refute() { # name, unexpected substring, actual
  if [[ "$3" != *"$2"* ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  did not want: $2"; echo "  got: $3"; fi
}

mkdir -p "$T/bin"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' >"$T/bin/codex"
chmod +x "$T/bin/codex"
ORCA_ENV=(ORCA_USER_DATA_PATH="/Users/u/Library/Application Support/orca" ORCA_WORKSPACE_ID="ws-1::/repo"
  ORCA_WORKTREE_ID="ws-1::/repo" ORCA_PANE_KEY="tab-1:pane-1" ORCA_TERMINAL_HANDLE="term_1")
launch() { env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" "$@" sh "$L" ${ARGS} 2>&1; }

ARGS="gpt-6-luna medium"; out=$(launch "${ORCA_ENV[@]}"); ec=$?
expect "sandbox override is passed" $'-c\nsandbox_workspace_write.network_access=true' "$out" 0 $ec
expect "model is passed" $'-m\ngpt-6-luna' "$out" 0 $ec
expect "effort is passed" $'-c\nmodel_reasoning_effort=medium' "$out" 0 $ec
expect "Orca argv: --no-daemon first" $'\n--no-daemon\n' $'\n'"${out%%$'\n'*}"$'\n' 0 $ec
expect "Orca argv: startup options kept" $'-c\ncheck_for_update_on_startup=false\n-c\ndisable_paste_burst=true\n-m' "$out" 0 $ec
expect "path with spaces is forwarded as one TOML literal" "shell_environment_policy.set.ORCA_USER_DATA_PATH='/Users/u/Library/Application Support/orca'" "$out" 0 $ec
expect "terminal handle is forwarded" "shell_environment_policy.set.ORCA_TERMINAL_HANDLE='term_1'" "$out" 0 $ec
refute "no wider sandbox mode is set" "sandbox_mode" "$out"
expect "workspace-write sandbox is passed before the config options" $'\n--sandbox\nworkspace-write\n-c\nshell_environment_policy.set.ORCA_USER_DATA_PATH=' "$out" 0 $ec
want=$(printf '%s\n' --no-daemon --sandbox workspace-write \
  -c "shell_environment_policy.set.ORCA_USER_DATA_PATH='/Users/u/Library/Application Support/orca'" \
  -c "shell_environment_policy.set.ORCA_WORKSPACE_ID='ws-1::/repo'" \
  -c "shell_environment_policy.set.ORCA_WORKTREE_ID='ws-1::/repo'" \
  -c "shell_environment_policy.set.ORCA_PANE_KEY='tab-1:pane-1'" \
  -c "shell_environment_policy.set.ORCA_TERMINAL_HANDLE='term_1'" \
  -c check_for_update_on_startup=false -c disable_paste_burst=true \
  -m gpt-6-luna -c model_reasoning_effort=medium -c sandbox_workspace_write.network_access=true \
  -c 'plugins."engram@engram".enabled=false')
expect "argv: pin once, existing order kept" "$want" "$out" 0 $ec exact

mkdir -p "$T/empty-home" "$T/empty-codex"
out=$(launch "${ORCA_ENV[@]}" HOME="$T/empty-home" CODEX_HOME="$T/empty-codex"); ec=$?
expect "no Engram installed: Codex launches with the plugin override and no MCP override" "$want" "$out" 0 $ec exact

mkdir -p "$T/configured-home/.codex" "$T/codex"
printf '%s\n' '[mcp_servers.engram]' 'command = "engram"' >"$T/configured-home/.codex/config.toml"
printf '%s\n' '[mcp_servers."engram"]' 'command = "engram"' >"$T/codex/config.toml"
out=$(launch "${ORCA_ENV[@]}" HOME="$T/configured-home"); ec=$?
expect "bare Engram table in default config: both overrides passed" "$want"$'\n-c\nmcp_servers.engram.enabled=false' "$out" 0 $ec exact
out=$(launch "${ORCA_ENV[@]}" HOME="$T/empty-home" CODEX_HOME="$T/codex"); ec=$?
expect "quoted Engram table in CODEX_HOME: both overrides passed" "$want"$'\n-c\nmcp_servers.engram.enabled=false' "$out" 0 $ec exact

ARGS=""; out=$(launch "${ORCA_ENV[@]}"); ec=$?
refute "no model: no -m flag" $'\n-m\n' "$out"
expect "no model: still sandbox override" "sandbox_workspace_write.network_access=true" "$out" 0 $ec

ARGS="gpt-6-luna"; out=$(launch "${ORCA_ENV[@]}"); ec=$?
refute "model only: no effort flag" "model_reasoning_effort" "$out"

ARGS="gpt-6-luna medium"; out=$(launch ORCA_USER_DATA_PATH=x ORCA_WORKSPACE_ID=x ORCA_WORKTREE_ID=x ORCA_PANE_KEY=x); ec=$?
expect "outside an Orca terminal: refuse" "ORCA_TERMINAL_HANDLE" "$out" 2 $ec

ARGS="gpt-6-luna medium"; out=$(launch "${ORCA_ENV[@]}" ORCA_PANE_KEY="it's"); ec=$?
expect "single quote in a value: refuse" "single quote" "$out" 2 $ec

ARGS="gpt-6-luna medium extra"; out=$(launch "${ORCA_ENV[@]}"); ec=$?
expect "too many arguments: refuse" "usage" "$out" 2 $ec

out=$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" "${ORCA_ENV[@]}" sh "$L" "" high 2>&1); ec=$?
expect "empty model: refuse, never take the effort as the model" "must not be empty" "$out" 2 $ec

out=$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" "${ORCA_ENV[@]}" sh "$L" -- high 2>&1); ec=$?
expect "option-like argument: refuse" "must not start with '-'" "$out" 2 $ec

# profile.py resolve announces the launch path without changing existing fields.
cat >"$T/profiles.json" <<'JSON'
{"profiles": {"p": {
  "explore": {"agent": "codex", "model": "gpt-6-luna", "effort": "medium"},
  "verify": {"agent": "claude", "model": "claude-opus-5-5", "effort": "high"},
  "write": {"agent": "codex"},
  "review": {"agent": "antigravity", "model": "gemini-4", "effort": "low"},
  "refute": {"agent": "antigravity"}
}}}
JSON
resolve() { env -i HOME="$T" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=p python3 -I "$P" resolve "$@" 2>&1; }

out=$(resolve explore --json); ec=$?
expect "codex role: launch is terminal" '"launch": "terminal"' "$out" 0 $ec
expect "codex role: flags unchanged" '"flags": ["--agent", "codex", "--model", "gpt-6-luna", "--effort", "medium"]' "$out" 0 $ec
expect "codex role: terminal command runs the launcher with model and effort" "codex-worker.sh' 'gpt-6-luna' 'medium'\"" "$out" 0 $ec
same=$(printf '%s\n' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("split_command") == d["terminal_command"])')
expect "codex role: split command equals terminal command" "True" "$same" 0 $ec

out=$(resolve write --json); ec=$?
expect "codex role without model: launcher without arguments" "codex-worker.sh'\"" "$out" 0 $ec

out=$(resolve verify --json); ec=$?
expect "claude role: launch is worker-start" '"launch": "worker-start"' "$out" 0 $ec
expect "claude role: no terminal command" '"terminal_command": null' "$out" 0 $ec
argv=$(printf '%s\n' "$out" | python3 -I -c 'import json,shlex,sys; print("\n".join(shlex.split(json.load(sys.stdin)["split_command"])))')
expect "claude role: split command preserves model and effort, then adds settings" \
  $'claude\n--model\nclaude-opus-5-5\n--effort\nhigh\n--settings\n'"$ROOT/skills/odd-flow/scripts/claude-worker-settings.json" "$argv" 0 "$ec" exact

out=$(resolve review --json); ec=$?
expect "antigravity role: launch is worker-start" '"launch": "worker-start"' "$out" 0 $ec
expect "antigravity role: no terminal command" '"terminal_command": null' "$out" 0 $ec
expect "antigravity role: split command includes model and effort" "\"split_command\": \"agy --model 'gemini-4' --effort 'low'\"" "$out" 0 $ec

out=$(resolve refute --json); ec=$?
expect "antigravity role without model: split command is agy" '"split_command": "agy"' "$out" 0 $ec

out=$(resolve explore); ec=$?
expect "text mode: names the terminal path" "launch: terminal" "$out" 0 $ec
out=$(resolve verify); ec=$?
refute "text mode, claude role: output unchanged" "launch:" "$out"

# terminal_command, run by one shell, survives a plugin path with a space and a quote.
D="$T/plug in/it's"; mkdir -p "$D"; cp -R "$ROOT/skills" "$D/"
cmd=$(env -i HOME="$T" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=p \
  python3 -I "$D/skills/odd-flow/scripts/profile.py" resolve explore --json \
  | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["terminal_command"])')
out=$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" "${ORCA_ENV[@]}" sh -c "$cmd" 2>&1); ec=$?
expect "terminal_command runs from a path with spaces and a quote" $'-m\ngpt-6-luna\n-c\nmodel_reasoning_effort=medium' "$out" 0 $ec

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
