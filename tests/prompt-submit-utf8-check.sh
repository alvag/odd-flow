#!/usr/bin/env bash
# Regression test for UTF-8 stdin decoding in scripts/prompt-submit.py on cp1252 locales.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX")
trap 'rm -rf -- "$T"' EXIT

env -i PATH="$PATH" python3 -I -B - "$ROOT" "$T" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
scratch = scratch.resolve()
home = scratch / "home"
profiles = scratch / "profiles"
claude_data = scratch / "claude-data"
agy_data = scratch / "agy-data"
for directory in (home, profiles, claude_data, agy_data):
    directory.mkdir(parents=True)
(profiles / "profiles.json").write_text('{"default":"A","profiles":{"A":{}}}', encoding="utf-8")

base_env = {
    "PATH": os.environ["PATH"],
    "HOME": str(home),
    "ODD_FLOW_HOME": str(profiles),
    "ODD_ORCHESTRATOR_MODE": "full-delegation",
}


def marker_value(data_dir, session_id):
    key = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    marker = data_dir / "prompt-sessions" / key
    return marker.read_text(encoding="ascii") if marker.is_file() else None


def run_claude(session_id, prompt):
    payload = json.dumps({"session_id": session_id, "prompt": prompt}, ensure_ascii=False).encode("utf-8")
    return subprocess.run(
        [sys.executable, "-I", str(root / "scripts/prompt-submit.py")],
        cwd=scratch,
        env=base_env | {"CLAUDE_PLUGIN_DATA": str(claude_data)},
        input=payload,
        capture_output=True,
        timeout=12,
    )


def run_antigravity(conversation_id, prompt):
    payload = json.dumps(
        {"conversationId": conversation_id, "invocationNum": 0, "lastUserInput": prompt},
        ensure_ascii=False,
    ).encode("utf-8")
    return subprocess.run(
        [sys.executable, "-I", str(root / "scripts/prompt-submit.py"), "--runtime", "antigravity"],
        cwd=scratch,
        env=base_env | {"PLUGIN_DATA": str(agy_data)},
        input=payload,
        capture_output=True,
        timeout=12,
    )


def run_raw(args, extra_env, raw_bytes):
    return subprocess.run(
        [sys.executable, "-I", str(root / "scripts/prompt-submit.py"), *args],
        cwd=scratch,
        env=base_env | extra_env,
        input=raw_bytes,
        capture_output=True,
        timeout=12,
    )


failed = 0


def check(label, condition, detail=""):
    global failed
    if condition:
        print(f"PASS {label}")
    else:
        failed += 1
        print(f"FAIL {label}: {detail}")


ascii_claude = run_claude("claude-ascii", "Check alarm")
utf8_claude_id = "claude-\u23f0"
utf8_claude = run_claude(utf8_claude_id, "Check \u23f0")
check(
    "Claude Code U+23F0 matches ASCII output and marker",
    ascii_claude.returncode == 0
    and utf8_claude.returncode == 0
    and not utf8_claude.stderr
    and utf8_claude.stdout == ascii_claude.stdout
    and marker_value(claude_data, utf8_claude_id) == marker_value(claude_data, "claude-ascii") == "parent",
    f"ascii={ascii_claude!r}, utf8={utf8_claude!r}, marker={marker_value(claude_data, utf8_claude_id)!r}",
)

ascii_agy = run_antigravity("agy-ascii", "Check alarm")
utf8_agy_id = "agy-\u23f0"
utf8_agy = run_antigravity(utf8_agy_id, "Check \u23f0")
check(
    "Antigravity U+23F0 matches ASCII output and marker",
    ascii_agy.returncode == 0
    and utf8_agy.returncode == 0
    and not utf8_agy.stderr
    and utf8_agy.stdout == ascii_agy.stdout
    and marker_value(agy_data, utf8_agy_id) == marker_value(agy_data, "agy-ascii") == "parent",
    f"ascii={ascii_agy!r}, utf8={utf8_agy!r}, marker={marker_value(agy_data, utf8_agy_id)!r}",
)

bad_claude = run_raw([], {"CLAUDE_PLUGIN_DATA": str(claude_data)}, b'{"session_id":"bad-claude","prompt":"\xff"}')
check(
    "Claude Code invalid UTF-8 fails closed without marker",
    bad_claude.returncode == 0 and not bad_claude.stderr and marker_value(claude_data, "bad-claude") is None,
    f"result={bad_claude!r}, marker={marker_value(claude_data, 'bad-claude')!r}",
)

bad_agy = run_raw(
    ["--runtime", "antigravity"],
    {"PLUGIN_DATA": str(agy_data)},
    b'{"conversationId":"bad-agy","invocationNum":0,"lastUserInput":"\xff"}',
)
check(
    "Antigravity invalid UTF-8 fails closed without marker",
    bad_agy.returncode == 0
    and not bad_agy.stderr
    and json.loads(bad_agy.stdout.decode("utf-8")) == {"injectSteps": []}
    and marker_value(agy_data, "bad-agy") is None,
    f"result={bad_agy!r}, marker={marker_value(agy_data, 'bad-agy')!r}",
)

sys.exit(1 if failed else 0)
PY
