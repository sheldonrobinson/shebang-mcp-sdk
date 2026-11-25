#!/usr/bin/env sh
# Shebang MCP SDK - Setup Script (POSIX sh compliant)
# Displays SDK information and verifies the installation.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd || pwd)}"
export PLUGIN_ROOT

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      cat << 'HELP_EOF'
Shebang MCP SDK - Setup Script

USAGE:
  skills/shebang-mcp-sdk/scripts/setup-sdk.sh [OPTIONS]

OPTIONS:
  --info         Show SDK installation information
  --check        Verify SDK files are present
  -h, --help     Show this help message
HELP_EOF
      exit 0
      ;;
    --info)
      echo "Shebang MCP SDK"
      echo "  Plugin root: ${PLUGIN_ROOT}"
      echo "  SDK Bash:    ${PLUGIN_ROOT}/bin/mcp-sdk.sh"
      echo "  SDK PowerShell: ${PLUGIN_ROOT}/bin/mcp-sdk.psm1"
      echo "  Server (sh): ${PLUGIN_ROOT}/bin/shebang-mcp-sdk.sh"
      echo "  Server (pwsh): ${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1"
      echo "  Runner:      ${PLUGIN_ROOT}/bin/script-runner"
      exit 0
      ;;
    --check)
      missing=0
      for f in bin/mcp-sdk.sh bin/shebang-mcp-sdk.sh bin/script-runner; do
        if [ -f "${PLUGIN_ROOT}/${f}" ]; then
          echo "OK: ${f}"
        else
          echo "MISSING: ${f}"
          missing=1
        fi
      done
      if [ "$missing" -eq 1 ]; then
        exit 1
      fi
      echo "All required SDK files present."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Default: show info
echo "Shebang MCP SDK v1.0.0"
echo "Plugin root: ${PLUGIN_ROOT}"
echo ""
echo "Usage:"
echo "  ./bin/script-runner.sh shebang-mcp-sdk --stdio"
echo "  ./bin/shebang-mcp-sdk.sh --streamable-http --port 8080"
