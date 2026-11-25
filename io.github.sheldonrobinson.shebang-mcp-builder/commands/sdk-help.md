---
name: shebang-mcp-sdk-help
description: "Explain the Shebang MCP SDK — the MCP SDK for shell environments, analogous to python-sdk for Python and @modelcontextprotocol/sdk for TypeScript. Includes MCP Builder Skill integration guidance."
---

# Shebang MCP SDK Help

Explain the **Shebang MCP SDK** capabilities and OS-specific execution rules to the user:

## Overview

The Shebang MCP SDK is a **generic Model Context Protocol (MCP) SDK** for shell environments (POSIX sh/Bash & PowerShell). It implements the core MCP specification over stdio and streamable-http transports. It contains NO application-specific logic — consumers override tool handlers via global functions.

**SDK Positioning:**
- Python: [`python-sdk`](https://github.com/modelcontextprotocol/python-sdk)
- TypeScript: [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk)
- Shell (Bash/PowerShell): **shebang-mcp-sdk**

## OS-Specific MCP Servers (`mcp.json`)

| Server Key | Platform / Runtime | Transport | Command / Endpoint |
|---|---|---|---|
| `shebang-mcp-sdk` | Cross-Platform (`script-runner`) | `stdio` | `./bin/script-runner shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-sh` | Linux / macOS (Bash) | `stdio` | `./bin/script-runner.sh --use-sh shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-pwsh` | Windows (PowerShell 7+) | `stdio` | `pwsh -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-powershell` | Windows (Windows PowerShell 5.1) | `stdio` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-http` | Cross-Platform | `streamable-http` | `http://127.0.0.1:8080/mcp` |

## Quick Start

### 1. Start MCP Server (stdio mode)
- **Linux / macOS (Bash):**
  ```bash
  ./bin/script-runner.sh shebang-mcp-sdk --stdio
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio
  ```

### 2. Start Streamable HTTP Service
- **Linux / macOS (Bash):**
  ```bash
  ./bin/shebang-mcp-sdk.sh --streamable-http --host 127.0.0.1 --port 8080 --listen
  ```
- **Windows (PowerShell):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --streamable-http --port 8080
  ```

### 3. Verify the server responds
```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

## Environment Variables

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

## Consumer Extension

The SDK is generic — consumers extend it by defining global functions:

- **Bash:** `handle_list_tools`, `handle_tools_call`, `mcp_custom_method_handler`
- **PowerShell:** `Handle-ListTools`, `Handle-ToolsCall`, `Invoke-McpCustomMethod`

See `skills/shebang-mcp-sdk/SKILL.md` for the full consumer extension guide.

## MCP Builder Skill Integration

The Shebang MCP SDK is designed to work with the **[MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)** — a skill for creating high-quality MCP servers that enable LLMs to interact with external services through well-designed tools.

Apply MCP Builder principles:
- Define tool handlers (`handle_list_tools` / `Handle-ListTools`) following MCP Builder patterns
- Use `mcp_custom_method_handler` / `Invoke-McpCustomMethod` for custom protocol methods
- Register cleanup hooks via `mcp_register_cleanup` / `Register-McpCleanup`
- Package as MCPB bundles via `bin/package-mcpb.sh` / `bin/package-mcpb.ps1` for Official MCP Registry distribution
