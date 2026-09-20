$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts\Invoke-CpaStackUpgrade.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-Equal 0 @($parseErrors).Count 'Recovery script parses'
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-SwitchPhaseState' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
function Get-RequiredJournalProperty { param($Journal, $Name, $JournalPath) return $Journal[$Name] }

foreach ($phase in @('target-started', 'runtime-verified')) {
    foreach ($case in @(
        @{ Component='cpa'; Recorded='A'; Active='A'; Backup='C:\fixture\backup'; Pid=123; Accept=$true },
        @{ Component='cpa'; Recorded='A'; Active='B'; Backup='C:\fixture\backup'; Pid=123; Accept=$true },
        @{ Component='cpa'; Recorded='B'; Active='B'; Backup='C:\fixture\backup'; Pid=123; Accept=$true },
        @{ Component='cpa'; Recorded='B'; Active='A'; Backup='C:\fixture\backup'; Pid=123; Accept=$false },
        @{ Component='cpa'; Recorded='A'; Active='C'; Backup='C:\fixture\backup'; Pid=123; Accept=$false },
        @{ Component='cpa'; Recorded='C'; Active='A'; Backup='C:\fixture\backup'; Pid=123; Accept=$false },
        @{ Component='cpa'; Recorded='A'; Active='A'; Backup=''; Pid=123; Accept=$false },
        @{ Component='cpa'; Recorded='A'; Active='A'; Backup='C:\fixture\backup'; Pid=0; Accept=$false },
        @{ Component='manager'; Recorded='A'; Active='A'; Backup='C:\fixture\backup'; Pid=123; Accept=$false },
        @{ Component='manager'; Recorded='A'; Active='B'; Backup='C:\fixture\backup'; Pid=123; Accept=$true }
    )) {
        $accepted = $true
        try {
            Assert-SwitchPhaseState -Component $case.Component -Phase $phase -RecordedHash ($case.Recorded * 64) `
                -ActiveHash ($case.Active * 64) -OldHash ('A' * 64) -NewHash ('B' * 64) `
                -PendingPath $case.Backup -Journal @{ targetProcessId=$case.Pid } -JournalPath 'fixture'
        } catch { $accepted = $false }
        Assert-Equal $case.Accept $accepted "$phase $($case.Component) recorded=$($case.Recorded) active=$($case.Active) preserves recovery boundary"
    }
}
foreach ($active in @('', ('A' * 64), ('B' * 64))) {
    Assert-SwitchPhaseState -Component cpa -Phase 'rolling-back' -RecordedHash ('A' * 64) -ActiveHash $active `
        -OldHash ('A' * 64) -NewHash ('B' * 64) -PendingPath 'C:\fixture\backup' -Journal @{targetProcessId=123} -JournalPath 'fixture'
}
Assert-Throws {
    Assert-SwitchPhaseState -Component cpa -Phase 'rolling-back' -RecordedHash ('B' * 64) -ActiveHash ('A' * 64) `
        -OldHash ('A' * 64) -NewHash ('B' * 64) -PendingPath 'C:\fixture\backup' -Journal @{targetProcessId=123} -JournalPath 'fixture'
} 'A committed new version cannot silently roll back under an old transaction'
Assert-Throws {
    Assert-SwitchPhaseState -Component cpa -Phase 'rolling-back' -RecordedHash ('A' * 64) -ActiveHash ('C' * 64) `
        -OldHash ('A' * 64) -NewHash ('B' * 64) -PendingPath 'C:\fixture\backup' -Journal @{targetProcessId=123} -JournalPath 'fixture'
} 'Unknown active code still requires manual recovery'

& {
    $checkpoint = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-UpgradeCheckpoint' }, $true)
    . ([scriptblock]::Create($checkpoint.Extent.Text))
    $result=[ordered]@{success=$false;error='original-failure'}
    $resultPath='unused-fixture'; $operationMutex=[object]::new(); $instanceMarker=[object]::new()
    $suppressResultPersistence=$false; $script:checkpointWrites=0
    function Write-CpaStackJson { $script:checkpointWrites++ }
    Write-UpgradeCheckpoint -Phase 'restoring-cpa-runtime'
    Assert-Equal 1 $script:checkpointWrites 'Validated progress is persisted before restoration'
    $suppressResultPersistence=$true
    Write-UpgradeCheckpoint -Phase 'untrusted-artifact'
    Assert-Equal 1 $script:checkpointWrites 'Foreign recovery artifacts remain read-only'
    $suppressResultPersistence=$false; $operationMutex=$null
    Write-UpgradeCheckpoint -Phase 'no-lock'
    Assert-Equal 1 $script:checkpointWrites 'An unowned operation cannot overwrite progress'
    $operationMutex=[object]::new()
    function Write-CpaStackJson { throw [System.IO.IOException]::new('fixture-file-locked') }
    Write-UpgradeCheckpoint -Phase 'restoring-cpa-runtime'
    Assert-Equal 'CheckpointWriteFailed' $result.checkpointWarning 'Progress failure is explicit without preventing service recovery'
    Assert-Equal 'original-failure' $result.error 'Progress failure cannot replace the triggering error'
    Remove-Variable -Scope Script -Name checkpointWrites
}

& {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
    $temp=Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-manifest-prune-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $temp 'auth') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $temp 'payload.bin'),'runtime')
    [System.IO.File]::WriteAllText((Join-Path $temp 'auth\fixture.json'),'fixture')
    try {
        function Get-Item {
            [CmdletBinding()]
            param([string]$LiteralPath,[switch]$Force)
            if ($LiteralPath -match '\\auth(?:\\|$)') { throw 'Excluded auth tree was traversed.' }
            Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
        }
        $manifest=Get-CpaStackTreeManifest -Root $temp -ExcludeDirectoryNames @('auth')
        Assert-Equal 1 $manifest.entryCount 'Payload comparisons never walk excluded credentials'
    } finally {
        Remove-Item -LiteralPath (Join-Path $temp 'auth\fixture.json'),(Join-Path $temp 'payload.bin')
        Remove-Item -LiteralPath (Join-Path $temp 'auth')
        Remove-Item -LiteralPath $temp
    }
}
'Recovery phase tests passed.'
