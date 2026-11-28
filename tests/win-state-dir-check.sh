#!/usr/bin/env bash
# Windows session-state scanning, pruning and SessionStart cleanup, against isolated state.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
python3 -I -B - "$root" "$scratch" <<'PY'
import os
import sys

if os.name != "nt":
    print("SKIP Windows session-state checks (not running on Windows)")
    sys.exit(0)

from contextlib import contextmanager
import ctypes
from ctypes import wintypes
import hashlib
import importlib.util
import json
import msvcrt
from pathlib import Path
import runpy
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

root, scratch = map(Path, sys.argv[1:])
scratch = scratch.resolve()
sys.argv[1:] = []
day = 86400
stamp_name = "session-cleanup.stamp"
profile_script = root / "skills/odd-flow/scripts/profile.py"
install_script = root / "skills/odd-flow/scripts/install_check.py"
hook_script = root / "scripts/session-start.py"
buckets = ("prompt-sessions", "session-modes")


def key(name):
    return hashlib.sha256(name.encode("ascii")).hexdigest()


def set_age(path, days):
    then = time.time() - days * day
    os.utime(path, (then, then))


def record(path, age=31):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"{}\n")
    set_age(path, age)
    return path


def junction(link, target):
    link.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)],
                   check=True, capture_output=True)


@contextmanager
def held(path, access, share):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    ]
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel32.CreateFileW(str(path), access, share, None, 3, 0x02000000, None)
    assert handle != ctypes.c_void_p(-1).value, ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        kernel32.CloseHandle(handle)


GENERIC_READ, DELETE = 0x80000000, 0x00010000


class WinStateDirCheck(unittest.TestCase):
    def setUp(self):
        # Short names keep the deepest record path under MAX_PATH when TMPDIR is long.
        self.state = Path(tempfile.mkdtemp(prefix="t", dir=scratch))
        self.home = self.state / "home"
        self.odd = self.state / "odd-flow"
        self.bindings = self.odd / "sessions"
        self.claude = self.state / "claude"
        self.codex = self.state / "codex"
        self.data = self.claude / "plugins/data/odd-flow-market"
        self.agy = self.home / ".gemini/antigravity-cli/plugin_data/odd-flow"
        self.outside = self.state / "outside"
        empty = self.state / "empty-bin"
        for folder in (self.home, empty, self.outside):
            folder.mkdir(parents=True)
        self.env = {
            "PATH": str(empty),
            "SystemRoot": os.environ["SystemRoot"],
            "HOME": str(self.home),
            "USERPROFILE": str(self.home),
            "ODD_FLOW_HOME": str(self.odd),
            "CLAUDE_CONFIG_DIR": str(self.claude),
            "CODEX_HOME": str(self.codex),
            "ODD_FLOW_STATE_DIR": str(self.state / "token-state"),
            "TEMP": str(self.state),
            "TMP": str(self.state),
        }

    def run_script(self, script, *args, stdin=b"", **env):
        return subprocess.run([sys.executable, "-I", "-B", "-X", "utf8", str(script), *args], input=stdin,
                              env=dict(self.env, **env), capture_output=True)

    def prune(self, expected_code=0):
        result = self.run_script(profile_script, "prune", "--days", "30")
        self.assertEqual(result.returncode, expected_code, result)
        if expected_code == 0:
            self.assertEqual(result.stderr, b"", result)
        return result.stdout.decode().splitlines(), result.stderr.decode()

    def counts(self):
        result = self.run_script(install_script, "--json")
        return json.loads(result.stdout)["session_state"]

    def hook(self, data):
        result = self.run_script(
            hook_script, stdin=json.dumps({"session_id": "current", "source": "startup"}).encode(),
            CLAUDE_PLUGIN_DATA=str(data))
        self.assertEqual((result.returncode, result.stderr), (0, b""), result)

    def cleanup(self, data):
        cleanup = runpy.run_path(str(hook_script))["cleanup_session_state"]
        with patch.dict(os.environ, self.env, clear=True):
            cleanup(str(data))

    def module(self):
        spec = importlib.util.spec_from_file_location("odd_profile", profile_script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def seed(self):
        old = [record(self.bindings / "old.json")]
        new = [record(self.bindings / "new.json", 0.5)]
        for data in (self.data, self.agy):
            for bucket in buckets:
                old.append(record(data / bucket / key("old")))
                new.append(record(data / bucket / key("new"), 0.5))
                new.append(record(data / bucket / "notes"))
        return old, new

    def assert_present(self, paths):
        for path in paths:
            self.assertTrue(path.is_file(), path)

    def assert_gone(self, paths):
        for path in paths:
            self.assertFalse(path.exists(), path)

    def test_install_check_counts_and_prune_removes_old_records(self):
        old, new = self.seed()
        self.assertEqual(self.counts(),
                         {"session_bindings": 2, "prompt_sessions": 4, "session_modes": 4})
        lines, _ = self.prune()
        self.assertEqual(lines, [
            "removed 1 session binding(s) older than 30 days",
            "removed 2 prompt-hook record(s) older than 30 days",
            "removed 2 mode-notice record(s) older than 30 days",
        ])
        self.assert_gone(old)
        self.assert_present(new)

    def test_session_start_cleanup_runs_once_a_day_under_the_stamp_lock(self):
        old, new = self.seed()
        owned = [path for path in old if self.agy not in path.parents]
        foreign = [path for path in old if self.agy in path.parents]
        self.hook(self.data)
        stamp = self.data / stamp_name
        self.assertEqual(stamp.read_bytes(), b"\n")
        self.assert_gone(owned)
        self.assert_present(new + foreign)

        later = record(self.data / "prompt-sessions" / key("later"))
        self.hook(self.data)
        self.assert_present([later])

        set_age(stamp, 2)
        before = stamp.stat().st_mtime_ns
        with stamp.open("r+b") as holder:
            msvcrt.locking(holder.fileno(), msvcrt.LK_NBLCK, 1)
            try:
                self.cleanup(self.data)
                self.assert_present([later])
            finally:
                holder.seek(0)
                msvcrt.locking(holder.fileno(), msvcrt.LK_UNLCK, 1)
        self.assertEqual(stamp.stat().st_mtime_ns, before)

        self.hook(self.data)
        self.assert_gone([later])
        self.assertGreater(stamp.stat().st_mtime_ns, before)

    def test_exhausted_budget_leaves_the_stamp_stale(self):
        expired = [record(self.data / "prompt-sessions" / key(name)) for name in ("first", "second")]
        stamp = record(self.data / stamp_name, 2)
        before = stamp.stat().st_mtime_ns

        def clock():
            return 100.0 if all(path.exists() for path in expired) else 101.0

        with patch.object(time, "monotonic", clock):
            self.cleanup(self.data)
        self.assertEqual(sum(path.exists() for path in expired), 1)
        self.assertEqual(stamp.stat().st_mtime_ns, before)

    def test_hard_linked_stamp_stops_cleanup(self):
        expired = record(self.data / "prompt-sessions" / key("old"))
        target = record(self.outside / "target", 2)
        os.link(target, self.data / stamp_name)
        before = target.stat().st_mtime_ns
        self.cleanup(self.data)
        self.assert_present([expired])
        self.assertEqual(target.stat().st_mtime_ns, before)

    def test_junction_state_directories_are_not_followed(self):
        outside = [record(self.outside / "bindings" / "old.json")]
        outside += [record(self.outside / name / bucket / key("old"))
                    for name in ("root", "buckets") for bucket in buckets]
        junction(self.bindings, self.outside / "bindings")
        junction(self.claude / "plugins/data/odd-flow-junction", self.outside / "root")
        for bucket in buckets:
            junction(self.agy / bucket, self.outside / "buckets" / bucket)
        self.assertEqual(self.counts(),
                         {"session_bindings": 0, "prompt_sessions": 0, "session_modes": 0})
        lines, _ = self.prune()
        self.assertEqual(lines, [
            "no session bindings",
            "removed 0 prompt-hook record(s) older than 30 days",
            "removed 0 mode-notice record(s) older than 30 days",
        ])
        self.cleanup(self.agy)
        self.assert_present(outside)

    def test_session_start_skips_a_junction_data_directory(self):
        outside = [record(self.outside / bucket / key("old")) for bucket in buckets]
        binding = record(self.bindings / "old.json")
        linked = self.state / "linked-data"
        junction(linked, self.outside)
        self.cleanup(linked)
        self.assertFalse((self.outside / stamp_name).exists())
        self.assert_present(outside + [binding])

    def test_symlinks_are_neither_scanned_nor_removed(self):
        target = record(self.outside / "old.json")
        bucket_target = record(self.outside / "bucket" / key("old"))
        link = self.bindings / "link.json"
        bucket_link = self.data / "prompt-sessions"
        link.parent.mkdir(parents=True)
        self.data.mkdir(parents=True)
        try:
            os.symlink(target, link)
            os.symlink(bucket_target.parent, bucket_link, target_is_directory=True)
        except OSError as exc:
            if exc.winerror != 1314:
                raise
            print("SKIP symlink checks (creating symlinks needs Developer Mode or elevation)")
            self.skipTest("symlinks are not permitted")
        self.assertEqual(self.counts(),
                         {"session_bindings": 0, "prompt_sessions": 0, "session_modes": 0})
        self.prune()
        self.assertTrue(link.is_symlink() and bucket_link.is_symlink())
        self.assert_present([target, bucket_target])

    def test_pinned_state_directories_cannot_be_renamed_or_removed(self):
        folder = self.data / "prompt-sessions"
        folder.mkdir(parents=True)
        module = self.module()
        with module._open_state_dir(self.data.parent, self.data.name, folder.name) as pinned:
            self.assertIsNotNone(pinned)
            for pinned_path in (folder, self.data, self.data.parent):
                with self.assertRaises(OSError):
                    os.rename(pinned_path, pinned_path.with_name("moved"))
            with self.assertRaises(OSError):
                os.rmdir(folder)
        os.rename(folder, folder.with_name("moved"))

    def test_pinned_base_directory_cannot_be_renamed_or_removed(self):
        folder = self.state / "root"
        folder.mkdir()
        module = self.module()
        with module._open_state_dir(folder) as pinned:
            self.assertIsNotNone(pinned)
            with self.assertRaises(OSError):
                os.rename(folder, folder.with_name("moved"))
            with self.assertRaises(OSError):
                os.rmdir(folder)
        os.rmdir(folder)

    def test_held_state_directory_is_skipped_with_an_error(self):
        for name, access, share in (("exclusive", GENERIC_READ, 0), ("delete-access", DELETE, 7)):
            with self.subTest(name):
                locked = record(self.bindings / f"{name}.json")
                other = record(self.data / "prompt-sessions" / key(name))
                with held(self.bindings, access, share):
                    lines, errors = self.prune(2)
                self.assertIn(f"{self.bindings}: cannot read session bindings:", errors)
                self.assertEqual(lines[0], "removed 0 session binding(s) older than 30 days")
                self.assert_present([locked])
                self.assert_gone([other])
                locked.unlink()

    def test_held_state_file_is_skipped_with_an_error(self):
        locked = record(self.bindings / "locked.json")
        other = record(self.bindings / "other.json")
        with held(locked, GENERIC_READ, 0):
            lines, errors = self.prune(2)
        self.assertIn(f"{locked}: cannot remove session binding:", errors)
        self.assertEqual(lines[0], "removed 1 session binding(s) older than 30 days")
        self.assert_present([locked])
        self.assert_gone([other])

    def test_replaced_file_is_not_deleted(self):
        target = record(self.bindings / "old.json")
        replacement = record(self.outside / "replacement")
        module = self.module()
        remove = module.remove_session_file
        deletions = []
        load = ctypes.WinDLL

        def recording_dll(*args, **kwargs):
            library = load(*args, **kwargs)
            real = library.SetFileInformationByHandle

            class Recorder:
                def __call__(self, *call):
                    deletions.append(call)
                    return real(*call)

            library.SetFileInformationByHandle = Recorder()
            return library

        def replace_then_remove(path, **kwargs):
            os.replace(replacement, path)
            return remove(path, **kwargs)

        errors = []
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(module, "remove_session_file", replace_then_remove), \
                patch.object(ctypes, "WinDLL", recording_dll), \
                patch.object(os, "unlink") as unlink:
            counts = module.prune_session_state([], time.time() - 30 * day, errors=errors)
        self.assertEqual(counts["session_bindings"], 0)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("changed since it was scanned", str(errors[0]))
        self.assertEqual((deletions, unlink.call_count), ([], 0))
        self.assert_present([target])

    def test_missing_win32_symbol_fails_closed(self):
        old, new = self.seed()
        runner = self.state / "missing-symbol.py"
        runner.write_text("""
import ctypes
import runpy
import sys

load = ctypes.WinDLL


class Partial:
    def __init__(self, library):
        self.library = library

    def __getattr__(self, name):
        if name == "SetFileInformationByHandle":
            raise AttributeError("function 'SetFileInformationByHandle' not found")
        return getattr(self.library, name)


ctypes.WinDLL = lambda *args, **kwargs: Partial(load(*args, **kwargs))
script = sys.argv[1]
sys.argv = [script, "prune"]
runpy.run_path(script, run_name="__main__")
""", encoding="utf-8")
        result = self.run_script(runner, str(profile_script))
        self.assertEqual((result.returncode, result.stdout), (2, b""), result)
        self.assertIn(b"requires Windows Win32 handle support", result.stderr)
        self.assert_present(old + new)

    def test_non_directory_state_path_fails(self):
        self.odd.mkdir()
        self.bindings.write_bytes(b"")
        lines, errors = self.prune(2)
        self.assertEqual(lines[0], "removed 0 session binding(s) older than 30 days")
        self.assertEqual(errors.splitlines(), [
            f"odd-flow: {self.bindings}: cannot read session bindings: "
            f"[Errno 20] Not a directory: {str(self.bindings)!r}",
        ])


unittest.main(verbosity=2)
PY
