#!/usr/bin/env bash
# Behavioral checks for profile.py discover, save and default, against an isolated
# ODD_FLOW_HOME, a fake Orca CLI and a fake Codex models cache.
set -u
P="$(cd "$(dirname "$0")/.." && pwd)/skills/odd-flow/scripts/profile.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
expect() { # name, expected substring, actual, expected exit, actual exit
  if [[ "$3" == *"$2"* && "$4" == "$5" ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  want exit $4 and: $2"; echo "  got  exit $5: $3"; fi
}
refute() { # name, unexpected substring, actual
  if [[ "$3" != *"$2"* ]]; then pass=$((pass+1)); echo "PASS $1";
  else fail=$((fail+1)); echo "FAIL $1"; echo "  did not want: $2"; echo "  got: $3"; fi
}
same() { # name, file, expected sha
  local got; got=$(shasum "$2" 2>/dev/null | cut -d' ' -f1)
  if [[ "$got" == "$3" ]]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "  file changed: $2"; fi
}

mkdir -p "$T/bin" "$T/codex"
printf '#!/bin/sh\nprintf %%s %s\n' "'{\"ok\":true,\"result\":{\"agents\":[{\"id\":\"claude\"},{\"id\":\"codex\"},{\"id\":\"pi\"}]}}'" >"$T/bin/orca"
chmod +x "$T/bin/orca"
printf '%s' '{"models":[{"slug":"gpt-a","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"gpt-hidden","visibility":"hide","supported_reasoning_levels":[]}]}' >"$T/codex/models_cache.json"
run() { env -i HOME="$T" PATH="$T/bin:$PATH" ODD_FLOW_HOME="$T/home" CODEX_HOME="$T/codex" CLAUDE_CODE_SESSION_ID=s1 "$@" 2>&1; }

# discover
out=$(run python3 -I "$P" discover --json); ec=$?
expect "discover: lists Orca agents" '"id": "pi"' "$out" 0 $ec
expect "discover: codex models from the cache, verified" '"id": "codex", "models": [{"id": "gpt-a", "efforts": ["low", "high"]}], "verified": true' "$out" 0 $ec
refute "discover: hidden codex models are left out" "gpt-hidden" "$out"
expect "discover: claude models are marked unverified" '"verified": false' "$out" 0 $ec
expect "discover: agents without a source report no models" '"id": "pi", "models": [], "verified": null' "$out" 0 $ec

out=$(run ORCA_CLI_COMMAND="$T/missing-orca" python3 -I "$P" discover --json); ec=$?
expect "discover: Orca unavailable is reported, not fatal" '"orca_error"' "$out" 0 $ec

out=$(run python3 -I "$P" discover); ec=$?
expect "discover: text mode names each agent" "codex: gpt-a (low, high) [verified: codex models cache]" "$out" 0 $ec

# save: dry run, write, refuse overwrite, validation
printf '%s' '{"explore": {"agent": "codex", "model": "gpt-a", "effort": "low"}}' >"$T/roles.json"
out=$(run python3 -I "$P" save fast --roles-file "$T/roles.json"); ec=$?
expect "save: dry run shows the diff" '+    "fast": {' "$out" 0 $ec
expect "save: dry run says how to write" "re-run with --yes" "$out" 0 $ec
[ -e "$T/home/profiles.json" ] && { fail=$((fail+1)); echo "FAIL save: dry run wrote the file"; } || { pass=$((pass+1)); echo "PASS save: dry run writes nothing"; }

out=$(run python3 -I "$P" save fast --roles-file "$T/roles.json" --yes); ec=$?
expect "save --yes: writes the profile" "profile 'fast' saved" "$out" 0 $ec
out=$(run ODD_PROFILE=fast python3 -I "$P" resolve explore --json); ec=$?
expect "save --yes: resolve uses the saved values" '"--model", "gpt-a", "--effort", "low"' "$out" 0 $ec

sha=$(shasum "$T/home/profiles.json" | cut -d' ' -f1)
out=$(run python3 -I "$P" save fast --roles-file "$T/roles.json" --yes); ec=$?
expect "save: existing profile needs --replace" "already exists" "$out" 2 $ec
same "save: refused overwrite leaves the file unchanged" "$T/home/profiles.json" "$sha"

printf '%s' '{"explore": {"agent": "codex", "model": "gpt-b"}}' >"$T/roles2.json"
out=$(run python3 -I "$P" save fast --roles-file "$T/roles2.json" --replace --yes); ec=$?
expect "save --replace --yes: replaces the profile" "profile 'fast' saved" "$out" 0 $ec

printf '%s' '{"writer": {"agent": "codex"}}' >"$T/bad.json"
sha=$(shasum "$T/home/profiles.json" | cut -d' ' -f1)
out=$(run python3 -I "$P" save other --roles-file "$T/bad.json" --yes); ec=$?
expect "save: invalid roles are rejected" "unknown role" "$out" 2 $ec
same "save: rejected roles leave the file unchanged" "$T/home/profiles.json" "$sha"

printf '%s' '{"explore": {"effort": "low"}}' >"$T/bad2.json"
out=$(run python3 -I "$P" save other --roles-file "$T/bad2.json" --yes); ec=$?
expect "save: effort without model is rejected" "'effort' requires 'model'" "$out" 2 $ec

printf '%s' '{"profiles": {"keep": {}}, "note": "mine"}' >"$T/home/profiles.json"
out=$(run python3 -I "$P" save fast --roles-file "$T/roles.json" --yes); ec=$?
expect "save: other profiles are kept" '"keep"' "$(cat "$T/home/profiles.json")" 0 $ec
expect "save: unknown top-level keys are kept" '"note": "mine"' "$(cat "$T/home/profiles.json")" 0 $ec

# default
sha=$(shasum "$T/home/profiles.json" | cut -d' ' -f1)
out=$(run python3 -I "$P" default fast); ec=$?
expect "default: dry run shows the diff" '+  "default": "fast",' "$out" 0 $ec
same "default: dry run leaves the file unchanged" "$T/home/profiles.json" "$sha"
changed=$(printf '%s\n' "$out" | grep -E '^[+-]' | grep -vcE '^(\+\+\+|---) ')
expect "default: on a file the script wrote, the diff holds only the new line" "1" "$changed" 0 0

out=$(run python3 -I "$P" default fast --yes); ec=$?
expect "default --yes: writes the default" "default profile: fast" "$out" 0 $ec
out=$(run python3 -I "$P" resolve explore --json); ec=$?
expect "default --yes: resolve uses it" '"profile": "fast", "profile_source": "file default"' "$out" 0 $ec

sha=$(shasum "$T/home/profiles.json" | cut -d' ' -f1)
out=$(run python3 -I "$P" default nope --yes); ec=$?
expect "default: unknown profile is rejected" "profile 'nope' is not defined" "$out" 2 $ec
same "default: rejected name leaves the file unchanged" "$T/home/profiles.json" "$sha"

# discover survives a Codex cache with an unexpected shape
for bad in '{"models": null}' '{"models": 5}' '{"models":[{"slug":"g","supported_reasoning_levels":null}]}' '{"models":[{"slug":7}]}'; do
  printf '%s' "$bad" >"$T/codex/models_cache.json"
  out=$(run python3 -I "$P" discover --json); ec=$?
  expect "discover: tolerates cache $bad" '"id": "pi"' "$out" 0 $ec
  refute "discover: no traceback for cache $bad" "Traceback" "$out"
done
refute "discover: a non-string slug is not reported as a model" '"id": 7' "$out"

# non-ASCII survives a write unescaped, so the diff shows only the real change
printf '%s\n' '{' '  "profiles": {' '    "señor": {}' '  }' '}' >"$T/home/profiles.json"
out=$(run python3 -I "$P" default "señor"); ec=$?
esc="$(printf '%s%s' "$(printf '\\')" u00f1)"  # a JSON escape for the n with tilde
refute "default: unicode names are not escaped in the diff" "$esc" "$out"
out=$(run python3 -I "$P" default "señor" --yes); ec=$?
expect "default: unicode name written as UTF-8" '"default": "señor"' "$(cat "$T/home/profiles.json")" 0 $ec
out=$(run python3 -I "$P" default "señor" --yes); ec=$?
expect "default: setting the current default writes nothing" "already the default" "$out" 0 $ec

# file mode and symlinks are kept across an atomic write
chmod 644 "$T/home/profiles.json"
printf '%s' '{"explore": {"agent": "codex"}}' >"$T/roles3.json"
out=$(run python3 -I "$P" save keepmode --roles-file "$T/roles3.json" --yes); ec=$?
expect "save: keeps file mode 644" "644" "$(stat -f %Lp "$T/home/profiles.json")" 0 $ec
mv "$T/home/profiles.json" "$T/real.json"; ln -s "$T/real.json" "$T/home/profiles.json"
out=$(run python3 -I "$P" save viaLink --roles-file "$T/roles3.json" --yes); ec=$?
expect "save: a symlinked file is written through the link" '"viaLink"' "$(cat "$T/real.json")" 0 $ec
[ -L "$T/home/profiles.json" ] && { pass=$((pass+1)); echo "PASS save: the symlink stays a symlink"; } || { fail=$((fail+1)); echo "FAIL save: the symlink stays a symlink"; }

# failures are odd-flow errors, not tracebacks
printf '\xff\xfe' >"$T/latin.json"
out=$(run python3 -I "$P" save bad --roles-file "$T/latin.json" --yes); ec=$?
expect "save: a non-UTF-8 roles file is an odd-flow error" "odd-flow:" "$out" 2 $ec
rm "$T/home/profiles.json"; mv "$T/real.json" "$T/home/profiles.json"; chmod 555 "$T/home"
out=$(run python3 -I "$P" save ro --roles-file "$T/roles3.json" --yes); ec=$?
expect "save: a read-only directory is an odd-flow error" "odd-flow: cannot write" "$out" 2 $ec
chmod 755 "$T/home"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
