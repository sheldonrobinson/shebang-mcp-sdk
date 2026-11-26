#Requires -Version 5.1
# Shebang MCP SDK - Setup Script (PowerShell)
# Displays SDK information and verifies the installation.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $ScriptDir "../../..")).Path }
$env:PLUGIN_ROOT = $PluginRoot

if (-not (Test-Path -LiteralPath (Join-Path $PluginRoot 'bin') -PathType Container)) {
    [Console]::Error.WriteLine("SDK runtime not found: ${PluginRoot}/bin")
    [Console]::Error.WriteLine('A skill-only copy does not install the SDK runtime.')
    [Console]::Error.WriteLine('Set PLUGIN_ROOT to a full shebang-mcp-sdk checkout or extracted MCPB containing bin/, then rerun this script.')
    exit 1
}

$idx = 0
while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    switch ($arg) {
        { $_ -in @('-h', '--help') } {
            Write-Output @"
Shebang MCP SDK - Setup Script

USAGE:
  skills\shebang-mcp-builder\scripts\setup-sdk.ps1 [OPTIONS]

OPTIONS:
  --info         Show SDK installation information
  --check        Verify SDK files are present
  -h, --help     Show this help message
"@
            exit 0
        }
        '--info' {
            Write-Output "Shebang MCP SDK"
            Write-Output "  Plugin root:      ${PluginRoot}"
            Write-Output "  SDK PowerShell:   ${PluginRoot}/bin/mcp-sdk.psm1"
            Write-Output "  Server (pwsh):    ${PluginRoot}/bin/shebang-mcp-sdk.ps1"
            Write-Output "  Runner (pwsh):    ${PluginRoot}/bin/script-runner.ps1"
            exit 0
        }
        '--check' {
            $missing = 0
            foreach ($f in @('bin\mcp-sdk.psm1', 'bin\shebang-mcp-sdk.ps1', 'bin\script-runner.ps1')) {
                $full = Join-Path $PluginRoot $f
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    Write-Output "OK: ${f}"
                } else {
                    Write-Output "MISSING: ${f}"
                    $missing = 1
                }
            }
            if ($missing -eq 1) {
                exit 1
            }
            Write-Output "All required SDK files present."
            exit 0
        }
        default {
            [Console]::Error.WriteLine("Unknown argument: $arg")
            exit 1
        }
    }
    $idx++
}

# Default: show info
Write-Output "Shebang MCP SDK v1.0.0"
Write-Output "Plugin root: ${PluginRoot}"
Write-Output ""
Write-Output "Usage:"
Write-Output "  pwsh -NoProfile -File ./bin/shebang-mcp-sdk.ps1 --stdio"
Write-Output "  pwsh -NoProfile -File ./bin/shebang-mcp-sdk.ps1 --streamable-http --port 8080"
