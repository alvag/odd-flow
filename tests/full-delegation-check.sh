#!/usr/bin/env bash
# Checks for full delegation mode: the hooks pick the mode's rules, no organic routing rule reaches a
# full delegation session, and organic mode keeps every rule it had.
set -u
R="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S="$R/skills/odd-flow"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; }
has() { [[ "$3" == *"$2"* ]] && ok "$1" || ko "$1" "missing: $2"; }
lacks() { [[ "$3" != *"$2"* ]] && ok "$1" || ko "$1" "unexpected: $2"; }

FULL='{"default":"A","profiles":{"A":{},"B":{}},"workflow":{"A":{"orchestratorMode":"full-delegation"}}}'
printf '%s' "$FULL" > "$T/profiles.json"
hook() { # script, payload, env...
  local script="$1" payload="$2"; shift 2
  printf '%s' "$payload" | env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_PLUGIN_ROOT="$R" "$@" python3 -I "$R/scripts/$script" 2>&1
}
ctx() { python3 -I -c 'import json,sys; d=sys.stdin.read(); print(json.loads(d)["hookSpecificOutput"]["additionalContext"] if d.strip() else "")'; }

# --- organic keeps its expected core block and routing ---
[[ "$(shasum -a 256 "$S/assets/core-block.md" | cut -d' ' -f1)" == "d7a080f49575286a009f1a217791e9781cabd4f5b9b2bbe14203fa1fcc60df6e" ]] \
  && ok "organic core block matches expected bytes" || ko "organic core block matches expected bytes"

out=$(hook session-start.py '{"source":"startup","session_id":"s1"}' ODD_PROFILE=B | ctx)
[[ "$out" == "$(cat "$S/assets/core-block.md")"* ]] && ok "organic session starts with the organic core block" || ko "organic session starts with the organic core block" "${out:0:200}"
has "organic session reports its mode" "mode: organic (default); rules: references/mode-organic.md" "$out"

out=$(hook prompt-submit.py '{"session_id":"s1","prompt":"hi"}' ODD_PROFILE=B)
[[ -z "$out" ]] && ok "organic prompts get no per-turn line" || ko "organic prompts get no per-turn line" "$out"

organic=$(cat "$S/references/mode-organic.md" 2>/dev/null)
for rule in \
  "Work inline by default." \
  "No trigger holds by default. When in doubt, work inline." \
  "Never delegate for size, file count, a large task alone, or price. Units of ~100 changed lines or less run inline." \
  '| Writer: parallel | Two or more independent units with disjoint edit surfaces' \
  '| Writer: context | `scripts/context.py` reports `holds`' \
  'Run `python3 <skill-dir>/scripts/context.py` before the first write of each implementation unit' \
  'The trigger threshold is `min(150000, max(1, floor(0.15 × window)))` tokens, or 150k when the model window is unknown. Set `ODD_FLOW_CONTEXT_WINDOW` to a positive integer to override the runtime window.' \
  "Small path: inline" \
  "Inline otherwise: the parent runs the role itself, one unit at a time." \
  "fix inline when small and understood, otherwise relaunch once with the diagnosis and a new hypothesis" \
  'Write it inline or with one `write` worker.'
do has "organic keeps: ${rule:0:60}" "$rule" "$organic"; done

# --- full delegation gets its own rules ---
out=$(hook session-start.py '{"source":"startup","session_id":"s2"}' | ctx)
[[ "$out" == "$(cat "$S/assets/core-block-full-delegation.md" 2>/dev/null)"* && -s "$S/assets/core-block-full-delegation.md" ]] \
  && ok "full delegation session starts with its own core block" || ko "full delegation session starts with its own core block" "${out:0:200}"
has "full delegation session reports its mode" "mode: full-delegation (profile A); rules: references/mode-full-delegation.md" "$out"
lacks "full delegation session start holds no organic core" "Work inline by default" "$out"

# Both modes inject the same memory rules.
for block in core-block.md core-block-full-delegation.md; do
  memory=$(sed -n '/^### Engram memory$/,/^### /p' "$S/assets/$block")
  has "$block: Engram precedence and write cadence" 'User instructions win; otherwise these rules override conflicting Engram session-start and compaction hooks and MCP server instructions: save grouped conclusions once per finding, not per event, and call `mem_session_summary` only at a significant close or handoff, not before every “done”.' "$memory"
  has "$block: safe Engram topic updates" 'Search the topic in the current project with `mem_search` and read plausible hits with `mem_get_observation`; update the same topic by `topic_key` or ID, retaining valid facts and superseded history, save new topics with a stable `topic_key`, and write nothing if covered or the lookup fails or is ambiguous.' "$memory"
done

organic_memory=$(sed -n '/^### Engram memory$/,/^### /p' "$S/assets/core-block.md")
[[ "$organic_memory" == "$memory" ]] \
  && ok "both core blocks carry the same Engram section" || ko "both core blocks carry the same Engram section"
mem=$(cat "$S/references/memory.md")
has "memory: review needs project" 'Never call `mem_review` without the resolved `project`.' "$mem"
has "memory: mark_reviewed needs user confirmation" 'Call `mem_review` with `action: mark_reviewed` only after the user confirms the memory still holds.' "$mem"
has "memory: worker learnings are saved by the parent" 'After accepting a worker report, save its `learnings` using this topic workflow. Drop entries without evidence.' "$mem"
has "memory: failed lookup is not absence" 'A failed or ambiguous lookup does not establish absence.' "$mem"
has "memory: CLI save command" 'engram save "<title>" "$(cat <scratch file>)" --project <project> --type <type> --topic <topic_key>' "$mem"
has "memory: CLI replaces whole content" 'on an existing `topic_key` replaces the whole content' "$mem"
has "memory: only the file read in command substitution" 'Put only the file read inside `$(...)`' "$mem"
has "memory: no CLI conflict check" 'returns no `judgment_required` and records no conflict candidates' "$mem"
has "memory: report missing CLI" 'If the `engram` CLI is missing or its save fails, report that the save failed; do not try another path.' "$mem"

out=$(hook prompt-submit.py '{"session_id":"s2","prompt":"hi"}' | ctx)
has "full delegation prompts get the per-turn mode line" "odd-flow mode: full-delegation" "$out"
has "per-turn line names the rules file" "references/mode-full-delegation.md" "$out"
has "per-turn line keeps parent writes to the closed list" "The parent coordinates and writes only what the mode file lists; bounded writers make all other workspace changes." "$out"

# --- replay a mid-session mode switch on Claude ---
full_line="$out"
data="$T/claude-data"
sid='{"session_id":"claude-switch","prompt":"hi"}'
marker="$data/session-modes/$(printf claude-switch | shasum -a 256 | cut -d' ' -f1)"
switch_line='odd-flow mode changed to organic (session (CLAUDE_CODE_SESSION_ID)); the session-start full-delegation rules no longer apply. Rules: skills/odd-flow/references/mode-organic.md.'
recorded=true
for source in startup resume clear compact; do
  hook session-start.py "{\"source\":\"$source\",\"session_id\":\"claude-switch\"}" ODD_PROFILE=B CLAUDE_PLUGIN_DATA="$data" >/dev/null
  [[ -f "$marker" && "$(cat "$marker")" == organic ]] || recorded=false
  hook session-start.py "{\"source\":\"$source\",\"session_id\":\"claude-switch\"}" CLAUDE_PLUGIN_DATA="$data" >/dev/null
  [[ -f "$marker" && "$(cat "$marker")" == full-delegation ]] || recorded=false
done
$recorded && ok "Claude SessionStart overwrites the mode for every source" || ko "Claude SessionStart overwrites the mode for every source"
out=$(hook prompt-submit.py "$sid" CLAUDE_PLUGIN_DATA="$data" | ctx)
[[ "$out" == "$full_line" ]] && ok "unchanged Claude mode preserves exactly the per-turn line" || ko "unchanged Claude mode preserves exactly the per-turn line" "$out"
hook session-start.py '{"source":"startup","session_id":"worker"}' CLAUDE_PLUGIN_DATA="$data" >/dev/null
hook prompt-submit.py '{"session_id":"worker","prompt":"# Role: write"}' CLAUDE_PLUGIN_DATA="$data" >/dev/null

env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_CODE_SESSION_ID=claude-switch \
  python3 -I "$S/scripts/profile.py" session-mode organic >/dev/null
out=$(hook prompt-submit.py "$sid" CLAUDE_PLUGIN_DATA="$data" | ctx)
[[ "$out" == "$switch_line" ]] && ok "Claude organic switch emits exactly the notice" || ko "Claude organic switch emits exactly the notice" "$out"
out=$(hook prompt-submit.py "$sid" CLAUDE_PLUGIN_DATA="$data")
[[ -z "$out" ]] && ok "Claude organic notice does not repeat" || ko "Claude organic notice does not repeat" "$out"
out=$(hook prompt-submit.py '{"session_id":"worker","prompt":"hi"}' ODD_ORCHESTRATOR_MODE=organic CLAUDE_PLUGIN_DATA="$data")
[[ -z "$out" ]] && ok "Claude worker gets no mode-change notice" || ko "Claude worker gets no mode-change notice" "$out"
out=$(hook prompt-submit.py "$sid" ODD_ORCHESTRATOR_MODE=full-delegation CLAUDE_PLUGIN_DATA="$data" | ctx)
back_line='odd-flow mode changed to full-delegation (env ODD_ORCHESTRATOR_MODE); the session-start organic rules no longer apply. Rules: skills/odd-flow/references/mode-full-delegation.md.'
env_full_line=${full_line/'(profile A)'/'(env ODD_ORCHESTRATOR_MODE)'}
[[ "$out" == "$back_line"$'\n'"$env_full_line" ]] && ok "Claude full switch adds one notice before the per-turn line" || ko "Claude full switch adds one notice before the per-turn line" "$out"

out=$(hook session-start.py '{"source":"startup","session_id":"s3"}' ODD_ORCHESTRATOR_MODE=bogus | ctx)
has "unresolved mode falls back to organic and says so" "mode unresolved" "$out"
out=$(hook prompt-submit.py '{"session_id":"s3"}' ODD_ORCHESTRATOR_MODE=bogus); ec=$?
[[ $ec == 0 ]] && ok "prompt hook never fails the prompt" || ko "prompt hook never fails the prompt" "exit $ec: $out"

full=$(cat "$S/references/mode-full-delegation.md" 2>/dev/null)
core=$(cat "$S/assets/core-block-full-delegation.md")
scope='Every authorized change inside the workspace goes to a bounded writer, whether the workspace is a Git repository or a project folder without Git.'
[[ "$full" == *"$scope"* && "$core" == *"$scope"* ]] \
  && ok "full delegation: workspace scope in both prompts" || ko "full delegation: workspace scope in both prompts" "missing from mode or core: $scope"
parent_writes='The parent writes only: scratch files outside the workspace (specs, messages, temporary indexes); `odd/tasks/*.md`; Engram; Git operations (stage, commit, merge, candidate commits); files written by `scripts/profile.py` or `scripts/init.py` after the user confirms their diff; scratch cleanup.'
[[ "$full" == *"$parent_writes"* && "$core" == *"$parent_writes"* ]] \
  && ok "full delegation: closed parent write list in both prompts" || ko "full delegation: closed parent write list in both prompts" "missing from mode or core: $parent_writes"
delegation=$(cat "$S/references/delegation.md")
has "non-Git writers: shadow snapshot command" 'git --git-dir="$G/.git" --work-tree="$folder" init -q' "$delegation"
has "non-Git writers: shadow baseline includes ignored files" 'run `add -A -f` and `commit --allow-empty -m "Writer baseline"`' "$delegation"
has "non-Git writers: shadow status includes type changes" '` T` if its type changes (for example, if a symlink replaces the file)' "$delegation"
has "non-Git writers: shadow candidate force-adds ignored paths" 'to the temporary index with `git add -A -f -- <paths>` because plain `git add` exits 1 for a deletion inside an ignored directory and for a new `!!` file' "$delegation"
folders=$(sed -n '/^## Project folders without Git$/,/^## /p' "$S/references/orca-dispatch.md")
has "non-Git writers: remove only task-registered folders at close" 'At task close, if you registered the folder for this task, wait until the writer'\''s terminal is closed, then run `orca project setup-delete --setup <id> --force` using the setup whose `path` in `orca project setups --json` matches the folder'\''s real path. Leave any pre-existing entry in place.' "$folders"
has "both modes: external file confirmation" 'In both modes, only the parent may write a file outside the workspace: the user must name the file, see the exact diff and confirm it before the write. Never delegate it.' "$delegation"
organic_core=$(cat "$S/assets/core-block.md")
[[ "$organic" == *"outside the workspace"*"confirms the exact diff"* && "$organic_core" == *"outside the workspace"*"confirms the exact diff"* ]] \
  && ok "organic: external file confirmation reachable" || ko "organic: external file confirmation reachable" "missing from mode-organic.md or core-block.md"
has "full delegation: the parent never edits" "never edit a file yourself" "$full"
has "full delegation: size never decides who writes" "Task size decides tracking and risk only, never who writes." "$full"
has "full delegation: relaunch after exhaustion" "Launch one new bounded writer with the diagnosis" "$full"
dispatch=$(sed -n '/^## When Orca wakes you$/,/^## /p' "$S/references/orca-dispatch.md")
grep -Eq 'Do not send a follow-up.*"delivery": "reopened".*pins are not guaranteed' <<< "$dispatch" \
  && ok "closed Codex terminal: no follow-up" || ko "closed Codex terminal: no follow-up" "reopen note or launcher caveat missing"
grep -Eq 'never answer it for the user.*relay the screen unchanged' <<< "$dispatch" \
  && ok "trust prompt stays with user" || ko "trust prompt stays with user" "trust rule missing"
grep -Eq 'closed Codex writer terminal.*orca-dispatch\.md#when-orca-wakes-you.*relaunch counts as the correction' <<< "$full" \
  && ok "mode file points to closed-terminal exception" || ko "mode file points to closed-terminal exception" "mode file contradicts orca-dispatch reopen rule"
has "full delegation: no new worker per fix" "never a new worker per fix" "$full"
has "full delegation: how to switch back" "/odd-flow --mode organic" "$full"
has "organic: how to switch" "/odd-flow --mode full-delegation" "$organic"

# --- worker memory rules and report fields ---
for role in write explore verify; do
  report=$(sed -n '/^Return/,$p' "$S/assets/roles/$role.md")
  has "$role: optional learnings field" 'learnings: (optional)' "$report"
done
for role in write explore verify review refute; do
  rules=$(cat "$S/assets/roles/$role.md")
  has "$role: memory ban takes precedence" "The ban on memory tools overrides any memory protocol injected by the worker's runtime or global instructions (for example, an Engram section in the agent's global \`CLAUDE.md\` or \`AGENTS.md\`); such a section is not a task instruction from the parent." "$rules"
  has "$role: global Engram example is not a parent instruction" 'an Engram section in the agent'\''s global `CLAUDE.md` or `AGENTS.md`); such a section is not a task instruction from the parent.' "$rules"
done

# --- closure: nothing a full delegation session can load carries an organic routing rule ---
show=$(env -i HOME="$HOME" PATH="$PATH" ODD_FLOW_HOME="$T" CLAUDE_CODE_SESSION_ID=s2 python3 -I "$S/scripts/profile.py" show 2>&1)
reach=("$S/assets/core-block-full-delegation.md" "$S/SKILL.md" "$S/references/mode-full-delegation.md" "$S/assets/spec-template.md")
for f in "$S"/references/*.md "$S"/assets/roles/*.md; do
  case "$f" in */mode-organic.md|*/init.md) ;; *) reach+=("$f");; esac
done
reach+=("$S/assets/feature-doc-template.md")
PATTERNS='work inline|it inline|works inline|run inline|runs inline|fix inline|stays? inline|writing inline|inline by default|inline otherwise|or inline|fallback: inline|inline budget|inline evidence|small path: inline|writer: context|writer: parallel|context\.py|when in doubt'
for f in "${reach[@]}"; do
  hits=$(grep -n -i -E "$PATTERNS" "$f" 2>/dev/null)
  [[ -e "$f" && -z "$hits" ]] && ok "closure: ${f#$S/}" || ko "closure: ${f#$S/}" "${hits:-file missing}"
done
hits=$(printf '%s' "$show" | grep -i -E "$PATTERNS")
[[ -z "$hits" ]] && ok "closure: profile.py show in full delegation" || ko "closure: profile.py show in full delegation" "$hits"

# the feature-document route never offers organic `inline` to a full delegation session
for f in "$S/references/tracking.md" "$S/assets/feature-doc-template.md"; do
  hits=$(grep -n -E '`inline`|\| inline \|' "$f")
  [[ -z "$hits" ]] && ok "closure: route in ${f#$S/}" || ko "closure: route in ${f#$S/}" "$hits"
done
has "organic names its feature-document routes" '`inline`, `orca:<role>` or `subagent:<role>`' "$organic"
has "full delegation names its feature-document routes" '`orca:<role>`, `subagent:<role>` or `blocked`' "$full"

# an explicit ODD_ORCHESTRATOR_MODE wins even when the profiles file is invalid
cp "$T/profiles.json" "$T/profiles.json.bak"
printf '{bad' > "$T/profiles.json"
out=$(hook session-start.py '{"source":"startup","session_id":"s4"}' ODD_ORCHESTRATOR_MODE=full-delegation | ctx)
[[ "$out" == "$(cat "$S/assets/core-block-full-delegation.md")"* ]] \
  && ok "env full-delegation survives an invalid profiles file" || ko "env full-delegation survives an invalid profiles file" "${out:0:200}"
out=$(hook prompt-submit.py '{"session_id":"s4"}' ODD_ORCHESTRATOR_MODE=full-delegation | ctx)
has "per-turn line with env override and invalid file" "odd-flow mode: full-delegation" "$out"
mv "$T/profiles.json.bak" "$T/profiles.json"

echo "passed=$pass failed=$fail scratch=$T"
[ "$fail" -eq 0 ]
