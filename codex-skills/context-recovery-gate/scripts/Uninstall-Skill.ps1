param(
    [string]$CodexHome = '',
    [switch]$ConfirmRemoval
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ConfirmRemoval) {
    throw 'Uninstall requires -ConfirmRemoval. The installed Skill will be moved to a recoverable backup.'
}

$skillName = 'context-recovery-gate'
$resolvedCodexHome = if ($CodexHome) {
    [IO.Path]::GetFullPath($CodexHome)
} elseif ($env:CODEX_HOME) {
    [IO.Path]::GetFullPath($env:CODEX_HOME)
} else {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}
$skillsRoot = Join-Path $resolvedCodexHome 'skills'
$destination = Join-Path $skillsRoot $skillName
if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
    [ordered]@{ uninstalled = $true; changed = $false; destination = $destination } | ConvertTo-Json
    exit 0
}

$expectedDestination = [IO.Path]::GetFullPath((Join-Path $skillsRoot $skillName)).TrimEnd('\')
$actualDestination = [IO.Path]::GetFullPath($destination).TrimEnd('\')
if (-not $actualDestination.Equals($expectedDestination, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to uninstall unexpected path: $actualDestination"
}
$skillFile = Join-Path $destination 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf) -or
    (Get-Content -LiteralPath $skillFile -Raw) -notmatch '(?m)^name:\s*context-recovery-gate\s*$') {
    throw "Destination does not contain the expected Skill identity: $destination"
}

$backupRoot = Join-Path $resolvedCodexHome 'skill-backups'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$backup = Join-Path $backupRoot ("$skillName-uninstalled-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Move-Item -LiteralPath $destination -Destination $backup

[ordered]@{
    uninstalled = $true
    changed = $true
    destination = $destination
    recoverable_backup = $backup
} | ConvertTo-Json -Depth 5
