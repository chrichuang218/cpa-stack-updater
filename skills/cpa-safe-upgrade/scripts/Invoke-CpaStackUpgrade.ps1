[CmdletBinding()]
param(
    [string]$ControlRoot,
    [switch]$AllowUnknownVersionReplacement,
    [switch]$RecoverOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")

$ControlRoot = Resolve-CpaStackControlRoot -RequestedRoot $ControlRoot
$ControlRoot = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
if (-not $RecoverOnly) {
    Assert-CpaStackFreeSpace -Path $ControlRoot -MinimumBytes 1073741824
}

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
$candidatePortPlan = $null
$suppressResultPersistence = $false

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

function Remove-CommittedOrphanSwitchPrevious {
    param($CurrentState)

    function Assert-OrphanPathEquals {
        param([string]$Actual, [string]$Expected, [string]$Description)

        if ([string]::IsNullOrWhiteSpace($Actual) -or [string]::IsNullOrWhiteSpace($Expected)) {
            throw "$Description is missing."
        }
        $actualFull = [System.IO.Path]::GetFullPath($Actual).TrimEnd('\')
        $expectedFull = [System.IO.Path]::GetFullPath($Expected).TrimEnd('\')
        if (-not [string]::Equals($actualFull, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$Description does not match the canonical path."
        }
    }

    $removed = $false
    $rollbackRoot = Join-Path $ControlRoot 'rollback'
    foreach ($component in @('cpa', 'manager')) {
        $journalPath = Join-Path $stateDir "switch-$component.pending.json"
        $previousPath = $journalPath + '.previous'
        if ((Test-Path -LiteralPath $journalPath -PathType Leaf) -or -not (Test-Path -LiteralPath $previousPath -PathType Leaf)) {
            continue
        }

        Assert-CpaStackPath -Path $previousPath -PathType Leaf
        $beforeHash = Get-CpaStackFileHash -Path $previousPath
        $journal = Read-CpaStackJson -Path $previousPath
        $expectedOperation = "switch-$component"
        foreach ($field in @('operation', 'operationId', 'parentOperationId', 'instanceId', 'oldHash', 'newHash', 'targetRuntime')) {
            if ($null -eq $journal.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$journal.$field)) {
                throw "Orphan $expectedOperation previous journal is missing $field."
            }
        }
        if ([string]$journal.operation -cne $expectedOperation -or [string]$journal.instanceId -cne [string]$CurrentState.instanceId) {
            throw "Orphan $expectedOperation previous journal is not bound to the current stack instance."
        }

        $componentState = $CurrentState.$component
        $runtime = if ($component -eq 'cpa') { $cpaRuntime } else { $managerRuntime }
        $exeName = if ($component -eq 'cpa') { 'cli-proxy-api.exe' } else { 'cpa-manager-plus.exe' }
        $exe = Join-Path $runtime $exeName
        Assert-OrphanPathEquals -Actual ([string]$journal.targetRuntime) -Expected $runtime -Description "$component orphan previous targetRuntime"
        if ([string]$componentState.sha256 -ine [string]$journal.newHash -or
            (Get-CpaStackFileHash -Path $exe) -ine [string]$journal.newHash) {
            throw "Orphan $expectedOperation previous journal does not describe the committed executable."
        }

        $pendingPath = Join-Path $rollbackRoot ("pending-$component-" + [string]$journal.operationId)
        if (Test-Path -LiteralPath $pendingPath) {
            throw "Orphan $expectedOperation previous journal still has a rollback pending directory."
        }

        $matchingResult = $null
        foreach ($name in @("$component-migration-switch.json", "$component-upgrade-switch.json")) {
            $path = Join-Path $stateDir $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            Assert-CpaStackPath -Path $path -PathType Leaf
            $candidate = Read-CpaStackJson -Path $path
            if ([bool]$candidate.success -and
                [string]$candidate.operation -ceq $expectedOperation -and
                [string]$candidate.operationId -ceq [string]$journal.operationId -and
                [string]$candidate.parentOperationId -ceq [string]$journal.parentOperationId -and
                [string]$candidate.newHash -ieq [string]$journal.newHash -and
                -not [bool]$candidate.rolledBack) {
                $matchingResult = $candidate
                break
            }
        }
        if ($null -eq $matchingResult) {
            throw "Orphan $expectedOperation previous journal has no matching successful switch result."
        }
        Assert-OrphanPathEquals -Actual ([string]$matchingResult.targetPath) -Expected $exe -Description "$component orphan previous switch result targetPath"
        if ((Get-CpaStackFileHash -Path $previousPath) -ine $beforeHash) {
            throw "Orphan $expectedOperation previous journal changed while it was being validated."
        }
        Remove-Item -LiteralPath $previousPath -Force -ErrorAction Stop
        $removed = $true
    }
    return $removed
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

function Read-StableUpgradeJournalFile {
    param([string]$Path, [string]$Description)

    Assert-CpaStackPath -Path $Path -PathType Leaf
    $beforeHash = Get-CpaStackFileHash -Path $Path
    $value = Read-CpaStackJson -Path $Path
    $afterHash = Get-CpaStackFileHash -Path $Path
    if ($beforeHash -notmatch '^[0-9A-Fa-f]{64}$' -or $beforeHash -ine $afterHash) {
        throw "$Description changed while it was being validated."
    }
    return [pscustomobject]@{
        Value = $value
        Descriptor = [pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($Path)
            Exists = $true
            Sha256 = $afterHash.ToUpperInvariant()
        }
    }
}

function Assert-UpgradeJournalFileDescriptor {
    param($Descriptor, [string]$Description)

    if ($null -eq $Descriptor) { throw "$Description descriptor is missing." }
    $exists = Test-Path -LiteralPath ([string]$Descriptor.Path) -PathType Leaf
    if (-not [bool]$Descriptor.Exists) {
        if ($exists -or (Test-Path -LiteralPath ([string]$Descriptor.Path))) {
            throw "$Description appeared after validation."
        }
        return
    }
    if (-not $exists) { throw "$Description disappeared after validation." }
    if ((Get-CpaStackFileHash -Path ([string]$Descriptor.Path)) -ine [string]$Descriptor.Sha256) {
        throw "$Description changed after validation."
    }
}

function Assert-ValidatedUpgradeJournalDescriptors {
    param($Validated)

    if ($null -eq $Validated) { throw 'Validated upgrade journal state is missing.' }
    Assert-UpgradeJournalFileDescriptor -Descriptor $Validated.JournalDescriptor -Description 'Current upgrade journal'
    Assert-UpgradeJournalFileDescriptor -Descriptor $Validated.PreviousJournalDescriptor -Description 'Previous upgrade journal'
}

function Remove-UpgradeJournal {
    $validated = Read-ValidatedUpgradeJournal
    if ($null -eq $validated) { return }
    Assert-ValidatedUpgradeJournalDescriptors -Validated $validated
    if ([bool]$validated.PreviousJournalDescriptor.Exists) {
        Remove-Item -LiteralPath ([string]$validated.PreviousJournalDescriptor.Path) -Force -ErrorAction Stop
    }
    Assert-UpgradeJournalFileDescriptor -Descriptor $validated.JournalDescriptor -Description 'Current upgrade journal'
    Remove-Item -LiteralPath ([string]$validated.JournalDescriptor.Path) -Force -ErrorAction Stop
}

function Stop-UpgradeTemporaryListeners {
    param($Journal)

    $hasRecordedPorts = $null -ne $Journal.PSObject.Properties['cpaCandidatePort'] -and
        $null -ne $Journal.PSObject.Properties['managerCandidatePort']
    if (-not $hasRecordedPorts) {
        foreach ($expected in @([string]$Journal.cpaCandidateExe, [string]$Journal.managerCandidateExe)) {
            if (-not $expected) { continue }
            Assert-CpaStackChildPath -Root $ControlRoot -Path $expected
            [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath $expected)
        }
        return
    }

    foreach ($entry in @(
        [pscustomobject]@{ Port = [int]$Journal.cpaCandidatePort; Expected = [string]$Journal.cpaCandidateExe; Name = "CPA" },
        [pscustomobject]@{ Port = [int]$Journal.managerCandidatePort; Expected = [string]$Journal.managerCandidateExe; Name = "Manager" }
    )) {
        if (-not $entry.Expected) { continue }
        Assert-CpaStackChildPath -Root $ControlRoot -Path $entry.Expected
        $listener = Get-CpaStackListener -Port $entry.Port
        if ($listener) {
            if ($listener.ExecutablePath -ine $entry.Expected) {
                throw "Unexpected process owns $($entry.Name) temporary port $($entry.Port): $($listener.ExecutablePath)"
            }
            Stop-CpaStackPort -Port $entry.Port -ExpectedPath $entry.Expected -RequireExecutableWriteAccess
        }
        # A hard-killed validator can leave its fixed executable running before it binds.
        [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath $entry.Expected)
    }
}

function Assert-UpgradeTemporaryPortsFree {
    param($Journal)

    if ($null -eq $Journal) { return }
    if ($null -eq $Journal.PSObject.Properties['cpaCandidatePort'] -or
        $null -eq $Journal.PSObject.Properties['managerCandidatePort']) { return }
    foreach ($port in @([int]$Journal.cpaCandidatePort, [int]$Journal.managerCandidatePort)) {
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
    param($Journal)

    Assert-UpgradeTemporaryPortsFree -Journal $Journal
    $workBase = Join-Path $ControlRoot "work"
    if (-not (Test-Path -LiteralPath $workBase -PathType Container)) { return }
    foreach ($directory in Get-ChildItem -Force -LiteralPath $workBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(cpa-(?:candidate|\d{1,5})|manager-(?:candidate|\d{1,5})|manager-formal-verification)-[0-9a-fA-F]{32}$' }) {
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
    param($Journal)

    $candidateRuntime = Join-Path $testRoot "cpa-runtime"
    if (Test-Path -LiteralPath $candidateRuntime) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $candidateRuntime
        Remove-Item -LiteralPath $candidateRuntime -Recurse -Force -ErrorAction Stop
    }
    Remove-UpgradeTemporaryWork -Journal $Journal
}

function Ensure-CanonicalServicesForPreparationRecovery {
    param([string]$CpaRuntime, [string]$ManagerRuntime)

    $stack = Get-CpaStackConfig -ControlRoot $ControlRoot
    $cpaPort = [int]$stack.Cpa.Port
    $managerPort = [int]$stack.Manager.Port
    $expectedCpa = Join-Path $CpaRuntime "cli-proxy-api.exe"
    $expectedManager = Join-Path $ManagerRuntime "cpa-manager-plus.exe"
    $cpaListener = Get-CpaStackListener -Port $cpaPort
    $managerListener = Get-CpaStackListener -Port $managerPort
    if ($cpaListener -and $cpaListener.ExecutablePath -ine $expectedCpa) { throw "Unexpected process owns CPA formal port $cpaPort during candidate recovery." }
    if ($managerListener -and $managerListener.ExecutablePath -ine $expectedManager) { throw "Unexpected process owns Manager formal port $managerPort during candidate recovery." }
    if ($cpaListener -and $managerListener) { return }
    $startResult = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Start-CPA-Stack.ps1") -Arguments @("-NoBrowser", "-ConfigPath", (Join-Path $ControlRoot 'config\stack.psd1')) -AdditionalParameters @{ OperationLockHandle = $operationMutex; RecoveryMode = $true }
    if (-not $startResult.Success) { throw "Canonical stack could not be started for candidate recovery: $($startResult.Error.Message)" }
}

function Read-ValidatedUpgradeJournal {
    $previousPath = $upgradeJournalPath + '.previous'
    if (-not (Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $previousPath) {
            throw 'An orphan upgrade journal previous generation requires manual recovery.'
        }
        return $null
    }
    $stableCurrent = Read-StableUpgradeJournalFile -Path $upgradeJournalPath -Description 'Current upgrade journal'
    $journal = $stableCurrent.Value
    if ([string]$journal.operation -ne "upgrade-candidates") { throw "Unexpected upgrade journal operation." }
    $journalSchemaVersion = [int]$journal.schemaVersion
    if ($journalSchemaVersion -notin @(1, 2, 3)) { throw "Unsupported upgrade journal schema version." }
    if ($journalSchemaVersion -eq 3 -and [string]$journal.operationId -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'Upgrade journal operationId is invalid.'
    }
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
    $phase = [string]$journal.phase
    $allowedPhases = @('prepared', 'testing-cpa', 'testing-manager', 'switching-cpa', 'switching-manager', 'committing')
    if ($phase -cnotin $allowedPhases) { throw "Upgrade journal phase is invalid: $phase" }
    if ($journalSchemaVersion -ge 2) {
        $stack = Get-CpaStackConfig -ControlRoot $ControlRoot
        $formalPorts = @([int]$stack.Cpa.Port, [int]$stack.Manager.Port)
        $protectedPorts = @(Get-CpaStackCandidateProtectedPorts -FormalPort $formalPorts)
        $candidatePorts = @()
        foreach ($property in @('cpaCandidatePort', 'managerCandidatePort')) {
            if ($null -eq $journal.PSObject.Properties[$property]) {
                throw "Upgrade journal is missing candidate port field $property."
            }
            $port = [int]$journal.$property
            if ($port -lt 49152 -or $port -gt 65535 -or $port -in $protectedPorts) {
                throw "Upgrade journal candidate port is unsafe: $property=$port"
            }
            $candidatePorts += $port
        }
        if (@($candidatePorts | Sort-Object -Unique).Count -ne $candidatePorts.Count) {
            throw 'Upgrade journal candidate ports must be distinct.'
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

    $previousDescriptor = [pscustomobject]@{
        Path = [System.IO.Path]::GetFullPath($previousPath)
        Exists = $false
        Sha256 = $null
    }
    if (Test-Path -LiteralPath $previousPath -PathType Leaf) {
        $stablePrevious = Read-StableUpgradeJournalFile -Path $previousPath -Description 'Previous upgrade journal'
        $previous = $stablePrevious.Value
        $previousDescriptor = $stablePrevious.Descriptor
        foreach ($field in @('schemaVersion', 'operation', 'instanceId', 'canonicalRoot', 'createdAt')) {
            $currentProperty = $journal.PSObject.Properties[$field]
            $previousProperty = $previous.PSObject.Properties[$field]
            if ($null -eq $currentProperty -or $null -eq $previousProperty -or
                [string]$currentProperty.Value -cne [string]$previousProperty.Value) {
                throw "Previous upgrade journal immutable field '$field' does not match the current transaction."
            }
        }
        if ($journalSchemaVersion -eq 3) {
            if ([string]$previous.operationId -notmatch '^[0-9a-fA-F]{32}$' -or
                [string]$previous.operationId -cne [string]$journal.operationId) {
                throw 'Previous upgrade journal belongs to a different operationId.'
            }
        }
        if ($journalSchemaVersion -ge 2) {
            foreach ($field in @('cpaCandidatePort', 'managerCandidatePort')) {
                if ([string]$previous.$field -cne [string]$journal.$field) {
                    throw "Previous upgrade journal immutable field '$field' does not match the current transaction."
                }
            }
        }
        foreach ($field in @('cpaBaseUrl', 'collectorEnabled', 'pollIntervalMs', 'usageStatisticsEnabled')) {
            if ($null -eq $previous.managerBaseline -or
                [string]$previous.managerBaseline.$field -cne [string]$journal.managerBaseline.$field) {
                throw "Previous upgrade journal Manager baseline field '$field' does not match the current transaction."
            }
        }
        foreach ($field in @('cpaCandidateExe', 'managerCandidateExe')) {
            $previousValue = [string]$previous.$field
            $currentValue = [string]$journal.$field
            if (-not [string]::IsNullOrWhiteSpace($previousValue) -and $previousValue -cne $currentValue) {
                throw "Previous upgrade journal candidate field '$field' changed within the transaction."
            }
        }
        $previousPhase = [string]$previous.phase
        $allowedPreviousPhases = switch ($phase) {
            'prepared' { @('prepared') }
            'testing-cpa' { @('prepared', 'testing-cpa') }
            'testing-manager' { @('prepared', 'testing-cpa', 'testing-manager') }
            'switching-cpa' { @('testing-cpa', 'testing-manager', 'switching-cpa') }
            'switching-manager' { @('testing-manager', 'switching-cpa', 'switching-manager') }
            'committing' { @('switching-cpa', 'switching-manager', 'committing') }
        }
        if ($previousPhase -cnotin @($allowedPreviousPhases)) {
            throw "Previous upgrade journal phase '$previousPhase' is not a legal predecessor of '$phase'."
        }
        $currentUpdatedAt = [DateTimeOffset]::MinValue
        $previousUpdatedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$journal.updatedAt, [ref]$currentUpdatedAt) -or
            -not [DateTimeOffset]::TryParse([string]$previous.updatedAt, [ref]$previousUpdatedAt) -or
            $previousUpdatedAt -gt $currentUpdatedAt) {
            throw 'Previous upgrade journal timestamp is not ordered before the current generation.'
        }
    }
    return [pscustomobject]@{
        Journal = $journal
        JournalDescriptor = $stableCurrent.Descriptor
        PreviousJournalDescriptor = $previousDescriptor
    }
}

function Recover-UpgradePreparationState {
    param([string]$CpaRuntime, [string]$ManagerRuntime)

    $validatedJournal = Read-ValidatedUpgradeJournal
    if ($null -eq $validatedJournal) { return $false }
    $journal = $validatedJournal.Journal
    Assert-ValidatedUpgradeJournalDescriptors -Validated $validatedJournal
    Stop-UpgradeTemporaryListeners -Journal $journal
    Assert-ValidatedUpgradeJournalDescriptors -Validated $validatedJournal
    Ensure-CanonicalServicesForPreparationRecovery -CpaRuntime $CpaRuntime -ManagerRuntime $ManagerRuntime
    $trustedManager = Assert-TrustedCanonicalManagerListener -ManagerRuntime $ManagerRuntime
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $baseline = $journal.managerBaseline
    [void](Set-CpaStackManagerCollector -ManagerPort $trustedManager.Port -CpaPort ([int]$trustedManager.Stack.Cpa.Port) -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$baseline.collectorEnabled) -Baseline $baseline)
    [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $trustedManager.Port -ManagerAdminKey $secrets.managerAdminKey -Expected $baseline)
    [void](Wait-CpaStackTrustedListener -Port $trustedManager.Port -ExpectedPath $trustedManager.Exe -ExpectedProcessId $trustedManager.Listener.ProcessId -ExpectedHash $trustedManager.Hash -AllowedAddresses @([string]$trustedManager.Stack.Manager.BindAddress) -Seconds 2)
    Assert-ValidatedUpgradeJournalDescriptors -Validated $validatedJournal
    Clear-SensitiveUpgradeWork -Journal $journal
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
    $hasRecoveryArtifact = (Test-Path -LiteralPath $cpaJournalPath -PathType Leaf) -or
        (Test-Path -LiteralPath $managerJournalPath -PathType Leaf) -or
        (@(Get-ChildItem -LiteralPath $rollbackRoot -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue).Count -gt 0)
    if ($hasRecoveryArtifact) { $script:suppressResultPersistence = $true }
    $recoveryStack = Get-CpaStackConfig -ControlRoot $ControlRoot
    $cpaFormalPort = [int]$recoveryStack.Cpa.Port
    $managerFormalPort = [int]$recoveryStack.Manager.Port
    $canonicalCpaRuntime = Join-Path $ControlRoot ([string]$recoveryStack.Cpa.WorkingDirectory)
    $canonicalCpaConfig = Join-Path $ControlRoot ([string]$recoveryStack.Cpa.Config)
    $canonicalManagerRuntime = Join-Path $ControlRoot ([string]$recoveryStack.Manager.WorkingDirectory)
    $canonicalManagerData = Join-Path $ControlRoot ([string]$recoveryStack.Manager.DataDirectory)

    function Get-NormalizedRecoveryPath {
        param([string]$Path, [string]$Description)
        if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Description is missing." }
        try {
            return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        } catch {
            throw "$Description is invalid: $Path"
        }
    }

    function Assert-RecoveryPathEquals {
        param([string]$Actual, [string]$Expected, [string]$Description)
        $actualFull = Get-NormalizedRecoveryPath -Path $Actual -Description $Description
        $expectedFull = Get-NormalizedRecoveryPath -Path $Expected -Description "Canonical $Description"
        if (-not [string]::Equals($actualFull, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$Description is not the canonical stack slot. Expected=$expectedFull Actual=$actualFull"
        }
    }

    foreach ($canonicalPath in @($canonicalCpaRuntime, $canonicalCpaConfig, $canonicalManagerRuntime, $canonicalManagerData)) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $canonicalPath
    }
    Assert-RecoveryPathEquals -Actual $CpaRuntime -Expected $canonicalCpaRuntime -Description 'CPA recovery runtime'
    Assert-RecoveryPathEquals -Actual $ManagerRuntime -Expected $canonicalManagerRuntime -Description 'Manager recovery runtime'
    Assert-RecoveryPathEquals -Actual $ManagerData -Expected $canonicalManagerData -Description 'Manager recovery data directory'

    $recordedState = Read-CpaStackJson -Path $currentStatePath

    function Get-RequiredJournalProperty {
        param($Journal, [string]$Name, [string]$JournalPath)
        $property = $Journal.PSObject.Properties[$Name]
        if ($null -eq $property) { throw "Recovery journal is missing $Name in $JournalPath" }
        return $property.Value
    }

    function Read-StableRecoveryJson {
        param([string]$Path, [string]$Description)

        Assert-CpaStackPath -Path $Path -PathType Leaf
        $beforeHash = Get-CpaStackFileHash -Path $Path
        $value = Read-CpaStackJson -Path $Path
        $afterHash = Get-CpaStackFileHash -Path $Path
        if ($beforeHash -notmatch '^[0-9A-Fa-f]{64}$' -or $beforeHash -ine $afterHash) {
            throw "$Description changed while it was being validated."
        }
        return [pscustomobject]@{
            Value = $value
            Descriptor = [pscustomobject]@{
                Path = [System.IO.Path]::GetFullPath($Path)
                Exists = $true
                Sha256 = $afterHash.ToUpperInvariant()
            }
        }
    }

    function Assert-RecoveryFileDescriptor {
        param($Descriptor, [string]$Description)

        if ($null -eq $Descriptor) { throw "$Description descriptor is missing." }
        $exists = Test-Path -LiteralPath ([string]$Descriptor.Path) -PathType Leaf
        if (-not [bool]$Descriptor.Exists) {
            if ($exists -or (Test-Path -LiteralPath ([string]$Descriptor.Path))) {
                throw "$Description appeared after recovery validation."
            }
            return
        }
        if (-not $exists) { throw "$Description disappeared after recovery validation." }
        if ((Get-CpaStackFileHash -Path ([string]$Descriptor.Path)) -ine [string]$Descriptor.Sha256) {
            throw "$Description changed after recovery validation."
        }
    }

    function Assert-RecoveryJournalDescriptors {
        param($Recovery)

        Assert-RecoveryFileDescriptor -Descriptor $Recovery.JournalDescriptor -Description 'Current switch journal'
        Assert-RecoveryFileDescriptor -Descriptor $Recovery.PreviousJournalDescriptor -Description 'Previous switch journal'
    }

    function Assert-RecoveryBackupDescriptor {
        param($Recovery)

        if ($null -eq $Recovery.BackupDescriptor) { return }
        $descriptor = $Recovery.BackupDescriptor
        $backupRoot = Get-NormalizedRecoveryPath -Path ([string]$descriptor.Root) -Description 'Recovery backup root'
        if ($backupRoot -ine (Get-NormalizedRecoveryPath -Path ([string]$Recovery.Backup.FullName) -Description 'Recorded recovery backup root')) {
            throw 'Recovery backup descriptor no longer identifies the validated backup.'
        }
        Assert-CpaStackChildPath -Root $ControlRoot -Path $backupRoot
        Assert-CpaStackPath -Path $backupRoot
        Assert-RecoveryFileDescriptor -Descriptor $descriptor.Manifest -Description 'Recovery backup manifest'
        $runtimeRoot = Join-Path $backupRoot 'runtime'
        if ([string](Get-CpaStackTreeManifest -Root $runtimeRoot).sha256 -ine [string]$descriptor.RuntimeTreeSha256) {
            throw 'Recovery backup runtime tree changed after validation.'
        }
        if ((Get-CpaStackFileHash -Path ([string]$descriptor.ExecutablePath)) -ine [string]$descriptor.ExecutableSha256) {
            throw 'Recovery backup executable changed after validation.'
        }
        if ($null -ne $descriptor.DataTreeSha256) {
            $dataRoot = Join-Path $backupRoot 'data'
            if ([string](Get-CpaStackTreeManifest -Root $dataRoot).sha256 -ine [string]$descriptor.DataTreeSha256) {
                throw 'Recovery backup data tree changed after validation.'
            }
            if ((Get-CpaStackFileHash -Path ([string]$descriptor.DataKeyPath)) -ine [string]$descriptor.DataKeySha256) {
                throw 'Recovery backup data.key changed after validation.'
            }
            Assert-RecoveryFileDescriptor -Descriptor $descriptor.SqliteBackupResult -Description 'Recovery SQLite backup result'
        }
    }

    function Assert-RecoveryDescriptors {
        param($Recovery, [switch]$IncludeBackup)

        if ($null -eq $Recovery) { return }
        Assert-RecoveryJournalDescriptors -Recovery $Recovery
        if ($IncludeBackup) { Assert-RecoveryBackupDescriptor -Recovery $Recovery }
    }

    function Assert-SwitchPhaseState {
        param(
            [string]$Component,
            [string]$Phase,
            [string]$RecordedHash,
            [string]$ActiveHash,
            [string]$OldHash,
            [string]$NewHash,
            [string]$PendingPath,
            $Journal,
            [string]$JournalPath
        )

        $recorded = $RecordedHash.ToUpperInvariant()
        $active = $ActiveHash.ToUpperInvariant()
        $old = $OldHash.ToUpperInvariant()
        $new = $NewHash.ToUpperInvariant()
        $targetProcessValue = Get-RequiredJournalProperty -Journal $Journal -Name 'targetProcessId' -JournalPath $JournalPath
        $targetProcessId = if ($null -eq $targetProcessValue) { 0 } else { [int]$targetProcessValue }

        switch ($Phase) {
            'prepared' {
                if ($recorded -ne $old -or $active -ne $old -or $targetProcessId -ne 0 -or
                    ($Component -eq 'manager' -and -not [string]::IsNullOrWhiteSpace($PendingPath))) {
                    throw "$Component prepared recovery phase is not bound to the active old runtime."
                }
            }
            'collector-disabled' {
                if ($Component -ne 'manager' -or $recorded -ne $old -or $active -ne $old -or
                    -not [string]::IsNullOrWhiteSpace($PendingPath) -or $targetProcessId -ne 0) {
                    throw 'Manager collector-disabled recovery phase is not semantically valid.'
                }
                if ($null -eq $Journal.managerBaseline -or
                    [bool](Get-RequiredJournalProperty -Journal $Journal -Name 'collectorEnabled' -JournalPath $JournalPath) -ne
                    [bool](Get-RequiredJournalProperty -Journal $Journal.managerBaseline -Name 'collectorEnabled' -JournalPath $JournalPath)) {
                    throw 'Manager collector-disabled recovery phase has an inconsistent collector baseline.'
                }
            }
            'source-stopped' {
                if ($recorded -ne $old -or $active -notin @($old, $new) -or $targetProcessId -ne 0) {
                    throw "$Component source-stopped recovery phase is inconsistent with the recorded runtime."
                }
            }
            { $_ -in @('target-started', 'runtime-verified') } {
                if ($recorded -notin @($old, $new) -or $active -ne $new -or
                    [string]::IsNullOrWhiteSpace($PendingPath) -or $targetProcessId -lt 1) {
                    throw "$Component $Phase recovery phase is not bound to the active new runtime and canonical backup."
                }
            }
            default { throw "$Component switch recovery phase is unsupported: $Phase" }
        }
    }

    function Read-ValidatedPending {
        param([string]$JournalPath, [string]$ExpectedOperation)
        if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $null }
        $stableJournal = Read-StableRecoveryJson -Path $JournalPath -Description 'Current switch journal'
        $journal = $stableJournal.Value
        $journalDescriptor = $stableJournal.Descriptor
        $operation = [string](Get-RequiredJournalProperty -Journal $journal -Name 'operation' -JournalPath $JournalPath)
        if ($operation -cne $ExpectedOperation) { throw "Unexpected recovery journal operation in $JournalPath" }

        $operationId = [string](Get-RequiredJournalProperty -Journal $journal -Name 'operationId' -JournalPath $JournalPath)
        if ($operationId -notmatch '^[0-9a-fA-F]{32}$') { throw "Recovery journal operationId is invalid in $JournalPath" }
        $journalInstanceId = [string](Get-RequiredJournalProperty -Journal $journal -Name 'instanceId' -JournalPath $JournalPath)
        if ($journalInstanceId -notmatch '^[0-9a-fA-F]{32}$' -or
            $null -eq $instanceMarker -or
            $journalInstanceId -cne [string]$instanceMarker.instanceId -or
            $journalInstanceId -cne [string]$recordedState.instanceId) {
            throw "Switch recovery journal belongs to a different CPA stack instance."
        }

        $phase = [string](Get-RequiredJournalProperty -Journal $journal -Name 'phase' -JournalPath $JournalPath)
        $allowedPhases = if ($ExpectedOperation -eq 'switch-cpa') {
            @('prepared', 'source-stopped', 'target-started', 'runtime-verified')
        } else {
            @('prepared', 'collector-disabled', 'source-stopped', 'target-started', 'runtime-verified')
        }
        if ($allowedPhases -cnotcontains $phase) { throw "Switch recovery journal phase is invalid in $JournalPath" }

        $component = if ($ExpectedOperation -eq 'switch-cpa') { 'cpa' } else { 'manager' }
        $componentStateProperty = $recordedState.PSObject.Properties[$component]
        if ($null -eq $componentStateProperty) { throw "Current state is missing the recorded $component component." }
        $componentState = $componentStateProperty.Value
        $canonicalRuntime = if ($component -eq 'cpa') { $canonicalCpaRuntime } else { $canonicalManagerRuntime }
        $canonicalExecutable = Join-Path $canonicalRuntime $(if ($component -eq 'cpa') { 'cli-proxy-api.exe' } else { 'cpa-manager-plus.exe' })
        Assert-RecoveryPathEquals `
            -Actual ([string](Get-RequiredJournalProperty -Journal $componentState -Name 'executable' -JournalPath $currentStatePath)) `
            -Expected $canonicalExecutable `
            -Description "Recorded $component executable"

        $oldHash = [string](Get-RequiredJournalProperty -Journal $journal -Name 'oldHash' -JournalPath $JournalPath)
        $newHash = [string](Get-RequiredJournalProperty -Journal $journal -Name 'newHash' -JournalPath $JournalPath)
        $recordedHash = [string](Get-RequiredJournalProperty -Journal $componentState -Name 'sha256' -JournalPath $currentStatePath)
        if ($oldHash -notmatch '^[0-9A-Fa-f]{64}$' -or
            $newHash -notmatch '^[0-9A-Fa-f]{64}$' -or
            $recordedHash -notmatch '^[0-9A-Fa-f]{64}$' -or
            $oldHash -ieq $newHash) {
            throw "Switch recovery journal hashes are invalid in $JournalPath"
        }
        $activeHash = Get-CpaStackFileHash -Path $canonicalExecutable
        if ($activeHash -notmatch '^[0-9A-Fa-f]{64}$') { throw "Canonical $component executable is missing during recovery validation." }

        if ($ExpectedOperation -eq 'switch-cpa') {
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'sourceRuntime' -JournalPath $JournalPath)) `
                -Expected $canonicalCpaRuntime `
                -Description 'CPA switch sourceRuntime'
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'targetRuntime' -JournalPath $JournalPath)) `
                -Expected $canonicalCpaRuntime `
                -Description 'CPA switch targetRuntime'
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'sourceConfig' -JournalPath $JournalPath)) `
                -Expected $canonicalCpaConfig `
                -Description 'CPA switch sourceConfig'
            $journalPort = [int](Get-RequiredJournalProperty -Journal $journal -Name 'port' -JournalPath $JournalPath)
            if ($journalPort -ne $cpaFormalPort) {
                throw 'CPA switch recovery journal formal port does not match stack configuration.'
            }
        } else {
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'sourceRuntime' -JournalPath $JournalPath)) `
                -Expected $canonicalManagerRuntime `
                -Description 'Manager switch sourceRuntime'
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'targetRuntime' -JournalPath $JournalPath)) `
                -Expected $canonicalManagerRuntime `
                -Description 'Manager switch targetRuntime'
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'sourceData' -JournalPath $JournalPath)) `
                -Expected $canonicalManagerData `
                -Description 'Manager switch sourceData'
            Assert-RecoveryPathEquals `
                -Actual ([string](Get-RequiredJournalProperty -Journal $journal -Name 'targetData' -JournalPath $JournalPath)) `
                -Expected $canonicalManagerData `
                -Description 'Manager switch targetData'
            $journalManagerPort = [int](Get-RequiredJournalProperty -Journal $journal -Name 'managerPort' -JournalPath $JournalPath)
            $journalCpaPort = [int](Get-RequiredJournalProperty -Journal $journal -Name 'cpaPort' -JournalPath $JournalPath)
            if ($journalManagerPort -ne $managerFormalPort -or $journalCpaPort -ne $cpaFormalPort) {
                throw 'Manager switch recovery journal formal ports do not match stack configuration.'
            }
            foreach ($field in @("cpaBaseUrl", "collectorEnabled", "pollIntervalMs", "usageStatisticsEnabled")) {
                if ($null -eq $journal.managerBaseline -or $null -eq $journal.managerBaseline.PSObject.Properties[$field]) {
                    throw "Manager recovery journal is missing baseline field $field."
                }
            }
        }
        $pendingPropertyValue = Get-RequiredJournalProperty -Journal $journal -Name 'pendingPath' -JournalPath $JournalPath
        $pendingPath = if ($null -eq $pendingPropertyValue) { $null } else { [string]$pendingPropertyValue }
        $destinationPath = if ($component -eq 'cpa') { Join-Path $rollbackRoot 'last-known-good\cpa' } else { Join-Path $rollbackRoot 'last-known-good\manager-plus' }
        $expectedLeaf = "pending-$component-$operationId"
        $rollbackFull = [System.IO.Path]::GetFullPath($rollbackRoot).TrimEnd('\')
        $expectedPendingFull = Join-Path $rollbackFull $expectedLeaf
        $pendingFull = $null
        if (-not [string]::IsNullOrWhiteSpace($pendingPath)) {
            $pendingFull = Get-NormalizedRecoveryPath -Path $pendingPath -Description "$ExpectedOperation pendingPath"
            if ((Split-Path -Parent $pendingFull).TrimEnd('\') -ine $rollbackFull -or
                (Split-Path -Leaf $pendingFull) -ine $expectedLeaf -or
                $pendingFull -ine $expectedPendingFull) {
                throw "Recovery journal pendingPath is not the exact expected rollback slot: $pendingPath"
            }
            Assert-CpaStackChildPath -Root $ControlRoot -Path $pendingFull
        } elseif ($component -eq 'cpa') {
            throw "$ExpectedOperation recovery journal is missing its canonical pendingPath."
        }

        $previousJournalPath = $JournalPath + '.previous'
        $previousJournalDescriptor = [pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($previousJournalPath)
            Exists = $false
            Sha256 = $null
        }
        if (Test-Path -LiteralPath $previousJournalPath -PathType Leaf) {
            $stablePrevious = Read-StableRecoveryJson -Path $previousJournalPath -Description 'Previous switch journal'
            $previous = $stablePrevious.Value
            $previousJournalDescriptor = $stablePrevious.Descriptor
            foreach ($field in @('schemaVersion', 'operation', 'operationId', 'parentOperationId', 'instanceId', 'createdAt', 'sourceRuntime', 'targetRuntime', 'oldHash', 'newHash')) {
                $currentValue = Get-RequiredJournalProperty -Journal $journal -Name $field -JournalPath $JournalPath
                $previousValue = Get-RequiredJournalProperty -Journal $previous -Name $field -JournalPath $previousJournalPath
                if ([string]$currentValue -cne [string]$previousValue) {
                    throw "Previous switch journal immutable field '$field' does not match the current transaction."
                }
            }
            $componentFields = if ($component -eq 'cpa') {
                @('sourceConfig', 'port', 'pendingPath', 'targetRuntimeManifestSha256', 'targetConfigSha256', 'targetHost')
            } else {
                @('sourceData', 'targetData', 'managerPort', 'cpaPort', 'collectorEnabled')
            }
            foreach ($field in $componentFields) {
                $currentValue = Get-RequiredJournalProperty -Journal $journal -Name $field -JournalPath $JournalPath
                $previousValue = Get-RequiredJournalProperty -Journal $previous -Name $field -JournalPath $previousJournalPath
                if ([string]$currentValue -cne [string]$previousValue) {
                    throw "Previous switch journal immutable field '$field' does not match the current transaction."
                }
            }
            if ($component -eq 'manager') {
                foreach ($field in @('cpaBaseUrl', 'collectorEnabled', 'pollIntervalMs', 'usageStatisticsEnabled')) {
                    $currentValue = Get-RequiredJournalProperty -Journal $journal.managerBaseline -Name $field -JournalPath $JournalPath
                    $previousValue = Get-RequiredJournalProperty -Journal $previous.managerBaseline -Name $field -JournalPath $previousJournalPath
                    if ([string]$currentValue -cne [string]$previousValue) {
                        throw "Previous Manager switch journal baseline field '$field' does not match the current transaction."
                    }
                }
                $previousPendingValue = Get-RequiredJournalProperty -Journal $previous -Name 'pendingPath' -JournalPath $previousJournalPath
                $previousPendingPath = if ($null -eq $previousPendingValue) { $null } else { [string]$previousPendingValue }
                if (-not [string]::IsNullOrWhiteSpace($previousPendingPath)) {
                    $previousPendingFull = Get-NormalizedRecoveryPath -Path $previousPendingPath -Description 'Previous Manager pendingPath'
                    if ($previousPendingFull -ine $expectedPendingFull) {
                        throw 'Previous Manager switch journal pendingPath is not the canonical transaction slot.'
                    }
                }
            }
            $phaseOrder = if ($component -eq 'cpa') {
                @('prepared', 'source-stopped', 'target-started', 'runtime-verified')
            } else {
                @('prepared', 'collector-disabled', 'source-stopped', 'target-started', 'runtime-verified')
            }
            $previousPhase = [string](Get-RequiredJournalProperty -Journal $previous -Name 'phase' -JournalPath $previousJournalPath)
            $currentPhaseIndex = [array]::IndexOf($phaseOrder, $phase)
            $previousPhaseIndex = [array]::IndexOf($phaseOrder, $previousPhase)
            if ($previousPhaseIndex -lt 0 -or $previousPhaseIndex -gt $currentPhaseIndex -or
                ($currentPhaseIndex - $previousPhaseIndex) -gt 1) {
                throw "Previous switch journal phase '$previousPhase' is not a legal predecessor of '$phase'."
            }
        }

        Assert-SwitchPhaseState -Component $component -Phase $phase -RecordedHash $recordedHash -ActiveHash $activeHash `
            -OldHash $oldHash -NewHash $newHash -PendingPath $pendingFull -Journal $journal -JournalPath $JournalPath
        $disposition = Resolve-CpaStackSwitchDisposition `
            -RecordedHash $recordedHash `
            -ActiveHash $activeHash `
            -OldHash $oldHash `
            -NewHash $newHash

        if (-not $pendingFull) {
            return [pscustomobject]@{
                Journal = $journal
                Backup = $null
                BackupLocation = 'none'
                DestinationPath = $destinationPath
                Disposition = $disposition
                JournalDescriptor = $journalDescriptor
                PreviousJournalDescriptor = $previousJournalDescriptor
                BackupDescriptor = $null
                ValidationError = $null
            }
        }
        $backupPath = $null
        $backupLocation = 'none'
        if (Test-Path -LiteralPath $pendingFull -PathType Container) {
            $backupPath = $pendingFull
            $backupLocation = 'pending'
        } elseif (Test-Path -LiteralPath (Join-Path $destinationPath 'manifest.json') -PathType Leaf) {
            $destinationManifest = Read-CpaStackJson -Path (Join-Path $destinationPath 'manifest.json')
            if ([string]$destinationManifest.operationId -eq $operationId) {
                $backupPath = $destinationPath
                $backupLocation = 'destination'
            }
        }
        if (-not $backupPath) {
            return [pscustomobject]@{
                Journal = $journal
                Backup = $null
                BackupLocation = 'none'
                DestinationPath = $destinationPath
                Disposition = $disposition
                JournalDescriptor = $journalDescriptor
                PreviousJournalDescriptor = $previousJournalDescriptor
                BackupDescriptor = $null
                ValidationError = $null
            }
        }
        try {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $backupPath
            Assert-CpaStackPath -Path $backupPath
            $manifestPath = Join-Path $backupPath 'manifest.json'
            $stableManifest = Read-StableRecoveryJson -Path $manifestPath -Description 'Recovery backup manifest'
            $manifest = $stableManifest.Value
            if ([string]$manifest.operationId -ne [string]$journal.operationId) { throw "Pending operationId does not match its journal." }
            $runtimeRoot = Join-Path $backupPath 'runtime'
            $runtimeTreeSha256 = [string](Get-CpaStackTreeManifest -Root $runtimeRoot).sha256
            $dataTreeSha256 = $null
            $dataKey = $null
            $dataKeySha256 = $null
            $sqliteBackupDescriptor = $null
            if ($ExpectedOperation -eq "switch-cpa") {
                $exe = Join-Path $backupPath "runtime\cli-proxy-api.exe"
                if ((Get-CpaStackFileHash -Path $exe) -ne [string]$manifest.executableSha256 -or [string]$manifest.executableSha256 -ne [string]$journal.oldHash) {
                    throw "CPA pending executable hash validation failed."
                }
                Assert-RecoveryPathEquals -Actual ([string]$manifest.sourceRuntime) -Expected $canonicalCpaRuntime -Description 'CPA rollback manifest sourceRuntime'
            } else {
                $exe = Join-Path $backupPath "runtime\cpa-manager-plus.exe"
                $dataKey = Join-Path $backupPath "data\data.key"
                if ((Get-CpaStackFileHash -Path $exe) -ne [string]$manifest.executableSha256 -or [string]$manifest.executableSha256 -ne [string]$journal.oldHash) { throw "Manager pending executable hash validation failed." }
                if ((Get-CpaStackFileHash -Path $dataKey) -ne [string]$manifest.dataKeySha256) { throw "Manager pending data.key hash validation failed." }
                Assert-RecoveryPathEquals -Actual ([string]$manifest.sourceRuntime) -Expected $canonicalManagerRuntime -Description 'Manager rollback manifest sourceRuntime'
                Assert-RecoveryPathEquals -Actual ([string]$manifest.sourceData) -Expected $canonicalManagerData -Description 'Manager rollback manifest sourceData'
                $stableBackupResult = Read-StableRecoveryJson -Path (Join-Path $backupPath 'sqlite-backup.json') -Description 'Recovery SQLite backup result'
                $backupResult = $stableBackupResult.Value
                if (-not $backupResult.success) { throw "Manager pending SQLite backup did not complete successfully." }
                $dataTreeSha256 = [string](Get-CpaStackTreeManifest -Root (Join-Path $backupPath 'data')).sha256
                $dataKeySha256 = [string]$manifest.dataKeySha256
                $sqliteBackupDescriptor = $stableBackupResult.Descriptor
            }
            $backupDescriptor = [pscustomobject]@{
                Root = [System.IO.Path]::GetFullPath($backupPath)
                Manifest = $stableManifest.Descriptor
                RuntimeTreeSha256 = $runtimeTreeSha256
                ExecutablePath = [System.IO.Path]::GetFullPath($exe)
                ExecutableSha256 = ([string]$manifest.executableSha256).ToUpperInvariant()
                DataTreeSha256 = $dataTreeSha256
                DataKeyPath = if ($null -eq $dataKey) { $null } else { [System.IO.Path]::GetFullPath($dataKey) }
                DataKeySha256 = if ($null -eq $dataKeySha256) { $null } else { $dataKeySha256.ToUpperInvariant() }
                SqliteBackupResult = $sqliteBackupDescriptor
            }
            return [pscustomobject]@{
                Journal = $journal
                Backup = Get-Item -LiteralPath $backupPath
                BackupLocation = $backupLocation
                DestinationPath = $destinationPath
                Disposition = $disposition
                ManagerSnapshot = if ($ExpectedOperation -eq 'switch-manager') { $backupResult } else { $null }
                JournalDescriptor = $journalDescriptor
                PreviousJournalDescriptor = $previousJournalDescriptor
                BackupDescriptor = $backupDescriptor
                ValidationError = $null
            }
        } catch {
            return [pscustomobject]@{
                Journal = $journal
                Backup = $null
                BackupLocation = 'none'
                DestinationPath = $destinationPath
                Disposition = $disposition
                JournalDescriptor = $journalDescriptor
                PreviousJournalDescriptor = $previousJournalDescriptor
                BackupDescriptor = $null
                ValidationError = $_.Exception.Message
            }
        }
    }

    $cpaRecovery = Read-ValidatedPending -JournalPath $cpaJournalPath -ExpectedOperation "switch-cpa"
    $managerRecovery = Read-ValidatedPending -JournalPath $managerJournalPath -ExpectedOperation "switch-manager"
    foreach ($recovery in @($cpaRecovery, $managerRecovery)) {
        if ($recovery -and -not [string]::IsNullOrWhiteSpace([string]$recovery.ValidationError)) {
            throw "A switch recovery backup failed validation: $($recovery.ValidationError)"
        }
    }

    $cpaDisposition = if ($cpaRecovery) { [string]$cpaRecovery.Disposition } else { 'none' }
    $managerDisposition = if ($managerRecovery) { [string]$managerRecovery.Disposition } else { 'none' }
    if ($cpaRecovery -and $cpaDisposition -notin @('restore-old', 'commit-new')) {
        throw 'CPA switch recovery disposition is invalid.'
    }
    if ($managerRecovery -and $managerDisposition -notin @('restore-old', 'commit-new')) {
        throw 'Manager switch recovery disposition is invalid.'
    }

    $referencedPending = @()
    if ($cpaRecovery -and $cpaRecovery.BackupLocation -eq 'pending') { $referencedPending += $cpaRecovery.Backup.FullName }
    if ($managerRecovery -and $managerRecovery.BackupLocation -eq 'pending') { $referencedPending += $managerRecovery.Backup.FullName }

    $unreferencedPending = @(Get-ChildItem -Force -LiteralPath $rollbackRoot -Directory -Filter "pending-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^pending-(cpa|manager)-[0-9a-fA-F]{32}$' -and $referencedPending -inotcontains $_.FullName })
    if ($unreferencedPending.Count -gt 0) {
        throw "Unreferenced rollback pending artifacts require manual recovery: $(@($unreferencedPending.FullName) -join ', ')"
    }
    Assert-RecoveryDescriptors -Recovery $cpaRecovery -IncludeBackup
    Assert-RecoveryDescriptors -Recovery $managerRecovery -IncludeBackup
    if ($hasRecoveryArtifact) { $script:suppressResultPersistence = $false }

    if (-not $cpaRecovery -and -not $managerRecovery -and $Preflight.Cpa.Healthy -and $Preflight.Manager.Healthy) {
        return
    }

    if ($cpaRecovery) {
        if ($cpaRecovery.Backup) {
            Assert-CpaStackProjectedTreePathBudget -Source (Join-Path $cpaRecovery.Backup.FullName 'runtime') -Destination $CpaRuntime
        }
        Assert-RecoveryDescriptors -Recovery $cpaRecovery -IncludeBackup
        [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath (Join-Path $CpaRuntime 'cli-proxy-api.exe'))
    }
    if ($managerRecovery) {
        if ($managerRecovery.Backup) {
            Assert-CpaStackProjectedTreePathBudget -Source (Join-Path $managerRecovery.Backup.FullName 'runtime') -Destination $ManagerRuntime
            Assert-CpaStackProjectedTreePathBudget -Source (Join-Path $managerRecovery.Backup.FullName 'data') -Destination $ManagerData
        }
        Assert-RecoveryDescriptors -Recovery $managerRecovery -IncludeBackup
        [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath (Join-Path $ManagerRuntime 'cpa-manager-plus.exe'))
    }

    if ($managerRecovery -and $managerDisposition -eq 'restore-old') {
        if (-not $managerRecovery.Backup -and (Get-CpaStackFileHash -Path (Join-Path $ManagerRuntime 'cpa-manager-plus.exe')) -ne [string]$managerRecovery.Journal.oldHash) {
            throw "Manager must be rolled back, but its validated backup is unavailable. $($managerRecovery.ValidationError)"
        }
        if ($managerRecovery.Backup) {
            Assert-RecoveryDescriptors -Recovery $managerRecovery -IncludeBackup
            $listener = Get-CpaStackListener -Port $managerFormalPort
            $expectedExe = Join-Path $ManagerRuntime "cpa-manager-plus.exe"
            if ($listener -and $listener.ExecutablePath -ine $expectedExe) { throw "Unexpected process owns Manager formal port $managerFormalPort during recovery." }
            if ($listener) {
                $listenerProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $expectedExe
                try { Stop-CpaStackPort -Port $managerFormalPort -ExpectedPath $expectedExe -ExpectedProcess $listenerProcess -RequireExecutableWriteAccess }
                finally { if ($listenerProcess -is [System.IDisposable]) { $listenerProcess.Dispose() } }
            }
            Assert-RecoveryDescriptors -Recovery $managerRecovery -IncludeBackup
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
            Assert-RecoveryDescriptors -Recovery $cpaRecovery -IncludeBackup
            $listener = Get-CpaStackListener -Port $cpaFormalPort
            $expectedExe = Join-Path $CpaRuntime "cli-proxy-api.exe"
            if ($listener -and $listener.ExecutablePath -ine $expectedExe) { throw "Unexpected process owns CPA formal port $cpaFormalPort during recovery." }
            if ($listener) {
                $listenerProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $expectedExe
                try { Stop-CpaStackPort -Port $cpaFormalPort -ExpectedPath $expectedExe -ExpectedProcess $listenerProcess -RequireExecutableWriteAccess }
                finally { if ($listenerProcess -is [System.IDisposable]) { $listenerProcess.Dispose() } }
            }
            Assert-RecoveryDescriptors -Recovery $cpaRecovery -IncludeBackup
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
        Protect-CpaStackSecretFile -Path $canonicalCpaConfig
        Protect-CpaStackPrivateTree -Root (Join-Path $CpaRuntime 'auth')
        $recoveryPlugins = Join-Path $CpaRuntime 'plugins'
        if (Test-Path -LiteralPath $recoveryPlugins) { Protect-CpaStackPrivateTree -Root $recoveryPlugins }
    }

    $recoveryPlugins = Join-Path $CpaRuntime 'plugins'
    if (Test-Path -LiteralPath $recoveryPlugins) {
        Assert-CpaStackPrivateTree -Root $recoveryPlugins -Description 'Preserved CPA plugins'
    }

    Protect-CpaStackSecretFile -Path (Join-Path $ControlRoot 'config\stack.psd1')
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
        Assert-RecoveryDescriptors -Recovery $entry.Recovery -IncludeBackup
        if ($entry.Recovery.BackupLocation -eq 'pending' -and (Test-Path -LiteralPath $entry.Recovery.Backup.FullName)) {
            [void](Commit-CpaStackDirectorySlot -ControlRoot $ControlRoot -PendingPath $entry.Recovery.Backup.FullName -DestinationPath $entry.Recovery.DestinationPath)
        }
        Assert-RecoveryJournalDescriptors -Recovery $entry.Recovery
        foreach ($descriptor in @($entry.Recovery.JournalDescriptor, $entry.Recovery.PreviousJournalDescriptor)) {
            if ([bool]$descriptor.Exists) {
                Remove-Item -LiteralPath ([string]$descriptor.Path) -Force -ErrorAction Stop
            }
        }
    }
}

try {
    $operationMutex = Enter-CpaStackOperationLock
    Assert-CpaStackPath -Path $ControlRoot
    $pendingAtEntry = @(Get-ChildItem -LiteralPath $stateDir -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
    $rollbackPendingAtEntry = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'rollback') -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue)
    $upgradePreviousAtEntry = Test-Path -LiteralPath ($upgradeJournalPath + '.previous') -PathType Leaf
    if ($pendingAtEntry.Count -gt 0 -or $rollbackPendingAtEntry.Count -gt 0 -or $upgradePreviousAtEntry) {
        $rootAcl = Get-CpaStackFileSystemAcl -Path $ControlRoot
        if (-not (Test-CpaStackPrivateAcl -Acl $rootAcl -Directory)) {
            throw 'Pending recovery requires an already protected canonical root; refusing to repair ACLs before journal validation.'
        }
    } else {
        Protect-CpaStackPrivateDirectory -Path $ControlRoot
    }
    if ($upgradePreviousAtEntry -and -not (Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf)) {
        throw 'An orphan upgrade journal previous generation requires manual recovery.'
    }
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

    if ($RecoverOnly -and (Remove-CommittedOrphanSwitchPrevious -CurrentState $identityState)) {
        $result.recoveredInterruptedState = $true
    }

    $pendingStateFiles = @(Get-ChildItem -LiteralPath $stateDir -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
    $pendingRollbackDirectories = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'rollback') -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue)
    if ($pendingStateFiles.Count -eq 0 -and $pendingRollbackDirectories.Count -eq 0) {
        Repair-CpaStackRecordedExecutableAcl -CurrentState $identityState -Stack $stack -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime
    }
    $preflight = Invoke-ChildPowerShellJson -Script (Join-Path $PSScriptRoot "Get-CpaStackState.ps1") -Arguments @("-ControlRoot", $ControlRoot) -AllowNonZero
    $hasSwitchJournal = (Test-Path -LiteralPath (Join-Path $stateDir "switch-cpa.pending.json") -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $stateDir "switch-manager.pending.json") -PathType Leaf)
    $hasUpgradeJournal = Test-Path -LiteralPath $upgradeJournalPath -PathType Leaf
    if ($hasSwitchJournal) {
        Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $preflight
        if ($hasUpgradeJournal) { [void](Recover-UpgradePreparationState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime) }
        $result.recoveredInterruptedState = $true
        if (-not $RecoverOnly) { throw "Interrupted CPA stack state was recovered. Rerun the upgrade to start a fresh transaction." }
    }
    elseif ($hasUpgradeJournal) {
        [void](Recover-UpgradePreparationState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime)
        $result.recoveredInterruptedState = $true
        if (-not $RecoverOnly) { throw "Interrupted candidate validation state was recovered. Rerun the upgrade to start a fresh transaction." }
    }
    elseif ($preflight.InterruptedState) {
        Restore-CanonicalInterruptedState -CpaRuntime $cpaRuntime -ManagerRuntime $managerRuntime -ManagerData $managerData -Preflight $preflight
        $result.recoveredInterruptedState = $true
        if (-not $RecoverOnly) { throw "Interrupted CPA stack state was recovered. Rerun the upgrade to start a fresh transaction." }
    }
    if ($RecoverOnly) {
        $result.success = $true
    } else {
    if (-not $preflight.OverallHealthy -or $preflight.CanonicalEstablished -eq $false) {
        throw "Canonical preflight is not healthy."
    }
    $launcherSync = Sync-CpaStackCanonicalLauncher -ControlRoot $ControlRoot
    $result.launcherUpdated = [bool]$launcherSync.changed
    foreach ($path in @($cpaRuntime, $managerRuntime, $managerData)) { Assert-CpaStackPath -Path $path }
    foreach ($path in @($cpaConfig, (Join-Path $cpaRuntime "cli-proxy-api.exe"), (Join-Path $managerRuntime "cpa-manager-plus.exe"))) { Assert-CpaStackPath -Path $path -PathType Leaf }
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
        $cpaFormalPort = [int]$stack.Cpa.Port
        $managerFormalPort = [int]$stack.Manager.Port
        $candidatePortPlan = New-CpaStackCandidatePortPlan -FormalPort @($cpaFormalPort, $managerFormalPort)
        $cpaCandidatePort = [int]$candidatePortPlan.Ports.CpaCandidate
        $managerCandidatePort = [int]$candidatePortPlan.Ports.ManagerCandidate
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
            schemaVersion = 3
            operation = "upgrade-candidates"
            operationId = [guid]::NewGuid().ToString('N')
            instanceId = [string]$instanceMarker.instanceId
            phase = "prepared"
            canonicalRoot = $ControlRoot
            cpaCandidateExe = $null
            managerCandidateExe = $null
            cpaCandidatePort = $cpaCandidatePort
            managerCandidatePort = $managerCandidatePort
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
            "-ResultPath", (Join-Path $stateDir "cpa-candidate-upgrade-test.json"),
            "-Port", ([string]$cpaCandidatePort)
        ) -AdditionalParameters @{ FormalPort = @($cpaFormalPort, $managerFormalPort) }
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
            "-ResultPath", (Join-Path $stateDir "manager-candidate-upgrade-test.json"),
            "-CpaPort", ([string]$cpaFormalPort),
            "-FormalPort", ([string]$managerFormalPort),
            "-TempPort", ([string]$managerCandidatePort)
        )
        if ($requireV111) { $managerTestArguments += "-RequireV111Schema" }
        $result.managerCandidate = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Test-ManagerCandidate.ps1") -Arguments $managerTestArguments
    }

    Assert-UpgradeTemporaryPortsFree -Journal $upgradeJournal

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
            "-Port", ([string]$cpaFormalPort),
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
            "-ManagerPort", ([string]$managerFormalPort),
            "-CpaPort", ([string]$cpaFormalPort),
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
    if ((Test-Path -LiteralPath $stateDir) -and -not $suppressResultPersistence) {
        Write-CpaStackJson -Value $result -Path $resultPath
    }
    Exit-CpaStackOperationLock -Mutex $operationMutex
}

$result | ConvertTo-Json -Depth 14 -Compress
if (-not $result.success) {
    Write-Error $result.error
    exit 1
}
