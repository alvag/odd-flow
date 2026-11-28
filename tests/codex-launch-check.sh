#!/usr/bin/env bash
# Behavioral checks for the Codex worker launch path: scripts/codex-worker.sh, its
# PowerShell twin codex-worker.ps1, and the launch fields of `profile.py resolve`.
# A fake `codex` on PATH records its argv.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
L="$ROOT/skills/odd-flow/scripts/codex-worker.sh"
P="$ROOT/skills/odd-flow/scripts/profile.py"
PLATFORM=$(python3 -I -c 'import sys; print(sys.platform)')
# Git Bash passes a path containing a quote to native programs unconverted, so a
# Windows Python would read /tmp/... as C:\tmp\...
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi; }
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
cat >"$T/bin/codex" <<'SH'
#!/bin/sh
if [ "$#" -eq 3 ] && [ "$1 $2 $3" = "mcp get engram" ]; then
  config_home=${CODEX_HOME:-$HOME/.codex}
  # A fixture supplies Codex's expected answer; the fake does not parse TOML.
  [ -f "$config_home/config.toml" ] && [ "$(cat "$config_home/mcp-get-exit")" = 0 ]
  exit "$?"
fi
printf '%s\n' "$@"
exit "${CODEX_FAKE_EXIT:-0}"
SH
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
  -c plugins.engram@engram.enabled=false)
expect "argv: pin once, existing order kept" "$want" "$out" 0 $ec exact

mkdir -p "$T/empty-home" "$T/empty-codex"
out=$(launch "${ORCA_ENV[@]}" HOME="$T/empty-home" CODEX_HOME="$T/empty-codex"); ec=$?
expect "no Engram installed: Codex launches with the plugin override and no MCP override" "$want" "$out" 0 $ec exact

mkdir -p "$T/configured-home/.codex" "$T/codex"
printf '%s\n' '[mcp_servers.engram]' 'command = "engram"' >"$T/configured-home/.codex/config.toml"
printf '%s\n' '[mcp_servers."engram"]' 'command = "engram"' >"$T/codex/config.toml"
printf '0\n' >"$T/configured-home/.codex/mcp-get-exit"
printf '0\n' >"$T/codex/mcp-get-exit"
out=$(launch "${ORCA_ENV[@]}" HOME="$T/configured-home"); ec=$?
expect "bare Engram table in default config: both overrides passed" "$want"$'\n-c\nmcp_servers.engram.enabled=false' "$out" 0 $ec exact
out=$(launch "${ORCA_ENV[@]}" HOME="$T/empty-home" CODEX_HOME="$T/codex"); ec=$?
expect "quoted Engram table in CODEX_HOME: both overrides passed" "$want"$'\n-c\nmcp_servers.engram.enabled=false' "$out" 0 $ec exact
quoted_keys=$(printf '%s\n' "$out" | awk '/^-c$/ { getline; key = substr($0, 1, index($0, "=") - 1); if (index(key, "\"") || index(key, "\047")) print key }')
expect "no -c key path contains a quote" "" "$quoted_keys" 0 "$ec" exact

expect_mcp_lookup() { # name, lookup exit, config content (including line endings)
  local out ec argv="$want"
  printf '%s' "$3" >"$T/codex/config.toml"
  printf '%s\n' "$2" >"$T/codex/mcp-get-exit"
  if [[ "$2" == 0 ]]; then argv+=$'\n-c\nmcp_servers.engram.enabled=false'; fi
  out=$(launch "${ORCA_ENV[@]}" HOME="$T/empty-home" CODEX_HOME="$T/codex"); ec=$?
  expect "$1" "$argv" "$out" 0 "$ec" exact
}
expect_mcp_lookup "single-quoted Engram table: both overrides passed" 0 $'[mcp_servers.\'engram\']\ncommand = "engram"\n'
expect_mcp_lookup "inline Engram table: both overrides passed" 0 $'[mcp_servers]\nengram = { command = "engram" }\n'
expect_mcp_lookup "root dotted Engram key: both overrides passed" 0 $'mcp_servers.engram.command = "engram"\n'
expect_mcp_lookup "nested dotted Engram key: both overrides passed" 0 $'[mcp_servers]\nengram.command = "engram"\n'
expect_mcp_lookup "Engram table with CRLF: both overrides passed" 0 $'[mcp_servers.engram]\r\ncommand = "engram"\r\n'
expect_mcp_lookup "Engram header in a multiline string: no MCP override" 1 $'developer_instructions = """\n[mcp_servers.engram]\n"""\n'

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
LNAME=codex-worker.sh; [[ "$PLATFORM" == win32 ]] && LNAME=codex-worker.ps1
expect "codex role: terminal command runs the launcher with model and effort" "$LNAME' 'gpt-6-luna' 'medium'\"" "$out" 0 $ec
same=$(printf '%s\n' "$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("split_command") == d["terminal_command"])')
expect "codex role: split command equals terminal command" "True" "$same" 0 $ec

out=$(resolve write --json); ec=$?
expect "codex role without model: launcher without arguments" "$LNAME'\"" "$out" 0 $ec

out=$(resolve verify --json); ec=$?
expect "claude role: launch is worker-start" '"launch": "worker-start"' "$out" 0 $ec
expect "claude role: no terminal command" '"terminal_command": null' "$out" 0 $ec
argv=$(printf '%s\n' "$out" | python3 -I -c 'import json,shlex,sys; print("\n".join(shlex.split(json.load(sys.stdin)["split_command"])))' | tr -d '\r')
expect "claude role: split command preserves model and effort, then adds settings" \
  $'claude\n--model\nclaude-opus-5-5\n--effort\nhigh\n--settings\n'"$(native "$ROOT/skills/odd-flow/scripts/claude-worker-settings.json")" "$argv" 0 "$ec" exact

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

D="$T/plug in/it's"; mkdir -p "$D"; cp -R "$ROOT/skills" "$D/"
DP=$(native "$D/skills/odd-flow/scripts/profile.py")

# Each platform's command shape, checked on any host by forcing sys.platform.
forced() { # platform, Python expression over the loaded `profile` module; reads FORCED_HOME
  env -i HOME="$T" PATH="$PATH" ODD_FLOW_HOME="${FORCED_HOME:-$T}" CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=p python3 -I -c '
import importlib.util, sys
platform, path, expression = sys.argv[1:]
spec = importlib.util.spec_from_file_location("odd_flow_profile", path)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
# Forced only after the stdlib has loaded under the real platform; profile.py reads it at call time.
sys.platform = platform
print(eval(expression))
' "$1" "$DP" "$2" 2>&1
}
field() { printf 'profile.resolve_role(profile.load_profiles(), "%s")["%s"]' "$1" "$2"; }
ps_quote() { local v=${1//\'/\'\'}; printf "'%s'" "$v"; }
sh_quote() { local v=${1//\'/\'\\\'\'}; printf "'%s'" "$v"; }
ps1=$(forced win32 profile.CODEX_LAUNCHER_WINDOWS)
settings=$(forced win32 profile.CLAUDE_WORKER_SETTINGS)
pscmd="powershell -NoProfile -ExecutionPolicy Bypass -File $(ps_quote "$ps1")"

out=$(forced win32 "$(field explore terminal_command)"); ec=$?
expect "win32: codex terminal command runs the PowerShell launcher, quoted for PowerShell" "$pscmd 'gpt-6-luna' 'medium'" "$out" 0 $ec exact
out=$(forced win32 "$(field explore split_command)"); ec=$?
expect "win32: codex split command equals terminal command" "$pscmd 'gpt-6-luna' 'medium'" "$out" 0 $ec exact
out=$(forced win32 "$(field write terminal_command)"); ec=$?
expect "win32: codex role without model: launcher without arguments" "$pscmd" "$out" 0 $ec exact
out=$(forced win32 "$(field verify split_command)"); ec=$?
expect "win32: claude split command quotes the settings path for PowerShell" \
  "claude --model 'claude-opus-5-5' --effort 'high' --settings $(ps_quote "$settings")" "$out" 0 $ec exact
out=$(forced win32 "$(field review split_command)"); ec=$?
expect "win32: antigravity split command includes model and effort" "agy --model 'gemini-4' --effort 'low'" "$out" 0 $ec exact
out=$(forced win32 'profile.shell_quote("a\u2019b\u2018c").encode("unicode_escape").decode()'); ec=$?
expect "win32: typographic single quotes are doubled" "'a\u2019\u2019b\u2018\u2018c'" "$out" 0 $ec exact

out=$(forced linux "$(field explore terminal_command)"); ec=$?
expect "posix: codex terminal command runs sh, quoted for POSIX" \
  "sh $(sh_quote "$(forced linux profile.CODEX_LAUNCHER)") 'gpt-6-luna' 'medium'" "$out" 0 $ec exact
out=$(forced linux "$(field verify split_command)"); ec=$?
expect "posix: claude split command quotes the settings path for POSIX" \
  "claude --model 'claude-opus-5-5' --effort 'high' --settings $(sh_quote "$settings")" "$out" 0 $ec exact

# Windows rebuilds a command line for each native program, so these values could
# add Codex flags or swallow the ones after them; sh passes them intact.
FLAG_MODEL='gpt\" --dangerously-bypass-approvals-and-sandbox'
SLASH_MODEL='gpt x\'
mkdir -p "$T/unsafe"
python3 -I -c '
import json, sys
flag, slash = sys.argv[1:3]
print(json.dumps({"profiles": {"p": {
    "explore": {"agent": "codex", "model": flag, "effort": "medium"},
    "write": {"agent": "codex", "model": slash},
    "refute": {"agent": "codex", "model": "gpt-6-luna", "effort": "medium\\"},
    "verify": {"agent": "claude", "model": flag, "effort": "high"},
    "review": {"agent": "antigravity", "model": slash}}}}))
' "$FLAG_MODEL" "$SLASH_MODEL" >"$T/unsafe/profiles.json"
unsafe_resolve() { FORCED_HOME=$T/unsafe forced "$1" "sys.exit(profile.main([\"resolve\", \"$2\", \"--json\"]))"; }
for role in explore write refute verify review; do
  out=$(unsafe_resolve win32 "$role"); ec=$?
  expect "win32: resolve $role refuses a model or effort with a double quote, backslash or whitespace" \
    "must not contain a double quote, a backslash or whitespace" "$out" 2 $ec
done
out=$(FORCED_HOME=$T/unsafe forced linux "$(field explore terminal_command)"); ec=$?
expect "posix: codex terminal command still passes a double quote and whitespace" \
  "sh $(sh_quote "$(forced linux profile.CODEX_LAUNCHER)") $(sh_quote "$FLAG_MODEL") 'medium'" "$out" 0 $ec exact
out=$(FORCED_HOME=$T/unsafe forced linux "$(field write terminal_command)"); ec=$?
expect "posix: codex terminal command still passes a trailing backslash" \
  "sh $(sh_quote "$(forced linux profile.CODEX_LAUNCHER)") $(sh_quote "$SLASH_MODEL")" "$out" 0 $ec exact
out=$(FORCED_HOME=$T/unsafe forced linux "$(field verify split_command)"); ec=$?
expect "posix: claude split command still passes a double quote and whitespace" \
  "claude --model $(sh_quote "$FLAG_MODEL") --effort 'high' --settings $(sh_quote "$settings")" "$out" 0 $ec exact
out=$(FORCED_HOME=$T/unsafe forced linux "$(field review split_command)"); ec=$?
expect "posix: antigravity split command still passes a trailing backslash" \
  "agy --model $(sh_quote "$SLASH_MODEL")" "$out" 0 $ec exact
out=$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" "${ORCA_ENV[@]}" sh "$L" "$FLAG_MODEL" medium 2>&1); ec=$?
expect "codex-worker.sh passes a model with a double quote and whitespace as one argument" $'-m\n'"$FLAG_MODEL"$'\n-c\nmodel_reasoning_effort=medium' "$out" 0 $ec

PS_HOSTS=()
candidates=(pwsh); [[ "$PLATFORM" == win32 ]] && candidates=(powershell.exe pwsh.exe)
for host in "${candidates[@]}"; do
  if command -v "$host" >/dev/null 2>&1; then PS_HOSTS+=("$host"); fi
done
if [[ ${#PS_HOSTS[@]} -gt 0 ]]; then
  # The fake hands its argv to a native program, as Codex's own launcher does.
  mkdir -p "$T/psbin" "$T/ps-engram"
  cat >"$T/psbin/argv.py" <<'PY'
import os, sys
args = sys.argv[1:]
if args == ["mcp", "get", "engram"]:
    home = os.environ["CODEX_HOME"]
    try:
        with open(os.path.join(home, "mcp-get-exit")) as f:
            found = os.path.isfile(os.path.join(home, "config.toml")) and f.read().strip() == "0"
    except OSError:
        found = False
    sys.exit(0 if found else 1)
sys.stdout.buffer.write("".join(arg + "\n" for arg in args).encode())
sys.exit(int(os.environ.get("CODEX_FAKE_EXIT", "0")))
PY
  cat >"$T/psbin/codex.ps1" <<'PS1'
& $env:CODEX_FAKE_PYTHON -I (Join-Path $PSScriptRoot 'argv.py') @args
exit $LASTEXITCODE
PS1
  printf '%s\n' '[mcp_servers.engram]' 'command = "engram"' >"$T/ps-engram/config.toml"
  printf '0\n' >"$T/ps-engram/mcp-get-exit"
  PYEXE=$(python3 -I -c 'import sys; print(sys.executable)')
  PS1_PATH=$(native "$ROOT/skills/odd-flow/scripts/codex-worker.ps1")
  # No value starts with '/': Git Bash would rewrite it for a native PowerShell.
  PS_ENV=(ORCA_USER_DATA_PATH='C:\Users\u\AppData\Roaming\Orca Data' ORCA_WORKSPACE_ID='ws-1::C:\repo'
    ORCA_WORKTREE_ID='ws-1::C:\repo' ORCA_PANE_KEY='tab-1:pane-1' ORCA_TERMINAL_HANDLE='term_1')
  NO_ORCA=(-u ORCA_USER_DATA_PATH -u ORCA_WORKSPACE_ID -u ORCA_WORKTREE_ID -u ORCA_PANE_KEY -u ORCA_TERMINAL_HANDLE)
  run_ps() { # host, PowerShell arguments; reads RUN_ENV and CH (Codex home)
    local host=$1; shift
    env "${NO_ORCA[@]}" PATH="$T/psbin:$PATH" CODEX_FAKE_PYTHON="$PYEXE" CODEX_HOME="$(native "$CH")" \
      ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$host" -NoProfile "$@" 2>&1 | tr -d '\r'
    return "${PIPESTATUS[0]}"
  }
  run_sh() {
    env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" CODEX_HOME="$CH" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
      sh "$L" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} 2>&1
  }
  parity() { # name
    local want wec got gec host
    want=$(run_sh); wec=$?
    want=${want/#$'--no-daemon\n--sandbox\nworkspace-write\n'/$'--no-daemon\n--approve-for-me\n'}
    for host in "${PS_HOSTS[@]}"; do
      got=$(run_ps "$host" -ExecutionPolicy Bypass -File "$PS1_PATH" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}); gec=$?
      expect "$host: codex-worker.ps1 matches codex-worker.sh except for --approve-for-me: $1" "$want" "${got//codex-worker.ps1/codex-worker.sh}" "$wec" "$gec" exact # The anchored substitution above rewrites only the expected argv prefix.
    done
  }
  CH=$T/empty-codex
  RUN_ENV=("${PS_ENV[@]}"); RUN_ARGS=(gpt-6-luna medium)
  for host in "${PS_HOSTS[@]}"; do
    out=$(run_ps "$host" -ExecutionPolicy Bypass -File "$PS1_PATH" "${RUN_ARGS[@]}"); ec=$?
    expect "$host: PowerShell argv includes --approve-for-me and no --sandbox" --approve-for-me \
      "$(printf '%s\n' "$out" | grep -E '^--(approve-for-me|sandbox)(=|$)')" 0 "$ec" exact
  done
  parity "model and effort"
  CH=$T/ps-engram; parity "Engram configured"
  CH=$T/empty-codex
  RUN_ARGS=(); parity "no arguments"
  RUN_ARGS=(gpt-6-luna); parity "model only"
  RUN_ENV=("${PS_ENV[@]}" CODEX_FAKE_EXIT=3); RUN_ARGS=(gpt-6-luna medium); parity "Codex exit code returned"
  RUN_ENV=("${PS_ENV[@]:0:4}"); parity "missing variable refused"
  RUN_ENV=("${PS_ENV[@]}" ORCA_PANE_KEY="it's"); parity "single quote refused"
  RUN_ENV=("${PS_ENV[@]}"); RUN_ARGS=(gpt-6-luna medium extra); parity "too many arguments refused"
  RUN_ARGS=("" high); parity "empty model refused"
  RUN_ARGS=(-- high); parity "option-like argument refused"
  refuse_ps() { # name, expected message
    local host
    for host in "${PS_HOSTS[@]}"; do
      out=$(run_ps "$host" -ExecutionPolicy Bypass -File "$PS1_PATH" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"}); ec=$?
      expect "$host: codex-worker.ps1 refuses $1" "$2" "$out" 2 $ec
    done
  }
  unsafe="must not contain a double quote, a backslash or whitespace"
  RUN_ENV=("${PS_ENV[@]}")
  RUN_ARGS=("$FLAG_MODEL" medium); refuse_ps "a model with a double quote and whitespace" "$unsafe"
  RUN_ARGS=("$SLASH_MODEL"); refuse_ps "a model with whitespace and a trailing backslash" "$unsafe"
  RUN_ARGS=(gpt-6-luna 'medium\'); refuse_ps "an effort with a backslash" "$unsafe"
  RUN_ARGS=(gpt-6-luna medium)
  RUN_ENV=("${PS_ENV[@]}" ORCA_PANE_KEY='tab"1'); refuse_ps "an Orca value with a double quote" "ORCA_PANE_KEY contains a double quote"
else
  echo "SKIP codex-worker.ps1 matches codex-worker.sh: PowerShell is not installed"
fi

# terminal_command, run by the terminal's shell, survives a plugin path with a space and a quote.
cmd=$(env -i HOME="$T" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_CODE_SESSION_ID=s1 ODD_PROFILE=p \
  python3 -I "$DP" resolve explore --json \
  | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["terminal_command"])')
if [[ "$PLATFORM" != win32 ]]; then
  out=$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" "${ORCA_ENV[@]}" sh -c "$cmd" 2>&1); ec=$?
  expect "terminal_command runs from a path with spaces and a quote" $'-m\ngpt-6-luna\n-c\nmodel_reasoning_effort=medium' "$out" 0 $ec
elif [[ ${#PS_HOSTS[@]} -gt 0 ]]; then
  CH=$T/empty-codex; RUN_ENV=("${PS_ENV[@]}")
  for host in "${PS_HOSTS[@]}"; do
    out=$(run_ps "$host" -Command "$cmd"); ec=$?
    expect "$host: terminal_command runs from a path with spaces and a quote" $'-m\ngpt-6-luna\n-c\nmodel_reasoning_effort=medium' "$out" 0 $ec
  done
else
  echo "SKIP terminal_command runs from a path with spaces and a quote: PowerShell is not installed"
fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
