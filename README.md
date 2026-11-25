# shebang-mcp-sdk

> **Generic Shebang MCP SDK** — The Model Context Protocol (MCP) SDK for shell environments (POSIX sh/Bash & PowerShell), analogous to [`python-sdk`](https://github.com/modelcontextprotocol/python-sdk) for Python and [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk) for TypeScript.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP SDK](https://img.shields.io/badge/MCP-2025-03--26-blue)](https://modelcontextprotocol.io)
[![Agent Skills](https://img.shields.io/badge/Agent--Skills-v1.0-green)](https://agentskills.io/specification)
[![Agent Plugins](https://img.shields.io/badge/Agent--Plugins-v1.0-blue)](https://agent-plugins.org)

## Overview

The **Shebang MCP SDK** is a generic, cross-platform MCP SDK that provides the core Model Context Protocol (MCP) implementation usable by any shell-based MCP server. It is strictly generic and contains no application-specific logic.

Like the official [Python SDK](https://github.com/modelcontextprotocol/python-sdk) and [TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk), the Shebang MCP SDK gives you the protocol foundation — JSON-RPC 2.0 framing, initialize/ping/tools/list/tools/call handling, stdio and streamable-http transports, and lifecycle management — so you can focus on building your MCP tools rather than reimplementing the protocol.

Native implementations for:
- **Linux / macOS (Bash):** `bin/mcp-sdk.sh` + `bin/shebang-mcp-sdk.sh`
- **Windows (PowerShell):** `bin/mcp-sdk.psm1` + `bin/shebang-mcp-sdk.ps1`
- **Polyglot Runner:** `bin/script-runner.sh` / `bin/script-runner.ps1` (runs in both POSIX `sh`/`bash` and PowerShell)

## MCP Protocol Support

**Required features (implemented per MCP specification):**
- JSON-RPC 2.0 envelope (`jsonrpc: "2.0"`) on every message
- `initialize` request → capabilities, serverInfo, protocolVersion
- `notifications/initialized` → handled silently (no response)
- `ping` request → empty object `{}` response
- `tools/list` → list of available tools
- `tools/call` → invoke a named tool with arguments
- Standard JSON-RPC 2.0 error codes (-32700, -32600, -32601, -32602, -32603)
- Transports: stdio and streamable-http
- On-exit cleanup handler

**Optional features (explicitly NOT implemented):**
- Authorization, Elicitation, Roots, Sampling, Completions, Logging

**Deprecated features (explicitly NOT implemented):**
- Legacy HTTP+SSE transport

## Install Skill (`.agents/skills/`)

Per the [Agent Skills Specification](https://agentskills.io/specification), install the skill to `.agents/skills/`:

```bash
# Project-level (.agents/skills/) or User-level (~/.agents/skills/)
mkdir -p .agents/skills
cp -R skills/shebang-mcp-sdk .agents/skills/shebang-mcp-sdk
```
```powershell
New-Item -ItemType Directory -Path .agents/skills -Force | Out-Null
Copy-Item -Recurse -Force skills/shebang-mcp-sdk .agents/skills/shebang-mcp-sdk
```

## OS-Specific MCP Servers (`mcp.json`)

| MCP Server Name | OS / Runtime | Transport | Command / Endpoint |
|---|---|---|---|
| `shebang-mcp-sdk` | Cross-Platform (`script-runner`) | `stdio` | `./bin/script-runner shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-sh` | Linux / macOS (Bash) | `stdio` | `./bin/script-runner.sh --use-sh shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-pwsh` | Windows (PowerShell 7+) | `stdio` | `pwsh -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-powershell` | Windows (PowerShell 5.1) | `stdio` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${PLUGIN_ROOT}/bin/script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio` |
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

## Package Structure

```
shebang-mcp-sdk/
+-- bin/
|   +-- mcp-sdk.sh                    # Generic Bash MCP SDK (stdio + streamable-http)
|   +-- mcp-sdk.psm1                  # Generic PowerShell MCP SDK (stdio + streamable-http)
|   +-- shebang-mcp-sdk.sh            # Bash MCP server entry point
|   +-- shebang-mcp-sdk.ps1           # PowerShell MCP server entry point
|   +-- script-runner                 # Polyglot runner (POSIX sh / Bash & PowerShell)
|   +-- script-runner.sh              # Polyglot runner (.sh entry point)
|   +-- script-runner.ps1             # Polyglot runner (.ps1 entry point)
|   +-- script-runner.cmd             # Windows CMD launcher -> script-runner.ps1
|   +-- package-mcpb.sh               # MCPB bundle builder (POSIX sh)
|   +-- package-mcpb.ps1              # MCPB bundle builder (PowerShell)
+-- packaging/mcpb/
|   +-- manifest.sh.json              # MCPB manifest (Bash edition)
|   +-- manifest.pwsh.json            # MCPB manifest (PowerShell edition)
|   +-- mcp.template.json             # MCP server config template
+-- skills/shebang-mcp-sdk/           # Agent Skills discovery mirror
|   +-- SKILL.md                      # Skill metadata & instructions
|   +-- references/
|   |   +-- spec-template.md
|   |   +-- checklist.md
|   +-- scripts/
|       +-- setup-sdk.{sh,ps1}        # SDK setup & info script
+-- io.github.sheldonrobinson.shebang-mcp-builder/  # Client extension hooks & commands
|   +-- hooks/
|   |   +-- hooks.json
|   |   +-- stop-hook.{sh,ps1}
|   +-- commands/
|       +-- sdk-help.md
+-- plugin.json                       # Agent Plugins v1.0.0 manifest
+-- mcp.json                          # MCP Server configurations
+-- server.json                       # Official MCP Registry manifest
+-- bpkg.json                         # Basher package manifest
+-- package.sh                        # Basher install script
+-- LICENSE
+-- README.md
```

## Consumer Extension

The SDK is generic — consumers extend it by defining global functions:

- **Bash:** `handle_list_tools`, `handle_tools_call`, `mcp_custom_method_handler`
- **PowerShell:** `Handle-ListTools`, `Handle-ToolsCall`, `Invoke-McpCustomMethod`

See `skills/shebang-mcp-sdk/SKILL.md` for the full consumer extension guide.

## MCP Builder Skill Integration

The Shebang MCP SDK is designed to work with the **[MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)** — a skill for creating high-quality MCP servers that enable LLMs to interact with external services through well-designed tools.

The MCP Builder Skill (from [anthropics/skills](https://github.com/anthropics/skills)) provides guidance for building MCP servers to integrate external APIs or services, whether in Python (FastMCP) or Node/TypeScript (MCP SDK). With the Shebang MCP SDK, you can apply the same MCP Builder principles to shell-based MCP servers:

- Define tool handlers (`handle_list_tools` / `handle_tools_call`) following MCP Builder patterns
- Use `mcp_custom_method_handler` for custom protocol methods
- Register cleanup hooks via `mcp_register_cleanup` / `Register-McpCleanup`
- Package as MCPB bundles for distribution via the Official MCP Registry

See `bin/package-mcpb.sh` / `bin/package-mcpb.ps1` for building distributable `.mcpb` packages.

## Links

- [Full Documentation](./docs/README.md) — API reference and deployment guide
- [Deployment Guide](./docs/deploy.md) — Installation, MCP configuration, and Streamable HTTP service setup
- [Source Repository](https://github.com/sheldonrobinson/shebang-mcp-sdk)
- [Official Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Official TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Agent Plugins Specification](https://agent-plugins.org)
- [Model Context Protocol Specification](https://modelcontextprotocol.io)

## License

MIT

