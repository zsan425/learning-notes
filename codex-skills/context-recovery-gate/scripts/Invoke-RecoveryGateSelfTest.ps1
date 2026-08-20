param(
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$gateScript = Join-Path $projectRoot 'scripts\Test-RecoveryGate.ps1'
$fixtures = Join-Path $projectRoot 'assets\self-test'
$reportFile = if ($ReportPath) {
    [IO.Path]::GetFullPath($ReportPath)
} else {
    Join-Path ([IO.Path]::GetTempPath()) ("context-recovery-gate-self-test-$PID.json")
}
$reportsDirectory = Split-Path -Parent $reportFile
$removeReportAfterRun = -not [bool]$ReportPath
$runtime = Join-Path $projectRoot ('.poc-runtime-' + [guid]::NewGuid().ToString('N'))
$taskId = 'recovery-gate-poc-001'
$archiveTag = "archive/$taskId"
$testResults = [Collections.Generic.List[object]]::new()
$server = $null
$fatalError = ''
$cleanupPassed = $false

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-GitScalar {
    param(
        [string]$Repository,
        [string[]]$Arguments
    )
    return ((Invoke-GitChecked -Repository $Repository -Arguments $Arguments | Select-Object -First 1).ToString()).Trim()
}

function Invoke-Gate {
    param(
        [string]$Repository,
        [string]$Remote,
        [string]$DeploymentRoot,
        [string]$GateTaskId = $taskId,
        [string]$AllowedDeploymentOrigin = $script:allowedDeploymentOrigin,
        [switch]$GitOnly
    )

    $arguments = @(
        '-NoProfile',
        '-File', $gateScript,
        '-RepoRoot', $Repository,
        '-TaskId', $GateTaskId,
        '-Remote', $Remote
    )
    if (-not $GitOnly) {
        $arguments += @(
            '-DeploymentRoot', $DeploymentRoot,
            '-AllowedDeploymentOrigin', $AllowedDeploymentOrigin,
            '-VerifyHttp'
        )
    }
    $raw = @(& pwsh @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $json = $raw -join [Environment]::NewLine
    $parsed = $null
    try {
        $parsed = $json | ConvertFrom-Json -Depth 30
    } catch {
        return [ordered]@{
            exit_code = $exitCode
            report = $null
            raw = $json
            parse_error = $_.Exception.Message
        }
    }
    return [ordered]@{
        exit_code = $exitCode
        report = $parsed
        raw = $json
        parse_error = ''
    }
}

function Add-TestExpectation {
    param(
        [string]$Name,
        $GateRun,
        [bool]$ExpectedPass,
        [string[]]$RequiredFindingCodes = @()
    )

    $actualPass = $false
    $codes = @()
    if ($GateRun.report) {
        $actualPass = [bool]$GateRun.report.passed
        $codes = @($GateRun.report.findings | ForEach-Object { $_.code.ToString() })
    }
    $missingCodes = @($RequiredFindingCodes | Where-Object { $_ -notin $codes })
    $passed = ($actualPass -eq $ExpectedPass -and $missingCodes.Count -eq 0 -and -not $GateRun.parse_error)
    $testResults.Add([ordered]@{
        name = $Name
        expected_pass = $ExpectedPass
        actual_pass = $actualPass
        process_exit_code = $GateRun.exit_code
        required_finding_codes = $RequiredFindingCodes
        observed_finding_codes = $codes
        missing_required_codes = $missingCodes
        passed = $passed
        parse_error = $GateRun.parse_error
    })
}

function Invoke-ManifestFaultTest {
    param(
        [string]$Repository,
        [string]$DeploymentRoot,
        [string]$Name,
        [scriptblock]$Mutation,
        [string[]]$RequiredFindingCodes,
        [string]$Remote = 'origin'
    )

    $manifestFile = Join-Path $Repository 'recovery\recovery-manifest.json'
    $faultManifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json -Depth 30
    & $Mutation $faultManifest
    [IO.File]::WriteAllText(
        $manifestFile,
        ($faultManifest | ConvertTo-Json -Depth 30) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    try {
        $gateRun = Invoke-Gate -Repository $Repository -Remote $Remote -DeploymentRoot $DeploymentRoot
        Add-TestExpectation -Name $Name -GateRun $gateRun -ExpectedPass $false -RequiredFindingCodes $RequiredFindingCodes
    } finally {
        Invoke-GitChecked -Repository $Repository -Arguments @('restore', '--source', 'HEAD', '--', 'recovery/recovery-manifest.json') | Out-Null
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Assert-SafeRuntimePath {
    param([string]$Path)
    $rootPrefix = $projectRoot.TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Runtime cleanup path escaped project root: $full"
    }
    if ([IO.Path]::GetFileName($full) -notlike '.poc-runtime-*') {
        throw "Runtime cleanup path has an unexpected leaf: $full"
    }
}

try {
    if (-not (Test-Path -LiteralPath $gateScript -PathType Leaf)) {
        throw "Gate script is missing: $gateScript"
    }

    New-Item -ItemType Directory -Path $runtime | Out-Null
    $authorRepo = Join-Path $runtime 'author'
    $remoteRepo = Join-Path $runtime 'remote.git'
    $taglessRemote = Join-Path $runtime 'tagless.git'
    $restoreRepo = Join-Path $runtime 'restore'
    $deployedSite = Join-Path $runtime 'deployed-site'
    $restoredSite = Join-Path $runtime 'restored-site'

    New-Item -ItemType Directory -Path $authorRepo | Out-Null
    & git init --bare --initial-branch=main $remoteRepo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the bare origin.' }
    & git init --bare --initial-branch=main $taglessRemote | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the tagless bare remote.' }
    & git -C $authorRepo init -b main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the author repository.' }

    Invoke-GitChecked -Repository $authorRepo -Arguments @('config', 'user.name', 'Recovery Gate PoC') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('config', 'user.email', 'recovery-gate@example.invalid') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('remote', 'add', 'origin', $remoteRepo) | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('remote', 'add', 'tagless-source', $taglessRemote) | Out-Null

    Copy-Item -LiteralPath (Join-Path $fixtures 'site-src') -Destination $authorRepo -Recurse
    Copy-Item -LiteralPath (Join-Path $fixtures 'skill-output') -Destination $authorRepo -Recurse
    Copy-Item -LiteralPath (Join-Path $fixtures 'notes') -Destination $authorRepo -Recurse
    New-Item -ItemType Directory -Path (Join-Path $authorRepo 'tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtures 'build-site.ps1') -Destination (Join-Path $authorRepo 'tools\build-site.ps1')

    Invoke-GitChecked -Repository $authorRepo -Arguments @('add', '--', 'site-src', 'skill-output', 'notes', 'tools/build-site.ps1') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('commit', '-m', 'feat(poc): add deterministic skill website output') | Out-Null
    $sourceCommit = Get-GitScalar -Repository $authorRepo -Arguments @('rev-parse', 'HEAD')
    $deploymentId = 'poc-' + $sourceCommit.Substring(0, 12)
    $port = Get-FreeTcpPort
    $script:allowedDeploymentOrigin = "http://127.0.0.1:${port}"

    $authorBuildParameters = @{
        SourceRoot      = $authorRepo
        OutputDirectory = $deployedSite
        SourceCommit    = $sourceCommit
        DeploymentId    = $deploymentId
    }
    & (Join-Path $authorRepo 'tools\build-site.ps1') @authorBuildParameters

    $trackedPaths = @('site-src/index.html', 'skill-output/RESULT.md', 'notes/通用 工作记录.md', 'tools/build-site.ps1')
    $trackedOutputs = @(
        foreach ($path in $trackedPaths) {
            [ordered]@{
                path = $path
                git_object = Get-GitScalar -Repository $authorRepo -Arguments @('rev-parse', "${sourceCommit}:$path")
                type = 'release'
                stage = 'validated'
            }
        }
    )
    $deploymentArtifacts = @(
        foreach ($path in @('index.html', 'version.json')) {
            [ordered]@{
                path = $path
                sha256 = (Get-FileHash -LiteralPath (Join-Path $deployedSite $path) -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )

    $manifest = [ordered]@{
        schema_version = '1.0'
        task_id = $taskId
        type = 'release'
        state = 'ready_for_hard_cold'
        persistence_profile = 'git_and_deployment'
        repository_url = $remoteRepo
        branch = 'main'
        source_commit = $sourceCommit
        manifest_ref = $archiveTag
        archive_scope_paths = @('site-src', 'skill-output', 'notes', 'tools/build-site.ps1', 'recovery/recovery-manifest.json')
        tracked_outputs = $trackedOutputs
        deployment = [ordered]@{
            url = "http://127.0.0.1:${port}/"
            version_url = "http://127.0.0.1:${port}/version.json"
            deployment_id = $deploymentId
            source_commit = $sourceCommit
            artifacts = $deploymentArtifacts
        }
        validation = [ordered]@{
            status = 'passed'
            evidence = @('skill-output/RESULT.md')
        }
        known_limits = @('PoC only; no production deployment or hardware validation')
        must_not_claim = @('This PoC does not validate MOCE firmware or production infrastructure')
        restore_commands = @(
            "git clone '$remoteRepo' 'restore-copy'",
            "git -C 'restore-copy' fetch --tags",
            "git -C 'restore-copy' checkout '$archiveTag'"
        )
    }

    $recoveryDirectory = Join-Path $authorRepo 'recovery'
    New-Item -ItemType Directory -Path $recoveryDirectory | Out-Null
    $manifestJson = $manifest | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText(
        (Join-Path $recoveryDirectory 'recovery-manifest.json'),
        $manifestJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    Invoke-GitChecked -Repository $authorRepo -Arguments @('add', '--', 'recovery/recovery-manifest.json') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('commit', '-m', 'docs(poc): add recovery manifest') | Out-Null
    $manifestCommit = Get-GitScalar -Repository $authorRepo -Arguments @('rev-parse', 'HEAD')
    Invoke-GitChecked -Repository $authorRepo -Arguments @('tag', '-a', $archiveTag, '-m', "Archive $taskId") | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('push', '-u', 'origin', 'main') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('push', 'origin', $archiveTag) | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('push', 'tagless-source', 'main') | Out-Null

    $gitOnlyTaskId = 'recovery-gate-git-only-001'
    $gitOnlyTag = "archive/$gitOnlyTaskId"
    $gitOnlyManifest = $manifestJson | ConvertFrom-Json -Depth 30
    $gitOnlyManifest.task_id = $gitOnlyTaskId
    $gitOnlyManifest.persistence_profile = 'git_only'
    $gitOnlyManifest.manifest_ref = $gitOnlyTag
    $gitOnlyManifest.PSObject.Properties.Remove('deployment')
    [IO.File]::WriteAllText(
        (Join-Path $recoveryDirectory 'recovery-manifest.json'),
        ($gitOnlyManifest | ConvertTo-Json -Depth 30) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Invoke-GitChecked -Repository $authorRepo -Arguments @('add', '--', 'recovery/recovery-manifest.json') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('commit', '-m', 'docs(poc): add generic git-only recovery profile') | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('tag', '-a', $gitOnlyTag, '-m', "Archive $gitOnlyTaskId") | Out-Null
    Invoke-GitChecked -Repository $authorRepo -Arguments @('push', 'origin', 'main', $gitOnlyTag) | Out-Null

    & git clone --quiet $remoteRepo $restoreRepo
    if ($LASTEXITCODE -ne 0) { throw 'Failed to clone the recovery repository.' }
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('checkout', '--quiet', $archiveTag) | Out-Null
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('remote', 'add', 'tagless', $taglessRemote) | Out-Null

    $restoreBuildParameters = @{
        SourceRoot      = $restoreRepo
        OutputDirectory = $restoredSite
        SourceCommit    = $sourceCommit
        DeploymentId    = $deploymentId
    }
    & (Join-Path $restoreRepo 'tools\build-site.ps1') @restoreBuildParameters

    $python = (Get-Command python -ErrorAction Stop).Source
    $serverParameters = @{
        FilePath     = $python
        ArgumentList = @('-m', 'http.server', $port.ToString(), '--bind', '127.0.0.1', '--directory', $restoredSite)
        PassThru     = $true
        WindowStyle  = 'Hidden'
    }
    $server = Start-Process @serverParameters

    $ready = $false
    foreach ($attempt in 1..30) {
        try {
            $probe = Invoke-WebRequest -Uri "http://127.0.0.1:${port}/version.json" -TimeoutSec 1
            if ($probe.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        throw 'Local PoC website did not become ready.'
    }

    $nonGitDirectory = Join-Path $runtime 'non-git-input'
    New-Item -ItemType Directory -Path $nonGitDirectory | Out-Null
    $nonGit = Invoke-Gate -Repository $nonGitDirectory -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_non_git_workspace -GateRun $nonGit -ExpectedPass $false -RequiredFindingCodes @('repository_not_git')

    $positive = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name positive_clean_clone -GateRun $positive -ExpectedPass $true

    $unauthorizedOrigin = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite -AllowedDeploymentOrigin 'http://127.0.0.1:1'
    Add-TestExpectation -Name reject_unapproved_http_origin -GateRun $unauthorizedOrigin -ExpectedPass $false -RequiredFindingCodes @('http_origin_not_authorized')

    $unsafeRemoteName = Invoke-Gate -Repository $restoreRepo -Remote '--upload-pack=calc.exe' -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_unsafe_remote_name -GateRun $unsafeRemoteName -ExpectedPass $false -RequiredFindingCodes @('remote_name_invalid')

    Invoke-GitChecked -Repository $restoreRepo -Arguments @('checkout', '--quiet', $gitOnlyTag) | Out-Null
    $gitOnlyPositive = Invoke-Gate -Repository $restoreRepo -Remote origin -GateTaskId $gitOnlyTaskId -GitOnly
    Add-TestExpectation -Name positive_git_only_chinese_small_text -GateRun $gitOnlyPositive -ExpectedPass $true
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('checkout', '--quiet', $archiveTag) | Out-Null

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_manifest_path_escape `
        -RequiredFindingCodes @('unsafe_archive_scope_path', 'deployment_artifact_path_unsafe') `
        -Mutation {
            param($value)
            $value.archive_scope_paths[0] = '../outside'
            $value.deployment.artifacts[0].path = '../outside.html'
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_windows_unsafe_path `
        -RequiredFindingCodes @('unsafe_archive_scope_path', 'deployment_artifact_path_unsafe') `
        -Mutation {
            param($value)
            $value.archive_scope_paths[0] = 'notes/data:secret'
            $value.deployment.artifacts[0].path = 'NUL.txt'
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_manifest_sensitive_value `
        -RequiredFindingCodes @('manifest_sensitive_value') `
        -Mutation {
            param($value)
            $value | Add-Member -NotePropertyName api_key -NotePropertyValue 'test-secret-material-123456'
        }

    $restoreManifestFile = Join-Path $restoreRepo 'recovery\recovery-manifest.json'
    [IO.File]::WriteAllText($restoreManifestFile, '{', [Text.UTF8Encoding]::new($false))
    try {
        $invalidJson = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
        Add-TestExpectation -Name reject_invalid_manifest_json -GateRun $invalidJson -ExpectedPass $false -RequiredFindingCodes @('manifest_invalid_json')
    } finally {
        Invoke-GitChecked -Repository $restoreRepo -Arguments @('restore', '--source', 'HEAD', '--', 'recovery/recovery-manifest.json') | Out-Null
    }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_manifest_missing_required_object `
        -RequiredFindingCodes @('manifest_required_field_missing') `
        -Mutation {
            param($value)
            $value.PSObject.Properties.Remove('deployment')
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_oversized_manifest `
        -RequiredFindingCodes @('manifest_too_large') `
        -Mutation {
            param($value)
            $value | Add-Member -NotePropertyName oversized_notes -NotePropertyValue ('x' * 70000)
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_restore_command_injection `
        -RequiredFindingCodes @('restore_command_unsafe') `
        -Mutation {
            param($value)
            $value.restore_commands[0] = 'git clone origin restore-copy; Remove-Item important.txt'
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_git_clone_execution_option `
        -RequiredFindingCodes @('restore_command_unsafe') `
        -Mutation {
            param($value)
            $value.restore_commands[0] = 'git clone --upload-pack calc.exe origin restore-copy'
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_non_release_tracked_output `
        -RequiredFindingCodes @('tracked_output_not_release') `
        -Mutation {
            param($value)
            $value.tracked_outputs[0].stage = 'probe'
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_undeclared_archive_file `
        -RequiredFindingCodes @('archive_file_not_declared') `
        -Mutation {
            param($value)
            $value.tracked_outputs = @($value.tracked_outputs | Select-Object -Skip 1)
        }

    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_missing_validation_evidence `
        -RequiredFindingCodes @('validation_evidence_not_in_source') `
        -Mutation {
            param($value)
            $value.validation.evidence = @('validation/missing-evidence.json')
        }

    $unsafeRemoteUrl = 'ext::echo SHOULD_NOT_EXECUTE'
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('remote', 'add', 'unsafe', $unsafeRemoteUrl) | Out-Null
    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_unsafe_remote_helper `
        -Remote unsafe `
        -RequiredFindingCodes @('remote_url_unsafe') `
        -Mutation {
            param($value)
            $value.repository_url = $unsafeRemoteUrl
        }

    $unreachableRemoteUrl = Join-Path $runtime 'does-not-exist.git'
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('remote', 'add', 'unreachable', $unreachableRemoteUrl) | Out-Null
    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_unreachable_remote `
        -Remote unreachable `
        -RequiredFindingCodes @('remote_branch_fetch_failed', 'remote_archive_tag_missing') `
        -Mutation {
            param($value)
            $value.repository_url = $unreachableRemoteUrl
        }

    $reparseTarget = Join-Path $runtime 'reparse-target'
    $reparseLink = Join-Path $restoredSite 'reparse-link'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    [IO.File]::WriteAllText((Join-Path $reparseTarget 'outside.txt'), 'outside deployment root', [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
    $reparseHash = (Get-FileHash -LiteralPath (Join-Path $reparseTarget 'outside.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    Invoke-ManifestFaultTest -Repository $restoreRepo -DeploymentRoot $restoredSite `
        -Name reject_deployment_reparse_point `
        -RequiredFindingCodes @('deployment_reparse_point_forbidden') `
        -Mutation {
            param($value)
            $value.deployment.artifacts[0].path = 'reparse-link/outside.txt'
            $value.deployment.artifacts[0].sha256 = $reparseHash
        }

    $probeManifest = Get-Content -LiteralPath $restoreManifestFile -Raw | ConvertFrom-Json -Depth 20
    $probeManifest.type = 'probe'
    [IO.File]::WriteAllText(
        $restoreManifestFile,
        ($probeManifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $probe = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_probe_hard_cold -GateRun $probe -ExpectedPass $false -RequiredFindingCodes @('probe_not_hard_cold')
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('restore', '--source', $archiveTag, '--', 'recovery/recovery-manifest.json') | Out-Null

    Invoke-GitChecked -Repository $restoreRepo -Arguments @('tag', '--delete', $archiveTag) | Out-Null
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('tag', $archiveTag, $manifestCommit) | Out-Null
    $lightweightTag = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_lightweight_archive_tag -GateRun $lightweightTag -ExpectedPass $false -RequiredFindingCodes @('archive_tag_not_annotated')
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('tag', '--delete', $archiveTag) | Out-Null
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('fetch', '--quiet', '--force', 'origin', "refs/tags/${archiveTag}:refs/tags/${archiveTag}") | Out-Null

    Add-Content -LiteralPath (Join-Path $restoreRepo 'site-src\index.html') -Value '<!-- tampered -->'
    $tampered = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_tampered_tracked_source -GateRun $tampered -ExpectedPass $false -RequiredFindingCodes @('archive_scope_not_clean')
    Invoke-GitChecked -Repository $restoreRepo -Arguments @('restore', '--source', $archiveTag, '--', 'site-src/index.html') | Out-Null

    [IO.File]::WriteAllText(
        (Join-Path $restoreRepo 'skill-output\only-local.txt'),
        'This file exists only in the local worktree.',
        [Text.UTF8Encoding]::new($false)
    )
    $untracked = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_untracked_scope_file -GateRun $untracked -ExpectedPass $false -RequiredFindingCodes @('archive_scope_not_clean')
    Remove-Item -LiteralPath (Join-Path $restoreRepo 'skill-output\only-local.txt') -Force

    $tagless = Invoke-Gate -Repository $restoreRepo -Remote tagless -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_remote_without_archive_tag -GateRun $tagless -ExpectedPass $false -RequiredFindingCodes @('remote_archive_tag_missing')

    $badVersion = [ordered]@{
        schema_version = '1.0'
        deployment_id = $deploymentId
        source_commit = ('0' * 40)
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        (Join-Path $restoredSite 'version.json'),
        $badVersion + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $deploymentMismatch = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name reject_deployment_commit_mismatch -GateRun $deploymentMismatch -ExpectedPass $false -RequiredFindingCodes @('deployment_source_mismatch', 'deployment_artifact_hash_mismatch')

    & (Join-Path $restoreRepo 'tools\build-site.ps1') @restoreBuildParameters
    $finalPositive = Invoke-Gate -Repository $restoreRepo -Remote origin -DeploymentRoot $restoredSite
    Add-TestExpectation -Name positive_after_fault_repair -GateRun $finalPositive -ExpectedPass $true
} catch {
    $fatalError = $_.Exception.ToString()
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        $server.WaitForExit(5000) | Out-Null
    }

    try {
        Assert-SafeRuntimePath -Path $runtime
        if (Test-Path -LiteralPath $runtime) {
            Remove-Item -LiteralPath $runtime -Recurse -Force
        }
        $cleanupPassed = -not (Test-Path -LiteralPath $runtime)
    } catch {
        $cleanupPassed = $false
        if (-not $fatalError) {
            $fatalError = $_.Exception.ToString()
        } else {
            $fatalError += [Environment]::NewLine + $_.Exception.ToString()
        }
    }
}

New-Item -ItemType Directory -Path $reportsDirectory -Force | Out-Null
$failedTests = @($testResults | Where-Object { -not $_.passed })
$runtimeResidue = @(Get-ChildItem -LiteralPath $projectRoot -Directory -Filter '.poc-runtime-*' -Force -ErrorAction SilentlyContinue)
$overallPassed = (-not $fatalError -and $failedTests.Count -eq 0 -and $cleanupPassed -and $runtimeResidue.Count -eq 0)

$finalReport = [ordered]@{
    schema_version = '1.0'
    generated_at = (Get-Date).ToString('o')
    passed = $overallPassed
    environment = [ordered]@{
        git = (git --version)
        powershell = $PSVersionTable.PSVersion.ToString()
        python = (python --version 2>&1)
    }
    protocol = [ordered]@{
        task_id = $taskId
        source_commit_then_manifest_commit = $true
        annotated_archive_tag = $true
        git_required = $true
        probe_never_hard_cold = $true
        clean_clone_required = $true
        website_commit_binding_required = $true
    }
    tests = $testResults
    cleanup = [ordered]@{
        passed = $cleanupPassed
        runtime_residue_count = $runtimeResidue.Count
    }
    fatal_error = $fatalError
}

$reportJson = $finalReport | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($reportFile, $reportJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$reportJson

if ($removeReportAfterRun -and (Test-Path -LiteralPath $reportFile -PathType Leaf)) {
    Remove-Item -LiteralPath $reportFile -Force
}

if (-not $overallPassed) {
    exit 1
}
