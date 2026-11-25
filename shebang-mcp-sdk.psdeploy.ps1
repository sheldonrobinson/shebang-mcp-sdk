$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { Join-Path $env:USERPROFILE '.agents\shebang-mcp-sdk' }
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item -Recurse -Force -Path "$RepoRoot\*" -Destination $InstallRoot
New-Item -ItemType Directory -Path "${HOME}\.agents\skills" -Force | Out-Null
Copy-Item -Recurse -Force -Path "$RepoRoot\skills\shebang-mcp-sdk" -Destination "${HOME}\.agents\skills\shebang-mcp-sdk"
Write-Output "shebang-mcp-sdk installed to $InstallRoot"
