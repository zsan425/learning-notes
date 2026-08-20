param(
    [string]$SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $SkillRoot).Path
$manifestPath = Join-Path $root 'package-manifest.json'
$files = @(
    Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.FullName -ne $manifestPath } |
        ForEach-Object {
            [ordered]@{
                path = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        } |
        Sort-Object path
)

$manifest = [ordered]@{
    schema_version = '1.0'
    skill = 'context-recovery-gate'
    version = $Version
    files = $files
}

$json = $manifest | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($manifestPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$json
