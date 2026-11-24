#!/usr/bin/env python3
"""UserPromptSubmit hook: give full-delegation coordinators and workers distinct context.

The SessionStart core block is fixed for the whole session, so a mode switched mid-session
(`profile.py use`, `session-mode`, `set-mode`) would otherwise reach the model only once.
Organic sessions get no additional context (Claude Code gets no output). Always exits 0:
a failure here never blocks a prompt.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

CODEX = sys.argv[1:] == ["--runtime", "codex"]
ROOT_VAR = "PLUGIN_ROOT" if CODEX else "CLAUDE_PLUGIN_ROOT"
DATA_VAR = "PLUGIN_DATA" if CODEX else "CLAUDE_PLUGIN_DATA"
PLUGIN_ROOT = os.environ.get(ROOT_VAR) or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE_SCRIPT = os.path.join(PLUGIN_ROOT, "skills", "odd-flow", "scripts", "profile.py")
ORCA_WORKER_PREFIXES = (
    "You are working inside Orca, a multi-agent IDE.",
    "Please carry out this task from my Orca coordinator by following the brief I pasted below.",
)
WORKER_ROLE = re.compile(r"# Role: (explore|write|verify|review|refute)", re.IGNORECASE)


def session_marker(session_id):
    data = os.environ.get(DATA_VAR)
    if not data or not isinstance(session_id, str) or not session_id:
        return None
    key = hashlib.sha256(session_id.encode("utf-8", errors="surrogatepass")).hexdigest()
    return Path(data) / "prompt-sessions" / key


def mark_first_prompt(session_id, prompt):
    marker = session_marker(session_id)
    if marker is None:
        return
    prompt = prompt.lstrip() if isinstance(prompt, str) else ""
    first_line = prompt.splitlines()[0].rstrip() if prompt else ""
    worker = prompt.startswith(ORCA_WORKER_PREFIXES) or WORKER_ROLE.fullmatch(first_line)
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation keeps any later prompt from changing the recorded role.
        with marker.open("x", encoding="ascii") as stream:
            stream.write("worker" if worker else "parent")
    except (OSError, ValueError):
        pass


def is_worker_session(session_id):
    marker = session_marker(session_id)
    try:
        return marker is not None and marker.read_bytes() == b"worker"
    except (OSError, ValueError):
        return False


def mode_state(session_id):
    env = dict(os.environ)
    if CODEX:
        # profile.py checks the Claude key first, even in an inherited environment.
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        if isinstance(session_id, str) and session_id:
            env["CODEX_THREAD_ID"] = session_id
    elif session_id and not env.get("CLAUDE_CODE_SESSION_ID"):
        env["CLAUDE_CODE_SESSION_ID"] = session_id
    done = subprocess.run(
        [sys.executable, "-I", PROFILE_SCRIPT, "mode", "--json"],
        env=env, capture_output=True, text=True, timeout=5, check=False,
    )
    if done.returncode != 0:
        return {}
    return json.loads(done.stdout)


def emit_context(context):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}))


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except (ValueError, OSError):
        payload = {}
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if isinstance(payload, dict):
        mark_first_prompt(session_id, payload.get("prompt"))
    state = mode_state(session_id)
    if state.get("mode") != "full-delegation":
        if CODEX:
            emit_context("")
        return 0
    if is_worker_session(session_id):
        emit_context("You are a dispatched worker. Follow your spec's role rules, not the coordinator rules from session start.")
        return 0
    line = (
        f"odd-flow mode: full-delegation ({state.get('source')}). The parent coordinates and writes "
        "only what the mode file lists; bounded writers make all other workspace changes. "
        f"Rules: skills/odd-flow/{state.get('rules')}."
    )
    emit_context(line)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never block a prompt on a hook failure
        if CODEX:
            emit_context("")
        sys.exit(0)
