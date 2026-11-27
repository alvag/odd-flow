#!/usr/bin/env bash
# Check Windows worker-token ACL and owner validation in scripts/prompt-submit.py.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX")
trap 'rm -rf -- "$T"' EXIT

env -i PATH="$PATH" SystemRoot="${SystemRoot:-${SYSTEMROOT:-}}" python3 -I -B - "$ROOT" "$T" <<'PY'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root, scratch = map(Path, sys.argv[1:])
scratch = scratch.resolve()

spec = importlib.util.spec_from_file_location("prompt_submit", root / "scripts/prompt-submit.py")
prompt_submit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prompt_submit)

failed = 0


def check(label, condition, detail=""):
    global failed
    if condition:
        print(f"PASS {label}")
    else:
        failed += 1
        print(f"FAIL {label}: {detail}")


fixtures = json.loads((root / "orca-plugin/src/fixtures/windows-token-acl.json").read_text(encoding="utf-8"))
user_sid = fixtures["userSid"]

for case in fixtures["cases"]:
    actual = prompt_submit.evaluate_windows_dacl_sddl(case["sddl"], user_sid)
    check(
        f"fixture {case['name']}",
        actual is case["accept"],
        f"expected {case['accept']!r}, got {actual!r}",
    )

owner_cases = (
    ("owner matches user SID", f"O:{user_sid}D:(A;;FA;;;{user_sid})", True),
    ("owner matches user SID case-insensitively", f"O:{user_sid.lower()}D:(A;;FA;;;{user_sid})", True),
    ("owner BA rejected", f"O:BAD:(A;;FA;;;{user_sid})", False),
    ("owner SY rejected", f"O:SYD:(A;;FA;;;{user_sid})", False),
    (
        "owner another SID rejected",
        f"O:S-1-5-21-1000000000-2000000000-3000000000-1001D:(A;;FA;;;{user_sid})",
        False,
    ),
    ("missing owner section rejected", f"D:(A;;FA;;;{user_sid})", False),
)
for label, sddl, expected in owner_cases:
    actual = prompt_submit.windows_owner_matches(sddl, user_sid)
    check(label, actual is expected, f"expected {expected!r}, got {actual!r}")

if os.name != "nt":
    print("SKIP Windows hook integration checks (not running on Windows)")
    sys.exit(1 if failed else 0)

import _winapi

system_root = os.environ.get("SystemRoot")
assert system_root and Path(system_root).is_absolute(), f"missing SystemRoot: {system_root!r}"
whoami = subprocess.run(
    [str(Path(system_root) / "System32" / "whoami.exe"), "/user", "/fo", "csv", "/nh"],
    capture_output=True,
    text=True,
    encoding="utf-8",
    timeout=10,
    check=True,
)
current_sid = whoami.stdout.strip().split('","')[1].rstrip('"')
icacls_exe = str(Path(system_root) / "System32" / "icacls.exe")


def make_private(path):
    subprocess.run(
        [
            icacls_exe,
            str(path),
            "/inheritance:r",
            "/grant:r",
            "*S-1-5-18:(OI)(CI)F",
            "*S-1-5-32-544:(OI)(CI)F",
            f"*{current_sid}:(OI)(CI)F",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )


def issue_record(tokens_dir, token, role="write"):
    record = tokens_dir / hashlib.sha256(token.encode("ascii")).hexdigest()
    record.write_text(
        json.dumps({"role": role, "issuedAt": time.time_ns() // 1_000_000}),
        encoding="utf-8",
    )
    return record


def run_claude_hook(data_dir, state_dir, session_id, token):
    payload = json.dumps(
        {"session_id": session_id, "prompt": f"Dispatched task\nodd-flow-worker: write {token}"},
        ensure_ascii=False,
    ).encode("utf-8")
    env = {
        "PATH": os.environ["PATH"],
        "SystemRoot": system_root,
        "CLAUDE_PLUGIN_DATA": str(data_dir),
        "ODD_FLOW_STATE_DIR": str(state_dir),
        "ODD_ORCHESTRATOR_MODE": "full-delegation",
    }
    return subprocess.run(
        [sys.executable, "-I", str(root / "scripts/prompt-submit.py")],
        cwd=scratch,
        env=env,
        input=payload,
        capture_output=True,
        timeout=12,
    )


def marker_value(data_dir, session_id):
    key = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    marker = data_dir / "prompt-sessions" / key
    return marker.read_text(encoding="ascii") if marker.is_file() else None


data_dir = scratch / "claude-data"
data_dir.mkdir(parents=True)

private_state = scratch / "private-state"
private_tokens = private_state / "worker-tokens"
private_tokens.mkdir(parents=True)
make_private(private_state)

valid_token = "0123456789abcdef0123456789abcdef"
valid_record = issue_record(private_tokens, valid_token)
res_valid = run_claude_hook(data_dir, private_state, "win-valid", valid_token)
check(
    "valid token in private Windows dir marks worker and removes record",
    res_valid.returncode == 0
    and not res_valid.stderr
    and marker_value(data_dir, "win-valid") == "worker"
    and not valid_record.exists(),
    f"rc={res_valid.returncode}, stderr={res_valid.stderr!r}, marker={marker_value(data_dir, 'win-valid')!r}, exists={valid_record.exists()}",
)

subprocess.run(
    [icacls_exe, str(private_tokens), "/grant", "*S-1-1-0:R"],
    capture_output=True,
    text=True,
    encoding="utf-8",
    timeout=10,
    check=True,
)
broad_token = "abcdef0123456789abcdef0123456789"
broad_record = issue_record(private_tokens, broad_token)
res_broad = run_claude_hook(data_dir, private_state, "win-broad", broad_token)
check(
    "Everyone-readable worker-tokens marks parent and keeps record",
    res_broad.returncode == 0
    and not res_broad.stderr
    and marker_value(data_dir, "win-broad") == "parent"
    and broad_record.is_file(),
    f"rc={res_broad.returncode}, stderr={res_broad.stderr!r}, marker={marker_value(data_dir, 'win-broad')!r}, exists={broad_record.is_file()}",
)

junction_target = scratch / "junction-target"
junction_target.mkdir(parents=True)
make_private(junction_target)
junction_state = scratch / "junction-state"
junction_state.mkdir(parents=True)
make_private(junction_state)
junction_tokens = junction_state / "worker-tokens"
_winapi.CreateJunction(str(junction_target), str(junction_tokens))

junction_token = "fedcba9876543210fedcba9876543210"
junction_record = issue_record(junction_target, junction_token)
res_junction = run_claude_hook(data_dir, junction_state, "win-junction", junction_token)
check(
    "junction worker-tokens marks parent and keeps record",
    res_junction.returncode == 0
    and not res_junction.stderr
    and marker_value(data_dir, "win-junction") == "parent"
    and junction_record.is_file(),
    f"rc={res_junction.returncode}, stderr={res_junction.stderr!r}, marker={marker_value(data_dir, 'win-junction')!r}, exists={junction_record.is_file()}",
)

sys.exit(1 if failed else 0)
PY
