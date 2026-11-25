---
layout: default
title: Deployment Guide - shebang-mcp-sdk
---

# Deployment Guide - shebang-mcp-sdk

Full installation, MCP configuration, and Streamable HTTP service setup for the **Shebang MCP SDK** — the Model Context Protocol (MCP) SDK for shell environments, analogous to [`python-sdk`](https://github.com/modelcontextprotocol/python-sdk) for Python and [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk) for TypeScript.

## Installation

### Install Skill (`.agents/skills/`)

Per the [Agent Skills Specification](https://agentskills.io/specification):

```bash
# Project-level install
mkdir -p .agents/skills
cp -R skills/shebang-mcp-sdk .agents/skills/shebang-mcp-sdk
```

```powershell
New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
Copy-Item -Recurse -Force skills/shebang-mcp-sdk .agents/skills/shebang-mcp-sdk
```

### Basher Install

```bash
./package.sh
```

## MCP Configuration (`mcp.json`)

Add the appropriate server entry to your MCP client's `mcp.json`:

```json
{
  "mcpServers": {
    "shebang-mcp-sdk": {
      "type": "stdio",
      "command": "./bin/script-runner",
      "args": ["shebang-mcp-sdk", "--stdio"],
      "cwd": "${PLUGIN_ROOT}",
      "env": {
        "MCP_TRANSPORT": "stdio",
        "MCP_SERVER_NAME": "shebang-mcp-sdk",
        "MCP_SERVER_VERSION": "1.0.0"
      }
    },
    "shebang-mcp-sdk-http": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:8080/mcp"
    }
  }
}
```

## Streamable HTTP Service Setup

The Streamable HTTP server runs as an independent HTTP service that must be started before connecting to `http://127.0.0.1:8080/mcp`.

### Linux / macOS (Bash)

**Start in background:**
```bash
./bin/shebang-mcp-sdk.sh --streamable-http --host 127.0.0.1 --port 8080 --listen
```

**Start via script-runner:**
```bash
./bin/script-runner.sh shebang-mcp-sdk --streamable-http --port 8080
```

**Verify:**
```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

### Windows (PowerShell)

**Start:**
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --streamable-http --port 8080
```

**Verify:**
```powershell
Invoke-RestMethod -Uri "http://127.0.0.1:8080/mcp" -Method Post -ContentType "application/json" `
  -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MCP_TRANSPORT` | `stdio` | Transport: stdio or streamable-http |
| `MCP_SERVER_NAME` | `shebang-mcp-sdk` | Server name reported during initialize |
| `MCP_SERVER_VERSION` | `1.0.0` | Server version reported during initialize |
| `MCP_PROTOCOL_VERSION` | `2025-03-26` | MCP protocol version |
| `MCP_HTTP_HOST` | `127.0.0.1` | HTTP bind address |
| `MCP_HTTP_PORT` | `8080` | HTTP port |
| `MCP_HTTP_ENDPOINT` | `/mcp` | HTTP endpoint path |
| `PLUGIN_ROOT` | auto-detected | Installation root |

## Building MCPB Bundles

```bash
# PowerShell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\package-mcpb.ps1

# POSIX sh
./bin/package-mcpb.sh
```

This builds `dist/shebang-mcp-sdk.sh.mcpb` and `dist/shebang-mcp-sdk.pwsh.mcpb` and updates `server.json` for distribution via the Official MCP Registry.

## MCP Builder Skill Integration

The Shebang MCP SDK is designed to work with the **[MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)** — a skill for creating high-quality MCP servers that enable LLMs to interact with external services through well-designed tools.

Apply MCP Builder principles when building shell-based MCP servers on this SDK:

1. **Define tool handlers** — Implement `handle_list_tools` / `Handle-ListTools` and `handle_tools_call` / `Handle-ToolsCall` following MCP Builder patterns
2. **Add custom methods** — Use `mcp_custom_method_handler` / `Invoke-McpCustomMethod` for protocol extensions
3. **Register cleanup hooks** — Use `mcp_register_cleanup` / `Register-McpCleanup` for graceful shutdown
4. **Package for distribution** — Build `.mcpb` bundles via `bin/package-mcpb.sh` / `bin/package-mcpb.ps1`

## Links

- [Source Repository](https://github.com/sheldonrobinson/shebang-mcp-sdk)
- [Official Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Official TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Model Context Protocol Specification](https://modelcontextprotocol.io)
