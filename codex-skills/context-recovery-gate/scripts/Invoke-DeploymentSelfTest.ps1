param(
    [switch]$RunRecoverySelfTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$skillRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$installer = Join-Path $skillRoot 'scripts\Install-Skill.ps1'
$uninstaller = Join-Path $skillRoot 'scripts\Uninstall-Skill.ps1'
$runtime = Join-Path ([IO.Path]::GetTempPath()) ('context-recovery-gate-deploy-' + [guid]::NewGuid().ToString('N'))
$findings = [Collections.Generic.List[object]]::new()
$cleanupPassed = $false

function Add-Finding {
    param([string]$Code, [string]$Detail)
    $findings.Add([ordered]@{ code = $Code; detail = $Detail })
}

function Invoke-JsonProcess {
    param([string]$Script, [string[]]$Arguments, [bool]$ExpectedSuccess)
    $raw = @(& pwsh -NoProfile -File $Script @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $raw -join [Environment]::NewLine
    $parsed = $null
    try {
        $parsed = $text | ConvertFrom-Json -Depth 20
    } catch {
    }
    if ($ExpectedSuccess -and ($exitCode -ne 0 -or $null -eq $parsed)) {
        Add-Finding deployment_command_failed "script=$Script exit=$exitCode output=$text"
    }
    if (-not $ExpectedSuccess -and $exitCode -eq 0) {
        Add-Finding deployment_command_unexpected_success $Script
    }
    return [ordered]@{ exit_code = $exitCode; report = $parsed; raw = $text }
}

try {
    New-Item -ItemType Directory -Path $runtime | Out-Null
    $firstArguments = @('-CodexHome', $runtime)
    if ($RunRecoverySelfTest) {
        $firstArguments += '-RunSelfTest'
    }
    $first = Invoke-JsonProcess -Script $installer -Arguments $firstArguments -ExpectedSuccess $true
    $installed = Join-Path $runtime 'skills\context-recovery-gate'
    if (-not (Test-Path -LiteralPath (Join-Path $installed 'SKILL.md') -PathType Leaf)) {
        Add-Finding first_install_missing $installed
    }

    $refusal = Invoke-JsonProcess -Script $installer -Arguments @('-CodexHome', $runtime) -ExpectedSuccess $false
    if ($refusal.raw -notmatch 'already exists') {
        Add-Finding reinstall_without_force_not_rejected $refusal.raw
    }

    $upgrade = Invoke-JsonProcess -Script $installer -Arguments @('-CodexHome', $runtime, '-Force') -ExpectedSuccess $true
    if ($null -eq $upgrade.report -or -not $upgrade.report.backup -or
        -not (Test-Path -LiteralPath $upgrade.report.backup -PathType Container)) {
        Add-Finding upgrade_backup_missing 'Forced upgrade did not retain a recoverable backup.'
    }

    $integrity = Invoke-JsonProcess -Script (Join-Path $installed 'scripts\Test-PackageIntegrity.ps1') -Arguments @('-SkillRoot', $installed) -ExpectedSuccess $true
    if ($null -eq $integrity.report -or -not $integrity.report.passed) {
        Add-Finding installed_package_invalid $integrity.raw
    }

    $uninstall = Invoke-JsonProcess -Script $uninstaller -Arguments @('-CodexHome', $runtime, '-ConfirmRemoval') -ExpectedSuccess $true
    if (Test-Path -LiteralPath $installed) {
        Add-Finding uninstall_destination_still_exists $installed
    }
    if ($null -eq $uninstall.report -or -not (Test-Path -LiteralPath $uninstall.report.recoverable_backup -PathType Container)) {
        Add-Finding uninstall_backup_missing 'Uninstall did not retain a recoverable backup.'
    }
} catch {
    Add-Finding deployment_self_test_exception $_.Exception.Message
} finally {
    try {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $runtimeFull = [IO.Path]::GetFullPath($runtime)
        if (-not $runtimeFull.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($runtimeFull) -notlike 'context-recovery-gate-deploy-*') {
            throw "Unsafe deployment self-test cleanup path: $runtimeFull"
        }
        if (Test-Path -LiteralPath $runtimeFull) {
            Remove-Item -LiteralPath $runtimeFull -Recurse -Force
        }
        $cleanupPassed = -not (Test-Path -LiteralPath $runtimeFull)
    } catch {
        Add-Finding deployment_cleanup_failed $_.Exception.Message
    }
}

$report = [ordered]@{
    schema_version = '1.0'
    passed = ($findings.Count -eq 0 -and $cleanupPassed)
    recovery_self_test_requested = [bool]$RunRecoverySelfTest
    cleanup_passed = $cleanupPassed
    findings = $findings
}
$report | ConvertTo-Json -Depth 20
if (-not $report.passed) {
    exit 1
}
