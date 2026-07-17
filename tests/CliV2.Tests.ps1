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

    @'
param([string]$ControlRoot)
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $false
    CanonicalEstablished = $false
    MigrationRequired = $true
    LegacyCanonicalAdoptionRequired = $false
    InterruptedState = $false
    PendingOperations = @()
    Error = $null
} | ConvertTo-Json -Depth 8 -Compress
exit 1
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

    foreach ($legacyInspectionCommand in @('doctor', 'plan')) {
        $legacyInspection = Invoke-TestCli $legacyInspectionCommand -Root $managedRoot -Json
        Assert-Equal 0 $legacyInspection.ExitCode "$legacyInspectionCommand remains a successful read-only compatibility command"
        Assert-Equal 2 $legacyInspection.Json.schemaVersion "$legacyInspectionCommand uses the v2 result envelope"
        Assert-Equal 'status' $legacyInspection.Json.operation "$legacyInspectionCommand maps to the status operation"
        Assert-Equal $legacyInspectionCommand $legacyInspection.Json.deprecatedCommand "$legacyInspectionCommand identifies the deprecated command"
        Assert-True (@($legacyInspection.Json.warnings).Count -gt 0) "$legacyInspectionCommand reports its one-release deprecation"
        Assert-False ([bool]$legacyInspection.Json.changed) "$legacyInspectionCommand remains read-only"
    }

    $legacyCombinedInit = Invoke-TestCli init -Root $managedRoot -ExposeToLan -Json
    Assert-Equal 1 $legacyCombinedInit.ExitCode 'Deprecated init rejects an implicit LAN side effect'
    Assert-Equal 2 $legacyCombinedInit.Json.schemaVersion 'Deprecated init failure uses the v2 result envelope'
    Assert-Equal 'migrate' $legacyCombinedInit.Json.operation 'Deprecated init maps to migrate'
    Assert-Equal 'init' $legacyCombinedInit.Json.deprecatedCommand 'Deprecated init identifies the compatibility command'
    Assert-Equal 'OperationSplitRequired' $legacyCombinedInit.Json.error.code 'Deprecated init requires explicit split operations'

    foreach ($invalidInvocation in @(
        [pscustomobject]@{ Command = 'status'; Arguments = @('-Mode', 'Lan'); Operation = 'status' },
        [pscustomobject]@{ Command = 'migrate'; Arguments = @('-ExposeToLan'); Operation = 'migrate' },
        [pscustomobject]@{ Command = 'upgrade'; Arguments = @('-RequestPath', (Join-Path $temp 'not-used.json')); Operation = 'upgrade' }
    )) {
        $invalidArguments = @([string]$invalidInvocation.Command, '-Root', $managedRoot) + @($invalidInvocation.Arguments) + @('-Json')
        $invalid = Invoke-TestCli @invalidArguments
        Assert-Equal 1 $invalid.ExitCode "$($invalidInvocation.Command) rejects unrelated parameters"
        Assert-Equal $invalidInvocation.Operation $invalid.Json.operation "$($invalidInvocation.Command) preserves the operation in its parameter error"
        Assert-Equal 'UnsupportedCommandParameter' $invalid.Json.error.code "$($invalidInvocation.Command) returns a stable parameter error"
    }

    $upgrade = Invoke-TestCli upgrade -Root $managedRoot -Json
    Assert-Equal 1 $upgrade.ExitCode 'Upgrade is blocked when explicit migration is required'
    Assert-Equal 2 $upgrade.Json.schemaVersion ('Blocked upgrade uses the v2 result envelope. Output=' + ($upgrade.Output -join ' | '))
    Assert-Equal 'upgrade' $upgrade.Json.operation 'Blocked result identifies upgrade'
    Assert-Equal 'Blocked' $upgrade.Json.outcome 'Migration requirement blocks upgrade'
    Assert-Equal 'MigrationRequired' $upgrade.Json.error.code ('Upgrade returns a stable explicit-migration error. Output=' + ($upgrade.Output -join ' | '))
    foreach ($name in @('Initialize-CpaStack.ps1', 'Adopt-CpaStackLegacyCanonical.ps1', 'Invoke-CpaStackUpgrade.ps1')) {
        Assert-False (Test-Path -LiteralPath (Join-Path $managedRoot ($name + '.called'))) "Upgrade must not invoke $name"
    }

    $split = Invoke-TestCli upgrade -Root $managedRoot -ExposeToLan -Json
    Assert-Equal 1 $split.ExitCode 'Legacy combined upgrade intent is rejected'
    Assert-Equal 'OperationSplitRequired' $split.Json.error.code 'Combined upgrade intent returns a stable split-operation error'

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

    $legacySecretsOnly = Invoke-TestCli init -Root $managedRoot -SecretsInputPath $secretsPath -Json
    Assert-Equal 0 $legacySecretsOnly.ExitCode ('Deprecated init preserves secrets-only auto discovery. Output=' + ($legacySecretsOnly.Output -join ' | '))
    Assert-Equal 'migrate' $legacySecretsOnly.Json.operation 'Deprecated secrets-only init maps to migrate'
    Assert-Equal 'init' $legacySecretsOnly.Json.deprecatedCommand 'Deprecated secrets-only init identifies the compatibility command'
    Assert-Equal $secretsPath ([string]$legacySecretsOnly.Json.migration.received.secretsInputPath) 'Deprecated init forwards SecretsInputPath during auto discovery'

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

    $blockedByPending = Invoke-TestCli upgrade -Root $managedRoot -Json
    Assert-Equal 1 $blockedByPending.ExitCode 'Upgrade does not recover implicitly'
    Assert-Equal 'RecoveryRequired' $blockedByPending.Json.outcome 'Upgrade exposes the explicit recovery state'
    Assert-False (Test-Path -LiteralPath (Join-Path $managedRoot 'recovered.flag')) 'Blocked upgrade does not run recovery'

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

    $register = Invoke-TestCli register-root -Root $managedRoot -Json
    Assert-Equal 0 $register.ExitCode ('register-root compatibility command succeeds. Output=' + ($register.Output -join ' | '))
    Assert-Equal 2 $register.Json.schemaVersion 'register-root uses the v2 result envelope'
    Assert-Equal 'register-root' $register.Json.operation 'register-root identifies its compatibility operation'
    Assert-Equal 'Changed' $register.Json.outcome 'register-root reports its locator write'
    Assert-True (@($register.Json.warnings).Count -gt 0) 'register-root reports its one-release deprecation'
    $locatorPath = Join-Path $isolatedLocalAppData 'CPAStack\root.json'
    Assert-True (Test-Path -LiteralPath $locatorPath -PathType Leaf) 'register-root writes only the isolated root locator'
    $locator = [System.IO.File]::ReadAllText($locatorPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    Assert-Equal ([System.IO.Path]::GetFullPath($managedRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$locator.root).TrimEnd('\')) 'register-root stores the requested managed root'

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
