#!/usr/bin/env python3
"""Validate the edit surface declared in a bounded writer spec."""

import argparse
import glob
import ntpath
from pathlib import Path
import re

ROLE = "# Role: write"
HEADING = "## Allowed edit surfaces"
ATX_HEADING = re.compile(r"^ {0,3}#{1,6}(?:[ \t]|$)")
SETEXT_UNDERLINE = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
FENCE = re.compile(r"^ {0,3}(~{3,}|`{3,})(.*)$")
LIST_OR_QUOTE = re.compile(r"^(?:[-*+>]|\d+[.)])[ \t]+")


class SurfaceError(ValueError):
    """A spec file or declaration could not be validated."""


def is_writer(spec):
    return next(
        (line.strip().casefold() for line in spec.lstrip("\ufeff").splitlines() if line.strip()), ""
    ) == ROLE.casefold()


def read_spec(path):
    try:
        path = Path(path)
        if not path.is_file():
            raise OSError("not a readable regular file")
        return path.read_text(encoding="utf-8")
    except (OSError, ValueError) as exc:
        raise SurfaceError(f"cannot read spec file {str(path)!r}: {exc}") from exc


def validate_entry(entry):
    parts = [part for part in re.split(r"[/\\]", entry) if part not in {"", "."}]
    if not entry:
        rule = "entry is empty"
    elif not parts and not entry.startswith("\\"):
        rule = "the repository root is not an edit surface"
    elif entry.startswith(("/", "\\")) or ntpath.splitdrive(entry)[0]:
        rule = "an absolute path or drive-qualified path is not repo-relative"
    elif entry.startswith("~") or parts[0].startswith("~"):
        rule = "a home-relative path is not repo-relative"
    elif ".." in parts:
        rule = "a parent segment ('..') is not permitted"
    elif glob.has_magic(parts[0]):
        rule = "a wildcard is not permitted in the first path segment"
    elif re.search(r"<[^<>]*>", entry):
        rule = "replace the unfilled template placeholder"
    elif any(char in entry for char in "`${},"):
        rule = "backticks, dollar signs, braces and commas are not permitted in a path entry"
    elif LIST_OR_QUOTE.match(entry):
        rule = "a list or quote marker is not permitted in a path entry"
    else:
        return
    raise SurfaceError(f"{entry!r}: {rule}")


def outside_fences(spec):
    fence = None
    for line in spec.splitlines():
        match = FENCE.match(line)
        if fence:
            if match and match[1].startswith(fence) and not match[2].strip():
                fence = None
        elif match and (match[1][0] == "~" or "`" not in match[2]):
            fence = match[1]
        else:
            yield line
            continue
        # Keep a boundary so lines across a fence cannot form a setext heading.
        yield ""


def check(spec):
    """Return normalized entries from all exact surface sections, or raise SurfaceError."""
    lines = list(outside_fences(spec))
    entries = []
    section_start = None
    for i, line in enumerate(lines):
        if line == HEADING or ATX_HEADING.match(line) or (
            line.strip() and i + 1 < len(lines) and SETEXT_UNDERLINE.fullmatch(lines[i + 1])
        ):
            if section_start == len(entries):
                raise SurfaceError(f"{HEADING} is empty; list at least one repo-relative path or narrow glob")
            section_start = len(entries) if line == HEADING else None
            continue
        if section_start is None or not line.strip():
            continue
        entry = re.sub(r"^[-*][ \t]+", "", line.lstrip()).strip()
        if entry.startswith("`") and entry.endswith("`"):
            entry = entry[1:-1].strip()
        validate_entry(entry)
        entries.append(entry)
    if section_start == len(entries):
        raise SurfaceError(f"{HEADING} is empty; list at least one repo-relative path or narrow glob")
    if not entries:
        raise SurfaceError(f"missing {HEADING}; add one repo-relative path or narrow glob per line")
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check"])
    parser.add_argument("spec_file")
    args = parser.parse_args()
    try:
        print("\n".join(check(read_spec(args.spec_file))))
    except SurfaceError as exc:
        parser.exit(2, f"odd-flow: {exc}\n")


if __name__ == "__main__":
    main()
