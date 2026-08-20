param(
    [string]$SkillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $SkillRoot).Path
$manifestPath = Join-Path $root 'package-manifest.json'
$findings = [Collections.Generic.List[object]]::new()
$manifest = $null

function Add-Finding {
    param([string]$Code, [string]$Detail)
    $findings.Add([ordered]@{ code = $Code; detail = $Detail })
}

function Test-SafePackagePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or
        $Path.StartsWith('/') -or $Path.StartsWith(':') -or $Path -match '^[A-Za-z]:') {
        return $false
    }
    $segments = @($Path -split '/')
    return -not @($segments | Where-Object { $_ -in @('', '.', '..') }).Count
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-Finding package_manifest_missing 'package-manifest.json'
} else {
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 10
    } catch {
        Add-Finding package_manifest_invalid $_.Exception.Message
    }
}

$declared = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if ($null -ne $manifest) {
    if ($manifest.schema_version -ne '1.0' -or $manifest.skill -ne 'context-recovery-gate') {
        Add-Finding package_identity_invalid "schema=$($manifest.schema_version); skill=$($manifest.skill)"
    }
    foreach ($entry in @($manifest.files)) {
        $path = $entry.path.ToString()
        if (-not (Test-SafePackagePath -Path $path)) {
            Add-Finding package_path_unsafe $path
            continue
        }
        if (-not $declared.Add($path)) {
            Add-Finding package_path_duplicate $path
            continue
        }
        $file = [IO.Path]::GetFullPath((Join-Path $root ($path -replace '/', [IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Add-Finding package_file_missing $path
            continue
        }
        $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($entry.sha256 -notmatch '^[0-9a-f]{64}$' -or $actualHash -ne $entry.sha256) {
            Add-Finding package_hash_mismatch $path
        }
    }
}

$actualFiles = @(
    Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.FullName -ne $manifestPath } |
        ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') }
)
foreach ($path in $actualFiles) {
    if (-not $declared.Contains($path)) {
        Add-Finding package_file_undeclared $path
    }
}

$skillFile = Join-Path $root 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    Add-Finding skill_file_missing 'SKILL.md'
} else {
    $skillText = Get-Content -LiteralPath $skillFile -Raw
    if ($skillText -notmatch '(?m)^name:\s*context-recovery-gate\s*$' -or $skillText -match '\[TODO') {
        Add-Finding skill_frontmatter_invalid 'SKILL.md name is wrong or scaffold TODO remains.'
    }
}

foreach ($scriptFile in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File -Filter '*.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) {
        Add-Finding powershell_syntax_error "$($scriptFile.Name): $($parseError.Message)"
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    passed = ($findings.Count -eq 0)
    skill_root = $root
    declared_file_count = $declared.Count
    findings = $findings
}
$report | ConvertTo-Json -Depth 10
if ($findings.Count -gt 0) {
    exit 2
}
