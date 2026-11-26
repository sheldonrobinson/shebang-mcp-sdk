$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallRoot = if ($env:PLUGIN_ROOT) { $env:PLUGIN_ROOT } else { [System.IO.Path]::Combine($HOME, '.agents', 'shebang-mcp-sdk') }
$SkillsRoot = [System.IO.Path]::Combine($HOME, '.agents', 'skills')
$BuilderSkillSource = [System.IO.Path]::Combine($RepoRoot, 'skills', 'shebang-mcp-builder')
$BuilderSkillDestination = [System.IO.Path]::Combine($SkillsRoot, 'shebang-mcp-builder')

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $RepoRoot '*') -Destination $InstallRoot
New-Item -ItemType Directory -Path $SkillsRoot -Force | Out-Null
Copy-Item -Recurse -Force -Path $BuilderSkillSource -Destination $BuilderSkillDestination
Write-Output "shebang-mcp-sdk installed to $InstallRoot"
