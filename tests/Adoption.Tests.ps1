$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$sourceRepo = Split-Path -Parent $PSScriptRoot
$productionGuardModule = Join-Path $sourceRepo 'tools\CpaStack.ProductionGuard.psm1'
Import-Module $productionGuardModule -Force
$temp = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('cpa-adoption-tests-' + [guid]::NewGuid().ToString('N'))
$fixtureRepo = Join-Path $temp 'repository'
$fixtureLocalAppData = Join-Path $temp 'local-app-data'
$harness = Join-Path $temp 'harness'
$root = Join-Path $temp 'legacy canonical root'
$previousFixtureRoot = [Environment]::GetEnvironmentVariable('CPA_STACK_ADOPTION_TEST_ROOT', 'Process')
$pluginRootJunction = $null
$authRootJunction = $null
$productionGuard = $null

function Invoke-GuardedAdoptionScript {
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [switch]$RecoverOnly
    )

    New-Item -ItemType Directory -Force -Path $CaseRoot | Out-Null
    $token = [guid]::NewGuid().ToString('N')
    $readyPath = Join-Path $CaseRoot ($token + '.ready')
    $goPath = Join-Path $CaseRoot ($token + '.go')
    $stdoutPath = Join-Path $CaseRoot ($token + '.stdout')
    $stderrPath = Join-Path $CaseRoot ($token + '.stderr')
    $scriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($ScriptPath)))
    $rootBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($ControlRoot)))
    $readyBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($readyPath))
    $goBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($goPath))
    $recoverLiteral = if ($RecoverOnly) { '$true' } else { '$false' }
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
function Decode([string]`$Value) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Value)) }
`$scriptPath = Decode '$scriptBase64'
`$controlRoot = Decode '$rootBase64'
`$readyPath = Decode '$readyBase64'
`$goPath = Decode '$goBase64'
`$recoverOnly = $recoverLiteral
[System.IO.File]::WriteAllText(`$readyPath, 'ready', [System.Text.Encoding]::ASCII)
`$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath `$goPath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge `$deadline) { throw 'Adoption test registration gate timed out.' }
    Start-Sleep -Milliseconds 20
}
`$arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', `$scriptPath, '-ControlRoot', `$controlRoot)
if (`$recoverOnly) { `$arguments += '-RecoverOnly' }
`$savedErrorAction = `$ErrorActionPreference
try {
    `$ErrorActionPreference = 'Continue'
    `$output = @(& (Get-Command powershell.exe -ErrorAction Stop).Source @arguments 2>&1)
    `$exitCode = `$LASTEXITCODE
} finally {
    `$ErrorActionPreference = `$savedErrorAction
}
foreach (`$line in @(`$output)) { [Console]::Out.WriteLine([string]`$line) }
if (`$null -eq `$exitCode) { `$exitCode = 0 }
exit `$exitCode
"@
    $encodedWrapper = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))
    $process = Start-Process `
        -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedWrapper) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            throw 'Adoption test process did not reach its registration gate.'
        }
        [void](Register-CpaStackTestProcess -Guard $Guard -Process $process)
        [System.IO.File]::WriteAllText($goPath, 'go', [System.Text.Encoding]::ASCII)
        if (-not $process.WaitForExit(60000)) { throw 'Adoption test process timed out.' }
        $process.WaitForExit()
        $process.Refresh()
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { @([System.IO.File]::ReadAllLines($stdoutPath)) } else { @() }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { @([System.IO.File]::ReadAllLines($stderrPath)) } else { @() }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output = @($stdout | ForEach-Object { [string]$_ })
            ErrorOutput = @($stderr | ForEach-Object { [string]$_ })
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $listenerSnapshot = @(Get-CpaStackListenerSnapshot)
    $productionStateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack'
    $productionRegistration = Get-CpaStackProductionRegistration -ProductionStateHome $productionStateHome
    $productionGuard = New-CpaStackProductionGuard `
        -ProductionRoot @($productionRegistration.Roots) `
        -ProductionStateHome @($productionStateHome) `
        -ProductionPort @($productionRegistration.ProtectedPorts) `
        -ListenerSnapshot $listenerSnapshot
    $portPlan = New-CpaStackTestPortPlan -Guard $productionGuard -Name @('AdoptionCpa', 'AdoptionManager', 'AdoptionWrongManager')
    $cpaPort = [int]$portPlan.Ports.AdoptionCpa
    $managerPort = [int]$portPlan.Ports.AdoptionManager
    $wrongManagerPort = [int]$portPlan.Ports.AdoptionWrongManager
    [void](Assert-CpaStackTestIsolation `
        -Guard $productionGuard `
        -TestRoot $temp `
        -TestStateHome $fixtureLocalAppData `
        -TestPort @($cpaPort, $managerPort, $wrongManagerPort))
    $fixture = New-CpaStackUpdaterTestFixture -SourceRepository $sourceRepo -DestinationRepository $fixtureRepo -LocalAppDataRoot $fixtureLocalAppData
    $repo = $fixture.Repository
    $commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
    . $commonPath
    Protect-CpaStackPrivateTree -Root $temp
    $locatorPath = Get-CpaStackRootLocatorPath
    $productionLocatorPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\root.json'
    Assert-False ([string]::Equals($locatorPath, $productionLocatorPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Adoption tests never use the production root locator'
    Assert-True ([System.IO.Path]::GetFullPath($locatorPath).StartsWith($fixture.LocalAppData + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Adoption tests keep the root locator inside isolated LocalApplicationData'
    New-Item -ItemType Directory -Force -Path $harness | Out-Null
    foreach ($name in @('CpaStack.Common.ps1', 'Adopt-CpaStackLegacyCanonical.ps1', 'Start-CPA-Stack.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo ('skills\cpa-safe-upgrade\scripts\' + $name)) -Destination $harness
    }
    $adoptionHarnessPath = Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1'
    $adoptionHarnessText = [System.IO.File]::ReadAllText($adoptionHarnessPath, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 3 ([regex]::Matches($adoptionHarnessText, '(?<!\d)8317(?!\d)').Count) 'Source adoption contract contains three CPA formal-port references'
    Assert-Equal 3 ([regex]::Matches($adoptionHarnessText, '(?<!\d)18317(?!\d)').Count) 'Source adoption contract contains three Manager formal-port references'
    $adoptionHarnessText = [regex]::Replace($adoptionHarnessText, '(?<!\d)8317(?!\d)', [string]$cpaPort)
    $adoptionHarnessText = [regex]::Replace($adoptionHarnessText, '(?<!\d)18317(?!\d)', [string]$managerPort)
    [System.IO.File]::WriteAllText($adoptionHarnessPath, $adoptionHarnessText, [System.Text.UTF8Encoding]::new($false))
    $listenerMock = @'
function Get-CpaStackListener {
    param([int]$Port)
    $relative = if ($Port -eq __CPA_PORT__) { 'runtime\cli-proxy-api\cli-proxy-api.exe' } else { 'runtime\manager-plus\cpa-manager-plus.exe' }
    return [pscustomobject]@{
        Port = $Port
        LocalAddress = '127.0.0.1'
        LocalAddresses = @('127.0.0.1')
        ListenerCount = 1
        ProcessId = $PID
        ExecutablePath = Join-Path $env:CPA_STACK_ADOPTION_TEST_ROOT $relative
    }
}
function Wait-CpaStackTrustedListener {
    param([int]$Port, [string]$ExpectedPath, [int]$ExpectedProcessId, [string]$ExpectedHash, [string[]]$AllowedAddresses, [int]$Seconds)
    return Get-CpaStackListener -Port $Port
}
'@
    $listenerMock = $listenerMock.Replace('__CPA_PORT__', [string]$cpaPort)
    Add-Content -LiteralPath (Join-Path $harness 'CpaStack.Common.ps1') -Value $listenerMock -Encoding ASCII
    @'
param([string]$ControlRoot)
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $false
    CanonicalEstablished = $false
    MigrationRequired = $true
    LegacyCanonicalAdoptionRequired = $true
    Cpa = [pscustomobject]@{ Healthy = $true }
    Manager = [pscustomobject]@{ Healthy = $true }
    Security = [pscustomobject]@{
        RootAcl = [pscustomobject]@{ Protected = $true }
        ManagerDataTree = [pscustomobject]@{ Protected = $true }
        Integrity = [pscustomobject]@{ Ready = $true }
    }
} | ConvertTo-Json -Depth 10
exit 1
'@ | Set-Content -LiteralPath (Join-Path $harness 'Get-CpaStackState.ps1') -Encoding ASCII

    $fixtureStateRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath (Join-Path $harness 'Get-CpaStackState.ps1') -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io')
    $fixtureStateOutput = @($fixtureStateRun.Output)
    Assert-Equal 1 $fixtureStateRun.ExitCode 'Adoption status fixture preserves the unhealthy pre-adoption exit code'
    Assert-True ($fixtureStateOutput.Count -gt 1) 'Adoption status fixture emits realistic multi-line JSON'
    Assert-Equal '{' ([string]$fixtureStateOutput[0]).Trim() 'Adoption status fixture starts a JSON document on its own line'
    Assert-Equal '}' ([string]$fixtureStateOutput[$fixtureStateOutput.Count - 1]).Trim() 'Adoption status fixture ends a JSON document on its own line'

    foreach ($directory in @('config', 'ops', 'state', 'runtime\cli-proxy-api\auth', 'runtime\cli-proxy-api\plugins\nested', 'runtime\manager-plus', 'data\manager-plus', 'rollback')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
    }
    [Environment]::SetEnvironmentVariable('CPA_STACK_ADOPTION_TEST_ROOT', $root, 'Process')
    $cpaExe = Join-Path $root 'runtime\cli-proxy-api\cli-proxy-api.exe'
    $managerExe = Join-Path $root 'runtime\manager-plus\cpa-manager-plus.exe'
    Set-Content -LiteralPath $cpaExe -Value 'synthetic old cpa executable' -Encoding ASCII
    Set-Content -LiteralPath $managerExe -Value 'synthetic old manager executable' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\config.yaml') -Value "host: `"127.0.0.1`"`r`nport: $cpaPort" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\plugins\plugin.ps1') -Value '# plugin fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\plugins\nested\helper.ps1') -Value '# nested plugin fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'data\manager-plus\usage.sqlite') -Value 'synthetic sqlite fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'data\manager-plus\data.key') -Value 'synthetic data key' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'config\secrets.local.json') -Value '{"cpaClientApiKey":"test","cpaManagementKey":"test","managerAdminKey":"test"}' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'ops\Start-CPA-Stack.ps1') -Value '# stale launcher' -Encoding ASCII
    @"
@{
    SchemaVersion = 1
    StartupTimeoutSeconds = 30
    HttpTimeoutSeconds = 5
    Cpa = @{
        Executable = 'runtime\cli-proxy-api\cli-proxy-api.exe'
        WorkingDirectory = 'runtime\cli-proxy-api'
        Config = 'runtime\cli-proxy-api\config.yaml'
        Port = $cpaPort
    }
    Manager = @{
        Executable = 'runtime\manager-plus\cpa-manager-plus.exe'
        WorkingDirectory = 'runtime\manager-plus'
        DataDirectory = 'data\manager-plus'
        Port = $managerPort
        BindAddress = '127.0.0.1'
        RequestMonitoringEnabled = `$true
    }
    Browser = @{ Url = 'http://127.0.0.1:$managerPort/management.html'; Executable = '' }
}
"@ | Set-Content -LiteralPath (Join-Path $root 'config\stack.psd1') -Encoding ASCII
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        canonicalRoot = $root
        cpa = [ordered]@{
            version = 'legacy'
            executable = $cpaExe
            sha256 = Get-CpaStackFileHash -Path $cpaExe
            config = Join-Path $root 'runtime\cli-proxy-api\config.yaml'
        }
        manager = [ordered]@{
            version = 'legacy'
            executable = $managerExe
            sha256 = Get-CpaStackFileHash -Path $managerExe
            data = Join-Path $root 'data\manager-plus'
        }
    }) -Path (Join-Path $root 'state\current.json')
    Protect-CpaStackPrivateTree -Root $root

    $adoptionRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath $adoptionHarnessPath -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io')
    $output = @($adoptionRun.Output)
    Assert-Equal 0 $adoptionRun.ExitCode ('Legacy canonical adoption succeeds. Output=' + ($output -join ' | '))
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
    Assert-Equal 1 $jsonLine.Count 'Adoption returns one structured result'
    $result = $jsonLine[0] | ConvertFrom-Json
    Assert-True ([bool]$result.success) 'Adoption reports success'
    Assert-True ([bool]$result.adopted) 'Adoption reports the legacy canonical transition'
    Assert-True ([bool]$result.changed) 'Adoption reports its state and ACL changes'
    $marker = Read-CpaStackJson -Path (Join-Path $root '.cpa-stack-instance.json')
    $current = Read-CpaStackJson -Path (Join-Path $root 'state\current.json')
    Assert-True ([string]$marker.instanceId -match '^[0-9a-fA-F]{32}$') 'Adoption creates a valid instance id'
    Assert-Equal ([string]$marker.instanceId) ([string]$current.instanceId) 'Marker and current state share the adopted instance id'
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'state\adopt.pending.json')) 'Adoption removes its pending journal after commit'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $harness 'Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path (Join-Path $root 'ops\Start-CPA-Stack.ps1')) 'Adoption refreshes the canonical launcher'
    Assert-CpaStackPrivateTree -Root (Join-Path $root 'runtime\cli-proxy-api\plugins') -Description 'Adopted CPA plugins'

    Remove-Item -LiteralPath (Join-Path $root '.cpa-stack-instance.json') -Force
    Set-Content -LiteralPath (Join-Path $root 'ops\Start-CPA-Stack.ps1') -Value '# interrupted stale launcher' -Encoding ASCII
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        operation = 'adopt-legacy-canonical-stack'
        instanceId = [string]$current.instanceId
        canonicalRoot = $root
        cpaSha256 = Get-CpaStackFileHash -Path $cpaExe
        managerSha256 = Get-CpaStackFileHash -Path $managerExe
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path (Join-Path $root 'state\adopt.pending.json')

    $replayRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath $adoptionHarnessPath -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io')
    $replayOutput = @($replayRun.Output)
    Assert-Equal 0 $replayRun.ExitCode ('Interrupted adoption replay succeeds. Output=' + ($replayOutput -join ' | '))
    $replayedMarker = Read-CpaStackJson -Path (Join-Path $root '.cpa-stack-instance.json')
    Assert-Equal ([string]$current.instanceId) ([string]$replayedMarker.instanceId) 'Adoption replay uses the journal-bound instance id'
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'state\adopt.pending.json')) 'Adoption replay removes its pending journal'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $harness 'Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path (Join-Path $root 'ops\Start-CPA-Stack.ps1')) 'Adoption replay finishes launcher synchronization'

    $aclTarget = Join-Path $root 'ops\Start-CPA-Stack.ps1'
    $permissiveAcl = Get-CpaStackFileSystemAcl -Path $aclTarget
    $everyone = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $readRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $everyone,
        [System.Security.AccessControl.FileSystemRights]::Read,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$permissiveAcl.AddAccessRule($readRule)
    Set-CpaStackFileSystemAcl -Path $aclTarget -Acl $permissiveAcl
    $aclSections = [System.Security.AccessControl.AccessControlSections]'Owner,Group,Access'
    $aclBeforeForeignRecovery = (Get-CpaStackFileSystemAcl -Path $aclTarget).GetSecurityDescriptorSddlForm($aclSections)
    $currentHashBeforeForeignRecovery = Get-CpaStackFileHash -Path (Join-Path $root 'state\current.json')
    $markerHashBeforeForeignRecovery = Get-CpaStackFileHash -Path (Join-Path $root '.cpa-stack-instance.json')
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        operation = 'adopt-legacy-canonical-stack'
        instanceId = [guid]::NewGuid().ToString('N')
        canonicalRoot = $root
        cpaSha256 = Get-CpaStackFileHash -Path $cpaExe
        managerSha256 = Get-CpaStackFileHash -Path $managerExe
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path (Join-Path $root 'state\adopt.pending.json')
    $foreignJournalHash = Get-CpaStackFileHash -Path (Join-Path $root 'state\adopt.pending.json')

    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $foreignRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath $adoptionHarnessPath -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io') -RecoverOnly
        $foreignOutput = @($foreignRun.Output)
        $foreignExitCode = $foreignRun.ExitCode
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $foreignExitCode 'Adoption recovery rejects a journal from another instance'
    Assert-True (($foreignOutput -join ' ') -match 'do not identify the same stack') 'Foreign adoption identity failure is explicit'
    Assert-Equal $aclBeforeForeignRecovery ((Get-CpaStackFileSystemAcl -Path $aclTarget).GetSecurityDescriptorSddlForm($aclSections)) 'Foreign adoption recovery does not modify ACLs'
    Assert-Equal $currentHashBeforeForeignRecovery (Get-CpaStackFileHash -Path (Join-Path $root 'state\current.json')) 'Foreign adoption recovery does not rewrite current state'
    Assert-Equal $markerHashBeforeForeignRecovery (Get-CpaStackFileHash -Path (Join-Path $root '.cpa-stack-instance.json')) 'Foreign adoption recovery does not rewrite the instance marker'
    Assert-Equal $foreignJournalHash (Get-CpaStackFileHash -Path (Join-Path $root 'state\adopt.pending.json')) 'Foreign adoption recovery preserves evidence for manual recovery'
    Remove-Item -LiteralPath (Join-Path $root 'state\adopt.pending.json') -Force
    Protect-CpaStackSecretFile -Path $aclTarget

    $stackConfigPath = Join-Path $root 'config\stack.psd1'
    $validStackConfig = [System.IO.File]::ReadAllText($stackConfigPath)
    [System.IO.File]::WriteAllText($stackConfigPath, $validStackConfig.Replace("Port = $managerPort", "Port = $wrongManagerPort"), [System.Text.UTF8Encoding]::new($false))
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $wrongPortRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath $adoptionHarnessPath -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io')
        $wrongPortOutput = @($wrongPortRun.Output)
        $wrongPortExitCode = $wrongPortRun.ExitCode
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $wrongPortExitCode 'Adoption rejects a non-canonical formal Manager port'
    Assert-True (($wrongPortOutput -join ' ') -match 'canonical formal ports') 'Wrong-port adoption failure is explicit'
    [System.IO.File]::WriteAllText($stackConfigPath, $validStackConfig, [System.Text.UTF8Encoding]::new($false))
    Protect-CpaStackSecretFile -Path $stackConfigPath

    $pluginsRoot = Join-Path $root 'runtime\cli-proxy-api\plugins'
    Remove-Item -LiteralPath $pluginsRoot -Recurse -Force
    $externalPlugins = Join-Path $temp 'external-plugins'
    New-Item -ItemType Directory -Force -Path $externalPlugins | Out-Null
    $pluginRootJunction = New-Item -ItemType Junction -Path $pluginsRoot -Target $externalPlugins
    $ErrorActionPreference = 'Continue'
    try {
        $pluginReparseRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath $adoptionHarnessPath -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io')
        $pluginReparseOutput = @($pluginReparseRun.Output)
        $pluginReparseExitCode = $pluginReparseRun.ExitCode
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $pluginReparseExitCode 'Adoption rejects a CPA plugins root junction'
    Assert-True (($pluginReparseOutput -join ' ') -match 'reparse point') 'Plugins-junction adoption failure is explicit'
    [System.IO.Directory]::Delete($pluginsRoot)
    $pluginRootJunction = $null
    New-Item -ItemType Directory -Force -Path $pluginsRoot | Out-Null
    Protect-CpaStackPrivateTree -Root $pluginsRoot

    $authRoot = Join-Path $root 'runtime\cli-proxy-api\auth'
    Remove-Item -LiteralPath $authRoot -Recurse -Force
    $externalAuth = Join-Path $temp 'external-auth'
    New-Item -ItemType Directory -Force -Path $externalAuth | Out-Null
    $authRootJunction = New-Item -ItemType Junction -Path $authRoot -Target $externalAuth
    $ErrorActionPreference = 'Continue'
    try {
        $reparseRun = Invoke-GuardedAdoptionScript -Guard $productionGuard -ScriptPath $adoptionHarnessPath -ControlRoot $root -CaseRoot (Join-Path $temp 'process-io')
        $reparseOutput = @($reparseRun.Output)
        $reparseExitCode = $reparseRun.ExitCode
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $reparseExitCode 'Adoption rejects a CPA auth junction'
    Assert-True (($reparseOutput -join ' ') -match 'reparse point') 'Auth-junction adoption failure is explicit'
} finally {
    $guardFailure = $null
    if ($null -ne $productionGuard) {
        try {
            Close-CpaStackProductionGuard -Guard $productionGuard
            $comparison = Compare-CpaStackProductionListenerSnapshot -Guard $productionGuard
            if (-not $comparison.Unchanged) {
                $guardFailure = 'Adoption tests changed a protected production listener.'
            }
        } catch {
            $guardFailure = $_.Exception.Message
        }
    }
    [Environment]::SetEnvironmentVariable('CPA_STACK_ADOPTION_TEST_ROOT', $previousFixtureRoot, 'Process')
    foreach ($junction in @($authRootJunction, $pluginRootJunction)) {
        if ($junction -and (Test-Path -LiteralPath $junction.FullName)) {
            [System.IO.Directory]::Delete($junction.FullName)
        }
    }
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
    if (-not [string]::IsNullOrWhiteSpace($guardFailure)) { throw $guardFailure }
}

'Adoption tests passed.'
