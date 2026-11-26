#!/usr/bin/env bash
# Check release versions in the plugin manifests, changelog, and compatibility table.
set -u
root=${1-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)} || exit 1

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit 1
}

result=$(python3 -I - "$root" 2>&1 <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
manifests = (
    ".claude-plugin/plugin.json",
    ".claude-plugin/marketplace.json",
    ".codex-plugin/plugin.json",
    ".antigravity-plugin/plugin.json",
)
versions = {}
for manifest in manifests:
    try:
        data = json.loads((root / manifest).read_text(encoding="utf-8"))
        if manifest.endswith("marketplace.json"):
            data = next(plugin for plugin in data["plugins"] if plugin["name"] == "odd-flow")
        version = data["version"]
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as exc:
        sys.exit(f"{manifest}: cannot read odd-flow version ({type(exc).__name__})")
    if not isinstance(version, str) or not version.strip():
        sys.exit(f"{manifest}: version must be a non-empty string")
    versions[manifest] = version

if len(set(versions.values())) != 1:
    sys.exit("plugin versions differ: " + ", ".join(
        f"{manifest}={version}" for manifest, version in versions.items()
    ))

odd_flow = next(iter(versions.values()))
heading = f"## [{odd_flow}]"
try:
    lines = (root / "CHANGELOG.md").read_text(encoding="utf-8").splitlines()
except (OSError, ValueError) as exc:
    sys.exit(f"CHANGELOG.md: cannot read release heading ({type(exc).__name__})")
if not any(line == heading or line.startswith(heading + " - ") for line in lines):
    sys.exit(f"CHANGELOG.md: missing release heading {heading}")

orca_manifest = "orca-plugin/orca-plugin.json"
try:
    orca_plugin = json.loads((root / orca_manifest).read_text(encoding="utf-8"))["version"]
except (OSError, ValueError, KeyError, TypeError) as exc:
    sys.exit(f"{orca_manifest}: cannot read ODD Flow Orca plugin version ({type(exc).__name__})")
if not isinstance(orca_plugin, str) or not orca_plugin.strip():
    sys.exit(f"{orca_manifest}: version must be a non-empty string")

compatibility = "docs/compatibility.md"
try:
    lines = (root / compatibility).read_text(encoding="utf-8").splitlines()
except (OSError, ValueError) as exc:
    sys.exit(f"{compatibility}: cannot read compatibility table ({type(exc).__name__})")
rows = [
    [cell.strip() for cell in line.strip("|").split("|")]
    for line in lines
    if line.startswith("| **Current checkout** ")
]
if len(rows) != 1 or rows[0][:2] != [f"**Current checkout** {odd_flow}", orca_plugin]:
    sys.exit(f"{compatibility}: expected one current checkout row with odd-flow {odd_flow} "
             f"and ODD Flow Orca plugin {orca_plugin}")
PY
) || fail "$result"
