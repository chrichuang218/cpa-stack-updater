[CmdletBinding()]
param(
    [string]$ControlRoot,
    [switch]$AllowUnknownVersionReplacement
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")

$ControlRoot = Resolve-CpaStackControlRoot -RequestedRoot $ControlRoot
$ControlRoot = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
Assert-CpaStackFreeSpace -Path $ControlRoot -MinimumBytes 1073741824

$stateDir = Join-Path $ControlRoot "state"
$workRoot = Join-Path $ControlRoot "work\current"
$packageRoot = Join-Path $workRoot "packages"
$testRoot = Join-Path $workRoot "tests"
$releaseCurrent = Join-Path $ControlRoot "releases\current"
$resultPath = Join-Path $stateDir "last-upgrade.json"
$currentStatePath = Join-Path $stateDir "current.json"
$upgradeJournalPath = Join-Path $stateDir "upgrade.pending.json"
$result = [ordered]@{
    operation = "upgrade-canonical-stack"
    success = $false
    canonicalRoot = $ControlRoot
    cpa = $null
    manager = $null
    cpaCandidate = $null
    managerCandidate = $null
    releases = $null
    recoveredInterruptedState = $false
    launcherUpdated = $false
    journalCleanupWarning = $null
    cleanupWarning = $null
    error = $null
}
$operationMutex = $null
$upgradeJournal = $null
$instanceMarker = $null

function Invoke-ChildPowerShellJson {
    param([string]$Script, [string[]]$Arguments, [switch]$AllowNonZero)

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne 0 -and -not $AllowNonZero) {
        throw "Child script failed: $Script. $text"
    }
    return $text | ConvertFrom-Json
}

function ConvertTo-InProcessParameters {
    param([string[]]$Arguments)

    $parameters = @{}
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $token = [string]$Arguments[$index]
        if (-not $token.StartsWith('-') -or $token.Length -lt 2) { throw "Invalid bundled script argument token: $token" }
        $name = $token.Substring(1)
        $value = $true
        if ($index + 1 -lt $Arguments.Count -and -not ([string]$Arguments[$index + 1]).StartsWith('-')) {
            $index++
            $value = $Arguments[$index]
        }
        $parameters[$name] = $value
    }
    return $parameters
}

function Invoke-InProcessPowerShellJson {
    param([string]$Script, [string[]]$Arguments, [hashtable]$AdditionalParameters = @{})

    $parameters = ConvertTo-InProcessParameters -Arguments $Arguments
    $parameters['InProcess'] = $true
    foreach ($name in $AdditionalParameters.Keys) { $parameters[$name] = $AdditionalParameters[$name] }
    try {
        $output = @(& $Script @parameters)
    } catch {
        throw "In-process bundled script failed: $Script. $($_.Exception.Message)"
    }
    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { throw "In-process bundled script returned no JSON: $Script" }
    return $text | ConvertFrom-Json
}

function Invoke-SwitchScript {
    param([string]$Script, [string[]]$Arguments)
    [void](Invoke-InProcessPowerShellJson -Script $Script -Arguments $Arguments)
}

function Assert-TrustedCanonicalManagerListener {
    param([string]$ManagerRuntime)

    $stackState = Get-CpaStackConfig -ControlRoot $ControlRoot
    $currentState = Read-CpaStackJson -Path $currentStatePath
    $port = [int]$stackState.Manager.Port
    $exe = Join-Path $ManagerRuntime 'cpa-manager-plus.exe'
    $listener = Get-CpaStackListener -Port $port
    if (-not $listener -or $listener.ExecutablePath -ine $exe) {
        throw 'Canonical Manager listener is not owned by the recorded executable.'
    }
    [void](Wait-CpaStackTrustedListener -Port $port -ExpectedPath $exe -ExpectedProcessId $listener.ProcessId -ExpectedHash ([string]$currentState.manager.sha256) -AllowedAddresses @([string]$stackState.Manager.BindAddress) -Seconds 2)
    return [pscustomobject]@{ Listener = $listener; Stack = $stackState; Port = $port; Exe = $exe; Hash = [string]$currentState.manager.sha256 }
}
function Repair-CpaStackRecordedExecutableAcl {
    param(
        $CurrentState,
        $Stack,
        [string]$CpaRuntime,
        [string]$ManagerRuntime
    )

    $cpaExe = Join-Path $CpaRuntime 'cli-proxy-api.exe'
    $managerExe = Join-Path $ManagerRuntime 'cpa-manager-plus.exe'
    $cpaConfig = Join-Path $ControlRoot ([string]$Stack.Cpa.Config)
    $cpaHost = Get-CpaStackConfigHost -ConfigPath $cpaConfig
    foreach ($entry in @(
        [pscustomobject]@{
            Name = 'CPA'
            Port = [int]$Stack.Cpa.Port
            Exe = $cpaExe
            Hash = [string]$CurrentState.cpa.sha256
            AllowedAddresses = @($cpaHost)
        },
        [pscustomobject]@{
            Name = 'Manager'
            Port = [int]$Stack.Manager.Port
            Exe = $managerExe
            Hash = [string]$CurrentState.manager.sha256
            AllowedAddresses = @([string]$Stack.Manager.BindAddress)
        }
    )) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $entry.Exe
        Assert-CpaStackPath -Path $entry.Exe -PathType Leaf
        if ($entry.Hash -notmatch '^[0-9A-Fa-f]{64}$' -or (Get-CpaStackFileHash -Path $entry.Exe) -ne $entry.Hash.ToUpperInvariant()) {
            throw "$($entry.Name) executable ACL cannot be repaired because its recorded hash is not active."
        }
        $listener = Get-CpaStackListener -Port $entry.Port
        if (-not $listener -or $listener.ExecutablePath -ine $entry.Exe) {
            throw "$($entry.Name) executable ACL cannot be repaired because the formal listener owner is not trusted."
        }
        [void](Wait-CpaStackTrustedListener `
            -Port $entry.Port `
            -ExpectedPath $entry.Exe `
            -ExpectedProcessId $listener.ProcessId `
            -ExpectedHash $entry.Hash `
            -AllowedAddresses $entry.AllowedAddresses `
            -Seconds 2)
        Protect-CpaStackSecretFile -Path $entry.Exe
    }
}

function Prepare-CpaCandidateRuntime {
    param([string]$ReleasePackageRoot, [string]$ActiveRuntime)

    $destination = Join-Path $testRoot "cpa-runtime"
    if (Test-Path -LiteralPath $destination) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $destination
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Copy-CpaStackTree -Source $ReleasePackageRoot -Destination $destination

    $auth = Join-Path $destination "auth"
    if (Test-Path -LiteralPath $auth) { Remove-Item -LiteralPath $auth -Recurse -Force }
    Copy-CpaStackAuthTree -Source (Join-Path $ActiveRuntime "auth") -Destination $auth
    $plugins = Join-Path $ActiveRuntime "plugins"
    $candidatePlugins = Join-Path $destination "plugins"
    if (Test-Path -LiteralPath $plugins) {
        if (Test-Path -LiteralPath $candidatePlugins) { Remove-Item -LiteralPath $candidatePlugins -Recurse -Force }
        Copy-CpaStackPluginTree -Source $plugins -Destination $candidatePlugins
    } elseif (Test-Path -LiteralPath $candidatePlugins) {
        Protect-CpaStackPrivateTree -Root $candidatePlugins
    }
    Copy-Item -LiteralPath (Join-Path $ActiveRuntime "config.yaml") -Destination (Join-Path $destination "config.yaml") -Force
    return $destination
}

function Set-UpgradeJournalPhase {
    param([string]$Phase)
    if ($null -eq $script:upgradeJournal) { return }
    $script:upgradeJournal.phase = $Phase
    $script:upgradeJournal.updatedAt = (Get-Date).ToString("o")
    Write-CpaStackJson -Value $script:upgradeJournal -Path $upgradeJournalPath
}

function Remove-UpgradeJournal {
    foreach ($path in @($upgradeJournalPath, ($upgradeJournalPath + ".previous"))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Stop-UpgradeTemporaryListeners {
    param($Journal)

    foreach ($entry in @(
        [pscustomobject]@{ Port = 8318; Expected = [string]$Journal.cpaCandidateExe; Name = "CPA" },
        [pscustomobject]@{ Port = 18318; Expected = [string]$Journal.managerCandidateExe; Name = "Manager" }
    )) {
        $listener = Get-CpaStackListener -Port $entry.Port
        if (-not $listener) { continue }
        if (-not $entry.Expected) { throw "$($entry.Name) temporary port $($entry.Port) is occupied without a recorded candidate path." }
        Assert-CpaStackChildPath -Root $ControlRoot -Path $entry.Expected
        if ($listener.ExecutablePath -ine $entry.Expected) {
            throw "Unexpected process owns $($entry.Name) temporary port $($entry.Port): $($listener.ExecutablePath)"
        }
        Stop-CpaStackPort -Port $entry.Port -ExpectedPath $entry.Expected -RequireExecutableWriteAccess
    }
}

function Assert-UpgradeTemporaryPortsFree {
    foreach ($port in @(8318, 18318)) {
        $listener = Get-CpaStackListener -Port $port
        if ($listener) { throw "Temporary validation port $port is already owned by $($listener.ExecutablePath)." }
    }
}

function Assert-SwitchedServicesHealthy {
    param([ValidateSet('cpa', 'manager')][string]$PendingSwitchComponent)

    $state = Invoke-ChildPowerShellJson -Script (Join-Path $PSScriptRoot 'Get-CpaStackState.ps1') -Arguments @(
        '-ControlRoot', $ControlRoot,
        '-PendingSwitchComponent', $PendingSwitchComponent
    ) -AllowNonZero
    if (-not $state.Cpa.Healthy -or -not $state.Manager.Healthy) {
        throw 'A switched component did not preserve the health of both formal services.'
    }
}

function Remove-UpgradeTemporaryWork {
    Assert-UpgradeTemporaryPortsFree
    $workBase = Join-Path $ControlRoot "work"
    if (-not (Test-Path -LiteralPath $workBase -PathType Container)) { return }
    foreach ($directory in Get-ChildItem -Force -LiteralPath $workBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(cpa-8318|manager-18318|manager-formal-verification)-[0-9a-fA-F]{32}$' }) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $directory.FullName
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Remove-OrphanedRollbackStaging {
    $rollbackRoot = Join-Path $ControlRoot "rollback"
    if (-not (Test-Path -LiteralPath $rollbackRoot -PathType Container)) { return }
    foreach ($directory in Get-ChildItem -Force -LiteralPath $rollbackRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^staging-(cpa|manager)-[0-9a-fA-F]{32}$' }) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $directory.FullName
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Clear-SensitiveUpgradeWork {
    $candidateRuntime = Join-Path $testRoot "cpa-runtime"
    if (Test-Path -LiteralPath $candidateRuntime) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $candidateRuntime
        Remove-Item -LiteralPath $candidateRuntime -Recurse -Force -ErrorAction Stop
    }
    Remove-UpgradeTemporaryWork
}

function Ensure-CanonicalServicesForPreparationRecovery {
    param([string]$CpaRuntime, [string]$ManagerRuntime)

    $expectedCpa = Join-Path $CpaRuntime "cli-proxy-api.exe"
    $expectedManager = Join-Path $ManagerRuntime "cpa-manager-plus.exe"
    $cpaListener = Get-CpaStackListener -Port 8317
    $managerListener = Get-CpaStackListener -Port 18317
    if ($cpaListener -and $cpaListener.ExecutablePath -ine $expectedCpa) { throw "Unexpected process owns 8317 during candidate recovery." }
    if ($managerListener -and $managerListener.ExecutablePath -ine $expectedManager) { throw "Unexpected process owns 18317 during candidate recovery." }
    if ($cpaListener -and $managerListener) { return }
    $startResult = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Start-CPA-Stack.ps1") -Arguments @("-NoBrowser", "-ConfigPath", (Join-Path $ControlRoot 'config\stack.psd1')) -AdditionalParameters @{ OperationLockHandle = $operationMutex; RecoveryMode = $true }
    if (-not $startResult.Success) { throw "Canonical stack could not be started for candidate recovery: $($startResult.Error.Message)" }
}

function Read-ValidatedUpgradeJournal {
    if (-not (Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf)) { return $null }
    $journal = Read-CpaStackJson -Path $upgradeJournalPath
    if ([string]$journal.operation -ne "upgrade-candidates") { throw "Unexpected upgrade journal operation." }
    if ($null -eq $instanceMarker -or [string]$journal.instanceId -ne [string]$instanceMarker.instanceId) {
        throw "Upgrade journal belongs to a different CPA stack instance."
    }
    if ([System.IO.Path]::GetFullPath([string]$journal.canonicalRoot).TrimEnd('\') -ine [System.IO.Path]::GetFullPath($ControlRoot).TrimEnd('\')) {
        throw "Upgrade journal belongs to a different canonical root."
    }
    foreach ($field in @("cpaBaseUrl", "collectorEnabled", "pollIntervalMs", "usageStatisticsEnabled")) {
        if ($null -eq $journal.managerBaseline -or $null -eq $journal.managerBaseline.PSObject.Properties[$field]) {
            throw "Upgrade journal is missing Manager baseline field $field."
        }
    }
    foreach ($property in @("cpaCandidateExe", "managerCandidateExe")) {
        $path = [string]$journal.$property
        if (-not $path) { continue }
        Assert-CpaStackChildPath -Root $ControlRoot -Path $path
        $workBase = [System.IO.Path]::GetFullPath((Join-Path $ControlRoot "work")).TrimEnd('\')
        $full = [System.IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($workBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Upgrade journal candidate path is outside the work tree: $path"
        }
    }
    return $journal
}

function Recover-UpgradePreparationState {
    param([string]$CpaRuntime, [string]$ManagerRuntime)

    $journal = Read-ValidatedUpgradeJournal
    if ($null -eq $journal) { return $false }
    Stop-UpgradeTemporaryListeners -Journal $journal
    Ensure-CanonicalServicesForPreparationRecovery -CpaRuntime $CpaRuntime -ManagerRuntime $ManagerRuntime
    $trustedManager = Assert-TrustedCanonicalManagerListener -ManagerRuntime $ManagerRuntime
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $baseline = $journal.managerBaseline
    [void](Set-CpaStackManagerCollector -ManagerPort $trustedManager.Port -CpaPort ([int]$trustedManager.Stack.Cpa.Port) -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$baseline.collectorEnabled) -Baseline $baseline)
    [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $trustedManager.Port -ManagerAdminKey $secrets.managerAdminKey -Expected $baseline)
    [void](Wait-CpaStackTrustedListener -Port $trustedManager.Port -ExpectedPath $trustedManager.Exe -ExpectedProcessId $trustedManager.Listener.ProcessId -ExpectedHash $trustedManager.Hash -AllowedAddresses @([string]$trustedManager.Stack.Manager.BindAddress) -Seconds 2)
    Clear-SensitiveUpgradeWork
    Remove-OrphanedRollbackStaging
    Remove-UpgradeJournal
    return $true
}

function Convert-TagVersion {
    param([string]$Tag)
    $value = $Tag.TrimStart('v', 'V')
    try { return [version]$value } catch { return [version]'0.0.0' }
}

function Set-CurrentComponentState {
    param(
        [ValidateSet("cpa", "manager")][string]$Component,
        $Package,
        [string]$Runtime,
        [string]$ConfigPath = "",
        [string]$DataPath = ""
    )

    $state = Read-CpaStackJson -Path $currentStatePath
    $componentState = if ($Component -eq "cpa") {
        [pscustomobject][ordered]@{
            version = $Package.tag
            executable = Join-Path $Runtime "cli-proxy-api.exe"
            sha256 = Get-CpaStackFileHash -Path (Join-Path $Runtime "cli-proxy-api.exe")
            config = $ConfigPath
            releaseUrl = $Package.releaseUrl
            archiveSha256 = $Package.archiveSha256
        }
    } else {
        [pscustomobject][ordered]@{
            version = $Package.tag
            executable = Join-Path $Runtime "cpa-manager-plus.exe"
            sha256 = Get-CpaStackFileHash -Path (Join-Path $Runtime "cpa-manager-plus.exe")
            data = $DataPath
            releaseUrl = $Package.releaseUrl
            archiveSha256 = $Package.archiveSha256
        }
    }
    $state | Add-Member -NotePropertyName $Component -NotePropertyValue $componentState -Force
    $state | Add-Member -NotePropertyName upgradedAt -NotePropertyValue (Get-Date).ToString("o") -Force
    Write-CpaStackJson -Value $state -Path $currentStatePath
}

function Assert-UpgradeSwitchPathBudget {
    $zeroId = '0' * 32
    $managerVerification = Join-Path $ControlRoot ('work\mv-' + $zeroId)
    $cpaStaging = Join-Path $ControlRoot ('rollback\staging-cpa-' + $zeroId)
    $cpaPending = Join-Path $ControlRoot ('rollback\pending-cpa-' + $zeroId)
    $managerStaging = Join-Path $ControlRoot ('rollback\staging-manager-' + $zeroId)
    $managerPending = Join-Path $ControlRoot ('rollback\pending-manager-' + $zeroId)
    $cpaRollback = Join-Path $ControlRoot 'rollback\last-known-good\cpa'
    $managerRollback = Join-Path $ControlRoot 'rollback\last-known-good\manager-plus'

    Assert-CpaStackPathBudget -Paths @(
        $cpaRuntime, $managerRuntime, $managerData,
        $cpaStaging, (Join-Path $cpaStaging 'runtime'), $cpaPending,
        $managerStaging, (Join-Path $managerStaging 'runtime'), (Join-Path $managerStaging 'data'), $managerPending,
        $managerVerification, (Join-Path $managerVerification 'post-start'), (Join-Path $managerVerification 'r-3'), (Join-Path $managerVerification 'rp-3'),
        $cpaRollback, ($cpaRollback + '.previous-' + $zeroId),
        $managerRollback, ($managerRollback + '.previous-' + $zeroId),
        $releaseCurrent
    ) -PathType Container

    if ($cpaNeedsUpgrade) {
        Assert-CpaStackProjectedTreePathBudget -Source $cpaRuntime -Destination (Join-Path $cpaStaging 'runtime') -ExcludeDirectoryNames @('auth', 'plugins') -ExcludeFileNames @('config.yaml', 'server.log')
        Assert-CpaStackProjectedTreePathBudget -Source $cpaCandidateRuntime -Destination $cpaRuntime -ExcludeDirectoryNames @('auth', 'plugins') -ExcludeFileNames @('config.yaml')
    }
    if ($managerNeedsUpgrade) {
        Assert-CpaStackProjectedTreePathBudget -Source $managerRuntime -Destination (Join-Path $managerStaging 'runtime') -ExcludeDirectoryNames @('data') -ExcludeFileNames @('server.log')
        Assert-CpaStackProjectedTreePathBudget -Source $managerPackage.packageRoot -Destination $managerRuntime -ExcludeDirectoryNames @('data') -ExcludeFileNames @('config.json', 'server.log')
        Assert-CpaStackPathBudget -Paths @(
            (Join-Path $managerStaging 'data\usage.sqlite'),
            (Join-Path $managerStaging 'data\usage.sqlite-wal'),
            (Join-Path $managerStaging 'data\usage.sqlite-shm'),
            (Join-Path $managerStaging 'data\data.key'),
            (Join-Path $managerVerification 'usage.sqlite'),
            (Join-Path $managerVerification 'post-start\usage.sqlite')
        ) -PathType Leaf
    }
    if (Test-Path -LiteralPath $packageRoot -PathType Container) {
        Assert-CpaStackProjectedTreePathBudget -Source $packageRoot -Destination $releaseCurrent
    }
    Assert-CpaStackJsonWritePathBudget -Paths @(
        $upgradeJournalPath,
        $currentStatePath,
        $resultPath,
        (Join-Path $stateDir 'switch-cpa.pending.json'),
        (Join-Path $stateDir 'switch-manager.pending.json'),
        (Join-Path $stateDir 'cpa-upgrade-switch.json'),
        (Join-Path $stateDir 'manager-upgrade-switch.json'),
        (Join-Path $managerVerification 'sqlite-baseline.json'),
        (Join-Path $managerVerification 'post-start\sqlite-after.json')
    )
}

function Restore-CanonicalInterruptedState {
    param(
        [string]$CpaRuntime,
        [string]$ManagerRuntime,
        [string]$ManagerData,
        $Preflight
    )

    $stateRoot = Join-Path $ControlRoot "state"
    $rollbackRoot = Join-Path $ControlRoot "rollback"
    $cpaJournalPath = Join-Path $stateRoot "switch-cpa.pending.json"
    $managerJournalPath = Join-Path $stateRoot "switch-manager.pending.json"

    function Quarantine-PendingPath {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
        $rollbackFull = [System.IO.Path]::GetFullPath($rollbackRoot).TrimEnd('\')
        $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        if ((Split-Path -Parent $pathFull).TrimEnd('\') -ine $rollbackFull -or (Split-Path -Leaf $pathFull) -notmatch '^pending-(cpa|manager)-[0-9a-fA-F]{32}$') {
            throw "Refusing to quarantine a path outside an exact rollback pending slot: $Path"
        }
        Assert-CpaStackChildPath -Root $ControlRoot -Path $Path
        $destination = Join-Path $rollbackRoot ("orphaned-" + (Split-Path -Leaf $Path) + "-" + [guid]::NewGuid().ToString("N"))
        Move-Item -LiteralPath $Path -Destination $destination -ErrorAction Stop
    }

    function Read-ValidatedPending {
        param([string]$JournalPath, [string]$ExpectedOperation)
        if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $null }
        $journal = Read-CpaStackJson -Path $JournalPath
        if ([string]$journal.operation -ne $ExpectedOperation) { throw "Unexpected recovery journal operation in $JournalPath" }
        if ($null -eq $instanceMarker -or [string]$journal.instanceId -ne [string]$instanceMarker.instanceId) {
            throw "Switch recovery journal belongs to a different CPA stack instance."
        }
        $operationId = [string]$journal.operationId
        if ($operationId -notmatch '^[0-9a-fA-F]{32}$') { throw "Recovery journal operationId is invalid in $JournalPath" }
        if ($ExpectedOperation -eq "switch-manager") {
            foreach ($field in @("cpaBaseUrl", "collectorEnabled", "pollIntervalMs", "usageStatisticsEnabled")) {
                if ($null -eq $journal.managerBaseline -or $null -eq $journal.managerBaseline.PSObject.Properties[$field]) {
                    throw "Manager recovery journal is missing baseline field $field."
                }
            }
        }
        $pendingPath = [string]$journal.pendingPath
        $component = if ($ExpectedOperation -eq "switch-cpa") { "cpa" } else { "manager" }
        $destinationPath = if ($component -eq 'cpa') { Join-Path $rollbackRoot 'last-known-good\cpa' } else { Join-Path $rollbackRoot 'last-known-good\manager-plus' }
        if (-not $pendingPath) {
            return [pscustomobject]@{ Journal = $journal; Backup = $null; BackupLocation = 'none'; DestinationPath = $destinationPath; ValidationError = $null }
        }
        $expectedLeaf = "pending-$component-$operationId"
        $rollbackFull = [System.IO.Path]::GetFullPath($rollbackRoot).TrimEnd('\')
        $pendingFull = [System.IO.Path]::GetFullPath($pendingPath).TrimEnd('\')
        if ((Split-Path -Parent $pendingFull).TrimEnd('\') -ine $rollbackFull -or (Split-Path -Leaf $pendingFull) -ine $expectedLeaf -or $pendingFull -ine (Join-Path $rollbackFull $expectedLeaf)) {
            throw "Recovery journal pendingPath is not the exact expected rollback slot: $pendingPath"
        }
        $backupPath = $null
        $backupLocation = 'none'
        if (Test-Path -LiteralPath $pendingPath -PathType Container) {
            $backupPath = $pendingPath
            $backupLocation = 'pending'
        } elseif (Test-Path -LiteralPath (Join-Path $destinationPath 'manifest.json') -PathType Leaf) {
            $destinationManifest = Read-CpaStackJson -Path (Join-Path $destinationPath 'manifest.json')
            if ([string]$destinationManifest.operationId -eq $operationId) {
                $backupPath = $destinationPath
                $backupLocation = 'destination'
            }
        }
        if (-not $backupPath) {
            return [pscustomobject]@{ Journal = $journal; Backup = $null; BackupLocation = 'none'; DestinationPath = $destinationPath; ValidationError = $null }
        }
        try {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $backupPath
            Assert-CpaStackPath -Path $backupPath
            $manifest = Read-CpaStackJson -Path (Join-Path $backupPath "manifest.json")
            if ([string]$manifest.operationId -ne [string]$journal.operationId) { throw "Pending operationId does not match its journal." }
            if ($ExpectedOperation -eq "switch-cpa") {
                $exe = Join-Path $backupPath "runtime\cli-proxy-api.exe"
                if ((Get-CpaStackFileHash -Path $exe) -ne [string]$manifest.executableSha256 -or [string]$manifest.executableSha256 -ne [string]$journal.oldHash) {
                    throw "CPA pending executable hash validation failed."
                }
            } else {
                $exe = Join-Path $backupPath "runtime\cpa-manager-plus.exe"
                $dataKey = Join-Path $backupPath "data\data.key"
                if ((Get-CpaStackFileHash -Path $exe) -ne [string]$manifest.executableSha256 -or [string]$manifest.executableSha256 -ne [string]$journal.oldHash) { throw "Manager pending executable hash validation failed." }
                if ((Get-CpaStackFileHash -Path $dataKey) -ne [string]$manifest.dataKeySha256) { throw "Manager pending data.key hash validation failed." }
                $backupResult = Read-CpaStackJson -Path (Join-Path $backupPath "sqlite-backup.json")
                if (-not $backupResult.success) { throw "Manager pending SQLite backup did not complete successfully." }
            }
            return [pscustomobject]@{
                Journal = $journal
                Backup = Get-Item -LiteralPath $backupPath
                BackupLocation = $backupLocation
                DestinationPath = $destinationPath
                ManagerSnapshot = if ($ExpectedOperation -eq 'switch-manager') { $backupResult } else { $null }
                ValidationError = $null
            }
        } catch {
            if ($backupLocation -eq 'pending') { Quarantine-PendingPath -Path $pendingPath }
            return [pscustomobject]@{ Journal = $journal; Backup = $null; BackupLocation = 'none'; DestinationPath = $destinationPath; ValidationError = $_.Exception.Message }
        }
    }

    try {
        $cpaRecovery = Read-ValidatedPending -JournalPath $cpaJournalPath -ExpectedOperation "switch-cpa"
        $managerRecovery = Read-ValidatedPending -JournalPath $managerJournalPath -ExpectedOperation "switch-manager"
    } catch {
        if (Test-Path -LiteralPath $cpaJournalPath -PathType Leaf) {
            [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath (Join-Path $CpaRuntime 'cli-proxy-api.exe'))
        }
        if (Test-Path -LiteralPath $managerJournalPath -PathType Leaf) {
            [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath (Join-Path $ManagerRuntime 'cpa-manager-plus.exe'))
        }
        throw
    }
    $referencedPending = @()
    if ($cpaRecovery -and $cpaRecovery.BackupLocation -eq 'pending') { $referencedPending += $cpaRecovery.Backup.FullName }
    if ($managerRecovery -and $managerRecovery.BackupLocation -eq 'pending') { $referencedPending += $managerRecovery.Backup.FullName }

    foreach ($orphan in Get-ChildItem -Force -LiteralPath $rollbackRoot -Directory -Filter "pending-*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^pending-(cpa|manager)-[0-9a-fA-F]{32}$' }) {
        if ($referencedPending -notcontains $orphan.FullName) { Quarantine-PendingPath -Path $orphan.FullName }
    }

    if (-not $cpaRecovery -and -not $managerRecovery -and $Preflight.Cpa.Healthy -and $Preflight.Manager.Healthy) {
        return
    }

    $recordedState = Read-CpaStackJson -Path $currentStatePath
    function Get-RecoveryDisposition {
        param($Recovery, [ValidateSet('cpa', 'manager')][string]$Component, [string]$Runtime)
        if (-not $Recovery) { return 'none' }
        $componentState = $recordedState.PSObject.Properties[$Component]
        if ($null -eq $componentState -or $null -eq $componentState.Value.PSObject.Properties['sha256']) {
            throw "Current state is missing the recorded $Component hash required for recovery."
        }
        $exeName = if ($Component -eq 'cpa') { 'cli-proxy-api.exe' } else { 'cpa-manager-plus.exe' }
        $activeHash = Get-CpaStackFileHash -Path (Join-Path $Runtime $exeName)
        if (-not $activeHash) { throw "$Component runtime executable is missing during recovery." }
        return Resolve-CpaStackSwitchDisposition `
            -RecordedHash ([string]$componentState.Value.sha256) `
            -ActiveHash $activeHash `
            -OldHash ([string]$Recovery.Journal.oldHash) `
            -NewHash ([string]$Recovery.Journal.newHash)
    }

    $cpaDisposition = Get-RecoveryDisposition -Recovery $cpaRecovery -Component cpa -Runtime $CpaRuntime
    $managerDisposition = Get-RecoveryDisposition -Recovery $managerRecovery -Component manager -Runtime $ManagerRuntime
    foreach ($recovery in @($cpaRecovery, $managerRecovery)) {
        if ($recovery -and -not [string]::IsNullOrWhiteSpace([string]$recovery.ValidationError)) {
            throw "A switch recovery backup failed validation: $($recovery.ValidationError)"
        }
    }

    if ($cpaRecovery) {
        if ($cpaRecovery.Backup) {
            Assert-CpaStackProjectedTreePathBudget -Source (Join-Path $cpaRecovery.Backup.FullName 'runtime') -Destination $CpaRuntime
        }
        [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath (Join-Path $CpaRuntime 'cli-proxy-api.exe'))
    }
    if ($managerRecovery) {
        if ($managerRecovery.Backup) {
            Assert-CpaStackProjectedTreePathBudget -Source (Join-Path $managerRecovery.Backup.FullName 'runtime') -Destination $ManagerRuntime
            Assert-CpaStackProjectedTreePathBudget -Source (Join-Path $managerRecovery.Backup.FullName 'data') -Destination $ManagerData
        }
        [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath (Join-Path $ManagerRuntime 'cpa-manager-plus.exe'))
    }

    if ($managerRecovery -and $managerDisposition -eq 'restore-old') {
        if (-not $managerRecovery.Backup -and (Get-CpaStackFileHash -Path (Join-Path $ManagerRuntime 'cpa-manager-plus.exe')) -ne [string]$managerRecovery.Journal.oldHash) {
            throw "Manager must be rolled back, but its validated backup is unavailable. $($managerRecovery.ValidationError)"
        }
        if ($managerRecovery.Backup) {
            $listener = Get-CpaStackListener -Port 18317
            $expectedExe = Join-Path $ManagerRuntime "cpa-manager-plus.exe"
            if ($listener -and $listener.ExecutablePath -ine $expectedExe) { throw "Unexpected process owns 18317 during recovery." }
            if ($listener) {
                $listenerProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $expectedExe
                try { Stop-CpaStackPort -Port 18317 -ExpectedPath $expectedExe -ExpectedProcess $listenerProcess -RequireExecutableWriteAccess }
                finally { if ($listenerProcess -is [System.IDisposable]) { $listenerProcess.Dispose() } }
            }
            $pendingManager = $managerRecovery.Backup
            if (Test-Path -LiteralPath $ManagerRuntime -PathType Container) {
                foreach ($item in Get-ChildItem -Force -LiteralPath $ManagerRuntime) {
                    if ($item.Name -eq "server.log") { continue }
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force
                }
            }
            Copy-CpaStackTree -Source (Join-Path $pendingManager.FullName "runtime") -Destination $ManagerRuntime -ExcludeFileNames @("server.log")
            if (Test-Path -LiteralPath $ManagerData) { Remove-Item -LiteralPath $ManagerData -Recurse -Force }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ManagerData) | Out-Null
            Copy-Item -LiteralPath (Join-Path $pendingManager.FullName "data") -Destination $ManagerData -Recurse -Force
            $managerManifest = Read-CpaStackJson -Path (Join-Path $pendingManager.FullName 'manifest.json')
            if ((Get-CpaStackFileHash -Path (Join-Path $ManagerRuntime 'cpa-manager-plus.exe')) -ne [string]$managerRecovery.Journal.oldHash -or
                (Get-CpaStackFileHash -Path (Join-Path $ManagerData 'data.key')) -ne [string]$managerManifest.dataKeySha256) {
                throw 'Manager rollback copy did not reproduce the validated executable and data.key hashes.'
            }
            if ($null -eq $managerRecovery.ManagerSnapshot) {
                throw 'Manager rollback backup is missing its business-data baseline.'
            }
            $verificationRoot = Join-Path $ControlRoot ('work\mv-' + [guid]::NewGuid().ToString('N'))
            Assert-CpaStackChildPath -Root $ControlRoot -Path $verificationRoot
            try {
                [void](Assert-CpaStackManagerRecoveryState `
                    -Runtime $ManagerRuntime `
                    -Data $ManagerData `
                    -ExpectedExecutableSha256 ([string]$managerRecovery.Journal.oldHash) `
                    -ExpectedDataKeySha256 ([string]$managerManifest.dataKeySha256) `
                    -ExpectedSnapshot $managerRecovery.ManagerSnapshot `
                    -VerificationRoot $verificationRoot)
            } finally {
                if (Test-Path -LiteralPath $verificationRoot) {
                    Remove-Item -LiteralPath $verificationRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if ($cpaRecovery -and $cpaDisposition -eq 'restore-old') {
        if (-not $cpaRecovery.Backup -and (Get-CpaStackFileHash -Path (Join-Path $CpaRuntime 'cli-proxy-api.exe')) -ne [string]$cpaRecovery.Journal.oldHash) {
            throw "CPA must be rolled back, but its validated backup is unavailable. $($cpaRecovery.ValidationError)"
        }
        if ($cpaRecovery.Backup) {
            $listener = Get-CpaStackListener -Port 8317
            $expectedExe = Join-Path $CpaRuntime "cli-proxy-api.exe"
            if ($listener -and $listener.ExecutablePath -ine $expectedExe) { throw "Unexpected process owns 8317 during recovery." }
            if ($listener) {
                $listenerProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $expectedExe
                try { Stop-CpaStackPort -Port 8317 -ExpectedPath $expectedExe -ExpectedProcess $listenerProcess -RequireExecutableWriteAccess }
                finally { if ($listenerProcess -is [System.IDisposable]) { $listenerProcess.Dispose() } }
            }
            $pendingCpa = $cpaRecovery.Backup
            if (Test-Path -LiteralPath $CpaRuntime -PathType Container) {
                foreach ($item in Get-ChildItem -Force -LiteralPath $CpaRuntime) {
                    if ($item.Name -in @("config.yaml", "auth", "plugins")) { continue }
                    Remove-Item -LiteralPath $item.FullName -Recurse -Force
                }
            }
            Copy-CpaStackTree -Source (Join-Path $pendingCpa.FullName "runtime") -Destination $CpaRuntime
            if ((Get-CpaStackFileHash -Path (Join-Path $CpaRuntime 'cli-proxy-api.exe')) -ne [string]$cpaRecovery.Journal.oldHash) {
                throw 'CPA rollback copy did not reproduce the validated executable hash.'
            }
        }
    }

    if ($cpaRecovery) {
        Protect-CpaStackPrivateDirectory -Path $CpaRuntime
        Protect-CpaStackSecretFile -Path (Join-Path $CpaRuntime 'cli-proxy-api.exe')
        Protect-CpaStackSecretFile -Path ([string]$cpaRecovery.Journal.sourceConfig)
        Protect-CpaStackPrivateTree -Root (Join-Path $CpaRuntime 'auth')
        $recoveryPlugins = Join-Path $CpaRuntime 'plugins'
        if (Test-Path -LiteralPath $recoveryPlugins) { Protect-CpaStackPrivateTree -Root $recoveryPlugins }
    }

    $recoveryPlugins = Join-Path $CpaRuntime 'plugins'
    if (Test-Path -LiteralPath $recoveryPlugins) {
        Assert-CpaStackPrivateTree -Root $recoveryPlugins -Description 'Preserved CPA plugins'
    }

    $startScript = Join-Path $PSScriptRoot "Start-CPA-Stack.ps1"
    $started = $false
    $startError = $null
    for ($attempt = 1; $attempt -le 3 -and -not $started; $attempt++) {
        try {
            $startResult = Invoke-InProcessPowerShellJson -Script $startScript -Arguments @("-NoBrowser", "-ConfigPath", (Join-Path $ControlRoot 'config\stack.psd1')) -AdditionalParameters @{ OperationLockHandle = $operationMutex; RecoveryMode = $true }
            if (-not $startResult.Success) { throw $startResult.Error.Message }
            $started = $true
        } catch {
            $startError = $_.Exception.Message
            Start-Sleep -Seconds 1
        }
    }
    if (-not $started) { throw "Canonical interrupted recovery could not restart the stack: $startError" }

    if ($managerRecovery -and $managerRecovery.Journal.managerBaseline) {
        $trustedManager = Assert-TrustedCanonicalManagerListener -ManagerRuntime $ManagerRuntime
        $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
        $baseline = $managerRecovery.Journal.managerBaseline
        [void](Set-CpaStackManagerCollector -ManagerPort $trustedManager.Port -CpaPort ([int]$trustedManager.Stack.Cpa.Port) -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$baseline.collectorEnabled) -Baseline $baseline)
        [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $trustedManager.Port -ManagerAdminKey $secrets.managerAdminKey -Expected $baseline)
        [void](Wait-CpaStackTrustedListener -Port $trustedManager.Port -ExpectedPath $trustedManager.Exe -ExpectedProcessId $trustedManager.Listener.ProcessId -ExpectedHash $trustedManager.Hash -AllowedAddresses @([string]$trustedManager.Stack.Manager.BindAddress) -Seconds 2)
    }

    $recoveredState = Invoke-ChildPowerShellJson -Script (Join-Path $PSScriptRoot "Get-CpaStackState.ps1") -Arguments @("-ControlRoot", $ControlRoot) -AllowNonZero
    if (-not $recoveredState.Cpa.Healthy -or -not $recoveredState.Manager.Healthy -or -not $recoveredState.Security.Integrity.Ready) {
        throw "Canonical services restarted but did not pass recovery health checks."
    }
    foreach ($recovery in @(
        [pscustomobject]@{ Value = $cpaRecovery; Component = "cpa" },
        [pscustomobject]@{ Value = $managerRecovery; Component = "manager" }
    )) {
        if ($recovery.Value -and [string]$recovery.Value.Journal.operationId -match '^[0-9a-fA-F]{32}$') {
            $staging = Join-Path $rollbackRoot ("staging-$($recovery.Component)-" + [string]$recovery.Value.Journal.operationId)
            if (Test-Path -LiteralPath $staging -PathType Container) {
                Assert-CpaStackChildPath -Root $ControlRoot -Path $staging
                Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
            }
        }
    }
    foreach ($entry in @(
        [pscustomobject]@{ Recovery = $cpaRecovery; Disposition = $cpaDisposition; JournalPath = $cpaJournalPath },
        [pscustomobject]@{ Recovery = $managerRecovery; Disposition = $managerDisposition; JournalPath = $managerJournalPath }
    )) {
        if (-not $entry.Recovery) { continue }
        if ($entry.Disposition -eq 'commit-new' -and -not $entry.Recovery.Backup) {
            throw "A committed runtime has no validated last-known-good backup. $($entry.Recovery.ValidationError)"
        }
        if ($entry.Recovery.BackupLocation -eq 'pending' -and (Test-Path -LiteralPath $entry.Recovery.Backup.FullName)) {
            [void](Commit-CpaStackDirectorySlot -ControlRoot $ControlRoot -PendingPath $entry.Recovery.Backup.FullName -DestinationPath $entry.Recovery.DestinationPath)
        }
        foreach ($path in @($entry.JournalPath, ($entry.JournalPath + '.previous'))) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
    }
}

try {
    $operationMutex = Enter-CpaStackOperationLock
    Assert-CpaStackPath -Path $ControlRoot
    Protect-CpaStackPrivateDirectory -Path $ControlRoot
    $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
    Assert-CpaStackPath -Path $currentStatePath -PathType Leaf
    $identityState = Read-CpaStackJson -Path $currentStatePath
    if ($null -eq $identityState.PSObject.Properties['instanceId'] -or [string]::IsNullOrWhiteSpace([string]$identityState.instanceId)) {
        $pendingIdentityState = @(Get-ChildItem -LiteralPath $stateDir -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
        if ($pendingIdentityState.Count -gt 0) {
            throw 'Current state has no instanceId and cannot be adopted while a transaction is pending.'
        }
        $identityState | Add-Member -NotePropertyName instanceId -NotePropertyValue ([string]$instanceMarker.instanceId) -Force
        Write-CpaStackJson -Value $identityState -Path $currentStatePath
    } elseif ([string]$identityState.instanceId -ne [string]$instanceMarker.instanceId) {
        throw 'Current state belongs to a different CPA stack instance.'
    }
    $stack = Get-CpaStackConfig -ControlRoot $ControlRoot
    $cpaRuntime = Join-Path $ControlRoot ([string]$stack.Cpa.WorkingDirectory)
    $cpaConfig = Join-Path $ControlRoot ([string]$stack.Cpa.Config)
    $managerRuntime = Join-Path $ControlRoot ([string]$stack.Manager.WorkingDirectory)
    $managerData = Join-Path $ControlRoot ([string]$stack.Manager.DataDirectory)
    foreach ($path in @($cpaRuntime, $cpaConfig, $managerRuntime, $managerData)) { Assert-CpaStackChildPath -Root $ControlRoot -Path $path }
    Assert-CpaStackPath -Path (Join-Path $ControlRoot "ops\Start-CPA-Stack.ps1") -PathType Leaf
    $activePlugins = Join-Path $cpaRuntime 'plugins'
    if (Test-Path -LiteralPath $activePlugins) {
        Assert-CpaStackPrivateTree -Root $activePlugins -Description 'Canonical CPA plugins'
    }

    if (Test-Path -LiteralPath (Join-Path $stateDir "initialize.pending.json") -PathType Leaf) {
        throw "Initialization recovery must be finalized with Initialize-CpaStack.ps1 before upgrading."
    }

    $pendingStateFiles = @(Get-ChildItem -LiteralPath $stateDir -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
    if ($pendingStateFiles.Count -eq 0) {
        Repair-CpaStackRecordedExecutableAcl -CurrentState $identityState -Stack $stack -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime
    }
    $preflight = Invoke-ChildPowerShellJson -Script (Join-Path $PSScriptRoot "Get-CpaStackState.ps1") -Arguments @("-ControlRoot", $ControlRoot) -AllowNonZero
    $hasSwitchJournal = (Test-Path -LiteralPath (Join-Path $stateDir "switch-cpa.pending.json") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $stateDir "switch-manager.pending.json") -PathType Leaf)
    $hasUpgradeJournal = Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf
    if ($hasSwitchJournal) {
        Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $preflight
        if ($hasUpgradeJournal) { [void](Recover-UpgradePreparationState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime) }
        $result.recoveredInterruptedState = $true
        throw "Interrupted CPA stack state was recovered. Rerun the upgrade to start a fresh transaction."
    }
    if ($hasUpgradeJournal) {
        [void](Recover-UpgradePreparationState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime)
        $result.recoveredInterruptedState = $true
        throw "Interrupted candidate validation state was recovered. Rerun the upgrade to start a fresh transaction."
    }
    if ($preflight.InterruptedState) {
        Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $preflight
        $result.recoveredInterruptedState = $true
        throw "Interrupted CPA stack state was recovered. Rerun the upgrade to start a fresh transaction."
    }
    if (-not $preflight.OverallHealthy -or $preflight.CanonicalEstablished -eq $false) {
        throw "Canonical preflight is not healthy."
    }
    $launcherSync = Sync-CpaStackCanonicalLauncher -ControlRoot $ControlRoot -SourcePath (Join-Path $PSScriptRoot 'Start-CPA-Stack.ps1')
    $result.launcherUpdated = [bool]$launcherSync.changed
    foreach ($path in @($cpaRuntime, $managerRuntime, $managerData)) { Assert-CpaStackPath -Path $path }
    foreach ($path in @($cpaConfig, (Join-Path $cpaRuntime "cli-proxy-api.exe"), (Join-Path $managerRuntime "cpa-manager-plus.exe"))) { Assert-CpaStackPath -Path $path -PathType Leaf }
    Assert-UpgradeTemporaryPortsFree
    Remove-UpgradeTemporaryWork
    Remove-OrphanedRollbackStaging

    Assert-CpaStackChildPath -Root $ControlRoot -Path $workRoot
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $packageRoot, $testRoot, $stateDir | Out-Null

    $cpaRelease = Get-CpaStackLatestRelease -Repository "router-for-me/CLIProxyAPI" -AssetPattern '^CLIProxyAPI_[0-9.]+_windows_amd64\.zip$'
    $managerRelease = Get-CpaStackLatestRelease -Repository "seakee/CPA-Manager-Plus" -AssetPattern '^cpa-manager-plus_v[0-9.]+_windows_amd64\.zip$'
    $cpaPackage = Save-CpaStackRelease -Release $cpaRelease -Destination (Join-Path $packageRoot "cpa")
    $managerPackage = Save-CpaStackRelease -Release $managerRelease -Destination (Join-Path $packageRoot "manager-plus")
    $managerVersion = Convert-TagVersion -Tag $managerPackage.tag
    if ($managerVersion -lt [version]'1.11.1') {
        throw "Manager Plus versions below v1.11.1 are blocked on Windows because v1.11.0 contains the known SQLite file URI defect."
    }
    $result.releases = [ordered]@{ cpa = $cpaPackage; manager = $managerPackage }

    $recordedState = Read-CpaStackJson -Path $currentStatePath
    $recordedCpaTag = [string]$recordedState.cpa.version
    $recordedManagerTag = [string]$recordedState.manager.version
    $recordedCpaComparable = ($recordedCpaTag -match '^[vV]?\d+\.\d+\.\d+(?:\.\d+)?$')
    $recordedManagerComparable = ($recordedManagerTag -match '^[vV]?\d+\.\d+\.\d+(?:\.\d+)?$')
    if ($recordedCpaComparable) {
        $recordedCpaVersion = Convert-TagVersion -Tag ([string]$recordedState.cpa.version)
        $latestCpaVersion = Convert-TagVersion -Tag ([string]$cpaPackage.tag)
        if ($latestCpaVersion -lt $recordedCpaVersion) {
            throw "Refusing to downgrade CPA from $recordedCpaVersion to $latestCpaVersion."
        }
    }
    if ($recordedManagerComparable) {
        $recordedManagerVersion = Convert-TagVersion -Tag ([string]$recordedState.manager.version)
        if ($managerVersion -lt $recordedManagerVersion) {
            throw "Refusing to downgrade Manager Plus from $recordedManagerVersion to $managerVersion."
        }
    }

    $currentCpaHash = Get-CpaStackFileHash -Path (Join-Path $cpaRuntime "cli-proxy-api.exe")
    $currentManagerHash = Get-CpaStackFileHash -Path (Join-Path $managerRuntime "cpa-manager-plus.exe")
    $cpaNeedsUpgrade = ($currentCpaHash -ne $cpaPackage.executableSha256)
    $managerNeedsUpgrade = ($currentManagerHash -ne $managerPackage.executableSha256)
    if (-not $AllowUnknownVersionReplacement) {
        $unknownComponents = @()
        if ($cpaNeedsUpgrade -and -not $recordedCpaComparable) { $unknownComponents += 'CPA' }
        if ($managerNeedsUpgrade -and -not $recordedManagerComparable) { $unknownComponents += 'Manager Plus' }
        if ($cpaNeedsUpgrade -and $recordedCpaComparable -and (Convert-TagVersion -Tag $recordedCpaTag) -eq (Convert-TagVersion -Tag ([string]$cpaPackage.tag))) {
            $unknownComponents += 'CPA (same-version hash mismatch)'
        }
        if ($managerNeedsUpgrade -and $recordedManagerComparable -and (Convert-TagVersion -Tag $recordedManagerTag) -eq $managerVersion) {
            $unknownComponents += 'Manager Plus (same-version hash mismatch)'
        }
        if ($unknownComponents.Count -gt 0) {
            throw "Cannot prove a monotonic official upgrade for $($unknownComponents -join ', ') because the installed version or binary provenance is ambiguous. Rerun only after review with -AllowUnknownVersionReplacement."
        }
    }
    if ($cpaNeedsUpgrade -or $managerNeedsUpgrade) {
        $managerFormalPort = [int]$stack.Manager.Port
        $managerFormalExe = Join-Path $managerRuntime 'cpa-manager-plus.exe'
        $managerFormalListener = Get-CpaStackListener -Port $managerFormalPort
        if (-not $managerFormalListener -or $managerFormalListener.ExecutablePath -ine $managerFormalExe) {
            throw 'Manager formal port is not owned by the recorded canonical executable.'
        }
        [void](Wait-CpaStackTrustedListener -Port $managerFormalPort -ExpectedPath $managerFormalExe -ExpectedProcessId $managerFormalListener.ProcessId -ExpectedHash $currentManagerHash -AllowedAddresses @([string]$stack.Manager.BindAddress) -Seconds 2)
        $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
        $formalBaseline = Get-CpaStackManagerSetupBaseline -ManagerPort $managerFormalPort -ManagerAdminKey $secrets.managerAdminKey
        [void](Wait-CpaStackTrustedListener -Port $managerFormalPort -ExpectedPath $managerFormalExe -ExpectedProcessId $managerFormalListener.ProcessId -ExpectedHash $currentManagerHash -AllowedAddresses @([string]$stack.Manager.BindAddress) -Seconds 2)
        $upgradeJournal = [pscustomobject][ordered]@{
            schemaVersion = 1
            operation = "upgrade-candidates"
            instanceId = [string]$instanceMarker.instanceId
            phase = "prepared"
            canonicalRoot = $ControlRoot
            cpaCandidateExe = $null
            managerCandidateExe = $null
            managerBaseline = [pscustomobject][ordered]@{
                cpaBaseUrl = [string]$formalBaseline.cpaBaseUrl
                collectorEnabled = [bool]$formalBaseline.collectorEnabled
                pollIntervalMs = [int]$formalBaseline.pollIntervalMs
                usageStatisticsEnabled = [bool]$formalBaseline.usageStatisticsEnabled
            }
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
        }
        Write-CpaStackJson -Value $upgradeJournal -Path $upgradeJournalPath
    }

    if (-not $cpaNeedsUpgrade) {
        $result.cpa = [ordered]@{ success = $true; skipped = $true; reason = "already-latest"; activeHash = $currentCpaHash }
    } else {
        $cpaCandidateRuntime = Prepare-CpaCandidateRuntime -ReleasePackageRoot $cpaPackage.packageRoot -ActiveRuntime $cpaRuntime
        $upgradeJournal.cpaCandidateExe = Join-Path $cpaCandidateRuntime "cli-proxy-api.exe"
        Set-UpgradeJournalPhase -Phase "testing-cpa"
        $result.cpaCandidate = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Test-CpaCandidate.ps1") -Arguments @(
            "-ControlRoot", $ControlRoot,
            "-CandidateRuntime", $cpaCandidateRuntime,
            "-ActiveConfig", (Join-Path $cpaCandidateRuntime "config.yaml"),
            "-ActiveRuntime", $cpaRuntime,
            "-ExpectedCandidateHash", ([string]$cpaPackage.executableSha256),
            "-ResultPath", (Join-Path $stateDir "cpa-8318-upgrade-test.json")
        )
    }

    if (-not $managerNeedsUpgrade) {
        $result.manager = [ordered]@{ success = $true; skipped = $true; reason = "already-latest"; activeHash = $currentManagerHash }
    } else {
        $requireV111 = $managerVersion -ge [version]'1.11.1'
        $upgradeJournal.managerCandidateExe = Join-Path $managerPackage.packageRoot "cpa-manager-plus.exe"
        Set-UpgradeJournalPhase -Phase "testing-manager"
        $managerTestArguments = @(
            "-ControlRoot", $ControlRoot,
            "-CandidateRuntime", $managerPackage.packageRoot,
            "-FormalRuntime", $managerRuntime,
            "-FormalData", $managerData,
            "-ExpectedCandidateHash", ([string]$managerPackage.executableSha256),
            "-ResultPath", (Join-Path $stateDir "manager-18318-upgrade-test.json")
        )
        if ($requireV111) { $managerTestArguments += "-RequireV111Schema" }
        $result.managerCandidate = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Test-ManagerCandidate.ps1") -Arguments $managerTestArguments
    }

    Assert-UpgradeSwitchPathBudget

    if ($cpaNeedsUpgrade) {
        $cpaSwitchPath = Join-Path $stateDir "cpa-upgrade-switch.json"
        Set-UpgradeJournalPhase -Phase "switching-cpa"
        Invoke-SwitchScript -Script (Join-Path $PSScriptRoot "Switch-CpaRuntime.ps1") -Arguments @(
            "-ControlRoot", $ControlRoot,
            "-SourceRuntime", $cpaRuntime,
            "-TargetRuntime", $cpaRuntime,
            "-CandidatePackageRoot", $cpaCandidateRuntime,
            "-SourceConfig", $cpaConfig,
            "-ExpectedCandidateHash", ([string]$cpaPackage.executableSha256),
            "-ResultPath", $cpaSwitchPath,
            "-DeferFinalCommit"
        )
        $result.cpa = Read-CpaStackJson -Path $cpaSwitchPath
        Assert-SwitchedServicesHealthy -PendingSwitchComponent cpa
    }
    Set-CurrentComponentState -Component cpa -Package $cpaPackage -Runtime $cpaRuntime -ConfigPath $cpaConfig
    if ($cpaNeedsUpgrade) {
        Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $preflight
    }

    if ($managerNeedsUpgrade) {
        $managerSwitchPath = Join-Path $stateDir "manager-upgrade-switch.json"
        $managerSwitchArguments = @(
            "-ControlRoot", $ControlRoot,
            "-SourceRuntime", $managerRuntime,
            "-SourceData", $managerData,
            "-TargetRuntime", $managerRuntime,
            "-TargetData", $managerData,
            "-CandidatePackageRoot", $managerPackage.packageRoot,
            "-ExpectedCandidateHash", ([string]$managerPackage.executableSha256),
            "-ResultPath", $managerSwitchPath,
            "-DeferFinalCommit"
        )
        if ($requireV111) { $managerSwitchArguments += "-RequireV111Schema" }
        Set-UpgradeJournalPhase -Phase "switching-manager"
        Invoke-SwitchScript -Script (Join-Path $PSScriptRoot "Switch-ManagerRuntime.ps1") -Arguments $managerSwitchArguments
        $result.manager = Read-CpaStackJson -Path $managerSwitchPath
        Assert-SwitchedServicesHealthy -PendingSwitchComponent manager
    }
    Set-CurrentComponentState -Component manager -Package $managerPackage -Runtime $managerRuntime -DataPath $managerData
    if ($managerNeedsUpgrade) {
        Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $preflight
    }

    if (-not $result.cpa.success -or -not $result.manager.success) {
        throw "One or more components did not complete successfully."
    }
    Set-UpgradeJournalPhase -Phase "committing"
    $result.success = $true
    Set-CpaStackRegisteredRoot -ControlRoot $ControlRoot
    try {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $releaseCurrent
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $releaseCurrent) | Out-Null
        if (Test-Path -LiteralPath $releaseCurrent) {
            Remove-Item -LiteralPath $releaseCurrent -Recurse -Force
        }
        Move-Item -LiteralPath $packageRoot -Destination $releaseCurrent
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force
        }
    } catch {
        $result.cleanupWarning = $_.Exception.Message
    }
    try {
        Remove-UpgradeJournal
    } catch {
        $result.journalCleanupWarning = $_.Exception.Message
    }
} catch {
    $result.error = $_.Exception.Message
    $switchJournalPresent = (Test-Path -LiteralPath (Join-Path $stateDir "switch-cpa.pending.json") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $stateDir "switch-manager.pending.json") -PathType Leaf)
    if ($switchJournalPresent) {
        try {
            $failedState = Invoke-ChildPowerShellJson -Script (Join-Path $PSScriptRoot 'Get-CpaStackState.ps1') -Arguments @('-ControlRoot', $ControlRoot) -AllowNonZero
            Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $failedState
            if (Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf) {
                [void](Recover-UpgradePreparationState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime)
            }
            $result.recoveredInterruptedState = $true
        } catch {
            $result.error += " Immediate switch recovery failed: " + $_.Exception.Message
        }
    } else {
        try {
            if (Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf) {
                [void](Recover-UpgradePreparationState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime)
            } else {
                Clear-SensitiveUpgradeWork
            }
        } catch {
            $result.error += " Sensitive/recovery cleanup failed: " + $_.Exception.Message
        }
    }
} finally {
    if (Test-Path -LiteralPath $stateDir) {
        Write-CpaStackJson -Value $result -Path $resultPath
    }
    Exit-CpaStackOperationLock -Mutex $operationMutex
}

$result | ConvertTo-Json -Depth 14 -Compress
if (-not $result.success) {
    Write-Error $result.error
    exit 1
}
