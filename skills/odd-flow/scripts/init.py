#!/usr/bin/env python3
"""Install or update the odd-flow core block in the current agent's global instructions file.

`plan` prints the target file and a unified diff without writing.
`apply` writes the block, after backing up the existing file.
`remove` removes the block, after backing up the existing file.
Only text between the odd-flow markers is ever changed.
"""

import argparse
import difflib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

START = "<!-- odd-flow:core -->"
END = "<!-- /odd-flow:core -->"
BLOCK_RE = re.compile(re.escape(START) + r".*?" + re.escape(END) + r"\n?", re.S)

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE_BLOCKS = {
    "organic": "core-block.md",
    "full-delegation": "core-block-full-delegation.md",
}
PROFILE_SCRIPT = os.path.join(SKILL_DIR, "scripts", "profile.py")

# Global instructions file per runtime, relative to HOME.
TARGETS = {
    "claude": os.path.join(".claude", "CLAUDE.md"),
    "codex": os.path.join(".codex", "AGENTS.md"),
    "antigravity": os.path.join(".gemini", "GEMINI.md"),
}

RUNTIME_VARS = (
    ("CLAUDE_CODE_SESSION_ID", "claude"),
    ("CODEX_THREAD_ID", "codex"),
    ("CODEX_SESSION_ID", "codex"),
    ("ANTIGRAVITY_CONVERSATION_ID", "antigravity"),
)


class InitError(Exception):
    pass


def detect_runtime():
    for var, runtime in RUNTIME_VARS:
        if os.environ.get(var, "").strip():
            return runtime
    return None


def target_path(runtime, explicit):
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    runtime = runtime or detect_runtime()
    if runtime not in TARGETS:
        raise InitError("cannot detect the agent runtime; pass --runtime claude|codex|antigravity or --target <file>")
    return os.path.join(os.path.expanduser("~"), TARGETS[runtime])


def resolve_mode(override):
    if override is not None:
        return override, "--mode"
    try:
        done = subprocess.run(
            [sys.executable, "-I", "-X", "utf8", PROFILE_SCRIPT, "mode", "--json"],
            capture_output=True, timeout=5, check=False,
        )
        if done.returncode:
            raise ValueError((done.stderr or done.stdout).decode("utf-8").strip() or f"exit {done.returncode}")
        state = json.loads(done.stdout.decode("utf-8"))
        mode, source = state["mode"], state["source"]
        if not isinstance(mode, str) or mode not in CORE_BLOCKS:
            raise ValueError(f"unknown mode {mode!r}")
        if not isinstance(source, str) or not source:
            raise ValueError("missing mode source")
        return mode, source
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
        raise InitError(f"cannot resolve mode ({exc}); pass --mode organic|full-delegation") from exc


def warn_if_session_only(source):
    if source == "env ODD_ORCHESTRATOR_MODE" or source.startswith("session ("):
        print("warning: the resolved mode is session-only, but the installed block is persistent")


def rendered_block(mode):
    with open(os.path.join(SKILL_DIR, "assets", CORE_BLOCKS[mode]), encoding="utf-8") as handle:
        body = handle.read().strip("\n")
    return f"{START}\n{body}\n{END}\n"


def existing_block(current):
    matches = list(BLOCK_RE.finditer(current))
    if len(matches) > 1:
        raise InitError("the file has more than one odd-flow block; fix it by hand first")
    if current.count(START) != current.count(END) or current.count(START) != len(matches):
        raise InitError("the file has an unbalanced odd-flow marker; fix it by hand first")
    return matches[0] if matches else None


def updated_content(current, block, match):
    """Return the new file content with exactly one odd-flow block."""
    if match:
        return current[:match.start()] + block + current[match.end():]
    if not current:
        return block
    separator = "" if current.endswith("\n\n") else ("\n" if current.endswith("\n") else "\n\n")
    return current + separator + block


def read_current(path):
    if os.path.islink(path):
        raise InitError(f"{path} is a symlink; pass --target with the real file")
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def format_apply_lines(command, platform):
    bash = shlex.join(command)
    if platform != "nt":
        return f"apply: {bash}"
    # Match the PowerShell single-quote rule in profile.py's shell_quote.
    quoted = ["'" + re.sub("['\u2018\u2019\u201a\u201b]", lambda m: m.group() * 2, arg) + "'" for arg in command]
    return f"apply (PowerShell): & {' '.join(quoted)}\napply (bash): {bash}"


def cmd_plan(args):
    path = target_path(args.runtime, args.target)
    current = read_current(path)
    match = existing_block(current)
    mode, source = resolve_mode(args.mode)
    block = rendered_block(mode)
    new = updated_content(current, block, match)
    print(f"target: {path} ({'exists' if os.path.exists(path) else 'will be created'})")
    print(f"mode: {mode} ({source}); block: assets/{CORE_BLOCKS[mode]}")
    if match:
        installed = next(
            (name for name in CORE_BLOCKS
             if match[0].rstrip("\n") == (block if name == mode else rendered_block(name)).rstrip("\n")),
            "unknown",
        )
        print(f"installed mode: {installed}")
    warn_if_session_only(source)
    command = [sys.executable, os.path.abspath(__file__), "apply", "--mode", mode]
    if args.runtime is not None:
        command.extend(["--runtime", args.runtime])
    if args.target is not None:
        command.extend(["--target", path])
    print(format_apply_lines(command, os.name))
    if new == current:
        print("status: up to date, nothing to write")
        return
    print("status: changes pending")
    diff = difflib.unified_diff(
        current.splitlines(keepends=True), new.splitlines(keepends=True),
        fromfile=f"{path} (current)", tofile=f"{path} (after init)",
    )
    sys.stdout.writelines(diff)


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".odd-flow-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def cmd_apply(args):
    path = target_path(args.runtime, args.target)
    current = read_current(path)
    match = existing_block(current)
    mode, source = resolve_mode(args.mode)
    new = updated_content(current, rendered_block(mode), match)
    if new == current:
        print(f"{path}: up to date, nothing written")
    else:
        backup = None
        if os.path.exists(path):
            backup = f"{path}.bak-odd-flow-{time.strftime('%Y%m%d-%H%M%S')}"
            shutil.copy2(path, backup)
        write_atomic(path, new)
        print(f"{path}: odd-flow block written" + (f"; backup: {backup}" if backup else " (new file)"))
    print(f"mode: {mode}; block: assets/{CORE_BLOCKS[mode]}")
    warn_if_session_only(source)


def cmd_remove(args):
    path = target_path(args.runtime, args.target)
    current = read_current(path)
    if START not in current:
        print(f"{path}: no odd-flow block")
        return
    existing_block(current)
    new = BLOCK_RE.sub("", current, count=1)
    backup = f"{path}.bak-odd-flow-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    write_atomic(path, new.rstrip("\n") + "\n" if new.strip() else "")
    print(f"{path}: odd-flow block removed; backup: {backup}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="init.py", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name, func, text in (
        ("plan", cmd_plan, "show the target and the diff without writing"),
        ("apply", cmd_apply, "write the block, backing up the file first"),
        ("remove", cmd_remove, "remove the block, backing up the file first"),
    ):
        cmd = sub.add_parser(name, help=text)
        cmd.add_argument("--runtime", choices=sorted(TARGETS))
        cmd.add_argument("--target", help="explicit instructions file (overrides --runtime)")
        if name != "remove":
            cmd.add_argument("--mode", choices=CORE_BLOCKS, help="override the resolved orchestrator mode")
        cmd.set_defaults(func=func)
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except (InitError, OSError) as exc:
        print(f"odd-flow init: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
