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


def evaluate_windows_dacl_sddl(sddl, user_sid):
    if not isinstance(sddl, str) or not isinstance(user_sid, str) or not user_sid:
        return False
    d_index = sddl.find("D:")
    s_index = sddl.find("S:")
    if d_index == -1 or (s_index != -1 and s_index < d_index):
        return False

    after_d = sddl[d_index + 2:]
    if after_d == "NO_ACCESS_CONTROL" or after_d.startswith("NO_ACCESS_CONTROL" + "S:"):
        return False

    flags_match = re.match(r"^([A-Za-z]*)", after_d)
    flags = flags_match.group(1) if flags_match else ""
    if not re.fullmatch(r"(?:P|AI|AR)*", flags, re.IGNORECASE):
        return False

    allowed_sids = {"SY", "S-1-5-18", "BA", "S-1-5-32-544", user_sid.upper()}
    pos = len(flags)
    while pos < len(after_d):
        if after_d.startswith("S:", pos):
            break
        if after_d[pos] != "(":
            return False

        depth = 0
        end = pos
        while end < len(after_d):
            if after_d[end] == "(":
                depth += 1
            elif after_d[end] == ")":
                depth -= 1
                if depth == 0:
                    break
            end += 1
        if depth != 0 or end >= len(after_d):
            return False

        parts = after_d[pos + 1:end].split(";")
        pos = end + 1
        if len(parts) < 6:
            return False

        ace_type = parts[0].upper()
        if ace_type == "D":
            if len(parts) != 6:
                return False
            continue
        if ace_type != "A":
            return False
        if len(parts) != 6 or not parts[5]:
            return False
        if parts[5].upper() not in allowed_sids:
            return False

    return True


def windows_owner_matches(sddl, user_sid):
    if not isinstance(sddl, str) or not isinstance(user_sid, str) or not user_sid:
        return False
    match = re.match(r"O:([^:]+?)(?=[GDS]:|$)", sddl)
    return match is not None and match.group(1).upper() == user_sid.upper()


def _windows_token_dir_trusted(tokens_dir):
    try:
        import ctypes
        from ctypes import wintypes

        advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        kernel32.GetCurrentProcess.argtypes = []
        kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        kernel32.LocalFree.restype = ctypes.c_void_p

        advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
        advapi32.OpenProcessToken.restype = wintypes.BOOL
        advapi32.GetTokenInformation.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
        ]
        advapi32.GetTokenInformation.restype = wintypes.BOOL
        advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        advapi32.ConvertSidToStringSidW.restype = wintypes.BOOL
        advapi32.GetNamedSecurityInfoW.argtypes = [
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p),
        ]
        advapi32.GetNamedSecurityInfoW.restype = wintypes.DWORD
        advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.ULONG),
        ]
        advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW.restype = wintypes.BOOL

        class _SidAndAttributes(ctypes.Structure):
            _fields_ = [("Sid", ctypes.c_void_p), ("Attributes", wintypes.DWORD)]

        class _TokenUser(ctypes.Structure):
            _fields_ = [("User", _SidAndAttributes)]

        token_handle = wintypes.HANDLE()
        if not advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), 0x0008, ctypes.byref(token_handle)):
            return False
        try:
            size = wintypes.DWORD()
            advapi32.GetTokenInformation(token_handle, 1, None, 0, ctypes.byref(size))
            if not size.value:
                return False
            buf = (ctypes.c_ubyte * size.value)()
            if not advapi32.GetTokenInformation(token_handle, 1, buf, size.value, ctypes.byref(size)):
                return False
            token_user = ctypes.cast(buf, ctypes.POINTER(_TokenUser)).contents
            sid_ptr = ctypes.c_void_p()
            if not advapi32.ConvertSidToStringSidW(token_user.User.Sid, ctypes.byref(sid_ptr)):
                return False
            try:
                user_sid = ctypes.wstring_at(sid_ptr.value)
            finally:
                kernel32.LocalFree(sid_ptr)
        finally:
            kernel32.CloseHandle(token_handle)

        sd_ptr = ctypes.c_void_p()
        sec_info = 0x00000001 | 0x00000004
        if advapi32.GetNamedSecurityInfoW(
            str(tokens_dir), 1, sec_info, None, None, None, None, ctypes.byref(sd_ptr),
        ) != 0:
            return False
        try:
            sddl_ptr = ctypes.c_void_p()
            if not advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW(
                sd_ptr, 1, sec_info, ctypes.byref(sddl_ptr), None,
            ):
                return False
            try:
                sddl = ctypes.wstring_at(sddl_ptr.value)
            finally:
                kernel32.LocalFree(sddl_ptr)
        finally:
            kernel32.LocalFree(sd_ptr)

        return windows_owner_matches(sddl, user_sid) and evaluate_windows_dacl_sddl(sddl, user_sid)
    except Exception:
        return False


def consume_worker_token(line):
    match = WORKER_MARKER.fullmatch(line)
    if match is None:
        return False
    role, token = match.groups()
    try:
        state_dir = os.environ.get("ODD_FLOW_STATE_DIR")
        if state_dir and not Path(state_dir).is_absolute():
            return False
        tokens_dir = Path(state_dir or Path.home() / ".odd-flow") / "worker-tokens"
        if os.name == "nt":
            directory = tokens_dir.lstat()
            reparse_point = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x0400)
            if (not stat.S_ISDIR(directory.st_mode)
                    or (getattr(directory, "st_file_attributes", 0) & reparse_point)
                    or not _windows_token_dir_trusted(tokens_dir)):
                return False
        else:
            getuid = getattr(os, "getuid", None)
            if getuid is None:
                return False
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
