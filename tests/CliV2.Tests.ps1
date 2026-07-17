$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-cli-v2-' + [guid]::NewGuid().ToString('N'))
$skillRoot = Join-Path $temp 'skill'
$scripts = Join-Path $skillRoot 'scripts'
$modules = Join-Path $skillRoot 'modules'
$managedRoot = Join-Path $temp 'managed root'
$engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$powershell = (Get-Command $engineName -ErrorAction Stop).Source

function Invoke-TestCli {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

    $output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $scripts 'cpa-stack.ps1') @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $documents = @($output | ForEach-Object { [string]$_ } | Where-Object {
        $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}')
    })
    if ($documents.Count -ne 1) {
        throw "Expected exactly one JSON document. ExitCode=$exitCode Output=[$($output -join ' | ')]"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Json = $documents[0] | ConvertFrom-Json
        Output = $output
    }
}

try {
    New-Item -ItemType Directory -Force -Path $scripts, $modules, $managedRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1') -Destination $scripts
    Copy-Item -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1') -Destination $scripts
    $isolatedLocalAppData = Join-Path $temp 'local-app-data'
    New-Item -ItemType Directory -Force -Path $isolatedLocalAppData | Out-Null
    $commonFixturePath = Join-Path $scripts 'CpaStack.Common.ps1'
    $commonFixtureText = [System.IO.File]::ReadAllText($commonFixturePath, [System.Text.UTF8Encoding]::new($false, $true))
    $localAppDataLookup = "[Environment]::GetFolderPath('LocalApplicationData')"
    Assert-True ($commonFixtureText.Contains($localAppDataLookup)) 'CLI fixture can isolate the root locator and operation lock'
    $commonFixtureText = $commonFixtureText.Replace($localAppDataLookup, ("'" + $isolatedLocalAppData.Replace("'", "''") + "'"))
    [System.IO.File]::WriteAllText($commonFixturePath, $commonFixtureText, [System.Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\VERSION') -Destination $skillRoot
    if (Test-Path -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\modules')) {
        Get-ChildItem -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\modules') -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $modules -Force
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $skillRoot 'VERSION'), '1.0.9', [System.Text.Encoding]::ASCII)
    @'
function Invoke-CpaStackSelfUpdate {
    param([string]$StackRoot)
    $skillRoot = Split-Path -Parent $PSScriptRoot
    $versionPath = Join-Path $skillRoot 'VERSION'
    $current = [System.IO.File]::ReadAllText($versionPath).Trim()
    if ($current -ceq '1.0.9') {
        [System.IO.File]::WriteAllText($versionPath, '1.1.0', [System.Text.Encoding]::ASCII)
        return [pscustomobject]@{ success = $true; changed = $true; currentVersion = '1.0.9'; latestVersion = '1.1.0'; availableVersion = '1.1.0'; installedCliPath = (Join-Path $skillRoot 'scripts\cpa-stack.ps1'); error = $null }
    }
    return [pscustomobject]@{ success = $true; changed = $false; currentVersion = $current; latestVersion = $current; availableVersion = $current; installedCliPath = (Join-Path $skillRoot 'scripts\cpa-stack.ps1'); error = $null }
}
Export-ModuleMember -Function Invoke-CpaStackSelfUpdate
'@ | Set-Content -LiteralPath (Join-Path $modules 'CpaStack.SelfUpdate.psm1') -Encoding ASCII

    @'
param([string]$ControlRoot)
$initialized = Test-Path -LiteralPath (Join-Path $ControlRoot 'Initialize-CpaStack.ps1.called')
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $initialized
    CanonicalEstablished = $initialized
    MigrationRequired = (-not $initialized)
    LegacyCanonicalAdoptionRequired = $false
    InterruptedState = $false
    PendingOperations = @()
    Error = $null
} | ConvertTo-Json -Depth 8 -Compress
if (-not $initialized) { exit 1 }
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Get-CpaStackState.ps1') -Encoding UTF8

    foreach ($name in @('Initialize-CpaStack.ps1', 'Adopt-CpaStackLegacyCanonical.ps1', 'Invoke-CpaStackUpgrade.ps1')) {
        @"
param([string]`$ControlRoot)
Set-Content -LiteralPath (Join-Path `$ControlRoot '$name.called') -Value 'called' -Encoding ASCII
[pscustomobject]@{ success = `$true } | ConvertTo-Json -Compress
"@ | Set-Content -LiteralPath (Join-Path $scripts $name) -Encoding UTF8
    }

    $status = Invoke-TestCli status -Root $managedRoot -Json
    Assert-Equal 0 $status.ExitCode ('Status exits zero when inspection completed even if the stack is blocked. Output=' + ($status.Output -join ' | '))
    Assert-Equal 2 $status.Json.schemaVersion 'Status uses the v2 result envelope'
    Assert-Equal 'status' $status.Json.operation 'Status identifies the operation'
    Assert-True ([bool]$status.Json.success) 'Status reports that inspection itself succeeded'
    Assert-Equal 'Blocked' $status.Json.outcome 'Unhealthy discovered state is observable as Blocked'
    Assert-False ([bool]$status.Json.changed) 'Status is strictly read-only'

    foreach ($invalidInvocation in @(
        [pscustomobject]@{ Command = 'status'; Arguments = @('-Mode', 'Lan'); Operation = 'status' },
        [pscustomobject]@{ Command = 'migrate'; Arguments = @('-Mode', 'Lan'); Operation = 'migrate' },
        [pscustomobject]@{ Command = 'upgrade'; Arguments = @('-Mode', 'Lan'); Operation = 'upgrade' }
    )) {
        $invalidArguments = @([string]$invalidInvocation.Command, '-Root', $managedRoot) + @($invalidInvocation.Arguments) + @('-Json')
        $invalid = Invoke-TestCli @invalidArguments
        Assert-Equal 1 $invalid.ExitCode "$($invalidInvocation.Command) rejects unrelated parameters"
        Assert-Equal $invalidInvocation.Operation $invalid.Json.operation "$($invalidInvocation.Command) preserves the operation in its parameter error"
        Assert-Equal 'UnsupportedCommandParameter' $invalid.Json.error.code "$($invalidInvocation.Command) returns a stable parameter error"
    }

    $upgrade = Invoke-TestCli upgrade -Root $managedRoot -Json
    Assert-Equal 0 $upgrade.ExitCode ('Upgrade automatically migrates an unmanaged root. Output=' + ($upgrade.Output -join ' | '))
    Assert-Equal 2 $upgrade.Json.schemaVersion 'Automatic upgrade uses the v2 result envelope'
    Assert-Equal 'upgrade' $upgrade.Json.operation 'Automatic result identifies upgrade'
    Assert-Equal 'Changed' $upgrade.Json.outcome 'Automatic migration makes the overall upgrade changed'
    Assert-True ([bool]$upgrade.Json.success) 'Automatic migration and upgrade succeed as one operation'
    Assert-True (Test-Path -LiteralPath (Join-Path $managedRoot 'Initialize-CpaStack.ps1.called')) 'Upgrade automatically invokes migration once'
    Assert-True (Test-Path -LiteralPath (Join-Path $managedRoot 'Invoke-CpaStackUpgrade.ps1.called')) 'Upgrade continues to the runtime upgrade after migration'
    Assert-False (Test-Path -LiteralPath (Join-Path $managedRoot 'Adopt-CpaStackLegacyCanonical.ps1.called')) 'Auto discovery does not invoke canonical adoption when it is not requested'
    Assert-True ('migrate' -in @($upgrade.Json.automation.steps.operation)) 'Automatic result records the migration step'
    Assert-True ('upgrade' -in @($upgrade.Json.automation.steps.operation)) 'Automatic result records the runtime upgrade step'
    Assert-True ('shortcut' -in @($upgrade.Json.automation.steps.operation)) 'Automatic result records desktop shortcut maintenance'
    Assert-True ('updater' -in @($upgrade.Json.automation.steps.operation)) 'Automatic result records updater self-update before runtime work'
    Assert-True ([bool]$upgrade.Json.updater.changed) 'Automatic result reports that the updater changed across re-execution'
    Assert-Equal '1.0.9' ([string]$upgrade.Json.updater.before) 'Automatic result preserves the updater version before re-execution'
    Assert-Equal '1.1.0' ([string]$upgrade.Json.updater.after) 'Automatic result reports the updater version used for runtime work'
    Remove-Item -LiteralPath (Join-Path $managedRoot 'Invoke-CpaStackUpgrade.ps1.called') -Force

    $requestPath = Join-Path $temp 'migration request.json'
    $secretsPath = Join-Path $temp 'private secrets.json'
    Set-Content -LiteralPath $secretsPath -Value '{}' -Encoding ASCII
    [ordered]@{
        schemaVersion = 1
        sourceMode = 'Explicit'
        source = [ordered]@{
            cpaRuntime = (Join-Path $temp 'legacy cpa')
            cpaConfig = (Join-Path $temp 'legacy cpa\config.yaml')
            managerRuntime = (Join-Path $temp 'legacy manager')
            managerData = (Join-Path $temp 'legacy manager\data')
        }
        secretsInputPath = $secretsPath
        ports = [ordered]@{ cpa = 22117; manager = 28317 }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestPath -Encoding UTF8

    @'
param(
    [string]$ControlRoot,
    [string]$SourceCpaRuntime,
    [string]$SourceCpaConfig,
    [string]$SourceManagerRuntime,
    [string]$SourceManagerData,
    [string]$SecretsInputPath,
    [int]$CpaPort,
    [int]$ManagerPort
)
[pscustomobject]@{
    success = $true
    rolledBack = $false
    received = [ordered]@{
        controlRoot = $ControlRoot
        sourceCpaRuntime = $SourceCpaRuntime
        sourceCpaConfig = $SourceCpaConfig
        sourceManagerRuntime = $SourceManagerRuntime
        sourceManagerData = $SourceManagerData
        secretsInputPath = $SecretsInputPath
        cpaPort = $CpaPort
        managerPort = $ManagerPort
    }
} | ConvertTo-Json -Depth 8 -Compress
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Initialize-CpaStack.ps1') -Encoding UTF8

    $migration = Invoke-TestCli migrate -Root $managedRoot -RequestPath $requestPath -Json
    Assert-Equal 0 $migration.ExitCode ('Explicit migrate exits successfully. Output=' + ($migration.Output -join ' | '))
    Assert-Equal 2 $migration.Json.schemaVersion 'Migrate uses the v2 result envelope'
    Assert-Equal 'migrate' $migration.Json.operation 'Migrate identifies the operation'
    Assert-Equal 'Changed' $migration.Json.outcome 'Successful migration reports Changed'
    Assert-Equal 22117 $migration.Json.migration.received.cpaPort 'CPA formal port is passed as a distinct argument'
    Assert-Equal 28317 $migration.Json.migration.received.managerPort 'Manager formal port is passed as a distinct argument'
    Assert-Equal (Join-Path $temp 'legacy cpa') ([string]$migration.Json.migration.received.sourceCpaRuntime) ('Source path with spaces remains one argument. Output=' + ($migration.Output -join ' | '))
    Assert-False (Test-Path -LiteralPath (Join-Path $managedRoot 'Invoke-CpaStackUpgrade.ps1.called')) 'Migrate does not invoke upgrade'

    @'
param([string]$ControlRoot)
$recovered = Test-Path -LiteralPath (Join-Path $ControlRoot 'recovered.flag')
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $recovered
    CanonicalEstablished = $true
    MigrationRequired = $false
    LegacyCanonicalAdoptionRequired = $false
    InterruptedState = (-not $recovered)
    PendingOperations = if ($recovered) { @() } else { @((Join-Path $ControlRoot 'state\initialize.pending.json')) }
    Error = $null
} | ConvertTo-Json -Depth 8 -Compress
if (-not $recovered) { exit 1 }
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Get-CpaStackState.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot, [switch]$RecoverOnly)
Set-Content -LiteralPath (Join-Path $ControlRoot 'recovered.flag') -Value 'recovered' -Encoding ASCII
[pscustomobject]@{ success = $true; recoveredInterruptedState = $true; rolledBack = $false; recoverOnly = [bool]$RecoverOnly } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Initialize-CpaStack.ps1') -Encoding UTF8

    $automaticRecovery = Invoke-TestCli upgrade -Root $managedRoot -Json
    Assert-Equal 0 $automaticRecovery.ExitCode ('Upgrade automatically recovers one supported pending transaction. Output=' + ($automaticRecovery.Output -join ' | '))
    Assert-True ([bool]$automaticRecovery.Json.recovered) 'Automatic upgrade reports that recovery occurred'
    Assert-True (Test-Path -LiteralPath (Join-Path $managedRoot 'recovered.flag')) 'Automatic upgrade runs the matching transaction recovery path'
    Assert-True ('recover' -in @($automaticRecovery.Json.automation.steps.operation)) 'Automatic result records the recovery step'

    Remove-Item -LiteralPath (Join-Path $managedRoot 'recovered.flag') -Force

    $recovery = Invoke-TestCli recover -Root $managedRoot -Json
    Assert-Equal 0 $recovery.ExitCode ('Explicit recover exits successfully. Output=' + ($recovery.Output -join ' | '))
    Assert-Equal 2 $recovery.Json.schemaVersion 'Recover uses the v2 result envelope'
    Assert-Equal 'recover' $recovery.Json.operation 'Recover identifies the operation'
    Assert-Equal 'Changed' $recovery.Json.outcome 'Successful recovery reports Changed'
    Assert-True ([bool]$recovery.Json.recovered) 'Successful recovery is explicit in the result'
    Assert-True ([bool]$recovery.Json.recovery.recoverOnly) 'Public recover invokes initialization through its recovery-only interface'
    Assert-True (Test-Path -LiteralPath (Join-Path $managedRoot 'recovered.flag')) 'Recovery actually ran the matching transaction recovery path'

    $instanceId = [guid]::NewGuid().ToString('N')
    foreach ($directory in @('config', 'ops', 'state')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $managedRoot $directory) | Out-Null
    }
    [ordered]@{ schemaVersion = 1; instanceId = $instanceId; root = $managedRoot } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $managedRoot '.cpa-stack-instance.json') -Encoding ASCII
    [ordered]@{ schemaVersion = 1; instanceId = $instanceId; canonicalRoot = $managedRoot } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $managedRoot 'state\current.json') -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $managedRoot 'config\stack.psd1') -Value '@{ SchemaVersion = 1 }' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $managedRoot 'ops\Start-CPA-Stack.ps1') -Value '# canonical launcher' -Encoding ASCII
    @'
param([string]$ConfigPath, [switch]$NoBrowser)
[pscustomobject]@{
    Success = $true
    Cpa = [pscustomobject]@{ Action = 'Reused' }
    Manager = [pscustomobject]@{ Action = 'Started' }
    Browser = 'Skipped'
} | ConvertTo-Json -Depth 6 -Compress
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Start-CPA-Stack.ps1') -Encoding UTF8

    $start = Invoke-TestCli start -Root $managedRoot -NoBrowser -Json
    Assert-Equal 0 $start.ExitCode ('Start exits successfully. Output=' + ($start.Output -join ' | '))
    Assert-Equal 2 $start.Json.schemaVersion 'Start uses the v2 result envelope'
    Assert-Equal 'start' $start.Json.operation 'Start identifies the operation'
    Assert-Equal 'Changed' $start.Json.outcome 'Starting a stopped program reports Changed'
    Assert-Equal 'Started' $start.Json.start.Manager.Action 'Start retains structured launcher evidence'

    @'
param([string]$ControlRoot, [ValidateSet('Loopback', 'Lan')][string]$Mode)
[pscustomobject]@{
    success = $true
    changed = $true
    rolledBack = $false
    mode = $Mode
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Set-CpaStackLan.ps1') -Encoding UTF8

    $lan = Invoke-TestCli lan -Action Set -Mode Lan -Root $managedRoot -Json
    Assert-Equal 0 $lan.ExitCode ('LAN operation exits successfully. Output=' + ($lan.Output -join ' | '))
    Assert-Equal 2 $lan.Json.schemaVersion 'LAN uses the v2 result envelope'
    Assert-Equal 'lan' $lan.Json.operation 'LAN identifies the operation'
    Assert-Equal 'Changed' $lan.Json.outcome 'Applied LAN configuration reports Changed'
    Assert-Equal 'Lan' $lan.Json.lan.mode 'LAN result retains the explicit requested mode'

    @'
param([string]$ControlRoot)
Write-Error 'synthetic inspection protocol failure'
exit 1
'@ | Set-Content -LiteralPath (Join-Path $scripts 'Get-CpaStackState.ps1') -Encoding UTF8
    $failedInspection = Invoke-TestCli status -Root $managedRoot -Json
    Assert-Equal 1 $failedInspection.ExitCode 'Status returns non-zero when inspection itself fails'
    Assert-False ([bool]$failedInspection.Json.success) 'Inspection protocol failure cannot masquerade as a successful status'
    Assert-Equal 'Blocked' $failedInspection.Json.outcome 'Inspection protocol failure is a blocked operation'
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-TestPathWithRetry -Path $temp
    }
}

'CLI v2 tests passed.'
