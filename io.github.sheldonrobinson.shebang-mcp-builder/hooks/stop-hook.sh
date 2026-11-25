#!/usr/bin/env sh
# shebang-mcp-sdk Stop Hook (Agent-Harness Agnostic & POSIX sh compliant)
# Performs clean shutdown of the generic Shebang MCP SDK server.
# Runs on session exit to close connections and release resources.

set -eu

# Source the MCP SDK for cleanup functions if available
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export PLUGIN_ROOT

if [ -f "${PLUGIN_ROOT}/bin/mcp-sdk.sh" ]; then
    . "${PLUGIN_ROOT}/bin/mcp-sdk.sh"
fi

# Close any active connections and clean up transport resources
mcp_close_connection() {
    if [ -n "${MCP_HTTP_SERVER_PID:-}" ]; then
        if kill -0 "${MCP_HTTP_SERVER_PID}" 2>/dev/null; then
            kill "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
            wait "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
        fi
        MCP_HTTP_SERVER_PID=""
    fi

    if [ -n "${MCP_TEMP_FILES:-}" ]; then
        _old_ifs="${IFS}"
        IFS='
'
        for _f in ${MCP_TEMP_FILES}; do
            if [ -n "${_f}" ] && [ -e "${_f}" ]; then
                rm -rf "${_f}" 2>/dev/null || true
            fi
        done
        IFS="${_old_ifs}"
        MCP_TEMP_FILES=""
    fi

    MCP_INITIALIZED="false"
    MCP_SESSION_ID=""
}

mcp_close_connection || true
exit 0
