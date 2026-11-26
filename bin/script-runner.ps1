#!/usr/bin/env sh
# =============================================================================
# Cross-Platform Polyglot Script Runner (POSIX sh / Bash & PowerShell)
# =============================================================================
# Runs in BOTH POSIX sh/bash and PowerShell (pwsh / powershell.exe), and can
# execute either the .sh or .ps1 version of any script in this plugin.
#
# How the polyglot header works (per cross-platform-command-format-for-sh-and-pwsh.md):
# 1. `sv --% 2>/dev/null ; : '`
#    - In PowerShell: `sv` (Set-Variable) sees `--%` (stop-parsing token) and
#      silently sets variable `--%` (no stdout/stderr); PowerShell then executes
#      the subsequent lines up to `exit $code`.
#    - In POSIX sh (dash/bash/ash): `sv` is not a POSIX special built-in (unlike
#      `set`, which aborts dash with exit code 2 on `--%`), so `sv --% 2>/dev/null`
#      silently fails and `; : '...'` runs a no-op single-quoted literal covering
#      the entire PowerShell section while preserving `$@`.
# 2. `' >/dev/null ; : ' <# '`
#    - In PowerShell: opens a `<# ... #>` block comment hiding all POSIX sh syntax.
#    - In POSIX sh/bash: closes the first `: '...'` and opens a second `: '...'`
#      that consumes `<# `, allowing the POSIX sh section to run cleanly.
# =============================================================================
sv --% 2>/dev/null ; : '
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RunnerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $RunnerDir "..")).Path }
$env:PLUGIN_ROOT = $PluginRoot

function Resolve-TargetScripts {
    param([string]$TargetName)
    if ([string]::IsNullOrWhiteSpace($TargetName)) {
        $TargetName = "shebang-mcp-sdk"
    }
    $stripped = $TargetName -replace "\.(ps1|sh)$", ""
    $candidates = @(
        [System.IO.Path]::Combine($PluginRoot, "bin", $stripped),
        [System.IO.Path]::Combine($PluginRoot, "scripts", $stripped),
        [System.IO.Path]::Combine($PluginRoot, ".agents", "skills", "shebang-mcp-builder", "scripts", $stripped),
        [System.IO.Path]::Combine($PluginRoot, "skills", "shebang-mcp-builder", "scripts", $stripped),
        [System.IO.Path]::Combine($PluginRoot, "io.github.sheldonrobinson.shebang-mcp-builder", "hooks", $stripped),
        [System.IO.Path]::Combine((Get-Location).Path, $stripped)
    )
    if ([System.IO.Path]::IsPathRooted($stripped)) {
        $candidates = @($stripped) + $candidates
    }
    foreach ($base in $candidates) {
        $psPath = "$base.ps1"
        $shPath = "$base.sh"
        if ((Test-Path -LiteralPath $psPath) -or (Test-Path -LiteralPath $shPath)) {
            return [PSCustomObject]@{
                Base   = $base
                PsPath = if (Test-Path -LiteralPath $psPath) { (Resolve-Path -LiteralPath $psPath).Path } else { $null }
                ShPath = if (Test-Path -LiteralPath $shPath) { (Resolve-Path -LiteralPath $shPath).Path } else { $null }
            }
        }
    }
    return $null
}

$ForcedShell = ""
$TargetScript = ""
$ForwardArgs = New-Object System.Collections.Generic.List[string]

$idx = 0
while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    if ($ForwardArgs.Count -eq 0 -and [string]::IsNullOrEmpty($TargetScript)) {
        if ($arg -in @("--use-sh", "--sh", "--bash")) {
            $ForcedShell = "sh"
            $idx++
            continue
        }
        if ($arg -in @("--use-pwsh", "--pwsh", "--ps1", "--powershell")) {
            $ForcedShell = "pwsh"
            $idx++
            continue
        }
        if ($arg -eq "--runner-help") {
            Write-Output @"
Cross-Platform Polyglot Script Runner (POSIX sh / Bash & PowerShell)

USAGE:
  ./bin/script-runner [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]
  pwsh -NoProfile -ExecutionPolicy Bypass -File ./bin/script-runner.ps1 [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]

TARGETS (auto-resolved to .ps1 or .sh):
  shebang-mcp-sdk   (default) Generic MCP SDK server (bin/shebang-mcp-sdk.{ps1,sh})
  setup-sdk         SDK setup/check utility (skills/shebang-mcp-builder/scripts/setup-sdk.{ps1,sh})
  stop-hook         Session Stop hook (io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.{ps1,sh})
  <path/to/script>  Any custom script path (with or without .ps1 / .sh extension)
"@
            exit 0
        }
        if (-not $arg.StartsWith("-")) {
            # A non-option in target position is always an explicit target. If it
            # cannot be resolved, fail below instead of running the default server.
            $TargetScript = $arg
            $idx++
            continue
        }
        $TargetScript = "shebang-mcp-sdk"
    }
    $ForwardArgs.Add($arg)
    $idx++
}

if ([string]::IsNullOrEmpty($TargetScript)) {
    $TargetScript = "shebang-mcp-sdk"
}

$resolved = Resolve-TargetScripts -TargetName $TargetScript
if ($null -eq $resolved) {
    [Console]::Error.WriteLine("script-runner: Could not find .ps1 or .sh script for target: $TargetScript")
    exit 1
}
if ($ForcedShell -eq "sh" -and $null -eq $resolved.ShPath) {
    [Console]::Error.WriteLine("script-runner: --use-sh requested, but no .sh script exists for target: $TargetScript")
    exit 1
}
if ($ForcedShell -eq "pwsh" -and $null -eq $resolved.PsPath) {
    [Console]::Error.WriteLine("script-runner: --use-pwsh requested, but no .ps1 script exists for target: $TargetScript")
    exit 1
}

$useWindowsPs = $true
if ($ForcedShell -eq "sh") {
    $useWindowsPs = $false
}
elseif ($ForcedShell -eq "pwsh") {
    $useWindowsPs = $true
}
else {
    $isWin = ($env:OS -eq "Windows_NT") -or ([System.Environment]::OSVersion.Platform -eq "Win32NT")
    if ($isWin -and $null -ne $resolved.PsPath) {
        $useWindowsPs = $true
    }
    elseif ($null -ne $resolved.ShPath -and -not $isWin) {
        $useWindowsPs = $false
    }
    elseif ($null -ne $resolved.PsPath) {
        $useWindowsPs = $true
    }
    else {
        $useWindowsPs = $false
    }
}

$fwdArray = $ForwardArgs.ToArray()
$resolvedBase = [System.IO.Path]::GetFullPath($resolved.Base)
$sdkServerBase = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RunnerDir, "shebang-mcp-sdk"))
$explicitStdio = $fwdArray.Count -gt 0 -and ($fwdArray[0] -eq "--stdio" -or $fwdArray[0] -eq "-Stdio")
$defaultStdio = $fwdArray.Count -eq 0 -and ([string]::IsNullOrEmpty($env:MCP_TRANSPORT) -or $env:MCP_TRANSPORT -eq "stdio")
$isPersistentStdio = ($resolvedBase -eq $sdkServerBase) -and ($explicitStdio -or $defaultStdio)

# MCP clients keep stdin open while waiting for responses. Do not even query
# automatic input on the persistent stdio path: doing so makes pwsh consume the
# redirected stream before the SDK can read it.
$pipedInput = @()
if (-not $isPersistentStdio) {
    # Preserve finite pipeline forwarding for non-stdio utility scripts.
    $pipedInput = @(Get-Variable -Name "input" -ValueOnly -ErrorAction SilentlyContinue)
}

if ($useWindowsPs) {
    if ($isPersistentStdio) {
        # Inherit the open client stdin/stdout/stderr handles directly. Passing
        # pipeline objects through this wrapper would buffer stdio until EOF.
        $powerShellExe = (Get-Process -Id $PID).Path
        $quotedPsPath = [System.String]::Concat([System.Char]34, $resolved.PsPath, [System.Char]34)
        $serverArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $quotedPsPath) + $fwdArray
        $child = Start-Process -FilePath $powerShellExe -ArgumentList $serverArgs -NoNewWindow -Wait -PassThru
        [System.Console]::Out.Flush()
        exit $child.ExitCode
    }
    elseif ($pipedInput.Count -gt 0) {
        $pipedInput | & $resolved.PsPath @fwdArray
    }
    else {
        & $resolved.PsPath @fwdArray
    }
    $code = if ((Test-Path Variable:\LASTEXITCODE) -and ($null -ne $global:LASTEXITCODE)) { [int]$global:LASTEXITCODE } else { 0 }
    [System.Console]::Out.Flush()
    exit $code
}
else {
    $bashCmd = $null
    if (Test-Path "C:\Program Files\Git\bin\bash.exe") {
        $bashCmd = "C:\Program Files\Git\bin\bash.exe"
    }
    elseif (Get-Command bash -ErrorAction SilentlyContinue) {
        $bashCmd = (Get-Command bash).Source
    }
    elseif (Get-Command sh -ErrorAction SilentlyContinue) {
        $bashCmd = (Get-Command sh).Source
    }
    else {
        [Console]::Error.WriteLine("script-runner: Neither bash nor sh found to execute $($resolved.ShPath)")
        exit 1
    }
    # MSYS/Git Bash accepts Windows drive paths with forward slashes. Besides
    # avoiding native-argument quoting surprises, this preserves the POSIX
    # entry point ${0##*/} script-name dispatch on Windows.
    $shPath = $resolved.ShPath.Replace("\", "/")
    if ($pipedInput.Count -gt 0) {
        $pipedInput | & $bashCmd $shPath @fwdArray
    }
    else {
        & $bashCmd $shPath @fwdArray
    }
    $code = if ((Test-Path Variable:\LASTEXITCODE) -and ($null -ne $global:LASTEXITCODE)) { [int]$global:LASTEXITCODE } else { 0 }
    [System.Console]::Out.Flush()
    exit $code
}
' >/dev/null ; : ' <# '

set -eu

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${RUNNER_DIR}/.." && pwd)}"
export PLUGIN_ROOT

resolve_target_base() {
    target_name="${1:-shebang-mcp-sdk}"
    stripped="${target_name%.sh}"
    stripped="${stripped%.ps1}"

    for candidate in \
        "${PLUGIN_ROOT}/bin/${stripped}" \
        "${PLUGIN_ROOT}/scripts/${stripped}" \
        "${PLUGIN_ROOT}/.agents/skills/shebang-mcp-builder/scripts/${stripped}" \
        "${PLUGIN_ROOT}/skills/shebang-mcp-builder/scripts/${stripped}" \
        "${PLUGIN_ROOT}/io.github.sheldonrobinson.shebang-mcp-builder/hooks/${stripped}" \
        "${stripped}"
    do
        if [ -f "${candidate}.sh" ] || [ -f "${candidate}.ps1" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

FORCED_SHELL=""
TARGET_SCRIPT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --use-sh|--sh|--bash)
            FORCED_SHELL="sh"
            shift
            ;;
        --use-pwsh|--pwsh|--ps1|--powershell)
            FORCED_SHELL="pwsh"
            shift
            ;;
        --runner-help)
            cat << 'HELP_EOF'
Cross-Platform Polyglot Script Runner (POSIX sh / Bash & PowerShell)

USAGE:
  ./bin/script-runner [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]
  pwsh -NoProfile -ExecutionPolicy Bypass -File ./bin/script-runner.ps1 [--use-sh|--use-pwsh] [TARGET_SCRIPT] [SCRIPT_ARGS...]

TARGETS (auto-resolved to .sh or .ps1):
  shebang-mcp-sdk   (default) Generic MCP SDK server (bin/shebang-mcp-sdk.{sh,ps1})
  setup-sdk         SDK setup/check utility (skills/shebang-mcp-builder/scripts/setup-sdk.{sh,ps1})
  stop-hook         Session Stop hook (io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.{sh,ps1})
  <path/to/script>  Any custom script path (with or without .sh / .ps1 extension)
HELP_EOF
            exit 0
            ;;
        -*)
            break
            ;;
        *)
            # This is an explicit target even when unresolved. Never substitute
            # the default server for a misspelled or missing target.
            TARGET_SCRIPT="$1"
            shift
            break
            ;;
    esac
done

if [ -z "${TARGET_SCRIPT}" ]; then
    TARGET_SCRIPT="shebang-mcp-sdk"
fi

if ! BASE_PATH="$(resolve_target_base "${TARGET_SCRIPT}")"; then
    echo "script-runner: Could not find .sh or .ps1 script for target: ${TARGET_SCRIPT}" >&2
    exit 1
fi

SH_PATH="${BASE_PATH}.sh"
PS_PATH="${BASE_PATH}.ps1"

if [ "${FORCED_SHELL}" = "sh" ] && [ ! -f "${SH_PATH}" ]; then
    echo "script-runner: --use-sh requested, but no .sh script exists for target: ${TARGET_SCRIPT}" >&2
    exit 1
fi
if [ "${FORCED_SHELL}" = "pwsh" ] && [ ! -f "${PS_PATH}" ]; then
    echo "script-runner: --use-pwsh requested, but no .ps1 script exists for target: ${TARGET_SCRIPT}" >&2
    exit 1
fi

USE_SH="true"
if [ "${FORCED_SHELL}" = "pwsh" ]; then
    USE_SH="false"
elif [ "${FORCED_SHELL}" = "sh" ]; then
    USE_SH="true"
else
    case "$(uname -s 2>/dev/null || echo Unknown)" in
        MINGW*|MSYS*|CYGWIN*)
            # In Git Bash / MSYS on Windows, prefer .sh when invoked via sh/bash.
            if [ -f "${SH_PATH}" ]; then
                USE_SH="true"
            else
                USE_SH="false"
            fi
            ;;
        *)
            if [ -f "${SH_PATH}" ]; then
                USE_SH="true"
            else
                USE_SH="false"
            fi
            ;;
    esac
fi

if [ "${USE_SH}" = "true" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "${SH_PATH}" "$@"
    else
        exec sh "${SH_PATH}" "$@"
    fi
else
    if command -v pwsh >/dev/null 2>&1; then
        exec pwsh -NoProfile -ExecutionPolicy Bypass -File "${PS_PATH}" "$@"
    elif command -v powershell.exe >/dev/null 2>&1; then
        exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${PS_PATH}" "$@"
    else
        echo "script-runner: Neither pwsh nor powershell.exe found to execute ${PS_PATH}" >&2
        exit 1
    fi
fi
#>
