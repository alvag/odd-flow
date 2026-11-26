#!/usr/bin/env python3
"""SessionStart hook: inject the odd-flow core block and the active profile into the session context.

The core block follows the session's orchestrator mode: `core-block.md` for organic,
`core-block-full-delegation.md` for full delegation. A mode that cannot be resolved
loads the organic block and says so, so the session still starts with ODD rules.

Reads the hook payload from stdin, prints a SessionStart `additionalContext` JSON object
(Antigravity: an `injectSteps` system message), and always exits 0 so a failure here never
blocks the session.
"""

import json
import os
import runpy
import stat
import subprocess
import sys
import time

CODEX = sys.argv[1:] == ["--runtime", "codex"]
ANTIGRAVITY = sys.argv[1:] == ["--runtime", "antigravity"]
ROOT_VAR = "PLUGIN_ROOT" if CODEX else "CLAUDE_PLUGIN_ROOT"
# Antigravity is rooted relative to this script, so inherited root variables cannot redirect it.
PLUGIN_ROOT = (None if ANTIGRAVITY else os.environ.get(ROOT_VAR)) or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
SKILL_DIR = os.path.join(PLUGIN_ROOT, "skills", "odd-flow")
CORE_BLOCKS = {
    "organic": os.path.join(SKILL_DIR, "assets", "core-block.md"),
    "full-delegation": os.path.join(SKILL_DIR, "assets", "core-block-full-delegation.md"),
}
PROFILE_SCRIPT = os.path.join(SKILL_DIR, "scripts", "profile.py")
SECONDS_PER_DAY = 86400


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


def cleanup_session_state(data):
    if not data:
        return
    try:
        import fcntl

        directory = os.open(data, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            stamp = os.open("session-cleanup.stamp", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW
                            | os.O_NONBLOCK, 0o600, dir_fd=directory)
            try:
                # Claim the daily scan through the stamp without waiting for another hook.
                fcntl.flock(stamp, fcntl.LOCK_EX | fcntl.LOCK_NB)
                info = os.fstat(stamp)
                now = time.time()
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    return
                if info.st_size and now - info.st_mtime < SECONDS_PER_DAY:
                    return
                os.write(stamp, b"\n")
            finally:
                os.close(stamp)
        finally:
            os.close(directory)
        helpers = runpy.run_path(PROFILE_SCRIPT)
        helpers["prune_session_state"]([data], now - 30 * SECONDS_PER_DAY)
    except Exception:
        pass  # Cleanup must not change the SessionStart response.


def update_session_state(session_id, mode):
    try:
        # The hooks run with Python -I, which leaves the script directory off sys.path.
        # Load the sibling without running its CLI to share its data directory and hash.
        sibling = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompt-submit.py")
        helpers = runpy.run_path(sibling)
    except (OSError, ValueError):
        return
    try:
        marker = helpers["session_marker"](session_id, "session-modes")
        helpers["record_session_mode"](marker, mode)
    except (OSError, ValueError):
        pass  # A missing or unwritable marker must not suppress the core block.
    cleanup_session_state(os.environ.get(helpers["DATA_VAR"]))


def emit_context(context):
    if ANTIGRAVITY:
        steps = [{"systemMessage": {"systemMessage": context}}] if context else []
        print(json.dumps({"injectSteps": steps}))
        return
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))


def main():
    payload = read_payload()
    source = payload.get("source") or "unknown"
    session_id = payload.get("conversationId" if ANTIGRAVITY else "session_id")
    env = profile_env(session_id)
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
    update_session_state(session_id, mode)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never block the session on a hook failure
        if CODEX or ANTIGRAVITY:
            emit_context("")
        sys.exit(0)
