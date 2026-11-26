# mcp-sdk.psm1 - Generic Shebang MCP SDK (PowerShell)
# Implementation of the Model Context Protocol (MCP) specification (latest: 2025-03-26 / 2024-11-05)
# Supports both stdio and streamable-http transports.
#
# This SDK is strictly generic and provides core MCP protocol functions usable by any
# PowerShell-based MCP server. It contains NO application-specific logic.
#
# ============================================================================
# REQUIRED features (MUST implement per MCP specification):
#   - JSON-RPC 2.0 envelope (jsonrpc: "2.0") on every message
#   - initialize request       -> capabilities, serverInfo, protocolVersion
#   - notifications/initialized (and initialized) -> handled silently (no response)
#   - ping request             -> empty object {} response
#   - tools/list               -> list of available tools
#   - tools/call               -> invoke a named tool with arguments
#   - Standard JSON-RPC 2.0 error codes (-32700, -32600, -32601, -32602, -32603)
#   - Transports: stdio and streamable-http
#   - On-exit cleanup handler (PowerShell.Exiting & Module.OnRemove)
#
# OPTIONAL features (explicitly NOT implemented):
#   - Authorization, Elicitation, Roots, Sampling, Completions, Logging
#
# DEPRECATED features (explicitly NOT implemented):
#   - Legacy HTTP+SSE transport (2024-11-05 separate SSE endpoint)
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# PROTOCOL CONSTANTS & STATE
# ============================================================================

$script:McpProtocolVersion   = if ($env:MCP_PROTOCOL_VERSION) { $env:MCP_PROTOCOL_VERSION } else { '2025-03-26' }
$script:McpSupportedVersions = @('2025-03-26', '2024-11-05')
$script:McpServerName        = if ($env:MCP_SERVER_NAME) { $env:MCP_SERVER_NAME } else { 'shebang-mcp-sdk' }
$script:McpServerVersion     = if ($env:MCP_SERVER_VERSION) { $env:MCP_SERVER_VERSION } else { '1.0.0' }

$script:McpTransport         = if ($env:MCP_TRANSPORT) { $env:MCP_TRANSPORT } else { 'stdio' }
$script:McpHttpHost          = if ($env:MCP_HTTP_HOST) { $env:MCP_HTTP_HOST } else { '127.0.0.1' }
$script:McpHttpPort          = if ($env:MCP_HTTP_PORT) { [int]$env:MCP_HTTP_PORT } else { 8080 }
$script:McpHttpEndpoint      = if ($env:MCP_HTTP_ENDPOINT) { $env:MCP_HTTP_ENDPOINT } else { '/mcp' }
$script:McpInitialized       = $false
$script:McpHttpListener      = $null
$script:McpCleanupDone       = $false
$script:McpCleanupHooks      = [System.Collections.Generic.List[scriptblock]]::new()

# McpInitialized is stdio lifecycle state. HTTP lifecycle state belongs only to
# an entry in McpSessions and is never mirrored into module-global variables.
$script:McpSessions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$script:McpHttpMaxBodyBytes = if ($env:MCP_HTTP_MAX_BODY_BYTES) { [int]$env:MCP_HTTP_MAX_BODY_BYTES } else { 1048576 }
$script:McpHttpAllowedOrigins = if ($env:MCP_HTTP_ALLOWED_ORIGINS) { $env:MCP_HTTP_ALLOWED_ORIGINS } else { '' }
$script:McpHttpAllowNonLoopback = if ($env:MCP_HTTP_ALLOW_NON_LOOPBACK) { $env:MCP_HTTP_ALLOW_NON_LOOPBACK } else { '' }

# ============================================================================
# ON-EXIT & CONNECTION CLEANUP HANDLERS
# ============================================================================

function Register-McpCleanup {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Callback
    )
    $script:McpCleanupHooks.Add($Callback)
}

function Close-McpConnection {
    if ($null -ne $script:McpHttpListener) {
        try {
            if ($script:McpHttpListener.IsListening) {
                $script:McpHttpListener.Stop()
            }
            $script:McpHttpListener.Close()
        }
        catch {
            # Ignore listener disposal errors during teardown
        }
        finally {
            $script:McpHttpListener = $null
        }
    }
    $script:McpInitialized = $false
    $script:McpSessions.Clear()
}

function Invoke-McpOnExit {
    if ($script:McpCleanupDone) { return }
    $script:McpCleanupDone = $true

    foreach ($hook in $script:McpCleanupHooks) {
        try {
            & $hook
        }
        catch {
            # Ignore errors in cleanup callbacks
        }
    }

    Close-McpConnection
}

# Alias for kebab-case naming consistency
Set-Alias -Name mcp-on-exit -Value Invoke-McpOnExit
Set-Alias -Name mcp-close-connection -Value Close-McpConnection
Set-Alias -Name mcp-register-cleanup -Value Register-McpCleanup

# Register module unload cleanup handler (runs when module is removed or runspace closes)
if ($MyInvocation.MyCommand.ScriptBlock.Module) {
    $MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
        Invoke-McpOnExit
    }
}

# ============================================================================
# CORE PROTOCOL UTILITIES
# ============================================================================

function Set-McpServerInfo {
    param(
        [string]$Name,
        [string]$Version,
        [string]$ProtocolVersion
    )
    if ($Name)            { $script:McpServerName      = $Name }
    if ($Version)         { $script:McpServerVersion   = $Version }
    if ($ProtocolVersion) { $script:McpProtocolVersion = $ProtocolVersion }
}

function ConvertTo-McpHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $val = $prop.Value
            if ($val -is [System.Management.Automation.PSCustomObject]) {
                $val = ConvertTo-McpHashtable $val
            }
            elseif ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                $arr = @()
                foreach ($item in $val) {
                    if ($item -is [System.Management.Automation.PSCustomObject]) {
                        $arr += ConvertTo-McpHashtable $item
                    }
                    else {
                        $arr += $item
                    }
                }
                $val = $arr
            }
            $hash[$prop.Name] = $val
        }
        return $hash
    }
    return $InputObject
}

# JSON-RPC 2.0 Response Constructor
# Usage: json-response -Id <id> [-Result <json_or_object>] [-Error <hashtable_or_json>]
function json-response {
    param(
        $Id = $null,
        $Result = '{}',
        $Error = $null
    )

    $resp = [ordered]@{
        jsonrpc = '2.0'
    }

    # Preserve id type (null, integer, or string) per JSON-RPC 2.0
    if ($null -eq $Id) {
        $resp['id'] = $null
    }
    elseif ($Id -is [int] -or $Id -is [long] -or $Id -is [double]) {
        $resp['id'] = $Id
    }
    elseif ($Id -is [string] -and $Id -match '^-?\d+$') {
        $resp['id'] = $Id
    }
    else {
        $resp['id'] = $Id
    }

    if ($null -ne $Error -and $Error -ne '') {
        if ($Error -is [string]) {
            try {
                $resp['error'] = $Error | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $resp['error'] = [ordered]@{ code = -32603; message = $Error }
            }
        }
        else {
            $resp['error'] = $Error
        }
    }
    else {
        if ($null -eq $Result) {
            $resp['result'] = [PSCustomObject]@{}
        }
        elseif ($Result -isnot [string]) {
            # Do not use PowerShell's loosely coercive comparisons here: both
            # $false and 0 otherwise compare equal to an empty string.
            $resp['result'] = $Result
        }
        elseif ([string]::IsNullOrEmpty($Result) -or $Result.Trim() -eq '{}') {
            $resp['result'] = [PSCustomObject]@{}
        }
        else {
            try {
                $trimmed = $Result.Trim()
                if ($trimmed -ceq 'null') {
                    $resp['result'] = $null
                }
                elseif ($trimmed.StartsWith('[')) {
                    # PowerShell 7 enumerates an empty JSON array into $null,
                    # while Windows PowerShell returns the array as one pipeline
                    # object. Assign the parsed array directly; wrapping that
                    # pipeline object in @() creates a spurious value/Count item
                    # on Windows PowerShell.
                    $parsedArray = $Result | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $parsedArray) {
                        $resp['result'] = @()
                    }
                    else {
                        $resp['result'] = [object[]]$parsedArray
                    }
                }
                else {
                    $resp['result'] = $Result | ConvertFrom-Json -ErrorAction Stop
                }
            }
            catch {
                $resp['result'] = [PSCustomObject]@{
                    content = @(
                        [PSCustomObject]@{ type = 'text'; text = $Result }
                    )
                }
            }
        }
    }

    return ConvertTo-Json -InputObject ([PSCustomObject]$resp) -Compress -Depth 20
}

Set-Alias -Name New-JsonResponse -Value json-response

# JSON-RPC 2.0 Error Object Constructor
# Usage: mcp-error -Code <code> -Message <message> [-Data <data>]
function mcp-error {
    param(
        [int]$Code = -32603,
        [string]$Message = 'Internal error',
        $Data = $null
    )
    $err = [ordered]@{
        code    = $Code
        message = $Message
    }
    if ($null -ne $Data -and $Data -ne 'null' -and $Data -ne '') {
        $err['data'] = $Data
    }
    return $err
}

# Format a tool result per MCP spec
function New-McpToolResult {
    param(
        [string]$Text = '',
        [bool]$IsError = $false
    )
    return [ordered]@{
        content = @(
            [ordered]@{
                type = 'text'
                text = $Text
            }
        )
        isError = $IsError
    }
}

# Parse incoming JSON-RPC 2.0 message
# Returns hashtable: Valid, JsonRpc, IsNotification, Id, Method, Params
# RAW JSON TOKEN HELPERS
# ConvertFrom-Json uses different numeric types in Windows PowerShell and pwsh.
# These helpers retain the exact top-level id token without interpreting params.
# ============================================================================

function Get-McpJsonValueEnd {
    param([string]$Json, [int]$Start)

    $length = $Json.Length
    $i = $Start
    while ($i -lt $length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
    if ($i -ge $length) { return -1 }

    if ($Json[$i] -eq '"') {
        $i++
        while ($i -lt $length) {
            if ($Json[$i] -eq '\') { $i += 2; continue }
            if ($Json[$i] -eq '"') { return $i + 1 }
            $i++
        }
        return -1
    }

    if ($Json[$i] -eq '{' -or $Json[$i] -eq '[') {
        $depth = 0
        $inString = $false
        while ($i -lt $length) {
            $ch = $Json[$i]
            if ($inString) {
                if ($ch -eq '\') { $i += 2; continue }
                if ($ch -eq '"') { $inString = $false }
            }
            elseif ($ch -eq '"') {
                $inString = $true
            }
            elseif ($ch -eq '{' -or $ch -eq '[') {
                $depth++
            }
            elseif ($ch -eq '}' -or $ch -eq ']') {
                $depth--
                if ($depth -eq 0) { return $i + 1 }
            }
            $i++
        }
        return -1
    }

    while ($i -lt $length) {
        $ch = $Json[$i]
        if ([char]::IsWhiteSpace($ch) -or $ch -eq ',' -or $ch -eq '}' -or $ch -eq ']') { break }
        $i++
    }
    return $i
}

function Get-McpJsonObjectPropertyRange {
    param([string]$Json, [string]$PropertyName)

    $length = $Json.Length
    $i = 0
    while ($i -lt $length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
    if ($i -ge $length -or $Json[$i] -ne '{') { return $null }
    $i++

    while ($i -lt $length) {
        while ($i -lt $length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -lt $length -and $Json[$i] -eq ',') { $i++; continue }
        if ($i -lt $length -and $Json[$i] -eq '}') { return $null }
        if ($i -ge $length -or $Json[$i] -ne '"') { return $null }

        $nameEnd = Get-McpJsonValueEnd -Json $Json -Start $i
        if ($nameEnd -lt 0) { return $null }
        $nameJson = $Json.Substring($i, $nameEnd - $i)
        try { $name = $nameJson | ConvertFrom-Json -ErrorAction Stop }
        catch { return $null }

        $i = $nameEnd
        while ($i -lt $length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $length -or $Json[$i] -ne ':') { return $null }
        $i++
        while ($i -lt $length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }

        $valueStart = $i
        $valueEnd = Get-McpJsonValueEnd -Json $Json -Start $valueStart
        if ($valueEnd -lt 0) { return $null }
        if ($name -ceq $PropertyName) {
            return @{ ValueStart = $valueStart; ValueEnd = $valueEnd }
        }
        $i = $valueEnd
    }
    return $null
}

function Restore-McpResponseId {
    param([string]$ResponseJson, [string]$IdJson)

    if ([string]::IsNullOrEmpty($ResponseJson) -or [string]::IsNullOrEmpty($IdJson)) {
        return $ResponseJson
    }
    $range = Get-McpJsonObjectPropertyRange -Json $ResponseJson -PropertyName 'id'
    if ($null -eq $range) { return $ResponseJson }
    return $ResponseJson.Substring(0, $range.ValueStart) + $IdJson + $ResponseJson.Substring($range.ValueEnd)
}

function New-McpInvalidMessage {
    param([int]$ErrorCode = -32700, [bool]$IsBatch = $false)
    return @{
        Valid          = $false
        ErrorCode      = $ErrorCode
        IsBatch        = $IsBatch
        JsonRpc        = ''
        IsNotification = $false
        HasId          = $false
        Id             = $null
        IdJson         = $null
        Method         = ''
        Params         = @{}
    }
}

# Parse incoming JSON-RPC 2.0. Batches are valid JSON but explicitly unsupported.
function mcp-parse-message {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return New-McpInvalidMessage }

    # Capture and temporarily replace a numeric id before ConvertFrom-Json.
    # Otherwise an otherwise valid request can fail merely because its id is
    # outside Int64/Decimal/Double range on one of the supported runtimes.
    $range = Get-McpJsonObjectPropertyRange -Json $Message -PropertyName 'id'
    $idJson = $null
    $jsonToParse = $Message
    if ($null -ne $range) {
        $idJson = $Message.Substring($range.ValueStart, $range.ValueEnd - $range.ValueStart)
        if ($idJson -match '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$') {
            $jsonToParse = $Message.Substring(0, $range.ValueStart) + '0' + $Message.Substring($range.ValueEnd)
        }
    }

    try { $json = $jsonToParse | ConvertFrom-Json -ErrorAction Stop }
    catch { return New-McpInvalidMessage -ErrorCode -32700 }

    if ($Message.TrimStart().StartsWith('[')) {
        return New-McpInvalidMessage -ErrorCode -32600 -IsBatch $true
    }
    if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) {
        return New-McpInvalidMessage -ErrorCode -32600
    }

    # JSON-RPC member names are case-sensitive. Do not let PowerShell's usual
    # case-insensitive property lookup turn an "ID" member into a request id.
    $props = @($json.PSObject.Properties | ForEach-Object { $_.Name })
    $hasId = $props -ccontains 'id'
    $idVal = $null
    if ($hasId) {
        if ($null -eq $range) { return New-McpInvalidMessage -ErrorCode -32600 }

        # Validate the JSON token itself rather than its runtime representation.
        # This admits only string, number, and null ids on both PowerShell editions.
        $isStringId = $idJson.StartsWith('"')
        $isNumberId = $idJson -match '^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$'
        if (-not $isStringId -and -not $isNumberId -and $idJson -cne 'null') {
            return New-McpInvalidMessage -ErrorCode -32600
        }
        if ($idJson.StartsWith('"')) {
            try { $idVal = $idJson | ConvertFrom-Json -ErrorAction Stop }
            catch { return New-McpInvalidMessage -ErrorCode -32600 }
        }
        elseif ($idJson -cne 'null') {
            # Handlers receive the runtime value where one is available. Response
            # construction always restores IdJson, preserving the exact token.
            try { $idVal = $idJson | ConvertFrom-Json -ErrorAction Stop }
            catch { $idVal = $idJson }
        }
    }

    $jsonrpc = if ($props -ccontains 'jsonrpc' -and $json.jsonrpc -is [string]) { $json.jsonrpc } else { '' }
    $method = if ($props -ccontains 'method' -and $json.method -is [string]) { $json.method } else { '' }
    $params = if ($props -ccontains 'params') {
        if ($null -eq $json.params) { $null } else { ConvertTo-McpHashtable $json.params }
    }
    else {
        @{}
    }

    return @{
        Valid          = $true
        ErrorCode      = 0
        IsBatch        = $false
        JsonRpc        = $jsonrpc
        IsNotification = (-not $hasId)
        HasId          = $hasId
        Id             = $idVal
        IdJson         = $idJson
        Method         = $method
        Params         = $params
    }
}

# ============================================================================
# MCP METHOD HANDLERS
# ============================================================================

function handle-initialize {
    param(
        $Id,
        [System.Collections.IDictionary]$Params = @{},
        [System.Collections.IDictionary]$Session = $null
    )

    $clientVersion = if ($null -ne $Params -and $Params.Contains('protocolVersion')) { [string]$Params['protocolVersion'] } else { '' }
    $negotiatedVersion = $script:McpProtocolVersion
    if ($clientVersion -and ($script:McpSupportedVersions -contains $clientVersion)) {
        $negotiatedVersion = $clientVersion
    }

    # stdio retains its historical lifecycle behavior. HTTP state lives only in
    # the supplied session and is never mirrored into module-global variables.
    if ($null -ne $Session) {
        $Session['InitializeReceived'] = $true
        $Session['Initialized'] = $false
    }
    else {
        $script:McpInitialized = $true
    }

    $capabilities = [ordered]@{
        tools = [PSCustomObject]@{}
    }
    if ((Get-Command -Name 'Handle-ListResources' -ErrorAction SilentlyContinue) -or
        (Get-Command -Name 'Handle-ReadResource' -ErrorAction SilentlyContinue)) {
        $capabilities['resources'] = [PSCustomObject]@{}
    }
    if ((Get-Command -Name 'Handle-ListPrompts' -ErrorAction SilentlyContinue) -or
        (Get-Command -Name 'Handle-GetPrompt' -ErrorAction SilentlyContinue)) {
        $capabilities['prompts'] = [PSCustomObject]@{}
    }

    $result = [ordered]@{
        protocolVersion = $negotiatedVersion
        capabilities    = $capabilities
        serverInfo      = [ordered]@{
            name    = $script:McpServerName
            version = $script:McpServerVersion
        }
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function handle-initialized {
    param([System.Collections.IDictionary]$Session = $null)

    # Notification from client: acknowledge silently, no response.
    if ($null -ne $Session) {
        if ($Session.Contains('InitializeReceived') -and [bool]$Session['InitializeReceived']) {
            $Session['Initialized'] = $true
        }
    }
    else {
        $script:McpInitialized = $true
    }
}

function handle-ping {
    param($Id)
    return json-response -Id $Id -Result '{}'
}

function handle-tools-list {
    param(
        $Id,
        [System.Collections.IDictionary]$Params = @{}
    )

    # Delegate to consumer Handle-ListTools if defined in global/script scope
    $consumerCmd = Get-Command -Name 'Handle-ListTools' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) {
        return & $consumerCmd -Id $Id -Params $Params
    }

    $result = [ordered]@{
        tools = @()
    }
    return json-response -Id $Id -Result ([PSCustomObject]$result)
}

function handle-tools-call {
    param(
        $Id,
        [System.Collections.IDictionary]$Params = @{}
    )

    $consumerCmd = Get-Command -Name 'Handle-ToolsCall' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) {
        return & $consumerCmd -Id $Id -Params $Params
    }

    $name = if ($null -ne $Params -and $Params.Contains('name') -and $null -ne $Params['name']) {
        [string]$Params['name']
    }
    else {
        ''
    }

    if ([string]::IsNullOrEmpty($name)) {
        $err = mcp-error -Code -32602 -Message 'Invalid params: missing tool name'
        return json-response -Id $Id -Error $err
    }

    $err = mcp-error -Code -32601 -Message "Tool not found: $name"
    return json-response -Id $Id -Error $err
}

# Process a single JSON-RPC 2.0 line and return response string (or $null for notifications)
# RESOURCE AND PROMPT ROUTES
# ============================================================================

function handle-resources-list {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    $consumerCmd = Get-Command -Name 'Handle-ListResources' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) { return & $consumerCmd -Id $Id -Params $Params }
    return json-response -Id $Id -Error (mcp-error -Code -32601 -Message 'Method not found: resources/list')
}

function handle-resources-read {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    $consumerCmd = Get-Command -Name 'Handle-ReadResource' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) { return & $consumerCmd -Id $Id -Params $Params }
    return json-response -Id $Id -Error (mcp-error -Code -32601 -Message 'Method not found: resources/read')
}

function handle-prompts-list {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    $consumerCmd = Get-Command -Name 'Handle-ListPrompts' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) { return & $consumerCmd -Id $Id -Params $Params }
    return json-response -Id $Id -Error (mcp-error -Code -32601 -Message 'Method not found: prompts/list')
}

function handle-prompts-get {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    $consumerCmd = Get-Command -Name 'Handle-GetPrompt' -ErrorAction SilentlyContinue
    if ($null -ne $consumerCmd) { return & $consumerCmd -Id $Id -Params $Params }
    return json-response -Id $Id -Error (mcp-error -Code -32601 -Message 'Method not found: prompts/get')
}

function New-McpProcessError {
    param($Parsed, [int]$Code, [string]$Message)

    $id = if ($Parsed.Valid -and $Parsed.HasId) { $Parsed.Id } else { $null }
    $response = json-response -Id $id -Error (mcp-error -Code $Code -Message $Message)
    if ($Parsed.Valid -and $Parsed.HasId -and $Parsed.IdJson) {
        return Restore-McpResponseId -ResponseJson $response -IdJson $Parsed.IdJson
    }
    return $response
}

# Process one JSON-RPC message. Notifications may invoke handlers, never responses.
function process-mcp-line {
    param(
        [string]$line,
        [System.Collections.IDictionary]$Session = $null
    )

    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $parsed = mcp-parse-message -Message $line
    if (-not $parsed.Valid) {
        $message = if ($parsed.IsBatch) {
            'Invalid Request: batch requests are not supported'
        }
        elseif ($parsed.ErrorCode -eq -32600) {
            'Invalid Request'
        }
        else {
            'Parse error'
        }
        return json-response -Id $null -Error (mcp-error -Code $parsed.ErrorCode -Message $message)
    }

    # A syntactically valid JSON-RPC notification never receives a response,
    # including method, params, and version errors discovered after parsing.
    if ($parsed.IsNotification -and
        ($parsed.JsonRpc -cne '2.0' -or [string]::IsNullOrEmpty($parsed.Method) -or
         $parsed.Params -isnot [System.Collections.IDictionary])) {
        return $null
    }
    if ($parsed.JsonRpc -cne '2.0') {
        return New-McpProcessError -Parsed $parsed -Code -32600 -Message 'Invalid Request'
    }
    if ([string]::IsNullOrEmpty($parsed.Method)) {
        return New-McpProcessError -Parsed $parsed -Code -32600 -Message 'Invalid Request: missing method'
    }
    if ($parsed.Params -isnot [System.Collections.IDictionary]) {
        return New-McpProcessError -Parsed $parsed -Code -32602 -Message 'Invalid params: expected an object'
    }

    $response = $null
    try {
        switch -CaseSensitive -Wildcard ($parsed.Method) {
        'initialize' {
            $response = handle-initialize -Id $parsed.Id -Params $parsed.Params -Session $Session
            break
        }
        'notifications/initialized' {
            if ($parsed.IsNotification) {
                handle-initialized -Session $Session
            }
            else {
                $response = New-McpProcessError -Parsed $parsed -Code -32601 -Message 'Method not found: notifications/initialized'
            }
            break
        }
        'initialized' {
            if ($parsed.IsNotification) {
                handle-initialized -Session $Session
            }
            else {
                $response = New-McpProcessError -Parsed $parsed -Code -32601 -Message 'Method not found: initialized'
            }
            break
        }
        'ping' {
            $response = handle-ping -Id $parsed.Id
            break
        }
        'tools/list' {
            $response = handle-tools-list -Id $parsed.Id -Params $parsed.Params
            break
        }
        'tools/call' {
            $response = handle-tools-call -Id $parsed.Id -Params $parsed.Params
            break
        }
        'resources/list' {
            $response = handle-resources-list -Id $parsed.Id -Params $parsed.Params
            break
        }
        'resources/read' {
            $response = handle-resources-read -Id $parsed.Id -Params $parsed.Params
            break
        }
        'prompts/list' {
            $response = handle-prompts-list -Id $parsed.Id -Params $parsed.Params
            break
        }
        'prompts/get' {
            $response = handle-prompts-get -Id $parsed.Id -Params $parsed.Params
            break
        }
        default {
            $customRouter = Get-Command -Name 'Invoke-McpCustomMethod' -ErrorAction SilentlyContinue
            if ($null -ne $customRouter) {
                $response = & $customRouter -Id $parsed.Id -Method $parsed.Method -Params $parsed.Params -IsNotification $parsed.IsNotification
            }
            elseif ($parsed.HasId) {
                $response = New-McpProcessError -Parsed $parsed -Code -32601 -Message ("Method not found: {0}" -f $parsed.Method)
            }
        }
        }
    }
    catch {
        # A consumer failure must not terminate persistent stdio or detach an
        # HTTP error response from the request ID which caused it.
        if ($parsed.IsNotification) { return $null }
        return New-McpProcessError -Parsed $parsed -Code -32603 -Message 'Internal error'
    }

    if ($parsed.IsNotification -or $null -eq $response) { return $null }
    $responseJson = [string]$response
    if ($parsed.HasId -and $parsed.IdJson) {
        return Restore-McpResponseId -ResponseJson $responseJson -IdJson $parsed.IdJson
    }
    return $responseJson
}

# ============================================================================
# TRANSPORT: STDIO
# ============================================================================

# STREAMING STDIO IMPLEMENTATION
# ============================================================================

function Invoke-Mcp-Stdio-Server {
    [CmdletBinding()]
    param()

    $previousInputEncoding = [System.Console]::InputEncoding
    $previousOutputEncoding = [System.Console]::OutputEncoding
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.Console]::InputEncoding = $utf8
    [System.Console]::OutputEncoding = $utf8

    try {
        while ($true) {
            $line = [System.Console]::In.ReadLine()
            if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $response = process-mcp-line -line $line
            if ($null -ne $response -and -not [string]::IsNullOrEmpty([string]$response)) {
                [System.Console]::Out.WriteLine([string]$response)
                [System.Console]::Out.Flush()
            }
        }
    }
    finally {
        try {
            [System.Console]::InputEncoding = $previousInputEncoding
            [System.Console]::OutputEncoding = $previousOutputEncoding
        }
        catch {
            # Console handles may already be closed during process teardown.
        }
        Invoke-McpOnExit
    }
}

# ============================================================================
# TRANSPORT: STREAMABLE-HTTP (MCP 2025-03-26 specification)
# ============================================================================

# HARDENED STREAMABLE HTTP IMPLEMENTATION
# ============================================================================

function check-http-available {
    return $true
}

function extract-jsonrpc-from-post {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try { return $Body | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
}

function Test-McpHttpTruthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    return @('1', 'true', 'yes', 'on') -contains ([string]$Value).Trim().ToLowerInvariant()
}

function Test-McpLoopbackHost {
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $candidate = $HostName.Trim().TrimStart('[').TrimEnd(']')
    if ($candidate -eq 'localhost') { return $true }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($candidate, [ref]$address)) {
        return [System.Net.IPAddress]::IsLoopback($address)
    }
    return $false
}

function Test-McpHttpOrigin {
    param([string]$OriginHeader = '', [string[]]$AllowedOrigins = @())

    # Non-browser MCP clients normally omit Origin. Browser-originated requests
    # must be explicitly loopback or present in the additive allowlist.
    if ([string]::IsNullOrWhiteSpace($OriginHeader)) { return $true }
    if ($OriginHeader.Contains(',')) { return $false }
    $origin = $OriginHeader.Trim()
    if ($origin -eq 'null') { return $false }

    $uri = $null
    if (-not [System.Uri]::TryCreate($origin, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $false }
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $false }
    if ($uri.AbsolutePath -and $uri.AbsolutePath -ne '/') { return $false }
    if (Test-McpLoopbackHost -HostName $uri.Host) { return $true }

    $configured = @($AllowedOrigins)
    if (-not [string]::IsNullOrWhiteSpace($script:McpHttpAllowedOrigins)) {
        $configured += @($script:McpHttpAllowedOrigins -split '[,;]')
    }
    $actual = $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd('/')
    foreach ($entry in $configured) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $allowed = ([string]$entry).Trim()
        if ($allowed -eq '*') { return $true }
        if ($allowed.TrimEnd('/') -ieq $actual) { return $true }
    }
    return $false
}

function send-http-response {
    param(
        [string]$Response = '',
        [int]$StatusCode = 200,
        [string]$ContentType = 'application/json',
        [string]$SessionId = ''
    )

    $statusText = switch ($StatusCode) {
        200 { 'OK' }
        202 { 'Accepted' }
        204 { 'No Content' }
        400 { 'Bad Request' }
        403 { 'Forbidden' }
        404 { 'Not Found' }
        405 { 'Method Not Allowed' }
        406 { 'Not Acceptable' }
        413 { 'Payload Too Large' }
        500 { 'Internal Server Error' }
        default { 'OK' }
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($Response)
    $headers = [System.Collections.Generic.List[string]]::new()
    $headers.Add("HTTP/1.1 $StatusCode $statusText")
    if ($ContentType -and $bodyBytes -gt 0) { $headers.Add("Content-Type: $ContentType") }
    if (-not [string]::IsNullOrEmpty($SessionId)) { $headers.Add("Mcp-Session-Id: $SessionId") }
    $headers.Add('Cache-Control: no-cache')
    $headers.Add('Connection: close')
    $headers.Add("Content-Length: $bodyBytes")
    return (($headers -join "`r`n") + "`r`n`r`n" + $Response)
}

function send-http-sse-response {
    param([string]$ResponseJson, [int]$StatusCode = 200, [string]$SessionId = '')
    $sseBody = "event: message`ndata: $ResponseJson`n`n"
    return send-http-response -Response $sseBody -StatusCode $StatusCode -ContentType 'text/event-stream' -SessionId $SessionId
}

function New-McpHttpTransportError {
    param([int]$Code, [string]$Message, [int]$StatusCode, [string]$SessionId = '', $Parsed = $null)
    $payload = if ($null -ne $Parsed) {
        New-McpProcessError -Parsed $Parsed -Code $Code -Message $Message
    }
    else {
        json-response -Id $null -Error (mcp-error -Code $Code -Message $Message)
    }
    return send-http-response -Response $payload -StatusCode $StatusCode -ContentType 'application/json' -SessionId $SessionId
}

function Get-McpHttpSession {
    param([string]$SessionId)
    if ([string]::IsNullOrEmpty($SessionId)) { return $null }
    if ($script:McpSessions.ContainsKey($SessionId)) { return $script:McpSessions[$SessionId] }
    return $null
}

function New-McpHttpSession {
    $id = [guid]::NewGuid().ToString()
    $session = @{
        Id                 = $id
        InitializeReceived = $false
        Initialized        = $false
        CreatedUtc         = [DateTime]::UtcNow
    }
    $script:McpSessions.Add($id, $session)
    return $session
}

function Read-McpHttpBody {
    param(
        [System.IO.Stream]$InputStream,
        [int]$MaxBodyBytes,
        [System.Text.Encoding]$Encoding = [System.Text.Encoding]::UTF8,
        [long]$DeclaredLength = -1,
        [switch]$Chunked
    )

    if ($MaxBodyBytes -le 0) { throw 'MaxBodyBytes must be greater than zero.' }
    if ($DeclaredLength -lt -1) { throw 'DeclaredLength must be -1 (unknown) or a nonnegative byte count.' }
    if ($DeclaredLength -gt $MaxBodyBytes) {
        return @{ Body = ''; TooLarge = $true; Truncated = $false; BytesRead = 0 }
    }

    $memory = [System.IO.MemoryStream]::new()
    $buffer = [byte[]]::new(8192)
    try {
        if ($DeclaredLength -ge 0 -and -not $Chunked.IsPresent) {
            # A declared body is complete only after exactly Content-Length bytes.
            # Do not probe past the declaration: an exact-limit body is valid.
            while ($memory.Length -lt $DeclaredLength) {
                $remaining = $DeclaredLength - [long]$memory.Length
                $toRead = [int][Math]::Min([long]$buffer.Length, $remaining)
                $read = $InputStream.Read($buffer, 0, $toRead)
                if ($read -le 0) {
                    return @{ Body = ''; TooLarge = $false; Truncated = $true; BytesRead = [long]$memory.Length }
                }
                $memory.Write($buffer, 0, $read)
            }
        }
        else {
            # Chunked and unknown-length bodies are decoded by HttpListener. Read
            # through the terminating chunk/EOF, but never buffer more than the
            # configured limit plus the single byte needed to detect overflow.
            while ($true) {
                $remaining = [long]$MaxBodyBytes - [long]$memory.Length
                $toRead = [int][Math]::Min([long]$buffer.Length, $remaining + 1)
                $read = $InputStream.Read($buffer, 0, $toRead)
                if ($read -le 0) { break }
                if ($read -gt $remaining) {
                    return @{ Body = ''; TooLarge = $true; Truncated = $false; BytesRead = [long]$memory.Length + $read }
                }
                $memory.Write($buffer, 0, $read)
            }
        }

        return @{
            Body      = $Encoding.GetString($memory.ToArray())
            TooLarge  = $false
            Truncated = $false
            BytesRead = [long]$memory.Length
        }
    }
    catch [System.Text.DecoderFallbackException] {
        return @{ Body = ''; TooLarge = $false; Truncated = $false; InvalidEncoding = $true; BytesRead = [long]$memory.Length }
    }
    catch [System.IO.IOException] {
        return @{ Body = ''; TooLarge = $false; Truncated = $true; BytesRead = [long]$memory.Length }
    }
    catch [System.Net.HttpListenerException] {
        return @{ Body = ''; TooLarge = $false; Truncated = $true; BytesRead = [long]$memory.Length }
    }
    finally {
        $memory.Dispose()
    }
}

function handle-http-post {
    param(
        [string]$Body,
        [string]$AcceptHeader = 'application/json, text/event-stream',
        [string]$SessionIdHeader = '',
        [string]$OriginHeader = '',
        [string[]]$AllowedOrigins = @(),
        [int]$MaxBodyBytes = $script:McpHttpMaxBodyBytes
    )

    if (-not (Test-McpHttpOrigin -OriginHeader $OriginHeader -AllowedOrigins $AllowedOrigins)) {
        return New-McpHttpTransportError -Code -32600 -Message 'Forbidden Origin' -StatusCode 403
    }
    if ($MaxBodyBytes -le 0) { throw 'MaxBodyBytes must be greater than zero.' }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Body) -gt $MaxBodyBytes) {
        return New-McpHttpTransportError -Code -32600 -Message 'Request body too large' -StatusCode 413
    }

    $parsed = mcp-parse-message -Message $Body
    if (-not $parsed.Valid) {
        $message = if ($parsed.IsBatch) { 'Invalid Request: batch requests are not supported' } elseif ($parsed.ErrorCode -eq -32600) { 'Invalid Request' } else { 'Parse error' }
        $payload = json-response -Id $null -Error (mcp-error -Code $parsed.ErrorCode -Message $message)
        return send-http-response -Response $payload -StatusCode 400 -ContentType 'application/json' -SessionId ''
    }
    if ($parsed.JsonRpc -cne '2.0' -or [string]::IsNullOrEmpty($parsed.Method)) {
        $payload = process-mcp-line -line $Body
        return send-http-response -Response $payload -StatusCode 400 -ContentType 'application/json' -SessionId ''
    }

    $session = $null
    $responseSessionId = ''
    $isInitialize = $parsed.Method -ceq 'initialize'
    $isInitializedNotification = $parsed.Method -ceq 'notifications/initialized' -or $parsed.Method -ceq 'initialized'

    if ($isInitialize) {
        # MCP initialize is a request, not a notification. Never allocate server
        # state for a message which cannot receive the initialize result.
        if (-not $parsed.HasId) {
            return send-http-response -Response '' -StatusCode 400 -ContentType '' -SessionId ''
        }
        if (-not [string]::IsNullOrEmpty($SessionIdHeader)) {
            if ($null -eq (Get-McpHttpSession -SessionId $SessionIdHeader)) {
                return New-McpHttpTransportError -Code -32600 -Message 'Invalid or expired Mcp-Session-Id' -StatusCode 404 -Parsed $parsed
            }
            return New-McpHttpTransportError -Code -32600 -Message 'Session already initialized' -StatusCode 400 -SessionId $SessionIdHeader -Parsed $parsed
        }
        $session = New-McpHttpSession
        $responseSessionId = [string]$session.Id
    }
    else {
        if ([string]::IsNullOrEmpty($SessionIdHeader)) {
            if ($parsed.IsNotification) {
                return send-http-response -Response '' -StatusCode 400 -ContentType '' -SessionId ''
            }
            $payload = New-McpProcessError -Parsed $parsed -Code -32600 -Message 'Missing Mcp-Session-Id'
            return send-http-response -Response $payload -StatusCode 400 -ContentType 'application/json' -SessionId ''
        }
        $session = Get-McpHttpSession -SessionId $SessionIdHeader
        if ($null -eq $session) {
            if ($parsed.IsNotification) {
                return send-http-response -Response '' -StatusCode 404 -ContentType '' -SessionId ''
            }
            return New-McpHttpTransportError -Code -32600 -Message 'Invalid or expired Mcp-Session-Id' -StatusCode 404 -Parsed $parsed
        }
        $responseSessionId = [string]$session.Id
        if (-not $isInitializedNotification -and $parsed.Method -cne 'ping' -and -not $session.Initialized) {
            if ($parsed.IsNotification) {
                return send-http-response -Response '' -StatusCode 400 -ContentType '' -SessionId $responseSessionId
            }
            $payload = New-McpProcessError -Parsed $parsed -Code -32600 -Message 'Session is not initialized'
            return send-http-response -Response $payload -StatusCode 400 -ContentType 'application/json' -SessionId $responseSessionId
        }
    }

    try {
        # This is the only path which mutates InitializeReceived/Initialized.
        # A session object is passed explicitly; no global current-session state
        # can leak between independent HTTP clients.
        $respPayload = process-mcp-line -line $Body -Session $session
    }
    catch {
        if ($isInitialize) { [void]$script:McpSessions.Remove($responseSessionId) }
        throw
    }

    if ($isInitialize) {
        $initializationFailed = [string]::IsNullOrEmpty([string]$respPayload)
        if (-not $initializationFailed) {
            try {
                $responseObject = $respPayload | ConvertFrom-Json -ErrorAction Stop
                $initializationFailed = @($responseObject.PSObject.Properties.Name) -ccontains 'error'
            }
            catch {
                $initializationFailed = $true
            }
        }
        if ($initializationFailed) {
            [void]$script:McpSessions.Remove($responseSessionId)
            $responseSessionId = ''
        }
    }

    if ([string]::IsNullOrEmpty([string]$respPayload)) {
        return send-http-response -Response '' -StatusCode 202 -ContentType '' -SessionId $responseSessionId
    }
    if ($AcceptHeader -like '*text/event-stream*' -and $AcceptHeader -notlike '*application/json*') {
        return send-http-sse-response -ResponseJson $respPayload -StatusCode 200 -SessionId $responseSessionId
    }
    return send-http-response -Response $respPayload -StatusCode 200 -ContentType 'application/json' -SessionId $responseSessionId
}

function handle-http-get {
    param(
        [string]$AcceptHeader = '',
        [string]$SessionIdHeader = '',
        [string]$OriginHeader = '',
        [string[]]$AllowedOrigins = @()
    )
    if (-not (Test-McpHttpOrigin -OriginHeader $OriginHeader -AllowedOrigins $AllowedOrigins)) {
        return New-McpHttpTransportError -Code -32600 -Message 'Forbidden Origin' -StatusCode 403
    }
    if ([string]::IsNullOrEmpty($SessionIdHeader)) {
        return New-McpHttpTransportError -Code -32600 -Message 'Missing Mcp-Session-Id' -StatusCode 400
    }
    $session = Get-McpHttpSession -SessionId $SessionIdHeader
    if ($null -eq $session) {
        return New-McpHttpTransportError -Code -32600 -Message 'Invalid or expired Mcp-Session-Id' -StatusCode 404
    }
    if (-not $session.Initialized) {
        return New-McpHttpTransportError -Code -32600 -Message 'Session is not initialized' -StatusCode 400 -SessionId $SessionIdHeader
    }
    if ($AcceptHeader -like '*text/event-stream*') {
        return send-http-response -Response ": streamable-http sse stream open`n`n" -StatusCode 200 -ContentType 'text/event-stream' -SessionId $SessionIdHeader
    }
    return send-http-response -Response '' -StatusCode 405 -ContentType 'text/plain' -SessionId $SessionIdHeader
}

function handle-http-delete {
    param(
        [string]$SessionIdHeader = '',
        [string]$OriginHeader = '',
        [string[]]$AllowedOrigins = @()
    )
    if (-not (Test-McpHttpOrigin -OriginHeader $OriginHeader -AllowedOrigins $AllowedOrigins)) {
        return New-McpHttpTransportError -Code -32600 -Message 'Forbidden Origin' -StatusCode 403
    }
    if ([string]::IsNullOrEmpty($SessionIdHeader)) {
        return New-McpHttpTransportError -Code -32600 -Message 'Missing Mcp-Session-Id' -StatusCode 400
    }
    $session = Get-McpHttpSession -SessionId $SessionIdHeader
    if ($null -eq $session) {
        return New-McpHttpTransportError -Code -32600 -Message 'Invalid or expired Mcp-Session-Id' -StatusCode 404
    }

    [void]$script:McpSessions.Remove($SessionIdHeader)
    return send-http-response -Response '' -StatusCode 200 -ContentType 'text/plain' -SessionId ''
}

function Write-McpHttpListenerResponse {
    param([System.Net.HttpListenerResponse]$Response, [string]$RawResponse)

    $split = $RawResponse.IndexOf("`r`n`r`n")
    if ($split -lt 0) { throw 'Invalid internal HTTP response.' }
    $headerText = $RawResponse.Substring(0, $split)
    $body = $RawResponse.Substring($split + 4)
    $lines = $headerText -split "`r`n"
    if ($lines[0] -match '^HTTP/1\.1\s+(\d{3})') { $Response.StatusCode = [int]$Matches[1] }

    $contentType = ''
    foreach ($line in $lines[1..($lines.Length - 1)]) {
        if ($line -notmatch '^([^:]+):\s*(.*)$') { continue }
        $name = $Matches[1]
        $value = $Matches[2]
        if ($name -ieq 'Content-Type') { $contentType = $value }
        elseif ($name -ieq 'Mcp-Session-Id') { $Response.Headers['Mcp-Session-Id'] = $value }
        elseif ($name -ieq 'Cache-Control') { $Response.Headers['Cache-Control'] = $value }
    }
    if ($contentType) { $Response.ContentType = $contentType }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $Response.ContentLength64 = $bytes.Length
    $Response.KeepAlive = $false
    if ($bytes.Length -gt 0) { $Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $Response.OutputStream.Flush()
}

function Invoke-Mcp-StreamableHttp-Server {
    param(
        [string]$HostName = $script:McpHttpHost,
        [int]$Port = $script:McpHttpPort,
        [string]$Endpoint = $script:McpHttpEndpoint,
        [int]$MaxRequests = 0,
        [string[]]$AllowedOrigins = @(),
        [switch]$AllowNonLoopback,
        [int]$MaxBodyBytes = $script:McpHttpMaxBodyBytes
    )

    if ($MaxBodyBytes -le 0) { throw 'MaxBodyBytes must be greater than zero.' }
    $remoteAllowed = $AllowNonLoopback.IsPresent -or (Test-McpHttpTruthy $script:McpHttpAllowNonLoopback)
    if (-not (Test-McpLoopbackHost -HostName $HostName) -and -not $remoteAllowed) {
        throw 'Refusing non-loopback HTTP binding. Use -AllowNonLoopback or MCP_HTTP_ALLOW_NON_LOOPBACK=1 only after adding appropriate external security controls.'
    }
    if (-not $Endpoint.StartsWith('/')) { $Endpoint = "/$Endpoint" }
    $prefixPath = if ($Endpoint.EndsWith('/')) { $Endpoint } else { "$Endpoint/" }
    $prefixHost = $HostName
    if ($prefixHost.Contains(':') -and -not $prefixHost.StartsWith('[')) { $prefixHost = "[$prefixHost]" }

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add(('http://{0}:{1}{2}' -f $prefixHost, $Port, $prefixPath))
    $script:McpHttpListener = $listener

    try {
        $listener.Start()
        $count = 0
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $req = $context.Request
            $res = $context.Response
            try {
                $httpMethod = $req.HttpMethod.ToUpperInvariant()
                $acceptHeader = if ($req.Headers['Accept']) { $req.Headers['Accept'] } else { 'application/json' }
                $sessionHeader = if ($req.Headers['Mcp-Session-Id']) { $req.Headers['Mcp-Session-Id'] } else { '' }
                $originHeader = if ($req.Headers['Origin']) { $req.Headers['Origin'] } else { '' }

                if (-not (Test-McpHttpOrigin -OriginHeader $originHeader -AllowedOrigins $AllowedOrigins)) {
                    $raw = New-McpHttpTransportError -Code -32600 -Message 'Forbidden Origin' -StatusCode 403
                }
                else {
                    switch ($httpMethod) {
                        'POST' {
                            $contentLengthValues = @($req.Headers.GetValues('Content-Length'))
                            $hasContentLength = $contentLengthValues.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$contentLengthValues[0])
                            $transferEncoding = [string]$req.Headers['Transfer-Encoding']
                            $hasTransferEncoding = -not [string]::IsNullOrWhiteSpace($transferEncoding)
                            $chunked = $hasTransferEncoding -and $transferEncoding.Trim() -ieq 'chunked'
                            $declaredLength = [long]-1
                            $invalidFraming = $hasContentLength -and $hasTransferEncoding

                            if ($hasTransferEncoding -and -not $chunked) { $invalidFraming = $true }
                            if ($hasContentLength) {
                                if ($contentLengthValues.Count -ne 1 -or [string]$contentLengthValues[0] -notmatch '^\s*[0-9]+\s*$') {
                                    $invalidFraming = $true
                                }
                                elseif (-not [long]::TryParse($contentLengthValues[0].Trim(), [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$declaredLength)) {
                                    $invalidFraming = $true
                                }
                            }
                            elseif (-not $hasTransferEncoding) {
                                # HttpListener supplies zero for a normal empty body. If no
                                # framing is present, do not treat a missing body as chunked.
                                $declaredLength = if ($req.ContentLength64 -ge 0) { [long]$req.ContentLength64 } else { [long]0 }
                            }

                            if ($invalidFraming) {
                                $raw = New-McpHttpTransportError -Code -32600 -Message 'Invalid HTTP request framing' -StatusCode 400
                            }
                            elseif ($declaredLength -gt $MaxBodyBytes) {
                                $raw = New-McpHttpTransportError -Code -32600 -Message 'Request body too large' -StatusCode 413
                            }
                            else {
                                $readResult = Read-McpHttpBody -InputStream $req.InputStream -MaxBodyBytes $MaxBodyBytes -Encoding ([System.Text.UTF8Encoding]::new($false, $true)) -DeclaredLength $declaredLength -Chunked:$chunked
                                if ($readResult.TooLarge) {
                                    $raw = New-McpHttpTransportError -Code -32600 -Message 'Request body too large' -StatusCode 413
                                }
                                elseif ($readResult.Truncated) {
                                    $raw = New-McpHttpTransportError -Code -32600 -Message 'Incomplete request body' -StatusCode 400
                                }
                                elseif ($readResult.ContainsKey('InvalidEncoding') -and $readResult.InvalidEncoding) {
                                    $raw = New-McpHttpTransportError -Code -32700 -Message 'Parse error' -StatusCode 400
                                }
                                else {
                                    $raw = handle-http-post -Body $readResult.Body -AcceptHeader $acceptHeader -SessionIdHeader $sessionHeader -OriginHeader $originHeader -AllowedOrigins $AllowedOrigins -MaxBodyBytes $MaxBodyBytes
                                }
                            }
                            break
                        }
                        'GET' {
                            $raw = handle-http-get -AcceptHeader $acceptHeader -SessionIdHeader $sessionHeader -OriginHeader $originHeader -AllowedOrigins $AllowedOrigins
                            break
                        }
                        'DELETE' {
                            $raw = handle-http-delete -SessionIdHeader $sessionHeader -OriginHeader $originHeader -AllowedOrigins $AllowedOrigins
                            break
                        }
                        default {
                            $raw = send-http-response -Response '' -StatusCode 405 -ContentType 'text/plain' -SessionId ''
                        }
                    }
                }
                Write-McpHttpListenerResponse -Response $res -RawResponse $raw
            }
            catch {
                try {
                    if ($res.OutputStream.CanWrite) {
                        $raw = New-McpHttpTransportError -Code -32603 -Message 'Internal error' -StatusCode 500
                        Write-McpHttpListenerResponse -Response $res -RawResponse $raw
                    }
                }
                catch {
                    # HTTP.sys can reject malformed/truncated framing and submit its
                    # own response before the SDK writes one. Client disconnects can
                    # likewise make the response unavailable. Either way, keep the
                    # listener alive so one client failure cannot stop the server.
                }
            }
            finally {
                try { $res.OutputStream.Close() } catch { }
                try { $res.Close() } catch { }
            }

            $count++
            if ($MaxRequests -gt 0 -and $count -ge $MaxRequests) { break }
        }
    }
    finally {
        Invoke-McpOnExit
    }
}

# ============================================================================
# TRANSPORT MODE DETECTION & ENTRY POINT
# ============================================================================

function get-transport-mode {
    if (-not [string]::IsNullOrEmpty($env:MCP_TRANSPORT)) {
        return $env:MCP_TRANSPORT
    }
    return 'stdio'
}

Set-Alias -Name 'route-mcp-message' -Value 'process-mcp-line'

# ENTRY POINT IMPLEMENTATION
# ============================================================================

function Start-McpServer {
    [CmdletBinding()]
    param(
        [string]$Transport = (get-transport-mode),
        [string]$HostName = $script:McpHttpHost,
        [int]$Port = $script:McpHttpPort,
        [string]$Endpoint = $script:McpHttpEndpoint,
        [string[]]$AllowedOrigins = @(),
        [switch]$AllowNonLoopback,
        [int]$MaxBodyBytes = $script:McpHttpMaxBodyBytes,
        [int]$MaxRequests = 0
    )

    switch ($Transport) {
        'http' {
            Invoke-Mcp-StreamableHttp-Server -HostName $HostName -Port $Port -Endpoint $Endpoint -AllowedOrigins $AllowedOrigins -AllowNonLoopback:$AllowNonLoopback -MaxBodyBytes $MaxBodyBytes -MaxRequests $MaxRequests
            break
        }
        'streamable-http' {
            Invoke-Mcp-StreamableHttp-Server -HostName $HostName -Port $Port -Endpoint $Endpoint -AllowedOrigins $AllowedOrigins -AllowNonLoopback:$AllowNonLoopback -MaxBodyBytes $MaxBodyBytes -MaxRequests $MaxRequests
            break
        }
        default {
            Invoke-Mcp-Stdio-Server
        }
    }
}

# ============================================================================
Export-ModuleMember -Function @(
    'Set-McpServerInfo',
    'Register-McpCleanup',
    'Close-McpConnection',
    'Invoke-McpOnExit',
    'ConvertTo-McpHashtable',
    'json-response',
    'mcp-error',
    'New-McpToolResult',
    'mcp-parse-message',
    'handle-initialize',
    'handle-initialized',
    'handle-ping',
    'handle-tools-list',
    'handle-tools-call',
    'handle-resources-list',
    'handle-resources-read',
    'handle-prompts-list',
    'handle-prompts-get',
    'process-mcp-line',
    'Invoke-Mcp-Stdio-Server',
    'check-http-available',
    'extract-jsonrpc-from-post',
    'send-http-response',
    'send-http-sse-response',
    'handle-http-post',
    'handle-http-get',
    'handle-http-delete',
    'Invoke-Mcp-StreamableHttp-Server',
    'get-transport-mode',
    'Start-McpServer'
) -Alias @(
    'New-JsonResponse',
    'mcp-on-exit',
    'mcp-close-connection',
    'mcp-register-cleanup',
    'route-mcp-message'
)

