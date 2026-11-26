---
layout: default
title: Documentation - shebang-mcp-sdk
---

# shebang-mcp-sdk

> **Shebang MCP SDK** — The Model Context Protocol (MCP) SDK for shell environments (POSIX sh/Bash & PowerShell), analogous to [`python-sdk`](https://github.com/modelcontextprotocol/python-sdk) for Python and [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk) for TypeScript.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Agent Skills](https://img.shields.io/badge/Agent--Skills-v1.0-green)](https://agentskills.io/specification)

## Overview

The **Shebang MCP SDK** is a generic, cross-platform MCP SDK that provides the core Model Context Protocol (MCP) implementation usable by any shell-based MCP server. It is strictly generic and contains no application-specific logic.

Like the official [Python SDK](https://github.com/modelcontextprotocol/python-sdk) and [TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk), the Shebang MCP SDK gives you the protocol foundation — JSON-RPC 2.0 framing, initialize/ping/tools/list/tools/call handling, stdio and streamable-http transports, and lifecycle management — so you can focus on building your MCP tools rather than reimplementing the protocol.

Native implementations for:
- **Linux / macOS (Bash):** `bin/mcp-sdk.sh` + `bin/shebang-mcp-sdk.sh`
- **Windows (PowerShell):** `bin/mcp-sdk.psm1` + `bin/shebang-mcp-sdk.ps1`
- **Polyglot Runner:** `bin/script-runner.sh` / `bin/script-runner.ps1` (runs in both POSIX `sh`/`bash` and PowerShell)

---

## Package Structure

```text
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
+-- skills/shebang-mcp-builder/       # Agent Skills discovery mirror
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
+-- package.sh                        # Basher install script
+-- LICENSE
+-- README.md
```

---

## MCP Servers (`mcp.json`)

| Server Key | Platform / Runtime | Transport | Command / Endpoint |
|---|---|---|---|
| `shebang-mcp-sdk` | Linux / macOS (POSIX sh/Bash) | `stdio` | `sh ${PLUGIN_ROOT}/bin/shebang-mcp-sdk.sh --stdio` |
| `shebang-mcp-sdk-sh` | Linux / macOS (with `jq` PATH bootstrap) | `stdio` | `sh ${PLUGIN_ROOT}/bin/shebang-mcp-sdk.sh --stdio` |
| `shebang-mcp-sdk-pwsh` | Windows (PowerShell 7+) | `stdio` | `pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:PLUGIN_ROOT 'bin/shebang-mcp-sdk.ps1') --stdio` |
| `shebang-mcp-sdk-powershell` | Windows (PowerShell 5.1) | `stdio` | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:PLUGIN_ROOT 'bin/shebang-mcp-sdk.ps1') --stdio` |
| `shebang-mcp-sdk-http` | Cross-Platform | `streamable-http` | `http://127.0.0.1:8080/mcp` |

---

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

---

## Consumer Extension

The SDK is generic — consumers extend it by defining global functions:

- **Bash:** `handle_list_tools`, `handle_tools_call`, `mcp_custom_method_handler`
- **PowerShell:** `Handle-ListTools`, `Handle-ToolsCall`, `Invoke-McpCustomMethod`

Optional resources and prompts use the dedicated `handle_list_resources` / `handle_read_resource` and `handle_list_prompts` / `handle_get_prompt` handlers (or their PowerShell equivalents). The core advertises the corresponding capabilities only when consumers provide those handlers; they are not automatic features of every generic server.

See `skills/shebang-mcp-builder/SKILL.md` for the full consumer extension guide.

## MCP Builder Skill Integration

The Shebang MCP SDK is designed to work with the **[MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)** — a skill for creating high-quality MCP servers that enable LLMs to interact with external services through well-designed tools.

Apply MCP Builder principles to shell-based MCP servers:
- Define tool handlers following MCP Builder patterns
- Use `mcp_custom_method_handler` for custom protocol methods
- Register cleanup hooks via `mcp_register_cleanup` / `Register-McpCleanup`
- Package as MCPB bundles for distribution via the Official MCP Registry

---

## Links

- [Deployment Guide](./deploy.md) — Full installation, MCP configuration, and Streamable HTTP service guide
- [Source Repository](https://github.com/sheldonrobinson/shebang-mcp-sdk)
- [Official Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Official TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Agent Plugins Specification](https://agent-plugins.org)
- [Model Context Protocol Specification](https://modelcontextprotocol.io)
