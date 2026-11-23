#!/bin/sh
# Start a Codex agent in an Orca terminal so it can act as a supervised worker.
#
# Usage: sh codex-worker.sh [model [effort]]
#
# `orca orchestration worker-start --agent codex` starts Codex inside its default
# workspace-write sandbox, which blocks the connection to Orca: the worker cannot send
# worker_done. This reproduces the argv Orca uses for Codex workers and adds one override,
# outbound network for the sandbox, which also lets the worker reach Orca. It never
# changes the user's Codex config.
#
# Run it as the command of `orca terminal create`; the Orca terminal provides the
# variables below. Codex filters variables named like keys or tokens out of its tool
# shells, so each one is forwarded explicitly, as Orca does.

if [ "$#" -gt 2 ]; then
  echo "codex-worker.sh: usage: codex-worker.sh [model [effort]]" >&2
  exit 2
fi
for arg in "$@"; do
  case "$arg" in
    "")
      echo "codex-worker.sh: model and effort must not be empty; omit them instead" >&2
      exit 2
      ;;
    -*)
      echo "codex-worker.sh: model and effort must not start with '-' ($arg)" >&2
      exit 2
      ;;
  esac
done
model=${1-}
effort=${2-}

set --
for name in ORCA_USER_DATA_PATH ORCA_WORKSPACE_ID ORCA_WORKTREE_ID ORCA_PANE_KEY ORCA_TERMINAL_HANDLE; do
  eval "value=\${$name-}"
  if [ -z "$value" ]; then
    echo "codex-worker.sh: $name is not set; run this as the command of 'orca terminal create'" >&2
    exit 2
  fi
  case "$value" in
    *"'"*)
      echo "codex-worker.sh: $name contains a single quote and cannot be forwarded as a TOML literal" >&2
      exit 2
      ;;
  esac
  set -- "$@" -c "shell_environment_policy.set.$name='$value'"
done

set -- "$@" -c check_for_update_on_startup=false -c disable_paste_burst=true
if [ -n "$model" ]; then
  set -- "$@" -m "$model"
  if [ -n "$effort" ]; then
    set -- "$@" -c "model_reasoning_effort=$effort"
  fi
fi
set -- "$@" -c sandbox_workspace_write.network_access=true

exec codex --no-daemon "$@"
