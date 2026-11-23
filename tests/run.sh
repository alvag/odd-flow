#!/usr/bin/env bash

suite_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
shopt -s nullglob

passed=0
failed=0
for suite in "$suite_dir"/*-check.sh; do
    if bash "$suite"; then
        printf 'PASS %s (exit 0)\n' "${suite##*/}"
        passed=$((passed + 1))
    else
        code=$?
        printf 'FAIL %s (exit %s)\n' "${suite##*/}" "$code"
        failed=$((failed + 1))
    fi
done

printf 'Summary: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
