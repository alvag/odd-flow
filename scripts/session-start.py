#!/usr/bin/env python3
"""SessionStart hook: inject the odd-flow core block and the active profile into the session context.

Reads the hook payload from stdin, prints a SessionStart `additionalContext` JSON object,
and always exits 0 so a failure here never blocks the session.
"""

import json
import os
import subprocess
import sys

PLUGIN_ROOT = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_DIR = os.path.join(PLUGIN_ROOT, "skills", "odd-flow")
CORE_BLOCK = os.path.join(SKILL_DIR, "assets", "core-block.md")
PROFILE_SCRIPT = os.path.join(SKILL_DIR, "scripts", "profile.py")


def read_payload():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except (ValueError, OSError):
        return {}


def core_block():
    try:
        with open(CORE_BLOCK, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError as exc:
        return f"odd-flow: core block unavailable ({exc})."


def profile_state(session_id):
    env = dict(os.environ)
    # Hook processes may not inherit the agent's session variable; the payload carries the same id.
    if session_id and not env.get("CLAUDE_CODE_SESSION_ID"):
        env["CLAUDE_CODE_SESSION_ID"] = session_id
    try:
        done = subprocess.run(
            [sys.executable, "-I", PROFILE_SCRIPT, "show"],
            env=env, capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return f"odd-flow profile state unavailable ({exc})."
    text = (done.stdout or done.stderr).strip()
    return text or "odd-flow profile state unavailable (no output)."


def main():
    payload = read_payload()
    source = payload.get("source") or "unknown"
    context = "\n\n".join([
        core_block(),
        f"### odd-flow session state (SessionStart source: {source})\n\n"
        f"Active odd-flow profile, resolved by `skills/odd-flow/scripts/profile.py show`:\n\n"
        f"```\n{profile_state(payload.get('session_id'))}\n```",
    ])
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never block the session on a hook failure
        sys.exit(0)
