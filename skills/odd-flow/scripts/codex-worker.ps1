# Start a Codex agent in an Orca terminal so it can act as a supervised worker.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File codex-worker.ps1 [model [effort]]
#
# The PowerShell twin of codex-worker.sh, for Orca terminals on Windows, which run
# PowerShell instead of sh. Commands still use the workspace-write sandbox, but it
# cannot reach Orca's named pipe on Windows. Codex rejects combining the flags, so
# --approve-for-me replaces --sandbox workspace-write and routes escalations to
# automatic review. Outbound network stays enabled so the worker can reach Orca.
# It never changes the user's Codex config.
#
# Unlike codex-worker.sh, it refuses a double quote, a backslash or whitespace in the
# model or effort, and a double quote in an Orca variable: Windows rebuilds a command
# line for Codex, and Windows PowerShell 5.1 neither escapes an embedded '"' nor keeps
# a trailing '\' from escaping the closing quote, so such a value could add Codex
# flags or swallow the ones after it.
#
# Run it as the command of `orca terminal create`; the Orca terminal provides the
# variables below. Codex filters variables named like keys or tokens out of its tool
# shells, so each one is forwarded explicitly, as Orca does.

function Stop-Launch([string]$Message, [int]$Code) {
    [Console]::Error.WriteLine("codex-worker.ps1: $Message")
    exit $Code
}

if ($args.Count -gt 2) {
    Stop-Launch 'usage: codex-worker.ps1 [model [effort]]' 2
}
foreach ($arg in $args) {
    $arg = [string]$arg
    if ($arg -eq '') {
        Stop-Launch 'model and effort must not be empty; omit them instead' 2
    }
    if ($arg.StartsWith('-')) {
        Stop-Launch "model and effort must not start with '-' ($arg)" 2
    }
    if ($arg -match '["\\\s]') {
        Stop-Launch "model and effort must not contain a double quote, a backslash or whitespace ($arg)" 2
    }
}
$model = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$effort = if ($args.Count -ge 2) { [string]$args[1] } else { '' }

$codexArgs = New-Object System.Collections.Generic.List[string]
foreach ($name in 'ORCA_USER_DATA_PATH', 'ORCA_WORKSPACE_ID', 'ORCA_WORKTREE_ID', 'ORCA_PANE_KEY', 'ORCA_TERMINAL_HANDLE') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrEmpty($value)) {
        Stop-Launch "$name is not set; run this as the command of 'orca terminal create'" 2
    }
    if ($value.Contains("'")) {
        Stop-Launch "$name contains a single quote and cannot be forwarded as a TOML literal" 2
    }
    if ($value.Contains('"')) {
        Stop-Launch "$name contains a double quote and cannot be passed to Codex intact on Windows" 2
    }
    $codexArgs.AddRange([string[]]@('-c', "shell_environment_policy.set.$name='$value'"))
}

$codexArgs.AddRange([string[]]@('-c', 'check_for_update_on_startup=false', '-c', 'disable_paste_burst=true'))
if ($model -ne '') {
    $codexArgs.AddRange([string[]]@('-m', $model))
    if ($effort -ne '') {
        $codexArgs.AddRange([string[]]@('-c', "model_reasoning_effort=$effort"))
    }
}
$codexArgs.AddRange([string[]]@('-c', 'sandbox_workspace_write.network_access=true'))
$codexArgs.AddRange([string[]]@('-c', 'plugins.engram@engram.enabled=false'))

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    Stop-Launch 'codex: not found' 127
}

& codex mcp get engram *> $null
if ($LASTEXITCODE -eq 0) {
    $codexArgs.AddRange([string[]]@('-c', 'mcp_servers.engram.enabled=false'))
}

& codex --no-daemon --approve-for-me @codexArgs
exit $LASTEXITCODE
