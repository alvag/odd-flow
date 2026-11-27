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
from pathlib import Path
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
CLEANUP_BUDGET_SECONDS = 1


def read_payload():
    try:
        return json.loads((sys.stdin.buffer.read() or b"{}").decode("utf-8"))
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
            [sys.executable, "-I", "-X", "utf8", PROFILE_SCRIPT, *args],
            env=env, capture_output=True, timeout=5, check=False,
        )
        text = (done.stdout or done.stderr).decode("utf-8")
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError) as exc:
        return None, str(exc)
    return done.returncode, text.replace("\r\n", "\n").replace("\r", "\n").strip()


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


def cleanup_windows_session_state(data):
    import ctypes
    from ctypes import wintypes

    class Overlapped(ctypes.Structure):
        _fields_ = [
            ("Internal", ctypes.c_size_t), ("InternalHigh", ctypes.c_size_t),
            ("Offset", wintypes.DWORD), ("OffsetHigh", wintypes.DWORD),
            ("hEvent", wintypes.HANDLE),
        ]

    deadline = time.monotonic() + CLEANUP_BUDGET_SECONDS
    helpers = runpy.run_path(PROFILE_SCRIPT)
    parent, name = os.path.split(os.path.abspath(data))
    # Opening data as a part of its parent rejects a junction or symlink on data itself.
    with helpers["_open_state_dir"](Path(parent), name) as pinned:
        if pinned is None:
            return
        # GENERIC_READ | GENERIC_WRITE, share read and write, OPEN_REPARSE_POINT, 4: OPEN_ALWAYS.
        with helpers["_windows_handle"](os.path.join(data, "session-cleanup.stamp"), 0xC0000000,
                                        0x3, 0x00200000, disposition=4) as (kernel32, stamp):
            overlapped_pointer = ctypes.POINTER(Overlapped)
            kernel32.LockFileEx.argtypes = [
                wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                wintypes.DWORD, overlapped_pointer,
            ]
            kernel32.LockFileEx.restype = wintypes.BOOL
            kernel32.UnlockFileEx.argtypes = [
                wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                overlapped_pointer,
            ]
            kernel32.UnlockFileEx.restype = wintypes.BOOL
            kernel32.WriteFile.argtypes = [
                wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p,
            ]
            kernel32.WriteFile.restype = wintypes.BOOL
            overlapped = Overlapped()
            # Claim the daily scan through the stamp without waiting for another hook:
            # 0x3 is LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, on byte 0.
            if not kernel32.LockFileEx(stamp, 0x3, 0, 1, 0, ctypes.byref(overlapped)):
                return
            try:
                info = helpers["_windows_file_info"](kernel32, stamp)
                # 0x0410: reparse point or directory.
                if info.dwFileAttributes & 0x0410 or info.nNumberOfLinks != 1:
                    return
                now = time.time()
                written = info.ftLastWriteTime
                # FILETIME counts 100 ns intervals since 1601.
                ticks = written.dwHighDateTime << 32 | written.dwLowDateTime
                age = now - (ticks / 10_000_000 - 11_644_473_600)
                if (info.nFileSizeHigh or info.nFileSizeLow) and 0 <= age < SECONDS_PER_DAY:
                    return
                helpers["prune_session_state"]([data], now - 30 * SECONDS_PER_DAY,
                                               deadline=deadline)
                if time.monotonic() < deadline:
                    count = wintypes.DWORD()
                    if not kernel32.WriteFile(stamp, b"\n", 1, ctypes.byref(count), None):
                        raise ctypes.WinError(ctypes.get_last_error())
            finally:
                kernel32.UnlockFileEx(stamp, 0, 1, 0, ctypes.byref(overlapped))


def cleanup_session_state(data):
    if not data:
        return
    try:
        if os.name == "nt":
            cleanup_windows_session_state(data)
            return
        import fcntl

        deadline = time.monotonic() + CLEANUP_BUDGET_SECONDS
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
                if info.st_size and 0 <= now - info.st_mtime < SECONDS_PER_DAY:
                    return
                helpers = runpy.run_path(PROFILE_SCRIPT)
                helpers["prune_session_state"]([data], now - 30 * SECONDS_PER_DAY,
                                               deadline=deadline)
                if time.monotonic() < deadline:
                    os.write(stamp, b"\n")
            finally:
                os.close(stamp)
        finally:
            os.close(directory)
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
