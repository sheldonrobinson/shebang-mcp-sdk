#!/usr/bin/env sh
# =============================================================================
# package-mcpb.sh (POSIX sh compliant)
# Builds multi-package MCPB bundles (shebang-mcp-sdk.sh.mcpb and
# shebang-mcp-sdk.pwsh.mcpb), renders platform-specific mcp.json from
# packaging/mcpb/mcp.template.json, and updates server.json with SHA-256 hashes
# for the Official MCP Registry.
#
# Uses a GeneratedArtifact model: artifacts (name, source_path, dest_path)
# are defined first, then materialized (written/copied to staging), then
# archived. This separates artifact generation from file I/O.
# =============================================================================

set -eu

# Ensure jq is in PATH using POSIX parameter expansion (${PATH#*dir})
if ! command -v jq >/dev/null 2>&1; then
    for _d in /opt/homebrew/bin /usr/local/bin "${HOME:-}/.local/bin"; do
        if [ -n "${_d}" ] && [ -d "${_d}" ] && [ "${PATH#*${_d}}" = "${PATH}" ]; then
            PATH="${_d}:${PATH}"
        fi
    done
    export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION=""
REPO_OWNER="sheldonrobinson"
REPO_NAME="shebang-mcp-sdk"
OUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version|-Version)
            VERSION="${2:-}"
            shift 2
            ;;
        --repo-owner|-RepoOwner)
            REPO_OWNER="${2:-sheldonrobinson}"
            shift 2
            ;;
        --repo-name|-RepoName)
            REPO_NAME="${2:-shebang-mcp-sdk}"
            shift 2
            ;;
        --out-dir|-OutDir)
            OUT_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: package-mcpb.sh [--version <ver>] [--repo-owner <owner>] [--repo-name <name>] [--out-dir <dir>]
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [ -z "${VERSION}" ]; then
    if [ -f "${REPO_ROOT}/plugin.json" ] && command -v jq >/dev/null 2>&1; then
        VERSION="$(jq -r '.version // "1.0.0"' "${REPO_ROOT}/plugin.json")"
    else
        VERSION="1.0.0"
    fi
fi

if [ -z "${OUT_DIR}" ]; then
    OUT_DIR="${REPO_ROOT}/dist"
fi

mkdir -p "${OUT_DIR}"

TEMP_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'shebang-mcpb')"
cleanup() {
    rm -rf "${TEMP_BASE}"
}
trap cleanup EXIT

# =============================================================================
# GeneratedArtifact Model
# =============================================================================
# Each artifact is defined by three parallel arrays:
#   ARTIFACT_NAMES[i]     - human-readable name
#   ARTIFACT_SOURCES[i]   - source file path (relative to REPO_ROOT) or "" for generated content
#   ARTIFACT_DESTS[i]     - destination path within the bundle
#   ARTIFACT_CONTENTS[i]  - inline content (if source is empty) or ""
#
# Artifact lifecycle:
#   1. add_artifact    - define an artifact (name, source, dest, content)
#   2. materialize_all - write/copy all artifacts to staging directory
#   3. archive_all     - create .mcpb archive from staged files
# =============================================================================

ARTIFACT_NAMES=""
ARTIFACT_SOURCES=""
ARTIFACT_DESTS=""
ARTIFACT_CONTENTS=""
ARTIFACT_COUNT=0

# add_artifact <name> <source_rel_path_or_empty> <dest_rel_path> <content_or_empty>
#   source_rel_path: path relative to REPO_ROOT, or "" if content is provided inline
#   content: inline file content, or "" if source is provided
add_artifact() {
    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
    ARTIFACT_NAMES="${ARTIFACT_NAMES}${1}${ARTIFACT_NL}"
    ARTIFACT_SOURCES="${ARTIFACT_SOURCES}${2}${ARTIFACT_NL}"
    ARTIFACT_DESTS="${ARTIFACT_DESTS}${3}${ARTIFACT_NL}"
    ARTIFACT_CONTENTS="${ARTIFACT_CONTENTS}${4}${ARTIFACT_NL}"
}

ARTIFACT_NL='
'

# materialize_artifacts <stage_dir>
#   Writes/copies all defined artifacts to the staging directory.
materialize_artifacts() {
    local stage_dir="$1"
    local i=1
    while [ "${i}" -le "${ARTIFACT_COUNT}" ]; do
        local name source dest content
        name=$(printf '%s\n' "${ARTIFACT_NAMES}" | sed -n "${i}p")
        source=$(printf '%s\n' "${ARTIFACT_SOURCES}" | sed -n "${i}p")
        dest=$(printf '%s\n' "${ARTIFACT_DESTS}" | sed -n "${i}p")
        content=$(printf '%s\n' "${ARTIFACT_CONTENTS}" | sed -n "${i}p")

        local dst_path="${stage_dir}/${dest}"
        mkdir -p "$(dirname "${dst_path}")"

        if [ -n "${source}" ]; then
            # Copy from source
            local src="${REPO_ROOT}/${source}"
            if [ ! -f "${src}" ]; then
                echo "Error: Required bundle file not found: ${src}" >&2
                exit 1
            fi
            cp "${src}" "${dst_path}"
        elif [ -n "${content}" ]; then
            # Write inline content
            printf '%s\n' "${content}" > "${dst_path}"
        else
            echo "Error: Artifact '${name}' has neither source nor content" >&2
            exit 1
        fi

        i=$((i + 1))
    done
}

# =============================================================================
# Existing helper functions
# =============================================================================

render_platform_mcp_json() {
    template_path="$1"
    dest_path="$2"
    target_platform="$3"

    if [ "${target_platform}" = "sh" ]; then
        cmd="bash"
        args_json='["-c", "command -v jq >/dev/null 2>&1 || { for d in /opt/homebrew/bin /usr/local/bin; do [ -d \"$d\" ] && [ \"${PATH#*$d}\" = \"$PATH\" ] && PATH=\"$d:$PATH\"; done; export PATH; }; exec bash \"$0\" \"$@\"", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.sh", "--stdio"]'
    else
        cmd="pwsh"
        args_json='["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1", "-Stdio"]'
    fi

    rendered="$(sed 's/{{MCP_STDIO_ARGS_JSON}}/[]/g' "${template_path}" | jq \
        --arg cmd "${cmd}" \
        --argjson args "${args_json}" \
        '.mcpServers["shebang-mcp-sdk"].command = $cmd | .mcpServers["shebang-mcp-sdk"].args = $args')"

    if [ "${target_platform}" = "pwsh" ] && command -v jq >/dev/null 2>&1; then
        printf '%s\n' "${rendered}" | jq '.mcpServers["shebang-mcp-sdk-powershell"] = {
            "type": "stdio",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1", "-Stdio"],
            "cwd": "${PLUGIN_ROOT}",
            "env": {
                "MCP_TRANSPORT": "stdio",
                "MCP_SERVER_NAME": "shebang-mcp-sdk",
                "MCP_SERVER_VERSION": "1.0.0"
            }
        }' > "${dest_path}"
    elif command -v jq >/dev/null 2>&1; then
        printf '%s\n' "${rendered}" | jq '.' > "${dest_path}"
    else
        printf '%s\n' "${rendered}" > "${dest_path}"
    fi
}

create_mcpb_archive() {
    stage_dir="$1"
    dest_mcpb="$2"
    rm -f "${dest_mcpb}"
    if command -v zip >/dev/null 2>&1; then
        (cd "${stage_dir}" && zip -q -r "${dest_mcpb}" .)
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "${stage_dir}" "${dest_mcpb}" <<'PY'
import os, sys, zipfile
stage_dir, dest_mcpb = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest_mcpb, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(stage_dir):
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = os.path.relpath(full, stage_dir).replace("\\", "/")
            zf.write(full, rel)
PY
    elif command -v pwsh >/dev/null 2>&1; then
        pwsh -NoProfile -Command "Compress-Archive -Path '${stage_dir}/*' -DestinationPath '${dest_mcpb}.zip' -Force; Move-Item -LiteralPath '${dest_mcpb}.zip' -Destination '${dest_mcpb}' -Force"
    elif command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "& '${SCRIPT_DIR}/package-mcpb.ps1' -Version '${VERSION}' -RepoOwner '${REPO_OWNER}' -RepoName '${REPO_NAME}' -OutDir '${OUT_DIR}'"
        exit 0
    else
        echo "Error: Neither zip, python3, nor pwsh found to create .mcpb archive." >&2
        exit 1
    fi
}

compute_sha256() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}" | awk '{print tolower($1)}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${file}" | awk '{print tolower($NF)}'
    else
        echo "Error: No SHA-256 tool found (sha256sum, shasum, openssl)." >&2
        exit 1
    fi
}

MCP_TEMPLATE_PATH="${REPO_ROOT}/packaging/mcpb/mcp.template.json"

# =============================================================================
# Build shebang-mcp-sdk.sh.mcpb (POSIX sh edition: linux, darwin)
# =============================================================================
STAGE_SH="${TEMP_BASE}/sh"
mkdir -p "${STAGE_SH}"

if command -v jq >/dev/null 2>&1; then
    jq --arg ver "${VERSION}" '.version = $ver' "${REPO_ROOT}/packaging/mcpb/manifest.sh.json" > "${STAGE_SH}/manifest.json"
else
    cp "${REPO_ROOT}/packaging/mcpb/manifest.sh.json" "${STAGE_SH}/manifest.json"
fi

render_platform_mcp_json "${MCP_TEMPLATE_PATH}" "${STAGE_SH}/mcp.json" "sh"

# Define artifacts for sh bundle
add_artifact "manifest.json" "packaging/mcpb/manifest.sh.json" "manifest.json" ""
add_artifact "mcp.json" "" "mcp.json" ""  # rendered above
add_artifact "shebang-mcp-sdk.sh" "bin/shebang-mcp-sdk.sh" "bin/shebang-mcp-sdk.sh" ""
add_artifact "mcp-sdk.sh" "bin/mcp-sdk.sh" "bin/mcp-sdk.sh" ""
add_artifact "script-runner" "bin/script-runner" "bin/script-runner" ""
add_artifact "script-runner.sh" "bin/script-runner.sh" "bin/script-runner.sh" ""
add_artifact "SKILL.md" "skills/shebang-mcp-builder/SKILL.md" "skills/shebang-mcp-builder/SKILL.md" ""
add_artifact "spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" ""
add_artifact "checklist.md" "skills/shebang-mcp-builder/references/checklist.md" "skills/shebang-mcp-builder/references/checklist.md" ""
add_artifact "setup-sdk.sh" "skills/shebang-mcp-builder/scripts/setup-sdk.sh" "skills/shebang-mcp-builder/scripts/setup-sdk.sh" ""
add_artifact "hooks.json" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/hooks.json" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/hooks.json" ""
add_artifact "stop-hook.sh" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/stop-hook.sh" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/stop-hook.sh" ""
add_artifact "sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-sdk/commands/sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-sdk/commands/sdk-help.md" ""
add_artifact "plugin.json" "plugin.json" "plugin.json" ""
add_artifact "LICENSE" "LICENSE" "LICENSE" ""
add_artifact "README.md" "README.md" "README.md" ""

# Materialize all artifacts to staging directory
materialize_artifacts "${STAGE_SH}"

# Make executables
chmod +x "${STAGE_SH}/bin/shebang-mcp-sdk.sh" "${STAGE_SH}/bin/mcp-sdk.sh" "${STAGE_SH}/bin/script-runner" "${STAGE_SH}/bin/script-runner.sh"

MCPB_SH_PATH="${OUT_DIR}/shebang-mcp-sdk.sh.mcpb"
create_mcpb_archive "${STAGE_SH}" "${MCPB_SH_PATH}"
SHA256_SH="$(compute_sha256 "${MCPB_SH_PATH}")"

# =============================================================================
# Build shebang-mcp-sdk.pwsh.mcpb (PowerShell edition: win32)
# =============================================================================
STAGE_PWSH="${TEMP_BASE}/pwsh"
mkdir -p "${STAGE_PWSH}"

if command -v jq >/dev/null 2>&1; then
    jq --arg ver "${VERSION}" '.version = $ver' "${REPO_ROOT}/packaging/mcpb/manifest.pwsh.json" > "${STAGE_PWSH}/manifest.json"
else
    cp "${REPO_ROOT}/packaging/mcpb/manifest.pwsh.json" "${STAGE_PWSH}/manifest.json"
fi

render_platform_mcp_json "${MCP_TEMPLATE_PATH}" "${STAGE_PWSH}/mcp.json" "pwsh"

# Define artifacts for pwsh bundle
ARTIFACT_NAMES=""
ARTIFACT_SOURCES=""
ARTIFACT_DESTS=""
ARTIFACT_CONTENTS=""
ARTIFACT_COUNT=0

add_artifact "manifest.json" "packaging/mcpb/manifest.pwsh.json" "manifest.json" ""
add_artifact "mcp.json" "" "mcp.json" ""  # rendered above
add_artifact "shebang-mcp-sdk.ps1" "bin/shebang-mcp-sdk.ps1" "bin/shebang-mcp-sdk.ps1" ""
add_artifact "mcp-sdk.psm1" "bin/mcp-sdk.psm1" "bin/mcp-sdk.psm1" ""
add_artifact "script-runner" "bin/script-runner" "bin/script-runner" ""
add_artifact "script-runner.ps1" "bin/script-runner.ps1" "bin/script-runner.ps1" ""
add_artifact "script-runner.cmd" "bin/script-runner.cmd" "bin/script-runner.cmd" ""
add_artifact "SKILL.md" "skills/shebang-mcp-builder/SKILL.md" "skills/shebang-mcp-builder/SKILL.md" ""
add_artifact "spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" ""
add_artifact "checklist.md" "skills/shebang-mcp-builder/references/checklist.md" "skills/shebang-mcp-builder/references/checklist.md" ""
add_artifact "setup-sdk.ps1" "skills/shebang-mcp-builder/scripts/setup-sdk.ps1" "skills/shebang-mcp-builder/scripts/setup-sdk.ps1" ""
add_artifact "hooks.json" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/hooks.json" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/hooks.json" ""
add_artifact "stop-hook.ps1" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/stop-hook.ps1" "io.github.sheldonrobinson.shebang-mcp-sdk/hooks/stop-hook.ps1" ""
add_artifact "sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-sdk/commands/sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-sdk/commands/sdk-help.md" ""
add_artifact "plugin.json" "plugin.json" "plugin.json" ""
add_artifact "LICENSE" "LICENSE" "LICENSE" ""
add_artifact "README.md" "README.md" "README.md" ""

# Materialize all artifacts to staging directory
materialize_artifacts "${STAGE_PWSH}"

MCPB_PWSH_PATH="${OUT_DIR}/shebang-mcp-sdk.pwsh.mcpb"
create_mcpb_archive "${STAGE_PWSH}" "${MCPB_PWSH_PATH}"
SHA256_PWSH="$(compute_sha256 "${MCPB_PWSH_PATH}")"

# =============================================================================
# Generate Official MCP Registry server.json with both MCPB packages
# =============================================================================
RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}"
SERVER_JSON_PATH="${REPO_ROOT}/server.json"

cat > "${SERVER_JSON_PATH}" <<EOF
{
  "\$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
  "name": "io.github.${REPO_OWNER}/${REPO_NAME}",
  "title": "Shebang MCP SDK",
  "description": "Generic Shebang MCP SDK server implementing the Model Context Protocol (MCP) over stdio and streamable-http transports.",
  "version": "${VERSION}",
  "websiteUrl": "https://${REPO_OWNER}.github.io/${REPO_NAME}",
  "repository": {
    "url": "https://github.com/${REPO_OWNER}/${REPO_NAME}",
    "source": "github"
  },
  "packages": [
    {
      "registryType": "mcpb",
      "identifier": "${RELEASE_BASE}/shebang-mcp-sdk.sh.mcpb",
      "version": "${VERSION}",
      "fileSha256": "${SHA256_SH}",
      "runtimeHint": "sh",
      "transport": {
        "type": "stdio"
      },
      "packageArguments": [
        {
          "type": "named",
          "name": "--stdio",
          "description": "Run the POSIX sh MCP SDK server over standard input/output (stdio)"
        }
      ],
      "environmentVariables": [
        {
          "name": "MCP_TRANSPORT",
          "description": "Transport protocol: stdio or streamable-http",
          "isRequired": false
        },
        {
          "name": "MCP_SERVER_NAME",
          "description": "MCP server name reported during initialize",
          "isRequired": false
        },
        {
          "name": "MCP_SERVER_VERSION",
          "description": "MCP server version reported during initialize",
          "isRequired": false
        }
      ]
    },
    {
      "registryType": "mcpb",
      "identifier": "${RELEASE_BASE}/shebang-mcp-sdk.pwsh.mcpb",
      "version": "${VERSION}",
      "fileSha256": "${SHA256_PWSH}",
      "runtimeHint": "pwsh",
      "transport": {
        "type": "stdio"
      },
      "packageArguments": [
        {
          "type": "named",
          "name": "-Stdio",
          "description": "Run the PowerShell MCP SDK server over standard input/output (stdio)"
        }
      ],
      "environmentVariables": [
        {
          "name": "MCP_TRANSPORT",
          "description": "Transport protocol: stdio or streamable-http",
          "isRequired": false
        },
        {
          "name": "MCP_SERVER_NAME",
          "description": "MCP server name reported during initialize",
          "isRequired": false
        },
        {
          "name": "MCP_SERVER_VERSION",
          "description": "MCP server version reported during initialize",
          "isRequired": false
        }
      ]
    }
  ]
}
EOF

echo "Built Multi-Package MCPB Bundles (v${VERSION}):"
echo "  [1] POSIX sh MCPB (linux, darwin) : ${MCPB_SH_PATH}"
echo "      fileSha256                    : ${SHA256_SH}"
echo "  [2] PowerShell MCPB (win32)       : ${MCPB_PWSH_PATH}"
echo "      fileSha256                    : ${SHA256_PWSH}"
echo "  [3] MCP Registry                  : ${SERVER_JSON_PATH}"

exit 0
