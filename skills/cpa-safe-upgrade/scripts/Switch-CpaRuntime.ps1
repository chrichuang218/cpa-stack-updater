[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [Parameter(Mandatory = $true)][string]$SourceRuntime,
    [Parameter(Mandatory = $true)][string]$TargetRuntime,
    [Parameter(Mandatory = $true)][string]$CandidatePackageRoot,
    [Parameter(Mandatory = $true)][string]$SourceConfig,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedCandidateHash,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedTargetRuntimeManifestSha256,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedTargetConfigHash,
    [string]$ExpectedTargetHost,
    [int]$Port = 8317,
    [switch]$DeferFinalCommit,
    [switch]$InProcess
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")

$sourceExe = Join-Path $SourceRuntime "cli-proxy-api.exe"
$targetExe = Join-Path $TargetRuntime "cli-proxy-api.exe"
$candidateExe = Join-Path $CandidatePackageRoot "cli-proxy-api.exe"
$targetConfig = Join-Path $TargetRuntime "config.yaml"
$sourceAuth = Join-Path $SourceRuntime "auth"
$targetAuth = Join-Path $TargetRuntime "auth"
$sourcePlugins = Join-Path $SourceRuntime "plugins"
$targetPlugins = Join-Path $TargetRuntime "plugins"
$sameRuntime = [System.IO.Path]::GetFullPath($SourceRuntime).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($TargetRuntime).TrimEnd('\')
$rollbackRoot = Join-Path $ControlRoot "rollback\last-known-good\cpa"
$journalPath = Join-Path $ControlRoot "state\switch-cpa.pending.json"
$journal = $null
$snapshotStaging = $null
$result = [ordered]@{
    component  = "CPA"
    success    = $false
    rolledBack = $false
    sourcePath = $sourceExe
    targetPath = $targetExe
    oldHash    = $null
    newHash    = Get-CpaStackFileHash -Path $candidateExe
    activeHash = $null
    modelCount = 0
    targetRuntimeManifestSha256 = $null
    targetConfigSha256 = $null
    targetHost = $null
    backupPath = if ($sameRuntime) { $rollbackRoot } else { $SourceRuntime }
    backupCleanupWarning = $null
    journalCleanupWarning = $null
    commitDeferred = $false
    error      = $null
}

function Start-CpaFormal {
    param([string]$Exe, [string]$Runtime, [string]$Config)
    return Start-CpaStackProcess -FilePath $Exe -Arguments "-config `"$Config`"" -WorkingDirectory $Runtime -MinimalEnvironment
}

function Test-CpaFormal {
    param([string]$ExpectedExe, [string]$Config, [int]$ExpectedProcessId, [string]$ExpectedHash)

    $configContent = [System.IO.File]::ReadAllText($Config, [System.Text.UTF8Encoding]::new($false, $true))
    $hostMatch = [regex]::Match($configContent, '(?m)^host:\s*["'']?(?<host>[^"''#\s]+)')
    if (-not $hostMatch.Success) {
        throw 'CPA config must declare an explicit host before formal credentialed validation.'
    }
    $allowedAddresses = switch ($hostMatch.Groups['host'].Value.ToLowerInvariant()) {
        'localhost' { @('127.0.0.1', '::1') }
        default { @($hostMatch.Groups['host'].Value) }
    }
    [void](Wait-CpaStackTrustedListener -Port $Port -ExpectedPath $ExpectedExe -ExpectedProcessId $ExpectedProcessId -ExpectedHash $ExpectedHash -AllowedAddresses $allowedAddresses -Seconds 35)

    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $managementHeaders = @{ Authorization = "Bearer $($secrets.cpaManagementKey)" }
    $clientHeaders = @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" }
    [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$Port/v0/management/config" -Headers $managementHeaders -Seconds 35)
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$Port/v1/models" -Headers $clientHeaders -Seconds 20
    [void](Wait-CpaStackTrustedListener -Port $Port -ExpectedPath $ExpectedExe -ExpectedProcessId $ExpectedProcessId -ExpectedHash $ExpectedHash -AllowedAddresses $allowedAddresses -Seconds 2)
    $count = if ($models.data) { @($models.data).Count } else { 0 }
    if ($count -lt 1) {
        throw "CPA returned no models on port $Port."
    }
    return $count
}

try {
    $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
    Assert-CpaStackPath -Path $SourceRuntime
    Assert-CpaStackPath -Path $sourceExe -PathType Leaf
    Assert-CpaStackPath -Path $SourceConfig -PathType Leaf
    Assert-CpaStackPath -Path $candidateExe -PathType Leaf
    if ($sameRuntime) {
        Assert-CpaStackPrivateTree -Root $sourceAuth -Description 'Preserved CPA auth'
        if (Test-Path -LiteralPath $sourcePlugins) {
            Assert-CpaStackPrivateTree -Root $sourcePlugins -Description 'Preserved CPA plugins'
        }
    } else {
        Assert-CpaStackLegacyCpaSource -Runtime $SourceRuntime -ConfigPath $SourceConfig
    }
    if ($DeferFinalCommit -and -not $sameRuntime) {
        throw 'Deferred CPA commit is only valid for an in-place canonical upgrade.'
    }
    if ((Get-CpaStackFileHash -Path $candidateExe) -ne $ExpectedCandidateHash.ToUpperInvariant()) {
        throw 'CPA candidate executable hash changed after validation.'
    }
    Assert-CpaStackChildPath -Root $ControlRoot -Path $TargetRuntime
    if (-not $sameRuntime) {
        if ([string]::IsNullOrWhiteSpace($ExpectedTargetRuntimeManifestSha256) -or
            [string]::IsNullOrWhiteSpace($ExpectedTargetConfigHash) -or
            [string]::IsNullOrWhiteSpace($ExpectedTargetHost)) {
            throw 'A non-in-place CPA migration requires the post-candidate target manifest, config hash, and host.'
        }
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($CandidatePackageRoot).TrimEnd('\'), [System.IO.Path]::GetFullPath($TargetRuntime).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'A non-in-place CPA migration must start the exact candidate runtime that was tested.'
        }
        Assert-CpaStackPath -Path $targetConfig -PathType Leaf
        Assert-CpaStackPrivateTree -Root $TargetRuntime -Description 'Prepared CPA target runtime'
        $preparedManifest = Get-CpaStackTreeManifest -Root $TargetRuntime
        $result.targetRuntimeManifestSha256 = [string]$preparedManifest.sha256
        $result.targetConfigSha256 = Get-CpaStackFileHash -Path $targetConfig
        $result.targetHost = Get-CpaStackConfigHost -ConfigPath $targetConfig
        if ($result.targetRuntimeManifestSha256 -ne $ExpectedTargetRuntimeManifestSha256.ToUpperInvariant()) {
            throw 'Prepared CPA target runtime no longer matches the post-candidate manifest.'
        }
        if ($result.targetConfigSha256 -ne $ExpectedTargetConfigHash.ToUpperInvariant()) {
            throw 'Prepared CPA target config no longer matches the post-candidate hash.'
        }
        if (-not [string]::Equals([string]$result.targetHost, $ExpectedTargetHost, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Prepared CPA target host no longer matches the explicit migration decision.'
        }
    }

    $listener = Get-CpaStackListener -Port $Port
    if (-not $listener -or $listener.ExecutablePath -ine $sourceExe) {
        throw "CPA source process is not the owner of port $Port. Expected $sourceExe"
    }
    $result.oldHash = Get-CpaStackFileHash -Path $sourceExe

    if ($sameRuntime) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $rollbackRoot
        $operationId = [guid]::NewGuid().ToString("N")
        $snapshotStaging = Join-Path $ControlRoot ("rollback\staging-cpa-" + $operationId)
        $pending = Join-Path $ControlRoot ("rollback\pending-cpa-" + $operationId)
        Assert-CpaStackChildPath -Root $ControlRoot -Path $snapshotStaging
        Assert-CpaStackChildPath -Root $ControlRoot -Path $pending
        New-Item -ItemType Directory -Force -Path (Join-Path $snapshotStaging "runtime") | Out-Null
        Copy-CpaStackTree -Source $SourceRuntime -Destination (Join-Path $snapshotStaging "runtime") -ExcludeDirectoryNames @("auth", "plugins") -ExcludeFileNames @("config.yaml")
        $snapshotExe = Join-Path $snapshotStaging "runtime\cli-proxy-api.exe"
        if ((Get-CpaStackFileHash -Path $snapshotExe) -ne $result.oldHash) {
            throw "CPA rollback snapshot hash validation failed."
        }
        Write-CpaStackJson -Value ([ordered]@{
            operationId = $operationId
            capturedAt = (Get-Date).ToString("o")
            executableSha256 = $result.oldHash
            sourceRuntime = $SourceRuntime
        }) -Path (Join-Path $snapshotStaging "manifest.json")
    } else {
        $operationId = [guid]::NewGuid().ToString("N")
        $pending = $null
    }

    Assert-CpaStackChildPath -Root $ControlRoot -Path $journalPath
    $journal = [ordered]@{
        operation = "switch-cpa"
        operationId = $operationId
        instanceId = [string]$instanceMarker.instanceId
        phase = "prepared"
        createdAt = (Get-Date).ToString("o")
        sourceRuntime = $SourceRuntime
        targetRuntime = $TargetRuntime
        sourceConfig = $SourceConfig
        pendingPath = $pending
        oldHash = $result.oldHash
        newHash = $result.newHash
        targetRuntimeManifestSha256 = if ($sameRuntime) { $null } else { $ExpectedTargetRuntimeManifestSha256.ToUpperInvariant() }
        targetConfigSha256 = if ($sameRuntime) { $null } else { $ExpectedTargetConfigHash.ToUpperInvariant() }
        targetHost = if ($sameRuntime) { $null } else { $ExpectedTargetHost }
    }
    Write-CpaStackJson -Value $journal -Path $journalPath
    if ($sameRuntime) {
        Move-Item -LiteralPath $snapshotStaging -Destination $pending -ErrorAction Stop
        $snapshotStaging = $null
        $journal.phase = "prepared"
        Write-CpaStackJson -Value $journal -Path $journalPath
    }

    Stop-CpaStackPort -Port $Port -ExpectedPath $sourceExe
    $journal.phase = "source-stopped"
    Write-CpaStackJson -Value $journal -Path $journalPath

    try {
        if ($sameRuntime) {
            foreach ($item in Get-ChildItem -Force -LiteralPath $TargetRuntime) {
                if ($item.Name -in @("config.yaml", "auth", "plugins")) {
                    continue
                }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force
            }
            Copy-CpaStackTree -Source $CandidatePackageRoot -Destination $TargetRuntime -ExcludeDirectoryNames @("auth", "plugins") -ExcludeFileNames @("config.yaml")
        } else {
            Assert-CpaStackPrivateTree -Root $TargetRuntime -Description 'Prepared CPA target runtime'
            $formalManifest = Get-CpaStackTreeManifest -Root $TargetRuntime
            $result.targetRuntimeManifestSha256 = [string]$formalManifest.sha256
            $result.targetConfigSha256 = Get-CpaStackFileHash -Path $targetConfig
            $result.targetHost = Get-CpaStackConfigHost -ConfigPath $targetConfig
            if ($result.targetRuntimeManifestSha256 -ne $ExpectedTargetRuntimeManifestSha256.ToUpperInvariant() -or
                $result.targetConfigSha256 -ne $ExpectedTargetConfigHash.ToUpperInvariant() -or
                -not [string]::Equals([string]$result.targetHost, $ExpectedTargetHost, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Prepared CPA target changed after the legacy service stopped.'
            }
        }

        if ((Get-CpaStackFileHash -Path $targetExe) -ne $result.newHash) {
            throw "CPA target executable hash does not match the candidate."
        }
        Assert-CpaStackPrivateTree -Root $targetAuth -Description 'Preserved CPA auth'
        if (Test-Path -LiteralPath $targetPlugins) {
            Assert-CpaStackPrivateTree -Root $targetPlugins -Description 'Preserved CPA plugins'
        }
        $targetProcess = Start-CpaFormal -Exe $targetExe -Runtime $TargetRuntime -Config $targetConfig
        $result.modelCount = Test-CpaFormal -ExpectedExe $targetExe -Config $targetConfig -ExpectedProcessId $targetProcess.Id -ExpectedHash $result.newHash
        $result.activeHash = Get-CpaStackFileHash -Path $targetExe

        if ($sameRuntime -and $DeferFinalCommit) {
            $journal.phase = "runtime-verified"
            Write-CpaStackJson -Value $journal -Path $journalPath
            $result.commitDeferred = $true
        } elseif ($sameRuntime) {
            $commit = Commit-CpaStackDirectorySlot -ControlRoot $ControlRoot -PendingPath $pending -DestinationPath $rollbackRoot
            $result.backupCleanupWarning = $commit.cleanupWarning
        }
        $result.success = $true
        if (-not $DeferFinalCommit) {
            try { Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop }
            catch { $result.journalCleanupWarning = $_.Exception.Message }
        }
    } catch {
        $result.success = $false
        $switchError = $_.Exception.Message
        $recovered = $false
        $recoveryError = $null
        for ($attempt = 1; $attempt -le 3 -and -not $recovered; $attempt++) {
            try {
                $recoveryListener = Get-CpaStackListener -Port $Port
                if ($recoveryListener) {
                    if (@($sourceExe, $targetExe) -inotcontains $recoveryListener.ExecutablePath) {
                        throw "Unexpected process owns CPA port $Port during recovery: $($recoveryListener.ExecutablePath)"
                    }
                    Stop-CpaStackPort -Port $Port -ExpectedPath $recoveryListener.ExecutablePath
                }
                if ($sameRuntime) {
                    foreach ($item in Get-ChildItem -Force -LiteralPath $SourceRuntime) {
                        if ($item.Name -in @("config.yaml", "auth", "plugins")) {
                            continue
                        }
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force
                    }
                    Copy-CpaStackTree -Source (Join-Path $pending "runtime") -Destination $SourceRuntime
                }
                if ($sameRuntime -and (Test-Path -LiteralPath $sourcePlugins)) {
                    Assert-CpaStackPrivateTree -Root $sourcePlugins -Description 'Preserved CPA plugins'
                }
                $sourceProcess = Start-CpaFormal -Exe $sourceExe -Runtime $SourceRuntime -Config $SourceConfig
                [void](Test-CpaFormal -ExpectedExe $sourceExe -Config $SourceConfig -ExpectedProcessId $sourceProcess.Id -ExpectedHash $result.oldHash)
                $recovered = $true
            } catch {
                $recoveryError = $_.Exception.Message
                Start-Sleep -Seconds 1
            }
        }
        if (-not $recovered) {
            throw "CPA switch failed and automatic recovery also failed. Switch error: $switchError Recovery error: $recoveryError"
        }
        if ($sameRuntime -and $pending -and (Test-Path -LiteralPath $pending)) {
            $commit = Commit-CpaStackDirectorySlot -ControlRoot $ControlRoot -PendingPath $pending -DestinationPath $rollbackRoot
            $result.backupCleanupWarning = $commit.cleanupWarning
        }
        if (Test-Path -LiteralPath $journalPath) {
            try { Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop }
            catch { $result.journalCleanupWarning = $_.Exception.Message }
        }
        $result.rolledBack = $true
        $result.activeHash = Get-CpaStackFileHash -Path $sourceExe
        throw "CPA switch failed and the old service was restored: $switchError"
    }
} catch {
    $result.error = $_.Exception.Message
} finally {
    Write-CpaStackJson -Value $result -Path $ResultPath
    if ($snapshotStaging -and (Test-Path -LiteralPath $snapshotStaging)) {
        Remove-Item -LiteralPath $snapshotStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $result.success) {
    if ($InProcess) { throw $result.error }
    Write-Error $result.error
    exit 1
}

$result | ConvertTo-Json -Depth 8 -Compress
