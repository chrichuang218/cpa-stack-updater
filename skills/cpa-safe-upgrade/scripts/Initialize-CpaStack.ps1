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
    [string]$CpaVersion = "unknown",
    [string]$ManagerVersion = "unknown"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")

$ControlRoot = Resolve-CpaStackControlRoot -RequestedRoot $ControlRoot
$ControlRoot = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
Assert-CpaStackFreeSpace -Path $ControlRoot -MinimumBytes 1073741824
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
$sourceManagerBindAddress = "127.0.0.1"
$operationMutex = $null
$switchPhaseStarted = $false
$legacyRestored = $false
$initializeJournal = $null
$recoveryAttempted = $false
$recoveryCompleted = $false
$preparationStarted = $false
$instanceMarker = $null
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
    $output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1)
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
        Port = 8317
    }
    Manager = @{
        Executable = 'runtime\manager-plus\cpa-manager-plus.exe'
        WorkingDirectory = 'runtime\manager-plus'
        DataDirectory = 'data\manager-plus'
        Port = 18317
        BindAddress = '$ManagerBindAddress'
        RequestMonitoringEnabled = $monitoringLiteral
    }
    Browser = @{
        Url = 'http://127.0.0.1:18317/management.html'
        Executable = ''
    }
}
"@
    [System.IO.File]::WriteAllText($stackConfigPath, $content, [System.Text.UTF8Encoding]::new($false))
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
    $process = Start-CpaStackProcess -FilePath $exe -Arguments "-config `"$SourceCpaConfig`"" -WorkingDirectory $SourceCpaRuntime -MinimalEnvironment
    [void](Wait-CpaStackTrustedListener -Port 8317 -ExpectedPath $exe -ExpectedProcessId $process.Id -ExpectedHash (Get-CpaStackFileHash -Path $exe) -Seconds 35)
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:8317/v0/management/config" -Headers @{ Authorization = "Bearer $($secrets.cpaManagementKey)" } -Seconds 35)
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:8317/v1/models" -Headers @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" } -Seconds 20
    if (-not $models.data -or @($models.data).Count -lt 1) {
        throw "Legacy CPA did not recover with a non-empty model list."
    }
}

function Start-LegacyManager {
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $exe = Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"
    $environment = @{
        HTTP_ADDR = "${sourceManagerBindAddress}:18317"
        USAGE_DATA_DIR = $SourceManagerData
        USAGE_DB_PATH = (Join-Path $SourceManagerData "usage.sqlite")
        CPA_MANAGER_ADMIN_KEY = [string]$secrets.managerAdminKey
    }
    $process = Start-CpaStackProcess -FilePath $exe -WorkingDirectory $SourceManagerRuntime -Environment $environment -RemoveEnvironment @("PANEL_PATH") -MinimalEnvironment
    [void](Wait-CpaStackTrustedListener -Port 18317 -ExpectedPath $exe -ExpectedProcessId $process.Id -ExpectedHash (Get-CpaStackFileHash -Path $exe) -AllowedAddresses @($sourceManagerBindAddress) -Seconds 35)
    [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:18317/health" -Seconds 35)
}

function Assert-LegacyStackState {
    if ($null -eq $sourceManagerBaseline) { throw "Legacy Manager baseline is unavailable." }
    $sourceCpaExe = Join-Path $SourceCpaRuntime "cli-proxy-api.exe"
    $sourceManagerExe = Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"
    $cpaListener = Get-CpaStackListener -Port 8317
    $managerListener = Get-CpaStackListener -Port 18317
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine $sourceCpaExe) { throw "Legacy CPA does not own port 8317." }
    if (-not $managerListener -or $managerListener.ExecutablePath -ine $sourceManagerExe) { throw "Legacy Manager does not own port 18317." }
    [void](Wait-CpaStackTrustedListener -Port 8317 -ExpectedPath $sourceCpaExe -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash (Get-CpaStackFileHash -Path $sourceCpaExe) -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port 18317 -ExpectedPath $sourceManagerExe -ExpectedProcessId $managerListener.ProcessId -ExpectedHash (Get-CpaStackFileHash -Path $sourceManagerExe) -Seconds 2)
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:8317/v1/models" -Headers @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" } -Seconds 20
    if (-not $models.data -or @($models.data).Count -lt 1) { throw "Legacy CPA model list is empty." }
    [void](Set-CpaStackManagerCollector -ManagerPort 18317 -CpaPort 8317 -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$sourceManagerBaseline.collectorEnabled) -Baseline $sourceManagerBaseline)
    [void](Assert-CpaStackManagerSetupBaseline -ManagerPort 18317 -ManagerAdminKey $secrets.managerAdminKey -Expected $sourceManagerBaseline)
    $status = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:18317/status" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ([System.IO.Path]::GetFullPath([string]$status.dbPath) -ine [System.IO.Path]::GetFullPath((Join-Path $SourceManagerData "usage.sqlite"))) {
        throw "Legacy Manager database path does not match the migration source."
    }
    $info = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:18317/usage-service/info" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ($null -eq $info.PSObject.Properties['hasHistoricalData']) { throw "Legacy Manager history state is unavailable." }
    Assert-CpaStackPath -Path (Join-Path $SourceManagerData "data.key") -PathType Leaf
}

function Restore-LegacyStack {
    $managerListener = Get-CpaStackListener -Port 18317
    if ($managerListener) {
        $allowedManagerPaths = @((Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"), (Join-Path $targetManagerRuntime "cpa-manager-plus.exe"))
        if ($allowedManagerPaths -inotcontains $managerListener.ExecutablePath) { throw "Unexpected process owns port 18317 during legacy recovery." }
        Stop-CpaStackPort -Port 18317 -ExpectedPath $managerListener.ExecutablePath
    }
    $cpaListener = Get-CpaStackListener -Port 8317
    if ($cpaListener) {
        $allowedCpaPaths = @((Join-Path $SourceCpaRuntime "cli-proxy-api.exe"), (Join-Path $targetCpaRuntime "cli-proxy-api.exe"))
        if ($allowedCpaPaths -inotcontains $cpaListener.ExecutablePath) { throw "Unexpected process owns port 8317 during legacy recovery." }
        Stop-CpaStackPort -Port 8317 -ExpectedPath $cpaListener.ExecutablePath
    }
    Start-LegacyCpa
    Start-LegacyManager
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

function Remove-SecretTempFiles {
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) { return }
    foreach ($file in Get-ChildItem -Force -LiteralPath $configDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^secrets\.local\.json\.secure-[0-9a-fA-F]{32}$' }) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $file.FullName
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
    }
}

function Stop-InitializationTemporaryListeners {
    foreach ($entry in @(
        [pscustomobject]@{ Port = 8318; Expected = (Join-Path $targetCpaRuntime "cli-proxy-api.exe") },
        [pscustomobject]@{ Port = 18318; Expected = (Join-Path $targetManagerRuntime "cpa-manager-plus.exe") }
    )) {
        $listener = Get-CpaStackListener -Port $entry.Port
        if (-not $listener) { continue }
        if ($listener.ExecutablePath -ine $entry.Expected) {
            throw "Unexpected process owns initialization temporary port $($entry.Port): $($listener.ExecutablePath)"
        }
        Stop-CpaStackPort -Port $entry.Port -ExpectedPath $entry.Expected
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
    foreach ($path in @($initializeJournalPath, ($initializeJournalPath + ".previous"))) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Remove-SwitchJournals {
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) { return }
    foreach ($journal in Get-ChildItem -Force -LiteralPath $stateDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^switch-(cpa|manager)\.pending\.json(\.previous)?$' }) {
        Remove-Item -LiteralPath $journal.FullName -Force -ErrorAction Stop
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
    foreach ($path in @($targetCpaRuntime, $targetManagerRuntime, $targetManagerData, (Join-Path $ControlRoot "releases\current"), (Join-Path $ControlRoot "rollback\last-known-good"))) {
        if (Test-Path -LiteralPath $path) {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $path
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        }
    }
    $workDir = Join-Path $ControlRoot "work"
    if (Test-Path -LiteralPath $workDir -PathType Container) {
        foreach ($child in Get-ChildItem -Force -LiteralPath $workDir) {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
    }
    $rollbackDir = Join-Path $ControlRoot "rollback"
    if (Test-Path -LiteralPath $rollbackDir -PathType Container) {
        foreach ($child in Get-ChildItem -Force -LiteralPath $rollbackDir | Where-Object { $_.Name -match '^(pending|staging)-' }) {
            Assert-CpaStackChildPath -Root $ControlRoot -Path $child.FullName
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
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
    $cpaListener = Get-CpaStackListener -Port 8317
    $managerListener = Get-CpaStackListener -Port 18317
    $expectedCpaExe = Join-Path $targetCpaRuntime "cli-proxy-api.exe"
    $expectedManagerExe = Join-Path $targetManagerRuntime "cpa-manager-plus.exe"
    if ($cpaListener -and $cpaListener.ExecutablePath -ine $expectedCpaExe) {
        throw "An unexpected process owns port 8317 during committed initialization recovery."
    }
    if ($managerListener -and $managerListener.ExecutablePath -ine $expectedManagerExe) {
        throw "An unexpected process owns port 18317 during committed initialization recovery."
    }
    if (-not $cpaListener -or -not $managerListener) {
        $startResult = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot 'Start-CPA-Stack.ps1') -Arguments @("-NoBrowser", "-ConfigPath", $stackConfigPath) -AdditionalParameters @{ OperationLockHandle = $operationMutex; RecoveryMode = $true }
        if (-not $startResult.Success) { throw "Committed canonical stack could not be restarted: $($startResult.Error.Message)" }
        $cpaListener = Get-CpaStackListener -Port 8317
        $managerListener = Get-CpaStackListener -Port 18317
    }
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine $expectedCpaExe) {
        throw "Committed canonical CPA is not the owner of port 8317."
    }
    if (-not $managerListener -or $managerListener.ExecutablePath -ine $expectedManagerExe) {
        throw "Committed canonical Manager is not the owner of port 18317."
    }
    [void](Wait-CpaStackTrustedListener -Port 8317 -ExpectedPath $expectedCpaExe -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash ([string]$current.cpa.sha256) -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port 18317 -ExpectedPath $expectedManagerExe -ExpectedProcessId $managerListener.ProcessId -ExpectedHash ([string]$current.manager.sha256) -Seconds 2)
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:8317/v1/models" -Headers @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" } -Seconds 20
    if (-not $models.data -or @($models.data).Count -lt 1) { throw "Committed canonical CPA model list is empty." }
    $managerInfo = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:18317/usage-service/info" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ($null -eq $managerInfo.PSObject.Properties['hasHistoricalData']) { throw "Committed canonical Manager history state is unavailable." }
    $managerStatus = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:18317/status" -Headers @{ Authorization = "Bearer $($secrets.managerAdminKey)" } -Seconds 20
    if ([System.IO.Path]::GetFullPath([string]$managerStatus.dbPath) -ine [System.IO.Path]::GetFullPath((Join-Path $targetManagerData "usage.sqlite"))) {
        throw "Committed canonical Manager database path is incorrect."
    }
    if ($Journal.managerBaseline) {
        [void](Set-CpaStackManagerCollector -ManagerPort 18317 -CpaPort 8317 -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$Journal.managerBaseline.collectorEnabled) -Baseline $Journal.managerBaseline)
        [void](Assert-CpaStackManagerSetupBaseline -ManagerPort 18317 -ManagerAdminKey $secrets.managerAdminKey -Expected $Journal.managerBaseline)
    }
    if ($Journal.desktopShortcut) {
        Assert-TrustedDesktopShortcut -Path ([string]$Journal.desktopShortcut)
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut([string]$Journal.desktopShortcut)
        if ($shortcut.Arguments -notmatch [regex]::Escape($newStartScript) -or $shortcut.WorkingDirectory -ine $opsDir) {
            throw "Committed desktop shortcut does not target the canonical start script."
        }
    }
    return $true
}

function Recover-InterruptedInitialization {
    if (-not (Test-Path -LiteralPath $initializeJournalPath -PathType Leaf)) { return $false }
    $journal = Read-CpaStackJson -Path $initializeJournalPath
    if ([string]$journal.operation -ne "initialize-canonical-stack") {
        throw "Unexpected initialization journal: $initializeJournalPath"
    }
    if ([System.IO.Path]::GetFullPath([string]$journal.canonicalRoot).TrimEnd('\') -ine [System.IO.Path]::GetFullPath($ControlRoot).TrimEnd('\')) {
        throw "Initialization journal belongs to a different canonical root."
    }
    if ($null -eq $instanceMarker -or [string]$journal.instanceId -ne [string]$instanceMarker.instanceId) {
        throw "Initialization journal belongs to a different CPA stack instance."
    }
    foreach ($pair in @(
        @([string]$journal.targetCpaRuntime, $targetCpaRuntime, "CPA runtime"),
        @([string]$journal.targetManagerRuntime, $targetManagerRuntime, "Manager runtime"),
        @([string]$journal.targetManagerData, $targetManagerData, "Manager data")
    )) {
        if ([System.IO.Path]::GetFullPath($pair[0]).TrimEnd('\') -ine [System.IO.Path]::GetFullPath($pair[1]).TrimEnd('\')) {
            throw "Initialization journal $($pair[2]) target is invalid."
        }
    }
    $script:SourceCpaRuntime = [string]$journal.sourceCpaRuntime
    $script:SourceCpaConfig = [string]$journal.sourceCpaConfig
    $script:SourceManagerRuntime = [string]$journal.sourceManagerRuntime
    $script:SourceManagerData = [string]$journal.sourceManagerData
    $script:LegacyStartScript = [string]$journal.legacyStartScript
    $script:DesktopShortcut = [string]$journal.desktopShortcut
    if ($journal.managerBaseline) { $script:sourceManagerBaseline = $journal.managerBaseline }
    if ($journal.managerBindAddress) { $script:sourceManagerBindAddress = [string]$journal.managerBindAddress }
    if ($sourceManagerBindAddress -notmatch '^[A-Za-z0-9.:%\[\]-]+$') { throw "Initialization journal Manager bind address is invalid." }
    foreach ($field in @("cpaBaseUrl", "collectorEnabled", "pollIntervalMs", "usageStatisticsEnabled")) {
        if ($null -eq $sourceManagerBaseline -or $null -eq $sourceManagerBaseline.PSObject.Properties[$field]) {
            throw "Initialization journal is missing Manager baseline field $field."
        }
    }
    Stop-InitializationTemporaryListeners

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

    Assert-MigrationSourceBoundaries
    Assert-CpaStackLegacyCpaSource -Runtime $SourceCpaRuntime -ConfigPath $SourceCpaConfig
    foreach ($field in @("sourceCpaSha256", "sourceManagerSha256", "sourceCpaConfigSha256", "sourceDataKeySha256")) {
        if ([string]$journal.$field -notmatch '^[0-9A-Fa-f]{64}$') { throw "Initialization journal hash field is invalid: $field" }
    }
    if ($LegacyStartScript -and [string]$journal.legacyStartScriptSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'Initialization journal legacy start script hash is invalid.'
    }
    if ((Get-CpaStackFileHash -Path (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")) -ne [string]$journal.sourceCpaSha256) {
        throw "Legacy CPA executable changed during interrupted initialization."
    }
    if ((Get-CpaStackFileHash -Path (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")) -ne [string]$journal.sourceManagerSha256) {
        throw "Legacy Manager executable changed during interrupted initialization."
    }
    if ((Get-CpaStackFileHash -Path $SourceCpaConfig) -ne [string]$journal.sourceCpaConfigSha256) { throw "Legacy CPA config changed during interrupted initialization." }
    if ($LegacyStartScript -and (Get-CpaStackFileHash -Path $LegacyStartScript) -ne [string]$journal.legacyStartScriptSha256) { throw "Legacy start script changed during interrupted initialization." }
    if ((Get-CpaStackFileHash -Path (Join-Path $SourceManagerData "data.key")) -ne [string]$journal.sourceDataKeySha256) { throw "Legacy Manager data.key changed during interrupted initialization." }

    $sourceCpaExe = Join-Path $SourceCpaRuntime "cli-proxy-api.exe"
    $sourceManagerExe = Join-Path $SourceManagerRuntime "cpa-manager-plus.exe"
    $cpaListener = Get-CpaStackListener -Port 8317
    $managerListener = Get-CpaStackListener -Port 18317
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
    $wsh = New-Object -ComObject WScript.Shell
    $link = $wsh.CreateShortcut($DesktopShortcut)
    $link.TargetPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    $link.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$newStartScript`""
    $link.WorkingDirectory = $opsDir
    $icon = Join-Path $ControlRoot "assets\cpa-frontend-logo.ico"
    if (Test-Path -LiteralPath $icon) {
        $link.IconLocation = "$icon,0"
    }
    $link.Save()
    $verify = $wsh.CreateShortcut($DesktopShortcut)
    if ($verify.Arguments -notmatch [regex]::Escape($newStartScript) -or $verify.WorkingDirectory -ine $opsDir) {
        throw "Desktop shortcut verification failed."
    }
    return [pscustomobject]@{ updated = $true; path = $DesktopShortcut; script = $newStartScript }
}

try {
    $operationMutex = Enter-CpaStackOperationLock
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
    New-Item -ItemType Directory -Force -Path $ControlRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $ControlRoot
    $instanceMarker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot -AllowCreate
    $recoveryAttempted = Test-Path -LiteralPath $initializeJournalPath -PathType Leaf
    $recoveryCommitted = Recover-InterruptedInitialization
    $recoveryCompleted = $true
    if ($recoveryCommitted) {
        $current = Read-CpaStackJson -Path $currentStatePath
        $result.cpa = $current.cpa
        $result.manager = $current.manager
        $result.shortcut = [ordered]@{ updated = $true; path = $DesktopShortcut; script = $newStartScript }
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
    $cpaListener = Get-CpaStackListener -Port 8317
    $managerListener = Get-CpaStackListener -Port 18317
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")) { throw "CPA source path does not own port 8317." }
    if (-not $managerListener -or $managerListener.ExecutablePath -ine (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")) { throw "Manager source path does not own port 18317." }
    [void](Wait-CpaStackTrustedListener -Port 8317 -ExpectedPath (Join-Path $SourceCpaRuntime "cli-proxy-api.exe") -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash (Get-CpaStackFileHash -Path (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")) -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port 18317 -ExpectedPath (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe") -ExpectedProcessId $managerListener.ProcessId -ExpectedHash (Get-CpaStackFileHash -Path (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")) -Seconds 2)

    foreach ($dir in @($configDir, $opsDir, $stateDir, (Join-Path $ControlRoot "work"), (Join-Path $ControlRoot "rollback"), (Join-Path $ControlRoot "assets"))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    foreach ($privateDir in @($configDir, (Join-Path $ControlRoot "work"), (Join-Path $ControlRoot "rollback"))) {
        Protect-CpaStackPrivateDirectory -Path $privateDir
    }
    $preparationStarted = $true
    Remove-SecretTempFiles
    Initialize-Secrets
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $sourceManagerBaseline = Get-CpaStackManagerSetupBaseline -ManagerPort 18317 -ManagerAdminKey $secrets.managerAdminKey
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
    $initializeJournal = [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = "initialize-canonical-stack"
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
        sourceCpaSha256 = Get-CpaStackFileHash -Path (Join-Path $SourceCpaRuntime "cli-proxy-api.exe")
        sourceManagerSha256 = Get-CpaStackFileHash -Path (Join-Path $SourceManagerRuntime "cpa-manager-plus.exe")
        sourceCpaConfigSha256 = Get-CpaStackFileHash -Path $SourceCpaConfig
        legacyStartScriptSha256 = if ([string]::IsNullOrWhiteSpace($LegacyStartScript)) { $null } else { Get-CpaStackFileHash -Path $LegacyStartScript }
        sourceDataKeySha256 = Get-CpaStackFileHash -Path (Join-Path $SourceManagerData "data.key")
        targetCpaRuntimeManifestSha256 = $null
        targetCpaConfigSha256 = $null
        targetCpaHost = $null
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
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Start-CPA-Stack.ps1") -Destination $newStartScript -Force
    $legacyIcon = if ($DesktopShortcut) { (New-Object -ComObject WScript.Shell).CreateShortcut($DesktopShortcut).IconLocation.Split(',')[0] } else { $null }
    if ($legacyIcon -and (Test-Path -LiteralPath $legacyIcon)) {
        Copy-Item -LiteralPath $legacyIcon -Destination (Join-Path $ControlRoot "assets\cpa-frontend-logo.ico") -Force
    }
    Backup-DesktopShortcut
    Set-InitializeJournalPhase -Phase "prepared"

    $cpaCandidate = Invoke-InProcessPowerShellJson -Script (Join-Path $PSScriptRoot "Test-CpaCandidate.ps1") -Arguments @(
        "-ControlRoot", $ControlRoot,
        "-CandidateRuntime", $targetCpaRuntime,
        "-ActiveConfig", (Join-Path $targetCpaRuntime "config.yaml"),
        "-ActiveRuntime", $SourceCpaRuntime,
        "-ExpectedCandidateHash", (Get-CpaStackFileHash -Path (Join-Path $targetCpaRuntime "cli-proxy-api.exe")),
        "-ResultPath", (Join-Path $stateDir "cpa-8318-migration-test.json")
    )
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
        "-ResultPath", (Join-Path $stateDir "manager-18318-migration-test.json")
    ))
    Set-InitializeJournalPhase -Phase "candidates-validated"

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
        "-ResultPath", $cpaSwitchResult
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
            "-ResultPath", $managerSwitchResult
        )
        $result.manager = Read-CpaStackJson -Path $managerSwitchResult
        Set-InitializeJournalPhase -Phase "services-switched"
        $result.shortcut = Update-DesktopShortcut
        Set-InitializeJournalPhase -Phase "shortcut-updated"
    } catch {
        Restore-LegacyStack
        $legacyRestored = $true
        if ($DesktopShortcut) { Restore-DesktopShortcut }
        $result.rolledBack = $true
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
        Remove-InitializationJournal
    } catch {
        $result.journalCleanupWarning = $_.Exception.Message
    }
    }
} catch {
    $originalError = $_.Exception.Message
    $initializationStarted = (Test-Path -LiteralPath $initializeJournalPath -PathType Leaf)
    $recoveryInvocationFailed = ($recoveryAttempted -and -not $recoveryCompleted)
    $recoverySucceeded = (-not $switchPhaseStarted -and -not $recoveryInvocationFailed)
    if (-not $recoveryInvocationFailed -and $switchPhaseStarted -and -not $legacyRestored -and (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
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
    }
    if (($initializationStarted -or $preparationStarted) -and $recoverySucceeded) {
        try {
            Stop-InitializationTemporaryListeners
            Remove-SwitchJournals
            Reset-CanonicalPreparation
            Remove-InitializationJournal
        } catch {
            $originalError += " Initialization cleanup failed: " + $_.Exception.Message
        }
    }
    $result.error = $originalError
} finally {
    try { Remove-SecretTempFiles } catch {
        if (-not $result.error) { $result.error = $_.Exception.Message } else { $result.error += " Secret temp cleanup failed: " + $_.Exception.Message }
    }
    if (Test-Path -LiteralPath $stateDir) {
        Write-CpaStackJson -Value $result -Path $resultPath
    }
    Exit-CpaStackOperationLock -Mutex $operationMutex
}

$result | ConvertTo-Json -Depth 12 -Compress
if (-not $result.success) {
    Write-Error $result.error
    exit 1
}
