#!/usr/bin/env python3
"""Install or update the odd-flow core block in the current agent's global instructions file.

`plan` prints the target file and a unified diff without writing.
`apply` writes the block, after backing up the existing file.
`remove` removes the block, after backing up the existing file.
Only text between the odd-flow markers is ever changed.
"""

import argparse
import difflib
import os
import re
import shutil
import sys
import tempfile
import time

START = "<!-- odd-flow:core -->"
END = "<!-- /odd-flow:core -->"
BLOCK_RE = re.compile(re.escape(START) + r".*?" + re.escape(END) + r"\n?", re.S)

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSET = os.path.join(SKILL_DIR, "assets", "core-block.md")

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


def rendered_block():
    with open(ASSET, encoding="utf-8") as handle:
        body = handle.read().strip("\n")
    return f"{START}\n{body}\n{END}\n"


def updated_content(current):
    """Return the new file content with exactly one odd-flow block."""
    block = rendered_block()
    matches = BLOCK_RE.findall(current)
    if len(matches) > 1:
        raise InitError("the file has more than one odd-flow block; fix it by hand first")
    if current.count(START) != current.count(END) or current.count(START) != len(matches):
        raise InitError("the file has an unbalanced odd-flow marker; fix it by hand first")
    if matches:
        return BLOCK_RE.sub(lambda _m: block, current, count=1)
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


def cmd_plan(args):
    path = target_path(args.runtime, args.target)
    current = read_current(path)
    new = updated_content(current)
    print(f"target: {path} ({'exists' if os.path.exists(path) else 'will be created'})")
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
    new = updated_content(current)
    if new == current:
        print(f"{path}: up to date, nothing written")
        return
    backup = None
    if os.path.exists(path):
        backup = f"{path}.bak-odd-flow-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, backup)
    write_atomic(path, new)
    print(f"{path}: odd-flow block written" + (f"; backup: {backup}" if backup else " (new file)"))


def cmd_remove(args):
    path = target_path(args.runtime, args.target)
    current = read_current(path)
    if START not in current:
        print(f"{path}: no odd-flow block")
        return
    updated_content(current)  # validates marker balance
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
