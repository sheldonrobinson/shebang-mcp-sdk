#Requires -Version 5.1
# shebang-mcp-sdk.ps1 - Generic Shebang MCP SDK Server Entry Point (PowerShell)
#
# Starts the generic Shebang MCP SDK server over stdio or streamable-http transport.
# This server implements the core Model Context Protocol (MCP) specification and
# contains NO application-specific logic; consumers override tool handlers via
# global functions (Handle-ListTools, Handle-ToolsCall, Invoke-McpCustomMethod).
#
# Dual-mode: Works as both an MCP server (stdio/streamable-http) and a CLI tool.
# In CLI mode, consumers can invoke tools directly without the MCP protocol.
#
# Development utilities (sdk-utils.psm1) are optionally imported for sdk-generate-handler.
# sdk-utils.psm1 is NOT part of the core runtime and should not be bundled with consumer
# MCP servers; it is only needed during development/code-generation.
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
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $ScriptDir '..')).Path }
$env:PLUGIN_ROOT = $PluginRoot

# Import the generic MCP SDK module (core runtime; included in consumer bundles)
Import-Module -Name (Join-Path $PluginRoot 'bin\mcp-sdk.psm1') -Force -DisableNameChecking -ErrorAction Stop

# Development utilities are deliberately not imported by the runtime. Consumers
# developing handlers can import bin/sdk-utils.psm1 in a separate generator script.

# --- CLI mode helpers -------------------------------------------------------
function New-CliMcpRequest {
    param(
        [int]$Id,
        [string]$Method,
        [object]$Params
    )

    $request = [ordered]@{
        jsonrpc = '2.0'
        id      = $Id
        method  = $Method
        params  = $Params
    }
    return ($request | ConvertTo-Json -Depth 32 -Compress)
}

function Invoke-CliMcpRequest {
    param(
        [int]$Id,
        [string]$Method,
        [object]$Params
    )

    $request = New-CliMcpRequest -Id $Id -Method $Method -Params $Params
    $response = process-mcp-line -line $request
    if ([string]::IsNullOrWhiteSpace([string]$response)) {
        throw "MCP request '$Method' returned no response."
    }

    try {
        $parsed = [string]$response | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "MCP request '$Method' returned invalid JSON: $($_.Exception.Message)"
    }

    $errorProperty = $parsed.PSObject.Properties['error']
    if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
        $mcpError = $errorProperty.Value
        $messageProperty = $mcpError.PSObject.Properties['message']
        $message = if ($null -ne $messageProperty) { [string]$messageProperty.Value } else { [string]$response }
        throw "MCP request '$Method' failed: $message"
    }

    return [PSCustomObject]@{
        Raw     = [string]$response
        Message = $parsed
    }
}

function Initialize-CliSession {
    $protocolVersion = if ($env:MCP_PROTOCOL_VERSION) { $env:MCP_PROTOCOL_VERSION } else { '2025-03-26' }
    $params = [ordered]@{
        protocolVersion = $protocolVersion
        capabilities    = @{}
        clientInfo      = [ordered]@{
            name    = 'cli'
            version = '1.0'
        }
    }
    $response = Invoke-CliMcpRequest -Id 1 -Method 'initialize' -Params $params
    if ($null -eq $response.Message.PSObject.Properties['result']) {
        throw 'MCP initialize returned no result.'
    }
}

function cli-list-tools {
    Initialize-CliSession
    $response = Invoke-CliMcpRequest -Id 2 -Method 'tools/list' -Params @{}
    $resultProperty = $response.Message.PSObject.Properties['result']
    if ($null -eq $resultProperty -or $null -eq $resultProperty.Value) {
        throw 'MCP tools/list returned no result.'
    }

    $toolsProperty = $resultProperty.Value.PSObject.Properties['tools']
    if ($null -eq $toolsProperty) {
        throw 'MCP tools/list returned no tools collection.'
    }

    foreach ($tool in @($toolsProperty.Value)) {
        $descriptionProperty = $tool.PSObject.Properties['description']
        $description = if ($null -ne $descriptionProperty -and -not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) {
            [string]$descriptionProperty.Value
        }
        else {
            'no description'
        }
        Write-Output ('{0} - {1}' -f $tool.name, $description)
    }
}

function cli-call-tool {
    param(
        [string]$ToolName,
        [string]$ToolArgs = '{}'
    )

    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        throw '--CallTool requires a tool name.'
    }

    try {
        $parsedArgs = ConvertFrom-Json -InputObject $ToolArgs -ErrorAction Stop
    }
    catch {
        throw "--CallTool arguments must be valid JSON: $($_.Exception.Message)"
    }
    if ($parsedArgs -isnot [System.Management.Automation.PSCustomObject] -and
        $parsedArgs -isnot [System.Collections.IDictionary]) {
        throw '--CallTool arguments must be a JSON object.'
    }

    Initialize-CliSession
    $params = [ordered]@{
        name      = $ToolName
        arguments = $parsedArgs
    }
    $response = Invoke-CliMcpRequest -Id 4 -Method 'tools/call' -Params $params
    Write-Output $response.Raw
}

# --- Main entry point -------------------------------------------------------
# MCP stdio must stream from open stdin. Do not enumerate the automatic $input
# variable or pipe collected lines into Start-McpServer on these paths.
if ($args.Count -eq 0) {
    Start-McpServer
    exit 0
}
elseif ($args[0] -eq '--stdio' -or $args[0] -eq '-Stdio') {
    Start-McpServer -Transport 'stdio'
    exit 0
}
elseif ($args[0] -eq '--http' -or $args[0] -eq '--streamable-http') {
    $port = if ($env:MCP_HTTP_PORT) { [int]$env:MCP_HTTP_PORT } else { 8080 }
    $hostName = if ($env:MCP_HTTP_HOST) { $env:MCP_HTTP_HOST } else { '127.0.0.1' }
    $endpoint = if ($env:MCP_HTTP_ENDPOINT) { $env:MCP_HTTP_ENDPOINT } else { '/mcp' }
    for ($i = 1; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '--port' -and ($i + 1) -lt $args.Count) {
            $port = [int]$args[++$i]
        }
        elseif ($args[$i] -eq '--host' -and ($i + 1) -lt $args.Count) {
            $hostName = [string]$args[++$i]
        }
        elseif ($args[$i] -eq '--endpoint' -and ($i + 1) -lt $args.Count) {
            $endpoint = [string]$args[++$i]
        }
        else {
            [Console]::Error.WriteLine("shebang-mcp-sdk: Invalid or incomplete HTTP argument: $($args[$i])")
            exit 1
        }
    }
    Start-McpServer -Transport 'streamable-http' -HostName $hostName -Port $port -Endpoint $endpoint
    exit 0
}
elseif ($args[0] -eq '--cli') {
    # Windows PowerShell otherwise writes CLI output with the legacy OEM code
    # page, corrupting non-ASCII tool names and descriptions for subprocess
    # consumers. Match the stdio transport's explicit UTF-8 output contract.
    [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    if ($args.Count -eq 1) {
        Write-Output 'shebang-mcp-sdk CLI mode'
        Write-Output 'Usage: pwsh -File .\bin\shebang-mcp-sdk.ps1 --cli --ListTools'
        Write-Output "       pwsh -File .\bin\shebang-mcp-sdk.ps1 --cli --CallTool <tool_name> '<json_args>'"
        exit 0
    }

    try {
        $cmd = [string]$args[1]
        if ($cmd -in @('--ListTools', 'ListTools', '--list-tools', 'list-tools')) {
            if ($args.Count -ne 2) {
                throw "$cmd does not accept additional arguments."
            }
            cli-list-tools
        }
        elseif ($cmd -in @('--CallTool', 'CallTool', '--call-tool', 'call-tool')) {
            if ($args.Count -lt 3) {
                throw '--CallTool requires a tool name.'
            }
            if ($args.Count -gt 4) {
                throw '--CallTool accepts only a tool name and one JSON object argument.'
            }
            $toolName = [string]$args[2]
            $toolArgs = if ($args.Count -eq 4) { [string]$args[3] } else { '{}' }
            cli-call-tool -ToolName $toolName -ToolArgs $toolArgs
        }
        else {
            throw "Unknown CLI command: $cmd. Available: --ListTools, --CallTool"
        }
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("shebang-mcp-sdk: $($_.Exception.Message)")
        exit 1
    }
}
else {
    [Console]::Error.WriteLine("shebang-mcp-sdk: Unknown argument: $($args[0])")
    [Console]::Error.WriteLine('Usage: pwsh -File .\bin\shebang-mcp-sdk.ps1 [--stdio|--streamable-http|--cli] [--port PORT] [--host HOST] [--endpoint PATH]')
    exit 1
}
