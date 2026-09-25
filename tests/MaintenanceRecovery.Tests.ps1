#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'skills\cpa-safe-upgrade'
Import-Module (Join-Path $skill 'modules\CpaStack.Recovery.psm1') -Force

$root = 'C:\fixture'
$journalPath = Join-Path $root 'state\maintenance.pending.json'
$backupPath = Join-Path $root ('rollback\pending-maintenance-' + ('1' * 32))
$pending = @($journalPath, ($journalPath + '.previous'), $backupPath)
Assert-Equal 'maintenance' (Get-CpaStackRecoveryPlan -Root $root -PendingPaths $pending).Kind 'Interrupted maintenance reaches its own recovery executor'
Assert-Equal 'maintenance' (Get-CpaStackRecoveryPlan -Root $root -PendingPaths @($journalPath)).Kind 'Commit interrupted after backup retention remains recoverable'
foreach ($extra in @('state\upgrade.pending.json', 'state\initialize.pending.json', 'state\switch-cpa.pending.json', 'state\upgrade.pending.json.previous', ('rollback\pending-cpa-' + ('2' * 32)))) {
    Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root $root -PendingPaths @($pending + (Join-Path $root $extra))).Kind 'Unrelated runtime transactions remain blocked'
}
Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root $root -PendingPaths @($backupPath)).Kind 'An orphan maintenance backup cannot trigger runtime recovery'
Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root $root -PendingPaths @($journalPath + '.previous')).Kind 'A previous record alone is not enough to recover'
Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root $root -PendingPaths @($pending + (Join-Path $root ('rollback\pending-maintenance-' + ('2' * 32))))).Kind 'Multiple pending maintenance backups remain blocked'

# Exercise the dispatcher used by public upgrade/recover, including its post-recovery gate.
foreach ($case in @('success', 'failed', 'no-json', 'still-pending', 'unhealthy')) { & {
    $calls = @{ Inspections = 0; Recovery = 0 }
    $pendingPaths = $pending
    $fixtureRoot = $root
    $scenario = $case
    $invoke = {
        param($Name, $Arguments)
        $exitCode = 0
        $document = $null
        switch ($Name) {
            'Get-CpaStackState.ps1' {
                $calls.Inspections++
                $blocked = $calls.Inspections -eq 1 -or $scenario -in @('still-pending', 'unhealthy')
                $exitCode = if ($blocked) { 1 } else { 0 }
                $document = [pscustomobject]@{
                    SchemaVersion = 1; OverallHealthy = (-not $blocked); InterruptedState = $blocked
                    PendingOperations = $(if ($calls.Inspections -eq 1 -or $scenario -eq 'still-pending') { $pendingPaths } else { @() })
                    Error = $null
                }
            }
            'Invoke-CpaStackMaintenance.ps1' {
                $calls.Recovery++
                if (($Arguments -join ',') -cne ('-ControlRoot,' + $fixtureRoot + ',-Action,CleanupDerived,-RecoverOnly')) {
                    throw 'Recovery must invoke only the maintenance recovery path.'
                }
                if ($scenario -in @('failed', 'no-json')) {
                    $exitCode = 1
                    if ($scenario -eq 'failed') { $document = [pscustomobject]@{ success = $false; error = @{ code = 'MaintenanceRollbackFailed'; message = 'Invalid backup'; phase = 'rollback' } } }
                } else { $document = [pscustomobject]@{ success = $true; rolledBack = $false } }
            }
            default { throw "Unexpected recovery script: $Name" }
        }
        [pscustomobject]@{ ExitCode = $exitCode; Json = $document; ProtocolError = $null; Output = @(); Text = '' }
    }.GetNewClosure()
    $recovery = Invoke-CpaStackRecovery -Root $root -HostAdapter ([pscustomobject]@{ Invoke = $invoke })
    Assert-Equal 1 $calls.Recovery "One recovery attempt only: $($recovery | ConvertTo-Json -Depth 4 -Compress)"
    Assert-Equal ($case -eq 'success') $recovery.success 'Only verified recovery allows upgrade to continue'
    if ($case -eq 'success') {
        Assert-True $recovery.recovered 'Public result reports completed recovery'
        Assert-Equal 'maintenance' $recovery.recoveryKind 'Public result identifies the recovered transaction'
    } elseif ($case -eq 'failed') {
        Assert-Equal 'MaintenanceRollbackFailed' $recovery.error.code 'Backup rejection remains a hard failure'
    } elseif ($case -in @('still-pending', 'unhealthy')) {
        Assert-Equal 'RecoveryVerificationFailed' $recovery.error.code 'Pending or unhealthy recovery remains blocked'
    }
} }

# Run the real transaction body and recovery function with IO replaced, as in UpgradeFlow.Tests.
$path = Join-Path $skill 'scripts\Invoke-CpaStackMaintenance.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
$flow = [scriptblock]::Create($main.Extent.Text)
$initializer = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$result' }, $false)
foreach ($case in @('validated', 'source-stopped', 'none', 'previous-mismatch', 'backup-mismatch', 'backup-invalid', 'data-invalid', 'runtime-changed', 'restart-failed')) { & {
    foreach ($name in @('Recover-InterruptedMaintenance', 'New-MaintenanceError')) {
        $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    . ([scriptblock]::Create($initializer.Extent.Text))
    $ControlRoot = $root
    $Action = 'CleanupDerived'
    $RecoverOnly = $true
    $events = [Collections.Generic.List[string]]::new()
    $fixture = @{ Pending = ($case -ne 'none') }
    $journal = [pscustomobject]@{
        schemaVersion = 1; operation = 'cleanup-derived'; operationId = ('1' * 32)
        instanceId = 'fixture'; canonicalRoot = $root
        phase = $(if ($case -eq 'source-stopped') { 'source-stopped' } else { 'validated' })
    }
    $previous = $journal | ConvertTo-Json | ConvertFrom-Json
    if ($case -eq 'previous-mismatch') { $previous.operationId = '2' * 32 }
    function Enter-CpaStackOperationLock { $events.Add('lock'); [object]::new() }
    function Exit-CpaStackOperationLock { $events.Add('unlock') }
    function Assert-CpaStackPath { }
    function Get-MaintenanceInstanceId { 'fixture' }
    function Test-Path { param($LiteralPath)
        if ($LiteralPath -match 'pending') { return $fixture.Pending }
        return $true
    }
    function Get-ChildItem { param($LiteralPath)
        $paths = if ($LiteralPath.EndsWith('state')) { @($journalPath, $journalPreviousPath) } else {
            @($(if ($case -eq 'backup-mismatch') { $backupPath.Replace(('1' * 32), ('2' * 32)) } else { $backupPath }))
        }
        foreach ($p in $paths) { [pscustomobject]@{ FullName = $p } }
    }
    function Read-CpaStackJson { param($Path) if ($Path.EndsWith('.previous')) { $previous } else { $journal } }
    function Write-CpaStackJson { $events.Add('persist') }
    function Read-MaintenanceBackup {
        $events.Add('backup-verified')
        if ($case -eq 'backup-invalid') { throw 'Invalid backup' }
        [pscustomobject]@{
            BaselinePath = 'fixture-baseline'
            Manifest = @{ executable = 'C:\fixture\manager.exe'; executableSha256 = 'trusted'; database = 'C:\fixture\usage.sqlite'; dataKeySha256 = 'trusted'; managerPort = 12345; bindAddress = '127.0.0.1' }
        }
    }
    function Get-CpaStackFileHash { if ($case -eq 'runtime-changed') { 'changed' } else { 'trusted' } }
    function Test-MaintenanceDatabase { param($Database, $BaselinePath)
        Assert-Equal 'C:\fixture\usage.sqlite' $Database 'Revalidate the current database, including newer writes'
        Assert-Equal 'fixture-baseline' $BaselinePath 'Keep the authoritative-data baseline check'
        $events.Add('validate-current')
        if ($case -eq 'data-invalid') { throw 'Authoritative data validation failed' }
    }
    function Restore-MaintenanceDatabase { $events.Add('restore') }
    function Start-MaintenanceStack { $events.Add('restart'); if ($case -eq 'restart-failed') { throw 'Restart failed' } }
    function Complete-MaintenanceCommit { $events.Add('commit'); $fixture.Pending = $false }
    function Get-MaintenanceState { throw 'Recovery-only must not start fresh cleanup' }
    & $flow
    Assert-Equal 'unlock' $events[$events.Count - 1] 'Recovery always releases the operation lock'
    if ($case -in @('validated', 'source-stopped', 'none')) {
        Assert-True $result.success "Recovery-only succeeds for $case without entering fresh cleanup"
        Assert-Equal ($case -ne 'none') $result.recovered 'Recovery flag reflects existing work'
        Assert-Equal ($case -ne 'none') $result.changed 'Change flag reflects existing work'
        Assert-Equal ($case -eq 'source-stopped') $events.Contains('restore') 'Validated/current data is never replaced by the old backup'
        Assert-Equal ($case -eq 'source-stopped') $result.rolledBack 'Only early-phase database restoration reports rollback'
        $events.Clear()
        . ([scriptblock]::Create($initializer.Extent.Text))
        & $flow
        Assert-True $result.success 'Completed recovery can be invoked again'
        Assert-False $result.changed 'Repeated recovery is a no-op'
        Assert-False $events.Contains('restart') 'Repeated recovery does not restart healthy services'
        Assert-False $events.Contains('commit') 'Repeated recovery does not recreate a transaction'
    } else {
        Assert-False $result.success "$case cannot report recovery success"
        Assert-Equal 'MaintenanceRollbackFailed' $result.error.code 'Keep the stable failure code'
        Assert-True $fixture.Pending 'Failed recovery keeps pending evidence'
        Assert-False $events.Contains('restore') 'Invalid or already validated transactions are never blindly restored'
        Assert-False $events.Contains('commit') 'Failed recovery never clears pending state'
        if ($case -ne 'restart-failed') { Assert-False $events.Contains('restart') 'Validation fails before service operations' }
        if ($case -eq 'restart-failed') {
            $case = 'validated'
            . ([scriptblock]::Create($initializer.Extent.Text))
            & $flow
            Assert-True $result.success 'Recovery can resume after restart failure'
            Assert-False $events.Contains('restore') 'Restart retry preserves current database'
        }
    }
} }

'Maintenance recovery checks passed.'
