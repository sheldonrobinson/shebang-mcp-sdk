# Specification: [FEATURE_NAME]

## Overview
[Brief description of the MCP server or consumer built on the Shebang MCP SDK — what it does and why it matters]

## SDK Positioning
The Shebang MCP SDK is the shell-environment equivalent of `python-sdk` (Python) and `@modelcontextprotocol/sdk` (TypeScript). This specification describes an MCP server built on the Shebang MCP SDK.

## Transport
- [ ] stdio (default, local process communication)
- [ ] streamable-http (remote HTTP communication)

## MCP Tools

Your consumer defines its own MCP tools. Each tool should have:

| Tool Name | Description | Input Schema |
|---|---|---|
| `tool_name` | [Description] | [JSON Schema for arguments] |

## Consumer Handler Implementation

- [ ] `handle_list_tools` / `Handle-ListTools` — Returns the list of available tools
- [ ] `handle_tools_call` / `Handle-ToolsCall` — Handles tool invocations
- [ ] `mcp_custom_method_handler` / `Invoke-McpCustomMethod` — Optional custom methods
- [ ] Cleanup hooks registered via `mcp_register_cleanup` / `Register-McpCleanup`

## MCP Builder Skill Integration

Apply [MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder) principles:

- [ ] Tool definitions follow MCP Builder patterns (clear names, descriptions, input schemas)
- [ ] Error handling uses standard JSON-RPC 2.0 error codes
- [ ] Cleanup hooks registered for graceful shutdown
- [ ] MCPB bundle built for Official MCP Registry distribution

## Testing & Verification

- [ ] JSON-RPC 2.0 compliance verified (initialize, ping, tools/list, tools/call)
- [ ] stdio mode tested: `./bin/script-runner.sh shebang-mcp-sdk --stdio`
- [ ] streamable-http mode tested: `./bin/shebang-mcp-sdk.sh --streamable-http --port 8080`
- [ ] Cleanup on exit verified (SIGINT/SIGTERM handling)
- [ ] Cross-platform verified (Linux/macOS Bash + Windows PowerShell)

## Completion Signal

- **MCP Mode:** Tools return proper JSON-RPC responses with `content` arrays per MCP spec
- **CLI Mode:** Server runs until interrupted, then cleans up resources
