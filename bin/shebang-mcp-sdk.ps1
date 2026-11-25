#Requires -Version 5.1
# shebang-mcp-sdk.ps1 - Generic Shebang MCP SDK Server Entry Point (PowerShell)
#
# Starts the generic Shebang MCP SDK server over stdio or streamable-http transport.
# This server implements the core Model Context Protocol (MCP) specification and
# contains NO application-specific logic — consumers override tool handlers via
# global functions (Handle-ListTools, Handle-ToolsCall, Invoke-McpCustomMethod).
#
# Dual-mode: Works as both an MCP server (stdio/streamable-http) and a CLI tool.
# In CLI mode, consumers can invoke tools directly without the MCP protocol.
#
# Development utilities (sdk-utils.psm1) are optionally imported for sdk-generate-handler.
# sdk-utils.psm1 is NOT part of the core runtime and should not be bundled with consumer
# MCP servers — it is only needed during development/code-generation.
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1               # stdio MCP server (default)
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --stdio       # stdio MCP server
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --streamable-http --port 8080
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --cli --ListTools          # List available tools
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --cli --CallTool my_tool '{"arg":"val"}'  # Call a tool
#
# Environment variables:
#   MCP_TRANSPORT       stdio | streamable-http  (default: stdio)
#   MCP_SERVER_NAME     server name (default: shebang-mcp-sdk)
#   MCP_SERVER_VERSION  version string (default: 1.0.0)
#   MCP_PROTOCOL_VERSION 2025-03-26 | 2024-11-05 (default: 2025-03-26)
#   MCP_HTTP_HOST, MCP_HTTP_PORT, MCP_HTTP_ENDPOINT
#   PLUGIN_ROOT         root of the installation (auto-detected if unset)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $ScriptDir "..")).Path }
$env:PLUGIN_ROOT = $PluginRoot

# Import the generic MCP SDK module (core runtime — included in consumer bundles)
Import-Module -LiteralPath (Join-Path $PluginRoot 'bin\mcp-sdk.psm1') -Force -ErrorAction Stop

# Optionally import SDK utilities (dev-time only — NOT bundled with consumers)
# Consumers who need sdk-generate-handler can import sdk-utils.psm1 directly:
#   Import-Module "${PLUGIN_ROOT}/bin/sdk-utils.psm1"
if (Test-Path -LiteralPath (Join-Path $PluginRoot 'bin\sdk-utils.psm1')) {
    Import-Module -LiteralPath (Join-Path $PluginRoot 'bin\sdk-utils.psm1') -Force -ErrorAction SilentlyContinue
}

# --- CLI mode helpers -------------------------------------------------------
function cli-list-tools {
    # Build a minimal initialize + tools/list request and dispatch it
    $req = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cli","version":"1.0"}}}'
    $resp = process-mcp-line -Message $req
    # Now request tools/list
    $req = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    $resp = process-mcp-line -Message $req
    $parsed = $resp | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -ne $parsed -and $parsed.result -and $parsed.result.tools) {
        foreach ($t in $parsed.result.tools) {
            Write-Output ("{0} — {1}" -f $t.name, if ($t.description) { $t.description } else { "no description" })
        }
    } else {
        Write-Output $resp
    }
}

function cli-call-tool {
    param([string]$ToolName, [string]$ToolArgs = "{}")
    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        Write-Error "Error: --CallTool requires a tool name"
        return 1
    }
    $req = '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cli","version":"1.0"}}}'
    process-mcp-line -Message $req > $null 2>&1 || true
    $req = ('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"{0}","arguments":{1}}}' -f $ToolName, $ToolArgs)
    process-mcp-line -Message $req
}

# --- Main entry point -------------------------------------------------------
$pipedLines = @($input)
if ($args.Count -eq 0) {
    if ($pipedLines.Count -gt 0) { $pipedLines | Start-McpServer } else { Start-McpServer }
    exit 0
}
elseif ($args[0] -eq '--stdio') {
    if ($pipedLines.Count -gt 0) { $pipedLines | Start-McpServer -Transport 'stdio' } else { Start-McpServer -Transport 'stdio' }
    exit 0
}
elseif ($args[0] -eq '--http' -or $args[0] -eq '--streamable-http') {
    $port = 8080
    $hostName = '127.0.0.1'
    $endpoint = '/mcp'
    for ($i = 1; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '--port' -and ($i + 1) -lt $args.Count) { $port = [int]$args[++$i] }
        elseif ($args[$i] -eq '--host' -and ($i + 1) -lt $args.Count) { $hostName = [string]$args[++$i] }
        elseif ($args[$i] -eq '--endpoint' -and ($i + 1) -lt $args.Count) { $endpoint = [string]$args[++$i] }
    }
    Start-McpServer -Transport 'streamable-http' -HostName $hostName -Port $port
    exit 0
}
elseif ($args[0] -eq '--cli') {
    if ($args.Count -eq 1) {
        Write-Output "shebang-mcp-sdk CLI mode"
        Write-Output "Usage: pwsh -File .\bin\shebang-mcp-sdk.ps1 --cli --ListTools"
        Write-Output "       pwsh -File .\bin\shebang-mcp-sdk.ps1 --cli --CallTool <tool_name> '<json_args>'"
        exit 0
    }
    shift
    $cmd = [string]$args[0]
    switch ($cmd) {
        { $_ -in @('--ListTools', 'ListTools', '--list-tools', 'list-tools') } {
            cli-list-tools
        }
        { $_ -in @('--CallTool', 'CallTool', '--call-tool', 'call-tool') } {
            shift
            $toolName = [string]${args[0] -as [string[]] -or @($args)[0]}
            $toolArgs = if ($args.Count -gt 1) { [string]${args[1] -as [string[]] -or @($args)[1]} } else { "{}" }
            cli-call-tool -ToolName $toolName -ToolArgs $toolArgs
        }
        default {
            Write-Error "Unknown CLI command: $cmd"
            Write-Output "Available: --ListTools, --CallTool"
            exit 1
        }
    }
    exit 0
}
else {
    [Console]::Error.WriteLine("shebang-mcp-sdk: Unknown argument: $($args[0])")
    [Console]::Error.WriteLine('Usage: pwsh -File .\bin\shebang-mcp-sdk.ps1 [--stdio|--streamable-http|--cli] [--port PORT] [--host HOST]')
    exit 1
}
