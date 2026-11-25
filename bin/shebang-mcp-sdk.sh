#!/usr/bin/env sh
# shebang-mcp-sdk.sh - Generic Shebang MCP SDK Server Entry Point (POSIX sh)
#
# Starts the generic Shebang MCP SDK server over stdio or streamable-http transport.
# This server implements the core Model Context Protocol (MCP) specification and
# contains NO application-specific logic — consumers override tool handlers via
# global functions (handle_list_tools, handle_tools_call, mcp_custom_method_handler).
#
# Dual-mode: Works as both an MCP server (stdio/streamable-http) and a CLI tool.
# In CLI mode, consumers can invoke tools directly without the MCP protocol.
#
# Development utilities (sdk-utils.sh) are optionally sourced for sdk-generate-handler.
# sdk-utils.sh is NOT part of the core runtime and should not be bundled with consumer
# MCP servers — it is only needed during development/code-generation.
#
# Usage:
#   ./bin/shebang-mcp-sdk.sh                # stdio MCP server (default)
#   ./bin/shebang-mcp-sdk.sh --stdio        # stdio MCP server
#   ./bin/shebang-mcp-sdk.sh --streamable-http --port 8080
#   ./bin/shebang-mcp-sdk.sh --cli --list-tools          # List available tools
#   ./bin/shebang-mcp-sdk.sh --cli --call-tool my_tool '{"arg":"val"}'  # Call a tool
#
# Environment variables:
#   MCP_TRANSPORT       stdio | streamable-http  (default: stdio)
#   MCP_SERVER_NAME     server name (default: shebang-mcp-sdk)
#   MCP_SERVER_VERSION  version string (default: 1.0.0)
#   MCP_PROTOCOL_VERSION 2025-03-26 | 2024-11-05 (default: 2025-03-26)
#   MCP_HTTP_HOST, MCP_HTTP_PORT, MCP_HTTP_ENDPOINT
#   PLUGIN_ROOT         root of the installation (auto-detected if unset)

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export PLUGIN_ROOT

# Mark SDK as sourced to prevent mcp-sdk.sh from auto-running its own main
MCP_SDK_SOURCED="true"

# Source the generic MCP SDK (core runtime — included in consumer bundles)
. "${PLUGIN_ROOT}/bin/mcp-sdk.sh"

# Optionally source SDK utilities (dev-time only — NOT bundled with consumers)
# Consumers who need sdk-generate-handler can source sdk-utils.sh directly:
#   . "${PLUGIN_ROOT}/bin/sdk-utils.sh"
if [ -f "${PLUGIN_ROOT}/bin/sdk-utils.sh" ]; then
    . "${PLUGIN_ROOT}/bin/sdk-utils.sh"
fi

# --- CLI mode helpers -------------------------------------------------------
cli_list_tools() {
    # Build a minimal initialize + tools/list request and dispatch it
    local req
    req='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cli","version":"1.0"}}}'
    local resp
    resp=$(process_mcp_line "$req")
    # Now request tools/list
    req='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
    resp=$(process_mcp_line "$req")
    printf '%s\n' "$resp" | jq -r '.result.tools[] | "\(.name) — \(.description // "no description")"' 2>/dev/null || \
        printf '%s\n' "$resp"
}

cli_call_tool() {
    local tool_name="${1:-}"
    local tool_args="${2:-"{}"}"
    if [ -z "$tool_name" ]; then
        echo "Error: --call-tool requires a tool name" >&2
        return 1
    fi
    local req
    req=$(printf '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cli","version":"1.0"}}}')
    process_mcp_line "$req" >/dev/null 2>&1 || true
    req=$(printf '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$tool_name" "$tool_args")
    process_mcp_line "$req"
}

# --- Main entry point -------------------------------------------------------
case "${0##*/}" in
    shebang-mcp-sdk.sh|shebang-mcp-sdk)
        if [ $# -eq 0 ]; then
            # Default: stdio mode via mcp_main
            mcp_main
            exit 0
        elif [ "${1}" = "--stdio" ]; then
            export MCP_TRANSPORT="stdio"
            mcp_main
            exit 0
        elif [ "${1}" = "--http-worker" ]; then
            handle_http_request_stream
            exit 0
        elif [ "${1}" = "--http" ] || [ "${1}" = "--streamable-http" ]; then
            export MCP_TRANSPORT="streamable-http"
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                    --port) shift; export MCP_HTTP_PORT="${1:-8080}" ;;
                    --host) shift; export MCP_HTTP_HOST="${1:-127.0.0.1}" ;;
                    --endpoint) shift; export MCP_HTTP_ENDPOINT="${1:-/mcp}" ;;
                    --listen) export MCP_HTTP_LISTEN="true" ;;
                esac
                shift
            done
            mcp_main
            exit 0
        elif [ "${1}" = "--cli" ]; then
            shift
            if [ $# -eq 0 ]; then
                echo "shebang-mcp-sdk CLI mode"
                echo "Usage: $0 --cli --list-tools"
                echo "       $0 --cli --call-tool <tool_name> '<json_args>'"
                exit 0
            fi
            case "${1}" in
                --list-tools|list-tools)
                    cli_list_tools
                    ;;
                --call-tool|call-tool)
                    shift
                    cli_call_tool "${1:-}" "${2:-"{}"}"
                    ;;
                *)
                    echo "Unknown CLI command: ${1}" >&2
                    echo "Available: --list-tools, --call-tool"
                    exit 1
                    ;;
            esac
            exit 0
        else
            echo "shebang-mcp-sdk: Unknown argument: $1" >&2
            echo "Usage: $0 [--stdio|--streamable-http|--cli] [--port PORT] [--host HOST]"
            exit 1
        fi
        ;;
esac
