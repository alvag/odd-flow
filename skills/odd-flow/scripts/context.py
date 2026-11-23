#!/usr/bin/env python3
"""Measure the current agent session's context size for the writer context trigger.

Claude Code: the session transcript under $CLAUDE_CONFIG_DIR (default ~/.claude)
records each reply's usage; the context is input + cache creation + cache read
tokens of the last main-thread reply. Codex: the session rollout under $CODEX_HOME
(default ~/.codex) records token_count events; the context is the last event's
input tokens. Any other runtime, or a missing file, reports unknown with a reason.
Always exits 0: a measurement never blocks work.
"""

import argparse
import glob
import json
import os
import sys

THRESHOLD = 150_000
TAIL_BYTES = 4 * 1024 * 1024


def tail_lines(path):
    """Last lines of a possibly large JSONL file, newest last."""
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - TAIL_BYTES))
        data = handle.read().decode("utf-8", errors="replace")
    lines = data.splitlines()
    return lines[1:] if size > TAIL_BYTES else lines


def records(path):
    for line in tail_lines(path):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict):
            yield record


def claude(session_id):
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    matches = glob.glob(os.path.join(glob.escape(home), "projects", "*", glob.escape(session_id) + ".jsonl"))
    if not matches:
        return None, None, f"no transcript for session {session_id} under {home}/projects"
    tokens = None
    for record in records(max(matches, key=os.path.getmtime)):
        if record.get("type") != "assistant" or record.get("isSidechain"):
            continue
        usage = (record.get("message") or {}).get("usage")
        if isinstance(usage, dict):
            tokens = sum(int(usage.get(key) or 0) for key in
                         ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    if tokens is None:
        return None, None, "transcript has no usage yet"
    return tokens, None, None


def codex(thread_id):
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    matches = glob.glob(os.path.join(glob.escape(home), "sessions", "**", f"rollout-*{glob.escape(thread_id)}.jsonl"),
                        recursive=True)
    if not matches:
        return None, None, f"no rollout for thread {thread_id} under {home}/sessions"
    tokens = window = None
    for record in records(max(matches, key=os.path.getmtime)):
        payload = record.get("payload") or {}
        if payload.get("type") != "token_count":
            continue
        info = payload.get("info") or {}
        last = info.get("last_token_usage") or {}
        if "input_tokens" in last:
            tokens = int(last["input_tokens"])
            window = info.get("model_context_window") or window
    if tokens is None:
        return None, None, "rollout has no token_count yet"
    return tokens, window, None


def measure():
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if session:
        source, (tokens, window, reason) = "claude transcript", claude(session)
    elif os.environ.get("CODEX_THREAD_ID", "").strip() or os.environ.get("CODEX_SESSION_ID", "").strip():
        thread = (os.environ.get("CODEX_THREAD_ID") or os.environ.get("CODEX_SESSION_ID")).strip()
        source, (tokens, window, reason) = "codex rollout", codex(thread)
    elif os.environ.get("ANTIGRAVITY_CONVERSATION_ID", "").strip():
        source, tokens, window, reason = None, None, None, "no token source known for antigravity"
    else:
        source, tokens, window, reason = None, None, None, "no agent session id in the environment"
    return {
        "tokens": tokens,
        "window": window,
        "threshold": THRESHOLD,
        "holds": None if tokens is None else tokens >= THRESHOLD,
        "source": source,
        "reason": reason,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(prog="context.py", description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = measure()
    except Exception as exc:  # a measurement never blocks work
        result = {"tokens": None, "window": None, "threshold": THRESHOLD, "holds": None,
                  "source": None, "reason": f"measurement failed: {exc}"}
    if args.json:
        print(json.dumps(result))
    elif result["tokens"] is None:
        print(f"context: unknown ({result['reason']}); writer context trigger: judge it yourself")
    else:
        window = f" of {result['window']}" if result["window"] else ""
        verdict = "holds" if result["holds"] else "does not hold"
        print(f"context: {result['tokens']} tokens{window} ({result['source']}); "
              f"writer context trigger: {verdict} (threshold {THRESHOLD})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
