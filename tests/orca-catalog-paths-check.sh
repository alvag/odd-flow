#!/usr/bin/env bash
# Pin which catalog states pass, warn, or fail.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! toplevel=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) ||
    [[ "$toplevel" != "$(cd -- "$root" && pwd -P)" ]] ||
    ! git -C "$root" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
    echo "SKIP Orca catalog path checks (no git history in this checkout)"
    exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

python3 -I - "$root" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
offline_bin = scratch / "bin"
offline_bin.mkdir()
for tool in ("bash", "git", "python3"):
    (offline_bin / tool).symlink_to(shutil.which(tool))
offline_env = dict(os.environ, PATH=str(offline_bin))
orca = shutil.which("orca")
manifest_path = Path("orca-plugin/orca-plugin.json")
note = "NOTE: orca-plugin/ has changes not yet released in orca-catalog.json"
missing_commit = "0" * 40
missing_history = "catalog release commits not in this checkout's history"
failures = 0


def git(repo, *args):
    return subprocess.check_output(("git", "-C", repo, *args), text=True).strip()


def commit(repo, message):
    git(repo, "add", "--", "orca-plugin/")
    git(repo, "-c", "user.name=Catalog Test", "-c", "user.email=catalog@example.invalid",
        "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-gpg-sign", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def set_version(repo, version):
    path = repo / manifest_path
    manifest = json.loads(path.read_text(encoding="utf-8"))
    manifest["version"] = version
    path.write_text(json.dumps(manifest), encoding="utf-8")
    return commit(repo, f"Set plugin version to {version}")


def check(case, expected, message="", *, with_orca=False):
    global failures
    repo = scratch / case
    git(root, "clone", "--quiet", "--no-hardlinks", "--no-checkout", "--", root, repo)
    git(repo, "checkout", "--quiet", "--detach", git(root, "rev-parse", "HEAD"))
    catalog_path = repo / "orca-catalog.json"
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    plugin = catalog["plugins"][0]
    version = json.loads((repo / manifest_path).read_text(encoding="utf-8"))["version"]
    release = dict(plugin["releases"][0], commit=git(repo, "rev-parse", "HEAD"), version=version)
    plugin["releases"] = [release]
    if case == "unreleased":
        (repo / "orca-plugin" / "README.md").write_text("Unreleased edit\n", encoding="utf-8")
        commit(repo, "Edit the plugin without releasing")
    elif case in ("bump", "lower", "bump-and-edit"):
        older, newer = "0.9.0", "0.10.0"
        release_version, head_version = (newer, older) if case == "lower" else (older, newer)
        if version != release_version:
            release["commit"] = set_version(repo, release_version)
            release["version"] = release_version
        if case == "bump-and-edit":
            (repo / "orca-plugin" / "README.md").write_text("Edit with version bump\n", encoding="utf-8")
        set_version(repo, head_version)
    elif case in ("prerelease", "prerelease-bump", "lower-than-prerelease",
                  "numeric-prerelease", "alphanumeric-prerelease", "duplicate-precedence"):
        release_version, head_version = {
            "prerelease": ("0.3.0-beta.1", None),
            "prerelease-bump": ("0.3.0-beta.1", "0.3.0"),
            "lower-than-prerelease": ("0.3.0-beta.1", "0.3.0-alpha"),
            "numeric-prerelease": ("0.3.0-beta.9", "0.3.0-beta.10"),
            "alphanumeric-prerelease": ("0.3.0--a", "0.3.0-99"),
            "duplicate-precedence": ("0.3.0+build.01", "0.3.0+build.02"),
        }[case]
        release["commit"] = set_version(repo, release_version)
        release["version"] = release_version
        if head_version is not None:
            head_commit = set_version(repo, head_version)
            if case == "duplicate-precedence":
                plugin["releases"].insert(0, dict(release, commit=head_commit, version=head_version))
    elif case == "invalid-head-version":
        set_version(repo, "1.2")
    elif case == "invalid-release-version":
        release["version"] = "1.2"
    elif case == "leading-zero-core":
        release["version"] = "1.02.0"
    elif case == "leading-zero-prerelease":
        release["version"] = "1.2.0-alpha.01"
    elif case == "empty-version":
        release["version"] = ""
    elif case == "all-commits-missing":
        release["commit"] = missing_commit
    elif case in ("missing-commit", "shallow-missing-commit", "shallow-all-commits-present"):
        older, newer = "0.9.0", "0.10.0"
        if version != older:
            release.update(commit=set_version(repo, older), version=older)
        newest = dict(release, commit=set_version(repo, newer), version=newer)
        if case == "missing-commit":
            newest["commit"] = missing_commit
        plugin["releases"] = [newest] if case == "shallow-all-commits-present" else [newest, release]
        if case.startswith("shallow-"):
            shallow = scratch / f"{case}-clone"
            git(root, "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth=1",
                "--", repo.as_uri(), shallow)
            repo = shallow
            catalog_path = repo / "orca-catalog.json"
    elif case == "non-commit":
        release["commit"] = git(repo, "rev-parse", f"HEAD:{manifest_path}")
    elif case == "non-ancestor":
        (repo / "orca-plugin" / "README.md").write_text("Off-branch edit\n", encoding="utf-8")
        release["commit"] = commit(repo, "Edit the plugin off the release branch")
        git(repo, "checkout", "--quiet", "--detach", "HEAD^")
    elif case == "release-version-mismatch":
        release["version"] = "0.0.0" if version != "0.0.0" else "0.0.1"
    elif case == "duplicate-version":
        plugin["releases"].append(release)
    elif case == "wrong-shape":
        catalog["catalogVersion"] = 1
    elif case == "wrong-id":
        plugin["id"] = "wrong.plugin-id"
    elif case == "wrong-source":
        plugin["source"]["path"] = "."
    elif case == "wrong-hash":
        output = subprocess.check_output(
            (orca, "plugin", "release-entry", repo / "orca-plugin", "--json"), text=True
        )
        release = json.loads(output)["result"]["entry"]
        digest = release["contentHash"]
        release["contentHash"] = ("1" if digest[0] == "0" else "0") + digest[1:]
        plugin["releases"] = [release]

    catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
    result = subprocess.run(
        ("bash", root / "tests/orca-catalog-check.sh", repo),
        capture_output=True, text=True, env=None if with_orca else offline_env,
    )
    notices = [line for line in result.stdout.splitlines() if line.startswith("NOTE:")]
    skips = [line for line in result.stdout.splitlines()
             if line.startswith("SKIP Orca catalog history checks")]
    if expected == "note":
        passed = (result.returncode == 0 and len(notices) == 1 and notices[0].startswith(note)
                  and message in notices[0] and not skips and not result.stderr)
    elif expected == "fail":
        passed = (result.returncode == 1 and not notices and not skips
                  and any(line.startswith("FAIL ") and message in line
                          for line in result.stderr.splitlines()))
    elif expected == "skip":
        passed = (result.returncode == 0 and not notices and len(skips) == 1
                  and message in skips[0] and not result.stderr)
    else:
        passed = result.returncode == 0 and not notices and not skips and not result.stderr
    if passed:
        print(f"PASS {case}")
    else:
        failures += 1
        print(f"FAIL {case}: expected {expected} {message!r}; got exit {result.returncode}, "
              f"stdout={result.stdout!r}, stderr={result.stderr!r}", file=sys.stderr)


check("unreleased", "note", "docs/compatibility.md")
check("bump", "note", "docs/compatibility.md")
check("lower", "fail", "is lower than")
check("prerelease", "pass")
check("prerelease-bump", "note", "docs/compatibility.md")
check("lower-than-prerelease", "fail", "is lower than")
check("bump-and-edit", "note", "docs/compatibility.md")
check("numeric-prerelease", "note", "docs/compatibility.md")
check("alphanumeric-prerelease", "fail", "is lower than")
check("invalid-head-version", "fail", "expected a valid SemVer version")
check("invalid-release-version", "fail", "expected a valid SemVer version")
check("leading-zero-core", "fail", "expected a valid SemVer version")
check("leading-zero-prerelease", "fail", "expected a valid SemVer version")
check("empty-version", "fail", "release versions must be non-empty and unique")
check("missing-commit", "fail", missing_commit)
check("all-commits-missing", "skip", missing_history)
check("shallow-missing-commit", "skip", missing_history)
check("shallow-all-commits-present", "pass")
check("non-commit", "fail", "is not a commit")
check("non-ancestor", "fail", "is not an ancestor of HEAD")
check("release-version-mismatch", "fail", "does not match")
check("duplicate-version", "fail", "release versions must be non-empty and unique")
check("duplicate-precedence", "fail", "release versions must be non-empty and unique")
check("wrong-shape", "fail", "expected catalogVersion 2")
check("wrong-id", "fail", "plugin id must")
check("wrong-source", "fail", "expected git source")
check("clean", "pass")
if orca is None:
    print("SKIP wrong-hash (orca not on PATH)")
else:
    check("wrong-hash", "fail", "newest release differs from Orca release-entry output", with_orca=True)
sys.exit(bool(failures))
PY
