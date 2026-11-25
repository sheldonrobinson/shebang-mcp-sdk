#Requires -Version 5.1
# Shebang MCP SDK - Setup Script (PowerShell)
# Displays SDK information and verifies the installation.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $ScriptDir "../../..")).Path }
$env:PLUGIN_ROOT = $PluginRoot

$idx = 0
while ($idx -lt $args.Count) {
    $arg = [string]$args[$idx]
    switch ($arg) {
        { $_ -in @('-h', '--help') } {
            Write-Output @"
Shebang MCP SDK - Setup Script

USAGE:
  skills\shebang-mcp-sdk\scripts\setup-sdk.ps1 [OPTIONS]

OPTIONS:
  --info         Show SDK installation information
  --check        Verify SDK files are present
  -h, --help     Show this help message
"@
            exit 0
        }
        '--info' {
            Write-Output "Shebang MCP SDK"
            Write-Output "  Plugin root: ${PluginRoot}"
            Write-Output "  SDK Bash:    ${PluginRoot}/bin/mcp-sdk.sh"
            Write-Output "  SDK PowerShell: ${PluginRoot}/bin/mcp-sdk.psm1"
            Write-Output "  Server (sh): ${PluginRoot}/bin/shebang-mcp-sdk.sh"
            Write-Output "  Server (pwsh): ${PluginRoot}/bin/shebang-mcp-sdk.ps1"
            Write-Output "  Runner:      ${PluginRoot}/bin/script-runner"
            exit 0
        }
        '--check' {
            $missing = 0
            foreach ($f in @('bin\mcp-sdk.sh', 'bin\shebang-mcp-sdk.sh', 'bin\script-runner')) {
                $full = Join-Path $PluginRoot $f
                if (Test-Path -LiteralPath $full) {
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
Write-Output "  ./bin/script-runner.sh shebang-mcp-sdk --stdio"
Write-Output "  ./bin/shebang-mcp-sdk.sh --streamable-http --port 8080"
