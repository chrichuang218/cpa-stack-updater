$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$expectedVersion = (Get-Content -Raw -LiteralPath (Join-Path $repo 'VERSION')).Trim()
$cjkSuffix = -join @([char]0x7A7A, [char]0x683C)
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('CPA Stack ' + $cjkSuffix + '-' + [guid]::NewGuid().ToString('N'))
$engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$powershell = (Get-Command $engineName -ErrorAction Stop).Source
$output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'cpa-stack.ps1') plan -Root $tempRoot -Json 2>&1)
Assert-Equal 0 $LASTEXITCODE 'Plan command exits successfully'
$jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
Assert-Equal 1 $jsonLine.Count 'Plan returns exactly one JSON document'
$result = $jsonLine[0] | ConvertFrom-Json
Assert-True ([bool]$result.success) 'Plan reports success'
Assert-Equal $expectedVersion $result.updaterVersion 'Public CLI envelope reports the updater version'
Assert-Equal ([System.IO.Path]::GetFullPath($tempRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$result.root).TrimEnd('\')) 'Plan preserves explicit root'
Assert-True (@($result.warnings).Count -gt 0) 'Plan declares that it is read-only'

$usedRoots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
$unusedLetter = @('Q', 'Y', 'X', 'W') | Where-Object { $usedRoots -notcontains $_ } | Select-Object -First 1
if ($unusedLetter) {
    $missingRoot = "${unusedLetter}:\CPA-Stack"
    $missingOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'cpa-stack.ps1') plan -Root $missingRoot -Json 2>&1)
    Assert-Equal 1 $LASTEXITCODE 'Missing target drive exits non-zero'
    $missingJsonLine = @($missingOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
    Assert-Equal 1 $missingJsonLine.Count 'Missing target drive returns one JSON document'
    $missingResult = $missingJsonLine[0] | ConvertFrom-Json
    Assert-Equal 'TargetDriveNotFound' $missingResult.error.code 'Missing target drive has a stable error code'
}

$harnessContainer = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-cli-strict-mode-' + [guid]::NewGuid().ToString('N'))
$harness = Join-Path $harnessContainer 'scripts'
try {
    New-Item -ItemType Directory -Force -Path $harness | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1') -Destination $harness
    Copy-Item -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1') -Destination $harness
    Copy-Item -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade\VERSION') -Destination $harnessContainer

    @'
param([string]$ControlRoot)
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $true
    MigrationRequired = $false
    CanonicalEstablished = $true
    InterruptedState = $false
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Get-CpaStackState.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
[pscustomobject]@{
    success = $true
    cpa = [pscustomobject]@{}
    manager = [pscustomobject]@{}
    cleanupWarning = $null
    journalCleanupWarning = $null
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Invoke-CpaStackUpgrade.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
[pscustomobject]@{ success = $false } | ConvertTo-Json -Compress
exit 7
'@ | Set-Content -LiteralPath (Join-Path $harness 'Initialize-CpaStack.ps1') -Encoding UTF8

    $strictPlanOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') plan -Root $harness -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE 'Plan tolerates a successful status document without optional Error'
    $strictPlanJson = @($strictPlanOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-True ([bool]$strictPlanJson.success) 'Strict-mode plan succeeds without optional Error'

    $instanceId = [guid]::NewGuid().ToString('N')
    foreach ($directory in @('ops', 'config', 'state')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $harness $directory) | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $harness 'ops\Start-CPA-Stack.ps1') -Value '# canonical launcher slot' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $harness 'config\stack.psd1') -Value '@{ SchemaVersion = 1 }' -Encoding ASCII
    [pscustomobject]@{ schemaVersion = 1; instanceId = $instanceId; root = $harness } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $harness '.cpa-stack-instance.json') -Encoding ASCII
    [pscustomobject]@{ schemaVersion = 1; instanceId = $instanceId; canonicalRoot = $harness } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $harness 'state\current.json') -Encoding ASCII
    @'
param([string]$ConfigPath, [switch]$NoBrowser)
[pscustomobject]@{
    Success = $true
    Cpa = [pscustomobject]@{ Action = 'Reused' }
    Manager = [pscustomobject]@{ Action = 'Started' }
    Browser = 'Skipped'
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Start-CPA-Stack.ps1') -Encoding UTF8

    $startOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') start -Root $harness -NoBrowser -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE ('Start command exits successfully. Output=' + ($startOutput -join ' | '))
    $startResult = @($startOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-Equal 1 $startResult.schemaVersion 'Start uses the public versioned JSON envelope'
    Assert-Equal 'start' $startResult.command 'Start envelope identifies its command'
    Assert-True ([bool]$startResult.success) 'Start envelope preserves launcher success'
    Assert-True ([bool]$startResult.changed) 'Starting a stopped component reports a change'
    Assert-Equal 'Started' $startResult.start.Manager.Action 'Start envelope retains the structured launcher result'

    $upgradeOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') upgrade -Root $harness -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE ('Upgrade summary tolerates missing optional skipped and rolledBack fields. Output=' + ($upgradeOutput -join ' | '))
    $upgradeResult = @($upgradeOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-True ([bool]$upgradeResult.success) 'Upgrade summary preserves success'
    Assert-True ([bool]$upgradeResult.changed) 'Missing skipped fields conservatively report a change'
    Assert-False ([bool]$upgradeResult.rolledBack) 'Missing rolledBack fields default to false'

    $initOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') init -Root $harness -Json 2>&1)
    Assert-Equal 1 $LASTEXITCODE 'Bundled init failure exits non-zero'
    $initResult = @($initOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-True ([string]$initResult.error.message -match 'failed with exit code 7') 'Missing optional Error falls back to bundled output instead of a StrictMode failure'
    Assert-Equal 1 $initResult.schemaVersion 'Init uses the public versioned JSON envelope'
    Assert-Equal 'init' $initResult.command 'Init envelope identifies its command'
    Assert-False ([bool]$initResult.changed) 'A failed init does not claim a completed change'

    @'
param([string]$ControlRoot)
$migrated = Test-Path -LiteralPath (Join-Path $ControlRoot 'migrated.flag')
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $true
    MigrationRequired = (-not $migrated)
    CanonicalEstablished = $migrated
    InterruptedState = $false
    PendingOperations = @()
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Get-CpaStackState.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
Set-Content -LiteralPath (Join-Path $ControlRoot 'migrated.flag') -Value 'done' -Encoding ASCII
[pscustomobject]@{ success = $true; rolledBack = $false; error = $null } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Initialize-CpaStack.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
[pscustomobject]@{
    success = $false
    cpa = $null
    manager = $null
    error = 'synthetic upgrade failure'
} | ConvertTo-Json -Compress
exit 9
'@ | Set-Content -LiteralPath (Join-Path $harness 'Invoke-CpaStackUpgrade.ps1') -Encoding UTF8

    $partialOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') upgrade -Root $harness -Json 2>&1)
    Assert-Equal 1 $LASTEXITCODE 'Upgrade failure after successful migration exits non-zero'
    $partialResult = @($partialOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-False ([bool]$partialResult.success) 'Upgrade envelope preserves the later failure'
    Assert-True ([bool]$partialResult.changed) 'Successful migration remains reported when the later upgrade fails'
    Assert-True ([bool]$partialResult.initialization.success) 'Upgrade failure retains initialization evidence'
    Assert-Equal 'synthetic upgrade failure' $partialResult.error 'Upgrade failure retains the structured inner error'

    @'
param([string]$ControlRoot)
$adopted = Test-Path -LiteralPath (Join-Path $ControlRoot 'adopted.flag')
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $adopted
    MigrationRequired = (-not $adopted)
    LegacyCanonicalAdoptionRequired = (-not $adopted)
    CanonicalEstablished = $adopted
    InterruptedState = $false
    PendingOperations = @()
} | ConvertTo-Json -Compress
if (-not $adopted) { exit 1 }
'@ | Set-Content -LiteralPath (Join-Path $harness 'Get-CpaStackState.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
Set-Content -LiteralPath (Join-Path $ControlRoot 'adopted.flag') -Value 'done' -Encoding ASCII
[pscustomobject]@{ success = $true; changed = $true; adopted = $true; launcherUpdated = $true; error = $null } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
[pscustomobject]@{
    success = $true
    launcherUpdated = $false
    cpa = [pscustomobject]@{ success = $true; skipped = $true }
    manager = [pscustomobject]@{ success = $true; skipped = $true }
    error = $null
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Invoke-CpaStackUpgrade.ps1') -Encoding UTF8

    $adoptionOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') upgrade -Root $harness -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE ('Upgrade adopts a verified legacy canonical root before version work. Output=' + ($adoptionOutput -join ' | '))
    $adoptionResult = @($adoptionOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-True ([bool]$adoptionResult.success) 'Upgrade continues after legacy canonical adoption'
    Assert-True ([bool]$adoptionResult.changed) 'Legacy canonical adoption reports a change even when versions are current'
    Assert-True ([bool]$adoptionResult.adoption.adopted) 'Upgrade envelope retains adoption evidence'
    Assert-True (Test-Path -LiteralPath (Join-Path $harness 'adopted.flag') -PathType Leaf) 'Legacy canonical adoption actually ran'

    $pendingStateDirectory = Join-Path $harness 'state'
    New-Item -ItemType Directory -Force -Path $pendingStateDirectory | Out-Null
    $initializePendingPath = Join-Path $pendingStateDirectory 'initialize.pending.json'
    Set-Content -LiteralPath $initializePendingPath -Value '{}' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $harness 'config\stack.psd1') -Value 'malformed interrupted content' -Encoding ASCII
    @'
param([string]$ControlRoot)
$pending = Join-Path $ControlRoot 'state\initialize.pending.json'
$hasPending = Test-Path -LiteralPath $pending
if ($hasPending) {
    [pscustomobject]@{
        SchemaVersion = 1
        OverallHealthy = $false
        Error = [pscustomobject]@{ Code = 'StatusFailed'; Message = 'Synthetic malformed interrupted config.' }
    } | ConvertTo-Json -Compress
    exit 1
}
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $true
    MigrationRequired = $false
    CanonicalEstablished = $true
    InterruptedState = $false
    PendingOperations = @()
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Get-CpaStackState.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
Remove-Item -LiteralPath (Join-Path $ControlRoot 'state\initialize.pending.json') -Force
Set-Content -LiteralPath (Join-Path $ControlRoot 'recovered.flag') -Value 'done' -Encoding ASCII
[pscustomobject]@{ success = $true; recoveredInterruptedState = $true; error = $null } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Initialize-CpaStack.ps1') -Encoding UTF8

    @'
param([string]$ControlRoot)
[pscustomobject]@{
    success = $true
    cpa = [pscustomobject]@{ success = $true; skipped = $true }
    manager = [pscustomobject]@{ success = $true; skipped = $true }
    error = $null
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $harness 'Invoke-CpaStackUpgrade.ps1') -Encoding UTF8

    $recoveryOutput = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $harness 'cpa-stack.ps1') upgrade -Root $harness -Json 2>&1)
    Assert-Equal 0 $LASTEXITCODE 'Upgrade routes initialize.pending through initialization recovery'
    $recoveryResult = @($recoveryOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)[0] | ConvertFrom-Json
    Assert-True ([bool]$recoveryResult.success) 'Upgrade continues after initialization recovery succeeds'
    Assert-True ([bool]$recoveryResult.initialization.recoveredInterruptedState) 'Upgrade preserves initialization recovery evidence'
    Assert-True ([bool]$recoveryResult.changed) 'Interrupted initialization recovery reports a change'
    Assert-True (Test-Path -LiteralPath (Join-Path $harness 'recovered.flag') -PathType Leaf) 'Initialization recovery actually ran'
} finally {
    if (Test-Path -LiteralPath $harnessContainer) { Remove-Item -LiteralPath $harnessContainer -Recurse -Force }
}

'CLI tests passed.'
