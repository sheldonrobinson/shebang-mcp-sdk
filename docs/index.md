---
title: shebang-mcp-sdk
description: Shebang MCP SDK — The Model Context Protocol (MCP) SDK for shell environments (POSIX sh/Bash & PowerShell), analogous to python-sdk for Python and @modelcontextprotocol/sdk for TypeScript.
---

# shebang-mcp-sdk

> **Shebang MCP SDK** — The Model Context Protocol (MCP) SDK for shell environments (POSIX sh/Bash & PowerShell), analogous to [`python-sdk`](https://github.com/modelcontextprotocol/python-sdk) for Python and [`@modelcontextprotocol/sdk`](https://github.com/modelcontextprotocol/typescript-sdk) for TypeScript.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Agent Skills](https://img.shields.io/badge/Agent--Skills-v1.0-green)](https://agentskills.io/specification)

## Overview

The **Shebang MCP SDK** is a generic, cross-platform MCP SDK that provides the core Model Context Protocol (MCP) implementation usable by any shell-based MCP server. It is strictly generic and contains no application-specific logic.

Native implementations for:
- **Linux / macOS (Bash):** `bin/mcp-sdk.sh` + `bin/shebang-mcp-sdk.sh`
- **Windows (PowerShell):** `bin/mcp-sdk.psm1` + `bin/shebang-mcp-sdk.ps1`
- **Polyglot Runner:** `bin/script-runner.sh` / `bin/script-runner.ps1` (runs in both POSIX `sh`/`bash` and PowerShell)

## Quick Start

### Start MCP Server (stdio mode)
```bash
# Linux / macOS (Bash)
./bin/script-runner.sh shebang-mcp-sdk --stdio

# Windows (PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\script-runner.ps1 --use-pwsh shebang-mcp-sdk --stdio
```

### Start Streamable HTTP Service
```bash
# Linux / macOS (Bash)
./bin/shebang-mcp-sdk.sh --streamable-http --host 127.0.0.1 --port 8080 --listen

# Windows (PowerShell)
pwsh -NoProfile -ExecutionPolicy Bypass -File .\bin\shebang-mcp-sdk.ps1 --streamable-http --port 8080
```

## MCP Servers (`mcp.json`)

| Server Key | Platform | Transport | Command / Endpoint |
|---|---|---|---|
| `shebang-mcp-sdk` | Cross-Platform | `stdio` | `./bin/script-runner shebang-mcp-sdk --stdio` |
| `shebang-mcp-sdk-http` | Cross-Platform | `streamable-http` | `http://127.0.0.1:8080/mcp` |

## Documentation

- [Full Documentation](./README.md) — API reference and deployment guide
- [Source Repository](https://github.com/sheldonrobinson/shebang-mcp-sdk)
- [Official Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Official TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
- [MCP Builder Skill](https://github.com/anthropics/skills/tree/main/skills/mcp-builder)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Model Context Protocol Specification](https://modelcontextprotocol.io)
