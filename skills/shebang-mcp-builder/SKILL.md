---
name: shebang-mcp-builder
description: "Shebang MCP Builder Skill — the Model Context Protocol (MCP) SDK for shell environments (POSIX sh/Bash & PowerShell), analogous to python-sdk for Python and @modelcontextprotocol/sdk for TypeScript. Contains NO application-specific logic — consumers override tool handlers via global functions. Integrates with the MCP Builder Skill for building production MCP servers."
license: MIT
compatibility: Windows requires PowerShell 5.1+ or pwsh 7+. Linux/macOS requires Bash 4+, jq, and socat or nc (for streamable-http).
metadata:
  author: sheldonrobinson
  author-email: sheldon.robinson@gmail.com
  author-url: https://github.com/sheldonrobinson
  version: "1.0.0"
  homepage: https://sheldonrobinson.github.io/shebang-mcp-sdk
  repository: https://github.com/sheldonrobinson/shebang-mcp-sdk
---

# Shebang MCP SDK

> The **Model Context Protocol (MCP) SDK for shell environments** — POSIX sh/Bash (Linux/macOS) and PowerShell (Windows). Analogous to [`python-sdk`](https://github.com/modelcontextprotocol/python-sdk) for Python and [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk) for TypeScript. Implements the core MCP specification over stdio and streamable-http transports. Contains NO application-specific logic — consumers extend by defining global handler functions.

## Installation (Canonical `.agents/skills/` Path)

Per the [Agent Skills Specification](https://agentskills.io/specification), install this skill to the canonical cross-client `.agents/skills/` directory so any Agent Skills-compatible client discovers it automatically:

- **Project-level install (`<project>/.agents/skills/shebang-mcp-builder/`):**
  ```bash
  mkdir -p .agents/skills
  cp -R skills/shebang-mcp-builder .agents/skills/shebang-mcp-builder
  ```
  ```powershell
  New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
  Copy-Item -Recurse -Force skills/shebang-mcp-builder .agents/skills/shebang-mcp-builder
  ```

## 1. Platform Selection Rules (Windows vs. Linux/macOS)

The SDK implementation is **OS-specific**:
- **Linux & macOS** use **Bash** (`bin/mcp-sdk.sh`).
- **Windows** uses **PowerShell** (`bin/mcp-sdk.psm1`).
- **Polyglot Runner (`bin/script-runner.sh` & `bin/script-runner.ps1`):** A single polyglot script valid in both POSIX `sh`/`bash` and PowerShell that automatically dispatches to the right `.sh` or `.ps1` script for the host OS.

| Component | Linux / macOS (Bash) | Windows (PowerShell 7+ `pwsh`) | Windows (Windows PowerShell 5.1) |
|---|---|---|---|
| **MCP SDK** | `bin/mcp-sdk.sh` | `bin/mcp-sdk.psm1` | `bin/mcp-sdk.psm1` |
| **SDK Utilities (dev-time)** | `bin/sdk-utils.sh` | `bin/sdk-utils.psm1` | `bin/sdk-utils.psm1` |
| **Server Entry Point** | `bin/shebang-mcp-sdk.sh` | `bin/shebang-mcp-sdk.ps1` | `bin/shebang-mcp-sdk.ps1` |
| **Polyglot Script Runner** | `./bin/script-runner.sh <target> [args...]` | `pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 <target> [args...]` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 <target> [args...]` |

## 2. Starting the SDK Server

### stdio mode (default)
```bash
# Linux / macOS (Bash)
./bin/script-runner.sh shebang-mcp-sdk --stdio

# Windows (PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio
```

### streamable-http mode
```bash
# Linux / macOS (Bash)
./bin/shebang-mcp-sdk.sh --streamable-http --host 127.0.0.1 --port 8080 --listen

# Windows (PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --streamable-http --port 8080
```

### CLI mode (for consumer testing & development)
Both entry points support a `--cli` mode that lets you invoke tools directly without the MCP protocol:

```bash
# List available tools
./bin/shebang-mcp-sdk.sh --cli --list-tools

# Call a specific tool
./bin/shebang-mcp-sdk.sh --cli --call-tool my_tool '{"arg":"value"}'

# Windows (PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --cli --ListTools
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --cli --CallTool my_tool '{"arg":"value"}'
```

## 3. Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MCP_TRANSPORT` | `stdio` | Transport protocol: stdio or streamable-http |
| `MCP_SERVER_NAME` | `shebang-mcp-sdk` | MCP server name reported during initialize |
| `MCP_SERVER_VERSION` | `1.0.0` | MCP server version reported during initialize |
| `MCP_PROTOCOL_VERSION` | `2025-03-26` | MCP protocol version |
| `MCP_HTTP_HOST` | `127.0.0.1` | HTTP bind address |
| `MCP_HTTP_PORT` | `8080` | HTTP port |
| `MCP_HTTP_ENDPOINT` | `/mcp` | HTTP endpoint path |
| `PLUGIN_ROOT` | auto-detected | Root of the installation |

## 4. Consumer Extension (How to Build on the SDK)

The SDK is **strictly generic** — it contains no application-specific logic. Consumers extend it by defining global functions that the SDK calls during request handling.

### MCP Concepts Supported

The SDK supports all four MCP concept types:

| Concept | MCP Method | Bash Handler | PowerShell Handler |
|---|---|---|---|
| **Tools** | `tools/list`, `tools/call` | `handle_list_tools`, `handle_tools_call` | `Handle-ListTools`, `Handle-ToolsCall` |
| **Resources** | `resources/list`, `resources/read` | `handle_list_resources`, `handle_read_resource` | `Handle-ListResources`, `Handle-ReadResource` |
| **Prompts** | `prompts/list`, `prompts/get` | `handle_list_prompts`, `handle_get_prompt` | `Handle-ListPrompts`, `Handle-GetPrompt` |
| **Transports** | N/A (transport layer) | `mcp_stdio_server`, `mcp_streamable_http_server` | `Invoke-Mcp-Stdio-Server`, `Invoke-Mcp-StreamableHttp-Server` |

### POSIX sh / Bash consumers

Define these functions in your consumer script:

```sh
# --- Tools ---
# List available tools (called on tools/list)
handle_list_tools() {
    local id="$1"
    local params="${2:-"{}"}"
    local result
    result=$(jq -cn '{tools:[{name:"my_tool",description:"My tool",inputSchema:{}]}}')
    json_response "${id}" "${result}"
}

# Handle tool calls (called on tools/call)
handle_tools_call() {
    local id="$1"
    local params="${2:-"{}"}"
    # ... handle the call ...
    json_response "${id}" '{"result":"ok"}'
}

# --- Resources ---
# List available resources (called on resources/list)
handle_list_resources() {
    local id="$1"
    local params="${2:-"{}"}"
    local result
    result=$(jq -cn '{resources:[{uri:"file:///data.txt",name:"Data File",mimeType:"text/plain"}]}')
    json_response "${id}" "${result}"
}

# Read a resource (called on resources/read)
handle_read_resource() {
    local id="$1"
    local params="${2:-"{}"}"
    local uri
    uri=$(printf '%s' "$params" | jq -r '.uri // ""')
    local result
    result=$(jq -cn --arg uri "$uri" --arg contents "file contents here" \
        '{contents:[{uri:$uri,mimeType:"text/plain",text:$contents}]}')
    json_response "${id}" "${result}"
}

# --- Prompts ---
# List available prompts (called on prompts/list)
handle_list_prompts() {
    local id="$1"
    local params="${2:-"{}"}"
    local result
    result=$(jq -cn '{prompts:[{name:"review_code",description:"Code review prompt",arguments:[]}]}')
    json_response "${id}" "${result}"
}

# Get a prompt (called on prompts/get)
handle_get_prompt() {
    local id="$1"
    local params="${2:-"{}"}"
    local name
    name=$(printf '%s' "$params" | jq -r '.name // ""')
    local result
    result=$(jq -cn --arg name "$name" --arg messages '[{"role":"user","content":"Review this code"}]' \
        '{description:"Prompt for $name",messages:$messages}')
    json_response "${id}" "${result}"
}

# --- Custom Methods (optional) ---
mcp_custom_method_handler() {
    local id="$1" method="$2" params="$3" is_notif="$4"
    # ... handle custom method ...
}
```

### PowerShell consumers

Define these functions in your consumer script:

```powershell
# --- Tools ---
function global:Handle-ListTools {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    # ... return tool list ...
    return json-response -Id $Id -Result @{ tools = @() }
}

function global:Handle-ToolsCall {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    # ... handle tool call ...
    return json-response -Id $Id -Result @{ result = "ok" }
}

# --- Resources ---
function global:Handle-ListResources {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    # ... return resource list ...
    return json-response -Id $Id -Result @{ resources = @() }
}

function global:Handle-ReadResource {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    # ... read resource ...
    return json-response -Id $Id -Result @{ contents = @() }
}

# --- Prompts ---
function global:Handle-ListPrompts {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    # ... return prompt list ...
    return json-response -Id $Id -Result @{ prompts = @() }
}

function global:Handle-GetPrompt {
    param($Id, [System.Collections.IDictionary]$Params = @{})
    # ... get prompt ...
    return json-response -Id $Id -Result @{ description = ""; messages = @() }
}

# --- Custom Methods (optional) ---
function global:Invoke-McpCustomMethod {
    param($Id, [string]$Method, [System.Collections.IDictionary]$Params = @{}, [bool]$IsNotification = $false)
    # ... handle custom method ...
}
```

## 5. Development Utilities (`sdk-utils.sh` / `sdk-utils.psm1`)

**These are dev-time utilities only — they are NOT part of the core MCP SDK runtime and should NOT be bundled with generated consumer MCP servers.**

The `sdk-utils.sh` (Bash) and `sdk-utils.psm1` (PowerShell) files contain `sdk-generate-handler`, a language-agnostic code generation function that takes a tool schema (JSON) and emits ready-to-use handler code.

### Usage

```bash
# Source sdk-utils.sh into your development script
. "${PLUGIN_ROOT}/bin/sdk-utils.sh"

# Generate Bash handler code from a tool schema
sdk-generate-handler '{"name":"my_tool","description":"Processes data","parameters":[{"name":"input","type":"string","required":true}]}'

# Source the generated code into your consumer script
. <(sdk-generate-handler '{"name":"my_tool",...}')
```

```powershell
# Import sdk-utils.psm1 into your development session
Import-Module "${PLUGIN_ROOT}/bin/sdk-utils.psm1"

# Generate PowerShell handler code
sdk-generate-handler -Schema '{"name":"my_tool","description":"Processes data"}' -Language pwsh

# Generate Bash handler code
sdk-generate-handler -Schema '{"name":"my_tool",...}' -Language bash

# Dot-source the generated code
. <(sdk-generate-handler -Schema '{"name":"my_tool",...}' -Language pwsh)
```

### Schema Format

```json
{
  "name": "tool_name",
  "description": "Human-readable description",
  "parameters": [
    {
      "name": "param_name",
      "type": "string",
      "description": "Parameter description",
      "required": true
    }
  ]
}
```

Supported parameter types: `string`, `number`, `integer`, `float`, `boolean`, `array`, `object`.

## 6. Public API Barrel

The Shebang MCP SDK exposes a clear public API surface for consumers. Functions are divided into two categories:

### Public API (Consumer-Facing)

These functions are intended for consumers building MCP servers on top of the SDK. They are exported from both `mcp-sdk.sh` and `mcp-sdk.psm1` and are safe to call directly.

| Function | Bash / PowerShell Alias | Description |
|---|---|---|
| `json_response` | `json-response` | Build a JSON-RPC 2.0 response |
| `mcp_error` | `mcp-error` | Build a JSON-RPC 2.0 error object |
| `mcp_tool_result` | `New-McpToolResult` | Format a tool result per MCP spec |
| `mcp_parse_message` | `mcp-parse-message` | Parse an incoming JSON-RPC message |
| `mcp_dispatch_message` | `process-mcp-line` | Dispatch a JSON-RPC message |
| `mcp_stdio_server` | `Invoke-Mcp-Stdio-Server` | Run stdio transport server |
| `mcp_streamable_http_server` | `Invoke-Mcp-StreamableHttp-Server` | Run streamable-http transport server |
| `Start-McpServer` | — | Start the server (auto-detects transport) |
| `mcp_register_cleanup` | `Register-McpCleanup` | Register a cleanup callback |
| `mcp_on_exit` | `Invoke-McpOnExit` | Run cleanup on exit |

### Internal SDK Helpers (Not Part of Public API)

These functions are used internally by the SDK and may change between versions. Consumers should not call them directly.

| Function | Bash / PowerShell Alias | Description |
|---|---|---|
| `ConvertTo-McpHashtable` | — | Convert PowerShell objects to hashtables |
| `send-http-response` | `send-http-response` | Low-level HTTP response formatting |
| `send-http-sse-response` | `send-http-sse-response` | SSE-formatted HTTP response |
| `handle-http-post` / `handle-http-get` / `handle-http-delete` | — | HTTP method handlers |
| `Invoke-Mcp-StreamableHttp-Server` internal loop | — | HTTPListener server loop |
| `check-http-available` | — | HTTP availability check |
| `extract-jsonrpc-from-post` | — | Extract JSON-RPC from POST body |
| `Mcp-Generate-Session-Id` / `mcp_generate_session_id` | — | Session ID generation |
| `Handle-Http-Request-Stream` / `handle_http_request_stream` | — | Raw HTTP request stream parsing |

### Development Utilities (Dev-Time Only)

These functions are in `sdk-utils.sh` / `sdk-utils.psm1` and are **not bundled with consumer MCP servers**. Consumers who need them must source/import them explicitly.

| Function | Description |
|---|---|
| `sdk-generate-handler` / `sdk_generate_handler` | Generate handler code from a tool schema (JSON) |

### Consumer Extension Points

Consumers extend the SDK by defining these global functions in their own scripts. The SDK calls them during request handling:

| Bash Function | PowerShell Function | Called When |
|---|---|---|
| `handle_list_tools` | `Handle-ListTools` | `tools/list` request |
| `handle_tools_call` | `Handle-ToolsCall` | `tools/call` request |
| `handle_list_resources` | `Handle-ListResources` | `resources/list` request |
| `handle_read_resource` | `Handle-ReadResource` | `resources/read` request |
| `handle_list_prompts` | `Handle-ListPrompts` | `prompts/list` request |
| `handle_get_prompt` | `Handle-GetPrompt` | `prompts/get` request |
| `mcp_custom_method_handler` | `Invoke-McpCustomMethod` | Custom MCP methods |

## 7. MCP Builder Skill Integration

The Shebang MCP SDK is designed to work with the **[MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)** — a skill for creating high-quality MCP servers that enable LLMs to interact with external services through well-designed tools.

The MCP Builder Skill (from [anthropics/skills](https://github.com/anthropics/skills)) provides guidance for building MCP servers to integrate external APIs or services, whether in Python (FastMCP) or Node/TypeScript (MCP SDK). With the Shebang MCP SDK, you can apply the same MCP Builder principles to shell-based MCP servers:

- Define tool handlers (`handle_list_tools` / `Handle-ListTools`) following MCP Builder patterns
- Use `mcp_custom_method_handler` / `Invoke-McpCustomMethod` for custom protocol methods
- Register cleanup hooks via `mcp_register_cleanup` / `Register-McpCleanup`
- Package as MCPB bundles for distribution via the Official MCP Registry (`bin/package-mcpb.sh` / `bin/package-mcpb.ps1`)

## 8. MCP Protocol Compliance

The SDK implements the [Model Context Protocol specification](https://modelcontextprotocol.io) including:

- JSON-RPC 2.0 message framing
- Server capabilities advertisement
- Tool discovery and invocation
- Resource listing and reading
- Prompt listing and retrieval
- Standard error codes
- stdio and streamable-http transports
- Session management (Mcp-Session-Id)
- Graceful shutdown and cleanup

## Bundled Resources
- `references/spec-template.md` - Specification template for MCP servers built on this SDK
- `references/checklist.md` - Quality & review checklist for MCP server implementations
- `scripts/setup-sdk.sh` / `scripts/setup-sdk.ps1` - SDK setup & info script
- `bin/package-mcpb.sh` / `bin/package-mcpb.ps1` - MCPB bundle builder for Official MCP Registry distribution
