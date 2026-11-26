# Tool Schema Reference

## Overview

The **tool schema** is a JSON schema format for consumers to define their MCP server tools. The schema is used by `sdk-generate-handler` to generate Bash or PowerShell handler code automatically.

Schema files use the `.json` extension and follow this structure:

```json
{
  "version": "1.0.0",
  "server": {
    "name": "my-mcp-server",
    "version": "1.0.0",
    "description": "My custom MCP server",
    "transport": "stdio",
    "protocolVersion": "2025-03-26"
  },
  "tools": [
    {
      "name": "my_tool",
      "description": "Does something useful",
      "parameters": [
        {
          "name": "input_text",
          "type": "string",
          "description": "Text to process",
          "required": true
        }
      ]
    }
  ]
}
```

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | No | Informational schema version |
| `server` | object | No | Server-level metadata |
| `tools` | array | Yes | List of tool definitions (minimum 1) |

### server Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | No | Informational metadata; not applied to initialize |
| `version` | string | No | Server version |
| `description` | string | No | Human-readable description |
| `transport` | string | No | Transport: "stdio" or "streamable-http" |
| `protocolVersion` | string | No | MCP protocol version |

All `server` fields are optional informational metadata. `sdk-generate-handler` does not apply them to `initialize` or transport selection. Configure runtime behavior with `MCP_SERVER_NAME`, `MCP_SERVER_VERSION`, `MCP_PROTOCOL_VERSION`, and `MCP_TRANSPORT`; PowerShell consumers can also use `Set-McpServerInfo` for server metadata.

### tools[].parameters[] Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Non-empty JSON property name, unique within the tool; Bash/PowerShell identifier syntax is not validated |
| `type` | string | No | Parameter type (default: "string") |
| `description` | string | No | Parameter description |
| `required` | boolean | No | Whether the parameter is required |

### Supported Parameter Types

| Schema Type | Generated Bash | Generated PowerShell | MCP JSON Schema |
|---|---|---|---|
| `string` | JSON string read with `jq` | string | string |
| `number` / `integer` / `float` | JSON number read with `jq` | parser-native numeric value | number |
| `boolean` | JSON `true`/`false` read with `jq` | bool | boolean |
| `array` | compact JSON array read with `jq` | array | array |
| `object` | compact JSON object read with `jq` | nested `PSCustomObject` or `IDictionary` | object |

## Usage Examples

### Generate Bash Handlers from Schema

```bash
# Source sdk-utils.sh
. "${PLUGIN_ROOT}/bin/sdk-utils.sh"

# Generate handler code from a schema file
SCHEMA=$(cat my-tool-schema.json)
sdk-generate-handler "$SCHEMA" bash
```

### Generate PowerShell Handlers from Schema

```powershell
# Import sdk-utils.psm1
Import-Module (Join-Path $env:PLUGIN_ROOT 'bin/sdk-utils.psm1')

# Generate handler code from a schema file
$SCHEMA = Get-Content "my-tool-schema.json" -Raw
sdk-generate-handler -Schema $SCHEMA -Language pwsh
```

### Complete Consumer Workflow

```bash
# 1. Define your tools in a schema file
cat > my-tools.json << 'EOF'
{
  "server": {
    "name": "my-mcp-server",
    "version": "1.0.0",
    "transport": "stdio"
  },
  "tools": [
    {
      "name": "read_file",
      "description": "Read a file's contents",
      "parameters": [
        {
          "name": "path",
          "type": "string",
          "description": "File path to read",
          "required": true
        }
      ]
    },
    {
      "name": "write_file",
      "description": "Write content to a file",
      "parameters": [
        {
          "name": "path",
          "type": "string",
          "description": "File path to write",
          "required": true
        },
        {
          "name": "content",
          "type": "string",
          "description": "Content to write",
          "required": true
        }
      ]
    }
  ]
}
EOF

# 2. Generate handler code
. "${PLUGIN_ROOT}/bin/sdk-utils.sh"
SCHEMA=$(cat my-tools.json)
sdk-generate-handler "$SCHEMA" bash > my-handlers.sh

# 3. Source the handlers into your consumer script
. my-handlers.sh

# 4. Your handle_list_tools and handle_tools_call are now defined
#    and will be called by the MCP SDK automatically
```

## Integration with SDK Entry Points

The `shebang-mcp-sdk.sh` and `shebang-mcp-sdk.ps1` runtime entry points deliberately do **not** load the development utilities. Source `sdk-utils.sh` or import `sdk-utils.psm1` explicitly in a development shell before calling `sdk-generate-handler`; pregenerated handlers do not need either utility at runtime.

```bash
# Development-time generation only
. "${PLUGIN_ROOT}/bin/sdk-utils.sh"
sdk-generate-handler "$SCHEMA" bash > my-handlers.sh
```

```powershell
# Development-time generation only
Import-Module (Join-Path $env:PLUGIN_ROOT 'bin/sdk-utils.psm1')
sdk-generate-handler -Schema $SCHEMA -Language pwsh |
    Set-Content -LiteralPath my-handlers.ps1
```

## See Also

- `references/schema.example.json` - Complete example schema file
- `SKILL.md` section 5 - Full SDK-Generate-Handler documentation
- `mcp-sdk.sh` / `mcp-sdk.psm1` - Core SDK functions used by generated handlers
