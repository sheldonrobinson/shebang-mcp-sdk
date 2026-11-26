#Requires -Version 5.1
# shebang-mcp-sdk Stop Hook (PowerShell - Agent-Harness Agnostic)
# Performs clean shutdown of the generic Shebang MCP SDK server.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $ScriptDir "..")).Path }
$env:PLUGIN_ROOT = $PluginRoot

# Import the MCP SDK for cleanup functions if available
$SdkModule = Join-Path $PluginRoot 'bin\mcp-sdk.psm1'
if (Test-Path -LiteralPath $SdkModule) {
    Import-Module -Name $SdkModule -Force -ErrorAction SilentlyContinue
}

# Close any active connections and clean up transport resources
if (Get-Command Close-McpConnection -ErrorAction SilentlyContinue) {
    Close-McpConnection
}

if (Get-Command Invoke-McpOnExit -ErrorAction SilentlyContinue) {
    Invoke-McpOnExit
}

exit 0
