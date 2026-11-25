# Shebang MCP SDK - Specification & Consumer Checklist

## 1. SDK Readiness (Pre-Integration)

- [ ] SDK files copied: `bin/mcp-sdk.sh` and/or `bin/mcp-sdk.psm1`
- [ ] Server entry point: `bin/shebang-mcp-sdk.sh` and/or `bin/shebang-mcp-sdk.ps1`
- [ ] Polyglot runner: `bin/script-runner.sh` / `bin/script-runner.ps1` / `bin/script-runner`
- [ ] `jq` available on Linux/macOS (required for JSON handling)
- [ ] PowerShell 5.1+ or pwsh 7+ available on Windows

## 2. Consumer Implementation Checklist

Before exposing your MCP server built on this SDK:

- [ ] Define `handle_list_tools` (bash) or `Handle-ListTools` (pwsh) to return your tools
- [ ] Define `handle_tools_call` (bash) or `Handle-ToolsCall` (pwsh) to handle tool invocations
- [ ] Optionally define `mcp_custom_method_handler` (bash) or `Invoke-McpCustomMethod` (pwsh) for custom methods
- [ ] Optionally register cleanup callbacks via `mcp_register_cleanup` / `Register-McpCleanup`
- [ ] Test stdio mode: `./bin/script-runner.sh shebang-mcp-sdk --stdio`
- [ ] Test streamable-http mode: `./bin/shebang-mcp-sdk.sh --streamable-http --port 8080`
- [ ] Verify JSON-RPC 2.0 compliance: initialize, ping, tools/list, tools/call
- [ ] Verify cleanup on exit (SIGINT/SIGTERM handling)

## 3. MCP Builder Skill Integration

When building production MCP servers on this SDK, apply the **[MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)** principles:

- [ ] Tool handlers follow MCP Builder patterns (clear names, descriptions, input schemas)
- [ ] Custom methods implemented via `mcp_custom_method_handler` / `Invoke-McpCustomMethod`
- [ ] Cleanup hooks registered via `mcp_register_cleanup` / `Register-McpCleanup`
- [ ] MCPB bundle built via `bin/package-mcpb.sh` / `bin/package-mcpb.ps1`
- [ ] Server registered in Official MCP Registry (`server.json`)

## 4. MCP Tools Contract (Consumer-Defined)

Your consumer defines the actual MCP tools. Example tool call payload:

```json
{
  "name": "my_tool",
  "arguments": {
    "param1": "value1"
  }
}
```

## 5. Transport Selection

| Transport | Use Case |
|---|---|
| `stdio` | Local MCP clients, CLI tools, process-based integration |
| `streamable-http` | Remote MCP clients, web-based integration, SSE streaming |

## 6. Cleanup & Shutdown

The SDK automatically handles cleanup on:
- Normal exit (POSIX `trap EXIT`, PowerShell `Module.OnRemove`)
- Signals: INT (SIGINT), TERM (SIGTERM), HUP (SIGHUP)

Consumers can register additional cleanup hooks via `mcp_register_cleanup` / `Register-McpCleanup`.

## 7. SDK Positioning

The Shebang MCP SDK is the shell-environment equivalent of:

| Language | SDK | Repository |
|---|---|---|
| Python | `python-sdk` | https://github.com/modelcontextprotocol/python-sdk |
| TypeScript | `@modelcontextprotocol/sdk` | https://github.com/modelcontextprotocol/typescript-sdk |
| Shell (Bash/PowerShell) | `shebang-mcp-sdk` | https://github.com/sheldonrobinson/shebang-mcp-sdk |
