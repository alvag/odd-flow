#!/usr/bin/env bash
# Check the Orca catalog against the committed plugin and its release history.
set -u
root=${1-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)} || exit 1

python3 -I - "$root" <<'PY'
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


def fail(message):
    print(f"FAIL {message}", file=sys.stderr)
    sys.exit(1)


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        fail(f"{' '.join(str(arg) for arg in args)} (exit {result.returncode}): {detail}")
    return result.stdout


def git(*args):
    return run("git", "-C", root, *args)


def object_from_json(data, label):
    try:
        value = json.loads(data)
    except ValueError as exc:
        fail(f"{label}: invalid JSON ({exc})")
    if not isinstance(value, dict):
        fail(f"{label}: expected a JSON object")
    return value


def version_key(value, label):
    number = r"0|[1-9][0-9]*"
    identifiers = r"[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*"
    pattern = rf"({number})\.({number})\.({number})(?:-({identifiers}))?(?:\+{identifiers})?"
    match = re.fullmatch(pattern, value) if isinstance(value, str) else None
    if match is None:
        fail(f"{label}: expected a valid SemVer version")
    major, minor, patch, prerelease = match.groups()
    identifiers_key = []
    if prerelease is not None:
        for identifier in prerelease.split("."):
            if identifier.isdecimal():
                if len(identifier) > 1 and identifier.startswith("0"):
                    fail(f"{label}: expected a valid SemVer version (numeric prerelease has a leading zero)")
                identifiers_key.append((0, len(identifier), identifier))
            else:
                identifiers_key.append((1, 0, identifier))
    # Length, then lexical order, compares digit strings without converting them to integers.
    core = tuple((len(part), part) for part in (major, minor, patch))
    return core, prerelease is None, tuple(identifiers_key)


def orca_result(*args):
    response = object_from_json(run(orca, "plugin", *args, "--json"), f"orca plugin {args[0]}")
    if response.get("ok") is not True or not isinstance(response.get("result"), dict):
        fail(f"orca plugin {args[0]}: expected a successful result")
    return response["result"]


root = Path(sys.argv[1]).resolve()
catalog_path = root / "orca-catalog.json"
orca = shutil.which("orca")
if orca is None:
    print("SKIP Orca catalog validation and release-entry comparison (orca not on PATH)", flush=True)

try:
    catalog_text = catalog_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as exc:
    fail(f"orca-catalog.json: cannot read catalog ({exc})")
catalog = object_from_json(catalog_text, "orca-catalog.json")
if catalog.get("catalogVersion") != 2:
    fail("orca-catalog.json: expected catalogVersion 2")

plugins = catalog.get("plugins")
if not isinstance(plugins, list) or len(plugins) != 1 or not isinstance(plugins[0], dict):
    fail("orca-catalog.json: expected exactly one plugin entry")
plugin = plugins[0]
url = "https://github.com/alvag/odd-flow.git"
source = plugin.get("source")
if not isinstance(source, dict) or (
    source.get("kind"), source.get("url"), source.get("ref"), source.get("path")
) != ("git", url, "main", "orca-plugin"):
    fail(f"orca-catalog.json: expected git source {url}, ref main, path orca-plugin")

manifest = "orca-plugin/orca-plugin.json"
head = object_from_json(git("show", f"HEAD:{manifest}"), f"HEAD:{manifest}")
owner = urlsplit(source["url"]).path.split("/")[1].lower()
plugin_id = head.get("id")
if not isinstance(plugin_id, str) or not plugin_id or plugin.get("id") != f"{owner}.{plugin_id}":
    fail("orca-catalog.json: plugin id must be the source owner and HEAD manifest id")

releases = plugin.get("releases")
if not isinstance(releases, list) or not releases:
    fail("orca-catalog.json: expected at least one release")

seen = set()
for release in releases:
    if not isinstance(release, dict):
        fail("orca-catalog.json: expected a release object")
    version = release.get("version")
    if version is None or version == "":
        fail("orca-catalog.json: release versions must be non-empty and unique")
    key = version_key(version, "orca-catalog.json release")
    if key in seen:
        fail("orca-catalog.json: release versions must be non-empty and unique")
    seen.add(key)
    commit = release.get("commit")
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        fail(f"release {version}: expected a full lowercase SHA-1 commit")
    if git("cat-file", "-t", commit).strip() != "commit":
        fail(f"release {version}: {commit} is not a commit")
    if subprocess.run(
        ("git", "-C", root, "merge-base", "--is-ancestor", commit, "HEAD"), capture_output=True
    ).returncode:
        fail(f"release {version}: {commit} is not an ancestor of HEAD")
    data = object_from_json(git("show", f"{commit}:{manifest}"), f"{commit}:{manifest}")
    if data.get("version") != version:
        fail(f"release {version}: version in {commit}:{manifest} does not match")

newest = releases[0]
head_version = version_key(head.get("version"), f"HEAD:{manifest}")
newest_version = version_key(newest["version"], "orca-catalog.json newest release")
if head_version < newest_version:
    fail(f"HEAD:{manifest}: version {head['version']} is lower than newest release {newest['version']}")

unreleased = head_version > newest_version or git(
    "rev-parse", f'{newest["commit"]}:orca-plugin'
) != git("rev-parse", "HEAD:orca-plugin")

if orca is not None:
    if orca_result("validate", catalog_path).get("valid") is not True:
        fail("orca-catalog.json: Orca did not report a valid catalog")
    with tempfile.TemporaryDirectory() as temp:
        clone = Path(temp) / "release"
        run("git", "clone", "--quiet", "--no-checkout", root, clone)
        run("git", "-C", clone, "checkout", "--quiet", "--detach", newest["commit"])
        if orca_result("release-entry", clone / "orca-plugin").get("entry") != newest:
            fail("orca-catalog.json: newest release differs from Orca release-entry output")

if unreleased:
    print("NOTE: orca-plugin/ has changes not yet released in orca-catalog.json. "
          "See Publishing an ODD Flow Orca plugin release in docs/compatibility.md.")
PY
