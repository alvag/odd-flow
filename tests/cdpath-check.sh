#!/usr/bin/env bash
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd -- "$ROOT"

# Pass a relative script path so CDPATH can affect its root lookup.
CDPATH=".:$HOME" bash tests/continuity-check.sh
