#Requires -Version 5.1
# sdk-utils.psm1 - Development Utilities for Shebang MCP SDK Consumers
#
# This module contains development-time utilities only. It is NOT part of the
# core MCP SDK runtime and should NOT be bundled with generated consumer servers.
#
# Public utilities:
#   sdk-generate-handler -Schema <json-schema> [-Language pwsh|bash]
#   sdk_generate_handler -Schema <json-schema> [-Language pwsh|bash]
#
# PowerShell usage (write, then dot-source a generated file):
#   Import-Module "${PLUGIN_ROOT}/bin/sdk-utils.psm1"
#   $schema = Get-Content -LiteralPath ./schema.json -Raw
#   sdk-generate-handler -Schema $schema -Language pwsh |
#       Set-Content -LiteralPath ./handlers.ps1 -Encoding UTF8
#   Import-Module "${PLUGIN_ROOT}/bin/mcp-sdk.psm1"
#   . ./handlers.ps1
#
# Bash generation uses the same Schema parameter with -Language bash. Save its
# output as a UTF-8 shell script and source that file from Bash.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { (Resolve-Path (Join-Path $ScriptDir '..')).Path }
$env:PLUGIN_ROOT = $PluginRoot

# Source core SDK module for JSON helpers used by generated PowerShell handlers.
$SdkModule = Join-Path $PluginRoot 'bin\mcp-sdk.psm1'
if (Test-Path -LiteralPath $SdkModule) {
    Import-Module -Name $SdkModule -Force -DisableNameChecking -ErrorAction SilentlyContinue
}

# Return a PowerShell single-quoted string literal. ConvertTo-Json escapes all
# JSON control characters; this additionally protects apostrophes in JSON text.
function ConvertTo-SghPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# Return a Bash single-quoted string literal. Embedded apostrophes close the
# literal, emit an escaped apostrophe, and reopen it.
function ConvertTo-SghBashLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# Keep generated source ASCII-only so Windows PowerShell 5.1 also reads it
# correctly when a consumer saves it as UTF-8 without a BOM. JSON combines the
# escaped UTF-16 code units back into the original Unicode strings at runtime.
function ConvertTo-SghAsciiJson {
    param([Parameter(Mandatory = $true)][string]$Value)
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $codePoint = [int][char]$character
        if ($codePoint -gt 0x7f) {
            [void]$builder.Append('\u' + $codePoint.ToString('x4'))
        }
        else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

# Validate and normalize the published { server = {}, tools = [] } schema. The
# normalized catalog contains exactly the fields needed by tools/list.
function ConvertTo-SghToolCatalog {
    param([Parameter(Mandatory = $true)]$Schema)

    if ($Schema -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Schema root must be a JSON object.'
    }

    $toolsProperty = $Schema.PSObject.Properties['tools']
    if ($null -eq $toolsProperty -or $toolsProperty.Value -isnot [array]) {
        throw 'Schema must contain a top-level tools array.'
    }
    if ($toolsProperty.Value.Count -eq 0) {
        throw 'Schema tools array must contain at least one tool.'
    }

    $typeMap = @{
        string  = 'string'
        number  = 'number'
        integer = 'number'
        float   = 'number'
        boolean = 'boolean'
        array   = 'array'
        object  = 'object'
    }
    $toolNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $normalizedTools = New-Object 'System.Collections.Generic.List[object]'
    $toolIndex = 0

    foreach ($tool in $toolsProperty.Value) {
        $toolIndex += 1
        if ($tool -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Tool at index $toolIndex must be a JSON object."
        }

        $nameProperty = $tool.PSObject.Properties['name']
        if ($null -eq $nameProperty -or $nameProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            throw "Tool at index $toolIndex requires a non-empty string name."
        }
        $toolName = [string]$nameProperty.Value
        if (-not $toolNames.Add($toolName)) {
            throw "Duplicate tool name '$toolName' is not supported."
        }

        $toolDescription = 'MCP tool'
        $descriptionProperty = $tool.PSObject.Properties['description']
        if ($null -ne $descriptionProperty -and $null -ne $descriptionProperty.Value) {
            if ($descriptionProperty.Value -isnot [string]) {
                throw "Description for tool '$toolName' must be a string."
            }
            $toolDescription = [string]$descriptionProperty.Value
        }

        $parametersValue = @()
        $parametersProperty = $tool.PSObject.Properties['parameters']
        if ($null -ne $parametersProperty -and $null -ne $parametersProperty.Value) {
            if ($parametersProperty.Value -isnot [array]) {
                throw "Parameters for tool '$toolName' must be an array."
            }
            $parametersValue = $parametersProperty.Value
        }

        $properties = [ordered]@{}
        $required = New-Object 'System.Collections.Generic.List[string]'
        $parameterNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $parameterIndex = 0

        foreach ($parameter in $parametersValue) {
            $parameterIndex += 1
            if ($parameter -isnot [System.Management.Automation.PSCustomObject]) {
                throw "Parameter at index $parameterIndex for tool '$toolName' must be a JSON object."
            }

            $parameterNameProperty = $parameter.PSObject.Properties['name']
            if ($null -eq $parameterNameProperty -or $parameterNameProperty.Value -isnot [string] -or [string]::IsNullOrEmpty([string]$parameterNameProperty.Value)) {
                throw "Parameter at index $parameterIndex for tool '$toolName' requires a non-empty string name."
            }
            $parameterName = [string]$parameterNameProperty.Value
            if (-not $parameterNames.Add($parameterName)) {
                throw "Duplicate parameter '$parameterName' for tool '$toolName' is not supported."
            }

            $parameterType = 'string'
            $typeProperty = $parameter.PSObject.Properties['type']
            if ($null -ne $typeProperty -and $null -ne $typeProperty.Value) {
                if ($typeProperty.Value -isnot [string]) {
                    throw "Type for parameter '$parameterName' on tool '$toolName' must be a string."
                }
                $parameterType = ([string]$typeProperty.Value).ToLowerInvariant()
            }
            if (-not $typeMap.ContainsKey($parameterType)) {
                throw "Unsupported type '$parameterType' for parameter '$parameterName' on tool '$toolName'."
            }

            $propertyDefinition = [ordered]@{ type = $typeMap[$parameterType] }
            $parameterDescription = $parameter.PSObject.Properties['description']
            if ($null -ne $parameterDescription -and $null -ne $parameterDescription.Value) {
                if ($parameterDescription.Value -isnot [string]) {
                    throw "Description for parameter '$parameterName' on tool '$toolName' must be a string."
                }
                $propertyDefinition['description'] = [string]$parameterDescription.Value
            }
            $properties[$parameterName] = $propertyDefinition

            $requiredProperty = $parameter.PSObject.Properties['required']
            if ($null -ne $requiredProperty -and $null -ne $requiredProperty.Value) {
                if ($requiredProperty.Value -isnot [bool]) {
                    throw "Required flag for parameter '$parameterName' on tool '$toolName' must be boolean."
                }
                if ([bool]$requiredProperty.Value) {
                    $required.Add($parameterName)
                }
            }
        }

        $normalizedTools.Add([ordered]@{
            name        = $toolName
            description = $toolDescription
            inputSchema = [ordered]@{
                type       = 'object'
                properties = $properties
                required   = @($required.ToArray())
            }
        })
    }

    return [ordered]@{ tools = @($normalizedTools.ToArray()) }
}

function New-SghPowerShellSource {
    param([Parameter(Mandatory = $true)][string]$CatalogJson)

    # This is a literal template: all $variables below belong to the generated
    # consumer script, not to this generator module.
    $template = @'
# Auto-generated by sdk-generate-handler. Development-time generator output.
# Dot-source this file after importing the core mcp-sdk.psm1 module.
$global:ShebangGeneratedToolCatalog = ConvertFrom-Json -InputObject __SHEBANG_TOOL_CATALOG__ -ErrorAction Stop

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

    # TODO: Implement the selected tool's logic here. $selectedTool.name is the
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
'@
    return $template.Replace('__SHEBANG_TOOL_CATALOG__', (ConvertTo-SghPowerShellLiteral -Value $CatalogJson))
}

function New-SghBashSource {
    param([Parameter(Mandatory = $true)][string]$CatalogJson)

    # This is a literal template: all $variables below belong to generated Bash.
    $template = @'
# Auto-generated by sdk-generate-handler. Development-time generator output.
# Source this file after sourcing the core mcp-sdk.sh module.
_SHEBANG_GENERATED_TOOL_CATALOG=__SHEBANG_TOOL_CATALOG__

_shebang_generated_tool_catalog() {
    printf '%s\n' "${_SHEBANG_GENERATED_TOOL_CATALOG}"
}

handle_list_tools() {
    local id="${1:-null}"
    local result
    result=$(_shebang_generated_tool_catalog | jq -c '{tools:.tools}')
    json_response "${id}" "${result}"
}

handle_tools_call() {
    local id="${1:-null}"
    local params="${2:-"{}"}"
    local err

    if ! printf '%s' "${params}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        err=$(mcp_error -32602 'Invalid params: expected a JSON object')
        json_response "${id}" '' "${err}"
        return 0
    fi

    local tool_name
    tool_name=$(printf '%s' "${params}" | jq -r 'if (.name | type) == "string" then .name else "" end')
    if [ -z "${tool_name}" ]; then
        err=$(mcp_error -32602 'Invalid params: missing tool name')
        json_response "${id}" '' "${err}"
        return 0
    fi

    local tool_json
    tool_json=$(_shebang_generated_tool_catalog | jq -c --arg name "${tool_name}" \
        'first(.tools[] | select(.name == $name))')
    if [ -z "${tool_json}" ]; then
        err=$(mcp_error -32601 "Tool not found: ${tool_name}")
        json_response "${id}" '' "${err}"
        return 0
    fi

    local args_json
    args_json=$(printf '%s' "${params}" | jq -c \
        'if has("arguments") and .arguments != null then .arguments else {} end')
    if ! printf '%s' "${args_json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        err=$(mcp_error -32602 'Invalid params: arguments must be a JSON object')
        json_response "${id}" '' "${err}"
        return 0
    fi

    local missing_required
    missing_required=$(jq -crn \
        --argjson tool "${tool_json}" \
        --argjson args "${args_json}" \
        '[$tool.inputSchema.required[]? as $name
          | select(($args | has($name) | not) or ($args[$name] == null))
          | $name] | join(", ")')
    if [ -n "${missing_required}" ]; then
        err=$(mcp_error -32602 "Invalid params: missing required argument(s): ${missing_required}")
        json_response "${id}" '' "${err}"
        return 0
    fi

    # TODO: Implement the selected tool's logic here. tool_args is compact JSON
    # preserving boolean, number, and string types; query it with jq as needed.
    local tool_args="${args_json}"
    local result
    result=$(jq -cn --arg text "Tool ${tool_name} executed successfully" \
        '{content:[{type:"text",text:$text}],isError:false}')
    json_response "${id}" "${result}"
}
'@
    return $template.Replace('__SHEBANG_TOOL_CATALOG__', (ConvertTo-SghBashLiteral -Value $CatalogJson))
}

function sdk-generate-handler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Schema,

        [string]$Language = 'pwsh'
    )

    if ([string]::IsNullOrWhiteSpace($Schema)) {
        throw 'sdk-generate-handler requires a Schema argument.'
    }

    try {
        $schemaObj = ConvertFrom-Json -InputObject $Schema -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON schema provided: $($_.Exception.Message)"
    }

    $catalog = ConvertTo-SghToolCatalog -Schema $schemaObj
    $catalogJson = ConvertTo-Json -InputObject $catalog -Compress -Depth 20 -ErrorAction Stop
    $catalogJson = ConvertTo-SghAsciiJson -Value $catalogJson

    switch ($Language.ToLowerInvariant()) {
        'pwsh' { return New-SghPowerShellSource -CatalogJson $catalogJson }
        'bash' { return New-SghBashSource -CatalogJson $catalogJson }
        default {
            throw "Unsupported Language '$Language'. Supported languages are 'pwsh' and 'bash'."
        }
    }
}

# Alias for snake_case consistency.
function sdk_generate_handler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Schema,
        [string]$Language = 'pwsh'
    )
    return sdk-generate-handler -Schema $Schema -Language $Language
}

Export-ModuleMember -Function @(
    'sdk-generate-handler',
    'sdk_generate_handler'
)
