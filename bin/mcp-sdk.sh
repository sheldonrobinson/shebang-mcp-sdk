#!/usr/bin/env sh
# mcp-sdk.sh - Generic Shebang MCP SDK (POSIX sh compliant)
# Implementation of the Model Context Protocol (MCP) specification (latest: 2025-03-26 / 2024-11-05)
# Supports both stdio and streamable-http transports.
#
# This SDK is strictly generic and provides core MCP protocol functions usable by any
# POSIX shell-based MCP server. It contains NO application-specific logic.
#
# ============================================================================
# REQUIRED features (MUST implement per MCP specification):
#   - JSON-RPC 2.0 envelope (jsonrpc: "2.0") on every message
#   - initialize request       -> capabilities, serverInfo, protocolVersion
#   - notifications/initialized (and initialized) -> handled silently (no response)
#   - ping request             -> empty object {} response
#   - tools/list               -> list of available tools
#   - tools/call               -> invoke a named tool with arguments
#   - Standard JSON-RPC 2.0 error codes (-32700, -32600, -32601, -32602, -32603)
#   - Transports: stdio and streamable-http
#   - On-exit cleanup handler (trap EXIT / INT / TERM / HUP)
#
# OPTIONAL features (explicitly NOT implemented):
#   - Authorization, Elicitation, Roots, Sampling, Completions, Logging
#
# DEPRECATED features (explicitly NOT implemented):
#   - Legacy HTTP+SSE transport (2024-11-05 separate SSE endpoint)
# ============================================================================

set -eu

# Carriage-return character for stripping CRLF line endings in POSIX sh
MCP_CR="$(printf '\r')"
MCP_NL="
"

# --- Protocol constants -----------------------------------------------------
MCP_PROTOCOL_VERSION="${MCP_PROTOCOL_VERSION:-2025-03-26}"
MCP_SUPPORTED_VERSIONS="2025-03-26 2024-11-05"
MCP_SERVER_NAME="${MCP_SERVER_NAME:-shebang-mcp-sdk}"
MCP_SERVER_VERSION="${MCP_SERVER_VERSION:-1.0.0}"

# --- Transport and connection state -----------------------------------------
MCP_TRANSPORT="${MCP_TRANSPORT:-stdio}"
MCP_HTTP_HOST="${MCP_HTTP_HOST:-127.0.0.1}"
MCP_HTTP_PORT="${MCP_HTTP_PORT:-8080}"
MCP_HTTP_ENDPOINT="${MCP_HTTP_ENDPOINT:-/mcp}"
MCP_SESSION_ID=""
MCP_INITIALIZED="false"
MCP_HTTP_SERVER_PID=""
MCP_CLEANUP_DONE="false"
MCP_CLEANUP_HOOKS=""
MCP_TEMP_FILES=""

# HTTP security limits. Origin values are matched exactly (case-insensitively);
# the allowlist is a comma/whitespace-separated list and defaults to loopback.
MCP_HTTP_ALLOWED_ORIGINS="${MCP_HTTP_ALLOWED_ORIGINS:-}"
MCP_HTTP_MAX_BODY_BYTES="${MCP_HTTP_MAX_BODY_BYTES:-${MCP_HTTP_MAX_CONTENT_LENGTH:-1048576}}"
MCP_HTTP_ALLOW_NON_LOOPBACK="${MCP_HTTP_ALLOW_NON_LOOPBACK:-false}"
# Shared by forked HTTP workers. Normally created by the listener with mktemp.
MCP_HTTP_STATE_DIR="${MCP_HTTP_STATE_DIR:-}"

# --- On-Exit & Connection Cleanup Handler -----------------------------------
# Register a custom cleanup callback function name to run on exit
mcp_register_cleanup() {
    _hook="${1:-}"
    if [ -n "${_hook}" ]; then
        if [ -z "${MCP_CLEANUP_HOOKS}" ]; then
            MCP_CLEANUP_HOOKS="${_hook}"
        else
            MCP_CLEANUP_HOOKS="${MCP_CLEANUP_HOOKS} ${_hook}"
        fi
    fi
}

# Track a temporary file/FIFO for automatic removal on exit
mcp_register_temp_file() {
    _tmpf="${1:-}"
    if [ -n "${_tmpf}" ]; then
        if [ -z "${MCP_TEMP_FILES}" ]; then
            MCP_TEMP_FILES="${_tmpf}"
        else
            MCP_TEMP_FILES="${MCP_TEMP_FILES}${MCP_NL}${_tmpf}"
        fi
    fi
}

# Close active MCP transport connections and release resources
mcp_close_connection() {
    # Stop background HTTP listener if running
    if [ -n "${MCP_HTTP_SERVER_PID:-}" ]; then
        if kill -0 "${MCP_HTTP_SERVER_PID}" 2>/dev/null; then
            kill "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
            wait "${MCP_HTTP_SERVER_PID}" 2>/dev/null || true
        fi
        MCP_HTTP_SERVER_PID=""
    fi

    # Remove any temporary files/FIFOs created by the transport
    if [ -n "${MCP_TEMP_FILES}" ]; then
        _old_ifs="${IFS}"
        IFS="${MCP_NL}"
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

# Trap handler invoked on EXIT, INT, TERM, HUP
mcp_on_exit() {
    _exit_code=$?
    trap - EXIT INT TERM HUP
    if [ "${MCP_CLEANUP_DONE}" = "true" ]; then
        return "${_exit_code}"
    fi
    MCP_CLEANUP_DONE="true"

    # Run registered consumer cleanup hooks if any
    if [ -n "${MCP_CLEANUP_HOOKS}" ]; then
        for _hook in ${MCP_CLEANUP_HOOKS}; do
            if command -v "${_hook}" >/dev/null 2>&1; then
                "${_hook}" || true
            fi
        done
    fi

    # Close connections and clean up transport resources
    mcp_close_connection || true

    return "${_exit_code}"
}

mcp_on_signal() {
    _sig="${1:-TERM}"
    _code="${2:-143}"
    mcp_on_exit || true
    exit "${_code}"
}

trap mcp_on_exit EXIT
trap 'mcp_on_signal INT 130' INT
trap 'mcp_on_signal TERM 143' TERM
trap 'mcp_on_signal HUP 129' HUP

# --- JSON-RPC 2.0 helpers ---------------------------------------------------
json_escape() {
    printf '%s' "${1:-}" | jq -Rs .
}

is_json_number() {
    case "${1:-}" in
        ''|'-') return 1 ;;
        -*)
            _num="${1#-}"
            ;;
        *)
            _num="${1}"
            ;;
    esac
    case "${_num}" in
        ''|*[!0-9.]*|*.*.*) return 1 ;;
        .*) return 1 ;;
        *.) return 1 ;;
        *) return 0 ;;
    esac
}

# Validate raw input bytes before jq can replace malformed UTF-8 with U+FFFD.
# iconv is available in the supported WSL and Git Bash environments. The POSIX
# od/awk fallback is deliberately strict rather than silently skipping validation.
mcp_utf8_valid() {
    if command -v iconv >/dev/null 2>&1; then
        iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
        return $?
    fi

    LC_ALL=C od -An -v -tu1 | awk '
        BEGIN { need = 0; lo = 128; hi = 191; bad = 0 }
        {
            for (i = 1; i <= NF; i++) {
                b = $i + 0
                if (need > 0) {
                    if (b < lo || b > hi) { bad = 1; exit }
                    need--
                    lo = 128
                    hi = 191
                } else if (b <= 127) {
                    # ASCII, including JSON-insignificant whitespace.
                } else if (b >= 194 && b <= 223) {
                    need = 1
                } else if (b == 224) {
                    need = 2; lo = 160
                } else if ((b >= 225 && b <= 236) || b == 238 || b == 239) {
                    need = 2
                } else if (b == 237) {
                    need = 2; hi = 159
                } else if (b == 240) {
                    need = 3; lo = 144
                } else if (b >= 241 && b <= 243) {
                    need = 3
                } else if (b == 244) {
                    need = 3; hi = 143
                } else {
                    bad = 1; exit
                }
            }
        }
        END { if (need > 0) bad = 1; exit bad }
    '
}

# JSON-RPC 2.0 response constructor
# Usage: json_response <id_json> <result_json> [error_json]
# Dispatcher IDs are already JSON-encoded. For compatibility with consumers that
# call this helper directly, a non-JSON legacy value is encoded as a string.
json_response() {
    _jr_id="${1:-null}"
    _jr_result="${2:-"{}"}"
    _jr_error="${3:-}"

    if [ -z "${_jr_id}" ]; then
        _jr_id_expr="null"
    elif printf '%s' "${_jr_id}" | jq . >/dev/null 2>&1; then
        # Never infer the ID type from its decoded text: "1" and 1 differ.
        _jr_id_expr=$(printf '%s' "${_jr_id}" | jq -c .)
    else
        _jr_id_expr=$(printf '%s' "${_jr_id}" | jq -Rs .)
    fi

    if [ -n "${_jr_error}" ]; then
        if printf '%s' "${_jr_error}" | jq -e . >/dev/null 2>&1; then
            _jr_payload=$(jq -cn \
                --argjson id "${_jr_id_expr}" \
                --argjson err "${_jr_error}" \
                '{jsonrpc:"2.0", id:$id, error:$err}')
        else
            _jr_payload=$(jq -cn \
                --argjson id "${_jr_id_expr}" \
                --arg msg "${_jr_error}" \
                '{jsonrpc:"2.0", id:$id, error:{code:-32603, message:$msg}}')
        fi
    else
        _jr_result_json="{}"
        if [ -n "${_jr_result}" ]; then
            if printf '%s' "${_jr_result}" | jq . >/dev/null 2>&1; then
                _jr_result_json="${_jr_result}"
            else
                _jr_result_json=$(printf '%s' "${_jr_result}" | jq -Rs '{content:[{type:"text",text:.}]}')
            fi
        fi
        _jr_payload=$(jq -cn \
            --argjson id "${_jr_id_expr}" \
            --argjson res "${_jr_result_json}" \
            '{jsonrpc:"2.0", id:$id, result:$res}')
    fi
    printf '%s\n' "${_jr_payload}"
}

# JSON-RPC 2.0 error object constructor
# Usage: mcp_error <code> <message> [data_json]
mcp_error() {
    _me_code="${1:--32603}"
    _me_message="${2:-Internal error}"
    _me_data="${3:-null}"
    if [ -z "${_me_data}" ] || [ "${_me_data}" = "null" ]; then
        jq -cn --argjson code "${_me_code}" --arg message "${_me_message}" \
            '{code:$code, message:$message}'
    else
        if ! printf '%s' "${_me_data}" | jq -e . >/dev/null 2>&1; then
            _me_data=$(printf '%s' "${_me_data}" | jq -Rs .)
        fi
        jq -cn --argjson code "${_me_code}" --arg message "${_me_message}" --argjson data "${_me_data}" \
            '{code:$code, message:$message, data:$data}'
    fi
}

# Format a tool result per MCP spec (content array with text item + optional structured/raw fields)
# Usage: mcp_tool_result <text_or_json> [is_error]
mcp_tool_result() {
    _mtr_content="${1:-}"
    _mtr_is_error="${2:-false}"
    jq -cn --arg text "${_mtr_content}" --argjson isError "${_mtr_is_error}" \
        '{content:[{type:"text", text:$text}], isError:$isError}'
}

# Validate and parse incoming JSON-RPC 2.0 message
# Usage: mcp_parse_message <message>
mcp_parse_message() {
    _mpm_message="${1:-}"
    if ! printf '%s' "${_mpm_message}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf 'VALID=false\nIS_NOTIFICATION=false\nID=null\nMETHOD=\nPARAMS={}\n'
        return 0
    fi

    _mpm_jsonrpc=$(printf '%s' "${_mpm_message}" | jq -r 'if .jsonrpc == "2.0" then "2.0" else "" end' 2>/dev/null || echo "")
    _mpm_has_id=$(printf '%s' "${_mpm_message}" | jq -r 'has("id")' 2>/dev/null || echo "false")
    # Keep ID and METHOD_JSON compact JSON so escaped newlines never become
    # physical lines. METHOD retains its historical unquoted form for ordinary
    # names, but special characters stay JSON-escaped to keep this public
    # line-oriented API unambiguous. Consumers needing decoded text should use
    # METHOD_JSON; the dispatcher decodes that field directly from the message.
    _mpm_id=$(printf '%s' "${_mpm_message}" | jq -c 'if has("id") then .id else null end' 2>/dev/null || echo "null")
    _mpm_method_json=$(printf '%s' "${_mpm_message}" | jq -c 'if (.method | type) == "string" then .method else "" end' 2>/dev/null || echo '""')
    _mpm_method="${_mpm_method_json#?}"
    _mpm_method="${_mpm_method%?}"
    _mpm_params=$(printf '%s' "${_mpm_message}" | jq -c '.params // {}' 2>/dev/null || echo "{}")

    if [ "${_mpm_has_id}" = "false" ]; then
        _mpm_is_notification="true"
    else
        _mpm_is_notification="false"
    fi

    printf 'VALID=true\nJSONRPC=%s\nIS_NOTIFICATION=%s\nID=%s\nMETHOD_JSON=%s\nMETHOD=%s\nPARAMS=%s\n' \
        "${_mpm_jsonrpc}" "${_mpm_is_notification}" "${_mpm_id}" \
        "${_mpm_method_json}" "${_mpm_method}" "${_mpm_params}"
}

# ============================================================================
# MCP METHOD HANDLERS (generic protocol handlers; overridable by consumers)
# ============================================================================

# Handle MCP initialize request
handle_initialize() {
    _hi_id="${1}"
    _hi_params="${2:-"{}"}"

    _hi_client_version=$(printf '%s' "${_hi_params}" | jq -r '.protocolVersion // ""' 2>/dev/null || echo "")
    _hi_negotiated="${MCP_PROTOCOL_VERSION}"

    if [ -n "${_hi_client_version}" ]; then
        for _v in ${MCP_SUPPORTED_VERSIONS}; do
            if [ "${_v}" = "${_hi_client_version}" ]; then
                _hi_negotiated="${_hi_client_version}"
                break
            fi
        done
    fi

    MCP_INITIALIZED="true"

    # Tools are supported by the generic empty-list/call routes. Resource and
    # prompt capabilities are advertised only when a consumer supplies at least
    # one handler for that concept; unsupported routes return method-not-found.
    _hi_caps=$(jq -cn '{tools:{}}')
    if command -v handle_list_resources >/dev/null 2>&1 || \
       command -v handle_read_resource >/dev/null 2>&1; then
        _hi_caps=$(printf '%s' "${_hi_caps}" | jq -c '. + {resources:{}}')
    fi
    if command -v handle_list_prompts >/dev/null 2>&1 || \
       command -v handle_get_prompt >/dev/null 2>&1; then
        _hi_caps=$(printf '%s' "${_hi_caps}" | jq -c '. + {prompts:{}}')
    fi
    _hi_info=$(jq -cn --arg name "${MCP_SERVER_NAME}" --arg version "${MCP_SERVER_VERSION}" \
        '{name:$name, version:$version}')
    _hi_res=$(jq -cn \
        --arg proto "${_hi_negotiated}" \
        --argjson caps "${_hi_caps}" \
        --argjson info "${_hi_info}" \
        '{protocolVersion:$proto, capabilities:$caps, serverInfo:$info}')
    json_response "${_hi_id}" "${_hi_res}"
}

# Handle notifications/initialized (and legacy initialized) notification
handle_initialized() {
    MCP_INITIALIZED="true"
    return 0
}

# Handle MCP ping request
handle_ping() {
    json_response "${1}" "{}"
}

# Default generic tools/list handler (consumers can override handle_tools_list or handle_list_tools)
handle_tools_list() {
    _htl_id="${1}"
    _htl_params="${2:-"{}"}"

    if command -v handle_list_tools >/dev/null 2>&1; then
        handle_list_tools "${_htl_id}" "${_htl_params}"
        return 0
    fi

    _htl_res=$(jq -cn '{tools:[]}')
    json_response "${_htl_id}" "${_htl_res}"
}

# Default generic tools/call handler (consumers can override handle_tools_call)
handle_tools_call() {
    _htc_id="${1}"
    _htc_params="${2:-"{}"}"

    _htc_name=$(printf '%s' "${_htc_params}" | jq -r '.name // ""' 2>/dev/null || echo "")
    if [ -z "${_htc_name}" ]; then
        _htc_err=$(mcp_error -32602 "Invalid params: missing tool name")
        json_response "${_htc_id}" "" "${_htc_err}"
        return 0
    fi

    _htc_err=$(mcp_error -32601 "Tool not found: ${_htc_name}")
    json_response "${_htc_id}" "" "${_htc_err}"
}

mcp_method_not_found() {
    _mmnf_id="${1:-null}"
    _mmnf_method="${2:-}"
    _mmnf_err=$(mcp_error -32601 "Method not found: ${_mmnf_method}")
    json_response "${_mmnf_id}" "" "${_mmnf_err}"
}

# Resource and prompt routes use the documented consumer extension names. No
# synthetic empty result is returned when the corresponding handler is absent.
handle_resources_list() {
    if command -v handle_list_resources >/dev/null 2>&1; then
        handle_list_resources "${1}" "${2:-"{}"}"
    else
        mcp_method_not_found "${1}" "resources/list"
    fi
}

handle_resources_read() {
    if command -v handle_read_resource >/dev/null 2>&1; then
        handle_read_resource "${1}" "${2:-"{}"}"
    else
        mcp_method_not_found "${1}" "resources/read"
    fi
}

handle_prompts_list() {
    if command -v handle_list_prompts >/dev/null 2>&1; then
        handle_list_prompts "${1}" "${2:-"{}"}"
    else
        mcp_method_not_found "${1}" "prompts/list"
    fi
}

handle_prompts_get() {
    if command -v handle_get_prompt >/dev/null 2>&1; then
        handle_get_prompt "${1}" "${2:-"{}"}"
    else
        mcp_method_not_found "${1}" "prompts/get"
    fi
}

# Generic JSON-RPC 2.0 message dispatcher
mcp_dispatch_message() {
    _mdm_line="${1:-}"
    if [ -z "${_mdm_line}" ]; then
        return 0
    fi

    if ! printf '%s' "${_mdm_line}" | mcp_utf8_valid || \
       ! printf '%s' "${_mdm_line}" | jq . >/dev/null 2>&1; then
        _mdm_err=$(mcp_error -32700 "Parse error")
        json_response "null" "" "${_mdm_err}"
        return 0
    fi

    _mdm_type=$(printf '%s' "${_mdm_line}" | jq -r 'type' 2>/dev/null || echo "")
    if [ "${_mdm_type}" = "array" ]; then
        _mdm_len=$(printf '%s' "${_mdm_line}" | jq 'length')
        if [ "${_mdm_len}" -eq 0 ]; then
            _mdm_err=$(mcp_error -32600 "Invalid Request: empty batch")
            json_response "null" "" "${_mdm_err}"
            return 0
        fi
        _mdm_responses=""
        _mdm_idx=0
        while [ "${_mdm_idx}" -lt "${_mdm_len}" ]; do
            _mdm_item=$(printf '%s' "${_mdm_line}" | jq -c ".[${_mdm_idx}]")
            _mdm_item_resp=$(mcp_dispatch_single "${_mdm_item}")
            if [ -n "${_mdm_item_resp}" ]; then
                if [ -z "${_mdm_responses}" ]; then
                    _mdm_responses="${_mdm_item_resp}"
                else
                    _mdm_responses="${_mdm_responses}${MCP_NL}${_mdm_item_resp}"
                fi
            fi
            _mdm_idx=$((_mdm_idx + 1))
        done
        if [ -n "${_mdm_responses}" ]; then
            printf '%s\n' "${_mdm_responses}" | jq -cs '.'
        fi
        return 0
    elif [ "${_mdm_type}" != "object" ]; then
        _mdm_err=$(mcp_error -32600 "Invalid Request")
        json_response "null" "" "${_mdm_err}"
        return 0
    fi

    mcp_dispatch_single "${_mdm_line}"
}

mcp_route_request() {
    _mrr_id="${1:-null}"
    _mrr_method="${2:-}"
    _mrr_params="${3:-"{}"}"
    _mrr_is_notif="${4:-false}"

    case "${_mrr_method}" in
        initialize)
            handle_initialize "${_mrr_id}" "${_mrr_params}"
            ;;
        notifications/initialized|initialized)
            if [ "${_mrr_is_notif}" != "true" ]; then
                _mrr_err=$(mcp_error -32600 "Invalid Request: notification method must not include an id")
                json_response "${_mrr_id}" "" "${_mrr_err}"
                return 0
            fi
            handle_initialized
            ;;
        notifications/*)
            if [ "${_mrr_is_notif}" != "true" ]; then
                _mrr_err=$(mcp_error -32600 "Invalid Request: notification method must not include an id")
                json_response "${_mrr_id}" "" "${_mrr_err}"
            fi
            return 0
            ;;
        ping)
            handle_ping "${_mrr_id}"
            ;;
        tools/list)
            handle_tools_list "${_mrr_id}" "${_mrr_params}"
            ;;
        tools/call)
            handle_tools_call "${_mrr_id}" "${_mrr_params}"
            ;;
        resources/list)
            handle_resources_list "${_mrr_id}" "${_mrr_params}"
            ;;
        resources/read)
            handle_resources_read "${_mrr_id}" "${_mrr_params}"
            ;;
        prompts/list)
            handle_prompts_list "${_mrr_id}" "${_mrr_params}"
            ;;
        prompts/get)
            handle_prompts_get "${_mrr_id}" "${_mrr_params}"
            ;;
        *)
            if command -v mcp_custom_method_handler >/dev/null 2>&1; then
                # A subshell contains an explicit consumer exit. Its stdout stays
                # attached to the dispatcher, so no callback output is captured,
                # truncated, or replayed. The dispatcher converts the status.
                if (mcp_custom_method_handler "${_mrr_id}" "${_mrr_method}" "${_mrr_params}" "${_mrr_is_notif}"); then
                    return 0
                else
                    _mrr_status=$?
                    return "${_mrr_status}"
                fi
            fi
            if [ "${_mrr_is_notif}" != "true" ] && [ "${_mrr_id}" != "null" ] && [ -n "${_mrr_id}" ]; then
                mcp_method_not_found "${_mrr_id}" "${_mrr_method}"
            fi
            ;;
    esac
}

mcp_dispatch_single() {
    _mds_message="${1}"

    # Extract fields directly from JSON instead of reparsing decoded values from
    # a line-oriented key/value stream. Compact JSON preserves ID type/escapes.
    if ! printf '%s' "${_mds_message}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _mds_err=$(mcp_error -32600 "Invalid Request")
        json_response "null" "" "${_mds_err}"
        return 0
    fi
    _mds_jsonrpc=$(printf '%s' "${_mds_message}" | jq -r 'if .jsonrpc == "2.0" then "2.0" else "" end' 2>/dev/null || echo "")
    _mds_is_notif=$(printf '%s' "${_mds_message}" | jq -r 'if has("id") then "false" else "true" end' 2>/dev/null || echo "false")
    _mds_id=$(printf '%s' "${_mds_message}" | jq -c 'if has("id") then .id else null end' 2>/dev/null || echo "null")
    _mds_method_json=$(printf '%s' "${_mds_message}" | jq -c 'if (.method | type) == "string" then .method else "" end' 2>/dev/null || echo '""')
    _mds_method=$(printf '%s' "${_mds_method_json}" | jq -r . 2>/dev/null || echo "")
    _mds_params=$(printf '%s' "${_mds_message}" | jq -c '.params // {}' 2>/dev/null || echo "{}")

    # An ID-less object never receives a response, even when its envelope is
    # invalid. Only route notifications after validating their version/method.
    if [ "${_mds_is_notif}" = "true" ]; then
        if [ "${_mds_jsonrpc}" != "2.0" ] || [ -z "${_mds_method}" ]; then
            return 0
        fi
        mcp_route_request "${_mds_id}" "${_mds_method}" "${_mds_params}" "true" >/dev/null || true
        return 0
    fi

    if [ "${_mds_jsonrpc}" != "2.0" ]; then
        _mds_err=$(mcp_error -32600 "Invalid Request")
        json_response "${_mds_id}" "" "${_mds_err}"
        return 0
    fi

    if [ -z "${_mds_method}" ]; then
        if printf '%s' "${_mds_message}" | jq -e 'has("result") or has("error")' >/dev/null 2>&1; then
            return 0
        fi
        _mds_err=$(mcp_error -32600 "Invalid Request: missing method")
        json_response "${_mds_id}" "" "${_mds_err}"
        return 0
    fi

    # Keep routing in the current shell to preserve handler state, but stage its
    # stdout. A failed consumer may have written a partial response before its
    # nonzero return; discard that output and emit exactly one internal error.
    if ! _mds_route_file=$(mktemp "${TMPDIR:-/tmp}/mcp-dispatch.XXXXXX"); then
        _mds_err=$(mcp_error -32603 "Internal error")
        json_response "${_mds_id}" "" "${_mds_err}"
        return 0
    fi
    _mds_route_status=0
    mcp_route_request "${_mds_id}" "${_mds_method}" "${_mds_params}" "false" > "${_mds_route_file}" || _mds_route_status=$?
    if [ "${_mds_route_status}" -ne 0 ]; then
        rm -f "${_mds_route_file}" || true
        _mds_err=$(mcp_error -32603 "Internal error")
        json_response "${_mds_id}" "" "${_mds_err}"
    else
        cat "${_mds_route_file}"
        rm -f "${_mds_route_file}" || true
    fi
    return 0
}

route_mcp_message() {
    mcp_dispatch_message "$@"
}

process_mcp_line() {
    mcp_dispatch_message "$@"
}

# ============================================================================
# TRANSPORT: STDIO
# ============================================================================

mcp_stdio_server() {
    while IFS= read -r _stdio_line || [ -n "${_stdio_line}" ]; do
        _stdio_line="${_stdio_line%"${MCP_CR}"}"
        if [ -z "${_stdio_line}" ]; then
            continue
        fi
        mcp_dispatch_message "${_stdio_line}"
    done
}

# ============================================================================
# TRANSPORT: STREAMABLE-HTTP (MCP 2025-03-26 specification)
# ============================================================================

check_curl_available() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    else
        echo "WARNING: curl not found, HTTP client features may be limited" >&2
        return 1
    fi
}

mcp_generate_session_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        _rand=$(awk 'BEGIN{srand(); printf "%d", int(rand()*100000)}' 2>/dev/null || echo "$$")
        printf 'mcp-%s-%s-%s\n' "$(date +%s)" "$$" "${_rand}"
    fi
}

extract_jsonrpc_from_post() {
    _ejp_body="${1:-}"
    if [ -z "${_ejp_body}" ]; then
        echo ""
        return 0
    fi
    if printf '%s' "${_ejp_body}" | jq -e . >/dev/null 2>&1; then
        printf '%s' "${_ejp_body}" | jq -c '.'
    else
        echo ""
    fi
}

# Print a canonical unsigned decimal integer, rejecting signs, whitespace,
# fractions, exponents, and empty values before any numeric shell test is used.
mcp_http_normalize_uint() {
    _mhnu_value="${1:-}"
    case "${_mhnu_value}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    while [ "${#_mhnu_value}" -gt 1 ] && [ "${_mhnu_value#0}" != "${_mhnu_value}" ]; do
        _mhnu_value="${_mhnu_value#0}"
    done
    printf '%s\n' "${_mhnu_value}"
}

mcp_http_body_limit() {
    _mhbl_limit=$(mcp_http_normalize_uint "${MCP_HTTP_MAX_BODY_BYTES}") || return 1
    # Keep subsequent awk comparisons exactly representable and dd counts
    # practical on all supported POSIX platforms.
    if [ "${#_mhbl_limit}" -gt 10 ]; then
        return 1
    fi
    if [ "${#_mhbl_limit}" -eq 10 ] && \
       awk -v n="${_mhbl_limit}" 'BEGIN { exit !(n > 2147483647) }'; then
        return 1
    fi
    printf '%s\n' "${_mhbl_limit}"
}

mcp_http_validate_bind_host() {
    _mhvb_host=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "${_mhvb_host}" in
        localhost|127.0.0.1|::1|\[::1\]) return 0 ;;
    esac
    if [ "${MCP_HTTP_ALLOW_NON_LOOPBACK}" = "true" ]; then
        return 0
    fi
    echo "ERROR: Refusing non-loopback HTTP bind '${1:-}'. Set MCP_HTTP_ALLOW_NON_LOOPBACK=true explicitly to override." >&2
    return 1
}

mcp_http_origin_allowed() {
    _mhoa_origin="${1:-}"
    # Non-browser clients commonly omit Origin. An explicitly empty Origin is
    # rejected by the request parser rather than treated as absent.
    if [ -z "${_mhoa_origin}" ]; then
        return 0
    fi
    _mhoa_origin=$(printf '%s' "${_mhoa_origin}" | tr '[:upper:]' '[:lower:]')
    _mhoa_list="${MCP_HTTP_ALLOWED_ORIGINS}"
    if [ -z "${_mhoa_list}" ]; then
        _mhoa_list="http://localhost https://localhost http://127.0.0.1 https://127.0.0.1 http://[::1] https://[::1] http://localhost:${MCP_HTTP_PORT} https://localhost:${MCP_HTTP_PORT} http://127.0.0.1:${MCP_HTTP_PORT} https://127.0.0.1:${MCP_HTTP_PORT} http://[::1]:${MCP_HTTP_PORT} https://[::1]:${MCP_HTTP_PORT}"
    fi
    # Origin contains no whitespace, so comma/whitespace tokenization cannot
    # introduce pattern matching; grep -F -x performs an exact comparison.
    printf '%s\n' "${_mhoa_list}" | tr ',' '\n' | \
        awk '{ for (i = 1; i <= NF; i++) print tolower($i) }' | \
        grep -F -x -e "${_mhoa_origin}" >/dev/null 2>&1
}

mcp_http_init_state() {
    if [ -n "${MCP_HTTP_STATE_DIR}" ]; then
        if [ ! -d "${MCP_HTTP_STATE_DIR}" ] || [ ! -w "${MCP_HTTP_STATE_DIR}" ]; then
            echo "ERROR: MCP HTTP state directory is not writable: ${MCP_HTTP_STATE_DIR}" >&2
            return 1
        fi
    else
        _mhis_dir=$(mktemp -d "${TMPDIR:-/tmp}/mcp-sdk-http.XXXXXX") || {
            echo "ERROR: Unable to create MCP HTTP state directory" >&2
            return 1
        }
        chmod 700 "${_mhis_dir}" 2>/dev/null || {
            rm -rf "${_mhis_dir}" 2>/dev/null || true
            echo "ERROR: Unable to secure MCP HTTP state directory" >&2
            return 1
        }
        MCP_HTTP_STATE_DIR="${_mhis_dir}"
        # Only the process that creates the directory owns its cleanup. Workers
        # inherit MCP_HTTP_STATE_DIR but start with an empty MCP_TEMP_FILES list.
        mcp_register_temp_file "${MCP_HTTP_STATE_DIR}"
    fi
    export MCP_HTTP_STATE_DIR
}

mcp_http_current_session() {
    [ -n "${MCP_HTTP_STATE_DIR}" ] || return 1
    for _mhcur_file in "${MCP_HTTP_STATE_DIR}"/session-*; do
        [ -f "${_mhcur_file}" ] || continue
        _mhcur_name="${_mhcur_file##*/}"
        _mhcur_sid="${_mhcur_name#session-}"
        case "${_mhcur_sid}" in
            ''|*[!A-Za-z0-9._-]*) continue ;;
        esac
        printf '%s\n' "${_mhcur_sid}"
        return 0
    done
    return 1
}

mcp_http_create_session() {
    mcp_http_init_state || return 1
    _mhcs_sid=$(mcp_generate_session_id) || return 1
    case "${_mhcs_sid}" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    if ! (umask 077; : > "${MCP_HTTP_STATE_DIR}/session-${_mhcs_sid}"); then
        return 1
    fi
    MCP_SESSION_ID="${_mhcs_sid}"
}

mcp_http_delete_session() {
    _mhds_req="${1:-}"
    _mhds_active=$(mcp_http_current_session 2>/dev/null || true)
    if [ -z "${_mhds_active}" ] || [ "${_mhds_req}" != "${_mhds_active}" ]; then
        return 1
    fi
    # The filename comes from the validated server-generated active ID, never
    # directly from an HTTP header. Deleting an old session cannot unlink a new
    # session with a different ID.
    rm -f "${MCP_HTTP_STATE_DIR}/session-${_mhds_active}" || return 1
    MCP_SESSION_ID=""
}

send_http_response() {
    _shr_body="${1:-}"
    _shr_status="${2:-200}"
    _shr_ctype="${3:-application/json}"
    _shr_sid="${4:-${MCP_SESSION_ID:-}}"

    case "${_shr_status}" in
        200) _shr_text="OK" ;;
        202) _shr_text="Accepted" ;;
        204) _shr_text="No Content" ;;
        400) _shr_text="Bad Request" ;;
        403) _shr_text="Forbidden" ;;
        404) _shr_text="Not Found" ;;
        405) _shr_text="Method Not Allowed" ;;
        406) _shr_text="Not Acceptable" ;;
        413) _shr_text="Payload Too Large" ;;
        500) _shr_text="Internal Server Error" ;;
        *)   _shr_text="OK" ;;
    esac

    _shr_len=$(printf '%s' "${_shr_body}" | wc -c | tr -d ' ')

    printf 'HTTP/1.1 %s %s\r\n' "${_shr_status}" "${_shr_text}"
    if [ -n "${_shr_ctype}" ] && [ "${_shr_len}" -gt 0 ]; then
        printf 'Content-Type: %s\r\n' "${_shr_ctype}"
    fi
    if [ -n "${_shr_sid}" ]; then
        printf 'Mcp-Session-Id: %s\r\n' "${_shr_sid}"
    fi
    printf 'Cache-Control: no-cache\r\n'
    printf 'Connection: close\r\n'
    printf 'Content-Length: %d\r\n' "${_shr_len}"
    printf '\r\n'
    if [ "${_shr_len}" -gt 0 ]; then
        printf '%s' "${_shr_body}"
    fi
}

# Send a JSON-RPC lifecycle error for requests, but no body for a payload
# consisting solely of valid notifications. For a mixed batch, retain the first
# request ID in the existing single-error HTTP response format.
mcp_http_lifecycle_error() {
    _mhle_msg="${1:-}"
    _mhle_status="${2:-500}"
    _mhle_code="${3:--32603}"
    _mhle_message="${4:-Internal error}"

    if printf '%s' "${_mhle_msg}" | jq -e '
        def is_notification:
            type == "object" and .jsonrpc == "2.0" and
            (.method | type) == "string" and (has("id") | not);
        if type == "object" then is_notification
        elif type == "array" then length > 0 and all(.[]; is_notification)
        else false end' >/dev/null 2>&1; then
        send_http_response "" "${_mhle_status}" "text/plain" ""
        return 0
    fi

    _mhle_id=$(printf '%s' "${_mhle_msg}" | jq -c '
        if type == "object" then
            if has("id") then .id else null end
        elif type == "array" then
            ([.[] | select(type == "object" and has("id")) | .id] |
                if length > 0 then .[0] else null end)
        else null end' 2>/dev/null || printf 'null')
    _mhle_err=$(mcp_error "${_mhle_code}" "${_mhle_message}")
    _mhle_body=$(json_response "${_mhle_id}" "" "${_mhle_err}")
    send_http_response "${_mhle_body}" "${_mhle_status}" "application/json" ""
}

send_http_sse_response() {
    _shs_json="${1:-}"
    _shs_status="${2:-200}"
    _shs_sid="${3:-${MCP_SESSION_ID:-}}"
    _shs_body=$(printf 'event: message\ndata: %s\n\n' "${_shs_json}")
    send_http_response "${_shs_body}" "${_shs_status}" "text/event-stream" "${_shs_sid}"
}

handle_http_post() {
    _hhp_body="${1:-}"
    _hhp_accept="${2:-application/json, text/event-stream}"
    _hhp_req_sid="${3:-}"

    _hhp_limit=$(mcp_http_body_limit 2>/dev/null || true)
    if [ -z "${_hhp_limit}" ]; then
        mcp_http_lifecycle_error "${_hhp_body}" 500 -32603 "Invalid MCP_HTTP_MAX_BODY_BYTES configuration"
        return 0
    fi
    _hhp_size=$(printf '%s' "${_hhp_body}" | wc -c | tr -d '[:space:]')
    if [ "${#_hhp_size}" -gt 10 ] || \
       awk -v have="${_hhp_size}" -v max="${_hhp_limit}" 'BEGIN { exit !(have > max) }'; then
        send_http_response "" 413 "text/plain" ""
        return 0
    fi

    if ! printf '%s' "${_hhp_body}" | mcp_utf8_valid || \
       ! printf '%s' "${_hhp_body}" | jq . >/dev/null 2>&1; then
        _hhp_err=$(json_response "null" "" "$(mcp_error -32700 "Parse error")")
        send_http_response "${_hhp_err}" 400 "application/json"
        return 0
    fi

    _hhp_msg=$(extract_jsonrpc_from_post "${_hhp_body}")
    if [ -z "${_hhp_msg}" ]; then
        _hhp_err=$(json_response "null" "" "$(mcp_error -32600 "Invalid JSON-RPC message")")
        send_http_response "${_hhp_err}" 400 "application/json"
        return 0
    fi

    # Session markers live in the shared state directory, not just in this
    # worker's variables. Once initialized, every request must present the
    # active session ID; an unknown supplied ID is never implicitly adopted.
    _hhp_active_sid=$(mcp_http_current_session 2>/dev/null || true)
    if [ -n "${_hhp_active_sid}" ]; then
        if [ -z "${_hhp_req_sid}" ]; then
            mcp_http_lifecycle_error "${_hhp_msg}" 400 -32600 "Missing Mcp-Session-Id"
            return 0
        fi
        if [ "${_hhp_req_sid}" != "${_hhp_active_sid}" ]; then
            mcp_http_lifecycle_error "${_hhp_msg}" 404 -32600 "Invalid or expired Mcp-Session-Id"
            return 0
        fi
        MCP_SESSION_ID="${_hhp_active_sid}"
    elif [ -n "${_hhp_req_sid}" ]; then
        mcp_http_lifecycle_error "${_hhp_msg}" 404 -32600 "Invalid or expired Mcp-Session-Id"
        return 0
    else
        MCP_SESSION_ID=""
        _hhp_has_initialize=$(printf '%s' "${_hhp_msg}" | jq -r '
            if type == "object" then
                (.jsonrpc == "2.0" and .method == "initialize" and has("id"))
            elif type == "array" then
                any(.[]; type == "object" and .jsonrpc == "2.0" and .method == "initialize" and has("id"))
            else false end' 2>/dev/null || echo "false")
        if [ "${_hhp_has_initialize}" = "true" ]; then
            if ! mcp_http_create_session; then
                mcp_http_lifecycle_error "${_hhp_msg}" 500 -32603 "Unable to create MCP session"
                return 0
            fi
        fi
    fi

    _hhp_resp=$(mcp_dispatch_message "${_hhp_msg}")

    if [ -z "${_hhp_resp}" ]; then
        send_http_response "" 202 "" "${MCP_SESSION_ID}"
        return 0
    fi

    # Check if accept_header contains text/event-stream and NOT application/json using POSIX parameter expansion
    if [ "${_hhp_accept#*text/event-stream}" != "${_hhp_accept}" ] && [ "${_hhp_accept#*application/json}" = "${_hhp_accept}" ]; then
        send_http_sse_response "${_hhp_resp}" 200 "${MCP_SESSION_ID}"
    else
        send_http_response "${_hhp_resp}" 200 "application/json" "${MCP_SESSION_ID}"
    fi
}

handle_http_get() {
    _hhg_accept="${1:-}"
    _hhg_req_sid="${2:-}"
    _hhg_active_sid=$(mcp_http_current_session 2>/dev/null || true)
    if [ -n "${_hhg_active_sid}" ] && [ -z "${_hhg_req_sid}" ]; then
        send_http_response "" 400 "text/plain" ""
        return 0
    fi
    if { [ -n "${_hhg_active_sid}" ] && [ "${_hhg_req_sid}" != "${_hhg_active_sid}" ]; } || \
       { [ -z "${_hhg_active_sid}" ] && [ -n "${_hhg_req_sid}" ]; }; then
        send_http_response "" 404 "text/plain" ""
        return 0
    fi
    MCP_SESSION_ID="${_hhg_active_sid}"
    if [ "${_hhg_accept#*text/event-stream}" != "${_hhg_accept}" ]; then
        _hhg_body="$(printf ': streamable-http sse stream open\n\n')"
        send_http_response "${_hhg_body}" 200 "text/event-stream" "${MCP_SESSION_ID}"
    else
        send_http_response "" 405 "text/plain" "${MCP_SESSION_ID}"
    fi
}

handle_http_delete() {
    _hhd_req_sid="${1:-}"
    _hhd_active_sid=$(mcp_http_current_session 2>/dev/null || true)
    if [ -n "${_hhd_active_sid}" ] && [ -z "${_hhd_req_sid}" ]; then
        send_http_response "" 400 "text/plain" ""
        return 0
    fi
    if [ -z "${_hhd_active_sid}" ] || [ "${_hhd_req_sid}" != "${_hhd_active_sid}" ]; then
        send_http_response "" 404 "text/plain" ""
        return 0
    fi
    if ! mcp_http_delete_session "${_hhd_req_sid}"; then
        send_http_response "" 500 "text/plain" ""
        return 0
    fi
    MCP_INITIALIZED="false"
    send_http_response "" 200 "text/plain" ""
}

handle_http_request_stream() {
    _hhrs_req_line=""
    if ! IFS= read -r _hhrs_req_line; then
        return 1
    fi
    _hhrs_req_line="${_hhrs_req_line%"${MCP_CR}"}"
    if [ -z "${_hhrs_req_line}" ]; then
        return 1
    fi

    # Extract method, path, and version using POSIX parameter expansion
    _hhrs_method="${_hhrs_req_line%% *}"
    _hhrs_rest="${_hhrs_req_line#* }"
    _hhrs_path="${_hhrs_rest%% *}"

    _hhrs_clen=""
    _hhrs_clen_seen="false"
    _hhrs_clen_invalid="false"
    _hhrs_accept="application/json, text/event-stream"
    _hhrs_session=""
    _hhrs_origin=""
    _hhrs_origin_seen="false"
    _hhrs_origin_invalid="false"
    while IFS= read -r _hhrs_hline; do
        _hhrs_hline="${_hhrs_hline%"${MCP_CR}"}"
        if [ -z "${_hhrs_hline}" ]; then
            break
        fi
        _hhrs_hname=$(printf '%s' "${_hhrs_hline%%:*}" | tr '[:upper:]' '[:lower:]')
        _hhrs_hval="${_hhrs_hline#*:}"
        _hhrs_hval=$(printf '%s\n' "${_hhrs_hval}" | awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }')
        case "${_hhrs_hname}" in
            content-length)
                if [ "${_hhrs_clen_seen}" = "true" ]; then
                    _hhrs_clen_invalid="true"
                else
                    _hhrs_clen="${_hhrs_hval}"
                    _hhrs_clen_seen="true"
                fi
                ;;
            accept)         _hhrs_accept="${_hhrs_hval}" ;;
            mcp-session-id) _hhrs_session="${_hhrs_hval}" ;;
            origin)
                if [ "${_hhrs_origin_seen}" = "true" ]; then
                    _hhrs_origin_invalid="true"
                else
                    _hhrs_origin="${_hhrs_hval}"
                    _hhrs_origin_seen="true"
                fi
                ;;
        esac
    done

    if [ "${_hhrs_origin_invalid}" = "true" ] || \
       { [ "${_hhrs_origin_seen}" = "true" ] && [ -z "${_hhrs_origin}" ]; } || \
       { [ "${_hhrs_origin_seen}" = "true" ] && ! mcp_http_origin_allowed "${_hhrs_origin}"; }; then
        send_http_response "" 403 "text/plain" ""
        return 0
    fi
    if [ "${_hhrs_clen_invalid}" = "true" ]; then
        send_http_response "" 400 "text/plain" ""
        return 0
    fi

    _hhrs_limit=$(mcp_http_body_limit 2>/dev/null || true)
    if [ -z "${_hhrs_limit}" ]; then
        send_http_response "" 500 "text/plain" ""
        return 0
    fi
    if [ "${_hhrs_clen_seen}" = "true" ]; then
        _hhrs_clen=$(mcp_http_normalize_uint "${_hhrs_clen}" 2>/dev/null || true)
        if [ -z "${_hhrs_clen}" ]; then
            send_http_response "" 400 "text/plain" ""
            return 0
        fi
        if [ "${#_hhrs_clen}" -gt 10 ] || \
           awk -v have="${_hhrs_clen}" -v max="${_hhrs_limit}" 'BEGIN { exit !(have > max) }'; then
            send_http_response "" 413 "text/plain" ""
            return 0
        fi
    else
        _hhrs_clen=0
    fi

    _hhrs_body=""
    if [ "${_hhrs_clen}" -gt 0 ]; then
        # Command substitution strips trailing newlines. Append one sentinel so
        # the byte count reflects exactly what dd read, including trailing LFs.
        _hhrs_body=$(dd bs=1 count="${_hhrs_clen}" 2>/dev/null; printf 'x')
        _hhrs_read_size=$(printf '%s' "${_hhrs_body}" | wc -c | tr -d '[:space:]')
        if [ "${_hhrs_read_size}" -ne "$((_hhrs_clen + 1))" ]; then
            send_http_response "" 400 "text/plain" ""
            return 0
        fi
        _hhrs_body="${_hhrs_body%?}"
    fi

    case "${_hhrs_method}" in
        POST)
            handle_http_post "${_hhrs_body}" "${_hhrs_accept}" "${_hhrs_session}"
            ;;
        GET)
            handle_http_get "${_hhrs_accept}" "${_hhrs_session}"
            ;;
        DELETE)
            handle_http_delete "${_hhrs_session}"
            ;;
        *)
            send_http_response "" 405 "text/plain"
            ;;
    esac
}

mcp_streamable_http_server() {
    _mshs_port="${1:-${MCP_HTTP_PORT:-8080}}"
    _mshs_host="${2:-${MCP_HTTP_HOST:-127.0.0.1}}"

    if ! mcp_http_validate_bind_host "${_mshs_host}"; then
        return 1
    fi
    if ! mcp_http_init_state; then
        return 1
    fi
    MCP_HTTP_PORT="${_mshs_port}"
    MCP_HTTP_HOST="${_mshs_host}"
    # socat workers are fresh processes; export both configuration and the
    # private state directory so every request sees the same policy/session.
    export MCP_HTTP_STATE_DIR MCP_HTTP_PORT MCP_HTTP_HOST \
        MCP_HTTP_ALLOWED_ORIGINS MCP_HTTP_MAX_BODY_BYTES MCP_HTTP_ALLOW_NON_LOOPBACK

    if [ ! -t 0 ] && [ "${MCP_HTTP_LISTEN:-false}" != "true" ]; then
        _mshs_first=""
        if IFS= read -r _mshs_first; then
            _mshs_stripped="${_mshs_first%"${MCP_CR}"}"
            case "${_mshs_stripped}" in
                "POST "*|"GET "*|"DELETE "*|"OPTIONS "*|"HEAD "*)
                    { printf '%s\r\n' "${_mshs_stripped}"; cat; } | handle_http_request_stream
                    return 0
                    ;;
                *)
                    if [ -n "${_mshs_stripped}" ]; then
                        _mshs_full=$(printf '%s\n' "${_mshs_stripped}"; cat)
                        handle_http_post "${_mshs_full}"
                        return 0
                    fi
                    ;;
            esac
        fi
    fi

    if command -v socat >/dev/null 2>&1; then
        socat TCP-LISTEN:"${_mshs_port}",bind="${_mshs_host}",reuseaddr,fork EXEC:"sh ${0} --http-worker" &
        MCP_HTTP_SERVER_PID=$!
        wait "${MCP_HTTP_SERVER_PID}"
    elif command -v nc >/dev/null 2>&1; then
        _mshs_fifo="$(mktemp -u "${TMPDIR:-/tmp}/mcp_http_fifo.XXXXXX")"
        mkfifo "${_mshs_fifo}"
        mcp_register_temp_file "${_mshs_fifo}"
        while true; do
            handle_http_request_stream < "${_mshs_fifo}" | nc -l "${_mshs_host}" "${_mshs_port}" > "${_mshs_fifo}" || break
        done
    else
        echo "ERROR: Neither socat nor nc found to bind TCP port ${_mshs_port} for streamable-http" >&2
        return 1
    fi
}

mcp_http_server() {
    mcp_streamable_http_server "$@"
}

get_transport_mode() {
    echo "${MCP_TRANSPORT:-stdio}"
}

mcp_main() {
    _mm_mode=$(get_transport_mode)
    case "${_mm_mode}" in
        http|streamable-http)
            mcp_streamable_http_server "${MCP_HTTP_PORT:-8080}" "${MCP_HTTP_HOST:-127.0.0.1}"
            ;;
        stdio|*)
            mcp_stdio_server
            ;;
    esac
}

if [ "${MCP_SDK_SOURCED:-false}" != "true" ]; then
    case "${0##*/}" in
        mcp-sdk.sh|mcp-sdk)
            while [ $# -gt 0 ]; do
                case "$1" in
                    --stdio)
                        export MCP_TRANSPORT="stdio"
                        ;;
                    --http|--streamable-http)
                        export MCP_TRANSPORT="streamable-http"
                        ;;
                    --listen)
                        export MCP_HTTP_LISTEN="true"
                        ;;
                    --http-worker)
                        handle_http_request_stream
                        exit 0
                        ;;
                    --port)
                        shift
                        export MCP_HTTP_PORT="${1:-8080}"
                        ;;
                    --host)
                        shift
                        export MCP_HTTP_HOST="${1:-127.0.0.1}"
                        ;;
                    *)
                        ;;
                esac
                shift
            done
            mcp_main
            ;;
    esac
fi
