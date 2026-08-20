param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [string]$Remote = 'origin',

    [string]$DeploymentRoot = '',

    [string]$AllowedDeploymentOrigin = '',

    [switch]$VerifyHttp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$manifestPath = 'recovery/recovery-manifest.json'
$maxManifestBytes = 65536
$maxCollectionItems = 128
$findings = [Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [ValidateSet('error', 'warning', 'info')]
        [string]$Severity,
        [string]$Code,
        [string]$Detail
    )

    $findings.Add([ordered]@{
        severity = $Severity
        code = $Code
        detail = $Detail
    })
}

function Invoke-RepoGit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& git -C $script:repo @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    return [ordered]@{
        exit_code = $exitCode
        output = $output
    }
}

function Get-ScalarGitOutput {
    param([string[]]$Arguments)
    $result = Invoke-RepoGit -Arguments $Arguments
    return (($result.output | Select-Object -First 1).ToString()).Trim()
}

function Test-NonEmptyArray {
    param($Value)
    return ($null -ne $Value -and @($Value).Count -gt 0)
}

function Test-HasProperty {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return $false
    }
    $property = $Object.PSObject.Properties[$Name]
    return ($null -ne $property -and $null -ne $property.Value)
}

function Test-GitObjectId {
    param([string]$Value)
    return ($Value -match '^(?:[0-9a-f]{40}|[0-9a-f]{64})$')
}

function Test-SafeRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 512) {
        return $false
    }
    if ($Path.Contains('\') -or $Path.IndexOfAny([char[]]':*?"<>|') -ge 0) {
        return $false
    }
    if (@($Path.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) {
        return $false
    }
    if ($Path.StartsWith('/') -or $Path.StartsWith(':') -or $Path -match '^[A-Za-z]:') {
        return $false
    }
    $segments = @($Path -split '/')
    if ($segments.Count -eq 0) {
        return $false
    }
    foreach ($segment in $segments) {
        if ($segment -in @('', '.', '..') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            return $false
        }
        $deviceBase = ($segment -split '\.')[0]
        if ($deviceBase -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])$') {
            return $false
        }
    }
    return $true
}

function Get-SafeChildPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )
    if (-not (Test-SafeRelativePath -Path $RelativePath)) {
        return $null
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $candidate
}

function Test-ChildPathHasReparsePoint {
    param(
        [string]$Root,
        [string]$RelativePath
    )
    $current = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    foreach ($segment in @($RelativePath -split '/')) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            return $false
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

function Test-ManifestContainsSensitiveMaterial {
    param([string]$Raw)
    $patterns = @(
        '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)(?:https?|ssh)://[^/\s:@]+:[^/\s@]+@',
        '(?i)"(?:password|passwd|token|api[_-]?key|client[_-]?secret|private[_-]?key|credential)"\s*:\s*"(?!\s*(?:redacted|none|null|replace[^" ]*)\s*")[^"]{4,}"'
    )
    return @($patterns | Where-Object { $Raw -match $_ }).Count -gt 0
}

function Test-RestoreCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command) -or $Command.Length -gt 2048) {
        return $false
    }
    if ($Command -match '[;|&`<>]|\$\(' -or
        @($Command.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0 -or
        $Command -cmatch '(?:^|\s)(?:-c|(?i:--config|--upload-pack|-u|--exec-path|--template))(?:=|\s)') {
        return $false
    }
    $argument = '(?:''[^'']+''|"[^"]+"|[^\s]+)'
    if ($Command -match "^git clone\s+$argument\s+$argument$") {
        return $true
    }
    if ($Command -match "^git -C\s+$argument\s+fetch\s+--tags$") {
        return $true
    }
    if ($Command -match "^git -C\s+$argument\s+checkout\s+(?<archive>$argument)$") {
        $archive = $Matches.archive.Trim("'`"")
        return $archive -match '^archive/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
    }
    return $false
}

function Protect-UrlForReport {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }
    return ($Value -replace '(?i)(://)[^/@\s]+@', '$1***@')
}

function Test-SafeRemoteUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url.Length -gt 2048) {
        return $false
    }
    if ($Url -match '^(?i)(?:ext|fd|helper)::' -or $Url -match '[\r\n]') {
        return $false
    }
    if ($Url -match '^[A-Za-z]:[\\/]' -or $Url -match '^\\\\') {
        return $true
    }
    if ($Url -match '^[^@/\s:]+@[^/\s:]+:.+$') {
        return $true
    }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    if ($uri.Scheme -notin @('https', 'ssh', 'file')) {
        return $false
    }
    if (($uri.Scheme -eq 'https' -and $uri.UserInfo) -or $uri.UserInfo -match ':') {
        return $false
    }
    return $true
}

function Get-ValidatedHttpUri {
    param([string]$Value)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Value) -or
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        return $null
    }
    return $uri
}

$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$deployment = if ($DeploymentRoot -and (Test-Path -LiteralPath $DeploymentRoot -PathType Container)) {
    (Resolve-Path -LiteralPath $DeploymentRoot).Path
} else {
    ''
}
$manifestFile = Join-Path $repo ($manifestPath -replace '/', [IO.Path]::DirectorySeparatorChar)

$insideResult = Invoke-RepoGit -Arguments @('rev-parse', '--is-inside-work-tree') -AllowFailure
$inside = if ($insideResult.exit_code -eq 0 -and @($insideResult.output).Count -gt 0) {
    (($insideResult.output | Select-Object -First 1).ToString()).Trim()
} else {
    ''
}
if ($inside -ne 'true') {
    Add-Finding error repository_not_git $repo
    [ordered]@{
        schema_version = '1.0'
        task_id = $TaskId
        passed = $false
        repository = $repo
        findings = $findings
    } | ConvertTo-Json -Depth 20
    exit 2
}

if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    Add-Finding error manifest_missing $manifestPath
}

$trackedCheck = Invoke-RepoGit -Arguments @('ls-files', '--error-unmatch', '--', $manifestPath) -AllowFailure
if ($trackedCheck.exit_code -ne 0) {
    Add-Finding error manifest_untracked $manifestPath
}

$manifest = $null
$manifestRaw = ''
if (Test-Path -LiteralPath $manifestFile -PathType Leaf) {
    $manifestItem = Get-Item -LiteralPath $manifestFile -Force
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Add-Finding error manifest_reparse_point_forbidden $manifestPath
    }
    if ($manifestItem.Length -gt $maxManifestBytes) {
        Add-Finding error manifest_too_large "Maximum=$maxManifestBytes; actual=$($manifestItem.Length)"
    }
    $manifestModeResult = Invoke-RepoGit -Arguments @('ls-files', '--stage', '--', $manifestPath) -AllowFailure
    if ($manifestModeResult.exit_code -eq 0 -and @($manifestModeResult.output).Count -gt 0) {
        $manifestMode = ((($manifestModeResult.output | Select-Object -First 1).ToString()).Trim() -split '\s+')[0]
        if ($manifestMode -notin @('100644', '100755')) {
            Add-Finding error manifest_unsafe_git_mode "Expected regular file, got $manifestMode"
        }
    }
    if ($manifestItem.Length -le $maxManifestBytes) {
        try {
            $manifestRaw = Get-Content -LiteralPath $manifestFile -Raw
            if (Test-ManifestContainsSensitiveMaterial -Raw $manifestRaw) {
                Add-Finding error manifest_sensitive_value 'Recovery manifest contains credential-like material.'
            }
            $manifest = $manifestRaw | ConvertFrom-Json -Depth 20
        } catch {
            Add-Finding error manifest_invalid_json $_.Exception.Message
        }
    }
}

$head = Get-ScalarGitOutput -Arguments @('rev-parse', 'HEAD')
$remoteNameValid = $Remote -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
if (-not $remoteNameValid) {
    Add-Finding error remote_name_invalid $Remote
}
$remoteUrlResult = if ($remoteNameValid) {
    Invoke-RepoGit -Arguments @('remote', 'get-url', $Remote) -AllowFailure
} else {
    [ordered]@{ exit_code = 2; output = @() }
}
$remoteUrl = if ($remoteUrlResult.exit_code -eq 0) {
    (($remoteUrlResult.output | Select-Object -First 1).ToString()).Trim()
} else {
    ''
}

if (-not $manifest) {
    $report = [ordered]@{
        schema_version = '1.0'
        task_id = $TaskId
        passed = $false
        repository = $repo
        head = $head
        findings = $findings
    }
    $report | ConvertTo-Json -Depth 20
    exit 2
}

$requiredTopLevel = @(
    'schema_version', 'task_id', 'type', 'state', 'persistence_profile', 'repository_url', 'branch',
    'source_commit', 'manifest_ref', 'archive_scope_paths', 'tracked_outputs',
    'validation', 'known_limits', 'must_not_claim', 'restore_commands'
)
$missingFields = [Collections.Generic.List[string]]::new()
foreach ($field in $requiredTopLevel) {
    if (-not (Test-HasProperty -Object $manifest -Name $field)) {
        $missingFields.Add($field)
    }
}
$persistenceProfile = if (Test-HasProperty -Object $manifest -Name 'persistence_profile') {
    $manifest.persistence_profile.ToString()
} else {
    ''
}
$deploymentObject = if (Test-HasProperty -Object $manifest -Name 'deployment') { $manifest.deployment } else { $null }
$validationObject = if (Test-HasProperty -Object $manifest -Name 'validation') { $manifest.validation } else { $null }
if ($persistenceProfile -eq 'git_and_deployment') {
    if ($null -eq $deploymentObject) {
        $missingFields.Add('deployment')
    }
    foreach ($field in @('url', 'version_url', 'deployment_id', 'source_commit', 'artifacts')) {
        if (-not (Test-HasProperty -Object $deploymentObject -Name $field)) {
            $missingFields.Add("deployment.$field")
        }
    }
}
foreach ($field in @('status', 'evidence')) {
    if (-not (Test-HasProperty -Object $validationObject -Name $field)) {
        $missingFields.Add("validation.$field")
    }
}
if ($missingFields.Count -gt 0) {
    Add-Finding error manifest_required_field_missing ($missingFields -join ', ')
    [ordered]@{
        schema_version = '1.0'
        task_id = $TaskId
        passed = $false
        repository = $repo
        head = $head
        findings = $findings
    } | ConvertTo-Json -Depth 20
    exit 2
}

if ($manifest.schema_version -ne '1.0') {
    Add-Finding error schema_version_unsupported "Expected 1.0, got $($manifest.schema_version)"
}
if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
    Add-Finding error task_id_invalid $TaskId
}
if ($manifest.task_id -ne $TaskId) {
    Add-Finding error task_id_mismatch "Expected $TaskId, got $($manifest.task_id)"
}
if ($manifest.type -ne 'release') {
    Add-Finding error probe_not_hard_cold "Only release is eligible; got $($manifest.type)"
}
if ($persistenceProfile -notin @('git_only', 'git_and_deployment')) {
    Add-Finding error persistence_profile_invalid $persistenceProfile
}
if ($persistenceProfile -eq 'git_only' -and $null -ne $deploymentObject) {
    Add-Finding error deployment_forbidden_for_git_only 'Remove stale deployment claims from a git_only manifest.'
}
if ($manifest.state -ne 'ready_for_hard_cold') {
    Add-Finding error state_not_ready "Got $($manifest.state)"
}
if (-not $remoteUrl) {
    Add-Finding error remote_missing $Remote
} elseif ($manifest.repository_url -ne $remoteUrl) {
    Add-Finding error repository_url_mismatch 'Manifest repository URL does not match the selected Git remote.'
}
if ($remoteUrl -and -not (Test-SafeRemoteUrl -Url $remoteUrl)) {
    Add-Finding error remote_url_unsafe (Protect-UrlForReport -Value $remoteUrl)
}

$sourceCommit = $manifest.source_commit.ToString()
$manifestRef = $manifest.manifest_ref.ToString()
$branch = $manifest.branch.ToString()

if (-not (Test-GitObjectId -Value $sourceCommit)) {
    Add-Finding error source_commit_invalid $sourceCommit
}
if ($manifestRef -ne "archive/$TaskId") {
    Add-Finding error archive_ref_mismatch "Expected archive/$TaskId, got $manifestRef"
}
$branchCheck = Invoke-RepoGit -Arguments @('check-ref-format', '--branch', $branch) -AllowFailure
if ($branchCheck.exit_code -ne 0) {
    Add-Finding error branch_name_invalid $branch
}

$localTagResult = Invoke-RepoGit -Arguments @('rev-parse', "$manifestRef^{commit}") -AllowFailure
$manifestCommit = if ($localTagResult.exit_code -eq 0) {
    (($localTagResult.output | Select-Object -First 1).ToString()).Trim()
} else {
    ''
}
if (-not $manifestCommit) {
    Add-Finding error local_archive_tag_missing $manifestRef
} elseif ($manifestCommit -ne $head) {
    Add-Finding error head_not_archive_commit "HEAD=$head; tag=$manifestCommit"
}

$localTagObjectResult = Invoke-RepoGit -Arguments @('rev-parse', "refs/tags/$manifestRef") -AllowFailure
$localTagObject = if ($localTagObjectResult.exit_code -eq 0 -and @($localTagObjectResult.output).Count -gt 0) {
    (($localTagObjectResult.output | Select-Object -First 1).ToString()).Trim()
} else {
    ''
}
if ($localTagObject) {
    $localTagType = Get-ScalarGitOutput -Arguments @('cat-file', '-t', "refs/tags/$manifestRef")
    if ($localTagType -ne 'tag') {
        Add-Finding error archive_tag_not_annotated "Expected annotated tag object, got $localTagType"
    }
}

if ($manifestCommit -and (Test-GitObjectId -Value $sourceCommit)) {
    if ($sourceCommit -eq $manifestCommit) {
        Add-Finding error source_manifest_commit_not_separate 'source commit A and manifest commit B must be distinct'
    }
    $ancestorResult = Invoke-RepoGit -Arguments @('merge-base', '--is-ancestor', $sourceCommit, $manifestCommit) -AllowFailure
    if ($ancestorResult.exit_code -ne 0) {
        Add-Finding error source_not_ancestor "source=$sourceCommit; manifest=$manifestCommit"
    }
}

if ($remoteUrl -and (Test-SafeRemoteUrl -Url $remoteUrl) -and $manifestCommit -and $branchCheck.exit_code -eq 0) {
    $fetchBranch = Invoke-RepoGit -Arguments @('fetch', '--quiet', $Remote, "refs/heads/${branch}:refs/remotes/${Remote}/${branch}") -AllowFailure
    if ($fetchBranch.exit_code -ne 0) {
        Add-Finding error remote_branch_fetch_failed (Protect-UrlForReport -Value ($fetchBranch.output -join '; '))
    } else {
        $remoteBranch = "refs/remotes/$Remote/$branch"
        $remoteAncestor = Invoke-RepoGit -Arguments @('merge-base', '--is-ancestor', $manifestCommit, $remoteBranch) -AllowFailure
        if ($remoteAncestor.exit_code -ne 0) {
            Add-Finding error manifest_commit_not_remote_reachable "manifest=$manifestCommit; remote=$remoteBranch"
        }
    }

    $remoteTagResult = Invoke-RepoGit -Arguments @('ls-remote', '--refs', $Remote, "refs/tags/$manifestRef") -AllowFailure
    $remoteTagLine = if ($remoteTagResult.exit_code -eq 0 -and @($remoteTagResult.output).Count -gt 0) {
        (($remoteTagResult.output | Select-Object -First 1).ToString()).Trim()
    } else {
        ''
    }
    if (-not $remoteTagLine) {
        Add-Finding error remote_archive_tag_missing $manifestRef
    } else {
        # `ls-remote --refs` returns the annotated tag object, while ^{commit}
        # returns its peeled commit. Compare like with like.
        $remoteTagObject = ($remoteTagLine -split '\s+')[0]
        if (-not $localTagObject -or $remoteTagObject -ne $localTagObject) {
            Add-Finding error remote_archive_tag_mismatch "local=$localTagObject; remote=$remoteTagObject"
        }
    }
}

if ($manifestCommit) {
    $manifestAtTag = Invoke-RepoGit -Arguments @('cat-file', '-e', "${manifestCommit}:$manifestPath") -AllowFailure
    if ($manifestAtTag.exit_code -ne 0) {
        Add-Finding error manifest_not_in_archive_commit $manifestPath
    }
}

$scopePaths = @($manifest.archive_scope_paths)
$safeScopePaths = [Collections.Generic.List[string]]::new()
if (-not (Test-NonEmptyArray $scopePaths)) {
    Add-Finding error archive_scope_empty 'archive_scope_paths must not be empty'
} else {
    if ($scopePaths.Count -gt $maxCollectionItems) {
        Add-Finding error archive_scope_too_many "Maximum=$maxCollectionItems; actual=$($scopePaths.Count)"
    }
    foreach ($scopePathValue in $scopePaths) {
        $scopePath = $scopePathValue.ToString()
        if (-not (Test-SafeRelativePath -Path $scopePath)) {
            Add-Finding error unsafe_archive_scope_path $scopePath
        } else {
            $safeScopePaths.Add($scopePath)
        }
    }
    if ($manifestPath -notin $safeScopePaths) {
        Add-Finding error manifest_not_in_archive_scope $manifestPath
    }
    if ($safeScopePaths.Count -gt 0) {
        $statusArguments = @('status', '--porcelain=v1', '--untracked-files=all', '--ignored', '--') + @($safeScopePaths)
        $scopeStatus = Invoke-RepoGit -Arguments $statusArguments
        if (@($scopeStatus.output).Count -gt 0) {
            Add-Finding error archive_scope_not_clean ($scopeStatus.output -join '; ')
        }
    }
}

$declaredTrackedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if (-not (Test-NonEmptyArray $manifest.tracked_outputs)) {
    Add-Finding error tracked_outputs_empty 'tracked_outputs must not be empty'
} else {
    if (@($manifest.tracked_outputs).Count -gt $maxCollectionItems) {
        Add-Finding error tracked_outputs_too_many "Maximum=$maxCollectionItems; actual=$(@($manifest.tracked_outputs).Count)"
    }
    foreach ($tracked in @($manifest.tracked_outputs)) {
        foreach ($requiredTrackedField in @('path', 'git_object', 'type', 'stage')) {
            if (-not (Test-HasProperty -Object $tracked -Name $requiredTrackedField)) {
                Add-Finding error tracked_output_required_field_missing $requiredTrackedField
            }
        }
        if (-not (Test-HasProperty -Object $tracked -Name 'path') -or
            -not (Test-HasProperty -Object $tracked -Name 'git_object')) {
            continue
        }
        $path = $tracked.path.ToString()
        $expectedObject = $tracked.git_object.ToString()
        if (-not (Test-SafeRelativePath -Path $path)) {
            Add-Finding error unsafe_tracked_output_path $path
            continue
        }
        if (-not $declaredTrackedPaths.Add($path)) {
            Add-Finding error tracked_output_path_duplicate $path
            continue
        }
        if (-not (Test-GitObjectId -Value $expectedObject)) {
            Add-Finding error tracked_output_object_invalid "$path object=$expectedObject"
            continue
        }
        if (-not (Test-HasProperty -Object $tracked -Name 'type') -or
            -not (Test-HasProperty -Object $tracked -Name 'stage') -or
            $tracked.type -ne 'release' -or $tracked.stage -ne 'validated') {
            Add-Finding error tracked_output_not_release "$path type=$($tracked.type) stage=$($tracked.stage)"
        }
        $objectResult = Invoke-RepoGit -Arguments @('rev-parse', "${sourceCommit}:$path") -AllowFailure
        if ($objectResult.exit_code -ne 0) {
            Add-Finding error tracked_output_missing "$path at $sourceCommit"
            continue
        }
        $actualObject = (($objectResult.output | Select-Object -First 1).ToString()).Trim()
        if ($actualObject -ne $expectedObject) {
            Add-Finding error tracked_output_object_mismatch "$path expected=$expectedObject actual=$actualObject"
        }
        $treeEntry = Invoke-RepoGit -Arguments @('ls-tree', $sourceCommit, '--', $path) -AllowFailure
        if ($treeEntry.exit_code -eq 0 -and @($treeEntry.output).Count -gt 0) {
            $gitMode = ((($treeEntry.output | Select-Object -First 1).ToString()).Trim() -split '\s+')[0]
            if ($gitMode -notin @('100644', '100755')) {
                Add-Finding error tracked_output_unsafe_git_mode "$path mode=$gitMode"
            }
        }
    }
}

if ((Test-GitObjectId -Value $sourceCommit) -and $safeScopePaths.Count -gt 0) {
    $sourceScopeFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($scopePath in $safeScopePaths) {
        if ($scopePath -eq $manifestPath) {
            continue
        }
        # Git quotes non-ASCII paths by default. Disable quoting for this
        # machine comparison so Chinese and spaced paths remain byte-equivalent
        # to the manifest declaration.
        $scopeTree = Invoke-RepoGit -Arguments @('-c', 'core.quotePath=false', 'ls-tree', '-r', '--name-only', $sourceCommit, '--', $scopePath) -AllowFailure
        if ($scopeTree.exit_code -ne 0) {
            Add-Finding error archive_scope_tree_read_failed $scopePath
            continue
        }
        foreach ($sourceFileValue in @($scopeTree.output)) {
            $sourceFile = $sourceFileValue.ToString().Trim()
            if ($sourceFile) {
                [void]$sourceScopeFiles.Add($sourceFile)
            }
        }
    }
    foreach ($sourceFile in $sourceScopeFiles) {
        if (-not $declaredTrackedPaths.Contains($sourceFile)) {
            Add-Finding error archive_file_not_declared "$sourceFile has no type/stage/object declaration"
        }
    }
    foreach ($declaredPath in $declaredTrackedPaths) {
        $covered = @($safeScopePaths | Where-Object {
            $declaredPath -eq $_ -or $declaredPath.StartsWith("$_/", [StringComparison]::Ordinal)
        }).Count -gt 0
        if (-not $covered) {
            Add-Finding error tracked_output_outside_archive_scope $declaredPath
        }
    }
}

if ($manifest.validation.status -ne 'passed') {
    Add-Finding error validation_not_passed $manifest.validation.status
}
if (-not (Test-NonEmptyArray $manifest.validation.evidence)) {
    Add-Finding error validation_evidence_empty 'validation.evidence must not be empty'
} else {
    foreach ($evidenceValue in @($manifest.validation.evidence)) {
        $evidencePath = $evidenceValue.ToString()
        if (-not (Test-SafeRelativePath -Path $evidencePath)) {
            Add-Finding error validation_evidence_path_unsafe $evidencePath
            continue
        }
        $evidenceResult = Invoke-RepoGit -Arguments @('cat-file', '-e', "${sourceCommit}:$evidencePath") -AllowFailure
        if ($evidenceResult.exit_code -ne 0) {
            Add-Finding error validation_evidence_not_in_source "$evidencePath at $sourceCommit"
        }
    }
}
if (-not (Test-NonEmptyArray $manifest.known_limits)) {
    Add-Finding error known_limits_empty 'known_limits must not be empty'
}
if (-not (Test-NonEmptyArray $manifest.must_not_claim)) {
    Add-Finding error must_not_claim_empty 'must_not_claim must not be empty'
}
if (-not (Test-NonEmptyArray $manifest.restore_commands)) {
    Add-Finding error restore_commands_empty 'restore_commands must not be empty'
} else {
    foreach ($restoreCommandValue in @($manifest.restore_commands)) {
        $restoreCommand = $restoreCommandValue.ToString()
        if (-not (Test-RestoreCommand -Command $restoreCommand)) {
            Add-Finding error restore_command_unsafe $restoreCommand
        }
    }
}

$deploymentUri = $null
$versionUri = $null
$httpOriginAuthorized = $false
if ($persistenceProfile -eq 'git_and_deployment') {
    if (-not $deployment) {
        Add-Finding error deployment_root_missing $DeploymentRoot
    } else {
        $deploymentUri = Get-ValidatedHttpUri -Value $manifest.deployment.url.ToString()
        $versionUri = Get-ValidatedHttpUri -Value $manifest.deployment.version_url.ToString()
        if (-not $deploymentUri -or -not $versionUri) {
            Add-Finding error deployment_url_invalid 'deployment.url and version_url must be absolute HTTP(S) URLs without credentials.'
        } elseif ($deploymentUri.Scheme -ne $versionUri.Scheme -or
                  $deploymentUri.Host -ne $versionUri.Host -or
                  $deploymentUri.Port -ne $versionUri.Port) {
            Add-Finding error deployment_version_origin_mismatch "site=$deploymentUri; version=$versionUri"
        }
        if ($VerifyHttp) {
            $allowedOriginUri = Get-ValidatedHttpUri -Value $AllowedDeploymentOrigin
            if (-not $allowedOriginUri -or -not $deploymentUri -or
                $allowedOriginUri.Scheme -ne $deploymentUri.Scheme -or
                $allowedOriginUri.Host -ne $deploymentUri.Host -or
                $allowedOriginUri.Port -ne $deploymentUri.Port) {
                Add-Finding error http_origin_not_authorized "allowed=$AllowedDeploymentOrigin; requested=$deploymentUri"
            } else {
                $httpOriginAuthorized = $true
            }
        }

        $versionFile = Join-Path $deployment 'version.json'
        if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
            Add-Finding error deployment_version_missing $versionFile
        } else {
            if (Test-ChildPathHasReparsePoint -Root $deployment -RelativePath 'version.json') {
                Add-Finding error deployment_reparse_point_forbidden 'version.json'
            }
            try {
                $version = Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
                if ($version.deployment_id -ne $manifest.deployment.deployment_id) {
                    Add-Finding error deployment_id_mismatch "manifest=$($manifest.deployment.deployment_id); actual=$($version.deployment_id)"
                }
                if ($version.source_commit -ne $sourceCommit -or $manifest.deployment.source_commit -ne $sourceCommit) {
                    Add-Finding error deployment_source_mismatch "source=$sourceCommit; manifest=$($manifest.deployment.source_commit); actual=$($version.source_commit)"
                }
            } catch {
                Add-Finding error deployment_version_invalid $_.Exception.Message
            }
        }

        if (-not (Test-NonEmptyArray $manifest.deployment.artifacts)) {
            Add-Finding error deployment_artifacts_empty 'deployment.artifacts must not be empty'
        } else {
            if (@($manifest.deployment.artifacts).Count -gt $maxCollectionItems) {
                Add-Finding error deployment_artifacts_too_many "Maximum=$maxCollectionItems; actual=$(@($manifest.deployment.artifacts).Count)"
            }
            $artifactPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($artifact in @($manifest.deployment.artifacts)) {
                foreach ($requiredArtifactField in @('path', 'sha256')) {
                    if (-not (Test-HasProperty -Object $artifact -Name $requiredArtifactField)) {
                        Add-Finding error deployment_artifact_required_field_missing $requiredArtifactField
                    }
                }
                if (-not (Test-HasProperty -Object $artifact -Name 'path') -or
                    -not (Test-HasProperty -Object $artifact -Name 'sha256')) {
                    continue
                }
                $artifactPath = $artifact.path.ToString()
                $expectedSha = $artifact.sha256.ToString().ToLowerInvariant()
                $artifactFile = Get-SafeChildPath -Root $deployment -RelativePath $artifactPath
                if (-not $artifactFile) {
                    Add-Finding error deployment_artifact_path_unsafe $artifactPath
                    continue
                }
                if (-not $artifactPaths.Add($artifactPath)) {
                    Add-Finding error deployment_artifact_path_duplicate $artifactPath
                    continue
                }
                if ($expectedSha -notmatch '^[0-9a-f]{64}$') {
                    Add-Finding error deployment_artifact_hash_invalid "$artifactPath sha256=$expectedSha"
                    continue
                }
                if (-not (Test-Path -LiteralPath $artifactFile -PathType Leaf)) {
                    Add-Finding error deployment_artifact_missing $artifactPath
                    continue
                }
                if (Test-ChildPathHasReparsePoint -Root $deployment -RelativePath $artifactPath) {
                    Add-Finding error deployment_reparse_point_forbidden $artifactPath
                    continue
                }
                $actualSha = (Get-FileHash -LiteralPath $artifactFile -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualSha -ne $expectedSha) {
                    Add-Finding error deployment_artifact_hash_mismatch "$artifactPath expected=$expectedSha actual=$actualSha"
                }
            }
        }
    }
}

if ($VerifyHttp -and $httpOriginAuthorized -and $deploymentUri -and $versionUri) {
    try {
        $httpVersion = Invoke-RestMethod -Uri $manifest.deployment.version_url -TimeoutSec 5
        if ($httpVersion.source_commit -ne $sourceCommit -or $httpVersion.deployment_id -ne $manifest.deployment.deployment_id) {
            Add-Finding error http_deployment_version_mismatch $manifest.deployment.version_url
        }
        $indexResponse = Invoke-WebRequest -Uri $manifest.deployment.url -TimeoutSec 5
        if ($indexResponse.StatusCode -ne 200 -or $indexResponse.Content -notmatch [regex]::Escape($sourceCommit)) {
            Add-Finding error http_deployment_content_mismatch $manifest.deployment.url
        }
    } catch {
        Add-Finding error http_deployment_unreachable $_.Exception.Message
    }
}

$errorCount = @($findings | Where-Object { $_.severity -eq 'error' }).Count
$report = [ordered]@{
    schema_version = '1.0'
    task_id = $TaskId
    passed = ($errorCount -eq 0)
    repository = $repo
    remote = (Protect-UrlForReport -Value $remoteUrl)
    head = $head
    source_commit = $sourceCommit
    manifest_commit = $manifestCommit
    archive_ref = $manifestRef
    checked_http = [bool]$VerifyHttp
    findings = $findings
}

$report | ConvertTo-Json -Depth 20
if ($errorCount -ne 0) {
    exit 2
}
