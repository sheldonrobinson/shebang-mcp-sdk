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
# archived. Declaration, bundle materialization, and archiving remain distinct.
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
# Archive creation changes into the staging directory, so retain an absolute
# destination when callers provide a relative output directory.
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

TEMP_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'shebang-mcpb')"
cleanup() {
    rm -rf "${TEMP_BASE}"
}
trap cleanup EXIT

# =============================================================================
# GeneratedArtifact Model
# =============================================================================
# Each artifact declaration is stored as a small set of files in ARTIFACT_STORE:
#   name   - human-readable name
#   source - source file path (relative to REPO_ROOT) or "" for generated content
#   dest   - destination path within the bundle
#   content - inline content (if source is empty) or ""
#
# Artifact lifecycle:
#   1. reset_artifacts/add_artifact - declare artifacts without writing bundle files
#   2. materialize_artifacts       - write/copy all artifacts to staging
#   3. create_mcpb_archive         - archive the staged files
# =============================================================================

ARTIFACT_STORE=""
ARTIFACT_COUNT=0
ARTIFACT_SET_ID=0

artifact_error() {
    echo "Error: $*" >&2
    exit 1
}

# reset_artifacts
#   Starts an independent artifact declaration set. Declaration metadata and
#   inline content live outside the bundle staging directory.
reset_artifacts() {
    ARTIFACT_SET_ID=$((ARTIFACT_SET_ID + 1))
    ARTIFACT_STORE="${TEMP_BASE}/artifacts-${ARTIFACT_SET_ID}"
    ARTIFACT_COUNT=0
    mkdir -p "${ARTIFACT_STORE}"
}

# add_artifact <name> <source_rel_path_or_empty> <dest_rel_path> <content_or_empty>
#   Exactly one of source_rel_path and content must be non-empty. Inline content
#   is stored in its own file, so embedded newlines are not record delimiters.
add_artifact() {
    if [ -z "${ARTIFACT_STORE}" ]; then
        artifact_error "reset_artifacts must be called before declaring artifacts"
    fi
    if [ "$#" -ne 4 ]; then
        artifact_error "add_artifact requires name, source, destination, and content"
    fi

    artifact_name="$1"
    artifact_source="$2"
    artifact_dest="$3"
    artifact_content="$4"

    if [ -z "${artifact_name}" ]; then
        artifact_error "Artifact name must not be empty"
    fi
    if [ -z "${artifact_dest}" ]; then
        artifact_error "Artifact '${artifact_name}' has an empty destination"
    fi
    case "${artifact_dest}" in
        /*|*\\*|*:*|*/)
            artifact_error "Artifact '${artifact_name}' destination must be a relative file path: ${artifact_dest}"
            ;;
    esac
    case "/${artifact_dest}/" in
        */../*|*/./*)
            artifact_error "Artifact '${artifact_name}' destination contains an invalid path segment: ${artifact_dest}"
            ;;
    esac
    if [ -n "${artifact_source}" ] && [ -n "${artifact_content}" ]; then
        artifact_error "Artifact '${artifact_name}' must not declare both source and content"
    fi
    if [ -z "${artifact_source}" ] && [ -z "${artifact_content}" ]; then
        artifact_error "Artifact '${artifact_name}' has neither source nor content"
    fi

    artifact_index=1
    while [ "${artifact_index}" -le "${ARTIFACT_COUNT}" ]; do
        if [ "$(cat "${ARTIFACT_STORE}/${artifact_index}.dest")" = "${artifact_dest}" ]; then
            artifact_error "Duplicate artifact destination declared: ${artifact_dest}"
        fi
        artifact_index=$((artifact_index + 1))
    done

    ARTIFACT_COUNT=$((ARTIFACT_COUNT + 1))
    artifact_record="${ARTIFACT_STORE}/${ARTIFACT_COUNT}"
    printf '%s' "${artifact_name}" > "${artifact_record}.name"
    printf '%s' "${artifact_source}" > "${artifact_record}.source"
    printf '%s' "${artifact_dest}" > "${artifact_record}.dest"
    printf '%s' "${artifact_content}" > "${artifact_record}.content"
}

# materialize_artifacts <stage_dir>
#   Writes/copies all defined artifacts to the staging directory. This is the
#   only artifact lifecycle phase that writes bundle files; archiving is separate.
materialize_artifacts() {
    if [ "$#" -ne 1 ] || [ -z "${ARTIFACT_STORE}" ]; then
        artifact_error "materialize_artifacts requires an initialized artifact set and staging directory"
    fi
    if [ "${ARTIFACT_COUNT}" -eq 0 ]; then
        artifact_error "Refusing to materialize an empty artifact set"
    fi

    materialize_stage_dir="$1"
    materialize_index=1
    while [ "${materialize_index}" -le "${ARTIFACT_COUNT}" ]; do
        artifact_record="${ARTIFACT_STORE}/${materialize_index}"
        artifact_name="$(cat "${artifact_record}.name")"
        artifact_source="$(cat "${artifact_record}.source")"
        artifact_dest="$(cat "${artifact_record}.dest")"
        artifact_dst_path="${materialize_stage_dir}/${artifact_dest}"
        mkdir -p "$(dirname "${artifact_dst_path}")"

        if [ -n "${artifact_source}" ]; then
            artifact_src_path="${REPO_ROOT}/${artifact_source}"
            if [ ! -f "${artifact_src_path}" ]; then
                artifact_error "Required bundle file not found for '${artifact_name}': ${artifact_src_path}"
            fi
            if [ ! -s "${artifact_src_path}" ]; then
                artifact_error "Required bundle file is empty for '${artifact_name}': ${artifact_src_path}"
            fi
            cp "${artifact_src_path}" "${artifact_dst_path}"
        elif [ -s "${artifact_record}.content" ]; then
            # Preserve all embedded newlines and retain the original interface's
            # behavior of terminating inline files with a newline.
            cat "${artifact_record}.content" > "${artifact_dst_path}"
            printf '\n' >> "${artifact_dst_path}"
        else
            artifact_error "Artifact '${artifact_name}' has no materializable source or content"
        fi

        if [ ! -s "${artifact_dst_path}" ]; then
            artifact_error "Artifact '${artifact_name}' materialized as an empty file: ${artifact_dest}"
        fi
        materialize_index=$((materialize_index + 1))
    done
}

# =============================================================================
# Existing helper functions
# =============================================================================

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to render versioned MCP metadata." >&2
    exit 1
fi

render_manifest() {
    if [ "$#" -ne 1 ]; then
        artifact_error "render_manifest requires a manifest template path"
    fi
    jq --arg ver "${VERSION}" '
        .version = $ver
        | .server.mcp_config.env.MCP_SERVER_VERSION = $ver
    ' "$1"
}

render_plugin_metadata() {
    if [ "$#" -ne 1 ]; then
        artifact_error "render_plugin_metadata requires a plugin.json path"
    fi
    jq --arg ver "${VERSION}" '.version = $ver' "$1"
}

render_platform_mcp_json() {
    template_path="$1"
    dest_path="$2"
    target_platform="$3"

    if [ "${target_platform}" = "sh" ]; then
        cmd="sh"
        args_json='["-c", "command -v jq >/dev/null 2>&1 || { for d in /opt/homebrew/bin /usr/local/bin; do [ -d \"$d\" ] && [ \"${PATH#*$d}\" = \"$PATH\" ] && PATH=\"$d:$PATH\"; done; export PATH; }; exec sh \"$0\" \"$@\"", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.sh", "--stdio"]'
    elif [ "${target_platform}" = "pwsh" ]; then
        cmd="pwsh"
        args_json='["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1", "--stdio"]'
    else
        artifact_error "Unknown MCP configuration target platform: ${target_platform}"
    fi

    rendered="$(sed 's/{{MCP_STDIO_ARGS_JSON}}/[]/g' "${template_path}" | jq \
        --arg cmd "${cmd}" \
        --arg ver "${VERSION}" \
        --argjson args "${args_json}" \
        '.mcpServers["shebang-mcp-sdk"].command = $cmd
         | .mcpServers["shebang-mcp-sdk"].args = $args
         | .mcpServers["shebang-mcp-sdk"].env.MCP_SERVER_VERSION = $ver')"

    if [ "${target_platform}" = "pwsh" ]; then
        printf '%s\n' "${rendered}" | jq --arg ver "${VERSION}" '.mcpServers["shebang-mcp-sdk-powershell"] = {
            "type": "stdio",
            "command": "powershell.exe",
            "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1", "--stdio"],
            "cwd": "${PLUGIN_ROOT}",
            "env": {
                "MCP_TRANSPORT": "stdio",
                "MCP_SERVER_NAME": "shebang-mcp-sdk",
                "MCP_SERVER_VERSION": $ver
            }
        }' > "${dest_path}"
    else
        printf '%s\n' "${rendered}" > "${dest_path}"
    fi

    if [ ! -s "${dest_path}" ] || ! jq -e . "${dest_path}" >/dev/null 2>&1; then
        artifact_error "Rendered MCP configuration is empty or invalid: ${dest_path}"
    fi
}

create_mcpb_archive() {
    stage_dir="$1"
    dest_mcpb="$2"
    rm -f "${dest_mcpb}"
    # Native Windows zip builds omit Unix modes from archives created by Git
    # Bash/MSYS/Cygwin. Use an explicit-mode fallback on those hosts.
    use_zip=true
    case "$(uname -s 2>/dev/null || printf unknown)" in
        MINGW*|MSYS*|CYGWIN*) use_zip=false ;;
    esac
    if [ "${use_zip}" = true ] && command -v zip >/dev/null 2>&1; then
        (cd "${stage_dir}" && zip -q -r "${dest_mcpb}" .)
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "${stage_dir}" "${dest_mcpb}" <<'PY'
import os, stat, sys, zipfile
stage_dir, dest_mcpb = sys.argv[1], sys.argv[2]

def is_executable(rel):
    return (
        (rel.startswith("bin/") and rel.endswith(".sh"))
        or rel == "bin/script-runner"
        or (rel.startswith("skills/shebang-mcp-builder/scripts/") and rel.endswith(".sh"))
        or (rel.startswith("io.github.sheldonrobinson.shebang-mcp-builder/hooks/") and rel.endswith(".sh"))
    )

with zipfile.ZipFile(dest_mcpb, "w") as zf:
    for root, _, files in os.walk(stage_dir):
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, stage_dir).replace("\\", "/")
            mode = 0o755 if is_executable(rel) else 0o644
            info = zipfile.ZipInfo(rel)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as src:
                zf.writestr(info, src.read())
PY
    elif command -v pwsh >/dev/null 2>&1 || command -v powershell.exe >/dev/null 2>&1; then
        archive_helper="${TEMP_BASE}/write-mcpb-archive.ps1"
        cat > "${archive_helper}" <<'POWERSHELL'
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [Parameter(Mandatory = $true)][string]$DestinationMcpb
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stageFull = [System.IO.Path]::GetFullPath($StageDir).TrimEnd('\', '/')
$zipStream = [System.IO.File]::Open($DestinationMcpb, [System.IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stageFull -Recurse -File) {
            $relPath = $file.FullName.Substring($stageFull.Length + 1).Replace('\', '/')
            $entry = $archive.CreateEntry($relPath, [System.IO.Compression.CompressionLevel]::Optimal)
            $isExecutable = $relPath -like 'bin/*.sh' -or
                $relPath -eq 'bin/script-runner' -or
                $relPath -like 'skills/shebang-mcp-builder/scripts/*.sh' -or
                $relPath -like 'io.github.sheldonrobinson.shebang-mcp-builder/hooks/*.sh'
            $unixMode = if ($isExecutable) { 33261 } else { 33188 } # 0100755 / 0100644
            $entry.ExternalAttributes = [int]($unixMode -shl 16)
            $entryStream = $entry.Open()
            try {
                $inStream = [System.IO.File]::OpenRead($file.FullName)
                try { $inStream.CopyTo($entryStream) } finally { $inStream.Dispose() }
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $zipStream.Dispose()
}
POWERSHELL
        if command -v pwsh >/dev/null 2>&1; then
            pwsh -NoProfile -File "${archive_helper}" -StageDir "${stage_dir}" -DestinationMcpb "${dest_mcpb}"
        else
            ps_helper="${archive_helper}"
            ps_stage_dir="${stage_dir}"
            ps_dest_mcpb="${dest_mcpb}"
            if command -v cygpath >/dev/null 2>&1; then
                ps_helper="$(cygpath -w "${archive_helper}")"
                ps_stage_dir="$(cygpath -w "${stage_dir}")"
                ps_dest_mcpb="$(cygpath -w "${dest_mcpb}")"
            elif command -v wslpath >/dev/null 2>&1; then
                ps_helper="$(wslpath -w "${archive_helper}")"
                ps_stage_dir="$(wslpath -w "${stage_dir}")"
                ps_dest_mcpb="$(wslpath -w "${dest_mcpb}")"
            fi
            powershell.exe -NoProfile -File "${ps_helper}" -StageDir "${ps_stage_dir}" -DestinationMcpb "${ps_dest_mcpb}"
        fi
    else
        echo "Error: Neither zip, python3, nor PowerShell found to create .mcpb archive." >&2
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
reset_artifacts

# Render all generated metadata before declaring or materializing artifacts.
MANIFEST_SH_CONTENT="$(render_manifest "${REPO_ROOT}/packaging/mcpb/manifest.sh.json")"
MCP_JSON_SH_RENDER="${TEMP_BASE}/mcp-sh.json"
render_platform_mcp_json "${MCP_TEMPLATE_PATH}" "${MCP_JSON_SH_RENDER}" "sh"
MCP_JSON_SH_CONTENT="$(cat "${MCP_JSON_SH_RENDER}")"
PLUGIN_JSON_CONTENT="$(render_plugin_metadata "${REPO_ROOT}/plugin.json")"

# Define artifacts for sh bundle. Generated files are content-only so template
# sources cannot overwrite their requested-version metadata during materialization.
add_artifact "manifest.json" "" "manifest.json" "${MANIFEST_SH_CONTENT}"
add_artifact "mcp.json" "" "mcp.json" "${MCP_JSON_SH_CONTENT}"
add_artifact "shebang-mcp-sdk.sh" "bin/shebang-mcp-sdk.sh" "bin/shebang-mcp-sdk.sh" ""
add_artifact "mcp-sdk.sh" "bin/mcp-sdk.sh" "bin/mcp-sdk.sh" ""
add_artifact "sdk-utils.sh" "bin/sdk-utils.sh" "bin/sdk-utils.sh" ""
add_artifact "script-runner" "bin/script-runner" "bin/script-runner" ""
add_artifact "script-runner.sh" "bin/script-runner.sh" "bin/script-runner.sh" ""
add_artifact "SKILL.md" "skills/shebang-mcp-builder/SKILL.md" "skills/shebang-mcp-builder/SKILL.md" ""
add_artifact "spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" ""
add_artifact "checklist.md" "skills/shebang-mcp-builder/references/checklist.md" "skills/shebang-mcp-builder/references/checklist.md" ""
add_artifact "schema-reference.md" "skills/shebang-mcp-builder/references/schema-reference.md" "skills/shebang-mcp-builder/references/schema-reference.md" ""
add_artifact "schema.example.json" "skills/shebang-mcp-builder/references/schema.example.json" "skills/shebang-mcp-builder/references/schema.example.json" ""
add_artifact "setup-sdk.sh" "skills/shebang-mcp-builder/scripts/setup-sdk.sh" "skills/shebang-mcp-builder/scripts/setup-sdk.sh" ""
add_artifact "hooks.json" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" ""
add_artifact "stop-hook.sh" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.sh" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.sh" ""
add_artifact "sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" ""
add_artifact "plugin.json" "" "plugin.json" "${PLUGIN_JSON_CONTENT}"
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
reset_artifacts

MANIFEST_PWSH_CONTENT="$(render_manifest "${REPO_ROOT}/packaging/mcpb/manifest.pwsh.json")"
MCP_JSON_PWSH_RENDER="${TEMP_BASE}/mcp-pwsh.json"
render_platform_mcp_json "${MCP_TEMPLATE_PATH}" "${MCP_JSON_PWSH_RENDER}" "pwsh"
MCP_JSON_PWSH_CONTENT="$(cat "${MCP_JSON_PWSH_RENDER}")"

# Define artifacts for pwsh bundle
add_artifact "manifest.json" "" "manifest.json" "${MANIFEST_PWSH_CONTENT}"
add_artifact "mcp.json" "" "mcp.json" "${MCP_JSON_PWSH_CONTENT}"
add_artifact "shebang-mcp-sdk.ps1" "bin/shebang-mcp-sdk.ps1" "bin/shebang-mcp-sdk.ps1" ""
add_artifact "mcp-sdk.psm1" "bin/mcp-sdk.psm1" "bin/mcp-sdk.psm1" ""
add_artifact "sdk-utils.psm1" "bin/sdk-utils.psm1" "bin/sdk-utils.psm1" ""
add_artifact "script-runner" "bin/script-runner" "bin/script-runner" ""
add_artifact "script-runner.ps1" "bin/script-runner.ps1" "bin/script-runner.ps1" ""
add_artifact "script-runner.cmd" "bin/script-runner.cmd" "bin/script-runner.cmd" ""
add_artifact "SKILL.md" "skills/shebang-mcp-builder/SKILL.md" "skills/shebang-mcp-builder/SKILL.md" ""
add_artifact "spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" "skills/shebang-mcp-builder/references/spec-template.md" ""
add_artifact "checklist.md" "skills/shebang-mcp-builder/references/checklist.md" "skills/shebang-mcp-builder/references/checklist.md" ""
add_artifact "schema-reference.md" "skills/shebang-mcp-builder/references/schema-reference.md" "skills/shebang-mcp-builder/references/schema-reference.md" ""
add_artifact "schema.example.json" "skills/shebang-mcp-builder/references/schema.example.json" "skills/shebang-mcp-builder/references/schema.example.json" ""
add_artifact "setup-sdk.ps1" "skills/shebang-mcp-builder/scripts/setup-sdk.ps1" "skills/shebang-mcp-builder/scripts/setup-sdk.ps1" ""
add_artifact "hooks.json" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" ""
add_artifact "stop-hook.ps1" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.ps1" "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.ps1" ""
add_artifact "sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" ""
add_artifact "plugin.json" "" "plugin.json" "${PLUGIN_JSON_CONTENT}"
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
  "description": "Generic shell MCP SDK server with stdio and Streamable HTTP transports.",
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
          "name": "--stdio",
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
