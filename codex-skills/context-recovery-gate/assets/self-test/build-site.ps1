param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$SourceCommit,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$sourceIndex = Join-Path $source 'site-src\index.html'
if (-not (Test-Path -LiteralPath $sourceIndex -PathType Leaf)) {
    throw "Site source is missing: $sourceIndex"
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path

$index = Get-Content -LiteralPath $sourceIndex -Raw
if ($index -notmatch '__SOURCE_COMMIT__') {
    throw 'Site source does not contain the source-commit placeholder.'
}
# Git may check out text as CRLF or LF on different machines. Normalize before
# hashing so a clean-clone rebuild is byte-for-byte reproducible.
$index = $index -replace "`r`n?", "`n"
$index = $index.Replace('__SOURCE_COMMIT__', $SourceCommit)
[IO.File]::WriteAllText((Join-Path $output 'index.html'), $index, [Text.UTF8Encoding]::new($false))

$version = [ordered]@{
    schema_version = '1.0'
    deployment_id = $DeploymentId
    source_commit = $SourceCommit
}
$versionJson = $version | ConvertTo-Json -Depth 3
[IO.File]::WriteAllText(
    (Join-Path $output 'version.json'),
    $versionJson + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
