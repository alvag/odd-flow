#!/usr/bin/env python3
"""UserPromptSubmit hook: on every prompt, restate full delegation to the coordinator or give the worker role context.

The SessionStart core block is fixed for the whole session. A parent gets a one-time notice
when its mode changes; otherwise organic sessions get no additional context. Always exits 0:
a failure here never blocks a prompt.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

CODEX = sys.argv[1:] == ["--runtime", "codex"]
ANTIGRAVITY = sys.argv[1:] == ["--runtime", "antigravity"]
ROOT_VAR = "PLUGIN_ROOT" if CODEX else "CLAUDE_PLUGIN_ROOT"
DATA_VAR = "PLUGIN_DATA" if CODEX or ANTIGRAVITY else "CLAUDE_PLUGIN_DATA"
# Antigravity is rooted relative to this script, so inherited root variables cannot redirect it.
PLUGIN_ROOT = (None if ANTIGRAVITY else os.environ.get(ROOT_VAR)) or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
PROFILE_SCRIPT = os.path.join(PLUGIN_ROOT, "skills", "odd-flow", "scripts", "profile.py")
ORCA_WORKER_PREFIXES = (
    "You are working inside Orca, a multi-agent IDE.",
    "Please carry out this task from my Orca coordinator by following the brief I pasted below.",
)
WORKER_ROLES = r"(explore|write|verify|review|refute)"
WORKER_ROLE = re.compile(rf"# Role: {WORKER_ROLES}", re.IGNORECASE | re.ASCII)
WORKER_MARKER = re.compile(rf"odd-flow-worker: {WORKER_ROLES} ((?-i:[0-9a-f]{{32}}))", re.IGNORECASE | re.ASCII)
PASTED_CONTENT_CLOSE = re.compile(r'</pasted_content id=(?:"[A-Za-z0-9_-]+"|[A-Za-z0-9_-]+)>')


def session_marker(session_id, bucket="prompt-sessions"):
    data = os.environ.get(DATA_VAR)
    if not data or not isinstance(session_id, str) or not session_id:
        return None
    key = hashlib.sha256(session_id.encode("utf-8", errors="surrogatepass")).hexdigest()
    return Path(data) / bucket / key


def record_session_mode(marker, mode):
    if marker is not None:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(mode, encoding="ascii")


def consume_worker_token(line):
    match = WORKER_MARKER.fullmatch(line)
    if match is None:
        return False
    role, token = match.groups()
    try:
        getuid = getattr(os, "getuid", None)
        if getuid is None:
            return False
        state_dir = os.environ.get("ODD_FLOW_STATE_DIR")
        if state_dir and not Path(state_dir).is_absolute():
            return False
        tokens_dir = Path(state_dir or Path.home() / ".odd-flow") / "worker-tokens"
        directory = tokens_dir.lstat()
        if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != getuid()
                or stat.S_IMODE(directory.st_mode) != 0o700):
            return False
        key = hashlib.sha256(token.encode("ascii")).hexdigest()
        record = tokens_dir / key
        if not stat.S_ISREG(record.lstat().st_mode):
            return False
        data = json.loads(record.read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("role") != role.lower():
            return False
        issued_at = data.get("issuedAt")
        now = time.time_ns() // 1_000_000
        if type(issued_at) not in (int, float) or not now - 900_000 <= issued_at <= now + 60_000:
            return False
        # Remove the record on first use so a later prompt cannot reuse it.
        # This does not guard against simultaneous use by multiple sessions.
        os.unlink(record)
    except (OSError, ValueError, RuntimeError):
        return False
    return True


def mark_first_prompt(session_id, prompt):
    marker = session_marker(session_id)
    if marker is None:
        return
    prompt = prompt.lstrip() if isinstance(prompt, str) else ""
    lines = prompt.rstrip().splitlines()
    last_line = lines[-1] if lines else ""
    if PASTED_CONTENT_CLOSE.fullmatch(last_line):
        # Claude Code can wrap an Orca brief in pasted_content.
        last_line = next(filter(None, map(str.strip, reversed(lines[:-1]))), "")
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation keeps any later prompt from changing the recorded role.
        with marker.open("x", encoding="ascii") as stream:
            worker = bool(lines) and (
                consume_worker_token(last_line.strip())
                or prompt.startswith(ORCA_WORKER_PREFIXES)
                or WORKER_ROLE.fullmatch(lines[0].rstrip())
            )
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
    if ANTIGRAVITY:
        # profile.py checks the Claude and Codex keys first, even in an inherited environment.
        for foreign in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CODEX_SESSION_ID"):
            env.pop(foreign, None)
        if isinstance(session_id, str) and session_id:
            env["ANTIGRAVITY_CONVERSATION_ID"] = session_id
    elif CODEX:
        # profile.py checks the Claude key first, even in an inherited environment.
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        if isinstance(session_id, str) and session_id:
            env["CODEX_THREAD_ID"] = session_id
    elif session_id and not env.get("CLAUDE_CODE_SESSION_ID"):
        env["CLAUDE_CODE_SESSION_ID"] = session_id
    done = subprocess.run(
        [sys.executable, "-I", PROFILE_SCRIPT, "mode", "--json"],
        env=env, capture_output=True, text=True, encoding="utf-8", timeout=5, check=False,
    )
    if done.returncode != 0:
        return {}
    return json.loads(done.stdout)


def emit_context(context):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": context}}))


def mode_change_notice(session_id, state):
    mode = state.get("mode")
    if mode not in ("organic", "full-delegation"):
        return ""
    marker = session_marker(session_id, "session-modes")
    if marker is None:
        return ""
    try:
        try:
            previous = marker.read_text(encoding="ascii")
        except FileNotFoundError:
            previous = None
        if previous != mode:
            # Only announce a transition that we can remember on the next prompt.
            record_session_mode(marker, mode)
            if previous in ("organic", "full-delegation"):
                return (
                    f"odd-flow mode changed to {mode} ({state.get('source')}); the session-start "
                    f"{previous} rules no longer apply. Rules: skills/odd-flow/{state.get('rules')}."
                )
    except (OSError, ValueError):
        pass
    return ""


def prompt_context(session_id):
    state = mode_state(session_id)
    full = state.get("mode") == "full-delegation"
    if is_worker_session(session_id):
        return (
            "You are a dispatched worker. Follow your spec's role rules, not the coordinator rules from session start."
        ) if full else ""
    notice = mode_change_notice(session_id, state)
    if not full:
        return notice
    line = (
        f"odd-flow mode: full-delegation ({state.get('source')}). The parent coordinates and writes "
        "only what the mode file lists; bounded writers make all other workspace changes. "
        f"Rules: skills/odd-flow/{state.get('rules')}."
    )
    return f"{notice}\n{line}" if notice else line


def antigravity_main():
    """Mark the session and inject prompt context only on the first invocation of a turn."""
    steps = []
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        if isinstance(payload, dict):
            conversation = payload.get("conversationId")
            mark_first_prompt(conversation, payload.get("lastUserInput"))
            number = payload.get("invocationNum", 0)
            if number is None:
                number = 0
            context = prompt_context(conversation) if number == 0 else ""
            if context:
                steps = [{"systemMessage": {"systemMessage": context}}]
    except Exception:  # never block an invocation on a hook failure
        steps = []
    print(json.dumps({"injectSteps": steps}))
    return 0


def main():
    if ANTIGRAVITY:
        return antigravity_main()
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8") or "{}")
    except (ValueError, OSError):
        payload = {}
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if isinstance(payload, dict):
        mark_first_prompt(session_id, payload.get("prompt"))
    context = prompt_context(session_id)
    if context or CODEX:
        emit_context(context)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never block a prompt on a hook failure
        if CODEX:
            emit_context("")
        sys.exit(0)
