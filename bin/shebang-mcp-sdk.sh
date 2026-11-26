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
# Development utilities (sdk-utils.sh) are deliberately not loaded by this
# runtime entry point. Consumers developing handlers can invoke sdk-utils.sh
# directly or source it explicitly in a development shell.
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

# Source only the generic MCP SDK core runtime. sdk-utils.sh is a development
# tool and must be sourced explicitly when code generation is wanted.
. "${PLUGIN_ROOT}/bin/mcp-sdk.sh"

# --- CLI mode helpers -------------------------------------------------------
# Print a JSON-RPC error response unchanged and return nonzero. Malformed or
# result-less responses are also failures rather than successful CLI commands.
cli_validate_response() {
    _cli_check_response="${1:-}"
    _cli_check_operation="${2:-request}"

    if ! printf '%s' "${_cli_check_response}" | jq -e \
        'type == "object" and .jsonrpc == "2.0" and (has("result") or has("error"))' \
        >/dev/null 2>&1; then
        printf 'Error: %s returned an invalid JSON-RPC response\n' "${_cli_check_operation}" >&2
        if [ -n "${_cli_check_response}" ]; then
            printf '%s\n' "${_cli_check_response}" >&2
        fi
        return 1
    fi

    if printf '%s' "${_cli_check_response}" | jq -e '.error != null' >/dev/null 2>&1; then
        printf '%s\n' "${_cli_check_response}"
        return 1
    fi

    if ! printf '%s' "${_cli_check_response}" | jq -e 'has("result")' >/dev/null 2>&1; then
        printf 'Error: %s returned no result\n' "${_cli_check_operation}" >&2
        return 1
    fi
    return 0
}

cli_initialize() {
    _cli_init_req=$(jq -cn \
        --arg protocol "${MCP_PROTOCOL_VERSION:-2025-03-26}" \
        '{jsonrpc:"2.0",id:1,method:"initialize",params:{protocolVersion:$protocol,capabilities:{},clientInfo:{name:"cli",version:"1.0"}}}') || {
        printf 'Error: could not construct initialize request\n' >&2
        return 1
    }

    if ! _cli_init_resp=$(process_mcp_line "${_cli_init_req}"); then
        printf 'Error: initialize request failed\n' >&2
        if [ -n "${_cli_init_resp:-}" ]; then
            printf '%s\n' "${_cli_init_resp}" >&2
        fi
        return 1
    fi
    cli_validate_response "${_cli_init_resp}" "initialize"
}

cli_list_tools() {
    if ! cli_initialize; then
        return 1
    fi

    _cli_list_req=$(jq -cn '{jsonrpc:"2.0",id:2,method:"tools/list",params:{}}') || {
        printf 'Error: could not construct tools/list request\n' >&2
        return 1
    }
    if ! _cli_list_resp=$(process_mcp_line "${_cli_list_req}"); then
        printf 'Error: tools/list request failed\n' >&2
        if [ -n "${_cli_list_resp:-}" ]; then
            printf '%s\n' "${_cli_list_resp}" >&2
        fi
        return 1
    fi
    if ! cli_validate_response "${_cli_list_resp}" "tools/list"; then
        return 1
    fi
    if ! printf '%s' "${_cli_list_resp}" | jq -e '.result.tools | type == "array"' >/dev/null 2>&1; then
        printf 'Error: tools/list result does not contain a tools array\n' >&2
        printf '%s\n' "${_cli_list_resp}" >&2
        return 1
    fi

    printf '%s' "${_cli_list_resp}" | jq -r \
        '.result.tools[] | "\(.name) — \(.description // "no description")"'
}

cli_call_tool() {
    _cli_tool_name="${1:-}"
    _cli_tool_args="${2-"{}"}"
    if [ -z "${_cli_tool_name}" ]; then
        printf 'Error: --call-tool requires a tool name\n' >&2
        return 1
    fi

    # A tools/call arguments value must be exactly one JSON object. Slurping
    # rejects empty input and streams containing multiple JSON values as well.
    if ! _cli_args_json=$(printf '%s' "${_cli_tool_args}" | jq -ce -s \
        'if length == 1 and (.[0] | type == "object") then .[0] else error("arguments must be a single JSON object") end'); then
        printf 'Error: --call-tool arguments must be a single JSON object\n' >&2
        return 2
    fi
    if ! cli_initialize; then
        return 1
    fi

    _cli_call_req=$(jq -cn \
        --arg name "${_cli_tool_name}" \
        --argjson arguments "${_cli_args_json}" \
        '{jsonrpc:"2.0",id:4,method:"tools/call",params:{name:$name,arguments:$arguments}}') || {
        printf 'Error: could not construct tools/call request\n' >&2
        return 1
    }
    if ! _cli_call_resp=$(process_mcp_line "${_cli_call_req}"); then
        printf 'Error: tools/call request failed\n' >&2
        if [ -n "${_cli_call_resp:-}" ]; then
            printf '%s\n' "${_cli_call_resp}" >&2
        fi
        return 1
    fi
    if ! cli_validate_response "${_cli_call_resp}" "tools/call"; then
        return 1
    fi
    printf '%s\n' "${_cli_call_resp}"
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
                    if cli_list_tools; then
                        exit 0
                    else
                        _cli_exit_status=$?
                        exit "${_cli_exit_status}"
                    fi
                    ;;
                --call-tool|call-tool)
                    shift
                    if cli_call_tool "${1:-}" "${2-"{}"}"; then
                        exit 0
                    else
                        _cli_exit_status=$?
                        exit "${_cli_exit_status}"
                    fi
                    ;;
                *)
                    echo "Unknown CLI command: ${1}" >&2
                    echo "Available: --list-tools, --call-tool"
                    exit 1
                    ;;
            esac
        else
            echo "shebang-mcp-sdk: Unknown argument: $1" >&2
            echo "Usage: $0 [--stdio|--streamable-http|--cli] [--port PORT] [--host HOST]"
            exit 1
        fi
        ;;
esac
