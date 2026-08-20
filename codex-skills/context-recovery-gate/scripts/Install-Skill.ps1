param(
    [string]$CodexHome = '',
    [switch]$Force,
    [switch]$RunSelfTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$skillName = 'context-recovery-gate'
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$resolvedCodexHome = if ($CodexHome) {
    [IO.Path]::GetFullPath($CodexHome)
} elseif ($env:CODEX_HOME) {
    [IO.Path]::GetFullPath($env:CODEX_HOME)
} else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}
$skillsRoot = Join-Path $resolvedCodexHome 'skills'
$destination = Join-Path $skillsRoot $skillName
$backup = ''

function Invoke-JsonCheck {
    param([string]$Script, [string[]]$Arguments)
    $raw = @(& pwsh -NoProfile -File $Script @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $raw -join [Environment]::NewLine
    try {
        $report = $text | ConvertFrom-Json -Depth 30
    } catch {
        throw "Validation script returned non-JSON output: $text"
    }
    if ($exitCode -ne 0 -or -not $report.passed) {
        throw "Validation failed: $text"
    }
    return $report
}

$packageReport = Invoke-JsonCheck -Script (Join-Path $sourceRoot 'scripts\Test-PackageIntegrity.ps1') -Arguments @('-SkillRoot', $sourceRoot)
if ($RunSelfTest) {
    $selfTestReport = Invoke-JsonCheck -Script (Join-Path $sourceRoot 'scripts\Invoke-RecoveryGateSelfTest.ps1') -Arguments @()
}

New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
$sourceFull = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
$destinationFull = [IO.Path]::GetFullPath($destination).TrimEnd('\')
if ($sourceFull.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
    [ordered]@{
        installed = $true
        changed = $false
        destination = $destinationFull
        package_files = $packageReport.declared_file_count
        self_tested = [bool]$RunSelfTest
        message = 'The verified Skill is already running from the installation directory.'
    } | ConvertTo-Json -Depth 5
    exit 0
}

$staging = Join-Path $skillsRoot ('.context-recovery-gate-install-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $resolvedCodexHome 'skill-backups'
try {
    Copy-Item -LiteralPath $sourceRoot -Destination $staging -Recurse
    if (Test-Path -LiteralPath $destination) {
        if (-not $Force) {
            throw "Skill already exists at $destination. Re-run with -Force to create a backup and upgrade."
        }
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $backup = Join-Path $backupRoot ("$skillName-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Move-Item -LiteralPath $destination -Destination $backup
    }
    Move-Item -LiteralPath $staging -Destination $destination
} catch {
    if ($backup -and -not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $destination
        $backup = ''
    }
    throw
} finally {
    if (Test-Path -LiteralPath $staging) {
        $stagingLeaf = [IO.Path]::GetFileName($staging)
        if ($stagingLeaf -like '.context-recovery-gate-install-*' -and
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($staging)) -eq [IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
}

[ordered]@{
    installed = $true
    changed = $true
    destination = $destination
    backup = $backup
    package_files = $packageReport.declared_file_count
    self_tested = [bool]$RunSelfTest
    restart_codex_required = $true
} | ConvertTo-Json -Depth 5
