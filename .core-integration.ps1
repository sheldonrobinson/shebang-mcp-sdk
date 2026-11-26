Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'bin/mcp-sdk.psm1') -Force -WarningAction SilentlyContinue
$module = Get-Module mcp-sdk
$script:Checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
    $script:Checks++
}
function Json($Text) { return $Text | ConvertFrom-Json -ErrorAction Stop }
function PropertyNames($Object) { return @($Object.PSObject.Properties.Name) }
function Call([string]$Text) { return process-mcp-line -line $Text }
function HttpParts([string]$Raw) {
    $at = $Raw.IndexOf("`r`n`r`n")
    Assert ($at -ge 0) 'HTTP response has header/body separator'
    $head = $Raw.Substring(0, $at)
    $status = [int]([regex]::Match($head, '^HTTP/1\.1 (\d{3})').Groups[1].Value)
    $session = [regex]::Match($head, '(?im)^Mcp-Session-Id:\s*([^\r\n]+)').Groups[1].Value
    $contentType = [regex]::Match($head, '(?im)^Content-Type:\s*([^\r\n]+)').Groups[1].Value
    return @{ Status = $status; Session = $session; ContentType = $contentType; Body = $Raw.Substring($at + 4); Head = $head }
}
function InitMessage([int]$Id = 1) {
    return '{"jsonrpc":"2.0","id":' + $Id + ',"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"integration","version":"1"}}}'
}

# JSON-RPC envelope, raw ID restoration, and notification behavior.
$r = Json (Call '{"jsonrpc":"2.0","id":42,"method":"ping"}')
Assert ($r.id -eq 42 -and $r.id -isnot [string]) 'numeric ID remains numeric'
$r = Json (Call '{"jsonrpc":"2.0","id":"42","method":"ping"}')
Assert ($r.id -ceq '42' -and $r.id -is [string]) 'numeric-string ID remains a string'
$raw = Call '{"jsonrpc":"2.0","id":1234567890123456789012345678901234567890,"method":"ping"}'
Assert ($raw -match '"id":1234567890123456789012345678901234567890') 'out-of-range numeric ID is preserved'
$raw = Call '{"jsonrpc":"2.0","id":"a\u0062","method":"ping"}'
Assert ((Json $raw).id -ceq 'ab') 'escaped string ID retains its value'
$r = Json (Call '{"jsonrpc":"2.0","id":null,"method":"ping"}')
Assert ($null -eq $r.id -and (PropertyNames $r) -ccontains 'id') 'explicit null ID is returned'
Assert ((Json (json-response -Id 1 -Result $false)).result -eq $false) 'false result is preserved'
Assert ((Json (json-response -Id 1 -Result 0)).result -eq 0) 'zero result is preserved'
Assert ($null -eq (Json (json-response -Id 1 -Result 'null')).result) 'JSON null result is preserved'
Assert ((json-response -Id 1 -Result '[]') -match '"result":\[\]') 'empty array result is preserved'
Assert (@((Json (json-response -Id 1 -Result '[1,2]')).result).Count -eq 2) 'non-empty array result is preserved'
Assert ($null -eq (Call '{"jsonrpc":"2.0","method":"tools/list"}')) 'valid notification is silent'
Assert ($null -eq (Call '{"jsonrpc":"2.0","method":"unknown/method"}')) 'unknown notification is silent'
Assert ($null -eq (Call '{"jsonrpc":"1.0","method":"unknown/method"}')) 'invalid-version notification is silent'
Assert ($null -eq (Call '{"jsonrpc":"2.0","method":"tools/list","params":[]}')) 'invalid-params notification is silent'
Assert ($null -eq (Call '')) 'empty stdio line is silent'
Assert ((Json (Call '{')).error.code -eq -32700) 'malformed JSON returns parse error'
Assert ((Json (Call '42')).error.code -eq -32600) 'scalar JSON returns invalid request'
Assert ((Json (Call '[]')).error.code -eq -32600) 'unsupported batch returns invalid request'
Assert ((Json (Call '{"jsonrpc":"1.0","id":8,"method":"ping"}')).error.code -eq -32600) 'wrong JSON-RPC version rejected'
Assert ((Json (Call '{"jsonrpc":"2.0","id":8,"method":"ping","params":[]}')).error.code -eq -32602) 'non-object params rejected'
Assert ((Json (Call '{"jsonrpc":"2.0","id":8,"method":"TOOLS/LIST"}')).error.code -eq -32601) 'method dispatch is case-sensitive'
Assert ((Json (Call '{"jsonrpc":"2.0","id":7,"method":"notifications/initialized"}')).error.code -eq -32601) 'ID-bearing initialized method receives an error'
Assert ((Json (Call '{"jsonrpc":"2.0","id":7,"method":"notifications/other"}')).error.code -eq -32601) 'ID-bearing notification-named method receives an error'
Assert ((Json (Call '{"jsonrpc":"2.0","id":8,"method":"resources/list"}')).error.code -eq -32601) 'unimplemented resources/list is method-not-found'
Assert ((Json (Call '{"jsonrpc":"2.0","id":8,"method":"prompts/get"}')).error.code -eq -32601) 'unimplemented prompts/get is method-not-found'

# Consumer callbacks and Params forwarding.
function global:Handle-ListTools { param($Id, $Params) return json-response -Id $Id -Result (@{ marker = $Params['marker']; tools = @() }) }
function global:Handle-ListResources { param($Id, $Params) return json-response -Id $Id -Result (@{ resources = @(); marker = $Params['marker'] }) }
function global:Handle-ReadResource { param($Id, $Params) return json-response -Id $Id -Result (@{ contents = @(); uri = $Params['uri'] }) }
function global:Handle-ListPrompts { param($Id, $Params) return json-response -Id $Id -Result (@{ prompts = @(); marker = $Params['marker'] }) }
function global:Handle-GetPrompt { param($Id, $Params) return json-response -Id $Id -Result (@{ messages = @(); name = $Params['name'] }) }
$r = Json (Call '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"marker":"tools-ok"}}')
Assert ($r.result.marker -ceq 'tools-ok') 'tools Params forwarded'
$r = Json (Call (InitMessage 10))
Assert ((PropertyNames $r.result.capabilities) -ccontains 'resources') 'resources capability is conditional and enabled'
Assert ((PropertyNames $r.result.capabilities) -ccontains 'prompts') 'prompts capability is conditional and enabled'
Assert ((Json (Call '{"jsonrpc":"2.0","id":11,"method":"resources/list","params":{"marker":"resources-ok"}}')).result.marker -ceq 'resources-ok') 'resources/list route and Params'
Assert ((Json (Call '{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"file:///a"}}')).result.uri -ceq 'file:///a') 'resources/read route and Params'
Assert ((Json (Call '{"jsonrpc":"2.0","id":13,"method":"prompts/list","params":{"marker":"prompts-ok"}}')).result.marker -ceq 'prompts-ok') 'prompts/list route and Params'
Assert ((Json (Call '{"jsonrpc":"2.0","id":14,"method":"prompts/get","params":{"name":"p"}}')).result.name -ceq 'p') 'prompts/get route and Params'
function global:Handle-ListPrompts { param($Id, $Params) throw 'consumer failure' }
$raw = Call '{"jsonrpc":"2.0","id":98765432101234567890,"method":"prompts/list"}'
Assert ($raw -match '"id":98765432101234567890' -and $raw -match '"code":-32603') 'consumer exception preserves raw request ID'
Assert ((Json (Call '{"jsonrpc":"2.0","id":15,"method":"prompts/list"}')).error.code -eq -32603) 'consumer exception becomes internal error'
Assert ($null -eq (Call '{"jsonrpc":"2.0","method":"prompts/list"}')) 'throwing consumer notification remains silent'

# Strict in-memory body reads, including exact limits and truncation.
$readResults = & $module {
    $a = [System.Text.Encoding]::UTF8.GetBytes('12345')
    $exact = New-Object System.IO.MemoryStream(,$a)
    $r1 = Read-McpHttpBody -InputStream $exact -MaxBodyBytes 5 -DeclaredLength 5
    $short = New-Object System.IO.MemoryStream(,$a)
    $r2 = Read-McpHttpBody -InputStream $short -MaxBodyBytes 6 -DeclaredLength 6
    $overDeclared = New-Object System.IO.MemoryStream(,$a)
    $r3 = Read-McpHttpBody -InputStream $overDeclared -MaxBodyBytes 4 -DeclaredLength 5
    $chunkExact = New-Object System.IO.MemoryStream(,$a)
    $r4 = Read-McpHttpBody -InputStream $chunkExact -MaxBodyBytes 5 -Chunked
    $chunkOver = New-Object System.IO.MemoryStream(,$a)
    $r5 = Read-McpHttpBody -InputStream $chunkOver -MaxBodyBytes 4 -Chunked
    return @($r1, $r2, $r3, $r4, $r5)
}
Assert ($readResults[0].Body -ceq '12345' -and -not $readResults[0].Truncated -and -not $readResults[0].TooLarge) 'declared exact-limit body succeeds'
Assert ($readResults[1].Truncated -and $readResults[1].BytesRead -eq 5) 'truncated declared body is detected'
Assert ($readResults[2].TooLarge) 'oversize declared body is rejected before reading'
Assert ($readResults[3].Body -ceq '12345' -and -not $readResults[3].TooLarge) 'chunked exact-limit body succeeds'
Assert ($readResults[4].TooLarge) 'chunked overflow is detected'

# Handler-level streamable HTTP lifecycle and independent sessions.
Close-McpConnection  # isolate HTTP checks from the direct stdio initialize above
$h = HttpParts (handle-http-post -Body (InitMessage 1))
Assert ($h.Status -eq 200 -and $h.Session) 'initialize returns HTTP 200 and a session'
$sessionA = $h.Session
Assert (-not [string]::IsNullOrEmpty([string](Json $h.Body).result.serverInfo.name)) 'initialize response is JSON-RPC result'
$h = HttpParts (handle-http-post -Body (InitMessage 2))
$sessionB = $h.Session
Assert ($h.Status -eq 200 -and $sessionB -and $sessionB -cne $sessionA) 'second client gets an independent session'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' -SessionIdHeader $sessionA)
Assert ($h.Status -eq 400 -and (Json $h.Body).error.message -match 'not initialized') 'request before initialized is rejected'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/cancelled"}' -SessionIdHeader $sessionA)
Assert ($h.Status -eq 400 -and $h.Body -eq '') 'pre-initialization notification rejection has no JSON-RPC body'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/cancelled"}')
Assert ($h.Status -eq 400 -and $h.Body -eq '') 'missing-session notification rejection has no JSON-RPC body'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/cancelled"}' -SessionIdHeader 'wrong-session')
Assert ($h.Status -eq 404 -and $h.Body -eq '') 'unknown-session notification rejection has no JSON-RPC body'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":4,"method":"ping"}' -SessionIdHeader $sessionA)
Assert ($h.Status -eq 200 -and $h.Session -ceq $sessionA) 'ping is allowed before initialized'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}')
Assert ($h.Status -eq 400) 'initialized requires a session'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -SessionIdHeader 'wrong-session')
Assert ($h.Status -eq 404) 'wrong session is rejected'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -SessionIdHeader $sessionA)
Assert ($h.Status -eq 202 -and $h.Body -eq '' -and $h.Session -ceq $sessionA) 'initialized notification returns empty 202'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{"marker":"A"}}' -SessionIdHeader $sessionA)
Assert ($h.Status -eq 200 -and (Json $h.Body).result.marker -ceq 'A') 'initialized session A can call methods'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":6,"method":"tools/list"}' -SessionIdHeader $sessionB)
Assert ($h.Status -eq 400) 'session A initialization does not initialize B'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"notifications/initialized"}' -SessionIdHeader $sessionB)
Assert ($h.Status -eq 202) 'session B initializes independently'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"marker":"B"}}' -SessionIdHeader $sessionB)
Assert ($h.Status -eq 200 -and (Json $h.Body).result.marker -ceq 'B') 'initialized session B can call methods'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":23,"method":"prompts/list"}' -SessionIdHeader $sessionB)
Assert ($h.Status -eq 200 -and (Json $h.Body).error.code -eq -32603 -and (Json $h.Body).id -eq 23) 'HTTP consumer exception preserves request ID'
$states = & $module { param($a, $b) return @($script:McpSessions[$a].Initialized, $script:McpSessions[$b].Initialized, $script:McpInitialized) } $sessionA $sessionB
Assert ($states[0] -and $states[1] -and -not $states[2]) 'HTTP lifecycle does not mutate stdio global state'
$h = HttpParts (handle-http-post -Body (InitMessage 15) -SessionIdHeader $sessionA)
Assert ($h.Status -eq 400) 'initialize cannot reuse an active session'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","method":"initialize","params":{}}')
Assert ($h.Status -eq 400 -and -not $h.Session -and $h.Body -eq '') 'initialize notification allocates no session and has no JSON-RPC body'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":16,"method":"initialize","params":[]}')
Assert ($h.Status -eq 200 -and (Json $h.Body).error.code -eq -32602 -and -not $h.Session) 'failed initialize response rolls back session header'
$h = HttpParts (handle-http-post -Body (InitMessage 17) -MaxBodyBytes 10)
Assert ($h.Status -eq 413) 'handler enforces body limit'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":18,"method":"ping"}' -SessionIdHeader $sessionA -OriginHeader 'https://evil.example')
Assert ($h.Status -eq 403) 'untrusted Origin is rejected'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":19,"method":"ping"}' -SessionIdHeader $sessionA -OriginHeader 'https://trusted.example' -AllowedOrigins @('https://trusted.example'))
Assert ($h.Status -eq 200) 'explicit Origin allowlist is honored'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":20,"method":"ping"}' -SessionIdHeader $sessionA -AcceptHeader 'text/event-stream')
Assert ($h.Status -eq 200 -and $h.ContentType -match '^text/event-stream' -and $h.Body -match 'data: ') 'SSE-only Accept receives SSE response'
$h = HttpParts (handle-http-get -SessionIdHeader $sessionA -AcceptHeader 'text/event-stream')
Assert ($h.Status -eq 200 -and $h.ContentType -match '^text/event-stream') 'initialized session can open GET SSE stream'
$h = HttpParts (handle-http-delete -SessionIdHeader $sessionA)
Assert ($h.Status -eq 200) 'DELETE terminates selected session'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":21,"method":"ping"}' -SessionIdHeader $sessionA)
Assert ($h.Status -eq 404) 'deleted session cannot be reused'
$h = HttpParts (handle-http-post -Body '{"jsonrpc":"2.0","id":22,"method":"ping"}' -SessionIdHeader $sessionB)
Assert ($h.Status -eq 200) 'DELETE does not terminate another session'

Remove-Module mcp-sdk -Force
"CORE_INTEGRATION_OK checks=$script:Checks"
