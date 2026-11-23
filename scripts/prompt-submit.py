#!/usr/bin/env python3
"""UserPromptSubmit hook: restate the orchestrator mode on every prompt of a full delegation session.

The SessionStart core block is fixed for the whole session, so a mode switched mid-session
(`profile.py use`, `session-mode`, `set-mode`) would otherwise reach the model only once.
Organic sessions get no output, so their context is unchanged. Always exits 0: a failure here
never blocks a prompt.
"""

import json
import os
import subprocess
import sys

PLUGIN_ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE_SCRIPT = os.path.join(PLUGIN_ROOT, "skills", "odd-flow", "scripts", "profile.py")


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except (ValueError, OSError):
        payload = {}
    env = dict(os.environ)
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if session_id and not env.get("CLAUDE_CODE_SESSION_ID"):
        env["CLAUDE_CODE_SESSION_ID"] = session_id
    done = subprocess.run(
        [sys.executable, "-I", PROFILE_SCRIPT, "mode", "--json"],
        env=env, capture_output=True, text=True, timeout=5, check=False,
    )
    if done.returncode != 0:
        return 0
    state = json.loads(done.stdout)
    if state.get("mode") != "full-delegation":
        return 0
    line = (
        f"odd-flow mode: full-delegation ({state.get('source')}). The parent coordinates and writes "
        "only what the mode file lists; bounded writers make all other workspace changes. "
        f"Rules: skills/odd-flow/{state.get('rules')}."
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": line}}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never block a prompt on a hook failure
        sys.exit(0)
