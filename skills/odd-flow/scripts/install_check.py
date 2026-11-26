#!/usr/bin/env python3
"""Compare installed odd-flow files with the checkout holding this script."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess

SCHEMA = "odd-flow.install-check/v1"
VERSION = re.compile(r"([0-9]+)\.([0-9]+)\.([0-9]+)")
HOOKS_MIN_VERSION = (0, 4, 0)
PLUGIN_LIST_TIMEOUT_SECS = 30
MANIFEST_BY_RUNTIME = {
    "claude": ".claude-plugin/plugin.json",
    "codex": ".codex-plugin/plugin.json",
    "antigravity": ".antigravity-plugin/plugin.json",
    "orca": "orca-plugin/orca-plugin.json",
}
SHIPPED_DIRS = ("skills", "scripts", "hooks")
SHIPPED_FILES = (
    "hooks.json",
    MANIFEST_BY_RUNTIME["claude"],
    ".claude-plugin/marketplace.json",
    MANIFEST_BY_RUNTIME["codex"],
    MANIFEST_BY_RUNTIME["antigravity"],
    ".agents/plugins/marketplace.json",
)
LABELS = {
    "claude": "Claude Code",
    "codex": "Codex",
    "antigravity": "Antigravity",
    "orca": "ODD Flow Orca plugin",
}


class CheckError(Exception):
    pass


def version_parts(value):
    match = VERSION.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise CheckError("invalid plugin version")
    return tuple(map(int, match.groups()))


def directory(path):
    try:
        resolved = path.resolve(strict=True)
        if "worker-tokens" in resolved.parts:
            raise CheckError("unexpected plugin directory")
        if not stat.S_ISDIR(resolved.stat().st_mode):
            raise CheckError("plugin path is not a directory")
        return resolved
    except FileNotFoundError:
        return None


def shipped_file(root, relative):
    path = root / relative
    resolved = path.resolve(strict=True)
    if resolved != path or not stat.S_ISREG(path.stat().st_mode):
        raise CheckError("shipped path is not a regular file")
    return path


def manifest_version(root, runtime):
    try:
        data = json.loads(shipped_file(root, MANIFEST_BY_RUNTIME[runtime]).read_bytes())
        version = data["version"]
    except (OSError, ValueError, TypeError, KeyError, RuntimeError):
        raise CheckError("cannot read plugin manifest version") from None
    version_parts(version)
    return version


def raise_walk_error(error):
    raise error


def shipped_tree_files(root, *, allow_missing=False):
    files = set()
    for name in SHIPPED_DIRS:
        directory_path = root / name
        try:
            resolved = directory(directory_path)
        except CheckError:
            raise CheckError("cannot read shipped files") from None
        if resolved is None and allow_missing:
            continue
        if resolved != directory_path:
            raise CheckError("cannot read shipped directory")
        for parent, dirs, names in os.walk(directory_path, onerror=raise_walk_error):
            dirs[:] = [child for child in dirs if child != "__pycache__"]
            files.update(
                (Path(parent) / child).relative_to(root).as_posix()
                for child in names if child != ".DS_Store" and not child.endswith(".pyc")
            )
    return files


def checkout_hashes(root):
    return {
        relative: hashlib.sha256(shipped_file(root, relative).read_bytes()).digest()
        for relative in sorted(shipped_tree_files(root).union(SHIPPED_FILES))
    }


def list_plugins(cli):
    if shutil.which(cli) is None:
        return []
    try:
        result = subprocess.run(
            [cli, "plugin", "list", "--json"], capture_output=True, stdin=subprocess.DEVNULL,
            check=True, timeout=PLUGIN_LIST_TIMEOUT_SECS,
        )
        data = json.loads(result.stdout)
        if cli == "orca":
            if data["ok"] is not True:
                raise ValueError
            data = data["result"]["plugins"]
        key = "id" if cli == "claude" else "pluginKey"
        if not isinstance(data, list) or not all(isinstance(entry.get(key), str) for entry in data):
            raise ValueError
        return data
    except subprocess.TimeoutExpired as error:
        raise CheckError(f"plugin list timed out (limit: {error.timeout}s)") from None
    except (OSError, subprocess.CalledProcessError, ValueError, TypeError, KeyError, AttributeError):
        raise CheckError("cannot read plugin list") from None


def installations(runtime):
    if runtime == "claude":
        for entry in list_plugins(runtime):
            if entry["id"] == "odd-flow@odd-flow":
                if "readFromFolder" in entry:
                    path, version = entry.get("readFromFolder"), entry.get("folderVersion")
                else:
                    path, version = entry.get("installPath"), entry.get("version")
                if not isinstance(path, str) or not Path(path).is_absolute():
                    raise CheckError("invalid plugin folder in plugin list")
                version_parts(version)
                yield Path(path), version
    elif runtime == "codex":
        cache = directory(Path.home() / ".codex/plugins/cache/odd-flow/odd-flow")
        if cache is not None:
            for path in sorted(cache.iterdir()):
                if VERSION.fullmatch(path.name):
                    yield path, None
    else:
        yield Path.home() / ".gemini/config/plugins/odd-flow", None


def status(runtime, state, **details):
    return {"runtime": runtime, "status": state, **details}


def unreadable(runtime, error, fallback):
    reason = str(error) if isinstance(error, CheckError) else fallback
    return status(runtime, "unreadable", reason=reason)


def compare_install(runtime, path, version, root, hashes):
    try:
        install = directory(path)
        if install is None:
            return status(runtime, "not installed")
        installed_version = version if version is not None else manifest_version(install, runtime)
        expected_version = manifest_version(root, runtime)
        differing = shipped_tree_files(install, allow_missing=True).difference(hashes)
        for relative, expected in hashes.items():
            try:
                actual = hashlib.sha256(shipped_file(install, relative).read_bytes()).digest()
            except FileNotFoundError:
                actual = None
            if actual != expected:
                differing.add(relative)
        state = "in sync"
        if installed_version != expected_version:
            state = "version differs"
        elif differing:
            state = "files differ"
        return status(
            runtime, state, path=str(path), version=installed_version,
            expected_version=expected_version, files_differ=sorted(differing),
        )
    except (CheckError, OSError, RuntimeError) as error:
        return unreadable(runtime, error, "cannot read shipped files")


def check_orca(root):
    try:
        for entry in list_plugins("orca"):
            if entry["pluginKey"] == "local.odd-flow-profiles":
                version, plugin_status = entry.get("version"), entry.get("status")
                version_parts(version)
                if not isinstance(plugin_status, str) or not re.fullmatch(r"[a-z-]+", plugin_status):
                    raise CheckError("invalid Orca plugin status")
                expected = manifest_version(root, "orca")
                state = "in sync" if version == expected else "version differs"
                row = status("orca", state, version=version, expected_version=expected,
                             plugin_status=plugin_status)
                error = entry.get("error")
                if plugin_status != "running" and isinstance(error, str):
                    error = re.sub(r"[\s\x00-\x1f\x7f-\x9f]+", " ", error).strip()
                    if error:
                        row["plugin_error"] = error
                return row
        return status("orca", "not installed")
    except CheckError as error:
        return unreadable("orca", error, "cannot read Orca plugin state")


def check(root):
    report = {"schema": SCHEMA, "installs": [], "warnings": []}
    rows = report["installs"]
    try:
        hashes = checkout_hashes(root)
    except (CheckError, OSError, RuntimeError):
        hashes = None

    for runtime in ("claude", "codex", "antigravity"):
        start = len(rows)
        try:
            for path, version in installations(runtime):
                if hashes is None:
                    rows.append(status(runtime, "unreadable", reason="cannot read checkout files"))
                else:
                    rows.append(compare_install(runtime, path, version, root, hashes))
        except (CheckError, OSError, RuntimeError) as error:
            rows.append(unreadable(runtime, error, "cannot read plugin directory"))
        if start == len(rows):
            rows.append(status(runtime, "not installed"))

    orca = check_orca(root)
    rows.append(orca)
    if "version" in orca:
        for row in rows[:-1]:
            if "version" in row and version_parts(row["version"]) < HOOKS_MIN_VERSION:
                report["warnings"].append(
                    f'{LABELS[row["runtime"]]} {row["version"]}: '
                    "the Orca tokened marker requires odd-flow hooks 0.4.0 or newer."
                )
    if hashes is None:
        report["reason"] = "cannot read checkout files"
    return report


def print_report(report):
    for row in report["installs"]:
        label = LABELS[row["runtime"]]
        line = f'{label}: {row["status"]}'
        if "reason" in row:
            line += f' ({row["reason"]})'
        if "path" in row:
            line += f' [{row["path"]}]'
        if "version" in row:
            line += f' (version {row["version"]}'
            if row["version"] != row["expected_version"]:
                line += f'; checkout {row["expected_version"]}'
            if "plugin_status" in row:
                line += f'; Orca status: {row["plugin_status"]}'
            if "plugin_error" in row:
                line += f'; {row["plugin_error"]}'
            line += ")"
        if row.get("files_differ"):
            prefix = ": " if row["status"] == "files differ" else ": files differ: "
            line += prefix + ", ".join(row["files_differ"])
        print(line)
    if "reason" in report:
        print(f'Checkout: unreadable ({report["reason"]})')
    for warning in report["warnings"]:
        print(f"Warning: {warning}")
    print("Compared: files under skills/, scripts/, and hooks/ in both trees, hooks.json, "
          "and runtime manifests. Other files (including .git, untracked extras outside "
          "shipped paths, Python bytecode, and .DS_Store) are ignored. "
          "Orca reports its listed version, state, and any error for a non-running plugin.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--json", action="store_true", help="print one JSON report")
    args = parser.parse_args()

    report = check(Path(__file__).resolve().parents[3])
    if args.json:
        print(json.dumps(report))
    else:
        print_report(report)
    states = {row["status"] for row in report["installs"]}
    if "unreadable" in states or "reason" in report:
        return 3
    return int(bool({"version differs", "files differ"} & states))


if __name__ == "__main__":
    raise SystemExit(main())
