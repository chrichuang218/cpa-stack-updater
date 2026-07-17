$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\CpaStack.ProductionGuard.psm1') -Force

function Get-TestTreeSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IgnoreDirectoryTimestamps
    )

    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full)) { return '<missing>' }
    return @(
        Get-Item -Force -LiteralPath $full
        Get-ChildItem -Force -LiteralPath $full -Recurse
    ) | Sort-Object FullName | ForEach-Object {
        $relative = if ([string]::Equals($_.FullName, $full, [System.StringComparison]::OrdinalIgnoreCase)) {
            '.'
        } else {
            $_.FullName.Substring($full.Length).TrimStart('\')
        }
        [ordered]@{
            path = $relative
            kind = if ($_.PSIsContainer) { 'directory' } else { 'file' }
            length = if ($_.PSIsContainer) { $null } else { $_.Length }
            sha256 = if ($_.PSIsContainer) { $null } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash }
            lastWriteUtcTicks = if ($IgnoreDirectoryTimestamps -and $_.PSIsContainer) { $null } else { $_.LastWriteTimeUtc.Ticks }
        }
    } | ConvertTo-Json -Depth 4 -Compress
}

function Get-TestLocatorSnapshot {
    param([Parameter(Mandatory = $true)][string]$LocalAppDataRoot)

    $stateHome = Join-Path $LocalAppDataRoot 'CPAStack'
    return @('root.json', 'root.json.previous') | ForEach-Object {
        $path = Join-Path $stateHome $_
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [ordered]@{ name = $_; missing = $true }
        } else {
            $item = Get-Item -Force -LiteralPath $path
            [ordered]@{
                name = $_
                missing = $false
                length = $item.Length
                sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
                lastWriteUtcTicks = $item.LastWriteTimeUtc.Ticks
            }
        }
    } | ConvertTo-Json -Depth 3 -Compress
}

function Invoke-InstallJson {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Update')][string]$Action,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [AllowNull()][string]$StackRoot
    )

    $text = @(& $Script -Action $Action -CodexHome $CodexHome -StackRoot $StackRoot -Json)
    return (($text | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
}

function Register-StartedInstallerTestProcess {
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [ValidateRange(1, 60000)][int]$WaitMilliseconds = 10000
    )

    try {
        return Register-CpaStackTestProcess -Guard $Guard -Process $Process
    } catch {
        $registrationError = $_
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
        if (-not $Process.WaitForExit($WaitMilliseconds)) {
            throw "Test process $($Process.Id) did not exit after registration failed."
        }
    } catch {
        throw "Test process registration failed and cleanup also failed. Registration=[$($registrationError.Exception.Message)] Cleanup=[$($_.Exception.Message)]"
    }

    throw $registrationError
}

function ConvertTo-InstallerTestBase64 {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function Start-RegisteredInstallerTestProcess {
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][string]$Script,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath,
        [ref]$StartedProcessId,
        [ValidateRange(1, 30000)][int]$GateTimeoutMilliseconds = 10000
    )

    $gateId = [guid]::NewGuid().ToString('N')
    $gateRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
    $readyPath = Join-Path $gateRoot ("process-gate-$gateId.ready")
    $goPath = Join-Path $gateRoot ("process-gate-$gateId.go")
    $parameterJson = ConvertTo-Json $Parameters -Compress
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$readyPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(ConvertTo-InstallerTestBase64 -Value $readyPath)'))
`$goPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(ConvertTo-InstallerTestBase64 -Value $goPath)'))
`$payloadPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(ConvertTo-InstallerTestBase64 -Value ([System.IO.Path]::GetFullPath($Script)))'))
`$parameterJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(ConvertTo-InstallerTestBase64 -Value $parameterJson)'))
`$parameterDocument = ConvertFrom-Json -InputObject `$parameterJson
`$payloadParameters = @{}
foreach (`$property in `$parameterDocument.PSObject.Properties) { `$payloadParameters[[string]`$property.Name] = `$property.Value }
[System.IO.File]::WriteAllText(`$readyPath, [string]`$PID, [System.Text.Encoding]::ASCII)
while (-not (Test-Path -LiteralPath `$goPath -PathType Leaf)) { Start-Sleep -Milliseconds 25 }
& `$payloadPath @payloadParameters
if (`$null -ne `$LASTEXITCODE) { exit [int]`$LASTEXITCODE }
"@
    $encodedWrapper = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))
    $process = Start-Process `
        -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedWrapper) `
        -RedirectStandardOutput $OutputPath `
        -RedirectStandardError $ErrorPath `
        -WindowStyle Hidden `
        -PassThru
    if ($null -ne $StartedProcessId) { $StartedProcessId.Value = [int]$process.Id }
    try {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($GateTimeoutMilliseconds)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            throw "Test process did not reach its pre-execution registration gate: $Script"
        }
        [void](Register-StartedInstallerTestProcess -Guard $Guard -Process $process)
        [System.IO.File]::WriteAllText($goPath, 'go', [System.Text.Encoding]::ASCII)
        return $process
    } catch {
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(10000)) {
                throw "Test process $($process.Id) did not exit after its registration gate failed."
            }
        }
        throw
    }
}

function Invoke-InstallProcessJson {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Update')][string]$Action,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$StackRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath,
        $Guard
    )

    $parameters = @{ Action = $Action; CodexHome = $CodexHome; Json = $true }
    if (-not [string]::IsNullOrWhiteSpace($StackRoot)) { $parameters.StackRoot = $StackRoot }
    $process = Start-RegisteredInstallerTestProcess `
        -Guard $Guard -Script $Script -Parameters $parameters `
        -OutputPath $OutputPath -ErrorPath $ErrorPath
    if (-not $process.WaitForExit(30000)) { throw 'Installer child process timed out.' }

    $output = [System.IO.File]::ReadAllText($OutputPath, [System.Text.UTF8Encoding]::new($false, $true)).Trim()
    $errorOutput = [System.IO.File]::ReadAllText($ErrorPath, [System.Text.Encoding]::Default).Trim()
    $document = if ([string]::IsNullOrWhiteSpace($output)) { $null } else { $output | ConvertFrom-Json }
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Document = $document
        Output = $output
        ErrorOutput = $errorOutput
    }
}

function Get-ProductionExecutableSnapshot {
    param(
        [Parameter(Mandatory = $true)]$ListenerSnapshot,
        [Parameter(Mandatory = $true)][int[]]$ProtectedPort
    )

    return @($ListenerSnapshot | Where-Object {
        [int]$_.LocalPort -in $ProtectedPort -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        (Test-Path -LiteralPath ([string]$_.ExecutablePath) -PathType Leaf)
    } | ForEach-Object {
        [ordered]@{
            port = [int]$_.LocalPort
            processId = [int]$_.OwningProcess
            path = [System.IO.Path]::GetFullPath([string]$_.ExecutablePath)
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$_.ExecutablePath)).Hash
        }
    } | Sort-Object port, processId, path) | ConvertTo-Json -Depth 4 -Compress
}

function Get-ProductionControlFileSnapshot {
    param([Parameter(Mandatory = $true)][string[]]$ProductionRoot)

    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $ProductionRoot) {
        foreach ($relative in @('.cpa-stack-instance.json', 'state\current.json', 'ops\Start-CPA-Stack.ps1')) {
            $path = Join-Path $root $relative
            if (Test-Path -LiteralPath $path -PathType Leaf) { [void]$paths.Add($path) }
        }
    }
    $locator = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\root.json'
    if (Test-Path -LiteralPath $locator -PathType Leaf) { [void]$paths.Add($locator) }
    return @($paths | Sort-Object -Unique | ForEach-Object {
        [ordered]@{
            path = [System.IO.Path]::GetFullPath($_)
            length = (Get-Item -Force -LiteralPath $_).Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash
        }
    }) | ConvertTo-Json -Depth 4 -Compress
}

$sourceRepo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-install-v2-tests-' + [guid]::NewGuid().ToString('N'))
$stackParent = Join-Path $HOME ('.cpa-install-v2-tests-' + [guid]::NewGuid().ToString('N'))
$previousFailurePoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_FAIL_AFTER_SLOT_ROTATION', 'Process')
$previousDelayPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_DELAY_BEFORE_INSTALL_LOCK', 'Process')
$previousHoldPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_RETIRE', 'Process')
$previousReadyPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_HOLD_READY_PATH', 'Process')
$previousLauncherFailurePoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_FAIL_LAUNCHER_SYNC', 'Process')
$previousRegistrationFailurePoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_FAIL_REGISTRATION', 'Process')
$previousLegacyMarkerHoldPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_MARKER', 'Process')
$previousLegacyMarkerReadyPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_LEGACY_MARKER_READY_PATH', 'Process')
$previousJournalRecoveryHoldPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_JOURNAL_RECOVERY', 'Process')
$previousJournalRecoveryReadyPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_JOURNAL_RECOVERY_READY_PATH', 'Process')
$previousLegacyRelocationHoldPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_PREVIOUS_RELOCATION', 'Process')
$previousLegacyRelocationReadyPoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_LEGACY_PREVIOUS_RELOCATION_READY_PATH', 'Process')
$guard = $null
$productionExecutableBefore = $null
$productionControlFilesBefore = $null
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $fixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $sourceRepo `
        -DestinationRepository (Join-Path $temp 'repository') `
        -LocalAppDataRoot (Join-Path $temp 'local-app-data')
    $install = Join-Path $fixture.Repository 'install.ps1'
    $codexHome = Join-Path $temp 'codex-home'
    $stackRoot = Join-Path $stackParent 'managed stack'
    . (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
    Protect-CpaStackPrivateDirectory -Path $stackParent

    $productionStateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack'
    $productionListenerSnapshot = @(Get-CpaStackListenerSnapshot)
    $productionRootCandidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($env:CPA_STACK_ROOT)) {
        [void]$productionRootCandidates.Add($env:CPA_STACK_ROOT)
    }
    $productionLocator = Join-Path $productionStateHome 'root.json'
    if (Test-Path -LiteralPath $productionLocator -PathType Leaf) {
        try {
            $locator = [System.IO.File]::ReadAllText($productionLocator, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$locator.root)) {
                [void]$productionRootCandidates.Add([string]$locator.root)
            }
        } catch {}
    }
    foreach ($listener in @($productionListenerSnapshot | Where-Object { [int]$_.LocalPort -in @(8317, 8318, 18317, 18318) })) {
        if ([string]::IsNullOrWhiteSpace([string]$listener.ExecutablePath)) { continue }
        $ancestor = Split-Path -Parent ([System.IO.Path]::GetFullPath([string]$listener.ExecutablePath))
        while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
            if (Test-Path -LiteralPath (Join-Path $ancestor '.cpa-stack-instance.json') -PathType Leaf) {
                [void]$productionRootCandidates.Add($ancestor)
                break
            }
            $parent = Split-Path -Parent $ancestor
            if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $ancestor, [System.StringComparison]::OrdinalIgnoreCase)) { break }
            $ancestor = $parent
        }
    }
    $productionRoots = @($productionRootCandidates | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Container)
    } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
    $guard = New-CpaStackProductionGuard `
        -ProductionRoot $productionRoots `
        -ProductionStateHome $productionStateHome `
        -ProductionPort @(8317, 8318, 18317, 18318) `
        -ListenerSnapshot $productionListenerSnapshot
    $portPlan = New-CpaStackTestPortPlan -Guard $guard -Name @('InstallerLoopback')
    [void](Assert-CpaStackTestIsolation `
        -Guard $guard `
        -TestRoot $stackParent `
        -TestStateHome $temp `
        -TestPort $portPlan.AllPorts)
    Assert-True ([int]$portPlan.Ports.InstallerLoopback -ge 49152) 'Installer test plan uses a dynamic high loopback port'
    Assert-False ([int]$portPlan.Ports.InstallerLoopback -in @(8317, 8318, 18317, 18318)) 'Installer test plan excludes every fixed production and legacy candidate port'
    Assert-False ([System.IO.Path]::GetFullPath($fixture.LocalAppData).StartsWith([System.IO.Path]::GetFullPath($productionStateHome).TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Installer fixture uses an isolated state and lock namespace'
    $productionExecutableBefore = Get-ProductionExecutableSnapshot -ListenerSnapshot $guard.ListenerSnapshot -ProtectedPort $guard.ProtectedPorts
    $productionControlFilesBefore = Get-ProductionControlFileSnapshot -ProductionRoot $productionRoots

    $registrationFailurePayload = Join-Path $temp 'registration-failure-race.ps1'
    $registrationFailureGrandchildPid = Join-Path $temp 'registration-failure-grandchild.pid'
    $registrationFailureOutput = Join-Path $temp 'registration-failure-race.out'
    $registrationFailureError = Join-Path $temp 'registration-failure-race.err'
    $grandchildCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes('while ($true) { Start-Sleep -Seconds 60 }')
    )
    $registrationFailurePayloadText = @"
`$grandchild = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList @('-NoProfile', '-EncodedCommand', '$grandchildCommand') -WindowStyle Hidden -PassThru
[System.IO.File]::WriteAllText('$($registrationFailureGrandchildPid.Replace("'", "''"))', [string]`$grandchild.Id, [System.Text.Encoding]::ASCII)
while (`$true) { Start-Sleep -Seconds 60 }
"@
    [System.IO.File]::WriteAllText($registrationFailurePayload, $registrationFailurePayloadText, [System.Text.UTF8Encoding]::new($false))
    $registrationFailureWrapperPid = 0
    try {
        $closedGuard = [pscustomobject]@{ Closed = $true }
        Assert-ThrowsMatch {
            [void](Start-RegisteredInstallerTestProcess `
                -Guard $closedGuard -Script $registrationFailurePayload `
                -OutputPath $registrationFailureOutput -ErrorPath $registrationFailureError `
                -StartedProcessId ([ref]$registrationFailureWrapperPid))
        } 'already closed' 'Registration failure is surfaced before an eager payload can run'
        Assert-True ($null -eq (Get-Process -Id $registrationFailureWrapperPid -ErrorAction SilentlyContinue)) 'Registration failure cleanup waits for the gated wrapper to exit'
        Assert-False (Test-Path -LiteralPath $registrationFailureGrandchildPid) 'Registration failure never releases a payload that immediately derives a long-lived grandchild'
    } finally {
        if (Test-Path -LiteralPath $registrationFailureGrandchildPid -PathType Leaf) {
            $grandchildId = [int][System.IO.File]::ReadAllText($registrationFailureGrandchildPid).Trim()
            $grandchild = Get-Process -Id $grandchildId -ErrorAction SilentlyContinue
            if ($null -ne $grandchild) {
                $grandchild.Kill()
                Assert-True ($grandchild.WaitForExit(10000)) 'Registration race regression cleanup terminates an unexpected grandchild'
                $grandchild.Dispose()
            }
        }
    }

    $check = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 2 $check.schemaVersion 'Check returns installer schema v2'
    Assert-Equal 'install' $check.operation 'Check reports the public install operation'
    Assert-Equal 'Check' $check.action 'Check reports its action'
    Assert-Equal 'NoChange' $check.outcome 'Check is observational even when an update is available'
    Assert-False ([bool]$check.changed) 'Check never reports a write'
    Assert-True ([bool]$check.updateAvailable) 'Check detects a missing installed skill'
    Assert-Equal $null $check.installedVersion 'Check reports no installed version before first install'
    Assert-Equal 'Missing' $check.launcherState 'Check detects a missing explicit launcher'
    Assert-False (Test-Path -LiteralPath $codexHome) 'Check does not create CodexHome'
    Assert-False (Test-Path -LiteralPath $stackRoot) 'Check does not create StackRoot'

    $legacyCodexHome = Join-Path $temp 'legacy-codex-home'
    $legacySkillsRoot = Join-Path $legacyCodexHome 'skills'
    $legacyInstalled = Join-Path $legacySkillsRoot 'cpa-safe-upgrade'
    $legacySlotRoot = Join-Path $legacyCodexHome 'cpa-stack-updater\skill-slots'
    $legacyPrevious = Join-Path $legacySlotRoot 'previous'
    $legacyStackRoot = Join-Path $stackParent 'legacy managed stack'
    New-Item -ItemType Directory -Force -Path $legacySkillsRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $legacyCodexHome
    Protect-CpaStackPrivateDirectory -Path $legacySkillsRoot
    Copy-Item -LiteralPath (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade') -Destination $legacyInstalled -Recurse
    Assert-False (Test-Path -LiteralPath (Join-Path $legacyInstalled '.cpa-stack-updater-installed.json')) 'Legacy fixture starts without an installer ownership marker'

    $legacyMarkerNeedle = '            $legacyMarkerHash = Get-CpaStackFileHash -Path (Get-InstallMarkerPath -Root $previous)'
    $installerBeforeLegacyMarkerHold = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerBeforeLegacyMarkerHold, [regex]::Escape($legacyMarkerNeedle)).Count) 'Legacy marker hard-kill fixture has one post-marker seam'
    $legacyMarkerProbe = @'
            if ($env:CPA_STACK_TEST_HOLD_AFTER_LEGACY_MARKER -ceq '1') {
                [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_LEGACY_MARKER_READY_PATH, 'ready', [System.Text.Encoding]::ASCII)
                while ($true) { Start-Sleep -Milliseconds 200 }
            }
'@
    $installerBeforeLegacyMarkerHold = $installerBeforeLegacyMarkerHold.Replace(
        $legacyMarkerNeedle,
        $legacyMarkerNeedle + [Environment]::NewLine + $legacyMarkerProbe.TrimEnd()
    )
    $journalRecoveryNeedle = '    $journalRecovered = [bool]([bool]$journalRecovery.recovered -or $legacyPreviousRelocated)'
    Assert-Equal 1 ([regex]::Matches($installerBeforeLegacyMarkerHold, [regex]::Escape($journalRecoveryNeedle)).Count) 'Legacy recovery hard-kill fixture has one post-recovery seam'
    $journalRecoveryProbe = @'
    if ($env:CPA_STACK_TEST_HOLD_AFTER_JOURNAL_RECOVERY -ceq '1' -and $journalRecovered) {
        [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_JOURNAL_RECOVERY_READY_PATH, 'ready', [System.Text.Encoding]::ASCII)
        while ($true) { Start-Sleep -Milliseconds 200 }
    }
'@
    $installerBeforeLegacyMarkerHold = $installerBeforeLegacyMarkerHold.Replace(
        $journalRecoveryNeedle,
        $journalRecoveryNeedle + [Environment]::NewLine + $journalRecoveryProbe.TrimEnd()
    )
    [System.IO.File]::WriteAllText($install, $installerBeforeLegacyMarkerHold, [System.Text.UTF8Encoding]::new($false))

    $legacyMarkerReady = Join-Path $temp 'legacy-marker-ready.txt'
    $legacyMarkerOutput = Join-Path $temp 'legacy-marker-output.json'
    $legacyMarkerError = Join-Path $temp 'legacy-marker-error.txt'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_MARKER', '1', 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_LEGACY_MARKER_READY_PATH', $legacyMarkerReady, 'Process')
        $legacyMarkerProcess = Start-RegisteredInstallerTestProcess `
            -Guard $guard -Script $install `
            -Parameters @{ Action = 'Update'; CodexHome = $legacyCodexHome; StackRoot = $legacyStackRoot; Json = $true } `
            -OutputPath $legacyMarkerOutput -ErrorPath $legacyMarkerError
        $legacyMarkerDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $legacyMarkerReady -PathType Leaf) -and [DateTime]::UtcNow -lt $legacyMarkerDeadline) {
            if ($legacyMarkerProcess.HasExited) {
                $legacyMarkerProcess.WaitForExit()
                throw "Legacy marker fixture exited early: $([System.IO.File]::ReadAllText($legacyMarkerError))"
            }
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $legacyMarkerReady -PathType Leaf) 'Legacy fixture reaches the post-marker pre-commit interruption seam'
        Stop-Process -Id $legacyMarkerProcess.Id -Force -ErrorAction Stop
        [void]$legacyMarkerProcess.WaitForExit(10000)
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_MARKER', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_LEGACY_MARKER_READY_PATH', $null, 'Process')
    }
    $legacyJournalPath = Join-Path $legacySlotRoot 'install.pending.json'
    $legacyMarkerPath = Join-Path $legacyPrevious '.cpa-stack-updater-installed.json'
    Assert-True (Test-Path -LiteralPath $legacyJournalPath -PathType Leaf) 'Legacy hard kill retains the installer journal'
    Assert-True (Test-Path -LiteralPath $legacyMarkerPath -PathType Leaf) 'Legacy hard kill occurs after the temporary ownership marker is written'
    $legacyJournal = Read-CpaStackJson -Path $legacyJournalPath
    $legacyMarker = Read-CpaStackJson -Path $legacyMarkerPath
    Assert-False ([bool]$legacyJournal.installedOwnedBeforeTransaction) 'Legacy journal records that installer ownership did not preexist the transaction'
    Assert-True ([bool]$legacyJournal.installedWasLegacy) 'Legacy journal records the preexisting unowned skill state'
    Assert-Equal ([string]$legacyJournal.transactionId) ([string]$legacyMarker.transactionId) 'Temporary legacy marker is bound to the interrupted journal transaction'

    $journalRecoveryReady = Join-Path $temp 'legacy-journal-recovery-ready.txt'
    $journalRecoveryOutput = Join-Path $temp 'legacy-journal-recovery-output.json'
    $journalRecoveryError = Join-Path $temp 'legacy-journal-recovery-error.txt'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_JOURNAL_RECOVERY', '1', 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_JOURNAL_RECOVERY_READY_PATH', $journalRecoveryReady, 'Process')
        $journalRecoveryProcess = Start-RegisteredInstallerTestProcess `
            -Guard $guard -Script $install `
            -Parameters @{ Action = 'Update'; CodexHome = $legacyCodexHome; StackRoot = $legacyStackRoot; Json = $true } `
            -OutputPath $journalRecoveryOutput -ErrorPath $journalRecoveryError
        $journalRecoveryDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $journalRecoveryReady -PathType Leaf) -and [DateTime]::UtcNow -lt $journalRecoveryDeadline) {
            if ($journalRecoveryProcess.HasExited) {
                $journalRecoveryProcess.WaitForExit()
                throw "Legacy journal recovery fixture exited early: $([System.IO.File]::ReadAllText($journalRecoveryError))"
            }
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $journalRecoveryReady -PathType Leaf) 'Legacy fixture reaches the post-recovery interruption seam'
        Assert-True (Test-Path -LiteralPath $legacyInstalled -PathType Container) 'Legacy recovery restores the original directory to the installed slot'
        Assert-False (Test-Path -LiteralPath (Join-Path $legacyInstalled '.cpa-stack-updater-installed.json')) 'Legacy recovery removes the transaction-only marker before restoring the user directory'
        Stop-Process -Id $journalRecoveryProcess.Id -Force -ErrorAction Stop
        [void]$journalRecoveryProcess.WaitForExit(10000)
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_JOURNAL_RECOVERY', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_JOURNAL_RECOVERY_READY_PATH', $null, 'Process')
    }
    Assert-False (Test-Path -LiteralPath $legacyJournalPath) 'Legacy recovery removes the interrupted pre-commit journal'
    $legacyRecoveryCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $legacyCodexHome -StackRoot $legacyStackRoot
    Assert-True ([bool]$legacyRecoveryCheck.updateAvailable) 'Check still treats the restored unowned legacy skill as requiring a managed install'
    $legacyRecoveryRetry = Invoke-InstallJson -Script $install -Action Update -CodexHome $legacyCodexHome -StackRoot $legacyStackRoot
    Assert-Equal 'Changed' $legacyRecoveryRetry.outcome 'A clean retry installs over the safely restored legacy skill'
    Assert-True (Test-Path -LiteralPath $legacyPrevious -PathType Container) 'Clean retry retains the original legacy skill as the rollback slot'

    $first = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'Changed' $first.outcome 'First Update reports a change'
    Assert-True ([bool]$first.changed) 'First Update changes the managed artifacts'
    Assert-False ([bool]$first.updateAvailable) 'Successful Update leaves no source update pending'
    Assert-Equal ([string]$first.sourceVersion) ([string]$first.installedVersion) 'First Update installs the source version'
    Assert-Equal 'Current' $first.launcherState 'First Update creates the current launcher contract'
    $installed = Join-Path $codexHome 'skills\cpa-safe-upgrade'
    $skillSlotRoot = Join-Path $codexHome 'cpa-stack-updater\skill-slots'
    $previous = Join-Path $skillSlotRoot 'previous'
    $launcher = Join-Path $stackRoot 'ops\Start-CPA-Stack.ps1'
    $instanceMarkerPath = Join-Path $stackRoot '.cpa-stack-instance.json'
    Assert-True (Test-Path -LiteralPath $instanceMarkerPath -PathType Leaf) 'First Update pre-initializes an explicit empty StackRoot with an instance marker'
    $migrationEntryMarker = Ensure-CpaStackInstanceMarker -ControlRoot $stackRoot -AllowCreate
    Assert-Equal ([System.IO.Path]::GetFullPath($stackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$migrationEntryMarker.root).TrimEnd('\')) 'The installed root can enter migration marker validation without non-empty-root rejection'
    Assert-True (Test-Path -LiteralPath $launcher -PathType Leaf) 'First Update creates the stable launcher bootstrap'
    $discoverableSkills = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'skills') -Recurse -File -Filter 'SKILL.md')
    Assert-Equal 1 $discoverableSkills.Count 'Codex discovery root contains exactly one SKILL.md after install'
    Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $installed 'SKILL.md'))) ([System.IO.Path]::GetFullPath($discoverableSkills[0].FullName)) 'Only the canonical installed skill is discoverable'
    $launcherText = [System.IO.File]::ReadAllText($launcher, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($launcherText -match 'CODEX_HOME') 'Launcher locates the installed skill through CODEX_HOME'
    Assert-True ($launcherText -match '\$HOME.+\.codex') 'Launcher falls back to the user Codex home'
    Assert-True ($launcherText -match 'cpa-stack\.ps1') 'Launcher invokes the stable installed CLI'
    Assert-False (Test-Path -LiteralPath (Join-Path $stackRoot 'runtime')) 'Installer does not create or change runtime data'
    Assert-False (Test-Path -LiteralPath (Join-Path $stackRoot 'data')) 'Installer does not create or change Manager data'

    foreach ($foreignSlotName in @(
        'foreign-user-evidence.txt',
        ('install.pending.json.tmp-' + [guid]::NewGuid().ToString('N')),
        ('install.pending.json.previous-' + [guid]::NewGuid().ToString('N'))
    )) {
        $foreignSlotPath = Join-Path $skillSlotRoot $foreignSlotName
        [System.IO.File]::WriteAllText($foreignSlotPath, 'foreign slot evidence', [System.Text.Encoding]::ASCII)
        Protect-CpaStackSecretFile -Path $foreignSlotPath
        $foreignSlotCodexBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
        $foreignSlotStackBefore = Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps
        $foreignSlotStateBefore = Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData
        try {
            Assert-ThrowsMatch {
                [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
            } 'foreign|orphan|unreferenced' "Installer rejects unexpected slotRoot sibling $foreignSlotName before any managed write"
            Assert-Equal $foreignSlotCodexBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) "Foreign slotRoot sibling $foreignSlotName is preserved byte-for-byte"
            Assert-Equal $foreignSlotStackBefore (Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps) "Foreign slotRoot sibling $foreignSlotName leaves StackRoot unchanged"
            Assert-Equal $foreignSlotStateBefore (Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData) "Foreign slotRoot sibling $foreignSlotName leaves locator state unchanged"
        } finally {
            Remove-Item -LiteralPath $foreignSlotPath -Force
        }
    }

    $unownedNonEmptyRoot = Join-Path $stackParent 'unowned non-empty root'
    New-Item -ItemType Directory -Path $unownedNonEmptyRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $unownedNonEmptyRoot
    Set-Content -LiteralPath (Join-Path $unownedNonEmptyRoot 'user-content.txt') -Value 'do not claim' -Encoding ASCII
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $unownedNonEmptyRoot)
    } 'non-empty|pre-initialized' 'Installer refuses to claim an arbitrary non-empty StackRoot'
    Assert-False (Test-Path -LiteralPath (Join-Path $unownedNonEmptyRoot '.cpa-stack-instance.json')) 'Rejected non-empty root receives no ownership marker'
    Assert-False (Test-Path -LiteralPath (Join-Path $unownedNonEmptyRoot 'ops')) 'Rejected non-empty root receives no launcher directory'

    $legacyAdoptionRoot = Join-Path $stackParent 'legacy adoption required root'
    $legacyAdoptionState = Join-Path $legacyAdoptionRoot 'state'
    New-Item -ItemType Directory -Path $legacyAdoptionRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $legacyAdoptionRoot
    New-Item -ItemType Directory -Path $legacyAdoptionState | Out-Null
    Protect-CpaStackPrivateDirectory -Path $legacyAdoptionState
    $legacyAdoptionCurrent = Join-Path $legacyAdoptionState 'current.json'
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        instanceId = [guid]::NewGuid().ToString('N')
        canonicalRoot = $legacyAdoptionRoot
    }) -Path $legacyAdoptionCurrent
    Protect-CpaStackSecretFile -Path $legacyAdoptionCurrent
    $legacyAdoptionTreeBefore = Get-TestTreeSnapshot -Root $legacyAdoptionRoot
    $legacyAdoptionCodexBefore = Get-TestTreeSnapshot -Root $codexHome
    $legacyAdoptionStateHomeBefore = Get-TestTreeSnapshot -Root $fixture.LocalAppData
    $legacyAdoptionBlocked = Invoke-InstallJson `
        -Script $install -Action Update -CodexHome $codexHome -StackRoot $legacyAdoptionRoot
    Assert-False ([bool]$legacyAdoptionBlocked.success) 'A current-only legacy canonical root is blocked until explicit adoption'
    Assert-Equal 'ManualActionRequired' $legacyAdoptionBlocked.outcome 'Legacy canonical root returns an explicit manual-action result'
    Assert-True ([bool]$legacyAdoptionBlocked.blocked) 'Legacy canonical root result is explicitly blocked'
    Assert-True ([bool]$legacyAdoptionBlocked.legacyCanonicalAdoptionRequired) 'Legacy canonical root identifies adoption as the required action'
    Assert-Equal $legacyAdoptionTreeBefore (Get-TestTreeSnapshot -Root $legacyAdoptionRoot) 'Blocked legacy root receives no marker, launcher, or other tree write'
    Assert-Equal $legacyAdoptionCodexBefore (Get-TestTreeSnapshot -Root $codexHome) 'Blocked legacy root does not rotate or rewrite the installed skill'
    Assert-Equal $legacyAdoptionStateHomeBefore (Get-TestTreeSnapshot -Root $fixture.LocalAppData) 'Blocked legacy root does not rewrite the registered-root locator'

    $v014Archive = Join-Path $temp 'v0.1.4.zip'
    $v014Source = Join-Path $temp 'v0.1.4-source'
    & git.exe -C $sourceRepo archive '--format=zip' ('--output=' + $v014Archive) 'v0.1.4'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $v014Archive -PathType Leaf)) {
        throw 'Could not export the local v0.1.4 tag for the installer compatibility test.'
    }
    Expand-Archive -LiteralPath $v014Archive -DestinationPath $v014Source -Force
    $v014Fixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $v014Source `
        -DestinationRepository (Join-Path $temp 'v0.1.4-repository') `
        -LocalAppDataRoot (Join-Path $temp 'v0.1.4-local-app-data')
    $v014CodexHome = Join-Path $temp 'v0.1.4-codex-home'
    $v014StackRoot = Join-Path $stackParent 'v0.1.4 upgrade stack'
    $v014InstallOutput = @(& (Join-Path $v014Fixture.Repository 'install.ps1') -CodexHome $v014CodexHome)
    $v014Install = (($v014InstallOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ([bool]$v014Install.success) 'The real local v0.1.4 tag installer succeeds in an isolated CodexHome'
    Assert-Equal '0.1.4' ([System.IO.File]::ReadAllText((Join-Path $v014CodexHome 'skills\cpa-safe-upgrade\VERSION')).Trim()) 'The tag fixture installs the actual v0.1.4 skill'
    Assert-False (Test-Path -LiteralPath $v014StackRoot) 'The v0.1.4 seed install does not touch the future isolated StackRoot'

    $v014ToCurrent = Invoke-InstallJson -Script $install -Action Update -CodexHome $v014CodexHome -StackRoot $v014StackRoot
    Assert-Equal 'Changed' $v014ToCurrent.outcome 'Current installer upgrades the real v0.1.4 tag installation'
    Assert-Equal '0.2.0' ([string]$v014ToCurrent.installedVersion) 'v0.1.4 compatibility upgrade installs v0.2.0'
    $v014SlotRoot = Join-Path $v014CodexHome 'cpa-stack-updater\skill-slots'
    $v014SlotPrevious = Join-Path $v014SlotRoot 'previous'
    $v014LegacyPrevious = Join-Path $v014CodexHome 'skills\cpa-safe-upgrade.previous'
    Assert-Equal '0.1.4' ([System.IO.File]::ReadAllText((Join-Path $v014SlotPrevious 'VERSION')).Trim()) 'v0.1.4 compatibility upgrade retains the tagged skill outside the discovery root'
    [System.IO.Directory]::Move($v014SlotPrevious, $v014LegacyPrevious)
    $legacyRelocationCheckBefore = Get-TestTreeSnapshot -Root $v014CodexHome -IgnoreDirectoryTimestamps
    $legacyRelocationCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $v014CodexHome -StackRoot $v014StackRoot
    Assert-True ([bool]$legacyRelocationCheck.updateAvailable) 'Check reports legacy previous-slot relocation as pending work'
    Assert-True ([bool]$legacyRelocationCheck.recoveryPending) 'Check exposes legacy previous-slot relocation through recoveryPending'
    Assert-Equal $legacyRelocationCheckBefore (Get-TestTreeSnapshot -Root $v014CodexHome -IgnoreDirectoryTimestamps) 'Legacy previous relocation Check is strictly observational for every file and path'

    $legacyRelocationNeedle = '        [System.IO.Directory]::Move($legacyPrevious, $previous)'
    $installerBeforeLegacyRelocationHold = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerBeforeLegacyRelocationHold, [regex]::Escape($legacyRelocationNeedle)).Count) 'Legacy previous relocation hard-kill fixture has one atomic move seam'
    $legacyRelocationProbe = @'
        if ($env:CPA_STACK_TEST_HOLD_AFTER_LEGACY_PREVIOUS_RELOCATION -ceq '1') {
            [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_LEGACY_PREVIOUS_RELOCATION_READY_PATH, 'ready', [System.Text.Encoding]::ASCII)
            while ($true) { Start-Sleep -Milliseconds 200 }
        }
'@
    $installerBeforeLegacyRelocationHold = $installerBeforeLegacyRelocationHold.Replace(
        $legacyRelocationNeedle,
        $legacyRelocationNeedle + [Environment]::NewLine + $legacyRelocationProbe.TrimEnd()
    )
    [System.IO.File]::WriteAllText($install, $installerBeforeLegacyRelocationHold, [System.Text.UTF8Encoding]::new($false))
    $legacyRelocationReady = Join-Path $temp 'legacy-previous-relocation-ready.txt'
    $legacyRelocationOutput = Join-Path $temp 'legacy-previous-relocation-output.json'
    $legacyRelocationError = Join-Path $temp 'legacy-previous-relocation-error.txt'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_PREVIOUS_RELOCATION', '1', 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_LEGACY_PREVIOUS_RELOCATION_READY_PATH', $legacyRelocationReady, 'Process')
        $legacyRelocationProcess = Start-RegisteredInstallerTestProcess `
            -Guard $guard -Script $install `
            -Parameters @{ Action = 'Update'; CodexHome = $v014CodexHome; StackRoot = $v014StackRoot; Json = $true } `
            -OutputPath $legacyRelocationOutput -ErrorPath $legacyRelocationError
        $legacyRelocationDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $legacyRelocationReady -PathType Leaf) -and [DateTime]::UtcNow -lt $legacyRelocationDeadline) {
            if ($legacyRelocationProcess.HasExited) {
                $legacyRelocationProcess.WaitForExit()
                throw "Legacy relocation fixture exited early: $([System.IO.File]::ReadAllText($legacyRelocationError))"
            }
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $legacyRelocationReady -PathType Leaf) 'Legacy relocation reaches the post-move persisted-journal seam'
        Stop-Process -Id $legacyRelocationProcess.Id -Force -ErrorAction Stop
        [void]$legacyRelocationProcess.WaitForExit(10000)
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_PREVIOUS_RELOCATION', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_LEGACY_PREVIOUS_RELOCATION_READY_PATH', $null, 'Process')
    }
    $legacyRelocationJournal = Join-Path $v014SlotRoot 'legacy-previous-relocation.pending.json'
    Assert-False (Test-Path -LiteralPath $v014LegacyPrevious) 'Interrupted relocation already removed the discoverable legacy previous slot'
    Assert-True (Test-Path -LiteralPath $v014SlotPrevious -PathType Container) 'Interrupted relocation preserves the rollback payload in protected slotRoot'
    Assert-True (Test-Path -LiteralPath $legacyRelocationJournal -PathType Leaf) 'Interrupted relocation retains its recovery journal'
    $legacyRelocationRecovery = Invoke-InstallJson -Script $install -Action Update -CodexHome $v014CodexHome -StackRoot $v014StackRoot
    Assert-Equal 'Changed' $legacyRelocationRecovery.outcome 'Update completes an interrupted legacy previous relocation'
    Assert-True ([bool]$legacyRelocationRecovery.recovered) 'Interrupted legacy previous relocation is reported as recovered'
    Assert-False (Test-Path -LiteralPath $legacyRelocationJournal) 'Recovered legacy relocation removes its journal only after target verification'
    Assert-Equal '0.1.4' ([System.IO.File]::ReadAllText((Join-Path $v014SlotPrevious 'VERSION')).Trim()) 'Recovered relocation preserves the exact v0.1.4 rollback payload'
    $v014DiscoverableSkills = @(Get-ChildItem -LiteralPath (Join-Path $v014CodexHome 'skills') -Recurse -File -Filter 'SKILL.md')
    Assert-Equal 1 $v014DiscoverableSkills.Count 'Legacy relocation leaves exactly one discoverable skill under CodexHome skills'
    $v014CodexBeforeNoChange = Get-TestTreeSnapshot -Root $v014CodexHome
    $v014StackBeforeNoChange = Get-TestTreeSnapshot -Root $v014StackRoot
    $v014NoChange = Invoke-InstallJson -Script $install -Action Update -CodexHome $v014CodexHome -StackRoot $v014StackRoot
    Assert-Equal 'NoChange' $v014NoChange.outcome 'A repeated current install after v0.1.4 upgrade is idempotent'
    Assert-False ([bool]$v014NoChange.updateAvailable) 'v0.1.4 compatibility path converges with no update pending'
    Assert-Equal $v014CodexBeforeNoChange (Get-TestTreeSnapshot -Root $v014CodexHome) 'NoChange after v0.1.4 upgrade preserves CodexHome bytes and timestamps'
    Assert-Equal $v014StackBeforeNoChange (Get-TestTreeSnapshot -Root $v014StackRoot) 'NoChange after v0.1.4 upgrade preserves StackRoot bytes and timestamps'
    Set-CpaStackRegisteredRoot -ControlRoot $stackRoot

    $installedCli = Join-Path $installed 'scripts\cpa-stack.ps1'
    $installedCliBytes = [System.IO.File]::ReadAllBytes($installedCli)
    $fakeCliText = @'
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Root,
    [switch]$NoBrowser
)
Start-Sleep -Milliseconds 500
[pscustomobject]@{
    command = $Command
    root = $Root
    noBrowser = [bool]$NoBrowser
} | ConvertTo-Json -Compress
'@
    [System.IO.File]::WriteAllText($installedCli, $fakeCliText, [System.Text.Encoding]::ASCII)
    $previousCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process')
    $previousUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $null, 'Process')
        [Environment]::SetEnvironmentVariable('USERPROFILE', (Join-Path $temp 'isolated-user-profile'), 'Process')
        $bootstrapOutput = Join-Path $temp 'bootstrap-output.json'
        $bootstrapError = Join-Path $temp 'bootstrap-error.txt'
        $bootstrapProcess = Start-RegisteredInstallerTestProcess `
            -Guard $guard -Script $launcher -Parameters @{ NoBrowser = $true } `
            -OutputPath $bootstrapOutput -ErrorPath $bootstrapError
        if (-not $bootstrapProcess.WaitForExit(10000)) { throw 'Launcher bootstrap test process timed out.' }
        if ($bootstrapProcess.ExitCode -ne 0) {
            throw "Launcher bootstrap test process failed: $([System.IO.File]::ReadAllText($bootstrapError))"
        }
        $bootstrapResult = [System.IO.File]::ReadAllText($bootstrapOutput, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousCodexHome, 'Process')
        [Environment]::SetEnvironmentVariable('USERPROFILE', $previousUserProfile, 'Process')
        [System.IO.File]::WriteAllBytes($installedCli, $installedCliBytes)
    }
    Assert-Equal 'start' $bootstrapResult.command 'Launcher delegates to its custom installed home without requiring a persistent CODEX_HOME'
    Assert-Equal ([System.IO.Path]::GetFullPath($stackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$bootstrapResult.root).TrimEnd('\')) 'Launcher derives Root from the parent of ops'
    Assert-True ([bool]$bootstrapResult.noBrowser) 'Launcher forwards NoBrowser without starting a real process'

    $codexBeforeNoChange = Get-TestTreeSnapshot -Root $codexHome
    $stackBeforeNoChange = Get-TestTreeSnapshot -Root $stackRoot
    $second = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'NoChange' $second.outcome 'Repeated Update reports NoChange'
    Assert-False ([bool]$second.changed) 'Repeated Update reports zero writes'
    Assert-Equal $codexBeforeNoChange (Get-TestTreeSnapshot -Root $codexHome) 'Repeated Update leaves every CodexHome file and timestamp unchanged'
    Assert-Equal $stackBeforeNoChange (Get-TestTreeSnapshot -Root $stackRoot) 'Repeated Update leaves every StackRoot file and timestamp unchanged'

    $installedSkill = Join-Path $installed 'SKILL.md'
    $oldInstalledHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedSkill).Hash
    [System.IO.File]::AppendAllText(
        (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\SKILL.md'),
        "`r`n# v2 manifest-only update fixture`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $delayNeedle = '$operationLock = $null'
    $installerBeforeConcurrency = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerBeforeConcurrency, [regex]::Escape($delayNeedle)).Count) 'Concurrent fixture has one lock acquisition seam'
    $delayProbe = @'
if ($env:CPA_STACK_TEST_DELAY_BEFORE_INSTALL_LOCK -ceq '1') {
    Start-Sleep -Milliseconds 1000
}
'@
    $installerBeforeConcurrency = $installerBeforeConcurrency.Replace($delayNeedle, $delayProbe.TrimEnd() + [Environment]::NewLine + $delayNeedle)
    [System.IO.File]::WriteAllText($install, $installerBeforeConcurrency, [System.Text.UTF8Encoding]::new($false))
    $concurrentProcesses = New-Object 'System.Collections.Generic.List[object]'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_DELAY_BEFORE_INSTALL_LOCK', '1', 'Process')
        foreach ($index in 1..2) {
            $outputPath = Join-Path $temp "concurrent-install-$index.json"
            $errorPath = Join-Path $temp "concurrent-install-$index.err"
            $process = Start-RegisteredInstallerTestProcess `
                -Guard $guard -Script $install `
                -Parameters @{ Action = 'Update'; CodexHome = $codexHome; StackRoot = $stackRoot; Json = $true } `
                -OutputPath $outputPath -ErrorPath $errorPath
            [void]$concurrentProcesses.Add([pscustomobject]@{ Process = $process; Output = $outputPath; Error = $errorPath })
        }
        foreach ($entry in $concurrentProcesses) {
            if (-not $entry.Process.WaitForExit(30000)) { throw 'Concurrent installer process timed out.' }
            if ($entry.Process.ExitCode -ne 0) {
                throw "Concurrent installer failed: $([System.IO.File]::ReadAllText($entry.Error))"
            }
        }
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_DELAY_BEFORE_INSTALL_LOCK', $null, 'Process')
    }
    $concurrentOutcomes = @($concurrentProcesses | ForEach-Object {
        ([System.IO.File]::ReadAllText($_.Output, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json).outcome
    } | Sort-Object)
    Assert-Equal 'Changed,NoChange' ($concurrentOutcomes -join ',') 'Concurrent Update rechecks under the lock and rotates slots exactly once'
    Assert-True (Test-Path -LiteralPath $previous -PathType Container) 'Atomic Update retains the prior installed slot'
    Assert-Equal $oldInstalledHash (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $previous 'SKILL.md')).Hash 'Previous contains the exact formerly active skill'
    Assert-False ($oldInstalledHash -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath $installedSkill).Hash) 'Installed contains the changed source manifest'

    $activeBeforePersistentRecovery = (Get-FileHash -Algorithm SHA256 -LiteralPath $installedSkill).Hash
    [System.IO.File]::AppendAllText(
        (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\SKILL.md'),
        "`r`n# v2 persistent-recovery fixture`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $retireNeedle = '        Move-SkillDirectoryWithRetry -SourcePath $installed -SourceKind Installed -DestinationPath $retiring -DestinationKind Retiring'
    $installerBeforeHardTermination = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerBeforeHardTermination, [regex]::Escape($retireNeedle)).Count) 'Hard termination fixture has one post-retire seam'
    $retireProbe = @'
        if ($env:CPA_STACK_TEST_HOLD_AFTER_RETIRE -ceq '1') {
            [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_HOLD_READY_PATH, 'ready', [System.Text.Encoding]::ASCII)
            while ($true) { Start-Sleep -Milliseconds 200 }
        }
'@
    $installerBeforeHardTermination = $installerBeforeHardTermination.Replace($retireNeedle, $retireNeedle + [Environment]::NewLine + $retireProbe.TrimEnd())
    [System.IO.File]::WriteAllText($install, $installerBeforeHardTermination, [System.Text.UTF8Encoding]::new($false))
    $holdReady = Join-Path $temp 'hard-termination-ready.txt'
    $hardOutput = Join-Path $temp 'hard-termination-output.json'
    $hardError = Join-Path $temp 'hard-termination-error.txt'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_RETIRE', '1', 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_READY_PATH', $holdReady, 'Process')
        $hardProcess = Start-RegisteredInstallerTestProcess `
            -Guard $guard -Script $install `
            -Parameters @{ Action = 'Update'; CodexHome = $codexHome; StackRoot = $stackRoot; Json = $true } `
            -OutputPath $hardOutput -ErrorPath $hardError
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $holdReady -PathType Leaf) -and [DateTime]::UtcNow -lt $readyDeadline) {
            if ($hardProcess.HasExited) {
                $hardProcess.WaitForExit()
                throw "Hard termination fixture exited early: $([System.IO.File]::ReadAllText($hardError))"
            }
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $holdReady -PathType Leaf) 'Hard termination fixture reaches the persisted retiring phase'
        Stop-Process -Id $hardProcess.Id -Force -ErrorAction Stop
        [void]$hardProcess.WaitForExit(10000)
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_RETIRE', $null, 'Process')
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_READY_PATH', $null, 'Process')
    }
    $pendingJournal = Join-Path $skillSlotRoot 'install.pending.json'
    Assert-True (Test-Path -LiteralPath $pendingJournal -PathType Leaf) 'Hard process termination leaves a protected persistent journal'
    Assert-False (Test-Path -LiteralPath $installed) 'Hard process termination occurs after active is retired'
    $pendingCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-True ([bool]$pendingCheck.recoveryPending) 'Check reports pending recovery without mutating slots'
    $interruptedJournal = Read-CpaStackJson -Path $pendingJournal
    $interruptedRetiring = Join-Path $skillSlotRoot ('retiring-' + [string]$interruptedJournal.transactionId)
    $interruptedRetiringClaim = $interruptedRetiring + '.claim.json'
    Assert-True (Test-Path -LiteralPath $interruptedRetiring -PathType Container) 'Interrupted retiring artifact remains available for recovery validation'
    Assert-True (Test-Path -LiteralPath $interruptedRetiringClaim -PathType Leaf) 'Interrupted retiring artifact has a journal-bound sidecar claim'

    $foreignEvidence = Join-Path $interruptedRetiring 'user-evidence.txt'
    [System.IO.File]::WriteAllText($foreignEvidence, 'must survive rejected recovery', [System.Text.Encoding]::ASCII)
    $foreignEvidenceCodexBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
    $foreignEvidenceStackBefore = Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps
    $foreignEvidenceStateBefore = Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
    } 'manifest changed|foreign files' 'Recovery rejects a claimed transaction directory containing an arbitrary user file'
    $foreignEvidenceCodexAfter = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
    Assert-Equal $foreignEvidenceCodexBefore $foreignEvidenceCodexAfter 'Foreign transaction file rejection preserves every artifact and journal file byte/timestamp'
    Assert-Equal $foreignEvidenceStackBefore (Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps) 'Foreign transaction file rejection does not write the target root'
    Assert-Equal $foreignEvidenceStateBefore (Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData) 'Foreign transaction file rejection does not rewrite the locator'
    Remove-Item -LiteralPath $foreignEvidence -Force

    $retiringMarkerPath = Join-Path $interruptedRetiring '.cpa-stack-updater-installed.json'
    $retiringMarkerBytes = [System.IO.File]::ReadAllBytes($retiringMarkerPath)
    try {
        [System.IO.File]::AppendAllText($retiringMarkerPath, [Environment]::NewLine, [System.Text.Encoding]::ASCII)
        $markerDriftBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
        Assert-ThrowsMatch {
            [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
        } 'marker changed|marker hash' 'Recovery rejects marker hash drift before moving any slot'
        Assert-Equal $markerDriftBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) 'Marker drift rejection preserves the journal and all transaction evidence'
    } finally {
        [System.IO.File]::WriteAllBytes($retiringMarkerPath, $retiringMarkerBytes)
    }

    $retiringClaimBytes = [System.IO.File]::ReadAllBytes($interruptedRetiringClaim)
    try {
        $foreignClaim = Read-CpaStackJson -Path $interruptedRetiringClaim
        $foreignClaim.transactionId = '00000000000000000000000000000000'
        [System.IO.File]::WriteAllText(
            $interruptedRetiringClaim,
            ($foreignClaim | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false)
        )
        Protect-CpaStackSecretFile -Path $interruptedRetiringClaim
        $foreignClaimBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
        Assert-ThrowsMatch {
            [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
        } 'sidecar claim is foreign|invalid' 'Recovery rejects a foreign sidecar transaction claim'
        Assert-Equal $foreignClaimBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) 'Foreign sidecar rejection preserves the directory, claim, and journal evidence'
    } finally {
        [System.IO.File]::WriteAllBytes($interruptedRetiringClaim, $retiringClaimBytes)
        Protect-CpaStackSecretFile -Path $interruptedRetiringClaim
    }

    $interruptedJournalBytes = [System.IO.File]::ReadAllBytes($pendingJournal)
    try {
        $foreignJournal = Read-CpaStackJson -Path $pendingJournal
        $foreignJournal.canonicalCodexHome = Join-Path $temp 'foreign-codex-home'
        [System.IO.File]::WriteAllText(
            $pendingJournal,
            ($foreignJournal | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false)
        )
        Protect-CpaStackSecretFile -Path $pendingJournal
        $foreignJournalBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
        Assert-ThrowsMatch {
            [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
        } 'journal is invalid' 'Recovery rejects a journal bound to a foreign canonical CodexHome'
        Assert-Equal $foreignJournalBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) 'Foreign journal rejection performs zero slot, claim, or journal writes'
    } finally {
        [System.IO.File]::WriteAllBytes($pendingJournal, $interruptedJournalBytes)
        Protect-CpaStackSecretFile -Path $pendingJournal
    }

    $persistentRecovery = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'Changed' $persistentRecovery.outcome 'Update automatically recovers a persisted retiring transaction and continues'
    Assert-True ([bool]$persistentRecovery.recovered) 'Update reports that a persistent transaction was recovered'
    Assert-Equal $activeBeforePersistentRecovery (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $previous 'SKILL.md')).Hash 'Persistent recovery preserves the crash-time active skill as previous'
    Assert-False (Test-Path -LiteralPath $pendingJournal) 'Successful recovery removes the persistent journal'
    $persistentSlotsAfter = @(Get-ChildItem -LiteralPath $skillSlotRoot -Directory -Force | Where-Object { $_.Name -match '^(?:staging|retained|retiring)-' })
    Assert-Equal 0 $persistentSlotsAfter.Count 'Persistent recovery and retry leave no transient slot'

    $installedBeforeFailure = Get-TestTreeSnapshot -Root $installed
    $previousBeforeFailure = Get-TestTreeSnapshot -Root $previous
    [System.IO.File]::AppendAllText(
        (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\SKILL.md'),
        "`r`n# v2 failure-recovery fixture`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $unreferencedTransactionId = [guid]::NewGuid().ToString('N')
    $unreferencedRetained = Join-Path $skillSlotRoot ('retained-' + $unreferencedTransactionId)
    $unreferencedRetiring = Join-Path $skillSlotRoot ('retiring-' + $unreferencedTransactionId)
    Copy-Item -LiteralPath $previous -Destination $unreferencedRetained -Recurse
    Copy-Item -LiteralPath $installed -Destination $unreferencedRetiring -Recurse
    $unreferencedEvidence = Join-Path $unreferencedRetained 'user-evidence.txt'
    $unreferencedRetiringEvidence = Join-Path $unreferencedRetiring 'user-evidence.txt'
    [System.IO.File]::WriteAllText($unreferencedEvidence, 'never delete without a validated journal', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($unreferencedRetiringEvidence, 'never move without a validated journal', [System.Text.Encoding]::ASCII)
    $unreferencedCodexBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
    $unreferencedStackBefore = Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps
    $unreferencedStateBefore = Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData
    try {
        Assert-ThrowsMatch {
            [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
        } 'Unreferenced skill transaction artifacts require manual recovery|foreign or orphan sibling' 'Retained artifacts without a validated journal fail closed'
        Assert-Equal $unreferencedCodexBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) 'Unreferenced retained artifact and arbitrary user evidence are preserved byte-for-byte'
        Assert-Equal $unreferencedStackBefore (Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps) 'Unreferenced retained artifact rejection does not write the stack root'
        Assert-Equal $unreferencedStateBefore (Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData) 'Unreferenced retained artifact rejection does not rewrite the locator'
        Assert-True (Test-Path -LiteralPath $unreferencedEvidence -PathType Leaf) 'Unreferenced retained user evidence remains present'
        Assert-True (Test-Path -LiteralPath $unreferencedRetiringEvidence -PathType Leaf) 'Unreferenced retiring user evidence remains present'
    } finally {
        if (Test-Path -LiteralPath $unreferencedRetained) { Remove-TestPathWithRetry -Path $unreferencedRetained }
        if (Test-Path -LiteralPath $unreferencedRetiring) { Remove-TestPathWithRetry -Path $unreferencedRetiring }
    }
    $failureNeedle = '    Move-SkillDirectoryWithRetry -SourcePath $staging -SourceKind Staging -DestinationPath $installed -DestinationKind Installed'
    $installerText = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerText, [regex]::Escape($failureNeedle)).Count) 'Failure injection has one public transaction seam'
    $failureProbe = @'
    if ($env:CPA_STACK_TEST_FAIL_AFTER_SLOT_ROTATION -ceq '1') {
        throw 'synthetic v2 failure after slot rotation'
    }
'@
    $installerText = $installerText.Replace($failureNeedle, $failureProbe.TrimEnd() + [Environment]::NewLine + $failureNeedle)
    [System.IO.File]::WriteAllText($install, $installerText, [System.Text.UTF8Encoding]::new($false))
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_AFTER_SLOT_ROTATION', '1', 'Process')
        Assert-ThrowsMatch {
            [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
        } 'synthetic v2 failure after slot rotation' 'A post-rotation failure is surfaced after automatic recovery'
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_AFTER_SLOT_ROTATION', $null, 'Process')
    }
    Assert-Equal $installedBeforeFailure (Get-TestTreeSnapshot -Root $installed) 'Failure recovery restores the active installed slot exactly'
    Assert-Equal $previousBeforeFailure (Get-TestTreeSnapshot -Root $previous) 'Failure recovery restores the previous slot exactly'
    $transactionSlots = @(Get-ChildItem -LiteralPath $skillSlotRoot -Directory -Force | Where-Object { $_.Name -match '^(?:staging|retained|retiring)-' })
    Assert-Equal 0 $transactionSlots.Count 'Failure recovery leaves no transient transaction slot'

    $recoveredUpdate = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'Changed' $recoveredUpdate.outcome 'Retry commits the update after recovery'

    [System.IO.File]::AppendAllText(
        (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\SKILL.md'),
        "`r`n# v2 launcher-failure retry fixture`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Set-Content -LiteralPath $launcher -Value '# launcher failure drift fixture' -Encoding ASCII
    Protect-CpaStackSecretFile -Path $launcher
    $launcherFailureNeedle = '        $launcherSync = Sync-InstallerLauncherBootstrap -ControlRoot $registeredRoot'
    $installerBeforeLauncherFailure = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerBeforeLauncherFailure, [regex]::Escape($launcherFailureNeedle)).Count) 'Launcher failure injection has one synchronization seam'
    $launcherFailureProbe = @'
        if ($env:CPA_STACK_TEST_FAIL_LAUNCHER_SYNC -ceq '1') {
            throw 'synthetic v2 launcher synchronization failure'
        }
'@
    $installerBeforeLauncherFailure = $installerBeforeLauncherFailure.Replace(
        $launcherFailureNeedle,
        $launcherFailureProbe.TrimEnd() + [Environment]::NewLine + $launcherFailureNeedle
    )
    [System.IO.File]::WriteAllText($install, $installerBeforeLauncherFailure, [System.Text.UTF8Encoding]::new($false))
    $launcherFailureOutput = Join-Path $temp 'launcher-failure-output.json'
    $launcherFailureError = Join-Path $temp 'launcher-failure-error.txt'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_LAUNCHER_SYNC', '1', 'Process')
        $launcherFailure = Invoke-InstallProcessJson `
            -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot `
            -OutputPath $launcherFailureOutput -ErrorPath $launcherFailureError -Guard $guard
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_LAUNCHER_SYNC', $null, 'Process')
    }
    Assert-Equal 1 $launcherFailure.ExitCode 'Committed skill plus failed launcher synchronization exits nonzero'
    Assert-True ($null -ne $launcherFailure.Document) 'Committed launcher failure emits one JSON result'
    Assert-False ([bool]$launcherFailure.Document.success) 'Committed launcher failure cannot report success'
    Assert-Equal 'Failed' $launcherFailure.Document.outcome 'Committed launcher failure reports a failed outcome'
    Assert-True ([bool]$launcherFailure.Document.coreCommitted) 'Committed launcher failure reports that the skill slot is already durable'
    Assert-True ([bool]$launcherFailure.Document.updateAvailable) 'Committed launcher failure remains explicitly retryable'
    Assert-Equal 'launcherSync' $launcherFailure.Document.error.step 'Committed launcher failure identifies the failed step'
    $launcherFailureJournal = Read-CpaStackJson -Path $pendingJournal
    Assert-Equal 3 $launcherFailureJournal.schemaVersion 'Committed journal uses the bound installer schema'
    Assert-Equal ([System.IO.Path]::GetFullPath($codexHome).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$launcherFailureJournal.canonicalCodexHome).TrimEnd('\')) 'Committed journal binds canonical CodexHome'
    Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $codexHome 'skills')).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$launcherFailureJournal.canonicalSkillsRoot).TrimEnd('\')) 'Committed journal binds canonical skillsRoot'
    Assert-True ([bool]$launcherFailureJournal.requestedStackRootSpecified) 'Committed journal preserves the original explicit-root intent'
    Assert-Equal ([System.IO.Path]::GetFullPath($stackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$launcherFailureJournal.requestedStackRoot).TrimEnd('\')) 'Committed journal preserves the original explicit StackRoot'
    Assert-True ([bool]$launcherFailureJournal.launcherIntent) 'Committed journal preserves launcher synchronization intent'
    Assert-True ([bool]$launcherFailureJournal.registrationIntent) 'Committed journal preserves registration verification intent'
    Assert-Equal ([System.IO.Path]::GetFullPath($installed).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$launcherFailureJournal.target.path).TrimEnd('\')) 'Committed journal binds the canonical target slot'
    Assert-True ([string]$launcherFailureJournal.target.markerSha256 -match '^[0-9A-F]{64}$') 'Committed journal binds the target ownership marker hash'
    Assert-True ([string]$launcherFailureJournal.target.manifestSha256 -match '^[0-9A-F]{64}$') 'Committed journal binds the target manifest hash'
    Assert-False ([bool]$launcherFailureJournal.postCommit.launcherVerified) 'Failed launcher remains an explicit journal todo'
    $launcherFailureJournalWrite = $pendingJournal + '.write'
    Copy-Item -LiteralPath $pendingJournal -Destination $launcherFailureJournalWrite
    Protect-CpaStackSecretFile -Path $launcherFailureJournalWrite
    $launcherFailureCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-True ([bool]$launcherFailureCheck.recoveryPending) 'Check reports the retained committed installer journal after launcher failure'
    Assert-True ([bool]$launcherFailureCheck.updateAvailable) 'Check reports the failed launcher synchronization as pending work'
    Assert-Equal 'Drifted' $launcherFailureCheck.launcherState 'Check preserves the observable launcher drift after failure'
    Assert-False ([bool]$launcherFailureCheck.registrationRequired) 'Launcher failure Check does not invent registration drift'
    $conflictingCommittedRoot = Join-Path $stackParent 'conflicting committed retry root'
    $conflictCodexBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
    $conflictStackBefore = Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps
    $conflictStateHomeBefore = Get-TestTreeSnapshot -Root $fixture.LocalAppData -IgnoreDirectoryTimestamps
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $conflictingCommittedRoot)
    } 'different explicit StackRoot' 'Conflicting explicit root cannot redirect a committed journal'
    Assert-Equal '<missing>' (Get-TestTreeSnapshot -Root $conflictingCommittedRoot) 'Conflicting committed retry does not create or preinitialize its requested root'
    Assert-Equal $conflictCodexBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) 'Conflicting committed retry leaves CodexHome and journal byte-identical'
    Assert-Equal $conflictStackBefore (Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps) 'Conflicting committed retry leaves the original target root byte-identical'
    Assert-Equal $conflictStateHomeBefore (Get-TestTreeSnapshot -Root $fixture.LocalAppData -IgnoreDirectoryTimestamps) 'Conflicting committed retry leaves locator state byte-identical'
    $claimOnlyRetained = Join-Path $skillSlotRoot ('retained-' + [string]$launcherFailureJournal.transactionId)
    $claimOnlyRetainedClaim = $claimOnlyRetained + '.claim.json'
    Assert-True (Test-Path -LiteralPath $claimOnlyRetained -PathType Container) 'Committed cleanup fixture starts with the journal-bound retained directory'
    Assert-True (Test-Path -LiteralPath $claimOnlyRetainedClaim -PathType Leaf) 'Committed cleanup fixture starts with the journal-bound retained claim'
    Remove-TestPathWithRetry -Path $claimOnlyRetained
    $launcherFailureRetry = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $null
    Assert-Equal 'Changed' $launcherFailureRetry.outcome 'Retry without StackRoot recovers the committed intent and synchronizes the launcher'
    Assert-Equal 'Current' $launcherFailureRetry.launcherState 'Launcher retry converges the launcher contract'
    Assert-False (Test-Path -LiteralPath $pendingJournal) 'Successful launcher retry removes the committed installer journal'
    Assert-False (Test-Path -LiteralPath $launcherFailureJournalWrite) 'Recovery removes a validated same-transaction journal write residue'
    Assert-False (Test-Path -LiteralPath $claimOnlyRetainedClaim) 'Recovery removes a validated claim-only cleanup residue before deleting its journal'

    [System.IO.File]::AppendAllText(
        (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\SKILL.md'),
        "`r`n# v2 registration-failure retry fixture`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $otherRegisteredRoot = Join-Path $stackParent 'other registered root'
    Set-CpaStackRegisteredRoot -ControlRoot $otherRegisteredRoot
    $registrationFailureNeedle = '        Set-CpaStackRegisteredRoot -ControlRoot $registeredRoot'
    $installerBeforeRegistrationFailure = [System.IO.File]::ReadAllText($install, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($installerBeforeRegistrationFailure, [regex]::Escape($registrationFailureNeedle)).Count) 'Registration failure injection has one synchronization seam'
    $registrationFailureProbe = @'
        if ($env:CPA_STACK_TEST_FAIL_REGISTRATION -ceq '1') {
            throw 'synthetic v2 registration synchronization failure'
        }
'@
    $installerBeforeRegistrationFailure = $installerBeforeRegistrationFailure.Replace(
        $registrationFailureNeedle,
        $registrationFailureProbe.TrimEnd() + [Environment]::NewLine + $registrationFailureNeedle
    )
    [System.IO.File]::WriteAllText($install, $installerBeforeRegistrationFailure, [System.Text.UTF8Encoding]::new($false))
    $registrationFailureOutput = Join-Path $temp 'registration-failure-output.json'
    $registrationFailureError = Join-Path $temp 'registration-failure-error.txt'
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_REGISTRATION', '1', 'Process')
        $registrationFailure = Invoke-InstallProcessJson `
            -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot `
            -OutputPath $registrationFailureOutput -ErrorPath $registrationFailureError -Guard $guard
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_REGISTRATION', $null, 'Process')
    }
    Assert-Equal 1 $registrationFailure.ExitCode 'Committed skill plus failed root registration exits nonzero'
    Assert-True ($null -ne $registrationFailure.Document) 'Committed registration failure emits one JSON result'
    Assert-False ([bool]$registrationFailure.Document.success) 'Committed registration failure cannot report success'
    Assert-Equal 'Failed' $registrationFailure.Document.outcome 'Committed registration failure reports a failed outcome'
    Assert-True ([bool]$registrationFailure.Document.coreCommitted) 'Committed registration failure reports that the skill slot is already durable'
    Assert-True ([bool]$registrationFailure.Document.updateAvailable) 'Committed registration failure remains explicitly retryable'
    Assert-Equal 'registration' $registrationFailure.Document.error.step 'Committed registration failure identifies the failed step'
    $registrationFailureCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-True ([bool]$registrationFailureCheck.recoveryPending) 'Check reports the retained committed installer journal after registration failure'
    Assert-True ([bool]$registrationFailureCheck.updateAvailable) 'Check reports the failed registration synchronization as pending work'
    Assert-True ([bool]$registrationFailureCheck.registrationRequired) 'Check identifies root registration as the remaining repair'
    Assert-Equal 'Current' $registrationFailureCheck.launcherState 'Registration failure does not regress the synchronized launcher'
    $registrationFailureJournal = Read-CpaStackJson -Path $pendingJournal
    Assert-True ([bool]$registrationFailureJournal.postCommit.launcherVerified) 'Registration failure journal preserves completed launcher verification'
    Assert-False ([bool]$registrationFailureJournal.postCommit.registrationVerified) 'Registration failure remains an explicit journal todo'
    $registrationFailureRetry = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $null
    Assert-Equal 'Changed' $registrationFailureRetry.outcome 'Retry without StackRoot recovers the committed intent and repairs root registration'
    Assert-True ([bool]$registrationFailureRetry.registrationUpdated) 'Registration retry reports the completed locator write'
    Assert-False (Test-Path -LiteralPath $pendingJournal) 'Successful registration retry removes the committed installer journal'

    $previousBeforeLauncherRepair = Get-TestTreeSnapshot -Root $previous
    Set-Content -LiteralPath $launcher -Value '# drifted launcher fixture' -Encoding ASCII
    Protect-CpaStackSecretFile -Path $launcher
    $foreignLauncherResidue = $launcher + '.tmp-' + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($foreignLauncherResidue, 'foreign launcher residue', [System.Text.Encoding]::ASCII)
    Protect-CpaStackSecretFile -Path $foreignLauncherResidue
    $foreignLauncherCodexBefore = Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps
    $foreignLauncherStackBefore = Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps
    $foreignLauncherStateBefore = Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot)
    } 'foreign|residue|artifact|unexpected' 'Installer rejects an unbound launcher temp residue before any managed write'
    Assert-Equal $foreignLauncherCodexBefore (Get-TestTreeSnapshot -Root $codexHome -IgnoreDirectoryTimestamps) 'Foreign launcher residue leaves CodexHome unchanged'
    Assert-Equal $foreignLauncherStackBefore (Get-TestTreeSnapshot -Root $stackRoot -IgnoreDirectoryTimestamps) 'Foreign launcher residue and drifted launcher remain byte-identical'
    Assert-Equal $foreignLauncherStateBefore (Get-TestLocatorSnapshot -LocalAppDataRoot $fixture.LocalAppData) 'Foreign launcher residue leaves locator state unchanged'
    Remove-Item -LiteralPath $foreignLauncherResidue -Force

    $launcherWriteArtifact = $launcher + '.cpa-stack-updater.write'
    [System.IO.File]::WriteAllText($launcherWriteArtifact, $launcherText, [System.Text.UTF8Encoding]::new($false))
    Protect-CpaStackSecretFile -Path $launcherWriteArtifact
    $codexBeforeDriftCheck = Get-TestTreeSnapshot -Root $codexHome
    $stackBeforeDriftCheck = Get-TestTreeSnapshot -Root $stackRoot
    $driftCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-True ([bool]$driftCheck.updateAvailable) 'Check reports an available launcher-only repair'
    Assert-Equal 'RecoveryPending' $driftCheck.launcherState 'Check reports a validated fixed launcher write artifact without consuming it'
    Assert-Equal $codexBeforeDriftCheck (Get-TestTreeSnapshot -Root $codexHome) 'Drift Check leaves CodexHome unchanged'
    Assert-Equal $stackBeforeDriftCheck (Get-TestTreeSnapshot -Root $stackRoot) 'Drift Check leaves StackRoot unchanged'
    $repair = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'Changed' $repair.outcome 'Update repairs a drifted launcher contract'
    Assert-Equal 'Current' $repair.launcherState 'Launcher repair reports the current contract'
    Assert-False (Test-Path -LiteralPath $launcherWriteArtifact) 'Launcher repair consumes the fixed intent-bound write artifact'
    Assert-Equal $previousBeforeLauncherRepair (Get-TestTreeSnapshot -Root $previous) 'Launcher-only repair does not rotate skill slots'

    Set-CpaStackRegisteredRoot -ControlRoot $otherRegisteredRoot
    $fixtureLocator = Get-CpaStackRootLocatorPath
    $locatorHashBeforeCheck = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureLocator).Hash
    $locatorTimeBeforeCheck = (Get-Item -Force -LiteralPath $fixtureLocator).LastWriteTimeUtc.Ticks
    $registrationCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-True ([bool]$registrationCheck.updateAvailable) 'Check reports an available registration-only repair'
    Assert-Equal $locatorHashBeforeCheck (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureLocator).Hash 'Registration Check leaves locator bytes unchanged'
    Assert-Equal $locatorTimeBeforeCheck (Get-Item -Force -LiteralPath $fixtureLocator).LastWriteTimeUtc.Ticks 'Registration Check leaves locator mtime unchanged'
    $previousBeforeRegistrationRepair = Get-TestTreeSnapshot -Root $previous
    $registrationRepair = Invoke-InstallJson -Script $install -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'Changed' $registrationRepair.outcome 'Update repairs registration without rotating the skill'
    Assert-True ([bool]$registrationRepair.registrationUpdated) 'Registration-only Update reports the locator write'
    Assert-Equal $previousBeforeRegistrationRepair (Get-TestTreeSnapshot -Root $previous) 'Registration-only repair preserves the rollback slot'
    Assert-Equal ([System.IO.Path]::GetFullPath($stackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string](Read-CpaStackJson -Path $fixtureLocator).root).TrimEnd('\')) 'Registration-only repair restores the explicit StackRoot'

    $codexBeforeCheck = Get-TestTreeSnapshot -Root $codexHome
    $stackBeforeCheck = Get-TestTreeSnapshot -Root $stackRoot
    $finalCheck = Invoke-InstallJson -Script $install -Action Check -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 'NoChange' $finalCheck.outcome 'Final Check remains observational'
    Assert-False ([bool]$finalCheck.updateAvailable) 'Final Check sees the installed source manifest'
    Assert-Equal 'Current' $finalCheck.launcherState 'Final Check sees the current launcher'
    Assert-Equal $codexBeforeCheck (Get-TestTreeSnapshot -Root $codexHome) 'Check leaves CodexHome byte- and timestamp-identical'
    Assert-Equal $stackBeforeCheck (Get-TestTreeSnapshot -Root $stackRoot) 'Check leaves StackRoot byte- and timestamp-identical'
} finally {
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_AFTER_SLOT_ROTATION', $previousFailurePoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_DELAY_BEFORE_INSTALL_LOCK', $previousDelayPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_RETIRE', $previousHoldPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_READY_PATH', $previousReadyPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_LAUNCHER_SYNC', $previousLauncherFailurePoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_REGISTRATION', $previousRegistrationFailurePoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_MARKER', $previousLegacyMarkerHoldPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_LEGACY_MARKER_READY_PATH', $previousLegacyMarkerReadyPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_JOURNAL_RECOVERY', $previousJournalRecoveryHoldPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_JOURNAL_RECOVERY_READY_PATH', $previousJournalRecoveryReadyPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_HOLD_AFTER_LEGACY_PREVIOUS_RELOCATION', $previousLegacyRelocationHoldPoint, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_LEGACY_PREVIOUS_RELOCATION_READY_PATH', $previousLegacyRelocationReadyPoint, 'Process')
    $productionGuardError = $null
    if ($null -ne $guard) {
        try {
            $afterListeners = @(Get-CpaStackListenerSnapshot)
            $comparison = Compare-CpaStackProductionListenerSnapshot -Guard $guard -AfterSnapshot $afterListeners
            Assert-True ([bool]$comparison.Unchanged) 'Installer tests leave every protected listener address, port, PID, and executable path unchanged'
            Assert-Equal $productionExecutableBefore (Get-ProductionExecutableSnapshot -ListenerSnapshot $afterListeners -ProtectedPort $guard.ProtectedPorts) 'Installer tests leave protected process executable hashes unchanged'
            Assert-Equal $productionControlFilesBefore (Get-ProductionControlFileSnapshot -ProductionRoot $productionRoots) 'Installer tests leave production marker, current state, launcher, and root locator unchanged'
        } catch {
            $productionGuardError = $_
        } finally {
            Close-CpaStackProductionGuard -Guard $guard
        }
    }
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
    if (Test-Path -LiteralPath $stackParent) { Remove-TestPathWithRetry -Path $stackParent }
    if ($null -ne $productionGuardError) { throw $productionGuardError }
}

'Install v2 tests passed.'
