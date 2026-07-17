[CmdletBinding()]
param(
    [string]$ControlRoot,
    [string]$SourceCpaRuntime,
    [string]$SourceCpaConfig,
    [string]$SourceManagerRuntime,
    [string]$SourceManagerData,
    [string]$LegacyStartScript,
    [string]$DesktopShortcut,
    [switch]$UpdateDesktopShortcut,
    [string]$SecretsInputPath,
    [switch]$ExposeToLan,
    [ValidateRange(1, 65535)][int]$CpaPort = 8317,
    [ValidateRange(1, 65535)][int]$ManagerPort = 18317,
    [string]$CpaVersion = "unknown",
    [string]$ManagerVersion = "unknown",
    [switch]$RecoverOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")

$ControlRoot = Resolve-CpaStackControlRoot -RequestedRoot $ControlRoot
$ControlRoot = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
if ($DesktopShortcut -and -not $UpdateDesktopShortcut) {
    throw 'Passing -DesktopShortcut requires the explicit -UpdateDesktopShortcut switch.'
}

$configDir = Join-Path $ControlRoot "config"
$targetCpaRuntime = Join-Path $ControlRoot "runtime\cli-proxy-api"
$targetManagerRuntime = Join-Path $ControlRoot "runtime\manager-plus"
$targetManagerData = Join-Path $ControlRoot "data\manager-plus"
$opsDir = Join-Path $ControlRoot "ops"
$stateDir = Join-Path $ControlRoot "state"
$resultPath = Join-Path $stateDir "last-operation.json"
$initializeJournalPath = Join-Path $stateDir "initialize.pending.json"
$currentStatePath = Join-Path $stateDir "current.json"
$stackConfigPath = Join-Path $configDir "stack.psd1"
$secretsPath = Join-Path $configDir "secrets.local.json"
$newStartScript = Join-Path $opsDir "Start-CPA-Stack.ps1"
$migrationRollback = Join-Path $ControlRoot "rollback\legacy-migration"
$sourceManagerBaseline = $null
$sourceManagerSnapshot = $null
$sourceManagerBindAddress = "127.0.0.1"
$operationMutex = $null
$switchPhaseStarted = $false
$legacyRestored = $false
$managerRecoveryBlocked = $false
$initializeJournal = $null
$recoveryAttempted = $false
$recoveryCompleted = $false
$preparationStarted = $false
$instanceMarker = $null
$candidatePortPlan = $null
$recoveryContractValidated = $false
$persistOperationResult = -not $RecoverOnly
$validatedInitializationJournalFiles = @()
$validatedInitializationSwitchFiles = @()
$validatedInitializationTopContract = $null
$validatedInitializationSubordinateArtifactCount = 0
$result = [ordered]@{
    operation = "initialize-canonical-stack"
    success = $false
    rolledBack = $false
    canonicalRoot = $ControlRoot
    cpa = $null
    manager = $null
    shortcut = $null
    recoveredInterruptedState = $false
    recoveryDisposition = $null
    journalCleanupWarning = $null
    excluded = @("legacy _updates", "legacy _backups", ".local-18318*", "auth\logs", "server.log", "old management.html snapshots")
    error = $null
}

function Invoke-ChildPowerShell {
    param([string]$Script, [string[]]$Arguments)
    [void](Invoke-InProcessPowerShellJson -Script $Script -Arguments $Arguments)
}

function Invoke-ChildPowerShellJson {
    param([string]$Script, [string[]]$Arguments)

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne 0) {
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

function Copy-CurrentCpaRuntime {
    param([string]$Source, [string]$Destination, [string]$Config)

    Assert-CpaStackLegacyCpaSource -Runtime $Source -ConfigPath $Config
    Assert-CpaStackChildPath -Root $ControlRoot -Path $Destination
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($name in @("cli-proxy-api.exe", "config.example.yaml", "LICENSE", "README.md", "README_CN.md")) {
        $sourcePath = Join-Path $Source $name
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $Destination $name) -Force
        }
    }
    $sourceStatic = Join-Path $Source "static"
    if (Test-Path -LiteralPath $sourceStatic) {
        Copy-Item -LiteralPath $sourceStatic -Destination (Join-Path $Destination "static") -Recurse -Force
    }
    Copy-Item -LiteralPath $Config -Destination (Join-Path $Destination "config.yaml") -Force
    if (-not $ExposeToLan) {
        $targetConfig = Join-Path $Destination 'config.yaml'
        $content = [System.IO.File]::ReadAllText($targetConfig, [System.Text.UTF8Encoding]::new($false, $true))
        if ($content -match '(?m)^host:\s*.*$') {
            $content = [regex]::Replace($content, '(?m)^host:\s*.*$', 'host: "127.0.0.1"', 1)
        } else {
            $content = "host: `"127.0.0.1`"`r`n" + $content
        }
        [System.IO.File]::WriteAllText($targetConfig, $content, [System.Text.UTF8Encoding]::new($false))
    }
    $targetConfig = Join-Path $Destination 'config.yaml'
    $content = [System.IO.File]::ReadAllText($targetConfig, [System.Text.UTF8Encoding]::new($false, $true))
    $updated = [regex]::Replace($content, '(?m)^port:\s*\d+\s*$', "port: $CpaPort", 1)
    if ($updated -eq $content -and $content -notmatch "(?m)^port:\s*$CpaPort\s*$") {
        throw 'CPA source config does not contain a replaceable top-level port.'
    }
    [System.IO.File]::WriteAllText($targetConfig, $updated, [System.Text.UTF8Encoding]::new($false))
    Copy-CpaStackAuthTree -Source (Join-Path $Source "auth") -Destination (Join-Path $Destination "auth")
    $plugins = Join-Path $Source "plugins"
    if (Test-Path -LiteralPath $plugins) {
        Copy-CpaStackPluginTree -Source $plugins -Destination (Join-Path $Destination "plugins")
    }
}

function Copy-CurrentManagerRuntime {
    param([string]$Source, [string]$Destination)

    Assert-CpaStackChildPath -Root $ControlRoot -Path $Destination
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($name in @("cpa-manager-plus.exe", "cpa-manager-plusctl.ps1", "LICENSE", "README.md", "README_CN.md", "config.json")) {
        $sourcePath = Join-Path $Source $name
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $Destination $name) -Force
        }
    }
    $docs = Join-Path $Source "docs"
    if (Test-Path -LiteralPath $docs) {
        Copy-Item -LiteralPath $docs -Destination (Join-Path $Destination "docs") -Recurse -Force
    }
}

function Write-CanonicalConfiguration {
    param(
        [bool]$RequestMonitoringEnabled,
        [string]$ManagerBindAddress
    )

    $monitoringLiteral = if ($RequestMonitoringEnabled) { '$true' } else { '$false' }
    $content = @"
@{
    SchemaVersion = 1
    StartupTimeoutSeconds = 40
    HttpTimeoutSeconds = 5
    Cpa = @{
        Executable = 'runtime\cli-proxy-api\cli-proxy-api.exe'
        WorkingDirectory = 'runtime\cli-proxy-api'
        Config = 'runtime\cli-proxy-api\config.yaml'
        Port = $CpaPort
    }
    Manager = @{
        Executable = 'runtime\manager-plus\cpa-manager-plus.exe'
        WorkingDirectory = 'runtime\manager-plus'
        DataDirectory = 'data\manager-plus'
        Port = $ManagerPort
        BindAddress = '$ManagerBindAddress'
        RequestMonitoringEnabled = $monitoringLiteral
    }
    Browser = @{
        Url = 'http://127.0.0.1:$ManagerPort/management.html'
        Executable = ''
    }
}
"@
    [System.IO.File]::WriteAllText($stackConfigPath, $content, [System.Text.UTF8Encoding]::new($false))
    Protect-CpaStackSecretFile -Path $stackConfigPath
}

function Initialize-Secrets {
    if ($SecretsInputPath) {
        $inputSecrets = Read-CpaStackSecretJson -Path $SecretsInputPath -Description 'Secrets input file'
        foreach ($field in @('cpaClientApiKey', 'cpaManagementKey', 'managerAdminKey')) {
            $property = $inputSecrets.PSObject.Properties[$field]
            if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw "Secrets input is missing required field: $field"
            }
        }
        $managerAdminKey = [string]$inputSecrets.managerAdminKey
        $cpaManagementKey = [string]$inputSecrets.cpaManagementKey
        $cpaClientApiKey = [string]$inputSecrets.cpaClientApiKey
    } else {
        if (-not $LegacyStartScript) {
            throw 'A legacy start script or -SecretsInputPath is required to import the three keys.'
        }
        $managerAdminKey = Get-CpaStackLegacySecret -StartScript $LegacyStartScript -VariableName managerAdminKey
        $cpaManagementKey = Get-CpaStackLegacySecret -StartScript $LegacyStartScript -VariableName cpaManagementKey
        $cpaClientApiKey = Get-CpaStackClientApiKey -ConfigPath $SourceCpaConfig
    }
    $secretObject = [ordered]@{
        cpaClientApiKey = $cpaClientApiKey
        cpaManagementKey = $cpaManagementKey
        managerAdminKey = $managerAdminKey
    }
    $tempSecret = $secretsPath + ".secure-" + [guid]::NewGuid().ToString("N")
    try {
        [System.IO.File]::WriteAllText($tempSecret, "{}", [System.Text.UTF8Encoding]::new($false))
        Protect-CpaStackSecretFile -Path $tempSecret
        $json = $secretObject | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($tempSecret, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $secretsPath -PathType Leaf) {
            $secretBackup = $secretsPath + ".previous"
            [System.IO.File]::Replace($tempSecret, $secretsPath, $secretBackup)
            if (Test-Path -LiteralPath $secretBackup) {
                Protect-CpaStackSecretFile -Path $secretBackup
                [System.IO.File]::Delete($secretBackup)
            }
        } else {
            [System.IO.File]::Move($tempSecret, $secretsPath)
        }
        Protect-CpaStackSecretFile -Path $secretsPath
    } finally {
        if (Test-Path -LiteralPath $tempSecret) {
            Remove-Item -LiteralPath $tempSecret -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-LegacyCpa {
    $exe = Join-Path $SourceCpaRuntime "cli-proxy-api.exe"
    Assert-NoInitializationProcessAtPath -ExpectedPath $exe -Description 'Legacy CPA start'
    Protect-CpaStackPrivateDirectory -Path $SourceCpaRuntime
    Protect-CpaStackSecretFile -Path $exe
    Protect-CpaStackSecretFile -Path $SourceCpaConfig
    Protect-CpaStackPrivateTree -Root (Join-Path $SourceCpaRuntime 'auth')
    $plugins = Join-Path $SourceCpaRuntime 'plugins'
    if (Test-Path -LiteralPath $plugins) { Protect-CpaStackPrivateTree -Root $plugins }

    $expectedHash = [string]$initializeJournal.sourceCpaSha256
    $process = $null
    try {
        $process = Start-CpaStackProcess -FilePath $exe -Arguments "-config `"$SourceCpaConfig`"" -WorkingDirectory $SourceCpaRuntime -MinimalEnvironment
        [void](Wait-CpaStackTrustedListener -Port $CpaPort -ExpectedPath $exe -ExpectedProcessId $process.Id -ExpectedHash $expectedHash -Seconds 35)
        $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
        [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$CpaPort/v0/management/config" -Headers @{ Authorization = "Bearer $($secrets.cpaManagementKey)" } -Seconds 35)
        $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$CpaPort/v1/models" -Headers @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" } -Seconds 20
        if (-not $models.data -or @($models.data).Count -lt 1) {
            throw "Legacy CPA did not recover with a non-empty model list."
        }
    } catch {
        if ($null -ne $process) { Stop-CpaStackStartedProcess -Process $process -ExpectedPath $exe }
        throw
    } finally {
        if ($null -ne $process -and $process -is [System.IDisposable]) { $process.Dispose() }
    }
}

function Set-SourceManagerSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string]$Description = 'Manager source snapshot'
    )

    if ($null -eq $Snapshot.quick_check -or -not [bool]$Snapshot.quick_check.ok -or
        $null -eq $Snapshot.usage_events -or $null -eq $Snapshot.critical_table_counts) {
        throw "$Description is missing the trusted SQLite recovery fields."
    }
    $script:sourceManagerSnapshot = $Snapshot
}

function Resolve-SourceManagerSnapshot {
    if ($null -ne $sourceManagerSnapshot) { return }
    if ($null -eq $initializeJournal) { return }

    foreach ($path in @(
        (Join-Path $stateDir 'manager-migration-switch.json'),
        (Join-Path $stateDir 'switch-manager.pending.json')
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $state = Read-CpaStackJson -Path $path
        $stateSourceRuntime = if ($null -ne $state.PSObject.Properties['sourceRuntime']) {
            [string]$state.sourceRuntime
        } else {
            Split-Path -Parent ([string]$state.sourcePath)
        }
        $stateSourceData = [string]$state.sourceData
        if ([string]$state.oldHash -ne [string]$initializeJournal.sourceManagerSha256 -or
            -not [string]::Equals([System.IO.Path]::GetFullPath($stateSourceRuntime).TrimEnd('\'), [System.IO.Path]::GetFullPath($SourceManagerRuntime).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([System.IO.Path]::GetFullPath($stateSourceData).TrimEnd('\'), [System.IO.Path]::GetFullPath($SourceManagerData).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Manager recovery snapshot state is not bound to the initialization source: $path"
        }
        if ($null -ne $state.PSObject.Properties['instanceId'] -and [string]$state.instanceId -ne [string]$initializeJournal.instanceId) {
            throw "Manager recovery snapshot state belongs to another instance: $path"
        }
        if ($null -ne $state.sourceSnapshot) {
            Set-SourceManagerSnapshot -Snapshot $state.sourceSnapshot -Description "Manager recovery snapshot in $path"
            return
        }
    }
}

function Start-LegacyManager {
    $exe = Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"
    Assert-NoInitializationProcessAtPath -ExpectedPath $exe -Description 'Legacy Manager start'
    $dataKey = Join-Path $SourceManagerData 'data.key'
    if ($null -eq $initializeJournal -or
        [string]$initializeJournal.sourceManagerSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        [string]$initializeJournal.sourceDataKeySha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Legacy Manager recovery requires recorded executable and data-key hashes.'
    }
    Resolve-SourceManagerSnapshot
    if ($null -eq $sourceManagerSnapshot) {
        throw 'Legacy Manager recovery requires a stopped-source SQLite business-data baseline.'
    }
    $expectedExecutableHash = [string]$initializeJournal.sourceManagerSha256
    $expectedDataKeyHash = [string]$initializeJournal.sourceDataKeySha256
    $expectedSnapshot = [pscustomobject]@{ snapshot = $sourceManagerSnapshot }
    $preVerification = Join-Path $ControlRoot ('work\mv-' + [guid]::NewGuid().ToString('N'))
    $postVerification = Join-Path $ControlRoot ('work\mv-' + [guid]::NewGuid().ToString('N'))
    Assert-CpaStackChildPath -Root $ControlRoot -Path $preVerification
    Assert-CpaStackChildPath -Root $ControlRoot -Path $postVerification
    try {
        [void](Assert-CpaStackManagerRecoverySource -Runtime $SourceManagerRuntime -Data $SourceManagerData -ExpectedExecutableSha256 $expectedExecutableHash -ExpectedDataKeySha256 $expectedDataKeyHash -ExpectedSnapshot $expectedSnapshot -VerificationRoot $preVerification)
        Protect-CpaStackPrivateDirectory -Path $SourceManagerRuntime
        Protect-CpaStackSecretFile -Path $exe
        Protect-CpaStackPrivateTree -Root $SourceManagerData
        [void](Assert-CpaStackManagerRecoverySource -Runtime $SourceManagerRuntime -Data $SourceManagerData -ExpectedExecutableSha256 $expectedExecutableHash -ExpectedDataKeySha256 $expectedDataKeyHash -ExpectedSnapshot $expectedSnapshot -VerificationRoot $postVerification)
    } finally {
        foreach ($verificationRoot in @($preVerification, $postVerification)) {
            if (Test-Path -LiteralPath $verificationRoot) {
                Remove-Item -LiteralPath $verificationRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ((Get-CpaStackFileHash -Path $exe) -ne $expectedExecutableHash -or
        (Get-CpaStackFileHash -Path $dataKey) -ne $expectedDataKeyHash) {
        throw 'Legacy Manager recovery source changed immediately before execution.'
    }
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $environment = @{
        HTTP_ADDR = "${sourceManagerBindAddress}:$ManagerPort"
        USAGE_DATA_DIR = $SourceManagerData
        USAGE_DB_PATH = (Join-Path $SourceManagerData "usage.sqlite")
        CPA_MANAGER_ADMIN_KEY = [string]$secrets.managerAdminKey
    }
    $process = $null
    try {
        $process = Start-CpaStackProcess -FilePath $exe -WorkingDirectory $SourceManagerRuntime -Environment $environment -RemoveEnvironment @("PANEL_PATH") -MinimalEnvironment
        [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $exe -ExpectedProcessId $process.Id -ExpectedHash $expectedExecutableHash -AllowedAddresses @($sourceManagerBindAddress) -Seconds 35)
        [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/health" -Seconds 35)
    } catch {
        if ($null -ne $process) {
            Stop-CpaStackStartedProcess -Process $process -ExpectedPath $exe
        }
        throw
    } finally {
        if ($null -ne $process -and $process -is [System.IDisposable]) { $process.Dispose() }
    }
}

function Get-InitializationProcessContracts {
    $sourceCpaHost = Get-CpaStackConfigHost -ConfigPath $SourceCpaConfig
    $targetCpaHost = if ([string]::IsNullOrWhiteSpace([string]$initializeJournal.targetCpaHost)) { $sourceCpaHost } else { [string]$initializeJournal.targetCpaHost }
    $sourceCpaAddresses = if ($sourceCpaHost -ieq 'localhost') { @('127.0.0.1', '::1') } else { @($sourceCpaHost) }
    $targetCpaAddresses = if ($targetCpaHost -ieq 'localhost') { @('127.0.0.1', '::1') } else { @($targetCpaHost) }
    $managerAddresses = if ($sourceManagerBindAddress -ieq 'localhost') { @('127.0.0.1', '::1') } else { @($sourceManagerBindAddress) }
    $targetCpaHashProperty = $initializeJournal.PSObject.Properties['targetCpaSha256']
    $targetManagerHashProperty = $initializeJournal.PSObject.Properties['targetManagerSha256']
    $targetCpaHash = if ($null -ne $targetCpaHashProperty -and [string]$targetCpaHashProperty.Value -match '^[0-9A-Fa-f]{64}$') { [string]$targetCpaHashProperty.Value } else { [string]$initializeJournal.sourceCpaSha256 }
    $targetManagerHash = if ($null -ne $targetManagerHashProperty -and [string]$targetManagerHashProperty.Value -match '^[0-9A-Fa-f]{64}$') { [string]$targetManagerHashProperty.Value } else { [string]$initializeJournal.sourceManagerSha256 }
    return @(
        [pscustomobject]@{
            Component = 'CPA'
            Port = $CpaPort
            Source = Join-Path $SourceCpaRuntime 'cli-proxy-api.exe'
            Target = Join-Path $targetCpaRuntime 'cli-proxy-api.exe'
            SourceHash = [string]$initializeJournal.sourceCpaSha256
            TargetHash = $targetCpaHash
            SourceAddresses = $sourceCpaAddresses
            TargetAddresses = $targetCpaAddresses
        },
        [pscustomobject]@{
            Component = 'Manager'
            Port = $ManagerPort
            Source = Join-Path $SourceManagerRuntime 'cpa-manager-plus.exe'
            Target = Join-Path $targetManagerRuntime 'cpa-manager-plus.exe'
            SourceHash = [string]$initializeJournal.sourceManagerSha256
            TargetHash = $targetManagerHash
            SourceAddresses = $managerAddresses
            TargetAddresses = $managerAddresses
        }
    )
}

function Get-InitializationProcessesByExecutablePath {
    param([Parameter(Mandatory = $true)][string]$ExpectedPath)

    $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath)
    $escapedPath = $expectedFull.Replace('\', '\\').Replace("'", "\'")
    $records = @(Get-CimInstance Win32_Process -Filter "ExecutablePath = '$escapedPath'" -ErrorAction Stop)
    foreach ($record in $records) {
        if ([string]::IsNullOrWhiteSpace([string]$record.ExecutablePath) -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$record.ExecutablePath), $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Initialization recovery process enumeration returned an identity outside the exact executable path: $expectedFull"
        }
    }
    return $records
}

function Assert-NoInitializationProcessAtPath {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $processes = @(Get-InitializationProcessesByExecutablePath -ExpectedPath $ExpectedPath)
    if ($processes.Count -gt 0) {
        throw "$Description found a process without fixed transaction identity at $ExpectedPath."
    }
}

function Assert-InitializationProcessOwnership {
    param($TopContract)

    if ($TopContract.PhaseIndex -lt (Get-InitializationPhaseIndex -Phase 'switching')) { return }

    $entries = @(Get-InitializationProcessContracts)
    $trustedFormalProcessIds = @{}
    foreach ($entry in $entries) {
        $listener = Get-CpaStackListener -Port $entry.Port
        if (-not $listener) { continue }

        if ($listener.ExecutablePath -ieq $entry.Source) {
            $expectedPath = $entry.Source
            $expectedHash = $entry.SourceHash
            $allowedAddresses = $entry.SourceAddresses
        } elseif ($listener.ExecutablePath -ieq $entry.Target) {
            $expectedPath = $entry.Target
            $expectedHash = $entry.TargetHash
            $allowedAddresses = $entry.TargetAddresses
        } else {
            throw "Unexpected process owns port $($entry.Port) during interrupted initialization recovery."
        }
        [void](Wait-CpaStackTrustedListener -Port $entry.Port -ExpectedPath $expectedPath -ExpectedProcessId $listener.ProcessId -ExpectedHash $expectedHash -AllowedAddresses $allowedAddresses -Seconds 2)
        $trustedFormalProcessIds[[System.IO.Path]::GetFullPath($expectedPath)] = [int]$listener.ProcessId
    }

    foreach ($entry in $entries) {
        foreach ($expectedPath in @($entry.Source, $entry.Target)) {
            $pathFull = [System.IO.Path]::GetFullPath($expectedPath)
            foreach ($processRecord in @(Get-InitializationProcessesByExecutablePath -ExpectedPath $pathFull)) {
                if (-not $trustedFormalProcessIds.ContainsKey($pathFull) -or
                    [int]$processRecord.ProcessId -ne [int]$trustedFormalProcessIds[$pathFull]) {
                    throw "Initialization recovery found a process without subordinate process identity evidence at $pathFull."
                }
            }
        }
    }
}

function Stop-UncommittedCanonicalProcesses {
    param($TopContract)

    if ($TopContract.PhaseIndex -lt (Get-InitializationPhaseIndex -Phase 'switching')) { return }

    $entries = @(Get-InitializationProcessContracts)
    $targetListeners = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($entry in $entries) {
            $listener = Get-CpaStackListener -Port $entry.Port
            if (-not $listener) { continue }
            if ($listener.ExecutablePath -ieq $entry.Source) {
                [void](Wait-CpaStackTrustedListener -Port $entry.Port -ExpectedPath $entry.Source -ExpectedProcessId $listener.ProcessId -ExpectedHash $entry.SourceHash -AllowedAddresses $entry.SourceAddresses -Seconds 2)
                continue
            }
            if ($listener.ExecutablePath -ine $entry.Target) {
                throw "Unexpected process owns port $($entry.Port) during interrupted initialization recovery."
            }
            [void](Wait-CpaStackTrustedListener -Port $entry.Port -ExpectedPath $entry.Target -ExpectedProcessId $listener.ProcessId -ExpectedHash $entry.TargetHash -AllowedAddresses $entry.TargetAddresses -Seconds 2)
            $process = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $entry.Target
            $targetListeners.Add([pscustomobject]@{ Entry = $entry; Process = $process })
        }

        foreach ($owned in $targetListeners) {
            Stop-CpaStackPort -Port $owned.Entry.Port -ExpectedPath $owned.Entry.Target -ExpectedProcess $owned.Process -RequireExecutableWriteAccess
        }
    } finally {
        foreach ($owned in $targetListeners) {
            if ($owned.Process -is [System.IDisposable]) { $owned.Process.Dispose() }
        }
    }

    foreach ($entry in $entries) {
        $listener = Get-CpaStackListener -Port $entry.Port
        if ($listener -and $listener.ExecutablePath -ieq $entry.Target) {
            throw "Uncommitted target process remained on port $($entry.Port) after quarantine."
        }
        if ($listener -and $listener.ExecutablePath -ine $entry.Source) {
            throw "Unexpected process owns port $($entry.Port) during interrupted initialization recovery."
        }
    }
}

function Restore-LegacyCpa {
    $cpaContract = @(Get-InitializationProcessContracts | Where-Object { $_.Component -eq 'CPA' })[0]
    $cpaListener = Get-CpaStackListener -Port $CpaPort
    if ($cpaListener) {
        if ($cpaListener.ExecutablePath -ieq $cpaContract.Source) {
            $expectedHash = $cpaContract.SourceHash
            $allowedAddresses = $cpaContract.SourceAddresses
        } elseif ($cpaListener.ExecutablePath -ieq $cpaContract.Target) {
            $expectedHash = $cpaContract.TargetHash
            $allowedAddresses = $cpaContract.TargetAddresses
        } else {
            throw "Unexpected process owns CPA formal port $CpaPort during legacy recovery."
        }
        [void](Wait-CpaStackTrustedListener -Port $CpaPort -ExpectedPath $cpaListener.ExecutablePath -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash $expectedHash -AllowedAddresses $allowedAddresses -Seconds 2)
        $cpaProcess = Get-CpaStackFixedListenerProcess -Listener $cpaListener -ExpectedPath $cpaListener.ExecutablePath
        try {
            Stop-CpaStackPort -Port $CpaPort -ExpectedPath $cpaListener.ExecutablePath -ExpectedProcess $cpaProcess
        } finally {
            if ($cpaProcess -is [System.IDisposable]) { $cpaProcess.Dispose() }
        }
    }
    Start-LegacyCpa
}

function Assert-LegacyStackState {
    if ($null -eq $sourceManagerBaseline) { throw "Legacy Manager baseline is unavailable." }
    $sourceCpaExe = Join-Path $SourceCpaRuntime "cli-proxy-api.exe"
    $sourceManagerExe = Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"
    $expectedCpaHash = if ($null -ne $initializeJournal) { [string]$initializeJournal.sourceCpaSha256 } else { Get-CpaStackFileHash -Path $sourceCpaExe }
    $expectedManagerHash = if ($null -ne $initializeJournal) { [string]$initializeJournal.sourceManagerSha256 } else { Get-CpaStackFileHash -Path $sourceManagerExe }
    if ($expectedCpaHash -notmatch '^[0-9A-Fa-f]{64}$' -or $expectedManagerHash -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Legacy stack verification requires recorded executable hashes.'
    }
    if ((Get-CpaStackFileHash -Path $sourceCpaExe) -ne $expectedCpaHash -or
        (Get-CpaStackFileHash -Path $sourceManagerExe) -ne $expectedManagerHash) {
        throw 'Legacy executable changed after initialization recorded its identity.'
    }
    if ($null -ne $initializeJournal) {
        if ((Get-CpaStackFileHash -Path $SourceCpaConfig) -ne [string]$initializeJournal.sourceCpaConfigSha256 -or
            (Get-CpaStackFileHash -Path (Join-Path $SourceManagerData 'data.key')) -ne [string]$initializeJournal.sourceDataKeySha256) {
            throw 'Legacy config or Manager data.key changed after initialization recorded it.'
        }
    }
    $cpaListener = Get-CpaStackListener -Port $CpaPort
    $managerListener = Get-CpaStackListener -Port $ManagerPort
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine $sourceCpaExe) { throw "Legacy CPA does not own formal port $CpaPort." }
    if (-not $managerListener -or $managerListener.ExecutablePath -ine $sourceManagerExe) { throw "Legacy Manager does not own formal port $ManagerPort." }
    [void](Wait-CpaStackTrustedListener -Port $CpaPort -ExpectedPath $sourceCpaExe -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash $expectedCpaHash -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $sourceManagerExe -ExpectedProcessId $managerListener.ProcessId -ExpectedHash $expectedManagerHash -Seconds 2)
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$CpaPort/v1/models" -Headers @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" } -Seconds 20
    if (-not $models.data -or @($models.data).Count -lt 1) { throw "Legacy CPA model list is empty." }
    Resolve-SourceManagerSnapshot
    if ($null -ne $sourceManagerSnapshot) {
        $verificationRoot = Join-Path $ControlRoot ('work\mv-' + [guid]::NewGuid().ToString('N'))
        Assert-CpaStackChildPath -Root $ControlRoot -Path $verificationRoot
        try {
            New-Item -ItemType Directory -Path $verificationRoot | Out-Null
            $currentSnapshot = Invoke-CpaStackSqliteBackup `
                -Source (Join-Path $SourceManagerData 'usage.sqlite') `
                -Destination (Join-Path $verificationRoot 'usage.sqlite') `
                -ResultPath (Join-Path $verificationRoot 'sqlite-current.json')
            if (-not [bool]$currentSnapshot.snapshot.quick_check.ok -or
                ([bool]$sourceManagerSnapshot.usage_events.exists -and -not [bool]$currentSnapshot.snapshot.usage_events.exists)) {
                throw 'Recovered Manager database failed quick_check or lost the required usage_events table.'
            }
            foreach ($field in @('count', 'max_id', 'max_timestamp_ms')) {
                $expectedValue = $sourceManagerSnapshot.usage_events.$field
                if ($null -ne $expectedValue -and [Int64]$currentSnapshot.snapshot.usage_events.$field -lt [Int64]$expectedValue) {
                    throw "Recovered Manager history regressed below the trusted snapshot: $field"
                }
            }
            foreach ($table in @('settings', 'model_prices')) {
                $expectedProperty = $sourceManagerSnapshot.critical_table_counts.PSObject.Properties[$table]
                if ($null -eq $expectedProperty -or $null -eq $expectedProperty.Value) { continue }
                $actualProperty = $currentSnapshot.snapshot.critical_table_counts.PSObject.Properties[$table]
                if ($null -eq $actualProperty -or $null -eq $actualProperty.Value -or [Int64]$actualProperty.Value -lt [Int64]$expectedProperty.Value) {
                    throw "Recovered Manager required business table regressed below the trusted baseline: $table"
                }
            }
        } finally {
            if (Test-Path -LiteralPath $verificationRoot) {
                Remove-Item -LiteralPath $verificationRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    [void](Set-CpaStackManagerCollector -ManagerPort $ManagerPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$sourceManagerBaseline.collectorEnabled) -Baseline $sourceManagerBaseline)
    [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey -Expected $sourceManagerBaseline)
    $status = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/status" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ([System.IO.Path]::GetFullPath([string]$status.dbPath) -ine [System.IO.Path]::GetFullPath((Join-Path $SourceManagerData "usage.sqlite"))) {
        throw "Legacy Manager database path does not match the migration source."
    }
    $info = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/info" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ($null -eq $info.PSObject.Properties['hasHistoricalData']) { throw "Legacy Manager history state is unavailable." }
    Assert-CpaStackPath -Path (Join-Path $SourceManagerData "data.key") -PathType Leaf
}

function Restore-LegacyStack {
    $managerContract = @(Get-InitializationProcessContracts | Where-Object { $_.Component -eq 'Manager' })[0]
    $managerListener = Get-CpaStackListener -Port $ManagerPort
    $startLegacyManager = $true
    if ($managerListener) {
        $allowedManagerPaths = @((Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"), (Join-Path $targetManagerRuntime "cpa-manager-plus.exe"))
        if ($allowedManagerPaths -inotcontains $managerListener.ExecutablePath) { throw "Unexpected process owns Manager formal port $ManagerPort during legacy recovery." }
        if ($managerListener.ExecutablePath -ieq (Join-Path $SourceManagerRuntime 'cpa-manager-plus.exe')) {
            Assert-CpaStackLegacyManagerSource -Runtime $SourceManagerRuntime -Data $SourceManagerData
            if ((Get-CpaStackFileHash -Path $managerListener.ExecutablePath) -ne [string]$initializeJournal.sourceManagerSha256 -or
                (Get-CpaStackFileHash -Path (Join-Path $SourceManagerData 'data.key')) -ne [string]$initializeJournal.sourceDataKeySha256) {
                throw 'Running legacy Manager no longer matches the initialization journal.'
            }
            [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $managerListener.ExecutablePath -ExpectedProcessId $managerListener.ProcessId -ExpectedHash ([string]$initializeJournal.sourceManagerSha256) -AllowedAddresses @($sourceManagerBindAddress) -Seconds 2)
            $startLegacyManager = $false
        } else {
            [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $managerListener.ExecutablePath -ExpectedProcessId $managerListener.ProcessId -ExpectedHash $managerContract.TargetHash -AllowedAddresses $managerContract.TargetAddresses -Seconds 2)
            $managerProcess = Get-CpaStackFixedListenerProcess -Listener $managerListener -ExpectedPath $managerListener.ExecutablePath
            try {
                Stop-CpaStackPort -Port $ManagerPort -ExpectedPath $managerListener.ExecutablePath -ExpectedProcess $managerProcess
            } finally {
                if ($managerProcess -is [System.IDisposable]) { $managerProcess.Dispose() }
            }
        }
    }
    Restore-LegacyCpa
    if ($startLegacyManager) {
        Start-LegacyManager
    }
    Assert-LegacyStackState
}

function Assert-PathsDoNotOverlap {
    param([string]$First, [string]$Second, [string]$Description)

    $firstFull = [System.IO.Path]::GetFullPath($First).TrimEnd('\')
    $secondFull = [System.IO.Path]::GetFullPath($Second).TrimEnd('\')
    if ($firstFull -ieq $secondFull -or
        $firstFull.StartsWith($secondFull + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        $secondFull.StartsWith($firstFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description paths must not be equal, ancestors, or descendants. First=$First Second=$Second"
    }
}

function Assert-PlainExistingPath {
    param([string]$Path, [ValidateSet("Leaf", "Container")][string]$PathType = "Container")

    Assert-CpaStackPath -Path $Path -PathType $PathType
    $cursor = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $filesystemRoot = [System.IO.Path]::GetPathRoot($cursor).TrimEnd('\')
    while ($cursor -and $cursor -ne $filesystemRoot) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Migration source must not be or cross a reparse point: $cursor"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-ProtectedSecretInput {
    param([string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    $ownerText = [string]$acl.Owner
    $ownerSid = if ($ownerText -match '^S-1-') {
        [System.Security.Principal.SecurityIdentifier]::new($ownerText).Value
    } else {
        [System.Security.Principal.NTAccount]::new($ownerText).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    if ($ownerSid -ne $currentSid) { throw 'Secrets input must be owned by the current Windows user.' }
    foreach ($rule in $acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' }) {
        try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { throw 'Secrets input contains an unresolvable allow principal.' }
        if ($allowedSids -notcontains $sid) {
            throw "Secrets input grants access to an unexpected identity: $sid"
        }
    }
}

function Assert-TrustedDesktopShortcut {
    param([string]$Path, [switch]$AllowMissing)

    if (-not $Path) { return }
    $desktop = [System.IO.Path]::GetFullPath([Environment]::GetFolderPath("Desktop")).TrimEnd('\')
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ((Split-Path -Parent $full).TrimEnd('\') -ine $desktop -or [System.IO.Path]::GetExtension($full) -ine ".lnk") {
        throw "Desktop shortcut must be a direct .lnk child of the current user's Desktop: $Path"
    }
    if (-not $AllowMissing -or (Test-Path -LiteralPath $full)) {
        Assert-PlainExistingPath -Path $full -PathType Leaf
    }
}

function Assert-MigrationSourceBoundaries {
    foreach ($path in @($SourceCpaRuntime, $SourceManagerRuntime, $SourceManagerData)) {
        Assert-PlainExistingPath -Path $path
        Assert-PathsDoNotOverlap -First $path -Second $ControlRoot -Description "Migration source and canonical root"
    }
    Assert-PathsDoNotOverlap -First $SourceCpaRuntime -Second $SourceManagerRuntime -Description "Legacy CPA and Manager runtimes"
    Assert-PathsDoNotOverlap -First $SourceCpaRuntime -Second $SourceManagerData -Description "Legacy CPA runtime and Manager data"
    foreach ($path in @($SourceCpaConfig, (Join-Path $SourceCpaRuntime "cli-proxy-api.exe"), (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"), (Join-Path $SourceManagerData "data.key"), (Join-Path $SourceManagerData "usage.sqlite"))) {
        Assert-PlainExistingPath -Path $path -PathType Leaf
    }
    Assert-PathsDoNotOverlap -First $SourceCpaConfig -Second $ControlRoot -Description "CPA config and canonical root"
    if ($LegacyStartScript) {
        Assert-PlainExistingPath -Path $LegacyStartScript -PathType Leaf
        Assert-PathsDoNotOverlap -First $LegacyStartScript -Second $ControlRoot -Description "Legacy start script and canonical root"
        if ([System.IO.Path]::GetExtension($LegacyStartScript) -ine ".ps1") { throw "Legacy start script must be a PowerShell script." }
    }
    if ($SecretsInputPath) {
        Assert-PlainExistingPath -Path $SecretsInputPath -PathType Leaf
        Assert-ProtectedSecretInput -Path $SecretsInputPath
        Assert-PathsDoNotOverlap -First $SecretsInputPath -Second $ControlRoot -Description "Secrets input and canonical root"
    }
    if (-not $LegacyStartScript -and -not $SecretsInputPath -and -not (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
        throw 'A legacy start script or protected secrets input file is required.'
    }
    Assert-TrustedDesktopShortcut -Path $DesktopShortcut
}

function Get-RequiredJournalValue {
    param($Journal, [string]$Name, [string]$Description)

    $property = $Journal.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Description is missing required field $Name." }
    return $property.Value
}

function Get-ValidatedFullPathValue {
    param([string]$Value, [string]$Description)

    if ([string]::IsNullOrWhiteSpace($Value) -or -not [System.IO.Path]::IsPathRooted($Value)) {
        throw "$Description must be an absolute path."
    }
    return [System.IO.Path]::GetFullPath($Value).TrimEnd('\')
}

function Assert-ExactJournalPath {
    param([string]$Actual, [string]$Expected, [string]$Description)

    $actualFull = Get-ValidatedFullPathValue -Value $Actual -Description $Description
    $expectedFull = [System.IO.Path]::GetFullPath($Expected).TrimEnd('\')
    if (-not [string]::Equals($actualFull, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description does not match its fixed transaction slot."
    }
}

function Assert-JournalHash {
    param([string]$Value, [string]$Description)

    if ($Value -notmatch '^[0-9A-Fa-f]{64}$') { throw "$Description is not a SHA-256 value." }
}

function Assert-ManagerBaselineContract {
    param($Baseline, [string]$Description, [int]$ExpectedCpaPort)

    foreach ($field in @('cpaBaseUrl', 'collectorEnabled', 'pollIntervalMs', 'usageStatisticsEnabled')) {
        if ($null -eq $Baseline -or $null -eq $Baseline.PSObject.Properties[$field]) {
            throw "$Description is missing field $field."
        }
    }
    if ($Baseline.collectorEnabled -isnot [bool] -or $Baseline.usageStatisticsEnabled -isnot [bool]) {
        throw "$Description boolean fields are invalid."
    }
    $pollInterval = 0L
    if (-not [long]::TryParse([string]$Baseline.pollIntervalMs, [ref]$pollInterval) -or
        $pollInterval -lt 100 -or $pollInterval -gt 86400000) {
        throw "$Description pollIntervalMs is outside the supported range."
    }
    $baseUri = $null
    if ($Baseline.cpaBaseUrl -isnot [string] -or
        -not [Uri]::TryCreate([string]$Baseline.cpaBaseUrl, [UriKind]::Absolute, [ref]$baseUri) -or
        $baseUri.Scheme -cne 'http' -or
        $baseUri.Host -notin @('127.0.0.1', 'localhost', '::1') -or
        $baseUri.Port -ne $ExpectedCpaPort -or
        $baseUri.AbsolutePath -cne '/' -or
        -not [string]::IsNullOrEmpty($baseUri.Query) -or
        -not [string]::IsNullOrEmpty($baseUri.Fragment) -or
        -not [string]::IsNullOrEmpty($baseUri.UserInfo)) {
        throw "$Description cpaBaseUrl is not bound to the recorded loopback CPA port."
    }
}

function Assert-InitializationRecoveryRootTrust {
    Assert-CpaStackPrivateTree -Root $ControlRoot -Description 'Protected initialization recovery root' -AllowInheritedDescendants
}

function Resolve-InitializationConfiguredPath {
    param([string]$Value, [string]$Description)

    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Description is missing." }
    $path = if ([System.IO.Path]::IsPathRooted($Value)) { $Value } else { Join-Path $ControlRoot $Value }
    return [System.IO.Path]::GetFullPath($path).TrimEnd('\')
}

function Assert-InitializationStackConfigurationContract {
    param($Journal, [int]$SchemaVersion, [string]$Description)

    Assert-CpaStackPath -Path $stackConfigPath -PathType Leaf
    if ($SchemaVersion -eq 2) {
        $expectedHash = [string](Get-RequiredJournalValue -Journal $Journal -Name 'stackConfigSha256' -Description $Description)
        Assert-JournalHash -Value $expectedHash -Description "$Description stackConfigSha256"
        if ((Get-CpaStackFileHash -Path $stackConfigPath) -cne $expectedHash.ToUpperInvariant()) {
            throw "$Description stack configuration hash no longer matches the recorded transaction."
        }
    }

    $config = Get-CpaStackConfig -ControlRoot $ControlRoot
    if ([int]$config.SchemaVersion -ne 1) { throw "$Description stack configuration schema is invalid." }
    foreach ($entry in @(
        @([string]$config.Cpa.Executable, (Join-Path $targetCpaRuntime 'cli-proxy-api.exe'), 'CPA executable'),
        @([string]$config.Cpa.WorkingDirectory, $targetCpaRuntime, 'CPA working directory'),
        @([string]$config.Cpa.Config, (Join-Path $targetCpaRuntime 'config.yaml'), 'CPA config'),
        @([string]$config.Manager.Executable, (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe'), 'Manager executable'),
        @([string]$config.Manager.WorkingDirectory, $targetManagerRuntime, 'Manager working directory'),
        @([string]$config.Manager.DataDirectory, $targetManagerData, 'Manager data directory')
    )) {
        $actualPath = Resolve-InitializationConfiguredPath -Value $entry[0] -Description "$Description $($entry[2])"
        if (-not [string]::Equals($actualPath, [System.IO.Path]::GetFullPath($entry[1]).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$Description $($entry[2]) is not bound to its canonical slot."
        }
    }
    if ([int]$config.Cpa.Port -ne [int]$Journal.cpaPort -or
        [int]$config.Manager.Port -ne [int]$Journal.managerPort -or
        [string]$config.Manager.BindAddress -cne [string]$Journal.managerBindAddress -or
        $config.Manager.RequestMonitoringEnabled -isnot [bool] -or
        [bool]$config.Manager.RequestMonitoringEnabled -ne [bool]$Journal.managerBaseline.collectorEnabled) {
        throw "$Description ports, Manager bind address, or monitoring state are not bound to the transaction."
    }
}

function Assert-ManagerSnapshotContract {
    param($Snapshot, [string]$Description)

    if ($null -eq $Snapshot -or $null -eq $Snapshot.quick_check -or -not [bool]$Snapshot.quick_check.ok -or
        $null -eq $Snapshot.usage_events -or $null -eq $Snapshot.critical_table_counts) {
        throw "$Description is missing the trusted SQLite recovery fields."
    }
}

function Get-InitializationPhaseIndex {
    param([string]$Phase)

    $phases = @(
        'preparing',
        'prepared',
        'cpa-candidate-validated',
        'candidates-validated',
        'switching',
        'services-switched',
        'shortcut-updated',
        'state-committing'
    )
    $index = [array]::IndexOf($phases, $Phase)
    if ($index -lt 0) { throw "Initialization journal phase is unsupported: $Phase" }
    return $index
}

function Assert-InitializationJournalContract {
    param(
        $Journal,
        [string]$Description = 'Initialization journal',
        [switch]$HistoricalGeneration
    )

    if ([string](Get-RequiredJournalValue -Journal $Journal -Name 'operation' -Description $Description) -cne 'initialize-canonical-stack') {
        throw "$Description operation is invalid."
    }
    $schemaVersion = [int](Get-RequiredJournalValue -Journal $Journal -Name 'schemaVersion' -Description $Description)
    if ($schemaVersion -notin @(1, 2)) { throw "$Description schema version is unsupported." }
    $phase = [string](Get-RequiredJournalValue -Journal $Journal -Name 'phase' -Description $Description)
    $phaseIndex = Get-InitializationPhaseIndex -Phase $phase
    Assert-ExactJournalPath -Actual ([string](Get-RequiredJournalValue -Journal $Journal -Name 'canonicalRoot' -Description $Description)) -Expected $ControlRoot -Description "$Description canonical root"

    $journalInstanceId = [string](Get-RequiredJournalValue -Journal $Journal -Name 'instanceId' -Description $Description)
    if ($journalInstanceId -notmatch '^[0-9a-fA-F]{32}$' -or $null -eq $instanceMarker -or
        $journalInstanceId -cne [string]$instanceMarker.instanceId) {
        throw "$Description belongs to a different CPA stack instance."
    }
    $operationId = $null
    if ($schemaVersion -eq 2) {
        $operationId = [string](Get-RequiredJournalValue -Journal $Journal -Name 'operationId' -Description $Description)
        if ($operationId -notmatch '^[0-9a-fA-F]{32}$') { throw "$Description operationId is invalid." }
    }

    if ($schemaVersion -eq 1) {
        $Journal | Add-Member -NotePropertyName cpaPort -NotePropertyValue 8317 -Force
        $Journal | Add-Member -NotePropertyName managerPort -NotePropertyValue 18317 -Force
        $Journal | Add-Member -NotePropertyName cpaCandidatePort -NotePropertyValue 8318 -Force
        $Journal | Add-Member -NotePropertyName managerCandidatePort -NotePropertyValue 18318 -Force
    } else {
        foreach ($property in @('cpaPort', 'managerPort', 'cpaCandidatePort', 'managerCandidatePort')) {
            [void](Get-RequiredJournalValue -Journal $Journal -Name $property -Description $Description)
        }
    }
    $journalCpaPort = [int]$Journal.cpaPort
    $journalManagerPort = [int]$Journal.managerPort
    $journalCpaCandidatePort = [int]$Journal.cpaCandidatePort
    $journalManagerCandidatePort = [int]$Journal.managerCandidatePort
    if ($journalCpaPort -lt 1 -or $journalCpaPort -gt 65535 -or
        $journalManagerPort -lt 1 -or $journalManagerPort -gt 65535 -or
        $journalCpaPort -eq $journalManagerPort) {
        throw "$Description formal ports are invalid."
    }
    if ($schemaVersion -eq 1) {
        if ($journalCpaPort -ne 8317 -or $journalManagerPort -ne 18317 -or
            $journalCpaCandidatePort -ne 8318 -or $journalManagerCandidatePort -ne 18318) {
            throw "$Description legacy port contract is invalid."
        }
    } else {
        $candidatePorts = @($journalCpaCandidatePort, $journalManagerCandidatePort)
        $protectedPorts = @(Get-CpaStackCandidateProtectedPorts -FormalPort @($journalCpaPort, $journalManagerPort))
        if (@($candidatePorts | Sort-Object -Unique).Count -ne 2 -or
            @($candidatePorts | Where-Object { $_ -lt 49152 -or $_ -gt 65535 -or $_ -in $protectedPorts }).Count -gt 0) {
            throw "$Description candidate ports are invalid."
        }
    }

    foreach ($pair in @(
        @([string](Get-RequiredJournalValue -Journal $Journal -Name 'targetCpaRuntime' -Description $Description), $targetCpaRuntime, 'CPA target runtime'),
        @([string](Get-RequiredJournalValue -Journal $Journal -Name 'targetManagerRuntime' -Description $Description), $targetManagerRuntime, 'Manager target runtime'),
        @([string](Get-RequiredJournalValue -Journal $Journal -Name 'targetManagerData' -Description $Description), $targetManagerData, 'Manager target data')
    )) {
        Assert-ExactJournalPath -Actual $pair[0] -Expected $pair[1] -Description "$Description $($pair[2])"
    }

    $sourceCpaRuntimeValue = Get-ValidatedFullPathValue -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name 'sourceCpaRuntime' -Description $Description)) -Description "$Description CPA source runtime"
    $sourceCpaConfigValue = Get-ValidatedFullPathValue -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name 'sourceCpaConfig' -Description $Description)) -Description "$Description CPA source config"
    $sourceManagerRuntimeValue = Get-ValidatedFullPathValue -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name 'sourceManagerRuntime' -Description $Description)) -Description "$Description Manager source runtime"
    $sourceManagerDataValue = Get-ValidatedFullPathValue -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name 'sourceManagerData' -Description $Description)) -Description "$Description Manager source data"

    foreach ($field in @('sourceCpaSha256', 'sourceManagerSha256', 'sourceCpaConfigSha256', 'sourceDataKeySha256')) {
        Assert-JournalHash -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name $field -Description $Description)) -Description "$Description $field"
    }
    $legacyStartScriptValue = [string](Get-RequiredJournalValue -Journal $Journal -Name 'legacyStartScript' -Description $Description)
    $legacyStartHashProperty = $Journal.PSObject.Properties['legacyStartScriptSha256']
    if (-not [string]::IsNullOrWhiteSpace($legacyStartScriptValue)) {
        $legacyStartScriptValue = Get-ValidatedFullPathValue -Value $legacyStartScriptValue -Description "$Description legacy start script"
        if ($null -eq $legacyStartHashProperty) { throw "$Description is missing legacyStartScriptSha256." }
        Assert-JournalHash -Value ([string]$legacyStartHashProperty.Value) -Description "$Description legacy start script hash"
    } elseif ($null -ne $legacyStartHashProperty -and -not [string]::IsNullOrWhiteSpace([string]$legacyStartHashProperty.Value)) {
        throw "$Description records a legacy start hash without a legacy start script."
    }
    $desktopShortcutValue = [string](Get-RequiredJournalValue -Journal $Journal -Name 'desktopShortcut' -Description $Description)
    if (-not [string]::IsNullOrWhiteSpace($desktopShortcutValue)) {
        $desktopShortcutValue = Get-ValidatedFullPathValue -Value $desktopShortcutValue -Description "$Description desktop shortcut"
    }

    Assert-ManagerBaselineContract -Baseline (Get-RequiredJournalValue -Journal $Journal -Name 'managerBaseline' -Description $Description) -Description "$Description Manager baseline" -ExpectedCpaPort $journalCpaPort
    $managerBindAddressValue = [string](Get-RequiredJournalValue -Journal $Journal -Name 'managerBindAddress' -Description $Description)
    if ($managerBindAddressValue -notmatch '^[A-Za-z0-9.:%\[\]-]+$') { throw "$Description Manager bind address is invalid." }
    $sourceSnapshotProperty = $Journal.PSObject.Properties['sourceManagerSnapshot']
    if ($null -ne $sourceSnapshotProperty -and $null -ne $sourceSnapshotProperty.Value) {
        Assert-ManagerSnapshotContract -Snapshot $sourceSnapshotProperty.Value -Description "$Description Manager source snapshot"
    }

    if ($schemaVersion -eq 2 -and $phaseIndex -ge (Get-InitializationPhaseIndex -Phase 'prepared')) {
        foreach ($field in @('targetCpaSha256', 'targetManagerSha256', 'targetCpaRuntimeManifestSha256', 'targetCpaConfigSha256')) {
            Assert-JournalHash -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name $field -Description $Description)) -Description "$Description $field"
        }
        $targetHost = [string](Get-RequiredJournalValue -Journal $Journal -Name 'targetCpaHost' -Description $Description)
        if ([string]::IsNullOrWhiteSpace($targetHost)) { throw "$Description target CPA host is missing." }
        if ((Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'cli-proxy-api.exe')) -ine [string]$Journal.targetCpaSha256 -or
            (Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe')) -ine [string]$Journal.targetManagerSha256 -or
            (Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'config.yaml')) -ine [string]$Journal.targetCpaConfigSha256 -or
            [string](Get-CpaStackConfigHost -ConfigPath (Join-Path $targetCpaRuntime 'config.yaml')) -cne $targetHost) {
            throw "$Description prepared target binding no longer matches the canonical slots."
        }
        if (-not $HistoricalGeneration -and
            $phaseIndex -ge (Get-InitializationPhaseIndex -Phase 'cpa-candidate-validated') -and
            $phaseIndex -lt (Get-InitializationPhaseIndex -Phase 'switching') -and
            [string](Get-CpaStackTreeManifest -Root $targetCpaRuntime).sha256 -ine [string]$Journal.targetCpaRuntimeManifestSha256) {
            throw "$Description prepared target runtime manifest no longer matches the canonical slot."
        }
        Assert-InitializationStackConfigurationContract -Journal $Journal -SchemaVersion $schemaVersion -Description $Description
    } elseif ($schemaVersion -eq 1 -and $phaseIndex -ge (Get-InitializationPhaseIndex -Phase 'cpa-candidate-validated')) {
        foreach ($field in @('targetCpaRuntimeManifestSha256', 'targetCpaConfigSha256')) {
            Assert-JournalHash -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name $field -Description $Description)) -Description "$Description $field"
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-RequiredJournalValue -Journal $Journal -Name 'targetCpaHost' -Description $Description))) {
            throw "$Description target CPA host is missing."
        }
        if ((Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'config.yaml')) -ine [string]$Journal.targetCpaConfigSha256 -or
            [string](Get-CpaStackConfigHost -ConfigPath (Join-Path $targetCpaRuntime 'config.yaml')) -cne [string]$Journal.targetCpaHost) {
            throw "$Description legacy target config binding no longer matches the canonical slot."
        }
        if (-not $HistoricalGeneration -and
            $phaseIndex -lt (Get-InitializationPhaseIndex -Phase 'switching') -and
            [string](Get-CpaStackTreeManifest -Root $targetCpaRuntime).sha256 -ine [string]$Journal.targetCpaRuntimeManifestSha256) {
            throw "$Description legacy target runtime manifest no longer matches the canonical slot."
        }
        Assert-InitializationStackConfigurationContract -Journal $Journal -SchemaVersion $schemaVersion -Description $Description
    }

    return [pscustomobject]@{
        SchemaVersion = $schemaVersion
        OperationId = $operationId
        Phase = $phase
        PhaseIndex = $phaseIndex
        CpaPort = $journalCpaPort
        ManagerPort = $journalManagerPort
        CpaCandidatePort = $journalCpaCandidatePort
        ManagerCandidatePort = $journalManagerCandidatePort
        SourceCpaRuntime = $sourceCpaRuntimeValue
        SourceCpaConfig = $sourceCpaConfigValue
        SourceManagerRuntime = $sourceManagerRuntimeValue
        SourceManagerData = $sourceManagerDataValue
        LegacyStartScript = $legacyStartScriptValue
        DesktopShortcut = $desktopShortcutValue
    }
}

function Assert-InitializationJournalSameTransaction {
    param($Current, $Previous, $CurrentContract, $PreviousContract)

    if ($PreviousContract.SchemaVersion -ne $CurrentContract.SchemaVersion -or
        $PreviousContract.PhaseIndex -gt $CurrentContract.PhaseIndex) {
        throw 'Initialization journal previous generation is not an earlier state of the current transaction.'
    }
    foreach ($field in @(
        'operation', 'instanceId', 'canonicalRoot',
        'sourceCpaRuntime', 'sourceCpaConfig', 'sourceManagerRuntime', 'sourceManagerData',
        'legacyStartScript', 'desktopShortcut',
        'targetCpaRuntime', 'targetManagerRuntime', 'targetManagerData',
        'sourceCpaSha256', 'sourceManagerSha256', 'sourceCpaConfigSha256', 'sourceDataKeySha256'
    )) {
        if ([string]$Previous.$field -cne [string]$Current.$field) {
            throw "Initialization journal previous generation disagrees on $field."
        }
    }
    if ($CurrentContract.SchemaVersion -eq 2 -and $PreviousContract.OperationId -cne $CurrentContract.OperationId) {
        throw 'Initialization journal previous generation belongs to another operation.'
    }
    foreach ($field in @('cpaPort', 'managerPort', 'cpaCandidatePort', 'managerCandidatePort')) {
        if ([int]$Previous.$field -ne [int]$Current.$field) {
            throw "Initialization journal previous generation disagrees on $field."
        }
    }
}

function New-ValidatedArtifactDescriptor {
    param([string]$Path, [string]$Description)

    Assert-CpaStackChildPath -Root $ControlRoot -Path $Path
    Assert-CpaStackPath -Path $Path -PathType Leaf
    $hash = Get-CpaStackFileHash -Path $Path
    Assert-JournalHash -Value $hash -Description "$Description file hash"
    return [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($Path); Sha256 = $hash; Description = $Description }
}

function Assert-InitializationSwitchJournalContract {
    param($Journal, [ValidateSet('cpa', 'manager')][string]$Component, [string]$Description, $TopContract)

    $expectedOperation = "switch-$Component"
    if ([string](Get-RequiredJournalValue -Journal $Journal -Name 'operation' -Description $Description) -cne $expectedOperation) {
        throw "$Description operation is invalid."
    }
    $operationId = [string](Get-RequiredJournalValue -Journal $Journal -Name 'operationId' -Description $Description)
    if ($operationId -notmatch '^[0-9a-fA-F]{32}$') { throw "$Description operationId is invalid." }
    if ([string](Get-RequiredJournalValue -Journal $Journal -Name 'instanceId' -Description $Description) -cne [string]$instanceMarker.instanceId) {
        throw "$Description belongs to another CPA stack instance."
    }
    if ($TopContract.SchemaVersion -eq 2) {
        if ([int](Get-RequiredJournalValue -Journal $Journal -Name 'schemaVersion' -Description $Description) -ne 1 -or
            [string](Get-RequiredJournalValue -Journal $Journal -Name 'parentOperationId' -Description $Description) -cne $TopContract.OperationId) {
            throw "$Description is not bound to the initialization operation."
        }
    }
    $pendingProperty = $Journal.PSObject.Properties['pendingPath']
    if ($null -ne $pendingProperty -and -not [string]::IsNullOrWhiteSpace([string]$pendingProperty.Value)) {
        throw "$Description unexpectedly owns an in-place rollback slot."
    }
    Assert-JournalHash -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name 'oldHash' -Description $Description)) -Description "$Description oldHash"
    Assert-JournalHash -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name 'newHash' -Description $Description)) -Description "$Description newHash"

    $phase = [string](Get-RequiredJournalValue -Journal $Journal -Name 'phase' -Description $Description)
    if ($Component -eq 'cpa') {
        if ($phase -cnotin @('prepared', 'source-stopped', 'target-started', 'runtime-verified')) {
            throw "$Description phase is unsupported."
        }
        Assert-ExactJournalPath -Actual ([string]$Journal.sourceRuntime) -Expected $TopContract.SourceCpaRuntime -Description "$Description source runtime"
        Assert-ExactJournalPath -Actual ([string]$Journal.targetRuntime) -Expected $targetCpaRuntime -Description "$Description target runtime"
        Assert-ExactJournalPath -Actual ([string]$Journal.sourceConfig) -Expected $TopContract.SourceCpaConfig -Description "$Description source config"
        if ([int](Get-RequiredJournalValue -Journal $Journal -Name 'port' -Description $Description) -ne $TopContract.CpaPort -or
            [string]$Journal.oldHash -ine [string]$initializeJournal.sourceCpaSha256 -or
            [string]$Journal.newHash -ine (Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'cli-proxy-api.exe'))) {
            throw "$Description ports or executable hashes are not bound to initialization."
        }
        foreach ($field in @('targetRuntimeManifestSha256', 'targetConfigSha256')) {
            Assert-JournalHash -Value ([string](Get-RequiredJournalValue -Journal $Journal -Name $field -Description $Description)) -Description "$Description $field"
        }
        if ([string]$Journal.targetRuntimeManifestSha256 -ine [string]$initializeJournal.targetCpaRuntimeManifestSha256 -or
            [string]$Journal.targetConfigSha256 -ine [string]$initializeJournal.targetCpaConfigSha256 -or
            [string]$Journal.targetHost -cne [string]$initializeJournal.targetCpaHost) {
            throw "$Description target binding is not owned by initialization."
        }
    } else {
        if ($phase -cnotin @('prepared', 'collector-disabled', 'source-stopped', 'target-started', 'runtime-verified')) {
            throw "$Description phase is unsupported."
        }
        Assert-ExactJournalPath -Actual ([string]$Journal.sourceRuntime) -Expected $TopContract.SourceManagerRuntime -Description "$Description source runtime"
        Assert-ExactJournalPath -Actual ([string]$Journal.sourceData) -Expected $TopContract.SourceManagerData -Description "$Description source data"
        Assert-ExactJournalPath -Actual ([string]$Journal.targetRuntime) -Expected $targetManagerRuntime -Description "$Description target runtime"
        Assert-ExactJournalPath -Actual ([string]$Journal.targetData) -Expected $targetManagerData -Description "$Description target data"
        if ([int](Get-RequiredJournalValue -Journal $Journal -Name 'managerPort' -Description $Description) -ne $TopContract.ManagerPort -or
            [int](Get-RequiredJournalValue -Journal $Journal -Name 'cpaPort' -Description $Description) -ne $TopContract.CpaPort -or
            [string]$Journal.oldHash -ine [string]$initializeJournal.sourceManagerSha256 -or
            [string]$Journal.newHash -ine (Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe'))) {
            throw "$Description ports or executable hashes are not bound to initialization."
        }
        $childBaseline = Get-RequiredJournalValue -Journal $Journal -Name 'managerBaseline' -Description $Description
        Assert-ManagerBaselineContract -Baseline $childBaseline -Description "$Description Manager baseline" -ExpectedCpaPort $TopContract.CpaPort
        foreach ($field in @('cpaBaseUrl', 'collectorEnabled', 'pollIntervalMs', 'usageStatisticsEnabled')) {
            if ([string]$childBaseline.$field -cne [string]$initializeJournal.managerBaseline.$field) {
                throw "$Description Manager baseline is not bound to initialization field $field."
            }
        }
        $snapshotProperty = $Journal.PSObject.Properties['sourceSnapshot']
        if ($null -ne $snapshotProperty -and $null -ne $snapshotProperty.Value) {
            Assert-ManagerSnapshotContract -Snapshot $snapshotProperty.Value -Description "$Description source snapshot"
        }
    }

    $targetProcessIdProperty = $Journal.PSObject.Properties['targetProcessId']
    if ($phase -in @('target-started', 'runtime-verified')) {
        $targetProcessId = 0
        if ($null -eq $targetProcessIdProperty -or
            -not [int]::TryParse([string]$targetProcessIdProperty.Value, [ref]$targetProcessId) -or
            $targetProcessId -le 0) {
            throw "$Description target process identity is missing after the target-started phase."
        }
    } elseif ($null -ne $targetProcessIdProperty -and $null -ne $targetProcessIdProperty.Value) {
        throw "$Description records a target process identity before the target-started phase."
    }
}

function Assert-InitializationSwitchResultContract {
    param($State, [ValidateSet('cpa', 'manager')][string]$Component, [string]$Description, $TopContract)

    if ($TopContract.SchemaVersion -eq 2) {
        if ([int](Get-RequiredJournalValue -Journal $State -Name 'schemaVersion' -Description $Description) -ne 1 -or
            [string](Get-RequiredJournalValue -Journal $State -Name 'operation' -Description $Description) -cne "switch-$Component" -or
            [string](Get-RequiredJournalValue -Journal $State -Name 'parentOperationId' -Description $Description) -cne $TopContract.OperationId -or
            [string](Get-RequiredJournalValue -Journal $State -Name 'instanceId' -Description $Description) -cne [string]$instanceMarker.instanceId -or
            [string](Get-RequiredJournalValue -Journal $State -Name 'operationId' -Description $Description) -notmatch '^[0-9a-fA-F]{32}$') {
            throw "$Description is not bound to the initialization operation."
        }
    }
    if ($Component -eq 'cpa') {
        Assert-ExactJournalPath -Actual ([string]$State.sourcePath) -Expected (Join-Path $TopContract.SourceCpaRuntime 'cli-proxy-api.exe') -Description "$Description source executable"
        Assert-ExactJournalPath -Actual ([string]$State.targetPath) -Expected (Join-Path $targetCpaRuntime 'cli-proxy-api.exe') -Description "$Description target executable"
        if ([int]$State.port -ne $TopContract.CpaPort -or [string]$State.oldHash -ine [string]$initializeJournal.sourceCpaSha256 -or
            [string]$State.newHash -ine (Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'cli-proxy-api.exe'))) {
            throw "$Description is not bound to the initialization CPA hashes and port."
        }
    } else {
        Assert-ExactJournalPath -Actual ([string]$State.sourcePath) -Expected (Join-Path $TopContract.SourceManagerRuntime 'cpa-manager-plus.exe') -Description "$Description source executable"
        Assert-ExactJournalPath -Actual ([string]$State.targetPath) -Expected (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe') -Description "$Description target executable"
        Assert-ExactJournalPath -Actual ([string]$State.sourceData) -Expected $TopContract.SourceManagerData -Description "$Description source data"
        Assert-ExactJournalPath -Actual ([string]$State.targetData) -Expected $targetManagerData -Description "$Description target data"
        if ([int]$State.managerPort -ne $TopContract.ManagerPort -or [int]$State.cpaPort -ne $TopContract.CpaPort -or
            [string]$State.oldHash -ine [string]$initializeJournal.sourceManagerSha256 -or
            [string]$State.newHash -ine (Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe'))) {
            throw "$Description is not bound to the initialization Manager hashes and ports."
        }
        $snapshotProperty = $State.PSObject.Properties['sourceSnapshot']
        if ($null -ne $snapshotProperty -and $null -ne $snapshotProperty.Value) {
            Assert-ManagerSnapshotContract -Snapshot $snapshotProperty.Value -Description "$Description source snapshot"
        }
    }
}

function Set-ValidatedInitializationArtifacts {
    param($Journal, $TopContract)

    $journalFiles = New-Object System.Collections.Generic.List[object]
    $switchFiles = New-Object System.Collections.Generic.List[object]
    $subordinateArtifactCount = 0
    $journalFiles.Add((New-ValidatedArtifactDescriptor -Path $initializeJournalPath -Description 'Initialization journal'))
    $previousPath = $initializeJournalPath + '.previous'
    if (Test-Path -LiteralPath $previousPath -PathType Leaf) {
        $previous = Read-CpaStackJson -Path $previousPath
        $previousContract = Assert-InitializationJournalContract -Journal $previous -Description 'Initialization journal previous generation' -HistoricalGeneration
        Assert-InitializationJournalSameTransaction -Current $Journal -Previous $previous -CurrentContract $TopContract -PreviousContract $previousContract
        $journalFiles.Add((New-ValidatedArtifactDescriptor -Path $previousPath -Description 'Initialization journal previous generation'))
    }

    foreach ($component in @('cpa', 'manager')) {
        $componentOperationIds = New-Object System.Collections.Generic.List[string]
        $componentResultCount = 0
        $basePath = Join-Path $stateDir "switch-$component.pending.json"
        foreach ($path in @($basePath, ($basePath + '.previous'))) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ($TopContract.PhaseIndex -lt (Get-InitializationPhaseIndex -Phase 'switching')) {
                throw "Initialization $component switch artifact exists before the switching phase."
            }
            $child = Read-CpaStackJson -Path $path
            Assert-InitializationSwitchJournalContract -Journal $child -Component $component -Description "Initialization $component switch journal" -TopContract $TopContract
            $componentOperationIds.Add([string]$child.operationId)
            $switchFiles.Add((New-ValidatedArtifactDescriptor -Path $path -Description "Initialization $component switch journal"))
            $subordinateArtifactCount++
        }
        $resultBase = Join-Path $stateDir "$component-migration-switch.json"
        foreach ($path in @($resultBase)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ($TopContract.PhaseIndex -lt (Get-InitializationPhaseIndex -Phase 'switching')) {
                throw "Initialization $component switch result exists before the switching phase."
            }
            $childResult = Read-CpaStackJson -Path $path
            Assert-InitializationSwitchResultContract -State $childResult -Component $component -Description "Initialization $component switch result" -TopContract $TopContract
            $subordinateArtifactCount++
            if ($path -ieq $resultBase) { $componentResultCount++ }
            $resultOperationIdProperty = $childResult.PSObject.Properties['operationId']
            if ($null -ne $resultOperationIdProperty -and [string]$resultOperationIdProperty.Value -match '^[0-9a-fA-F]{32}$') {
                $componentOperationIds.Add([string]$resultOperationIdProperty.Value)
            }
        }
        if (@($componentOperationIds | Sort-Object -Unique).Count -gt 1) {
            throw "Initialization $component subordinate artifacts belong to different switch operations."
        }
        if ($TopContract.PhaseIndex -ge (Get-InitializationPhaseIndex -Phase 'services-switched') -and $componentResultCount -ne 1) {
            throw "Initialization $component switch result is missing after the services-switched phase."
        }
    }

    $rollbackDir = Join-Path $ControlRoot 'rollback'
    if (Test-Path -LiteralPath $rollbackDir -PathType Container) {
        $unowned = @(Get-ChildItem -Force -LiteralPath $rollbackDir -ErrorAction Stop | Where-Object { $_.Name -match '^(pending|staging)-' })
        if ($unowned.Count -gt 0) {
            throw 'Initialization recovery found a rollback pending/staging artifact that cannot belong to a non-in-place initialization switch.'
        }
    }
    if ($TopContract.PhaseIndex -ge (Get-InitializationPhaseIndex -Phase 'switching') -and $subordinateArtifactCount -eq 0) {
        throw 'Initialization switching recovery has no subordinate process identity evidence.'
    }
    $script:validatedInitializationJournalFiles = @($journalFiles.ToArray())
    $script:validatedInitializationSwitchFiles = @($switchFiles.ToArray())
    $script:validatedInitializationTopContract = $TopContract
    $script:validatedInitializationSubordinateArtifactCount = $subordinateArtifactCount
}

function Assert-ValidatedArtifactUnchanged {
    param($Descriptor)

    if (-not (Test-Path -LiteralPath $Descriptor.Path -PathType Leaf) -or
        (Get-CpaStackFileHash -Path $Descriptor.Path) -cne [string]$Descriptor.Sha256) {
        throw "$($Descriptor.Description) changed after ownership validation."
    }
}

function Remove-SecretTempFiles {
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) { return }
    foreach ($file in Get-ChildItem -Force -LiteralPath $configDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^secrets\.local\.json\.secure-[0-9a-fA-F]{32}$' }) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $file.FullName
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
    }
}

function Stop-InitializationTemporaryListeners {
    param($TopContract)

    if ($null -eq $initializeJournal -or $null -eq $TopContract) { return }
    $components = switch ($TopContract.Phase) {
        'prepared' { @('cpa') }
        'cpa-candidate-validated' { @('manager') }
        default { @() }
    }
    if ($components.Count -eq 0) { return }

    $targetCpaHashProperty = $initializeJournal.PSObject.Properties['targetCpaSha256']
    $targetManagerHashProperty = $initializeJournal.PSObject.Properties['targetManagerSha256']
    $entries = @()
    if ('cpa' -in $components) {
        $expectedHash = if ($null -ne $targetCpaHashProperty -and [string]$targetCpaHashProperty.Value -match '^[0-9A-Fa-f]{64}$') { [string]$targetCpaHashProperty.Value } else { [string]$initializeJournal.sourceCpaSha256 }
        $entries += [pscustomobject]@{ Port = [int]$initializeJournal.cpaCandidatePort; Expected = (Join-Path $targetCpaRuntime 'cli-proxy-api.exe'); ExpectedHash = $expectedHash }
    }
    if ('manager' -in $components) {
        $expectedHash = if ($null -ne $targetManagerHashProperty -and [string]$targetManagerHashProperty.Value -match '^[0-9A-Fa-f]{64}$') { [string]$targetManagerHashProperty.Value } else { [string]$initializeJournal.sourceManagerSha256 }
        $entries += [pscustomobject]@{ Port = [int]$initializeJournal.managerCandidatePort; Expected = (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe'); ExpectedHash = $expectedHash }
    }

    $ownedListeners = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($entry in $entries) {
            $listener = Get-CpaStackListener -Port $entry.Port
            if (-not $listener) { continue }
            if ($listener.ExecutablePath -ine $entry.Expected) {
                throw "Unexpected process owns initialization temporary port $($entry.Port): $($listener.ExecutablePath)"
            }
            [void](Wait-CpaStackTrustedListener -Port $entry.Port -ExpectedPath $entry.Expected -ExpectedProcessId $listener.ProcessId -ExpectedHash $entry.ExpectedHash -AllowedAddresses @('127.0.0.1', '::1') -Seconds 2)
            $process = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $entry.Expected
            $ownedListeners.Add([pscustomobject]@{ Entry = $entry; Process = $process })
        }
        foreach ($owned in $ownedListeners) {
            Stop-CpaStackPort -Port $owned.Entry.Port -ExpectedPath $owned.Entry.Expected -ExpectedProcess $owned.Process -RequireExecutableWriteAccess
        }
    } finally {
        foreach ($owned in $ownedListeners) {
            if ($owned.Process -is [System.IDisposable]) { $owned.Process.Dispose() }
        }
    }
}

function Set-InitializeJournalPhase {
    param([string]$Phase)
    if ($null -eq $script:initializeJournal) { return }
    $script:initializeJournal.phase = $Phase
    $script:initializeJournal.updatedAt = (Get-Date).ToString("o")
    Write-CpaStackJson -Value $script:initializeJournal -Path $initializeJournalPath
    Protect-CpaStackSecretFile -Path $initializeJournalPath
}

function Remove-InitializationJournal {
    if (@($validatedInitializationJournalFiles).Count -eq 0) {
        throw 'Initialization journal cleanup requires a validated ownership descriptor.'
    }
    foreach ($descriptor in @($validatedInitializationJournalFiles)) {
        Assert-ValidatedArtifactUnchanged -Descriptor $descriptor
    }
    $removalOrder = @($validatedInitializationJournalFiles | Sort-Object {
        if ([string]::Equals([System.IO.Path]::GetFullPath($_.Path), [System.IO.Path]::GetFullPath($initializeJournalPath), [System.StringComparison]::OrdinalIgnoreCase)) { 1 } else { 0 }
    })
    foreach ($descriptor in $removalOrder) {
        Remove-Item -LiteralPath $descriptor.Path -Force -ErrorAction Stop
    }
}

function Remove-SwitchJournals {
    foreach ($descriptor in @($validatedInitializationSwitchFiles)) {
        Assert-ValidatedArtifactUnchanged -Descriptor $descriptor
    }
    foreach ($descriptor in @($validatedInitializationSwitchFiles | Sort-Object { if ($_.Path -like '*.previous') { 0 } else { 1 } })) {
        Remove-Item -LiteralPath $descriptor.Path -Force -ErrorAction Stop
    }
}

function Backup-DesktopShortcut {
    if (-not $DesktopShortcut) { return }
    Assert-TrustedDesktopShortcut -Path $DesktopShortcut
    $legacyLink = (New-Object -ComObject WScript.Shell).CreateShortcut($DesktopShortcut)
    $pointsToLegacy = ($legacyLink.TargetPath -ieq $LegacyStartScript -or $legacyLink.Arguments -match [regex]::Escape($LegacyStartScript))
    if (-not $pointsToLegacy) { throw "Desktop shortcut does not reference the discovered legacy start script." }
    New-Item -ItemType Directory -Force -Path $migrationRollback | Out-Null
    $backup = Join-Path $migrationRollback "startup.lnk"
    Assert-CpaStackChildPath -Root $ControlRoot -Path $backup
    Copy-Item -LiteralPath $DesktopShortcut -Destination $backup -Force
}

function Restore-DesktopShortcut {
    if (-not $DesktopShortcut) { return }
    Assert-TrustedDesktopShortcut -Path $DesktopShortcut -AllowMissing
    $backup = Join-Path $migrationRollback "startup.lnk"
    Assert-CpaStackChildPath -Root $ControlRoot -Path $backup
    Assert-CpaStackPath -Path $backup -PathType Leaf
    $backupLink = (New-Object -ComObject WScript.Shell).CreateShortcut($backup)
    $pointsToLegacy = ($backupLink.TargetPath -ieq $LegacyStartScript -or $backupLink.Arguments -match [regex]::Escape($LegacyStartScript))
    if (-not $pointsToLegacy) { throw "Legacy shortcut backup does not reference the recorded start script." }
    Copy-Item -LiteralPath $backup -Destination $DesktopShortcut -Force
}

function Reset-CanonicalPreparation {
    foreach ($path in @($targetCpaRuntime, $targetManagerRuntime, $targetManagerData)) {
        if (Test-Path -LiteralPath $path) {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $path
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }
    foreach ($file in @($stackConfigPath, $secretsPath, ($secretsPath + ".previous"), $newStartScript, (Join-Path $ControlRoot "assets\cpa-frontend-logo.ico"))) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
        }
    }
    Remove-SecretTempFiles
}

function Test-CommittedCanonicalInitialization {
    param($Journal)

    if (-not (Test-Path -LiteralPath $currentStatePath -PathType Leaf)) { return $false }
    if ([string]$Journal.phase -ne "state-committing") {
        throw "Initialization journal and current state disagree on the commit phase."
    }
    $current = Read-CpaStackJson -Path $currentStatePath
    if ([string]$current.instanceId -ne [string]$Journal.instanceId) {
        throw "Committed initialization state belongs to a different CPA stack instance."
    }
    if ([System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\') -ine [System.IO.Path]::GetFullPath($ControlRoot).TrimEnd('\')) {
        throw "Committed initialization state points to a different canonical root."
    }
    if ([System.IO.Path]::GetFullPath([string]$current.cpa.executable) -ine [System.IO.Path]::GetFullPath((Join-Path $targetCpaRuntime "cli-proxy-api.exe"))) {
        throw "Committed CPA executable does not match the canonical slot."
    }
    if ([System.IO.Path]::GetFullPath([string]$current.manager.executable) -ine [System.IO.Path]::GetFullPath((Join-Path $targetManagerRuntime "cpa-manager-plus.exe"))) {
        throw "Committed Manager executable does not match the canonical slot."
    }
    foreach ($path in @((Join-Path $targetCpaRuntime "cli-proxy-api.exe"), (Join-Path $targetManagerRuntime "cpa-manager-plus.exe"), (Join-Path $targetManagerData "usage.sqlite"), (Join-Path $targetManagerData "data.key"))) {
        Assert-CpaStackPath -Path $path -PathType Leaf
    }
    if ((Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime "cli-proxy-api.exe")) -ne [string]$current.cpa.sha256) {
        throw "Committed CPA executable hash does not match current.json."
    }
    if ((Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime "cpa-manager-plus.exe")) -ne [string]$current.manager.sha256) {
        throw "Committed Manager executable hash does not match current.json."
    }
    Assert-CpaStackPath -Path $newStartScript -PathType Leaf
    $expectedCpaExe = Join-Path $targetCpaRuntime "cli-proxy-api.exe"
    $expectedManagerExe = Join-Path $targetManagerRuntime "cpa-manager-plus.exe"
    $recoveryStartedProcesses = New-Object System.Collections.Generic.List[object]
    $startupTrusted = $false
    $registrationCallback = {
        param([System.Diagnostics.Process]$Process)
        $recoveryStartedProcesses.Add($Process)
    }.GetNewClosure()
    try {
    $cpaListener = Get-CpaStackListener -Port $CpaPort
    $managerListener = Get-CpaStackListener -Port $ManagerPort
    if ($cpaListener -and $cpaListener.ExecutablePath -ine $expectedCpaExe) {
        throw "An unexpected process owns CPA formal port $CpaPort during committed initialization recovery."
    }
    if ($managerListener -and $managerListener.ExecutablePath -ine $expectedManagerExe) {
        throw "An unexpected process owns Manager formal port $ManagerPort during committed initialization recovery."
    }
    if (-not $cpaListener -or -not $managerListener) {
        $startResult = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot 'Start-CPA-Stack.ps1') -Arguments @("-NoBrowser", "-ConfigPath", $stackConfigPath) -AdditionalParameters @{ OperationLockHandle = $operationMutex; RecoveryMode = $true; StartedProcessRegistration = $registrationCallback }
        if (-not $startResult.Success) { throw "Committed canonical stack could not be restarted: $($startResult.Error.Message)" }
        $cpaListener = Get-CpaStackListener -Port $CpaPort
        $managerListener = Get-CpaStackListener -Port $ManagerPort
    }
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine $expectedCpaExe) {
        throw "Committed canonical CPA is not the owner of formal port $CpaPort."
    }
    if (-not $managerListener -or $managerListener.ExecutablePath -ine $expectedManagerExe) {
        throw "Committed canonical Manager is not the owner of formal port $ManagerPort."
    }
    [void](Wait-CpaStackTrustedListener -Port $CpaPort -ExpectedPath $expectedCpaExe -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash ([string]$current.cpa.sha256) -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath $expectedManagerExe -ExpectedProcessId $managerListener.ProcessId -ExpectedHash ([string]$current.manager.sha256) -Seconds 2)
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$CpaPort/v1/models" -Headers @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" } -Seconds 20
    if (-not $models.data -or @($models.data).Count -lt 1) { throw "Committed canonical CPA model list is empty." }
    $managerInfo = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/info" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ($null -eq $managerInfo.PSObject.Properties['hasHistoricalData']) { throw "Committed canonical Manager history state is unavailable." }
    $managerStatus = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/status" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ([System.IO.Path]::GetFullPath([string]$managerStatus.dbPath) -ine [System.IO.Path]::GetFullPath((Join-Path $targetManagerData "usage.sqlite"))) {
        throw "Committed canonical Manager database path is incorrect."
    }
    $startupTrusted = $true
    if ($Journal.managerBaseline) {
        [void](Set-CpaStackManagerCollector -ManagerPort $ManagerPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$Journal.managerBaseline.collectorEnabled) -Baseline $Journal.managerBaseline)
        [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey -Expected $Journal.managerBaseline)
    }
    if ($Journal.desktopShortcut) {
        Assert-TrustedDesktopShortcut -Path ([string]$Journal.desktopShortcut)
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut([string]$Journal.desktopShortcut)
        [void](Assert-CpaStackCanonicalShortcutContract -Shortcut $shortcut -StartScript $newStartScript -WorkingDirectory $opsDir)
    }
    return $true
    } catch {
        $verificationError = $_
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        if (-not $startupTrusted) {
            foreach ($process in @($recoveryStartedProcesses)) {
                try {
                    if ($null -eq $process -or $process.HasExited) { continue }
                    $actualPath = [System.IO.Path]::GetFullPath([string]$process.MainModule.FileName)
                    if (@($expectedCpaExe, $expectedManagerExe) -inotcontains $actualPath) {
                        throw "Recovery-started process identity changed before cleanup: $actualPath"
                    }
                    Stop-CpaStackStartedProcess -Process $process -ExpectedPath $actualPath
                } catch {
                    $cleanupErrors.Add($_.Exception.Message)
                }
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            throw "Committed initialization verification failed and recovery-started process cleanup also failed. Verification: $($verificationError.Exception.Message) Cleanup: $($cleanupErrors -join ' ')"
        }
        throw $verificationError
    } finally {
        foreach ($process in @($recoveryStartedProcesses)) {
            if ($null -ne $process -and $process -is [System.IDisposable]) { $process.Dispose() }
        }
    }
}

function Recover-InterruptedInitialization {
    if (-not (Test-Path -LiteralPath $initializeJournalPath -PathType Leaf)) { return $false }
    Assert-InitializationRecoveryRootTrust
    $journal = Read-CpaStackJson -Path $initializeJournalPath
    $topContract = Assert-InitializationJournalContract -Journal $journal
    $script:initializeJournal = $journal
    $script:SourceCpaRuntime = $topContract.SourceCpaRuntime
    $script:SourceCpaConfig = $topContract.SourceCpaConfig
    $script:SourceManagerRuntime = $topContract.SourceManagerRuntime
    $script:SourceManagerData = $topContract.SourceManagerData
    $script:LegacyStartScript = $topContract.LegacyStartScript
    $script:DesktopShortcut = $topContract.DesktopShortcut
    $script:sourceManagerBaseline = $journal.managerBaseline
    $script:sourceManagerBindAddress = [string]$journal.managerBindAddress

    # Everything below this contract block may stop processes, repair ACLs, write
    # configuration, or delete transaction artifacts. Keep all ownership and
    # immutable-source validation above that boundary.
    Assert-MigrationSourceBoundaries
    Assert-CpaStackLegacyCpaSource -Runtime $SourceCpaRuntime -ConfigPath $SourceCpaConfig
    Assert-CpaStackLegacyManagerSource -Runtime $SourceManagerRuntime -Data $SourceManagerData
    if ((Get-CpaStackFileHash -Path (Join-Path $SourceCpaRuntime 'cli-proxy-api.exe')) -ine [string]$journal.sourceCpaSha256) {
        throw 'Legacy CPA executable changed during interrupted initialization.'
    }
    if ((Get-CpaStackFileHash -Path (Join-Path $SourceManagerRuntime 'cpa-manager-plus.exe')) -ine [string]$journal.sourceManagerSha256) {
        throw 'Legacy Manager executable changed during interrupted initialization.'
    }
    if ((Get-CpaStackFileHash -Path $SourceCpaConfig) -ine [string]$journal.sourceCpaConfigSha256) {
        throw 'Legacy CPA config changed during interrupted initialization.'
    }
    if ($LegacyStartScript -and (Get-CpaStackFileHash -Path $LegacyStartScript) -ine [string]$journal.legacyStartScriptSha256) {
        throw 'Legacy start script changed during interrupted initialization.'
    }
    if ((Get-CpaStackFileHash -Path (Join-Path $SourceManagerData 'data.key')) -ine [string]$journal.sourceDataKeySha256) {
        throw 'Legacy Manager data.key changed during interrupted initialization.'
    }
    Set-ValidatedInitializationArtifacts -Journal $journal -TopContract $topContract

    $script:CpaPort = $topContract.CpaPort
    $script:ManagerPort = $topContract.ManagerPort
    try {
        Assert-InitializationProcessOwnership -TopContract $topContract
    } catch {
        throw "Initialization process ownership preflight failed: $($_.Exception.Message)"
    }
    $script:recoveryContractValidated = $true
    $script:persistOperationResult = $true
    Stop-InitializationTemporaryListeners -TopContract $topContract

    if (Test-Path -LiteralPath $currentStatePath -PathType Leaf) {
        if (-not (Test-CommittedCanonicalInitialization -Journal $journal)) {
            throw "Initialization current state exists but could not be verified."
        }
        Set-CpaStackRegisteredRoot -ControlRoot $ControlRoot
        Remove-SwitchJournals
        Remove-InitializationJournal
        $result.recoveredInterruptedState = $true
        $result.recoveryDisposition = "committed"
        return $true
    }

    Stop-UncommittedCanonicalProcesses -TopContract $topContract
    $journalSourceSnapshot = $journal.PSObject.Properties['sourceManagerSnapshot']
    if ($null -ne $journalSourceSnapshot -and $null -ne $journalSourceSnapshot.Value) {
        Set-SourceManagerSnapshot -Snapshot $journalSourceSnapshot.Value -Description 'Initialization journal Manager source snapshot'
    }
    $sourceCpaExe = Join-Path $SourceCpaRuntime "cli-proxy-api.exe"
    $sourceManagerExe = Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"
    $cpaListener = Get-CpaStackListener -Port $CpaPort
    $managerListener = Get-CpaStackListener -Port $ManagerPort
    $sourceOwnsPorts = ($cpaListener -and $cpaListener.ExecutablePath -ieq $sourceCpaExe -and $managerListener -and $managerListener.ExecutablePath -ieq $sourceManagerExe)
    $postSwitchPhase = [string]$journal.phase -in @("switching", "services-switched", "shortcut-updated", "state-committing")
    if ($postSwitchPhase -or -not $sourceOwnsPorts) {
        if (-not (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
            New-Item -ItemType Directory -Force -Path $configDir | Out-Null
            Initialize-Secrets
        }
        Restore-LegacyStack
        $script:legacyRestored = $true
        $result.rolledBack = $true
        $result.recoveredInterruptedState = $true
        if ($DesktopShortcut) { Restore-DesktopShortcut }
    } else {
        if (-not (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
            New-Item -ItemType Directory -Force -Path $configDir | Out-Null
            Initialize-Secrets
        }
        Assert-LegacyStackState
    }
    Remove-SwitchJournals
    Reset-CanonicalPreparation
    Remove-InitializationJournal
    $result.recoveredInterruptedState = $true
    $result.recoveryDisposition = "rolled-back"
    return $false
}

function Update-DesktopShortcut {
    if (-not $DesktopShortcut) {
        return [pscustomobject]@{ updated = $false; reason = "not-found" }
    }
    Backup-DesktopShortcut
    $icon = Join-Path $ControlRoot "assets\cpa-frontend-logo.ico"
    [void](Set-CpaStackCanonicalShortcut -ShortcutPath $DesktopShortcut -StartScript $newStartScript -WorkingDirectory $opsDir -IconPath $icon)
    return [pscustomobject]@{ updated = $true; path = $DesktopShortcut; script = $newStartScript; hiddenWindow = $true }
}

function Assert-InitializationSwitchPathBudget {
    $managerVerification = Join-Path $ControlRoot ('work\mv-' + ('0' * 32))
    Assert-CpaStackPathBudget -Paths @(
        $targetCpaRuntime,
        $targetManagerRuntime,
        $targetManagerData,
        $managerVerification,
        (Join-Path $managerVerification 'post-start'),
        (Join-Path $managerVerification 'r-3'),
        (Join-Path $managerVerification 'rp-3'),
        $migrationRollback,
        ($migrationRollback + '.previous-' + ('0' * 32))
    ) -PathType Container
    Assert-CpaStackProjectedTreePathBudget -Source $targetCpaRuntime -Destination $targetCpaRuntime
    Assert-CpaStackProjectedTreePathBudget -Source $targetManagerRuntime -Destination $targetManagerRuntime
    Assert-CpaStackPathBudget -Paths @(
        (Join-Path $targetManagerData 'usage.sqlite'),
        (Join-Path $targetManagerData 'usage.sqlite-wal'),
        (Join-Path $targetManagerData 'usage.sqlite-shm'),
        (Join-Path $targetManagerData 'data.key'),
        (Join-Path $managerVerification 'usage.sqlite'),
        (Join-Path $managerVerification 'post-start\usage.sqlite'),
        $newStartScript
    ) -PathType Leaf
    Assert-CpaStackJsonWritePathBudget -Paths @(
        $initializeJournalPath,
        $currentStatePath,
        $resultPath,
        (Join-Path $stateDir 'cpa-migration-switch.json'),
        (Join-Path $stateDir 'manager-migration-switch.json'),
        (Join-Path $stateDir 'switch-cpa.pending.json'),
        (Join-Path $stateDir 'switch-manager.pending.json'),
        (Join-Path $managerVerification 'sqlite-baseline.json'),
        (Join-Path $managerVerification 'post-start\sqlite-after.json')
    )
}

try {
    $operationMutex = Enter-CpaStackOperationLock
    if ($RecoverOnly) {
        if (-not (Test-Path -LiteralPath $initializeJournalPath -PathType Leaf)) {
            $recoveryCompleted = $true
            $result.success = $true
        } else {
            Assert-CpaStackPath -Path $ControlRoot -PathType Container
            foreach ($path in @(
                $stackConfigPath,
                $secretsPath,
                $targetCpaRuntime,
                $targetManagerRuntime,
                $targetManagerData,
                $newStartScript,
                $resultPath,
                $initializeJournalPath,
                $migrationRollback,
                (Join-Path $ControlRoot 'assets\cpa-frontend-logo.ico')
            )) {
                Assert-CpaStackChildPath -Root $ControlRoot -Path $path
            }
            $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
            $recoveryAttempted = $true
            $recoveryCommitted = Recover-InterruptedInitialization
            $recoveryCompleted = $true
            if ($recoveryCommitted) {
                $current = Read-CpaStackJson -Path $currentStatePath
                $result.cpa = $current.cpa
                $result.manager = $current.manager
                $result.shortcut = [ordered]@{ updated = $true; path = $DesktopShortcut; script = $newStartScript; hiddenWindow = $true }
            }
            $result.success = $true
        }
    } else {
        Assert-CpaStackFreeSpace -Path $ControlRoot -MinimumBytes 1073741824
        if ($CpaPort -eq $ManagerPort) { throw 'CPA and Manager formal ports must differ.' }
        foreach ($path in @(
            $stackConfigPath,
            $secretsPath,
            $targetCpaRuntime,
            $targetManagerRuntime,
            $targetManagerData,
            $newStartScript,
            $resultPath,
            $initializeJournalPath,
            (Join-Path $ControlRoot 'work\current'),
            $migrationRollback,
            (Join-Path $ControlRoot 'assets\cpa-frontend-logo.ico')
        )) {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $path
        }
        $recoveryAttempted = Test-Path -LiteralPath $initializeJournalPath -PathType Leaf
        if ($recoveryAttempted) {
            Assert-CpaStackPath -Path $ControlRoot -PathType Container
            $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
            $recoveryCommitted = Recover-InterruptedInitialization
        } else {
            New-Item -ItemType Directory -Force -Path $ControlRoot | Out-Null
            Protect-CpaStackPrivateDirectory -Path $ControlRoot
            $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot -AllowCreate
            $recoveryCommitted = $false
        }
        $recoveryCompleted = $true
        if ($recoveryCommitted) {
            $current = Read-CpaStackJson -Path $currentStatePath
            $result.cpa = $current.cpa
            $result.manager = $current.manager
            $result.shortcut = [ordered]@{ updated = $true; path = $DesktopShortcut; script = $newStartScript; hiddenWindow = $true }
            $result.success = $true
        } else {
    if (Test-Path -LiteralPath $currentStatePath -PathType Leaf) {
        throw "Canonical stack is already initialized: $currentStatePath"
    }

    if (-not $SourceCpaRuntime -or -not $SourceManagerRuntime -or (-not $LegacyStartScript -and -not $SecretsInputPath)) {
        $state = Invoke-ChildPowerShellJson -Script (Join-Path $PSScriptRoot "Get-CpaStackState.ps1") -Arguments @("-ControlRoot", $ControlRoot)
        if (-not $state.OverallHealthy -or -not $state.MigrationRequired) {
            throw "Legacy CPA stack was not discovered in a healthy migratable state."
        }
        $SourceCpaRuntime = [string]$state.Cpa.RuntimeDirectory
        $SourceCpaConfig = [string]$state.Cpa.ConfigPath
        $SourceManagerRuntime = [string]$state.Manager.RuntimeDirectory
        $SourceManagerData = [string]$state.Manager.DataDirectory
        $LegacyStartScript = [string]$state.Startup.ScriptPath
        if ($UpdateDesktopShortcut) {
            $DesktopShortcut = [string]$state.Startup.Shortcut.Path
        }
    }
    if (-not $SourceCpaConfig) { $SourceCpaConfig = Join-Path $SourceCpaRuntime "config.yaml" }
    if (-not $SourceManagerData) { $SourceManagerData = Join-Path $SourceManagerRuntime "data" }

    Assert-MigrationSourceBoundaries
    Assert-CpaStackLegacyCpaSource -Runtime $SourceCpaRuntime -ConfigPath $SourceCpaConfig
    Assert-CpaStackLegacyManagerSource -Runtime $SourceManagerRuntime -Data $SourceManagerData
    $cpaListener = Get-CpaStackListener -Port $CpaPort
    $managerListener = Get-CpaStackListener -Port $ManagerPort
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")) { throw "CPA source path does not own formal port $CpaPort." }
    if (-not $managerListener -or $managerListener.ExecutablePath -ine (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")) { throw "Manager source path does not own formal port $ManagerPort." }
    [void](Wait-CpaStackTrustedListener -Port $CpaPort -ExpectedPath (Join-Path $SourceCpaRuntime "cli-proxy-api.exe") -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash (Get-CpaStackFileHash -Path (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")) -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port $ManagerPort -ExpectedPath (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe") -ExpectedProcessId $managerListener.ProcessId -ExpectedHash (Get-CpaStackFileHash -Path (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")) -Seconds 2)

    $canonicalDirectories = @(
        $configDir,
        $opsDir,
        $stateDir,
        (Join-Path $ControlRoot "runtime"),
        (Join-Path $ControlRoot "data"),
        (Join-Path $ControlRoot "work"),
        (Join-Path $ControlRoot "rollback"),
        (Join-Path $ControlRoot "assets")
    )
    foreach ($dir in $canonicalDirectories) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    foreach ($dir in $canonicalDirectories) {
        Protect-CpaStackPrivateDirectory -Path $dir
    }
    $preparationStarted = $true
    Remove-SecretTempFiles
    Initialize-Secrets
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $sourceManagerBaseline = Get-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $secrets.managerAdminKey
    $sourceManagerConfig = Join-Path $SourceManagerRuntime "config.json"
    if (Test-Path -LiteralPath $sourceManagerConfig -PathType Leaf) {
        try {
            $runtimeConfig = [System.IO.File]::ReadAllText($sourceManagerConfig, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
            if ([string]$runtimeConfig.httpAddr -match '^(?<host>.+):\d+$') {
                $sourceManagerBindAddress = $matches['host']
            }
        } catch {}
    }
    if (-not $ExposeToLan) {
        $sourceManagerBindAddress = '127.0.0.1'
    } elseif ($sourceManagerBindAddress -eq '127.0.0.1') {
        $sourceManagerBindAddress = '0.0.0.0'
    }
    if ($sourceManagerBindAddress -notmatch '^[A-Za-z0-9.:%\[\]-]+$') { throw "Legacy Manager bind address contains unsupported characters." }
    Assert-LegacyStackState
    $candidatePortPlan = New-CpaStackCandidatePortPlan -FormalPort @($CpaPort, $ManagerPort)
    $cpaCandidatePort = [int]$candidatePortPlan.Ports.CpaCandidate
    $managerCandidatePort = [int]$candidatePortPlan.Ports.ManagerCandidate
    $initializeJournal = [pscustomobject][ordered]@{
        schemaVersion = 2
        operation = "initialize-canonical-stack"
        operationId = [guid]::NewGuid().ToString('N')
        instanceId = [string]$instanceMarker.instanceId
        phase = "preparing"
        canonicalRoot = $ControlRoot
        sourceCpaRuntime = $SourceCpaRuntime
        sourceCpaConfig = $SourceCpaConfig
        sourceManagerRuntime = $SourceManagerRuntime
        sourceManagerData = $SourceManagerData
        legacyStartScript = $LegacyStartScript
        desktopShortcut = $DesktopShortcut
        targetCpaRuntime = $targetCpaRuntime
        targetManagerRuntime = $targetManagerRuntime
        targetManagerData = $targetManagerData
        cpaVersion = $CpaVersion
        managerVersion = $ManagerVersion
        cpaPort = $CpaPort
        managerPort = $ManagerPort
        cpaCandidatePort = $cpaCandidatePort
        managerCandidatePort = $managerCandidatePort
        sourceCpaSha256 = Get-CpaStackFileHash -Path (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")
        sourceManagerSha256 = Get-CpaStackFileHash -Path (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")
        sourceCpaConfigSha256 = Get-CpaStackFileHash -Path $SourceCpaConfig
        legacyStartScriptSha256 = if ([string]::IsNullOrWhiteSpace($LegacyStartScript)) { $null } else { Get-CpaStackFileHash -Path $LegacyStartScript }
        sourceDataKeySha256 = Get-CpaStackFileHash -Path (Join-Path $SourceManagerData "data.key")
        targetCpaSha256 = $null
        targetManagerSha256 = $null
        targetCpaRuntimeManifestSha256 = $null
        targetCpaConfigSha256 = $null
        targetCpaHost = $null
        stackConfigSha256 = $null
        managerBaseline = [pscustomobject][ordered]@{
            cpaBaseUrl = [string]$sourceManagerBaseline.cpaBaseUrl
            collectorEnabled = [bool]$sourceManagerBaseline.collectorEnabled
            pollIntervalMs = [int]$sourceManagerBaseline.pollIntervalMs
            usageStatisticsEnabled = [bool]$sourceManagerBaseline.usageStatisticsEnabled
        }
        managerBindAddress = $sourceManagerBindAddress
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
    }
    Write-CpaStackJson -Value $initializeJournal -Path $initializeJournalPath
    Protect-CpaStackSecretFile -Path $initializeJournalPath
    Write-CanonicalConfiguration -RequestMonitoringEnabled ([bool]$sourceManagerBaseline.collectorEnabled) -ManagerBindAddress $sourceManagerBindAddress
    Copy-CurrentCpaRuntime -Source $SourceCpaRuntime -Destination $targetCpaRuntime -Config $SourceCpaConfig
    Copy-CurrentManagerRuntime -Source $SourceManagerRuntime -Destination $targetManagerRuntime
    [System.IO.File]::WriteAllBytes($newStartScript, (Get-CpaStackCanonicalBootstrapBytes))
    Protect-CpaStackSecretFile -Path $newStartScript
    $legacyIcon = if ($DesktopShortcut) { (New-Object -ComObject WScript.Shell).CreateShortcut($DesktopShortcut).IconLocation.Split(',')[0] } else { $null }
    if ($legacyIcon -and (Test-Path -LiteralPath $legacyIcon)) {
        Copy-Item -LiteralPath $legacyIcon -Destination (Join-Path $ControlRoot "assets\cpa-frontend-logo.ico") -Force
    }
    Backup-DesktopShortcut
    $initializeJournal.targetCpaSha256 = Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'cli-proxy-api.exe')
    $initializeJournal.targetManagerSha256 = Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime 'cpa-manager-plus.exe')
    $initializeJournal.targetCpaRuntimeManifestSha256 = [string](Get-CpaStackTreeManifest -Root $targetCpaRuntime).sha256
    $initializeJournal.targetCpaConfigSha256 = Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime 'config.yaml')
    $initializeJournal.targetCpaHost = Get-CpaStackConfigHost -ConfigPath (Join-Path $targetCpaRuntime 'config.yaml')
    $initializeJournal.stackConfigSha256 = Get-CpaStackFileHash -Path $stackConfigPath
    Set-InitializeJournalPhase -Phase "prepared"

    $cpaCandidate = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Test-CpaCandidate.ps1") -Arguments @(
        "-ControlRoot", $ControlRoot,
        "-CandidateRuntime", $targetCpaRuntime,
        "-ActiveConfig", (Join-Path $targetCpaRuntime "config.yaml"),
        "-ActiveRuntime", $SourceCpaRuntime,
        "-ExpectedCandidateHash", (Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime "cli-proxy-api.exe")),
        "-ResultPath", (Join-Path $stateDir "cpa-candidate-migration-test.json"),
        "-Port", ([string]$cpaCandidatePort)
    ) -AdditionalParameters @{ FormalPort = @($CpaPort, $ManagerPort) }
    if ([string]$cpaCandidate.runtimeManifestSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        [string]$cpaCandidate.activeConfigSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$cpaCandidate.activeConfigHost)) {
        throw 'CPA candidate did not return a complete post-exit runtime binding.'
    }
    $expectedTargetHost = [string]$cpaCandidate.activeConfigHost
    if (-not $ExposeToLan -and $expectedTargetHost -ne '127.0.0.1') {
        throw 'Canonical CPA target config did not preserve the required loopback host.'
    }
    if ($ExposeToLan -and $expectedTargetHost -ne (Get-CpaStackConfigHost -ConfigPath $SourceCpaConfig)) {
        throw 'Canonical CPA target config did not preserve the explicitly retained legacy host.'
    }
    $initializeJournal.targetCpaRuntimeManifestSha256 = [string]$cpaCandidate.runtimeManifestSha256
    $initializeJournal.targetCpaConfigSha256 = [string]$cpaCandidate.activeConfigSha256
    $initializeJournal.targetCpaHost = $expectedTargetHost
    Set-InitializeJournalPhase -Phase "cpa-candidate-validated"
    [void](Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Test-ManagerCandidate.ps1") -Arguments @(
        "-ControlRoot", $ControlRoot,
        "-CandidateRuntime", $targetManagerRuntime,
        "-FormalRuntime", $SourceManagerRuntime,
        "-FormalData", $SourceManagerData,
        "-ExpectedCandidateHash", (Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime "cpa-manager-plus.exe")),
        "-ResultPath", (Join-Path $stateDir "manager-candidate-migration-test.json"),
        "-CpaPort", ([string]$CpaPort),
        "-FormalPort", ([string]$ManagerPort),
        "-TempPort", ([string]$managerCandidatePort)
    ))
    foreach ($candidatePort in @($cpaCandidatePort, $managerCandidatePort)) {
        [void](Assert-CpaStackCandidatePort -Port $candidatePort -FormalPort @($CpaPort, $ManagerPort))
    }
    Set-InitializeJournalPhase -Phase "candidates-validated"
    Assert-InitializationSwitchPathBudget

    $cpaSwitchResult = Join-Path $stateDir "cpa-migration-switch.json"
    Set-InitializeJournalPhase -Phase "switching"
    $switchPhaseStarted = $true
    Invoke-ChildPowerShell -Script (Join-Path $PSScriptRoot "Switch-CpaRuntime.ps1") -Arguments @(
        "-ControlRoot", $ControlRoot,
        "-SourceRuntime", $SourceCpaRuntime,
        "-TargetRuntime", $targetCpaRuntime,
        "-CandidatePackageRoot", $targetCpaRuntime,
        "-SourceConfig", $SourceCpaConfig,
        "-ExpectedCandidateHash", ([string]$cpaCandidate.candidateHash),
        "-ExpectedTargetRuntimeManifestSha256", ([string]$initializeJournal.targetCpaRuntimeManifestSha256),
        "-ExpectedTargetConfigHash", ([string]$initializeJournal.targetCpaConfigSha256),
        "-ExpectedTargetHost", ([string]$initializeJournal.targetCpaHost),
        "-ResultPath", $cpaSwitchResult,
        "-Port", ([string]$CpaPort),
        "-ParentOperationId", ([string]$initializeJournal.operationId)
    )
    $result.cpa = Read-CpaStackJson -Path $cpaSwitchResult

    try {
        $managerSwitchResult = Join-Path $stateDir "manager-migration-switch.json"
        Invoke-ChildPowerShell -Script (Join-Path $PSScriptRoot "Switch-ManagerRuntime.ps1") -Arguments @(
            "-ControlRoot", $ControlRoot,
            "-SourceRuntime", $SourceManagerRuntime,
            "-SourceData", $SourceManagerData,
            "-TargetRuntime", $targetManagerRuntime,
            "-TargetData", $targetManagerData,
            "-CandidatePackageRoot", $targetManagerRuntime,
            "-ExpectedCandidateHash", (Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime "cpa-manager-plus.exe")),
            "-ResultPath", $managerSwitchResult,
            "-ManagerPort", ([string]$ManagerPort),
            "-CpaPort", ([string]$CpaPort),
            "-ParentOperationId", ([string]$initializeJournal.operationId)
        )
        $managerResult = Read-CpaStackJson -Path $managerSwitchResult
        $managerResultSourceRuntime = Split-Path -Parent ([string]$managerResult.sourcePath)
        if (-not [bool]$managerResult.success -or
            [string]$managerResult.oldHash -ne [string]$initializeJournal.sourceManagerSha256 -or
            -not [string]::Equals([System.IO.Path]::GetFullPath($managerResultSourceRuntime).TrimEnd('\'), [System.IO.Path]::GetFullPath($SourceManagerRuntime).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$managerResult.sourceData).TrimEnd('\'), [System.IO.Path]::GetFullPath($SourceManagerData).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Manager migration result is not bound to the initialization source.'
        }
        Set-SourceManagerSnapshot -Snapshot $managerResult.sourceSnapshot -Description 'Manager migration result source snapshot'
        $result.manager = $managerResult
        $initializeJournal | Add-Member -NotePropertyName sourceManagerSnapshot -NotePropertyValue $result.manager.sourceSnapshot -Force
        Set-InitializeJournalPhase -Phase "services-switched"
        $result.shortcut = Update-DesktopShortcut
        Set-InitializeJournalPhase -Phase "shortcut-updated"
    } catch {
        $managerRecoveryBlocked = $true
        $managerSwitchState = $null
        $managerSwitchValidationError = $null
        if (Test-Path -LiteralPath $managerSwitchResult -PathType Leaf) {
            try {
                $candidateManagerSwitchState = Read-CpaStackJson -Path $managerSwitchResult
                $candidateSourceRuntime = Split-Path -Parent ([string]$candidateManagerSwitchState.sourcePath)
                if ([string]$candidateManagerSwitchState.oldHash -ne [string]$initializeJournal.sourceManagerSha256 -or
                    -not [string]::Equals([System.IO.Path]::GetFullPath($candidateSourceRuntime).TrimEnd('\'), [System.IO.Path]::GetFullPath($SourceManagerRuntime).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
                    -not [string]::Equals([System.IO.Path]::GetFullPath([string]$candidateManagerSwitchState.sourceData).TrimEnd('\'), [System.IO.Path]::GetFullPath($SourceManagerData).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
                    $null -eq $candidateManagerSwitchState.sourceSnapshot) {
                    throw 'Manager switch result is not bound to the initialization source snapshot.'
                }
                Set-SourceManagerSnapshot -Snapshot $candidateManagerSwitchState.sourceSnapshot -Description 'Failed Manager migration source snapshot'
                $managerSwitchState = $candidateManagerSwitchState
                $result.manager = $candidateManagerSwitchState
            } catch {
                $managerSwitchState = $null
                $managerSwitchValidationError = $_.Exception.Message
            }
        }
        if ($managerSwitchValidationError) {
            try {
                Restore-LegacyCpa
            } catch {
                throw "Manager switch result validation failed and CPA recovery also failed. Validation: $managerSwitchValidationError CPA recovery: $($_.Exception.Message)"
            }
            throw "Manager switch result validation failed; recovery state was not trusted. $managerSwitchValidationError"
        }
        if ($null -ne $managerSwitchState -and [bool]$managerSwitchState.success) {
            Restore-LegacyStack
            $legacyRestored = $true
            $managerRecoveryBlocked = $false
            if ($DesktopShortcut) { Restore-DesktopShortcut }
            $result.rolledBack = $true
            throw
        }
        $sourceManagerExe = Join-Path $SourceManagerRuntime 'cpa-manager-plus.exe'
        $managerListener = Get-CpaStackListener -Port $ManagerPort
        $managerSafelyRestored = [bool]($null -ne $managerSwitchState -and $managerSwitchState.rolledBack)
        if (-not $managerSafelyRestored -and $managerListener -and $managerListener.ExecutablePath -ieq $sourceManagerExe) {
            Resolve-SourceManagerSnapshot
            $managerSnapshotEvidenceValid = ($null -ne $sourceManagerSnapshot)
            $managerPendingPath = Join-Path $stateDir 'switch-manager.pending.json'
            if (-not $managerSnapshotEvidenceValid -and (Test-Path -LiteralPath $managerPendingPath -PathType Leaf)) {
                $managerPendingState = Read-CpaStackJson -Path $managerPendingPath
                $managerSnapshotEvidenceValid = [string]$managerPendingState.phase -in @('prepared', 'collector-disabled')
            }
            Assert-CpaStackLegacyManagerSource -Runtime $SourceManagerRuntime -Data $SourceManagerData
            $expectedManagerHash = if ($null -ne $initializeJournal) { [string]$initializeJournal.sourceManagerSha256 } else { $null }
            $expectedDataKeyHash = if ($null -ne $initializeJournal) { [string]$initializeJournal.sourceDataKeySha256 } else { $null }
            $managerSafelyRestored = (
                $managerSnapshotEvidenceValid -and
                $expectedManagerHash -match '^[0-9A-Fa-f]{64}$' -and
                $expectedDataKeyHash -match '^[0-9A-Fa-f]{64}$' -and
                (Get-CpaStackFileHash -Path $sourceManagerExe) -eq $expectedManagerHash -and
                (Get-CpaStackFileHash -Path (Join-Path $SourceManagerData 'data.key')) -eq $expectedDataKeyHash
            )
        }
        Restore-LegacyCpa
        if ($managerSafelyRestored) {
            Assert-LegacyStackState
            $legacyRestored = $true
            $managerRecoveryBlocked = $false
            if ($DesktopShortcut) { Restore-DesktopShortcut }
            $result.rolledBack = $true
        } else {
            throw 'Manager automatic recovery did not establish a trusted legacy listener; the outer initializer refused to execute the legacy Manager.'
        }
        throw
    }

    $current = [ordered]@{
        schemaVersion = 1
        instanceId = [string]$instanceMarker.instanceId
        canonicalRoot = $ControlRoot
        initializedAt = (Get-Date).ToString("o")
        cpa = [ordered]@{
            version = $CpaVersion
            executable = Join-Path $targetCpaRuntime "cli-proxy-api.exe"
            sha256 = Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime "cli-proxy-api.exe")
            config = Join-Path $targetCpaRuntime "config.yaml"
        }
        manager = [ordered]@{
            version = $ManagerVersion
            executable = Join-Path $targetManagerRuntime "cpa-manager-plus.exe"
            sha256 = Get-CpaStackFileHash -Path (Join-Path $targetManagerRuntime "cpa-manager-plus.exe")
            data = $targetManagerData
        }
        legacyRollback = [ordered]@{
            cpaRuntime = $SourceCpaRuntime
            cpaConfig = $SourceCpaConfig
            managerRuntime = $SourceManagerRuntime
            managerData = $SourceManagerData
            startScript = $LegacyStartScript
        }
        retention = "canonical current + last-known-good; legacy roots preserved pending explicit cleanup"
    }
    Set-InitializeJournalPhase -Phase "state-committing"
    Write-CpaStackJson -Value $current -Path $currentStatePath
    Set-CpaStackRegisteredRoot -ControlRoot $ControlRoot
    $result.success = $true
    try {
        $cleanupContract = Assert-InitializationJournalContract -Journal $initializeJournal
        Set-ValidatedInitializationArtifacts -Journal $initializeJournal -TopContract $cleanupContract
        Remove-InitializationJournal
    } catch {
        $result.journalCleanupWarning = $_.Exception.Message
    }
        }
    }
} catch {
    $originalError = $_.Exception.Message
    $initializationStarted = (Test-Path -LiteralPath $initializeJournalPath -PathType Leaf)
    $recoveryInvocationFailed = ($recoveryAttempted -and -not $recoveryCompleted)
    $recoverySucceeded = (-not $switchPhaseStarted -and -not $recoveryInvocationFailed -and -not $managerRecoveryBlocked)
    if (-not $managerRecoveryBlocked -and -not $recoveryInvocationFailed -and $switchPhaseStarted -and -not $legacyRestored -and (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
        try {
            Restore-LegacyStack
            $legacyRestored = $true
            $recoverySucceeded = $true
            $result.rolledBack = $true
            if ($DesktopShortcut) { Restore-DesktopShortcut }
        } catch {
            $originalError += " Legacy recovery failed: " + $_.Exception.Message
        }
    } elseif ($switchPhaseStarted -and $legacyRestored) {
        $recoverySucceeded = $true
    } elseif ($managerRecoveryBlocked) {
        $recoverySucceeded = $false
    }
    if (($initializationStarted -or $preparationStarted) -and $recoverySucceeded) {
        try {
            if ($initializationStarted -and @($validatedInitializationJournalFiles).Count -eq 0) {
                $cleanupJournal = Read-CpaStackJson -Path $initializeJournalPath
                $script:initializeJournal = $cleanupJournal
                $cleanupContract = Assert-InitializationJournalContract -Journal $cleanupJournal
                Set-ValidatedInitializationArtifacts -Journal $cleanupJournal -TopContract $cleanupContract
            }
            Stop-InitializationTemporaryListeners -TopContract $validatedInitializationTopContract
            Remove-SwitchJournals
            Reset-CanonicalPreparation
            if ($initializationStarted) { Remove-InitializationJournal }
        } catch {
            $originalError += " Initialization cleanup failed: " + $_.Exception.Message
        }
    }
    $result.error = $originalError
} finally {
    if ($persistOperationResult) {
        try { Remove-SecretTempFiles } catch {
            if (-not $result.error) { $result.error = $_.Exception.Message } else { $result.error += " Secret temp cleanup failed: " + $_.Exception.Message }
        }
        if (Test-Path -LiteralPath $stateDir) {
            Write-CpaStackJson -Value $result -Path $resultPath
        }
    }
    Exit-CpaStackOperationLock -Mutex $operationMutex
}

$result | ConvertTo-Json -Depth 12 -Compress
if (-not $result.success) {
    Write-Error $result.error
    exit 1
}
