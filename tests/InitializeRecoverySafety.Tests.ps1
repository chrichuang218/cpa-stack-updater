#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$productionGuardModule = Join-Path $repo 'tools\CpaStack.ProductionGuard.psm1'
$testHome = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex'
$temp = Join-Path $testHome ('cpa-init-recovery-safety-' + [guid]::NewGuid().ToString('N'))
$productionGuard = $null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

Import-Module $productionGuardModule -Force

function Write-TestText {
    param([string]$Path, [string]$Value)

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Write-TestJson {
    param([string]$Path, $Value)

    Write-TestText -Path $Path -Value ($Value | ConvertTo-Json -Depth 12)
}

function Protect-RecoveryFixtureTree {
    param([Parameter(Mandatory = $true)][string]$Root)

    Protect-CpaStackPrivateTree -Root $Root
}

function Get-UnusedHighLoopbackPort {
    param([int[]]$Exclude = @())

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $port = [int]([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        } finally {
            $listener.Stop()
        }
        if ($port -ge 49152 -and $port -le 65535 -and
            $port -notin @(8317, 8318, 18317, 18318) -and $port -notin $Exclude) {
            return $port
        }
    }
    throw 'Could not allocate an isolated high loopback port.'
}

function Get-IsolatedPortSet {
    $ports = New-Object System.Collections.Generic.List[int]
    while ($ports.Count -lt 4) {
        $ports.Add((Get-UnusedHighLoopbackPort -Exclude @($ports)))
    }
    return @($ports)
}

function Get-TestTreeSnapshot {
    param([string]$Root)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $accessSections = [System.Security.AccessControl.AccessControlSections]'Owner,Group,Access'
    $entries = foreach ($item in @(Get-Item -Force -LiteralPath $rootFull) + @(Get-ChildItem -Force -LiteralPath $rootFull -Recurse)) {
        $full = [System.IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
        $relative = if ($full -ieq $rootFull) { '.' } else { $full.Substring($rootFull.Length + 1) }
        $acl = Get-CpaStackFileSystemAcl -Path $item.FullName
        [ordered]@{
            path = $relative
            kind = if ($item.PSIsContainer) { 'directory' } else { 'file' }
            length = if ($item.PSIsContainer) { $null } else { [long]$item.Length }
            sha256 = if ($item.PSIsContainer) { $null } else { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
            sddl = $acl.GetSecurityDescriptorSddlForm($accessSections)
        }
    }
    return (@($entries | Sort-Object path) | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-GuardedRecoveryCommand {
    param(
        [string]$PowerShell,
        [string]$Runner,
        [string]$ScriptPath,
        [string]$Root,
        [ValidateSet('Initialize', 'PublicRecover')][string]$Mode,
        [string]$CaseRoot
    )

    New-Item -ItemType Directory -Force -Path $CaseRoot | Out-Null
    $gate = Join-Path $CaseRoot ('gate-' + [guid]::NewGuid().ToString('N'))
    $stdout = Join-Path $CaseRoot ('stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
    $stderr = Join-Path $CaseRoot ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Runner,
        '-ScriptPath', $ScriptPath,
        '-ControlRoot', $Root,
        '-Mode', $Mode,
        '-GatePath', $gate
    )
    $forbiddenPortArguments = @('8317', '8318', '18317', '18318')
    Assert-False (@($arguments | Where-Object { [string]$_ -in $forbiddenPortArguments }).Count -gt 0) "$Mode recovery invocation excludes production port arguments"
    $launchExecutable = $PowerShell
    $launchArguments = $arguments
    if ([System.IO.Path]::GetFileNameWithoutExtension($PowerShell) -ieq 'pwsh') {
        # The Store-packaged pwsh already belongs to an AppContainer job and
        # cannot be assigned to our guard after launch. Start it as a descendant
        # of an already-guarded Windows PowerShell trampoline instead.
        $trampoline = Join-Path $CaseRoot ('pwsh-trampoline-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $pwshLiteral = $PowerShell.Replace("'", "''")
        Write-TestText -Path $trampoline -Value @"
param([string]`$Runner,[string]`$ScriptPath,[string]`$ControlRoot,[string]`$Mode,[string]`$GatePath)
`$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath `$GatePath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge `$deadline) { throw 'Guard registration gate timed out.' }
    Start-Sleep -Milliseconds 20
}
& '$pwshLiteral' -NoLogo -NoProfile -NonInteractive -File `$Runner -ScriptPath `$ScriptPath -ControlRoot `$ControlRoot -Mode `$Mode -GatePath `$GatePath
`$code = if (`$null -eq `$global:LASTEXITCODE) { 0 } else { [int]`$global:LASTEXITCODE }
exit `$code
"@
        $launchExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source
        $launchArguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $trampoline,
            '-Runner', $Runner,
            '-ScriptPath', $ScriptPath,
            '-ControlRoot', $Root,
            '-Mode', $Mode,
            '-GatePath', $gate
        )
    }
    $process = Start-Process -FilePath $launchExecutable -ArgumentList $launchArguments -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    try {
        try {
            [void](Register-CpaStackTestProcess -Guard $productionGuard -Process $process)
        } catch {
            throw "Guard registration failed for $Mode case '$CaseRoot' via '$launchExecutable': $($_.Exception.Message)"
        }
        Write-TestText -Path $gate -Value 'go'
        if (-not $process.WaitForExit(60000)) {
            throw "$Mode recovery command did not exit within 60 seconds."
        }
        $process.Refresh()
        $stdoutText = if (Test-Path -LiteralPath $stdout) { Get-Content -Raw -LiteralPath $stdout } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderr) { Get-Content -Raw -LiteralPath $stderr } else { '' }
        $jsonLine = @($stdoutText -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
        $json = if ([string]::IsNullOrWhiteSpace([string]$jsonLine)) { $null } else { $jsonLine | ConvertFrom-Json }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Json = $json
            Stdout = $stdoutText
            Stderr = $stderrText
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Start-GuardedTargetSentinel {
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$CaseRoot
    )

    New-Item -ItemType Directory -Force -Path $CaseRoot | Out-Null
    $token = [guid]::NewGuid().ToString('N')
    $sentinelScript = Join-Path $CaseRoot "sentinel-$token.ps1"
    $readyPath = Join-Path $CaseRoot "ready-$token"
    $goPath = Join-Path $CaseRoot "go-$token"
    Write-TestText -Path $sentinelScript -Value @'
param([string]$ReadyPath, [string]$GoPath)
[System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Sentinel guard registration gate timed out.' }
    Start-Sleep -Milliseconds 20
}
Start-Sleep -Seconds 120
'@

    $process = Start-Process -FilePath $Executable -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $sentinelScript,
        '-ReadyPath', $readyPath,
        '-GoPath', $goPath
    ) -WindowStyle Hidden -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            if ($process.HasExited) { throw 'Target-path sentinel exited before reaching its registration gate.' }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Target-path sentinel did not reach its registration gate.' }
            Start-Sleep -Milliseconds 20
        }
        [void](Register-CpaStackTestProcess -Guard $Guard -Process $process)
        Write-TestText -Path $goPath -Value 'go'
        return [pscustomobject]@{ Process = $process; ReadyPath = $readyPath; GoPath = $goPath }
    } catch {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
        throw
    }
}

function New-MinimalJournalRoot {
    param(
        [string]$Root,
        [string]$Phase = 'foreign-phase',
        [string]$JournalInstanceId
    )

    $instanceId = [guid]::NewGuid().ToString('N')
    if ([string]::IsNullOrWhiteSpace($JournalInstanceId)) { $JournalInstanceId = $instanceId }
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'state') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'config') | Out-Null
    Write-TestJson -Path (Join-Path $Root '.cpa-stack-instance.json') -Value ([ordered]@{
        schemaVersion = 1
        instanceId = $instanceId
        root = $Root
    })
    Write-TestJson -Path (Join-Path $Root 'state\initialize.pending.json') -Value ([ordered]@{
        schemaVersion = 2
        operation = 'initialize-canonical-stack'
        operationId = [guid]::NewGuid().ToString('N')
        instanceId = $JournalInstanceId
        phase = $Phase
        canonicalRoot = $Root
    })
    Write-TestText -Path (Join-Path $Root 'config\secrets.local.json.secure-0123456789abcdef0123456789abcdef') -Value 'must-remain'
    Protect-RecoveryFixtureTree -Root $Root
    return [pscustomobject]@{ InstanceId = $instanceId; JournalInstanceId = $JournalInstanceId }
}

function New-FullJournalRoot {
    param([string]$CaseRoot, [string]$Root)

    $ports = @(Get-IsolatedPortSet)
    $instanceId = [guid]::NewGuid().ToString('N')
    $operationId = [guid]::NewGuid().ToString('N')
    $legacyCpa = Join-Path $CaseRoot 'legacy-cpa'
    $legacyManager = Join-Path $CaseRoot 'legacy-manager'
    $legacyManagerData = Join-Path $CaseRoot 'legacy-manager-data'
    $targetCpa = Join-Path $Root 'runtime\cli-proxy-api'
    $targetManager = Join-Path $Root 'runtime\manager-plus'
    $targetManagerData = Join-Path $Root 'data\manager-plus'
    foreach ($directory in @(
        (Join-Path $legacyCpa 'auth'),
        $legacyManager,
        $legacyManagerData,
        (Join-Path $targetCpa 'auth'),
        $targetManager,
        $targetManagerData,
        (Join-Path $Root 'state'),
        (Join-Path $Root 'config'),
        (Join-Path $Root 'rollback')
    )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Write-TestText -Path (Join-Path $legacyCpa 'cli-proxy-api.exe') -Value 'legacy-cpa-binary'
    Write-TestText -Path (Join-Path $legacyCpa 'config.yaml') -Value "host: `"127.0.0.1`"`r`nport: $($ports[0])`r`n"
    Write-TestText -Path (Join-Path $legacyCpa 'auth\account.json') -Value '{}'
    Write-TestText -Path (Join-Path $legacyManager 'cpa-manager-plus.exe') -Value 'legacy-manager-binary'
    Write-TestText -Path (Join-Path $legacyManagerData 'usage.sqlite') -Value 'sqlite-fixture'
    Write-TestText -Path (Join-Path $legacyManagerData 'data.key') -Value 'legacy-data-key'
    Write-TestText -Path (Join-Path $targetCpa 'cli-proxy-api.exe') -Value 'target-cpa-binary'
    Write-TestText -Path (Join-Path $targetCpa 'config.yaml') -Value "host: `"127.0.0.1`"`r`nport: $($ports[0])`r`n"
    Write-TestText -Path (Join-Path $targetCpa 'auth\account.json') -Value '{}'
    Write-TestText -Path (Join-Path $targetManager 'cpa-manager-plus.exe') -Value 'target-manager-binary'
    Write-TestJson -Path (Join-Path $Root '.cpa-stack-instance.json') -Value ([ordered]@{
        schemaVersion = 1
        instanceId = $instanceId
        root = $Root
    })
    Write-TestJson -Path (Join-Path $Root 'config\secrets.local.json') -Value ([ordered]@{
        cpaManagementKey = 'isolated-management-key'
        cpaClientApiKey = 'isolated-client-key'
        managerAdminKey = 'isolated-manager-key'
    })
    Write-TestText -Path (Join-Path $Root 'config\stack.psd1') -Value @"
@{
    SchemaVersion = 1
    Cpa = @{ Executable = 'runtime\cli-proxy-api\cli-proxy-api.exe'; WorkingDirectory = 'runtime\cli-proxy-api'; Config = 'runtime\cli-proxy-api\config.yaml'; Port = $($ports[0]) }
    Manager = @{ Executable = 'runtime\manager-plus\cpa-manager-plus.exe'; WorkingDirectory = 'runtime\manager-plus'; DataDirectory = 'data\manager-plus'; Port = $($ports[1]); BindAddress = '127.0.0.1'; RequestMonitoringEnabled = `$false }
    Browser = @{ Url = 'http://127.0.0.1:$($ports[1])/management.html'; Executable = '' }
}
"@
    $journal = [ordered]@{
        schemaVersion = 2
        operation = 'initialize-canonical-stack'
        operationId = $operationId
        instanceId = $instanceId
        phase = 'switching'
        canonicalRoot = $Root
        sourceCpaRuntime = $legacyCpa
        sourceCpaConfig = Join-Path $legacyCpa 'config.yaml'
        sourceManagerRuntime = $legacyManager
        sourceManagerData = $legacyManagerData
        legacyStartScript = $null
        desktopShortcut = $null
        targetCpaRuntime = $targetCpa
        targetManagerRuntime = $targetManager
        targetManagerData = $targetManagerData
        cpaVersion = 'fixture'
        managerVersion = 'fixture'
        cpaPort = $ports[0]
        managerPort = $ports[1]
        cpaCandidatePort = $ports[2]
        managerCandidatePort = $ports[3]
        sourceCpaSha256 = Get-CpaStackFileHash -Path (Join-Path $legacyCpa 'cli-proxy-api.exe')
        sourceManagerSha256 = Get-CpaStackFileHash -Path (Join-Path $legacyManager 'cpa-manager-plus.exe')
        sourceCpaConfigSha256 = Get-CpaStackFileHash -Path (Join-Path $legacyCpa 'config.yaml')
        legacyStartScriptSha256 = $null
        sourceDataKeySha256 = Get-CpaStackFileHash -Path (Join-Path $legacyManagerData 'data.key')
        targetCpaSha256 = Get-CpaStackFileHash -Path (Join-Path $targetCpa 'cli-proxy-api.exe')
        targetManagerSha256 = Get-CpaStackFileHash -Path (Join-Path $targetManager 'cpa-manager-plus.exe')
        targetCpaRuntimeManifestSha256 = [string](Get-CpaStackTreeManifest -Root $targetCpa).sha256
        targetCpaConfigSha256 = Get-CpaStackFileHash -Path (Join-Path $targetCpa 'config.yaml')
        targetCpaHost = '127.0.0.1'
        stackConfigSha256 = Get-CpaStackFileHash -Path (Join-Path $Root 'config\stack.psd1')
        managerBaseline = [ordered]@{
            cpaBaseUrl = "http://127.0.0.1:$($ports[0])"
            collectorEnabled = $false
            pollIntervalMs = 1000
            usageStatisticsEnabled = $true
        }
        managerBindAddress = '127.0.0.1'
        createdAt = [DateTimeOffset]::Now.ToString('o')
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-TestJson -Path (Join-Path $Root 'state\initialize.pending.json') -Value $journal
    Write-TestText -Path (Join-Path $Root 'config\secrets.local.json.secure-0123456789abcdef0123456789abcdef') -Value 'must-remain'
    Protect-RecoveryFixtureTree -Root $Root
    return [pscustomobject]@{
        Root = $Root
        Journal = $journal
        InstanceId = $instanceId
        OperationId = $operationId
        Ports = $ports
        LegacyCpa = $legacyCpa
        LegacyManager = $legacyManager
        LegacyManagerData = $legacyManagerData
        TargetCpa = $targetCpa
        TargetManager = $targetManager
        TargetManagerData = $targetManagerData
    }
}

function Write-ForeignCpaSwitchJournal {
    param($Fixture, [switch]$WrongInstance, [switch]$WrongParent)

    $journal = [ordered]@{
        schemaVersion = 1
        operation = 'switch-cpa'
        operationId = [guid]::NewGuid().ToString('N')
        parentOperationId = if ($WrongParent) { [guid]::NewGuid().ToString('N') } else { $Fixture.OperationId }
        instanceId = if ($WrongInstance) { [guid]::NewGuid().ToString('N') } else { $Fixture.InstanceId }
        phase = 'prepared'
        createdAt = [DateTimeOffset]::Now.ToString('o')
        sourceRuntime = $Fixture.LegacyCpa
        targetRuntime = $Fixture.TargetCpa
        sourceConfig = Join-Path $Fixture.LegacyCpa 'config.yaml'
        port = $Fixture.Ports[0]
        pendingPath = $null
        oldHash = $Fixture.Journal.sourceCpaSha256
        newHash = $Fixture.Journal.targetCpaSha256
        targetRuntimeManifestSha256 = $Fixture.Journal.targetCpaRuntimeManifestSha256
        targetConfigSha256 = $Fixture.Journal.targetCpaConfigSha256
        targetHost = $Fixture.Journal.targetCpaHost
        targetProcessId = $null
    }
    Write-TestJson -Path (Join-Path $Fixture.Root 'state\switch-cpa.pending.json') -Value $journal
}

function Assert-FailedWithoutRootMutation {
    param(
        [string]$PowerShell,
        [string]$Runner,
        [string]$InitializeScript,
        [string]$Root,
        [string]$CaseRoot,
        [string]$ErrorPattern,
        [string]$Message
    )

    $before = Get-TestTreeSnapshot -Root $Root
    $run = Invoke-GuardedRecoveryCommand -PowerShell $PowerShell -Runner $Runner -ScriptPath $InitializeScript -Root $Root -Mode Initialize -CaseRoot $CaseRoot
    Assert-True ($run.ExitCode -ne 0) "$Message returns a nonzero exit code"
    Assert-True (($run.Stdout + $run.Stderr) -match $ErrorPattern) "$Message reports the ownership/contract failure. Exit=$($run.ExitCode) Stdout=[$($run.Stdout)] Stderr=[$($run.Stderr)]"
    Assert-Equal $before (Get-TestTreeSnapshot -Root $Root) "$Message leaves every root file and ACL unchanged"
    Assert-False (Test-Path -LiteralPath (Join-Path $Root 'state\last-operation.json')) "$Message does not write last-operation.json"
}

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $listenerSnapshot = @(Get-CpaStackListenerSnapshot)
    $productionStateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack'
    $registration = Get-CpaStackProductionRegistration -ProductionStateHome $productionStateHome
    $productionGuard = New-CpaStackProductionGuard `
        -ProductionRoot @($registration.Roots) `
        -ProductionStateHome @($productionStateHome) `
        -ProductionPort @($registration.ProtectedPorts) `
        -ListenerSnapshot $listenerSnapshot
    [void](Assert-CpaStackTestIsolation -Guard $productionGuard -TestRoot $temp -TestStateHome (Join-Path $temp 'local-app-data'))

    $powershells = @((Get-Command powershell.exe -ErrorAction Stop).Source)
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwsh) { $powershells += $pwsh.Source }

    foreach ($powerShell in $powershells) {
        $hostName = [System.IO.Path]::GetFileNameWithoutExtension($powerShell)
        $hostRoot = Join-Path $temp $hostName
        $fixtureRepo = New-CpaStackUpdaterTestFixture `
            -SourceRepository $repo `
            -DestinationRepository (Join-Path $hostRoot 'repository') `
            -LocalAppDataRoot (Join-Path $hostRoot 'local-app-data')
        $scriptRoot = Join-Path $fixtureRepo.Repository 'skills\cpa-safe-upgrade\scripts'
        $initializeScript = Join-Path $scriptRoot 'Initialize-CpaStack.ps1'
        $publicScript = Join-Path $scriptRoot 'cpa-stack.ps1'
        . (Join-Path $scriptRoot 'CpaStack.Common.ps1')

        $runner = Join-Path $hostRoot 'guarded-runner.ps1'
        Write-TestText -Path $runner -Value @'
param(
    [string]$ScriptPath,
    [string]$ControlRoot,
    [ValidateSet('Initialize', 'PublicRecover')][string]$Mode,
    [string]$GatePath
)
$ErrorActionPreference = 'Stop'
$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath $GatePath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Guard registration gate timed out.' }
    Start-Sleep -Milliseconds 20
}
if ($Mode -eq 'Initialize') {
    & $ScriptPath -ControlRoot $ControlRoot -RecoverOnly
} else {
    & $ScriptPath recover -Root $ControlRoot -Json
}
$exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { [int]$global:LASTEXITCODE }
exit $exitCode
'@

        $missingRoot = Join-Path $hostRoot 'missing-root'
        $missingRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $initializeScript -Root $missingRoot -Mode Initialize -CaseRoot (Join-Path $hostRoot 'missing-case')
        Assert-Equal 0 $missingRun.ExitCode "$hostName RecoverOnly without a journal succeeds"
        Assert-True ([bool]$missingRun.Json.success) "$hostName RecoverOnly without a journal reports success"
        Assert-False (Test-Path -LiteralPath $missingRoot) "$hostName RecoverOnly does not create a missing root"

        $emptyRoot = Join-Path $hostRoot 'empty-root'
        New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null
        Write-TestText -Path (Join-Path $emptyRoot 'sentinel.txt') -Value 'unchanged'
        $emptyBefore = Get-TestTreeSnapshot -Root $emptyRoot
        $emptyRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $initializeScript -Root $emptyRoot -Mode Initialize -CaseRoot (Join-Path $hostRoot 'empty-case')
        Assert-Equal 0 $emptyRun.ExitCode "$hostName RecoverOnly accepts an empty root without a journal"
        Assert-Equal $emptyBefore (Get-TestTreeSnapshot -Root $emptyRoot) "$hostName RecoverOnly does not create a marker or state in an empty root"

        $phaseRoot = Join-Path $hostRoot 'invalid-phase-root'
        [void](New-MinimalJournalRoot -Root $phaseRoot -Phase 'foreign-phase')
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $phaseRoot `
            -CaseRoot (Join-Path $hostRoot 'invalid-phase-case') -ErrorPattern 'phase is unsupported' -Message "$hostName unknown initialization phase"

        $stateStub = Join-Path $scriptRoot 'Get-CpaStackState.ps1'
        Write-TestText -Path $stateStub -Value @'
param([string]$ControlRoot)
[ordered]@{
    SchemaVersion = 1
    OverallHealthy = $false
    CanonicalEstablished = $false
    MigrationRequired = $false
    LegacyCanonicalAdoptionRequired = $false
    InterruptedState = $true
    PendingOperations = @()
    Error = $null
} | ConvertTo-Json -Depth 6 -Compress
exit 1
'@
        $phaseBeforePublic = Get-TestTreeSnapshot -Root $phaseRoot
        $publicRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $publicScript -Root $phaseRoot -Mode PublicRecover -CaseRoot (Join-Path $hostRoot 'public-case')
        Assert-True ($publicRun.ExitCode -ne 0) "$hostName public recover fails closed for an invalid initialization journal. Exit=$($publicRun.ExitCode) Stdout=[$($publicRun.Stdout)] Stderr=[$($publicRun.Stderr)]"
        Assert-Equal 'ManualRecoveryRequired' ([string]$publicRun.Json.outcome) "$hostName public recover returns ManualRecoveryRequired"
        Assert-Equal $phaseBeforePublic (Get-TestTreeSnapshot -Root $phaseRoot) "$hostName public recover leaves the invalid journal tree unchanged"

        $instanceRoot = Join-Path $hostRoot 'wrong-instance-root'
        [void](New-MinimalJournalRoot -Root $instanceRoot -Phase 'preparing' -JournalInstanceId ([guid]::NewGuid().ToString('N')))
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $instanceRoot `
            -CaseRoot (Join-Path $hostRoot 'wrong-instance-case') -ErrorPattern 'different CPA stack instance' -Message "$hostName wrong-instance initialization journal"

        $foreignParentRoot = Join-Path $hostRoot 'foreign-parent-root'
        $foreignParentFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'foreign-parent-source') -Root $foreignParentRoot
        Write-ForeignCpaSwitchJournal -Fixture $foreignParentFixture -WrongParent
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $foreignParentRoot `
            -CaseRoot (Join-Path $hostRoot 'foreign-parent-case') -ErrorPattern 'not bound to the initialization operation' -Message "$hostName foreign-parent switch journal"

        $wrongChildInstanceRoot = Join-Path $hostRoot 'wrong-child-instance-root'
        $wrongChildInstanceFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'wrong-child-instance-source') -Root $wrongChildInstanceRoot
        Write-ForeignCpaSwitchJournal -Fixture $wrongChildInstanceFixture -WrongInstance
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $wrongChildInstanceRoot `
            -CaseRoot (Join-Path $hostRoot 'wrong-child-instance-case') -ErrorPattern 'another CPA stack instance' -Message "$hostName wrong-instance switch journal"

        $openAclRoot = Join-Path $hostRoot 'open-acl-root'
        [void](New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'open-acl-source') -Root $openAclRoot)
        $openJournalPath = Join-Path $openAclRoot 'state\initialize.pending.json'
        $openJournalAcl = Get-CpaStackFileSystemAcl -Path $openJournalPath
        $openJournalAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        ))
        Set-CpaStackFileSystemAcl -Path $openJournalPath -Acl $openJournalAcl
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $openAclRoot `
            -CaseRoot (Join-Path $hostRoot 'open-acl-case') -ErrorPattern 'unexpected identity|protected recovery root' -Message "$hostName mutable initialization journal ACL"

        $baselineRoot = Join-Path $hostRoot 'invalid-baseline-root'
        $baselineFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'invalid-baseline-source') -Root $baselineRoot
        $baselineFixture.Journal.managerBaseline.cpaBaseUrl = 'http://192.0.2.10:65500'
        Write-TestJson -Path (Join-Path $baselineRoot 'state\initialize.pending.json') -Value $baselineFixture.Journal
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $baselineRoot `
            -CaseRoot (Join-Path $hostRoot 'invalid-baseline-case') -ErrorPattern 'Manager baseline.*cpaBaseUrl' -Message "$hostName unbound Manager recovery baseline"

        $configDriftRoot = Join-Path $hostRoot 'config-drift-root'
        [void](New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'config-drift-source') -Root $configDriftRoot)
        [System.IO.File]::AppendAllText((Join-Path $configDriftRoot 'config\stack.psd1'), "`r`n# foreign recovery drift`r`n", $utf8NoBom)
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $configDriftRoot `
            -CaseRoot (Join-Path $hostRoot 'config-drift-case') -ErrorPattern 'stack configuration.*hash|stackConfigSha256' -Message "$hostName drifted committed stack configuration"

        $earlyPhaseRoot = Join-Path $hostRoot 'early-phase-root'
        $earlyPhaseFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'early-phase-source') -Root $earlyPhaseRoot
        $earlyPhaseFixture.Journal.phase = 'preparing'
        Write-TestJson -Path (Join-Path $earlyPhaseRoot 'state\initialize.pending.json') -Value $earlyPhaseFixture.Journal
        $foreignCandidateListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, [int]$earlyPhaseFixture.Ports[2])
        try {
            $foreignCandidateListener.Start()
            $earlyPhaseRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $initializeScript -Root $earlyPhaseRoot -Mode Initialize -CaseRoot (Join-Path $hostRoot 'early-phase-case')
            Assert-True ($earlyPhaseRun.ExitCode -ne 0) "$hostName preparing recovery reaches the later legacy verification failure"
            Assert-False (($earlyPhaseRun.Stdout + $earlyPhaseRun.Stderr) -match 'temporary port') "$hostName preparing recovery does not inspect or stop candidate listeners"
            Assert-True $foreignCandidateListener.Server.IsBound "$hostName preparing recovery leaves the unrelated candidate-port listener running"
        } finally {
            $foreignCandidateListener.Stop()
        }

        $unownedTargetRoot = Join-Path $hostRoot 'unowned-target-root'
        $unownedTargetFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'unowned-target-source') -Root $unownedTargetRoot
        $unownedTargetExe = Join-Path $unownedTargetFixture.TargetCpa 'cli-proxy-api.exe'
        Copy-Item -LiteralPath (Get-Command powershell.exe -ErrorAction Stop).Source -Destination $unownedTargetExe -Force
        $unownedTargetFixture.Journal.targetCpaSha256 = Get-CpaStackFileHash -Path $unownedTargetExe
        $unownedTargetFixture.Journal.targetCpaRuntimeManifestSha256 = [string](Get-CpaStackTreeManifest -Root $unownedTargetFixture.TargetCpa).sha256
        Write-TestJson -Path (Join-Path $unownedTargetRoot 'state\initialize.pending.json') -Value $unownedTargetFixture.Journal
        Protect-RecoveryFixtureTree -Root $unownedTargetRoot
        $unownedTargetSentinel = Start-GuardedTargetSentinel -Guard $productionGuard -Executable $unownedTargetExe -CaseRoot (Join-Path $hostRoot 'unowned-target-sentinel')
        $unownedTargetProcess = $unownedTargetSentinel.Process
        try {
            Assert-True (Test-Path -LiteralPath $unownedTargetSentinel.ReadyPath -PathType Leaf) "$hostName target-path sentinel reached ready before guard release"
            Assert-True (Test-Path -LiteralPath $unownedTargetSentinel.GoPath -PathType Leaf) "$hostName target-path sentinel was released only after guard registration"
            $unownedTargetBefore = Get-TestTreeSnapshot -Root $unownedTargetRoot
            $unownedTargetRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $initializeScript -Root $unownedTargetRoot -Mode Initialize -CaseRoot (Join-Path $hostRoot 'unowned-target-case')
            Assert-True ($unownedTargetRun.ExitCode -ne 0) "$hostName switching recovery without child identity fails closed"
            Assert-True (($unownedTargetRun.Stdout + $unownedTargetRun.Stderr) -match 'subordinate process identity evidence') "$hostName switching recovery reports missing subordinate process identity evidence. Exit=$($unownedTargetRun.ExitCode) Stdout=[$($unownedTargetRun.Stdout)] Stderr=[$($unownedTargetRun.Stderr)]"
            Assert-True (-not $unownedTargetProcess.HasExited) "$hostName switching recovery without child identity leaves an unrelated target-path process running"
            Assert-Equal $unownedTargetBefore (Get-TestTreeSnapshot -Root $unownedTargetRoot) "$hostName switching recovery without child identity leaves the recovery tree unchanged"
        } finally {
            if (-not $unownedTargetProcess.HasExited) {
                $unownedTargetProcess.Kill()
                [void]$unownedTargetProcess.WaitForExit(5000)
            }
            $unownedTargetProcess.Dispose()
        }

        $incompleteIdentityRoot = Join-Path $hostRoot 'incomplete-child-identity-root'
        $incompleteIdentityFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'incomplete-child-identity-source') -Root $incompleteIdentityRoot
        Write-ForeignCpaSwitchJournal -Fixture $incompleteIdentityFixture
        $incompleteChildPath = Join-Path $incompleteIdentityRoot 'state\switch-cpa.pending.json'
        $incompleteChild = Read-CpaStackJson -Path $incompleteChildPath
        $incompleteChild.phase = 'target-started'
        $incompleteChild.targetProcessId = $null
        Write-TestJson -Path $incompleteChildPath -Value $incompleteChild
        Protect-RecoveryFixtureTree -Root $incompleteIdentityRoot
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $incompleteIdentityRoot `
            -CaseRoot (Join-Path $hostRoot 'incomplete-child-identity-case') -ErrorPattern 'target process identity is missing' -Message "$hostName target-started child without a process identity"

        $extraTargetRoot = Join-Path $hostRoot 'extra-target-process-root'
        $extraTargetFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'extra-target-process-source') -Root $extraTargetRoot
        $extraTargetExe = Join-Path $extraTargetFixture.TargetCpa 'cli-proxy-api.exe'
        Copy-Item -LiteralPath (Get-Command powershell.exe -ErrorAction Stop).Source -Destination $extraTargetExe -Force
        $extraTargetFixture.Journal.targetCpaSha256 = Get-CpaStackFileHash -Path $extraTargetExe
        $extraTargetFixture.Journal.targetCpaRuntimeManifestSha256 = [string](Get-CpaStackTreeManifest -Root $extraTargetFixture.TargetCpa).sha256
        Write-TestJson -Path (Join-Path $extraTargetRoot 'state\initialize.pending.json') -Value $extraTargetFixture.Journal
        Write-ForeignCpaSwitchJournal -Fixture $extraTargetFixture
        Protect-RecoveryFixtureTree -Root $extraTargetRoot
        $extraTargetSentinel = Start-GuardedTargetSentinel -Guard $productionGuard -Executable $extraTargetExe -CaseRoot (Join-Path $hostRoot 'extra-target-process-sentinel')
        $extraTargetProcess = $extraTargetSentinel.Process
        try {
            Assert-True (Test-Path -LiteralPath $extraTargetSentinel.ReadyPath -PathType Leaf) "$hostName extra target-path sentinel reached ready before guard release"
            Assert-True (Test-Path -LiteralPath $extraTargetSentinel.GoPath -PathType Leaf) "$hostName extra target-path sentinel was released only after guard registration"
            $extraTargetBefore = Get-TestTreeSnapshot -Root $extraTargetRoot
            $extraTargetRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $initializeScript -Root $extraTargetRoot -Mode Initialize -CaseRoot (Join-Path $hostRoot 'extra-target-process-case')
            Assert-True ($extraTargetRun.ExitCode -ne 0) "$hostName switching recovery with an extra target-path process fails closed"
            Assert-True (($extraTargetRun.Stdout + $extraTargetRun.Stderr) -match 'process without subordinate process identity evidence') "$hostName switching recovery reports the unowned target-path process. Exit=$($extraTargetRun.ExitCode) Stdout=[$($extraTargetRun.Stdout)] Stderr=[$($extraTargetRun.Stderr)]"
            Assert-True (-not $extraTargetProcess.HasExited) "$hostName switching recovery leaves an extra target-path process running"
            Assert-Equal $extraTargetBefore (Get-TestTreeSnapshot -Root $extraTargetRoot) "$hostName switching recovery leaves the tree unchanged when an extra target-path process exists"
        } finally {
            if (-not $extraTargetProcess.HasExited) {
                $extraTargetProcess.Kill()
                [void]$extraTargetProcess.WaitForExit(5000)
            }
            $extraTargetProcess.Dispose()
        }

        $historicalResultRoot = Join-Path $hostRoot 'historical-result-root'
        [void](New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'historical-result-source') -Root $historicalResultRoot)
        Write-TestJson -Path (Join-Path $historicalResultRoot 'state\cpa-migration-switch.json.previous') -Value ([ordered]@{
            operation = 'switch-cpa'
            operationId = [guid]::NewGuid().ToString('N')
            success = $false
            error = 'historical result from a completed attempt'
        })
        $historicalForeignPending = Join-Path $historicalResultRoot ('rollback\pending-cpa-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $historicalForeignPending | Out-Null
        Write-TestText -Path (Join-Path $historicalForeignPending 'foreign.txt') -Value 'must-remain'
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $historicalResultRoot `
            -CaseRoot (Join-Path $hostRoot 'historical-result-case') -ErrorPattern 'cannot belong to a non-in-place initialization switch' -Message "$hostName historical stable result does not bind the current operation"

        $foreignRollbackRoot = Join-Path $hostRoot 'foreign-rollback-root'
        [void](New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'foreign-rollback-source') -Root $foreignRollbackRoot)
        $pending = Join-Path $foreignRollbackRoot ('rollback\pending-cpa-' + [guid]::NewGuid().ToString('N'))
        $staging = Join-Path $foreignRollbackRoot ('rollback\staging-manager-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $pending | Out-Null
        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        Write-TestText -Path (Join-Path $pending 'foreign.txt') -Value 'must-remain'
        Write-TestText -Path (Join-Path $staging 'foreign.txt') -Value 'must-remain'
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $foreignRollbackRoot `
            -CaseRoot (Join-Path $hostRoot 'foreign-rollback-case') -ErrorPattern 'cannot belong to a non-in-place initialization switch' -Message "$hostName foreign rollback pending/staging artifacts"

        # A schema-1 journal cannot safely reinterpret an isolated dynamic-port
        # fixture as the legacy fixed-slot installation. It must fail before
        # listener discovery and preserve every unrelated rollback artifact.
        $legacySchemaRoot = Join-Path $hostRoot 'legacy-schema-root'
        $legacySchemaFixture = New-FullJournalRoot -CaseRoot (Join-Path $hostRoot 'legacy-schema-source') -Root $legacySchemaRoot
        $legacyJournal = $legacySchemaFixture.Journal
        $legacyJournal.schemaVersion = 1
        foreach ($field in @('operationId', 'targetCpaSha256', 'targetManagerSha256')) {
            [void]$legacyJournal.Remove($field)
        }
        Write-TestJson -Path (Join-Path $legacySchemaRoot 'state\initialize.pending.json') -Value $legacyJournal
        $legacyForeignPending = Join-Path $legacySchemaRoot ('rollback\pending-manager-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $legacyForeignPending | Out-Null
        Write-TestText -Path (Join-Path $legacyForeignPending 'foreign.txt') -Value 'must-remain'
        Assert-FailedWithoutRootMutation -PowerShell $powerShell -Runner $runner -InitializeScript $initializeScript -Root $legacySchemaRoot `
            -CaseRoot (Join-Path $hostRoot 'legacy-schema-case') -ErrorPattern 'Manager baseline.*cpaBaseUrl' -Message "$hostName schema-1 recovery refuses an isolated dynamic-port fixture"

        $orphanPreviousRoot = Join-Path $hostRoot 'orphan-previous-root'
        New-Item -ItemType Directory -Force -Path (Join-Path $orphanPreviousRoot 'state') | Out-Null
        Write-TestJson -Path (Join-Path $orphanPreviousRoot 'state\initialize.pending.json.previous') -Value ([ordered]@{
            schemaVersion = 2
            operation = 'initialize-canonical-stack'
            operationId = [guid]::NewGuid().ToString('N')
        })
        $orphanPreviousBefore = Get-TestTreeSnapshot -Root $orphanPreviousRoot
        $orphanPreviousRun = Invoke-GuardedRecoveryCommand -PowerShell $powerShell -Runner $runner -ScriptPath $publicScript -Root $orphanPreviousRoot -Mode PublicRecover -CaseRoot (Join-Path $hostRoot 'orphan-previous-case')
        Assert-True ($orphanPreviousRun.ExitCode -ne 0) "$hostName public recover rejects an orphan initialize previous generation"
        Assert-Equal 'ManualRecoveryRequired' ([string]$orphanPreviousRun.Json.outcome) "$hostName orphan initialize previous generation requires manual recovery"
        Assert-Equal $orphanPreviousBefore (Get-TestTreeSnapshot -Root $orphanPreviousRoot) "$hostName orphan initialize previous generation remains untouched"
    }

    Write-Host 'Initialize recovery safety tests passed.'
} finally {
    $cleanupError = $null
    if ($null -ne $productionGuard) {
        try {
            Close-CpaStackProductionGuard -Guard $productionGuard
        } catch {
            $cleanupError = 'Initialize recovery test process cleanup failed: ' + $_.Exception.Message
        }
    }
    try {
        if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
    } catch {
        $pathCleanupError = 'Initialize recovery test path cleanup failed: ' + $_.Exception.Message
        $cleanupError = if ([string]::IsNullOrWhiteSpace($cleanupError)) { $pathCleanupError } else { $cleanupError + ' ' + $pathCleanupError }
    }
    if (-not [string]::IsNullOrWhiteSpace($cleanupError)) { throw $cleanupError }
}
