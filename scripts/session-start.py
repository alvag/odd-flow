#!/usr/bin/env python3
"""SessionStart hook: inject the odd-flow core block and the active profile into the session context.

The core block follows the session's orchestrator mode: `core-block.md` for organic,
`core-block-full-delegation.md` for full delegation. A mode that cannot be resolved
loads the organic block and says so, so the session still starts with ODD rules.

Reads the hook payload from stdin, prints a SessionStart `additionalContext` JSON object,
and always exits 0 so a failure here never blocks the session.
"""

import json
import os
import subprocess
import sys

CODEX = sys.argv[1:] == ["--runtime", "codex"]
ROOT_VAR = "PLUGIN_ROOT" if CODEX else "CLAUDE_PLUGIN_ROOT"
PLUGIN_ROOT = os.environ.get(ROOT_VAR) or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_DIR = os.path.join(PLUGIN_ROOT, "skills", "odd-flow")
CORE_BLOCKS = {
    "organic": os.path.join(SKILL_DIR, "assets", "core-block.md"),
    "full-delegation": os.path.join(SKILL_DIR, "assets", "core-block-full-delegation.md"),
}
PROFILE_SCRIPT = os.path.join(SKILL_DIR, "scripts", "profile.py")


def read_payload():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except (ValueError, OSError):
        return {}


def core_block(mode):
    try:
        with open(CORE_BLOCKS[mode], encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError as exc:
        return f"odd-flow: core block unavailable ({exc})."


def profile_env(session_id):
    env = dict(os.environ)
    # Hook processes may not inherit the agent's session variable; the payload carries the same id.
    if CODEX:
        # profile.py checks the Claude key first, even in an inherited environment.
        env.pop("CLAUDE_CODE_SESSION_ID", None)
        if isinstance(session_id, str) and session_id:
            env["CODEX_THREAD_ID"] = session_id
    elif session_id and not env.get("CLAUDE_CODE_SESSION_ID"):
        env["CLAUDE_CODE_SESSION_ID"] = session_id
    return env


def run_profile(env, *args):
    """Return (exit code, text) of a profile.py call; exit code None when it could not run."""
    try:
        done = subprocess.run(
            [sys.executable, "-I", PROFILE_SCRIPT, *args],
            env=env, capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, str(exc)
    return done.returncode, (done.stdout or done.stderr).strip()


def session_mode(env):
    """Return (mode, note); note explains an organic fallback when the mode is unresolved."""
    code, text = run_profile(env, "mode", "--json")
    if code == 0:
        try:
            mode = json.loads(text)["mode"]
        except (ValueError, KeyError, TypeError):
            mode = None
        if mode in CORE_BLOCKS:
            return mode, None
    return "organic", f"odd-flow: mode unresolved ({text or 'no output'}); organic rules loaded until it is fixed."


def profile_state(env):
    code, text = run_profile(env, "show")
    if code is None:
        return f"odd-flow profile state unavailable ({text})."
    return text or "odd-flow profile state unavailable (no output)."


def emit_context(context):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))


def main():
    payload = read_payload()
    source = payload.get("source") or "unknown"
    env = profile_env(payload.get("session_id"))
    mode, note = session_mode(env)
    parts = [core_block(mode)]
    if note:
        parts.append(note)
    parts.append(
        f"### odd-flow session state (SessionStart source: {source})\n\n"
        f"Active odd-flow profile, resolved by `skills/odd-flow/scripts/profile.py show`:\n\n"
        f"```\n{profile_state(env)}\n```"
    )
    emit_context("\n\n".join(parts))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never block the session on a hook failure
        if CODEX:
            emit_context("")
        sys.exit(0)
