#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds multi-package MCPB bundles (shebang-mcp-sdk.sh.mcpb and shebang-mcp-sdk.pwsh.mcpb),
    renders platform-specific mcp.json from packaging/mcpb/mcp.template.json,
    and updates server.json with SHA-256 integrity hashes for the Official MCP Registry.

    Uses a GeneratedArtifact model: artifacts (name, source_path, dest_path, content)
    are defined first, then materialized (written/copied to staging), then archived.
    This separates artifact generation from file I/O.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version = "",

    [Parameter(Mandatory = $false)]
    [string]$RepoOwner = "sheldonrobinson",

    [Parameter(Mandatory = $false)]
    [string]$RepoName = "shebang-mcp-sdk",

    [Parameter(Mandatory = $false)]
    [string]$OutDir = "",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Support POSIX double-dash flags (--version, --repo-owner, --repo-name, --out-dir)
if ($null -ne $RemainingArgs -and $RemainingArgs.Count -gt 0) {
    for ($i = 0; $i -lt $RemainingArgs.Count; $i++) {
        switch ($RemainingArgs[$i]) {
            "--version"    { if ($i + 1 -lt $RemainingArgs.Count) { $Version = $RemainingArgs[++$i] } }
            "--repo-owner" { if ($i + 1 -lt $RemainingArgs.Count) { $RepoOwner = $RemainingArgs[++$i] } }
            "--repo-name"  { if ($i + 1 -lt $RemainingArgs.Count) { $RepoName = $RemainingArgs[++$i] } }
            "--out-dir"    { if ($i + 1 -lt $RemainingArgs.Count) { $OutDir = $RemainingArgs[++$i] } }
        }
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path

if ([string]::IsNullOrWhiteSpace($Version)) {
    $pluginJsonPath = Join-Path $RepoRoot "plugin.json"
    if (Test-Path -LiteralPath $pluginJsonPath) {
        $pluginMeta = Get-Content -LiteralPath $pluginJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $Version = [string]$pluginMeta.version
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = "1.0.0"
    }
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $RepoRoot "dist"
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# =============================================================================
# GeneratedArtifact Model
# =============================================================================
# Each artifact is defined as a hashtable with:
#   Name      - human-readable name
#   Source    - source file path relative to REPO_ROOT, or "" for inline content
#   Dest      - destination path within the bundle
#   Content   - inline file content, or "" when Source is provided
# Exactly one of Source and Content must be non-empty.
#
# Artifact lifecycle:
#   1. Add-Artifact   - define an artifact
#   2. Materialize    - write/copy all artifacts to staging directory
#   3. Archive        - create .mcpb archive from staged files
# =============================================================================

$script:Artifacts = @()

function Add-Artifact {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Source,    # relative to REPO_ROOT, or ""
        [Parameter(Mandatory = $true)][string]$Dest,                         # destination path in bundle
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content    # inline content, or ""
    )

    $hasSource = -not [string]::IsNullOrWhiteSpace($Source)
    $hasContent = -not [string]::IsNullOrEmpty($Content)
    if ($hasSource -eq $hasContent) {
        throw "Artifact '$Name' must declare exactly one non-empty Source or Content"
    }

    $script:Artifacts += [ordered]@{
        Name    = $Name
        Source  = $Source
        Dest    = $Dest
        Content = $Content
    }
}

function Materialize-Artifacts {
    param(
        [Parameter(Mandatory = $true)][string]$StageDir
    )

    foreach ($artifact in $script:Artifacts) {
        $dstPath = Join-Path $StageDir $artifact.Dest
        $dstParent = Split-Path -Parent $dstPath
        if (-not (Test-Path -LiteralPath $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
        }

        if ($artifact.Source) {
            # Copy from source
            $src = Join-Path $RepoRoot $artifact.Source
            if (-not (Test-Path -LiteralPath $src)) {
                throw "Required bundle file not found: $src"
            }
            Copy-Item -LiteralPath $src -Destination $dstPath -Force
        }
        elseif ($artifact.Content) {
            # Write inline content
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($dstPath, $artifact.Content, $utf8NoBom)
        }
        else {
            throw "Artifact '$($artifact.Name)' has neither source nor content"
        }
    }
}

function New-McpbArchive {
    param(
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$DestinationMcpb
    )

    if (Test-Path -LiteralPath $DestinationMcpb) {
        Remove-Item -LiteralPath $DestinationMcpb -Force
    }

    $stageFull = (Resolve-Path -LiteralPath $StageDir).Path.TrimEnd('\', '/')
    $zipStream = [System.IO.File]::Open($DestinationMcpb, [System.IO.FileMode]::Create)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $files = Get-ChildItem -LiteralPath $stageFull -Recurse -File
            foreach ($file in $files) {
                $relPath = $file.FullName.Substring($stageFull.Length + 1).Replace('\', '/')
                $entry = $archive.CreateEntry($relPath, [System.IO.Compression.CompressionLevel]::Optimal)

                # ZipArchive does not preserve staged chmod metadata on Windows.
                # Write explicit Unix regular-file modes so POSIX extraction can
                # execute the entry points regardless of the packaging host.
                $isExecutable = $relPath -like 'bin/*.sh' -or
                    $relPath -eq 'bin/script-runner' -or
                    $relPath -like 'skills/shebang-mcp-builder/scripts/*.sh' -or
                    $relPath -like 'io.github.sheldonrobinson.shebang-mcp-builder/hooks/*.sh'
                $unixMode = if ($isExecutable) { 33261 } else { 33188 } # 0100755 / 0100644
                $entry.ExternalAttributes = [int]($unixMode -shl 16)

                $entryStream = $entry.Open()
                try {
                    $inStream = [System.IO.File]::OpenRead($file.FullName)
                    try {
                        $inStream.CopyTo($entryStream)
                    } finally {
                        $inStream.Dispose()
                    }
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
}

function Write-PlatformMcpJson {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][ValidateSet("sh", "pwsh")][string]$TargetPlatform,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Version
    )

    $rawTemplate = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    if ($TargetPlatform -eq "sh") {
        $cmd = "sh"
        $argsJson = '["-c", "command -v jq >/dev/null 2>&1 || { for d in /opt/homebrew/bin /usr/local/bin; do [ -d \"$d\" ] && [ \"${PATH#*$d}\" = \"$PATH\" ] && PATH=\"$d:$PATH\"; done; export PATH; }; exec sh \"$0\" \"$@\"", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.sh", "--stdio"]'
    } else {
        $cmd = "pwsh"
        $argsJson = '["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1", "--stdio"]'
    }

    $rendered = $rawTemplate.Replace("{{MCP_STDIO_COMMAND}}", $cmd).Replace("{{MCP_STDIO_ARGS_JSON}}", $argsJson)
    $parsed = $rendered | ConvertFrom-Json
    $parsed.mcpServers."shebang-mcp-sdk".env.MCP_SERVER_VERSION = $Version

    if ($TargetPlatform -eq "pwsh") {
        $parsed.mcpServers | Add-Member -NotePropertyName "shebang-mcp-sdk-powershell" -NotePropertyValue ([ordered]@{
            type    = "stdio"
            command = "powershell.exe"
            args    = @(
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                "`${PLUGIN_ROOT}/bin/shebang-mcp-sdk.ps1",
                "--stdio"
            )
            cwd     = "`${PLUGIN_ROOT}"
            env     = [ordered]@{
                MCP_TRANSPORT    = "stdio"
                MCP_SERVER_NAME  = "shebang-mcp-sdk"
                MCP_SERVER_VERSION = $Version
            }
        }) -Force
    }

    $renderedContent = (($parsed | ConvertTo-Json -Depth 10) + "`n")
    if ([string]::IsNullOrWhiteSpace($renderedContent)) {
        throw "Rendered MCP configuration is empty for platform '$TargetPlatform'"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($DestinationPath, $renderedContent, $utf8NoBom)
}

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("shebang-mcpb-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
$mcpTemplatePath = Join-Path $RepoRoot "packaging/mcpb/mcp.template.json"

try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # Render shared plugin metadata without modifying the source file.
    $pluginMetadataPath = Join-Path $RepoRoot "plugin.json"
    $pluginMetadataObj = Get-Content -LiteralPath $pluginMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $pluginMetadataObj.version = $Version
    $pluginJsonContent = (($pluginMetadataObj | ConvertTo-Json -Depth 10) + "`n")

    # =============================================================================
    # 1. Build shebang-mcp-sdk.sh.mcpb (POSIX sh edition: linux, darwin)
    # =============================================================================
    $stageSh = Join-Path $tempBase "sh"
    New-Item -ItemType Directory -Path $stageSh -Force | Out-Null

    # Render all generated metadata before declaring or materializing artifacts.
    $manifestShSrc = Join-Path $RepoRoot "packaging/mcpb/manifest.sh.json"
    $manifestShObj = Get-Content -LiteralPath $manifestShSrc -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestShObj.version = $Version
    $manifestShObj.server.mcp_config.env.MCP_SERVER_VERSION = $Version
    $manifestShContent = (($manifestShObj | ConvertTo-Json -Depth 10) + "`n")

    $mcpJsonShRender = Join-Path $tempBase "mcp-sh.json"
    Write-PlatformMcpJson -TemplatePath $mcpTemplatePath -DestinationPath $mcpJsonShRender -TargetPlatform "sh" -Version $Version
    $mcpJsonShContent = Get-Content -LiteralPath $mcpJsonShRender -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($mcpJsonShContent)) {
        throw "Rendered sh MCP configuration is empty"
    }

    # Generated files are content-only so template sources cannot replace them.
    Add-Artifact -Name "manifest.json"   -Source ""                                   -Dest "manifest.json"   -Content $manifestShContent
    Add-Artifact -Name "mcp.json"        -Source ""                                   -Dest "mcp.json"        -Content $mcpJsonShContent
    Add-Artifact -Name "shebang-mcp-sdk.sh" -Source "bin/shebang-mcp-sdk.sh"          -Dest "bin/shebang-mcp-sdk.sh" -Content ""
    Add-Artifact -Name "mcp-sdk.sh"      -Source "bin/mcp-sdk.sh"                     -Dest "bin/mcp-sdk.sh"      -Content ""
    Add-Artifact -Name "sdk-utils.sh"    -Source "bin/sdk-utils.sh"                   -Dest "bin/sdk-utils.sh"    -Content ""
    Add-Artifact -Name "script-runner"   -Source "bin/script-runner"                  -Dest "bin/script-runner"   -Content ""
    Add-Artifact -Name "script-runner.sh" -Source "bin/script-runner.sh"              -Dest "bin/script-runner.sh" -Content ""
    Add-Artifact -Name "SKILL.md"        -Source "skills/shebang-mcp-builder/SKILL.md" -Dest "skills/shebang-mcp-builder/SKILL.md" -Content ""
    Add-Artifact -Name "spec-template.md" -Source "skills/shebang-mcp-builder/references/spec-template.md" -Dest "skills/shebang-mcp-builder/references/spec-template.md" -Content ""
    Add-Artifact -Name "checklist.md"    -Source "skills/shebang-mcp-builder/references/checklist.md" -Dest "skills/shebang-mcp-builder/references/checklist.md" -Content ""
    Add-Artifact -Name "schema-reference.md" -Source "skills/shebang-mcp-builder/references/schema-reference.md" -Dest "skills/shebang-mcp-builder/references/schema-reference.md" -Content ""
    Add-Artifact -Name "schema.example.json" -Source "skills/shebang-mcp-builder/references/schema.example.json" -Dest "skills/shebang-mcp-builder/references/schema.example.json" -Content ""
    Add-Artifact -Name "setup-sdk.sh"    -Source "skills/shebang-mcp-builder/scripts/setup-sdk.sh" -Dest "skills/shebang-mcp-builder/scripts/setup-sdk.sh" -Content ""
    Add-Artifact -Name "hooks.json"      -Source "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" -Dest "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" -Content ""
    Add-Artifact -Name "stop-hook.sh"    -Source "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.sh" -Dest "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.sh" -Content ""
    Add-Artifact -Name "sdk-help.md"     -Source "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" -Dest "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" -Content ""
    Add-Artifact -Name "plugin.json"     -Source ""                                   -Dest "plugin.json"     -Content $pluginJsonContent
    Add-Artifact -Name "LICENSE"         -Source "LICENSE"                            -Dest "LICENSE"         -Content ""
    Add-Artifact -Name "README.md"       -Source "README.md"                          -Dest "README.md"       -Content ""

    Materialize-Artifacts -StageDir $stageSh

    # Preserve executable bits where chmod exists. Windows package builds invoke
    # the entry points through sh/pwsh explicitly and have no chmod command.
    if (Get-Command chmod -ErrorAction SilentlyContinue) {
        Get-ChildItem -Path "$stageSh/bin" -Filter "*.sh" | ForEach-Object { chmod +x $_.FullName }
        Get-ChildItem -Path "$stageSh/bin" -Filter "script-runner" | ForEach-Object { chmod +x $_.FullName }
    }

    $mcpbShPath = Join-Path $OutDir "shebang-mcp-sdk.sh.mcpb"
    New-McpbArchive -StageDir $stageSh -DestinationMcpb $mcpbShPath
    $sha256Sh = (Get-FileHash -LiteralPath $mcpbShPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # Reset artifacts for pwsh bundle
    $script:Artifacts = @()

    # =============================================================================
    # 2. Build shebang-mcp-sdk.pwsh.mcpb (PowerShell edition: win32)
    # =============================================================================
    $stagePwsh = Join-Path $tempBase "pwsh"
    New-Item -ItemType Directory -Path $stagePwsh -Force | Out-Null

    $manifestPwshSrc = Join-Path $RepoRoot "packaging/mcpb/manifest.pwsh.json"
    $manifestPwshObj = Get-Content -LiteralPath $manifestPwshSrc -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestPwshObj.version = $Version
    $manifestPwshObj.server.mcp_config.env.MCP_SERVER_VERSION = $Version
    $manifestPwshContent = (($manifestPwshObj | ConvertTo-Json -Depth 10) + "`n")

    $mcpJsonPwshRender = Join-Path $tempBase "mcp-pwsh.json"
    Write-PlatformMcpJson -TemplatePath $mcpTemplatePath -DestinationPath $mcpJsonPwshRender -TargetPlatform "pwsh" -Version $Version
    $mcpJsonPwshContent = Get-Content -LiteralPath $mcpJsonPwshRender -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($mcpJsonPwshContent)) {
        throw "Rendered pwsh MCP configuration is empty"
    }

    Add-Artifact -Name "manifest.json"   -Source ""                                   -Dest "manifest.json"   -Content $manifestPwshContent
    Add-Artifact -Name "mcp.json"        -Source ""                                   -Dest "mcp.json"        -Content $mcpJsonPwshContent
    Add-Artifact -Name "shebang-mcp-sdk.ps1" -Source "bin/shebang-mcp-sdk.ps1"        -Dest "bin/shebang-mcp-sdk.ps1" -Content ""
    Add-Artifact -Name "mcp-sdk.psm1"    -Source "bin/mcp-sdk.psm1"                   -Dest "bin/mcp-sdk.psm1"       -Content ""
    Add-Artifact -Name "sdk-utils.psm1"  -Source "bin/sdk-utils.psm1"                 -Dest "bin/sdk-utils.psm1"     -Content ""
    Add-Artifact -Name "script-runner"   -Source "bin/script-runner"                  -Dest "bin/script-runner"   -Content ""
    Add-Artifact -Name "script-runner.ps1" -Source "bin/script-runner.ps1"            -Dest "bin/script-runner.ps1" -Content ""
    Add-Artifact -Name "script-runner.cmd" -Source "bin/script-runner.cmd"            -Dest "bin/script-runner.cmd" -Content ""
    Add-Artifact -Name "SKILL.md"        -Source "skills/shebang-mcp-builder/SKILL.md" -Dest "skills/shebang-mcp-builder/SKILL.md" -Content ""
    Add-Artifact -Name "spec-template.md" -Source "skills/shebang-mcp-builder/references/spec-template.md" -Dest "skills/shebang-mcp-builder/references/spec-template.md" -Content ""
    Add-Artifact -Name "checklist.md"    -Source "skills/shebang-mcp-builder/references/checklist.md" -Dest "skills/shebang-mcp-builder/references/checklist.md" -Content ""
    Add-Artifact -Name "schema-reference.md" -Source "skills/shebang-mcp-builder/references/schema-reference.md" -Dest "skills/shebang-mcp-builder/references/schema-reference.md" -Content ""
    Add-Artifact -Name "schema.example.json" -Source "skills/shebang-mcp-builder/references/schema.example.json" -Dest "skills/shebang-mcp-builder/references/schema.example.json" -Content ""
    Add-Artifact -Name "setup-sdk.ps1"   -Source "skills/shebang-mcp-builder/scripts/setup-sdk.ps1" -Dest "skills/shebang-mcp-builder/scripts/setup-sdk.ps1" -Content ""
    Add-Artifact -Name "hooks.json"      -Source "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" -Dest "io.github.sheldonrobinson.shebang-mcp-builder/hooks/hooks.json" -Content ""
    Add-Artifact -Name "stop-hook.ps1"   -Source "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.ps1" -Dest "io.github.sheldonrobinson.shebang-mcp-builder/hooks/stop-hook.ps1" -Content ""
    Add-Artifact -Name "sdk-help.md"     -Source "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" -Dest "io.github.sheldonrobinson.shebang-mcp-builder/commands/sdk-help.md" -Content ""
    Add-Artifact -Name "plugin.json"     -Source ""                                   -Dest "plugin.json"     -Content $pluginJsonContent
    Add-Artifact -Name "LICENSE"         -Source "LICENSE"                            -Dest "LICENSE"         -Content ""
    Add-Artifact -Name "README.md"       -Source "README.md"                          -Dest "README.md"       -Content ""

    Materialize-Artifacts -StageDir $stagePwsh

    $mcpbPwshPath = Join-Path $OutDir "shebang-mcp-sdk.pwsh.mcpb"
    New-McpbArchive -StageDir $stagePwsh -DestinationMcpb $mcpbPwshPath
    $sha256Pwsh = (Get-FileHash -LiteralPath $mcpbPwshPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # =============================================================================
    # 3. Generate Official MCP Registry server.json with both MCPB packages
    # =============================================================================
    $releaseBase = "https://github.com/$RepoOwner/$RepoName/releases/download/v$Version"
    $serverJsonPath = Join-Path $RepoRoot "server.json"

    $serverManifest = [ordered]@{
        "`$schema"    = "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json"
        name          = "io.github.$RepoOwner/$RepoName"
        title         = "Shebang MCP SDK"
        description   = "Generic shell MCP SDK server with stdio and Streamable HTTP transports."
        version       = $Version
        websiteUrl    = "https://$RepoOwner.github.io/$RepoName"
        repository    = [ordered]@{
            url    = "https://github.com/$RepoOwner/$RepoName"
            source = "github"
        }
        packages      = @(
            [ordered]@{
                registryType         = "mcpb"
                identifier           = "$releaseBase/shebang-mcp-sdk.sh.mcpb"
                version              = $Version
                fileSha256           = $sha256Sh
                runtimeHint          = "sh"
                transport            = [ordered]@{
                    type = "stdio"
                }
                packageArguments     = @(
                    [ordered]@{
                        type        = "named"
                        name        = "--stdio"
                        description = "Run the POSIX sh MCP SDK server over standard input/output (stdio)"
                    }
                )
                environmentVariables = @(
                    [ordered]@{
                        name        = "MCP_TRANSPORT"
                        description = "Transport protocol: stdio or streamable-http"
                        isRequired  = $false
                    },
                    [ordered]@{
                        name        = "MCP_SERVER_NAME"
                        description = "MCP server name reported during initialize"
                        isRequired  = $false
                    },
                    [ordered]@{
                        name        = "MCP_SERVER_VERSION"
                        description = "MCP server version reported during initialize"
                        isRequired  = $false
                    }
                )
            },
            [ordered]@{
                registryType         = "mcpb"
                identifier           = "$releaseBase/shebang-mcp-sdk.pwsh.mcpb"
                version              = $Version
                fileSha256           = $sha256Pwsh
                runtimeHint          = "pwsh"
                transport            = [ordered]@{
                    type = "stdio"
                }
                packageArguments     = @(
                    [ordered]@{
                        type        = "named"
                        name        = "--stdio"
                        description = "Run the PowerShell MCP SDK server over standard input/output (stdio)"
                    }
                )
                environmentVariables = @(
                    [ordered]@{
                        name        = "MCP_TRANSPORT"
                        description = "Transport protocol: stdio or streamable-http"
                        isRequired  = $false
                    },
                    [ordered]@{
                        name        = "MCP_SERVER_NAME"
                        description = "MCP server name reported during initialize"
                        isRequired  = $false
                    },
                    [ordered]@{
                        name        = "MCP_SERVER_VERSION"
                        description = "MCP server version reported during initialize"
                        isRequired  = $false
                    }
                )
            }
        )
    }

    $serverJsonContent = ($serverManifest | ConvertTo-Json -Depth 10) + "`n"
    [System.IO.File]::WriteAllText($serverJsonPath, $serverJsonContent, $utf8NoBom)

    Write-Output "Built Multi-Package MCPB Bundles (v$Version):"
    Write-Output "  [1] POSIX sh MCPB (linux, darwin) : $mcpbShPath"
    Write-Output "      fileSha256                : $sha256Sh"
    Write-Output "  [2] PowerShell MCPB (win32)   : $mcpbPwshPath"
    Write-Output "      fileSha256                : $sha256Pwsh"
    Write-Output "  [3] MCP Registry              : $serverJsonPath"
} finally {
    if (Test-Path -LiteralPath $tempBase) {
        Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit 0
