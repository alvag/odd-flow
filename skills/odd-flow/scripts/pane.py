#!/usr/bin/env python3
"""Open an Orca worker in a split pane or a separate tab."""

import argparse
import fcntl
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import termios
import time

# Isolated mode omits the script directory. Always import the bundled profile.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
sys.dont_write_bytecode = True
from profile import ProfileError, load_profiles, orca_line, orca_terminal, resolve_role


SPLIT_HINT = "A pane may have opened. Check terminal list and close it."
CREATE_HINT = "A terminal may have opened. Check terminal list and close it."
ORCA_TIMEOUT_SECS = 30
ORCA_SPLIT_TIMEOUT_SECS = 40


def terminal(*args, timeout_context=""):
    hint = {"split": f". {SPLIT_HINT}", "create": f". {CREATE_HINT}"}.get(args[0], "")
    uncertain = hint + timeout_context
    timeout = ORCA_SPLIT_TIMEOUT_SECS if args[0] == "split" else ORCA_TIMEOUT_SECS
    try:
        proc = subprocess.run(
            [os.environ.get("ORCA_CLI_COMMAND", "orca"), "terminal", *args, "--json"],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"Orca terminal {args[0]}: timed out (limit: {exc.timeout}s){uncertain}"
        ) from exc
    try:
        data = json.loads(proc.stdout)
        if not isinstance(data, dict):
            raise ValueError("expected an object")
    except ValueError as exc:
        detail = proc.stderr.strip() or proc.stdout.strip() or str(exc)
        raise RuntimeError(f"Orca terminal {args[0]}: {detail}{uncertain}") from exc
    if proc.returncode or data.get("ok") is False:
        detail = data.get("error") or proc.stderr.strip() or proc.stdout.strip()
        recovery = detail.get("data") if isinstance(detail, dict) else None
        if isinstance(detail, dict):
            detail = detail.get("message") or detail
        if args[0] == "split":
            retrying = args[-2:-1] == ("--retry-split",)
            pending = isinstance(recovery, dict) and recovery.get("splitMayStillComplete") is True
            if pending and not retrying:
                split_id = recovery.get("splitId")
                if isinstance(split_id, str) and re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", split_id):
                    try:
                        return terminal(*args, "--retry-split", split_id, timeout_context=timeout_context)
                    except (OSError, RuntimeError) as exc:
                        raise RuntimeError(f"{exc} Original split reply for leaf {split_id}: {detail}") from exc
            if pending or retrying:
                detail = str(detail).rstrip(".") + uncertain
        raise RuntimeError(f"Orca terminal {args[0]}: {detail}")
    result = data.get("result", {})
    if args[0] == "split":
        pane = result.get("split") if isinstance(result, dict) else None
        handle = pane.get("handle") if isinstance(pane, dict) else None
        if not isinstance(handle, str) or not handle:
            raise RuntimeError(f"Orca terminal split: missing split handle{uncertain}")
        return handle
    return result


def malformed_layout(detail):
    return RuntimeError(f"malformed Orca terminal layout: {detail}")


def right_columns(node, parent, panes_only=False):
    if not isinstance(node, dict):
        raise malformed_layout("expected a node object")
    kind = node.get("type")
    if kind == "terminal":
        handle = node.get("handle")
        if not isinstance(handle, str) or not handle:
            raise malformed_layout("terminal node has no handle")
    elif kind == "pane-split":
        direction = node.get("direction")
        if direction not in ("horizontal", "vertical"):
            raise malformed_layout("invalid pane split direction")
        first, second = node.get("first"), node.get("second")
        if (
            direction == "vertical" and isinstance(first, dict)
            and first.get("type") == "terminal" and first.get("handle") == parent
        ):
            yield second, False
        yield from right_columns(first, parent, panes_only=True)
        yield from right_columns(second, parent, panes_only=True)
    elif not panes_only and kind == "split":
        yield from right_columns(node.get("first"), parent)
        yield from right_columns(node.get("second"), parent)
    elif not panes_only and kind == "group":
        tabs = node.get("tabs")
        if not isinstance(tabs, list):
            raise malformed_layout("group tabs must be a list")
        for tab in tabs:
            if not isinstance(tab, dict):
                raise malformed_layout("expected a tab object")
            panes = tab.get("panes")
            yield from right_columns(panes, parent, panes_only=True)
            if panes["type"] == "terminal" and panes["handle"] == parent:
                yield None, True
    else:
        raise malformed_layout(f"unexpected node type {kind!r}")


def layout_target(layout, parent):
    items = layout.get("visualLayouts") if isinstance(layout, dict) else None
    if not isinstance(items, list):
        raise malformed_layout("visualLayouts must be a list")
    column = None
    parent_alone = False
    for item in items:
        if not isinstance(item, dict):
            raise malformed_layout("expected a visualLayouts entry object")
        for candidate, alone in right_columns(item.get("root"), parent):
            # Keep the first match, but finish traversing to validate the layout.
            if column is None:
                column = candidate
            parent_alone |= alone
    target = max(leaves(column), key=lambda leaf: leaf[0])[1] if column is not None else None
    return target, parent_alone


def leaves(node, height=1):
    if node["type"] == "terminal":
        yield height, node["handle"]
    else:
        child_height = height / 2 if node["direction"] == "horizontal" else height
        # Visit later leaves first so max() breaks height ties in their favor.
        yield from leaves(node["second"], child_height)
        yield from leaves(node["first"], child_height)


def parent_cols():
    pid = os.getppid()
    while pid > 1:
        try:
            ps = subprocess.run(
                ["ps", "-o", "ppid=,tty=", "-p", str(pid)],
                capture_output=True, text=True, check=True,
            )
            next_pid, *tty = ps.stdout.split()
            next_pid = int(next_pid)
            if tty and tty[0] not in {"?", "??"}:
                try:
                    fd = os.open(f"/dev/{tty[0]}", os.O_RDONLY | os.O_NOCTTY)
                except FileNotFoundError:
                    # macOS ps can report sNNN rather than ttysNNN.
                    fd = os.open(f"/dev/tty{tty[0]}", os.O_RDONLY | os.O_NOCTTY)
                try:
                    size = fcntl.ioctl(fd, termios.TIOCGWINSZ, bytes(8))
                    return struct.unpack("HHHH", size)[1] or None
                finally:
                    os.close(fd)
            if next_pid == pid:
                break
            pid = next_pid
        except (OSError, subprocess.SubprocessError, ValueError):
            break
    return None


def recorded_width(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as record:
            age = time.time() - os.fstat(record.fileno()).st_mtime
            if not 0 <= age <= 10 * 60:
                return None
            return int(record.read(16))
    except (OSError, ValueError):
        return None


def open_pane(args):
    parent = orca_terminal()
    if parent is None:
        raise ProfileError(orca_line())
    role = resolve_role(load_profiles(), args.role)
    try:
        min_cols = int(os.environ.get("ODD_FLOW_SPLIT_MIN_COLS", "160"))
        if min_cols <= 0:
            raise ValueError
    except ValueError as exc:
        raise ProfileError("ODD_FLOW_SPLIT_MIN_COLS must be a positive integer") from exc
    try:
        settle_ms = int(os.environ.get("ODD_FLOW_SPLIT_SETTLE_MS", "1000"))
        if settle_ms < 0:
            raise ValueError
    except ValueError as exc:
        raise ProfileError("ODD_FLOW_SPLIT_SETTLE_MS must be a non-negative integer") from exc
    command = role["split_command"]
    quoted_title = json.dumps(args.title, ensure_ascii=False)

    pane_path = os.path.join(tempfile.gettempdir(), f"odd-flow-pane-{parent}")
    width_path = pane_path + ".cols"
    lock_fd = os.open(pane_path + ".lock", os.O_CREAT | os.O_RDONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "r") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        target, parent_alone = None, False
        if command is not None:
            layout = terminal("list", "--include-visual-layouts")
            target, parent_alone = layout_target(layout, parent)
        cols = args.cols if args.cols is not None else parent_cols()
        if command is not None and target is None and args.cols is None and settle_ms:
            # The layout can lose its right column before the TTY grows.
            deadline = time.monotonic_ns() + settle_ms * 1_000_000
            while cols is not None and cols < min_cols:
                remaining = deadline - time.monotonic_ns()
                if remaining <= 0:
                    break
                time.sleep(min(100_000_000, remaining) / 1_000_000_000)
                cols = parent_cols()

        result = dict(placement="tab", handle=None, parent=parent, target=None,
                      cols=cols, min_cols=min_cols, reason=None, title_error=None)
        if command is None:
            result["reason"] = f"no split command for {role['agent']}"
            return result, role
        saved_cols = None
        if (
            target is None and parent_alone and args.cols is None
            and cols is not None and cols < min_cols
        ):
            recorded = recorded_width(width_path)
            if recorded is not None and recorded >= min_cols:
                saved_cols = recorded
        if target:
            result.update(placement="split-below", target=target, reason="right column exists")
            direction = "horizontal"
        elif (cols is not None and cols >= min_cols) or saved_cols is not None:
            reason = (
                f"parent terminal has at least {min_cols} columns" if saved_cols is None
                else f"parent terminal measured {cols} columns; recorded width is {saved_cols} columns"
            )
            result.update(placement="split-right", target=parent, reason=reason)
            direction = "vertical"
        else:
            result["reason"] = (
                "parent terminal width is unknown" if cols is None
                else f"parent terminal is {cols} columns wide (minimum {min_cols})"
            )
            timeout_context = f" Worktree: current; title: {quoted_title}."
            try:
                baseline = terminal("list", "--worktree", "current", "--limit", "1000")
                rows = baseline.get("terminals") if isinstance(baseline, dict) else None
                if not isinstance(rows, list) or baseline.get("truncated"):
                    raise RuntimeError("terminal list is incomplete")
                handles = [row.get("handle") if isinstance(row, dict) else None for row in rows]
                if any(not isinstance(handle, str) or not handle for handle in handles):
                    raise RuntimeError("terminal list contains a row without a handle")
                timeout_context += f" Pre-create handles: {json.dumps(sorted(set(handles)))}."
            except (OSError, RuntimeError) as exc:
                timeout_context += f" Pre-create handles unavailable: {exc}."
            created = terminal("create", "--worktree", "current", "--title", args.title,
                               "--command", command, timeout_context=timeout_context)
            tab = created.get("terminal") if isinstance(created, dict) else None
            handle = tab.get("handle") if isinstance(tab, dict) else None
            if not isinstance(handle, str) or not handle:
                raise RuntimeError(f"Orca terminal create: missing terminal handle. {CREATE_HINT}{timeout_context}")
            result["handle"] = handle
            return result, role
        timeout_context = (f" Split target: {result['target']}; direction: {direction};"
                           f" intended title: {quoted_title}.")
        handle = terminal("split", "--terminal", result["target"], "--direction", direction,
                          "--command", command, timeout_context=timeout_context)
        result["handle"] = handle
        if direction == "vertical" and args.cols is None and cols is not None and cols >= min_cols:
            try:
                fd = os.open(
                    width_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | os.O_NONBLOCK,
                    0o600,
                )
                with os.fdopen(fd, "w") as record:
                    record.write(f"{cols}\n")
            except OSError:
                # The split already succeeded; a missing record must not hide its handle.
                pass

    try:
        terminal("set-pane-title", "--terminal", handle, "--title", args.title)
    except (OSError, RuntimeError) as exc:
        result["title_error"] = str(exc)
    return result, role


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    open_cmd = sub.add_parser("open", help="open a split pane or tab")
    open_cmd.add_argument("--role", required=True)
    open_cmd.add_argument("--title", required=True)
    open_cmd.add_argument("--cols", type=int, help="override the measured parent width")
    open_cmd.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result, role = open_pane(args)
    except ProfileError as exc:
        print(f"odd-flow: {exc}", file=sys.stderr)
        return 2
    except (OSError, RuntimeError) as exc:
        print(f"odd-flow: {exc}", file=sys.stderr)
        return 1
    if args.json:
        result.update({key: role[key] for key in ("role", "agent", "model", "effort")})
        print(json.dumps(result))
    else:
        line = f"pane: {result['placement']} {result['handle'] or '-'}: {result['reason']}"
        if result["title_error"]:
            line += f"; {result['title_error']}"
        line += " | " + role["notice"].split(" | ", 1)[1]
        print(line.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
