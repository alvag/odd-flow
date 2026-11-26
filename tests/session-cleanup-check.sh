#!/usr/bin/env bash
# SessionStart cleanup runs only against isolated session state.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 -I - "$root" "$scratch" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

root, scratch = map(Path, sys.argv[1:])
sys.argv[1:] = []
day = 86400
stamp_name = "session-cleanup.stamp"


def record(path, age=31):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()
    set_age(path, age)
    return path


def set_age(path, days):
    then = time.time() - days * day
    os.utime(path, (then, then))


def key(session):
    return hashlib.sha256(session.encode("ascii")).hexdigest()


class SessionCleanupCheck(unittest.TestCase):
    def setUp(self):
        self.state = scratch / self._testMethodName
        self.data = self.state / "data"
        self.bindings = self.state / "odd-flow" / "sessions"
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.state / "home"),
            "ODD_FLOW_HOME": str(self.bindings.parent),
            "CLAUDE_CONFIG_DIR": str(self.state / "claude"),
            "CODEX_HOME": str(self.state / "codex"),
            "ODD_FLOW_STATE_DIR": str(self.state),
            "TMPDIR": str(self.state),
        }

    def hook(self, runtime="claude", **data_env):
        session_key = "conversationId" if runtime == "antigravity" else "session_id"
        args = [] if runtime == "claude" else ["--runtime", runtime]
        return subprocess.run(
            [sys.executable, "-I", str(root / "scripts/session-start.py"), *args],
            input=json.dumps({session_key: "current", "source": "startup"}).encode(),
            env=dict(self.env, **{name: str(path) for name, path in data_env.items()}),
            capture_output=True,
        )

    def output(self, result):
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertTrue(result.stdout)
        return result.stdout, result.stderr, result.returncode

    def test_expired_state_only(self):
        expired = [record(self.bindings / "expired.json")]
        kept = [record(self.bindings / "recent.json", 29),
                record(self.bindings / "notes.txt"),
                record(self.state / "worker-tokens" / key("token"))]
        outside = record(self.state / "outside")
        for bucket in ("prompt-sessions", "session-modes"):
            expired.append(record(self.data / bucket / key("expired")))
            kept.extend([record(self.data / bucket / key("recent"), 29),
                         record(self.data / bucket / "notes")])
            link = self.data / bucket / key("symlink")
            link.symlink_to(outside)
            kept.append(link)
        self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data))
        for path in expired:
            self.assertFalse(path.exists(), path)
        for path in [*kept, outside]:
            self.assertTrue(path.exists(), path)

    def test_stamp_limits_cleanup_to_once_a_day(self):
        first = record(self.data / "prompt-sessions" / key("first"))
        self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data))
        stamp = self.data / stamp_name
        self.assertTrue(stamp.is_file())
        self.assertFalse(first.exists())
        later = record(self.data / "prompt-sessions" / key("later"))
        self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data))
        self.assertTrue(later.is_file())
        set_age(stamp, 2)
        self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data))
        self.assertFalse(later.exists())

    def test_future_stamp_does_not_throttle_cleanup(self):
        expired = record(self.data / "prompt-sessions" / key("expired"))
        stamp = self.data / stamp_name
        stamp.write_bytes(b"\n")
        set_age(stamp, -2)
        future = stamp.stat().st_mtime
        self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data))
        self.assertFalse(expired.exists())
        self.assertLess(stamp.stat().st_mtime, future)
        self.assertLess(time.time() - stamp.stat().st_mtime, day)

    def test_budget_exhaustion_leaves_stamp_stale_and_resumes(self):
        expired = [record(self.data / "prompt-sessions" / key(session))
                   for session in ("first", "second")]
        stamp = self.data / stamp_name
        stamp.write_bytes(b"\n")
        set_age(stamp, 2)
        before = stamp.stat().st_mtime_ns
        clock = 100.0
        unlink = os.unlink

        def unlink_at_deadline(path, **kwargs):
            nonlocal clock
            unlink(path, **kwargs)
            clock = 101.0

        cleanup = runpy.run_path(str(root / "scripts/session-start.py"))["cleanup_session_state"]
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(time, "monotonic", side_effect=lambda: clock), \
                patch.object(os, "unlink", side_effect=unlink_at_deadline):
            cleanup(str(self.data))

        self.assertEqual(sum(path.exists() for path in expired), 1)
        self.assertEqual(stamp.stat().st_mtime_ns, before)
        self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data))
        self.assertFalse(any(path.exists() for path in expired))
        self.assertGreater(stamp.stat().st_mtime_ns, before)

    def test_unreadable_bindings_do_not_stop_record_cleanup(self):
        self.bindings.parent.mkdir(parents=True)
        if os.geteuid() == 0:
            self.bindings.touch()
        else:
            self.bindings.mkdir(mode=0o000)
        expired = [record(self.data / bucket / key("expired"))
                   for bucket in ("prompt-sessions", "session-modes")]
        try:
            expected = self.output(self.hook())
            self.assertEqual(self.output(self.hook(CLAUDE_PLUGIN_DATA=self.data)), expected)
        finally:
            if self.bindings.is_dir():
                self.bindings.chmod(0o700)
        self.assertTrue((self.data / stamp_name).is_file())
        for path in expired:
            self.assertFalse(path.exists(), path)

    def test_each_runtime_only_cleans_its_own_data(self):
        for runtime in ("claude", "codex", "antigravity"):
            with self.subTest(runtime=runtime):
                owned = self.state / runtime
                foreign = self.state / (runtime + "-foreign")
                expired = record(owned / "prompt-sessions" / key("expired"))
                untouched = record(foreign / "prompt-sessions" / key("expired"))
                data = (dict(CLAUDE_PLUGIN_DATA=owned, PLUGIN_DATA=foreign)
                        if runtime == "claude" else
                        dict(PLUGIN_DATA=owned, CLAUDE_PLUGIN_DATA=foreign))
                self.output(self.hook(runtime, **data))
                self.assertFalse(expired.exists())
                self.assertTrue(untouched.is_file())
                self.assertFalse((foreign / stamp_name).exists())

    def test_output_and_status_are_unchanged(self):
        for runtime in ("claude", "codex", "antigravity"):
            with self.subTest(runtime=runtime):
                variable = "CLAUDE_PLUGIN_DATA" if runtime == "claude" else "PLUGIN_DATA"
                binding = record(self.bindings / "expired.json")
                expected = self.output(self.hook(runtime))
                self.assertTrue(binding.is_file())  # No plugin data means no cleanup.
                unwritable = self.state / (runtime + "-unwritable")
                if os.geteuid() == 0:
                    # Root bypasses directory permissions; a regular file still blocks writes.
                    unwritable.touch()
                else:
                    unwritable.mkdir(mode=0o555)
                try:
                    self.assertEqual(self.output(self.hook(runtime, **{variable: unwritable})), expected)
                finally:
                    if unwritable.is_dir():
                        unwritable.chmod(0o700)
                self.assertTrue(binding.is_file())
                data = self.state / runtime
                record(data / "session-modes" / key("expired"))
                self.assertEqual(self.output(self.hook(runtime, **{variable: data})), expected)


unittest.main(verbosity=2)
PY
