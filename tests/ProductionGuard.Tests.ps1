$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repo 'tools\CpaStack.ProductionGuard.psm1'
Import-Module $modulePath -Force

function New-TestOwnedLoopbackListener {
    param([int[]]$ExcludedPort)

    $excluded = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($port in @($ExcludedPort)) { [void]$excluded.Add([int]$port) }
    $random = [System.Random]::new(([BitConverter]::ToInt32([guid]::NewGuid().ToByteArray(), 0) -band 0x7fffffff))
    for ($attempt = 0; $attempt -lt 512; $attempt++) {
        $candidate = $random.Next(49152, 65536)
        if ($excluded.Contains($candidate)) { continue }
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidate)
        $listener.ExclusiveAddressUse = $true
        try {
            $listener.Start()
            return ,$listener
        } catch [System.Net.Sockets.SocketException] {
            $listener.Stop()
        }
    }
    throw 'Could not open a safe test-owned loopback listener.'
}

function Start-RegistrationGatedTestProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $readyPath = Join-Path $Root ($Name + '.ready')
    $goPath = Join-Path $Root ($Name + '.go')
    foreach ($path in @($readyPath, $goPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $readyBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($readyPath))
    $goBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($goPath))
    $command = @"
`$readyPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$readyBase64'))
`$goPath = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$goBase64'))
[System.IO.File]::WriteAllText(`$readyPath, [string]`$PID, [System.Text.Encoding]::ASCII)
`$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath `$goPath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge `$deadline) { exit 0 }
    Start-Sleep -Milliseconds 20
}
Start-Sleep -Seconds 30
"@
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process `
        -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
        -WindowStyle Hidden `
        -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            throw "Registration-gated process did not reach its ready state: $Name"
        }
        return [pscustomobject]@{
            Process = $process
            GoPath = $goPath
        }
    } catch {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
        throw
    }
}

function Release-RegistrationGatedTestProcess {
    param([Parameter(Mandatory = $true)]$Launch)

    [System.IO.File]::WriteAllText($Launch.GoPath, 'go', [System.Text.Encoding]::ASCII)
}

function Write-TestProductionRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$StateHome,
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$CpaPort = 52131,
        [int]$ManagerPort = 52132
    )

    New-Item -ItemType Directory -Force -Path $StateHome, (Join-Path $Root 'config') | Out-Null
    [ordered]@{
        schemaVersion = 1
        root = $Root
        updatedAt = '2026-01-01T00:00:00Z'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StateHome 'root.json') -Encoding UTF8
    @"
@{
    Cpa = @{ Port = $CpaPort }
    Manager = @{ Port = $ManagerPort }
}
"@ | Set-Content -LiteralPath (Join-Path $Root 'config\stack.psd1') -Encoding UTF8
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-production-guard-' + [guid]::NewGuid().ToString('N'))
try {
    $absentStateHome = Join-Path $temp 'registration-absent'
    $absentRegistration = Get-CpaStackProductionRegistration `
        -ProductionStateHome $absentStateHome `
        -EnvironmentRoot ''
    Assert-False ([bool]$absentRegistration.Registered) 'A proven-absent locator reports no registered production root'
    Assert-Equal 0 @($absentRegistration.Roots).Count 'A proven-absent locator protects no discovered root'
    foreach ($permanentPort in @(8317, 8318, 18317, 18318)) {
        Assert-True ($permanentPort -in @($absentRegistration.ProtectedPorts)) "Permanent production port $permanentPort remains protected without a locator"
    }

    $registrationStateHome = Join-Path $temp 'registration-valid'
    $registrationRoot = Join-Path $temp 'registered-production-root'
    Write-TestProductionRegistration `
        -StateHome $registrationStateHome `
        -Root $registrationRoot `
        -CpaPort 52131 `
        -ManagerPort 52132
    $registration = Get-CpaStackProductionRegistration `
        -ProductionStateHome $registrationStateHome `
        -EnvironmentRoot ''
    Assert-True ([bool]$registration.Registered) 'A valid locator reports a registered production root'
    Assert-Equal ([System.IO.Path]::GetFullPath($registrationRoot).TrimEnd('\')) $registration.Roots[0] 'The registered production root is normalized'
    foreach ($protectedPort in @(8317, 8318, 18317, 18318, 52131, 52132)) {
        Assert-True ($protectedPort -in @($registration.ProtectedPorts)) "Registered production discovery protects port $protectedPort"
    }

    $environmentRegistration = Get-CpaStackProductionRegistration `
        -ProductionStateHome $absentStateHome `
        -EnvironmentRoot $registrationRoot
    Assert-True ([bool]$environmentRegistration.Registered) 'CPA_STACK_ROOT prevents a missing locator from being treated as no production registration'
    Assert-Equal $registration.Roots[0] $environmentRegistration.Roots[0] 'CPA_STACK_ROOT is normalized through the same protected-root path'

    Set-Content -LiteralPath (Join-Path $registrationStateHome 'root.json') -Value '{' -Encoding UTF8
    Assert-ThrowsMatch {
        Get-CpaStackProductionRegistration `
            -ProductionStateHome $registrationStateHome `
            -EnvironmentRoot ''
    } 'production root locator.*could not be parsed' 'A malformed production locator blocks tests instead of failing open'

    Write-TestProductionRegistration -StateHome $registrationStateHome -Root $registrationRoot
    Set-Content -LiteralPath (Join-Path $registrationRoot 'config\stack.psd1') -Value '@{ Cpa = ' -Encoding UTF8
    Assert-ThrowsMatch {
        Get-CpaStackProductionRegistration `
            -ProductionStateHome $registrationStateHome `
            -EnvironmentRoot ''
    } 'production stack config.*could not be parsed' 'A malformed registered stack config blocks tests instead of losing custom ports'

    Write-TestProductionRegistration -StateHome $registrationStateHome -Root $registrationRoot
    Remove-Item -LiteralPath (Join-Path $registrationRoot 'config\stack.psd1') -Force
    Assert-ThrowsMatch {
        Get-CpaStackProductionRegistration `
            -ProductionStateHome $registrationStateHome `
            -EnvironmentRoot ''
    } 'production stack config is missing' 'A registered root without stack config blocks tests because its ports are unknown'

    Write-TestProductionRegistration -StateHome $registrationStateHome -Root $registrationRoot -CpaPort 0
    Assert-ThrowsMatch {
        Get-CpaStackProductionRegistration `
            -ProductionStateHome $registrationStateHome `
            -EnvironmentRoot ''
    } 'invalid Cpa.Port' 'An invalid registered production port blocks tests instead of being silently omitted'

    $staleStateHome = Join-Path $temp 'registration-stale'
    $staleRoot = Join-Path $temp 'missing-registered-root'
    New-Item -ItemType Directory -Force -Path $staleStateHome | Out-Null
    [ordered]@{ schemaVersion = 1; root = $staleRoot } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $staleStateHome 'root.json') -Encoding UTF8
    Assert-ThrowsMatch {
        Get-CpaStackProductionRegistration `
            -ProductionStateHome $staleStateHome `
            -EnvironmentRoot ''
    } 'registered production root does not exist' 'A stale locator is not mistaken for proven absence'

    $nonFileStateHome = Join-Path $temp 'registration-non-file'
    New-Item -ItemType Directory -Force -Path (Join-Path $nonFileStateHome 'root.json') | Out-Null
    Assert-ThrowsMatch {
        Get-CpaStackProductionRegistration `
            -ProductionStateHome $nonFileStateHome `
            -EnvironmentRoot ''
    } 'production root locator is not a file' 'A non-file locator path is not mistaken for proven absence'

    foreach ($entryPoint in @('tools\Test-All.ps1', 'tests\TransactionIntegration.Tests.ps1')) {
        $entryPointSource = Get-Content -LiteralPath (Join-Path $repo $entryPoint) -Raw
        Assert-True ($entryPointSource -match 'Get-CpaStackProductionRegistration') "$entryPoint uses fail-closed production registration discovery"
    }

    $productionRoot = Join-Path $temp 'production-root'
    $productionStateHome = Join-Path $temp 'production-state'
    $testRoot = Join-Path $temp 'test-root'
    $testStateHome = Join-Path $temp 'test-state'
    $customProductionPort = 47231
    $customProductionProcessId = 42421
    New-Item -ItemType Directory -Force -Path $productionRoot, $productionStateHome | Out-Null
    $baseline = @(
        [pscustomobject]@{
            LocalAddress = '127.0.0.1'
            LocalPort = $customProductionPort
            OwningProcess = $customProductionProcessId
            ExecutablePath = 'C:\fixtures\formal-cpa.exe'
        }
    )

    $productionAlias = Join-Path $temp 'production-root-alias'
    try {
        try {
            [void](New-Item -ItemType Junction -Path $productionAlias -Target $productionRoot -ErrorAction Stop)
            $productionAliasCreated = $true
        } catch {
            $productionAliasCreated = $false
            Write-Host "Production registration junction regression skipped: $($_.Exception.Message)"
        }
        if ($productionAliasCreated) {
            Assert-ThrowsMatch {
                New-CpaStackProductionGuard `
                    -ProductionRoot $productionAlias `
                    -ProductionStateHome $productionStateHome `
                    -ListenerSnapshot @()
            } 'reparse point' 'Production guard rejects a production root registered through a junction'
        }
    } finally {
        if (Test-Path -LiteralPath $productionAlias) {
            Remove-Item -LiteralPath $productionAlias -Force
        }
    }

    $guard = New-CpaStackProductionGuard `
        -ProductionRoot $productionRoot `
        -ProductionStateHome $productionStateHome `
        -ProductionPort $customProductionPort `
        -ProductionProcessId $customProductionProcessId `
        -ListenerSnapshot $baseline
    try {
        foreach ($protectedPort in @(8317, 8318, 18317, 18318, $customProductionPort)) {
            Assert-ThrowsMatch {
                Assert-CpaStackTestIsolation `
                    -Guard $guard `
                    -TestRoot $testRoot `
                    -TestStateHome $testStateHome `
                    -TestPort $protectedPort
            } 'protected port' "Production guard rejects protected port $protectedPort"
        }

        Assert-ThrowsMatch {
            Assert-CpaStackTestIsolation `
                -Guard $guard `
                -TestRoot $testRoot `
                -TestStateHome $testStateHome `
                -TestProcessId $customProductionProcessId
        } 'protected process' 'Production guard rejects a caller-supplied production process id'

        foreach ($overlappingRoot in @(
            $productionRoot,
            (Join-Path $productionRoot 'nested-test'),
            (Split-Path -Parent $productionRoot)
        )) {
            Assert-ThrowsMatch {
                Assert-CpaStackTestIsolation `
                    -Guard $guard `
                    -TestRoot $overlappingRoot `
                    -TestStateHome $testStateHome
            } 'overlaps protected path' "Production guard rejects overlapping test root $overlappingRoot"
        }

        foreach ($overlappingStateHome in @(
            $productionStateHome,
            (Join-Path $productionStateHome 'nested-test-state'),
            (Split-Path -Parent $productionStateHome)
        )) {
            Assert-ThrowsMatch {
                Assert-CpaStackTestIsolation `
                    -Guard $guard `
                    -TestRoot $testRoot `
                    -TestStateHome $overlappingStateHome
            } 'overlaps protected path' "Production guard rejects overlapping test state home $overlappingStateHome"
        }

        $junctionParent = Join-Path $temp 'junction-parent'
        $junctionPath = Join-Path $junctionParent 'production-alias'
        New-Item -ItemType Directory -Force -Path $junctionParent | Out-Null
        try {
            try {
                [void](New-Item -ItemType Junction -Path $junctionPath -Target $productionRoot -ErrorAction Stop)
                $junctionCreated = $true
            } catch {
                $junctionCreated = $false
                Write-Host "Junction isolation regression skipped: $($_.Exception.Message)"
            }
            if ($junctionCreated) {
                Assert-ThrowsMatch {
                    Assert-CpaStackTestIsolation `
                        -Guard $guard `
                        -TestRoot (Join-Path $junctionPath 'nested-test') `
                        -TestStateHome $testStateHome
                } 'reparse point' 'Production guard rejects a test root traversing a junction into the production root'

                Assert-ThrowsMatch {
                    Assert-CpaStackTestIsolation `
                        -Guard $guard `
                        -TestRoot $testRoot `
                        -TestStateHome (Join-Path $junctionPath 'nested-state')
                } 'reparse point' 'Production guard rejects a test state home traversing a junction into the production root'
            }
        } finally {
            if (Test-Path -LiteralPath $junctionPath) {
                Remove-Item -LiteralPath $junctionPath -Force
            }
        }

        $shortAliasRoot = 'C:\PROGRA~1'
        if (Test-Path -LiteralPath $shortAliasRoot -PathType Container) {
            $shortAliasItem = Get-Item -LiteralPath $shortAliasRoot -Force
            if (-not [string]::Equals($shortAliasRoot, [string]$shortAliasItem.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
                Assert-ThrowsMatch {
                    Assert-CpaStackTestIsolation `
                        -Guard $guard `
                        -TestRoot (Join-Path $shortAliasRoot 'cpa-guard-test-never-create') `
                        -TestStateHome $testStateHome
                } 'alias|canonical' 'Production guard rejects an 8.3 alias in an existing test path chain'
            }
        }

        $safeIsolation = Assert-CpaStackTestIsolation `
            -Guard $guard `
            -TestRoot $testRoot `
            -TestStateHome $testStateHome `
            -TestPort 47232 `
            -TestProcessId 42422
        Assert-True ([bool]$safeIsolation.Safe) 'Disjoint test root, state, port, and process pass the production guard'

        $occupiedListener = New-TestOwnedLoopbackListener -ExcludedPort @(8317, 8318, 18317, 18318, $customProductionPort)
        try {
            $occupiedPort = ([System.Net.IPEndPoint]$occupiedListener.LocalEndpoint).Port
            $portPlan = New-CpaStackTestPortPlan `
                -Guard $guard `
                -Name @('CpaFormal', 'CpaCandidate', 'ManagerFormal', 'ManagerCandidate')
        } finally {
            $occupiedListener.Stop()
        }

        Assert-Equal '127.0.0.1' $portPlan.BindAddress 'Test port plan is always loopback-only'
        Assert-Equal 4 @($portPlan.AllPorts).Count 'Test port plan returns one port per requested role'
        Assert-Equal 4 @($portPlan.AllPorts | Sort-Object -Unique).Count 'Test port plan ports are distinct'
        foreach ($allocatedPort in @($portPlan.AllPorts)) {
            Assert-True ($allocatedPort -ge 49152 -and $allocatedPort -le 65535) "Test port $allocatedPort is in the high dynamic range"
            Assert-False ($allocatedPort -in @(8317, 8318, 18317, 18318, $customProductionPort, $occupiedPort)) "Test port $allocatedPort excludes protected and active listeners"
        }
        Assert-Equal $portPlan.Ports.CpaFormal $portPlan.AllPorts[0] 'Named test port plan preserves requested role order'

        $unchangedSnapshot = Compare-CpaStackProductionListenerSnapshot -Guard $guard -AfterSnapshot $baseline
        Assert-True ([bool]$unchangedSnapshot.Unchanged) 'Identical protected listener metadata compares unchanged'
        Assert-Equal 0 @($unchangedSnapshot.Added).Count 'Identical listener snapshot adds nothing'
        Assert-Equal 0 @($unchangedSnapshot.Removed).Count 'Identical listener snapshot removes nothing'

        $afterWithUnprotectedListener = @($baseline) + @(
            [pscustomobject]@{
                LocalAddress = '127.0.0.1'
                LocalPort = 47232
                OwningProcess = 42422
                ExecutablePath = 'C:\fixtures\test-only.exe'
            }
        )
        $unprotectedDifference = Compare-CpaStackProductionListenerSnapshot -Guard $guard -AfterSnapshot $afterWithUnprotectedListener
        Assert-True ([bool]$unprotectedDifference.Unchanged) 'Unprotected test listeners do not alter the production comparison'

        $changedBaseline = @(
            [pscustomobject]@{
                LocalAddress = '127.0.0.1'
                LocalPort = $customProductionPort
                OwningProcess = ($customProductionProcessId + 1)
                ExecutablePath = 'C:\fixtures\replacement.exe'
            }
        )
        $changedSnapshot = Compare-CpaStackProductionListenerSnapshot -Guard $guard -AfterSnapshot $changedBaseline
        Assert-False ([bool]$changedSnapshot.Unchanged) 'Changed protected listener owner is detected from metadata'
        Assert-Equal 1 @($changedSnapshot.Added).Count 'Changed protected listener produces one added metadata record'
        Assert-Equal 1 @($changedSnapshot.Removed).Count 'Changed protected listener produces one removed metadata record'

        $liveSnapshot = @(Get-CpaStackListenerSnapshot)
        foreach ($listenerMetadata in $liveSnapshot) {
            Assert-True ($null -ne $listenerMetadata.PSObject.Properties['LocalAddress']) 'Live listener snapshot exposes local address metadata'
            Assert-True ($null -ne $listenerMetadata.PSObject.Properties['LocalPort']) 'Live listener snapshot exposes local port metadata'
            Assert-True ($null -ne $listenerMetadata.PSObject.Properties['OwningProcess']) 'Live listener snapshot exposes owning process metadata'
            Assert-True ($null -ne $listenerMetadata.PSObject.Properties['ExecutablePath']) 'Live listener snapshot exposes executable path metadata'
        }

        $staleIdentityGuard = New-CpaStackProductionGuard -ListenerSnapshot @()
        $staleIdentityProcess = $null
        $replacementProcess = $null
        $replacementLaunch = $null
        try {
            $staleIdentityLaunch = Start-RegistrationGatedTestProcess -Root $temp -Name 'stale-identity'
            $staleIdentityProcess = $staleIdentityLaunch.Process
            [void]$staleIdentityProcess.Handle
            $staleIdentityTicks = [long](($staleIdentityProcess.StartTime.ToUniversalTime()).Ticks)
            $staleIdentityPath = [string]$staleIdentityProcess.MainModule.FileName
            $staleIdentityProcess.Kill()
            [void]$staleIdentityProcess.WaitForExit(5000)

            $replacementLaunch = Start-RegistrationGatedTestProcess -Root $temp -Name 'replacement-identity'
            $replacementProcess = $replacementLaunch.Process
            [void]$staleIdentityGuard.RegisteredProcesses.Add([pscustomobject]@{
                ProcessId = [int]$replacementProcess.Id
                StartTimeUtcTicks = $staleIdentityTicks
                ExecutablePath = $staleIdentityPath
                Process = $staleIdentityProcess
            })

            $replacementRegistration = Register-CpaStackTestProcess -Guard $staleIdentityGuard -Process $replacementProcess
            Release-RegistrationGatedTestProcess -Launch $replacementLaunch
            Assert-False ([bool]$replacementRegistration.AlreadyRegistered) 'An exited stale PID record is removed before the replacement process is registered'
            Assert-Equal 1 @($staleIdentityGuard.RegisteredProcesses).Count 'Stale process registration is replaced instead of accumulated'
            Assert-Equal ([long](($replacementProcess.StartTime.ToUniversalTime()).Ticks)) ([long]$staleIdentityGuard.RegisteredProcesses[0].StartTimeUtcTicks) 'Replacement registration records the exact process start time'

            $duplicateRegistration = Register-CpaStackTestProcess -Guard $staleIdentityGuard -Process $replacementProcess
            Assert-True ([bool]$duplicateRegistration.AlreadyRegistered) 'The exact same PID, start time, and executable identity is idempotently registered'
            Assert-Equal 1 @($staleIdentityGuard.RegisteredProcesses).Count 'Idempotent registration keeps one fixed process handle'

            Close-CpaStackProductionGuard -Guard $staleIdentityGuard -WaitMilliseconds 10000
            Assert-True ($replacementProcess.WaitForExit(10000)) 'Closing the stale-record guard terminates the replacement process'
        } finally {
            Close-CpaStackProductionGuard -Guard $staleIdentityGuard
            foreach ($ownedProcess in @($replacementProcess, $staleIdentityProcess)) {
                if ($null -eq $ownedProcess) { continue }
                try {
                    if (-not $ownedProcess.HasExited) {
                        $ownedProcess.Kill()
                        [void]$ownedProcess.WaitForExit(5000)
                    }
                } catch [System.ObjectDisposedException] {
                } catch [System.InvalidOperationException] {
                } finally {
                    $ownedProcess.Dispose()
                }
            }
        }

        $conflictGuard = New-CpaStackProductionGuard -ListenerSnapshot @()
        $conflictProcess = $null
        $conflictTrackedProcess = $null
        try {
            $conflictLaunch = Start-RegistrationGatedTestProcess -Root $temp -Name 'conflicting-identity'
            $conflictProcess = $conflictLaunch.Process
            $conflictTrackedProcess = Get-Process -Id ([int]$conflictProcess.Id) -ErrorAction Stop
            [void]$conflictTrackedProcess.Handle
            [void]$conflictGuard.RegisteredProcesses.Add([pscustomobject]@{
                ProcessId = [int]$conflictProcess.Id
                StartTimeUtcTicks = ([long](($conflictProcess.StartTime.ToUniversalTime()).Ticks) + 1L)
                ExecutablePath = [string]$conflictProcess.MainModule.FileName
                Process = $conflictTrackedProcess
            })
            Assert-ThrowsMatch {
                Register-CpaStackTestProcess -Guard $conflictGuard -Process $conflictProcess
            } 'conflicting stored identity' 'An active same-PID record with a different identity fails closed'
            Assert-Equal 1 @($conflictGuard.RegisteredProcesses).Count 'An active identity conflict is retained for guard cleanup and investigation'
            $conflictGuard.RegisteredProcesses.RemoveAt(0)
            $conflictTrackedProcess.Dispose()
            $conflictTrackedProcess = $null
        } finally {
            Close-CpaStackProductionGuard -Guard $conflictGuard
            if ($null -ne $conflictTrackedProcess) { $conflictTrackedProcess.Dispose() }
            if ($null -ne $conflictProcess) {
                if (-not $conflictProcess.HasExited) {
                    $conflictProcess.Kill()
                    [void]$conflictProcess.WaitForExit(5000)
                }
                $conflictProcess.Dispose()
            }
        }

        $guardedLaunch = Start-RegistrationGatedTestProcess -Root $temp -Name 'guarded-process'
        $guardedProcess = $guardedLaunch.Process
        try {
            $registration = Register-CpaStackTestProcess -Guard $guard -Process $guardedProcess
            Release-RegistrationGatedTestProcess -Launch $guardedLaunch
            Assert-True ([bool]$registration.Registered) 'Test process is registered as guard-owned'
            Assert-Equal 'JobObject' $registration.Mode 'Test process is assigned to a KILL_ON_JOB_CLOSE Job Object'
            Assert-False ([bool]$registration.AlreadyRegistered) 'The first exact process registration is not reported as idempotent reuse'
            $repeatRegistration = Register-CpaStackTestProcess -Guard $guard -Process $guardedProcess
            Assert-True ([bool]$repeatRegistration.AlreadyRegistered) 'A repeated exact process identity is reported as already registered'
            Assert-Equal 1 @($guard.RegisteredProcesses).Count 'Repeated exact registration does not duplicate the fixed process handle'
            Close-CpaStackProductionGuard -Guard $guard -WaitMilliseconds 10000
            Assert-True ($guardedProcess.WaitForExit(10000)) 'Closing the production guard terminates its registered test process'
        } finally {
            if (-not $guardedProcess.HasExited) {
                $guardedProcess.Kill()
                [void]$guardedProcess.WaitForExit(5000)
            }
            $guardedProcess.Dispose()
        }
    } finally {
        Close-CpaStackProductionGuard -Guard $guard
    }
} finally {
    Remove-TestPathWithRetry -Path $temp
}

'Production guard tests passed.'
