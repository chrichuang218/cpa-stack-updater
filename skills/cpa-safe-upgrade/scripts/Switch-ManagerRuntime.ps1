[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [Parameter(Mandatory = $true)][string]$SourceRuntime,
    [Parameter(Mandatory = $true)][string]$SourceData,
    [Parameter(Mandatory = $true)][string]$TargetRuntime,
    [Parameter(Mandatory = $true)][string]$TargetData,
    [Parameter(Mandatory = $true)][string]$CandidatePackageRoot,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedCandidateHash,
    [switch]$RequireV111Schema,
    [int]$ManagerPort = 18317,
    [int]$CpaPort = 8317,
    [ValidatePattern('^[0-9A-Fa-f]{32}$')][string]$ParentOperationId,
    [switch]$DeferFinalCommit,
    [scriptblock]$StartedProcessRegistration,
    [switch]$InProcess
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")
if ($null -ne $StartedProcessRegistration -and -not $InProcess) {
    throw '-StartedProcessRegistration is reserved for in-process callers.'
}

$sourceExe = Join-Path $SourceRuntime "cpa-manager-plus.exe"
$targetExe = Join-Path $TargetRuntime "cpa-manager-plus.exe"
$candidateExe = Join-Path $CandidatePackageRoot "cpa-manager-plus.exe"
$sourceDb = Join-Path $SourceData "usage.sqlite"
$targetDb = Join-Path $TargetData "usage.sqlite"
$sourceDataKey = Join-Path $SourceData "data.key"
$targetDataKey = Join-Path $TargetData "data.key"
$sameRuntime = [System.IO.Path]::GetFullPath($SourceRuntime).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($TargetRuntime).TrimEnd('\')
$sameData = [System.IO.Path]::GetFullPath($SourceData).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($TargetData).TrimEnd('\')
$rollbackRoot = Join-Path $ControlRoot "rollback\last-known-good\manager-plus"
$workVerification = Join-Path $ControlRoot ("work\mv-" + [guid]::NewGuid().ToString("N"))
$journalPath = Join-Path $ControlRoot "state\switch-manager.pending.json"
$journal = $null
$snapshotStaging = $null
$result = [ordered]@{
    schemaVersion    = 1
    operation        = "switch-manager"
    operationId      = $null
    parentOperationId = $ParentOperationId
    instanceId       = $null
    component       = "Manager Plus"
    managerPort     = $ManagerPort
    cpaPort         = $CpaPort
    success         = $false
    rolledBack      = $false
    sourcePath      = $sourceExe
    targetPath      = $targetExe
    sourceData      = $SourceData
    targetData      = $TargetData
    oldHash         = $null
    newHash         = Get-CpaStackFileHash -Path $candidateExe
    activeHash      = $null
    hasHistoricalData = $false
    collectorEnabled = $null
    dataKeyPreserved = $false
    sourceSnapshot   = $null
    backupPath      = if ($sameRuntime -and $sameData) { $rollbackRoot } else { [ordered]@{ runtime = $SourceRuntime; data = $SourceData } }
    backupCleanupWarning = $null
    journalCleanupWarning = $null
    commitDeferred  = $false
    error           = $null
}

$secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
$stackConfig = Get-CpaStackConfig -ControlRoot $ControlRoot
$managerBindAddress = [string]$stackConfig.Manager.BindAddress
$managerAllowedAddresses = switch ($managerBindAddress.Trim().TrimStart('[').TrimEnd(']').ToLowerInvariant()) {
    'localhost' { @('127.0.0.1', '::1') }
    default { @($managerBindAddress) }
}
$managerHeaders = @{ Authorization = "Bearer $($secrets.managerAdminKey)" }
$collectorDisabled = $false
$pending = $null
$baselinePath = $null
$baseline = $null
$backupComplete = $false
$formalBaseline = $null
$expectHistorical = $false
$targetProcess = $null
$sourceProcess = $null
$fixedSourceProcess = $null

function Start-ManagerFormal {
    param([string]$Exe, [string]$Runtime, [string]$Data)

    $environment = @{
        HTTP_ADDR            = "${managerBindAddress}:$ManagerPort"
        USAGE_DATA_DIR       = $Data
        USAGE_DB_PATH        = (Join-Path $Data "usage.sqlite")
        CPA_MANAGER_ADMIN_KEY = [string]$secrets.managerAdminKey
    }
    return Start-CpaStackProcess -FilePath $Exe -WorkingDirectory $Runtime -Environment $environment -RemoveEnvironment @("PANEL_PATH") -MinimalEnvironment -StartedProcessRegistration $StartedProcessRegistration
}

function Test-ManagerFormal {
    param(
        [string]$ExpectedExe,
        [string]$ExpectedData,
        [bool]$ExpectedCollector,
        [bool]$ExpectHistorical,
        [int]$ExpectedProcessId,
        [string]$ExpectedHash
    )

    [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $ExpectedExe -ExpectedProcessId $ExpectedProcessId -ExpectedHash $ExpectedHash -AllowedAddresses $managerAllowedAddresses -Seconds 40)
    [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/health" -Seconds 40)
    $info = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/info" -Headers $managerHeaders
    $status = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/status" -Headers $managerHeaders
    $config = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/config" -Headers $managerHeaders
    [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $ExpectedExe -ExpectedProcessId $ExpectedProcessId -ExpectedHash $ExpectedHash -AllowedAddresses $managerAllowedAddresses -Seconds 2)
    if ($ExpectHistorical -and -not [bool]$info.hasHistoricalData) {
        throw "Manager reports hasHistoricalData=false on port $ManagerPort."
    }
    if ($null -eq $config.config -or $null -eq $config.config.collector -or $null -eq $config.config.collector.enabled) {
        throw "Manager config.collector.enabled is missing on port $ManagerPort."
    }
    if ([bool]$config.config.collector.enabled -ne $ExpectedCollector) {
        throw "Manager collector state is not $ExpectedCollector on port $ManagerPort."
    }
    $expectedDb = [System.IO.Path]::GetFullPath((Join-Path $ExpectedData "usage.sqlite"))
    $actualDb = [System.IO.Path]::GetFullPath([string]$status.dbPath)
    if ($actualDb -ine $expectedDb) {
        throw "Manager is using an unexpected SQLite path: $actualDb"
    }
    $page = Invoke-WebRequest -Uri "http://127.0.0.1:$ManagerPort/management.html" -UseBasicParsing -TimeoutSec 10
    if ($page.StatusCode -ne 200 -or $page.Content -notmatch "CPA Manager Plus") {
        throw "Manager embedded page validation failed on port $ManagerPort."
    }
    return [pscustomobject]@{ info = $info; status = $status; config = $config }
}

function Copy-ManagerProgram {
    param([string]$PackageRoot, [string]$Runtime)

    New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
    foreach ($item in Get-ChildItem -Force -LiteralPath $Runtime) {
        if ($item.Name -in @("config.json", "server.log")) {
            continue
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
    Copy-CpaStackTree -Source $PackageRoot -Destination $Runtime -ExcludeDirectoryNames @("data") -ExcludeFileNames @("config.json", "server.log")
}

function Copy-ManagerDataSnapshot {
    param(
        [string]$FromData,
        [string]$ToData,
        [string]$MetadataPath
    )

    if (Test-Path -LiteralPath $ToData) {
        Remove-Item -LiteralPath $ToData -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $ToData | Out-Null
    $dataKey = Join-Path $FromData "data.key"
    Assert-CpaStackPath -Path $dataKey -PathType Leaf
    Copy-Item -LiteralPath $dataKey -Destination (Join-Path $ToData "data.key") -Force
    return Invoke-CpaStackSqliteBackup -Source (Join-Path $FromData "usage.sqlite") -Destination (Join-Path $ToData "usage.sqlite") -ResultPath $MetadataPath
}

function Assert-HistoryPreserved {
    param($Before, $After)

    foreach ($field in @("count", "max_id", "max_timestamp_ms")) {
        $beforeValue = $Before.snapshot.usage_events.$field
        $afterValue = $After.snapshot.usage_events.$field
        if ($null -ne $beforeValue -and ($null -eq $afterValue -or [Int64]$afterValue -lt [Int64]$beforeValue)) {
            throw "Manager history watermark regressed while collector was disabled: $field"
        }
    }
    foreach ($table in @("settings", "model_prices")) {
        $expectedProperty = $Before.snapshot.critical_table_counts.PSObject.Properties[$table]
        if ($null -eq $expectedProperty -or $null -eq $expectedProperty.Value) { continue }
        $actualProperty = $After.snapshot.critical_table_counts.PSObject.Properties[$table]
        $actualValue = if ($null -eq $actualProperty) { $null } else { $actualProperty.Value }
        if ($null -eq $actualValue -or [long]$actualValue -lt [long]$expectedProperty.Value) {
            throw "Manager authoritative table count decreased while collector was disabled: $table"
        }
    }
}

try {
    $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
    $result.instanceId = [string]$instanceMarker.instanceId
    Assert-CpaStackPath -Path $SourceRuntime
    Assert-CpaStackPath -Path $SourceData
    Assert-CpaStackPath -Path $sourceExe -PathType Leaf
    Assert-CpaStackPath -Path $sourceDb -PathType Leaf
    Assert-CpaStackPath -Path $candidateExe -PathType Leaf
    if ($sameRuntime -xor $sameData) {
        throw 'Manager runtime and data must either both remain in place or both move to canonical paths.'
    }
    if ($DeferFinalCommit -and (-not $sameRuntime -or -not $sameData)) {
        throw 'Deferred Manager commit is only valid for an in-place canonical upgrade.'
    }
    if ((Get-CpaStackFileHash -Path $candidateExe) -ne $ExpectedCandidateHash.ToUpperInvariant()) {
        throw 'Manager candidate executable hash changed after validation.'
    }
    Assert-CpaStackChildPath -Root $ControlRoot -Path $TargetRuntime
    Assert-CpaStackChildPath -Root $ControlRoot -Path $TargetData
    Assert-CpaStackChildPath -Root $ControlRoot -Path $workVerification
    if (-not $sameRuntime -and -not $sameData) {
        Assert-CpaStackLegacyManagerSource -Runtime $SourceRuntime -Data $SourceData
    }

    $listener = Get-CpaStackListener -Port $ManagerPort
    if (-not $listener -or $listener.ExecutablePath -ine $sourceExe) {
        throw "Manager source process is not the owner of port $ManagerPort. Expected $sourceExe"
    }
    $fixedSourceProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $sourceExe
    $result.oldHash = Get-CpaStackFileHash -Path $sourceExe
    [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $sourceExe -ExpectedProcessId $listener.ProcessId -ExpectedHash $result.oldHash -AllowedAddresses $managerAllowedAddresses -Seconds 2)
    $sourceDataKeyHash = Get-CpaStackFileHash -Path (Join-Path $SourceData "data.key")
    if (-not $sourceDataKeyHash) { throw "Manager source data.key is missing." }

    $formalBaseline = Get-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey
    $operationId = [guid]::NewGuid().ToString("N")
    $result.operationId = $operationId
    if ($sameRuntime -and $sameData) {
        $snapshotStaging = Join-Path $ControlRoot ("rollback\staging-manager-" + $operationId)
        $pending = Join-Path $ControlRoot ("rollback\pending-manager-" + $operationId)
        Assert-CpaStackPathBudget -Paths @($snapshotStaging, (Join-Path $snapshotStaging 'runtime'), (Join-Path $snapshotStaging 'data'), $pending, $rollbackRoot, ($rollbackRoot + '.previous-' + ('0' * 32)), $workVerification, (Join-Path $workVerification 'post-start'), (Join-Path $workVerification 'r-3'), (Join-Path $workVerification 'rp-3')) -PathType Container
        Assert-CpaStackProjectedTreePathBudget -Source $SourceRuntime -Destination (Join-Path $snapshotStaging 'runtime') -ExcludeDirectoryNames @('data') -ExcludeFileNames @('server.log')
        Assert-CpaStackPathBudget -Paths @((Join-Path $snapshotStaging 'data\usage.sqlite'), (Join-Path $snapshotStaging 'data\data.key'), (Join-Path $snapshotStaging 'data\usage.sqlite-wal'), (Join-Path $snapshotStaging 'data\usage.sqlite-shm')) -PathType Leaf
        Assert-CpaStackProjectedTreePathBudget -Source $CandidatePackageRoot -Destination $TargetRuntime -ExcludeDirectoryNames @('data') -ExcludeFileNames @('config.json', 'server.log')
        Assert-CpaStackJsonWritePathBudget -Paths @($journalPath, $ResultPath, (Join-Path $snapshotStaging 'manifest.json'), (Join-Path $snapshotStaging 'sqlite-backup.json'))
    } else {
        Assert-CpaStackPathBudget -Paths @($workVerification, (Join-Path $workVerification 'post-start'), (Join-Path $workVerification 'r-3'), (Join-Path $workVerification 'rp-3'), $TargetRuntime, $TargetData) -PathType Container
        Assert-CpaStackProjectedTreePathBudget -Source $TargetRuntime -Destination $TargetRuntime
        Assert-CpaStackPathBudget -Paths @($targetDb, $targetDataKey, ($targetDb + '-wal'), ($targetDb + '-shm'), (Join-Path $workVerification 'usage.sqlite'), (Join-Path $workVerification 'post-start\usage.sqlite')) -PathType Leaf
        Assert-CpaStackJsonWritePathBudget -Paths @($journalPath, $ResultPath, (Join-Path $workVerification 'sqlite-baseline.json'), (Join-Path $workVerification 'post-start\sqlite-after.json'))
    }
    Assert-CpaStackChildPath -Root $ControlRoot -Path $journalPath
    $journal = [ordered]@{
        schemaVersion = 1
        operation = "switch-manager"
        operationId = $operationId
        parentOperationId = $ParentOperationId
        instanceId = [string]$instanceMarker.instanceId
        phase = "prepared"
        createdAt = (Get-Date).ToString("o")
        sourceRuntime = $SourceRuntime
        sourceData = $SourceData
        targetRuntime = $TargetRuntime
        targetData = $TargetData
        managerPort = $ManagerPort
        cpaPort = $CpaPort
        pendingPath = $null
        oldHash = $result.oldHash
        newHash = $result.newHash
        collectorEnabled = [bool]$formalBaseline.collectorEnabled
        managerBaseline = [ordered]@{
            cpaBaseUrl = [string]$formalBaseline.cpaBaseUrl
            collectorEnabled = [bool]$formalBaseline.collectorEnabled
            pollIntervalMs = [int]$formalBaseline.pollIntervalMs
            usageStatisticsEnabled = [bool]$formalBaseline.usageStatisticsEnabled
        }
        sourceSnapshot = $null
        targetProcessId = $null
    }
    Write-CpaStackJson -Value $journal -Path $journalPath
    $collectorDisabled = $true
    [void](Set-CpaStackManagerCollector -ManagerPort $ManagerPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled $false -Baseline $formalBaseline)
    $journal.phase = "collector-disabled"
    Write-CpaStackJson -Value $journal -Path $journalPath

    Stop-CpaStackPort -Port $ManagerPort -ExpectedPath $sourceExe -ExpectedProcess $fixedSourceProcess -RequireExecutableWriteAccess:$sameRuntime
    $journal.phase = "source-stopped"
    Write-CpaStackJson -Value $journal -Path $journalPath

    try {
        if ($sameRuntime -and $sameData) {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $rollbackRoot
            Assert-CpaStackChildPath -Root $ControlRoot -Path $snapshotStaging
            Assert-CpaStackChildPath -Root $ControlRoot -Path $pending
            New-Item -ItemType Directory -Force -Path (Join-Path $snapshotStaging "runtime") | Out-Null
            Copy-CpaStackTree -Source $SourceRuntime -Destination (Join-Path $snapshotStaging "runtime") -ExcludeDirectoryNames @("data") -ExcludeFileNames @("server.log")
            $snapshotExe = Join-Path $snapshotStaging "runtime\cpa-manager-plus.exe"
            if ((Get-CpaStackFileHash -Path $snapshotExe) -ne $result.oldHash) {
                throw "Manager rollback executable snapshot hash validation failed."
            }
            $stagingBaselinePath = Join-Path $snapshotStaging "sqlite-backup.json"
            $baseline = Copy-ManagerDataSnapshot -FromData $SourceData -ToData (Join-Path $snapshotStaging "data") -MetadataPath $stagingBaselinePath
            $result.sourceSnapshot = $baseline.snapshot
            $journal.sourceSnapshot = $baseline.snapshot
            $expectHistorical = ([Int64]$baseline.snapshot.usage_events.count -gt 0)
            if ((Get-CpaStackFileHash -Path (Join-Path $snapshotStaging "data\data.key")) -ne $sourceDataKeyHash) {
                throw "Manager rollback data.key snapshot hash validation failed."
            }
            Write-CpaStackJson -Value ([ordered]@{
                operationId = $operationId
                capturedAt = (Get-Date).ToString("o")
                executableSha256 = $result.oldHash
                dataKeySha256 = $sourceDataKeyHash
                sourceRuntime = $SourceRuntime
                sourceData = $SourceData
            }) -Path (Join-Path $snapshotStaging "manifest.json")
            Protect-CpaStackPrivateTree -Root $snapshotStaging
            Move-Item -LiteralPath $snapshotStaging -Destination $pending -ErrorAction Stop
            $snapshotStaging = $null
            $baselinePath = Join-Path $pending "sqlite-backup.json"
            $backupComplete = $true
            $journal.pendingPath = $pending
            Write-CpaStackJson -Value $journal -Path $journalPath
            Copy-ManagerProgram -PackageRoot $CandidatePackageRoot -Runtime $TargetRuntime
        } else {
            $baselinePath = Join-Path $workVerification "sqlite-baseline.json"
            New-Item -ItemType Directory -Force -Path $workVerification | Out-Null
            $baseline = Copy-ManagerDataSnapshot -FromData $SourceData -ToData $TargetData -MetadataPath $baselinePath
            $result.sourceSnapshot = $baseline.snapshot
            $journal.sourceSnapshot = $baseline.snapshot
            Write-CpaStackJson -Value $journal -Path $journalPath
            $expectHistorical = ([Int64]$baseline.snapshot.usage_events.count -gt 0)
        }

        Protect-CpaStackPrivateDirectory -Path $TargetRuntime
        if ((Get-CpaStackFileHash -Path $targetExe) -ne $result.newHash) {
            throw "Manager target executable hash does not match the candidate."
        }
        Protect-CpaStackSecretFile -Path $targetExe
        Protect-CpaStackPrivateTree -Root $TargetData

        $targetProcess = Start-ManagerFormal -Exe $targetExe -Runtime $TargetRuntime -Data $TargetData
        $journal.targetProcessId = [int]$targetProcess.Id
        $journal.phase = 'target-started'
        Write-CpaStackJson -Value $journal -Path $journalPath
        $formal = Test-ManagerFormal -ExpectedExe $targetExe -ExpectedData $TargetData -ExpectedCollector $false -ExpectHistorical $expectHistorical -ExpectedProcessId $targetProcess.Id -ExpectedHash $result.newHash

        $verifyDir = Join-Path $workVerification "post-start"
        New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
        $after = Invoke-CpaStackSqliteBackup -Source $targetDb -Destination (Join-Path $verifyDir "usage.sqlite") -ResultPath (Join-Path $verifyDir "sqlite-after.json")
        Assert-HistoryPreserved -Before $baseline -After $after

        if ($RequireV111Schema) {
            $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
            & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Test-ManagerData.ps1") -DatabasePath $targetDb -BaselineJsonPath $baselinePath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Manager v1.11 data compatibility assertions failed."
            }
        }

        [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $targetExe -ExpectedProcessId $targetProcess.Id -ExpectedHash $result.newHash -AllowedAddresses $managerAllowedAddresses -Seconds 2)
        [void](Set-CpaStackManagerCollector -ManagerPort $ManagerPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$formalBaseline.collectorEnabled) -Baseline $formalBaseline)
        [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
        $collectorDisabled = $false
        $formal = Test-ManagerFormal -ExpectedExe $targetExe -ExpectedData $TargetData -ExpectedCollector ([bool]$formalBaseline.collectorEnabled) -ExpectHistorical $expectHistorical -ExpectedProcessId $targetProcess.Id -ExpectedHash $result.newHash
        $result.dataKeyPreserved = ((Get-CpaStackFileHash -Path (Join-Path $TargetData "data.key")) -eq $sourceDataKeyHash)
        if (-not $result.dataKeyPreserved) { throw "Manager formal data.key hash changed during the switch." }
        Assert-CpaStackPrivateTree -Root $TargetData -Description 'Manager data tree' -AllowInheritedDescendants
        $result.hasHistoricalData = [bool]$formal.info.hasHistoricalData
        $result.collectorEnabled = [bool]$formal.config.config.collector.enabled
        $result.activeHash = Get-CpaStackFileHash -Path $targetExe

        if ($sameRuntime -and $sameData -and $DeferFinalCommit) {
            $journal.phase = "runtime-verified"
            Write-CpaStackJson -Value $journal -Path $journalPath
            $result.commitDeferred = $true
        } elseif ($sameRuntime -and $sameData) {
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
                if ($null -ne $targetProcess) {
                    Stop-CpaStackStartedProcess -Process $targetProcess -ExpectedPath $targetExe
                    $targetProcess = $null
                }
                if ($null -ne $sourceProcess) {
                    Stop-CpaStackStartedProcess -Process $sourceProcess -ExpectedPath $sourceExe
                    $sourceProcess = $null
                }
                $recoveryListener = Get-CpaStackListener -Port $ManagerPort
                if ($recoveryListener) {
                    if (@($sourceExe, $targetExe) -inotcontains $recoveryListener.ExecutablePath) {
                        throw "Unexpected process owns Manager port $ManagerPort during recovery: $($recoveryListener.ExecutablePath)"
                    }
                    $recoveryProcess = Get-CpaStackFixedListenerProcess -Listener $recoveryListener -ExpectedPath $recoveryListener.ExecutablePath
                    try {
                        Stop-CpaStackPort -Port $ManagerPort -ExpectedPath $recoveryListener.ExecutablePath -ExpectedProcess $recoveryProcess -RequireExecutableWriteAccess:$sameRuntime
                    } finally {
                        if ($recoveryProcess -is [System.IDisposable]) { $recoveryProcess.Dispose() }
                    }
                }
                if ($sameRuntime -and $sameData -and $pending -and $backupComplete) {
                    foreach ($item in Get-ChildItem -Force -LiteralPath $SourceRuntime) {
                        if ($item.Name -eq "server.log") {
                            continue
                        }
                        Remove-Item -LiteralPath $item.FullName -Recurse -Force
                    }
                    Copy-CpaStackTree -Source (Join-Path $pending "runtime") -Destination $SourceRuntime -ExcludeFileNames @("server.log")
                    if (Test-Path -LiteralPath $SourceData) {
                        Remove-Item -LiteralPath $SourceData -Recurse -Force
                    }
                    Copy-Item -LiteralPath (Join-Path $pending "data") -Destination $SourceData -Recurse -Force
                    $rollbackManifest = Read-CpaStackJson -Path (Join-Path $pending 'manifest.json')
                    if ((Get-CpaStackFileHash -Path (Join-Path $SourceRuntime 'cpa-manager-plus.exe')) -ne [string]$rollbackManifest.executableSha256 -or
                        (Get-CpaStackFileHash -Path (Join-Path $SourceData 'data.key')) -ne [string]$rollbackManifest.dataKeySha256) {
                        throw 'Manager recovery copy did not reproduce the rollback executable and data.key hashes.'
                    }
                }
                $legacyVerification = Join-Path $workVerification ("r-$attempt")
                Assert-CpaStackChildPath -Root $ControlRoot -Path $legacyVerification
                $recoveryStateParameters = @{
                    Runtime = $SourceRuntime
                    Data = $SourceData
                    ExpectedExecutableSha256 = $result.oldHash
                    ExpectedDataKeySha256 = $sourceDataKeyHash
                    ExpectedSnapshot = $baseline
                    VerificationRoot = $legacyVerification
                }
                if ($sameRuntime -and $sameData) {
                    [void](Assert-CpaStackManagerRecoveryState @recoveryStateParameters)
                } else {
                    [void](Assert-CpaStackManagerRecoverySource @recoveryStateParameters)
                }
                Protect-CpaStackPrivateDirectory -Path $SourceRuntime
                Protect-CpaStackSecretFile -Path $sourceExe
                Protect-CpaStackPrivateTree -Root $SourceData
                if ((Get-CpaStackFileHash -Path $sourceExe) -ne $result.oldHash -or
                    (Get-CpaStackFileHash -Path $sourceDataKey) -ne $sourceDataKeyHash) {
                    throw 'Manager recovery source changed while its ACLs were being hardened.'
                }
                $protectedVerification = Join-Path $workVerification ("rp-$attempt")
                Assert-CpaStackChildPath -Root $ControlRoot -Path $protectedVerification
                $recoveryStateParameters.VerificationRoot = $protectedVerification
                if ($sameRuntime -and $sameData) {
                    [void](Assert-CpaStackManagerRecoveryState @recoveryStateParameters)
                } else {
                    [void](Assert-CpaStackManagerRecoverySource @recoveryStateParameters)
                }
                $sourceProcess = Start-ManagerFormal -Exe $sourceExe -Runtime $SourceRuntime -Data $SourceData
                [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $sourceExe -ExpectedProcessId $sourceProcess.Id -ExpectedHash $result.oldHash -AllowedAddresses $managerAllowedAddresses -Seconds 35)
                [void](Set-CpaStackManagerCollector -ManagerPort $ManagerPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$formalBaseline.collectorEnabled) -Baseline $formalBaseline)
                [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
                [void](Test-ManagerFormal -ExpectedExe $sourceExe -ExpectedData $SourceData -ExpectedCollector ([bool]$formalBaseline.collectorEnabled) -ExpectHistorical $expectHistorical -ExpectedProcessId $sourceProcess.Id -ExpectedHash $result.oldHash)
                Assert-CpaStackPrivateTree -Root $SourceData -Description 'Recovered Manager data tree' -AllowInheritedDescendants
                $collectorDisabled = $false
                $recovered = $true
            } catch {
                $recoveryError = $_.Exception.Message
                if ($null -ne $sourceProcess) {
                    try {
                        Stop-CpaStackStartedProcess -Process $sourceProcess -ExpectedPath $sourceExe
                        $sourceProcess = $null
                    } catch {
                        throw "Manager recovery refused another attempt because source process cleanup failed: $($_.Exception.Message)"
                    }
                }
                if ($null -ne $targetProcess) {
                    try {
                        Stop-CpaStackStartedProcess -Process $targetProcess -ExpectedPath $targetExe
                        $targetProcess = $null
                    } catch {
                        throw "Manager recovery refused another attempt because target process cleanup failed: $($_.Exception.Message)"
                    }
                }
                Start-Sleep -Seconds 1
            }
        }
        if (-not $recovered) {
            throw "Manager switch failed and automatic recovery also failed. Switch error: $switchError Recovery error: $recoveryError"
        }
        if ($sameRuntime -and $sameData -and $pending -and $backupComplete -and (Test-Path -LiteralPath $pending)) {
            $commit = Commit-CpaStackDirectorySlot -ControlRoot $ControlRoot -PendingPath $pending -DestinationPath $rollbackRoot
            $result.backupCleanupWarning = $commit.cleanupWarning
        }
        if (Test-Path -LiteralPath $journalPath) {
            try { Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop }
            catch { $result.journalCleanupWarning = $_.Exception.Message }
        }
        $result.rolledBack = $true
        $result.activeHash = Get-CpaStackFileHash -Path $sourceExe
        throw "Manager switch failed and the old service was restored: $switchError"
    }
} catch {
    $result.error = $_.Exception.Message
    if ($collectorDisabled) {
        try {
            $restoreListener = Get-CpaStackListener -Port $ManagerPort
            if (-not $restoreListener -or $restoreListener.ExecutablePath -ine $sourceExe) {
                throw "Manager collector restore requires the fully verified source Manager."
            }
            [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $sourceExe -ExpectedProcessId $restoreListener.ProcessId -ExpectedHash $result.oldHash -AllowedAddresses $managerAllowedAddresses -Seconds 2)
            [void](Set-CpaStackManagerCollector -ManagerPort $ManagerPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$formalBaseline.collectorEnabled) -Baseline $formalBaseline)
            [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
            $collectorDisabled = $false
        } catch {
            $result.error = $result.error + " Collector restore also failed: " + $_.Exception.Message
        }
    }
} finally {
    if ($null -ne $fixedSourceProcess -and $fixedSourceProcess -is [System.IDisposable]) {
        $fixedSourceProcess.Dispose()
    }
    Write-CpaStackJson -Value $result -Path $ResultPath
    if (Test-Path -LiteralPath $workVerification) {
        Remove-Item -LiteralPath $workVerification -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($snapshotStaging -and (Test-Path -LiteralPath $snapshotStaging)) {
        Remove-Item -LiteralPath $snapshotStaging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $result.success) {
    if ($InProcess) { throw $result.error }
    Write-Error $result.error
    exit 1
}

$result | ConvertTo-Json -Depth 10 -Compress
