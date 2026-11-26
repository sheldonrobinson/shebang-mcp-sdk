#!/usr/bin/env sh
# sdk-utils.sh - Development Utilities for Shebang MCP SDK Consumers
#
# Development-time utilities only. This file is NOT part of the core MCP SDK
# runtime and should NOT be bundled with generated consumer MCP servers.
#
# Utilities:
#   sdk_generate_handler <json-schema> [bash|pwsh]
#   sdk-generate-handler <json-schema> [bash|pwsh]
#
# Direct POSIX sh launcher:
#   ./bin/sdk-utils.sh '{"server":{},"tools":[...]}' bash > handlers.sh
#   ./bin/sdk-utils.sh '{"server":{},"tools":[...]}' pwsh > handlers.ps1
#
# Or source this file explicitly in a development shell and call the function.
# Generated Bash must be sourced after mcp-sdk.sh. Generated PowerShell must be
# dot-sourced after importing mcp-sdk.psm1.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
export PLUGIN_ROOT

# Source core SDK for consumers that generate and test handlers in one shell.
# Generation itself depends only on POSIX sh utilities and jq.
if [ -f "${PLUGIN_ROOT}/bin/mcp-sdk.sh" ]; then
    . "${PLUGIN_ROOT}/bin/mcp-sdk.sh"
fi

# Normalize the documented { server: {}, tools: [] } contract into the exact
# tools/list catalog. Keeping the catalog as JSON avoids generating source from
# individual names/descriptions and preserves every JSON string safely.
sdk_generate_handler() {
    _sgh_schema="${1:-}"
    _sgh_lang="${2:-bash}"

    if [ "$#" -gt 2 ]; then
        printf 'Error: sdk-generate-handler accepts only a schema and optional language\n' >&2
        return 2
    fi
    if [ -z "${_sgh_schema}" ]; then
        printf 'Error: sdk-generate-handler requires a JSON schema argument\n' >&2
        return 1
    fi

    _sgh_lang=$(printf '%s' "${_sgh_lang}" | tr '[:upper:]' '[:lower:]')
    case "${_sgh_lang}" in
        bash|pwsh)
            ;;
        *)
            printf 'Error: unsupported language "%s"; supported languages are bash and pwsh\n' "${_sgh_lang}" >&2
            return 2
            ;;
    esac

    if ! _sgh_catalog=$(printf '%s' "${_sgh_schema}" | jq -c -s '
        if length != 1 then
            error("Schema must contain exactly one JSON value")
        else
            .[0]
        end
        | if type != "object" then
            error("Schema root must be a JSON object")
          elif has("server") and .server != null and (.server | type) != "object" then
            error("Schema server must be a JSON object")
          elif (.tools | type) != "array" then
            error("Schema must contain a top-level tools array")
          elif (.tools | length) == 0 then
            error("Schema tools array must contain at least one tool")
          else
            {tools: [
                .tools | to_entries[]
                | .key as $tool_index
                | .value as $tool
                | if ($tool | type) != "object" then
                    error("Tool at index \($tool_index + 1) must be a JSON object")
                  elif ($tool.name | type) != "string" then
                    error("Tool at index \($tool_index + 1) requires a string name")
                  elif ($tool.name | length) == 0 or ($tool.name | test("\\S") | not) then
                    error("Tool at index \($tool_index + 1) requires a non-empty name")
                  else
                    $tool.name as $name
                    | (if ($tool | has("description")) and $tool.description != null then
                        if ($tool.description | type) == "string" then
                            $tool.description
                        else
                            error("Description for tool \($name) must be a string")
                        end
                       else
                        "MCP tool"
                       end) as $description
                    | (if ($tool | has("parameters")) and $tool.parameters != null then
                        $tool.parameters
                       else
                        []
                       end) as $parameters
                    | if ($parameters | type) != "array" then
                        error("Parameters for tool \($name) must be an array")
                      else
                        [
                            $parameters | to_entries[]
                            | .key as $parameter_index
                            | .value as $parameter
                            | if ($parameter | type) != "object" then
                                error("Parameter at index \($parameter_index + 1) for tool \($name) must be a JSON object")
                              elif ($parameter.name | type) != "string" then
                                error("Parameter at index \($parameter_index + 1) for tool \($name) requires a string name")
                              elif ($parameter.name | length) == 0 then
                                error("Parameter at index \($parameter_index + 1) for tool \($name) requires a non-empty name")
                              else
                                $parameter.name as $parameter_name
                                | (if ($parameter | has("type")) and $parameter.type != null then
                                    if ($parameter.type | type) == "string" then
                                        $parameter.type | ascii_downcase
                                    else
                                        error("Type for parameter \($parameter_name) on tool \($name) must be a string")
                                    end
                                   else
                                    "string"
                                   end) as $parameter_type
                                | ({
                                    string: "string",
                                    number: "number",
                                    integer: "number",
                                    float: "number",
                                    boolean: "boolean",
                                    array: "array",
                                    object: "object"
                                  } as $type_map
                                  | if ($type_map | has($parameter_type) | not) then
                                        error("Unsupported type \($parameter_type) for parameter \($parameter_name) on tool \($name)")
                                    else
                                        $type_map[$parameter_type]
                                    end) as $input_type
                                | (if ($parameter | has("description")) and $parameter.description != null then
                                    if ($parameter.description | type) == "string" then
                                        {description: $parameter.description}
                                    else
                                        error("Description for parameter \($parameter_name) on tool \($name) must be a string")
                                    end
                                   else
                                    {}
                                   end) as $description_field
                                | (if ($parameter | has("required")) and $parameter.required != null then
                                    if ($parameter.required | type) == "boolean" then
                                        $parameter.required
                                    else
                                        error("Required flag for parameter \($parameter_name) on tool \($name) must be boolean")
                                    end
                                   else
                                    false
                                   end) as $required
                                | {
                                    name: $parameter_name,
                                    definition: ({type: $input_type} + $description_field),
                                    required: $required
                                  }
                              end
                        ] as $normalized_parameters
                        | if ([$normalized_parameters[].name] | unique | length) != ($normalized_parameters | length) then
                            error("Duplicate parameter names for tool \($name) are not supported")
                          else
                            {
                                name: $name,
                                description: $description,
                                inputSchema: {
                                    type: "object",
                                    properties: (reduce $normalized_parameters[] as $parameter
                                        ({}; .[$parameter.name] = $parameter.definition)),
                                    required: [$normalized_parameters[] | select(.required) | .name]
                                }
                            }
                          end
                      end
                  end
            ]}
          end
        | if ([.tools[].name] | unique | length) != (.tools | length) then
            error("Duplicate tool names are not supported")
          else
            .
          end
    '); then
        printf 'Error: invalid tool schema\n' >&2
        return 1
    fi

    case "${_sgh_lang}" in
        bash)
            # jq @sh emits a POSIX shell-quoted literal, including embedded
            # apostrophes. No generator-time variables are needed at runtime.
            if ! _sgh_catalog_shell=$(printf '%s' "${_sgh_catalog}" | jq -Rr '@sh' | tr -d '\r'); then
                printf 'Error: could not encode generated Bash catalog\n' >&2
                return 1
            fi
            cat <<'BASH_HEADER'
# Auto-generated by sdk-generate-handler. Development-time generator output.
# Source this file after sourcing the core mcp-sdk.sh module.
BASH_HEADER
            printf '_SHEBANG_GENERATED_TOOL_CATALOG=%s\n\n' "${_sgh_catalog_shell}"
            cat <<'BASH_EOF'
_shebang_generated_tool_catalog() {
    printf '%s\n' "${_SHEBANG_GENERATED_TOOL_CATALOG}"
}

handle_list_tools() {
    _sgh_list_id="${1:-null}"
    _sgh_list_result=$(_shebang_generated_tool_catalog | jq -c '{tools:.tools}')
    json_response "${_sgh_list_id}" "${_sgh_list_result}"
}

handle_tools_call() {
    _sgh_call_id="${1:-null}"
    _sgh_call_params="${2:-"{}"}"

    if ! printf '%s' "${_sgh_call_params}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _sgh_call_err=$(mcp_error -32602 'Invalid params: expected a JSON object')
        json_response "${_sgh_call_id}" '' "${_sgh_call_err}"
        return 0
    fi

    _sgh_call_name=$(printf '%s' "${_sgh_call_params}" | jq -r \
        'if (.name | type) == "string" then .name else "" end')
    if [ -z "${_sgh_call_name}" ]; then
        _sgh_call_err=$(mcp_error -32602 'Invalid params: missing tool name')
        json_response "${_sgh_call_id}" '' "${_sgh_call_err}"
        return 0
    fi

    _sgh_call_tool=$(_shebang_generated_tool_catalog | jq -c \
        --arg name "${_sgh_call_name}" \
        'first(.tools[] | select(.name == $name))')
    if [ -z "${_sgh_call_tool}" ]; then
        _sgh_call_err=$(mcp_error -32601 "Tool not found: ${_sgh_call_name}")
        json_response "${_sgh_call_id}" '' "${_sgh_call_err}"
        return 0
    fi

    _sgh_call_args=$(printf '%s' "${_sgh_call_params}" | jq -c \
        'if has("arguments") and .arguments != null then .arguments else {} end')
    if ! printf '%s' "${_sgh_call_args}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _sgh_call_err=$(mcp_error -32602 'Invalid params: arguments must be a JSON object')
        json_response "${_sgh_call_id}" '' "${_sgh_call_err}"
        return 0
    fi

    # Presence is checked by key and null, not truthiness: false, zero, and an
    # empty string are valid supplied values and retain their original JSON type.
    _sgh_missing_required=$(jq -crn \
        --argjson tool "${_sgh_call_tool}" \
        --argjson args "${_sgh_call_args}" \
        '[$tool.inputSchema.required[]? as $name
          | select(($args | has($name) | not) or ($args[$name] == null))
          | $name] | join(", ")')
    if [ -n "${_sgh_missing_required}" ]; then
        _sgh_call_err=$(mcp_error -32602 \
            "Invalid params: missing required argument(s): ${_sgh_missing_required}")
        json_response "${_sgh_call_id}" '' "${_sgh_call_err}"
        return 0
    fi

    # TODO: Implement the selected tool logic here. _sgh_call_name is the
    # dispatched tool name and _sgh_tool_args is compact JSON retaining boolean,
    # numeric, string, array, object, and null values. Query it with jq as needed.
    _sgh_tool_args="${_sgh_call_args}"
    _sgh_call_result=$(jq -cn \
        --arg text "Tool ${_sgh_call_name} executed successfully" \
        '{content:[{type:"text",text:$text}],isError:false}')
    json_response "${_sgh_call_id}" "${_sgh_call_result}"
}
BASH_EOF
            ;;
        pwsh)
            # Base64 is a deterministic literal containing no PowerShell source
            # delimiters. UTF-8 decoding restores all names and descriptions.
            if ! _sgh_catalog_base64=$(printf '%s' "${_sgh_catalog}" | jq -Rr '@base64' | tr -d '\r'); then
                printf 'Error: could not encode generated PowerShell catalog\n' >&2
                return 1
            fi
            cat <<'PWSH_HEADER'
#Requires -Version 5.1
# Auto-generated by sdk-generate-handler. Development-time generator output.
# Dot-source this file after importing the core mcp-sdk.psm1 module.
PWSH_HEADER
            printf '$global:ShebangGeneratedToolCatalog = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("%s"))) -ErrorAction Stop\n\n' "${_sgh_catalog_base64}"
            cat <<'PWSH_EOF'
function global:Handle-ListTools {
    param($Id, $Params = @{})
    $tools = @($global:ShebangGeneratedToolCatalog.tools)
    return json-response -Id $Id -Result ([PSCustomObject]@{ tools = $tools })
}

function global:Handle-ToolsCall {
    param($Id, $Params = @{})

    $hasName = $false
    $nameValue = $null
    if ($Params -is [System.Collections.IDictionary]) {
        $hasName = $Params.Contains('name')
        if ($hasName) { $nameValue = $Params['name'] }
    }
    elseif ($null -ne $Params) {
        $nameProperty = $Params.PSObject.Properties['name']
        if ($null -ne $nameProperty) {
            $hasName = $true
            $nameValue = $nameProperty.Value
        }
    }
    $toolName = if ($hasName -and $null -ne $nameValue) { [string]$nameValue } else { '' }
    if ([string]::IsNullOrEmpty($toolName)) {
        $err = mcp-error -Code -32602 -Message 'Invalid params: missing tool name'
        return json-response -Id $Id -Error $err
    }

    $selectedTool = $null
    foreach ($candidate in @($global:ShebangGeneratedToolCatalog.tools)) {
        if ([string]$candidate.name -ceq $toolName) {
            $selectedTool = $candidate
            break
        }
    }
    if ($null -eq $selectedTool) {
        $err = mcp-error -Code -32601 -Message ('Tool not found: ' + $toolName)
        return json-response -Id $Id -Error $err
    }

    $hasArguments = $false
    $rawArguments = $null
    if ($Params -is [System.Collections.IDictionary]) {
        $hasArguments = $Params.Contains('arguments')
        if ($hasArguments) { $rawArguments = $Params['arguments'] }
    }
    elseif ($null -ne $Params) {
        $argumentsProperty = $Params.PSObject.Properties['arguments']
        if ($null -ne $argumentsProperty) {
            $hasArguments = $true
            $rawArguments = $argumentsProperty.Value
        }
    }

    # Core handlers may supply arguments as a JSON string, a hashtable produced
    # by ConvertFrom-Json -AsHashtable, or a PSCustomObject on PowerShell 5.1.
    $toolArgs = @{}
    if ($hasArguments -and $null -ne $rawArguments) {
        if ($rawArguments -is [string]) {
            try {
                $toolArgs = ConvertFrom-Json -InputObject $rawArguments -ErrorAction Stop
            }
            catch {
                $err = mcp-error -Code -32602 -Message 'Invalid params: arguments must be valid JSON'
                return json-response -Id $Id -Error $err
            }
        }
        else {
            $toolArgs = $rawArguments
        }
    }
    if ($toolArgs -isnot [System.Collections.IDictionary] -and
        $toolArgs -isnot [System.Management.Automation.PSCustomObject]) {
        $err = mcp-error -Code -32602 -Message 'Invalid params: arguments must be a JSON object'
        return json-response -Id $Id -Error $err
    }

    $missingRequired = New-Object 'System.Collections.Generic.List[string]'
    foreach ($requiredValue in @($selectedTool.inputSchema.required)) {
        if ($null -eq $requiredValue) { continue }
        $requiredName = [string]$requiredValue
        $argumentExists = $false
        if ($toolArgs -is [System.Collections.IDictionary]) {
            $argumentExists = ($toolArgs.Contains($requiredName) -and ($null -ne $toolArgs[$requiredName]))
        }
        else {
            $argumentProperty = $toolArgs.PSObject.Properties[$requiredName]
            $argumentExists = ($null -ne $argumentProperty -and $null -ne $argumentProperty.Value)
        }
        # False, zero, and an empty string are present values, not missing ones.
        if (-not $argumentExists) { $missingRequired.Add($requiredName) }
    }
    if ($missingRequired.Count -gt 0) {
        $message = 'Invalid params: missing required argument(s): ' + ($missingRequired.ToArray() -join ', ')
        $err = mcp-error -Code -32602 -Message $message
        return json-response -Id $Id -Error $err
    }

    # TODO: Implement the selected tool logic here. $selectedTool.name is the
    # dispatched tool name. $toolArgs is the original typed argument object;
    # boolean, number, and string values have not been coerced to strings.
    # Use $toolArgs['name'] for IDictionary or $toolArgs.name for PSCustomObject.
    $result = [ordered]@{
        content = @(
            [ordered]@{
                type = 'text'
                text = ('Tool ' + [string]$selectedTool.name + ' executed successfully')
            }
        )
        isError = $false
    }
    return json-response -Id $Id -Result $result
}
PWSH_EOF
            ;;
    esac
}

# POSIX function names cannot contain hyphens. Preserve the documented legacy
# alias on shells that support such names without making the file unparseable
# on strictly POSIX shells such as dash. The snake_case API and direct launcher
# are always available.
if (eval 'sdk-generate-handler() { return 0; }') >/dev/null 2>&1; then
    eval 'sdk-generate-handler() { sdk_generate_handler "$@"; }'
fi

# A direct launcher keeps generation available without sourcing development
# utilities into the normal server runtime. When sourced, no command is run.
case "${0##*/}" in
    sdk-utils.sh|sdk-utils)
        if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
            printf 'Usage: %s <json-schema> [bash|pwsh]\n' "$0" >&2
            exit 2
        fi
        if sdk_generate_handler "$@"; then
            exit 0
        else
            _sgh_exit_status=$?
            exit "${_sgh_exit_status}"
        fi
        ;;
esac
