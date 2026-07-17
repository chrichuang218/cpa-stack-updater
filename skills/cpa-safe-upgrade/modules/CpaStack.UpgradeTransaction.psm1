Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.StateInspection.psm1') -Force

function Invoke-CpaStackUpgradeTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [switch]$AllowUnknownVersionReplacement
    )

    $inspection = Invoke-CpaStackStateInspection -Root $Root -HostAdapter $HostAdapter `
        -DefaultMessage 'Upgrade preflight inspection failed.'
    if (-not $inspection.Success) {
        return New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error $inspection.Error `
            -Extensions $(if ($null -eq $inspection.State) { @{} } else { [ordered]@{ state = $inspection.State } })
    }
    $state = $inspection.State
    $pendingOperations = @(ConvertTo-CpaStackList -Value (Get-CpaStackValue -Object $state -Name 'PendingOperations'))
    if ($pendingOperations.Count -gt 0) {
        return New-CpaStackResult -Operation upgrade -Success $false -Outcome RecoveryRequired -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'RecoveryRequired' -Message 'A pending transaction must be recovered explicitly before upgrade.' -Phase 'preflight') `
            -Extensions ([ordered]@{ state = $state })
    }
    $canonical = [bool](Get-CpaStackValue -Object $state -Name 'CanonicalEstablished' -Default $false)
    $migration = [bool](Get-CpaStackValue -Object $state -Name 'MigrationRequired' -Default $false)
    $adoption = [bool](Get-CpaStackValue -Object $state -Name 'LegacyCanonicalAdoptionRequired' -Default $false)
    if (-not $canonical -or $migration -or $adoption) {
        return New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'MigrationRequired' -Message 'The canonical stack must be established by an explicit migrate operation before upgrade.' -Phase 'preflight') `
            -Extensions ([ordered]@{ state = $state })
    }
    if (-not [bool](Get-CpaStackValue -Object $state -Name 'OverallHealthy' -Default $false)) {
        return New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'StackUnhealthy' -Message 'The canonical stack is not healthy enough to upgrade.' -Phase 'preflight') `
            -Extensions ([ordered]@{ state = $state })
    }

    $arguments = @('-ControlRoot', $Root)
    if ($AllowUnknownVersionReplacement) { $arguments += '-AllowUnknownVersionReplacement' }
    $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Invoke-CpaStackUpgrade.ps1' -Arguments $arguments
    if ($null -eq $run.Json) {
        return New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (ConvertTo-CpaStackError -Run $run -DefaultCode 'UpgradeFailed' `
                -DefaultMessage 'Upgrade returned no JSON document.' -DefaultPhase 'upgrade')
    }

    $success = ($run.ExitCode -eq 0 -and [bool](Get-CpaStackValue -Object $run.Json -Name 'success' -Default $false))
    $cpa = Get-CpaStackValue -Object $run.Json -Name 'cpa'
    $manager = Get-CpaStackValue -Object $run.Json -Name 'manager'
    $cpaChanged = $null -ne $cpa -and -not [bool](Get-CpaStackValue -Object $cpa -Name 'skipped' -Default $false)
    $managerChanged = $null -ne $manager -and -not [bool](Get-CpaStackValue -Object $manager -Name 'skipped' -Default $false)
    $changed = [bool]($cpaChanged -or $managerChanged)
    $rolledBack = [bool](Get-CpaStackValue -Object $cpa -Name 'rolledBack' -Default $false) -or
        [bool](Get-CpaStackValue -Object $manager -Name 'rolledBack' -Default $false)
    $innerError = Get-CpaStackValue -Object $run.Json -Name 'error'
    if ($success) {
        $outcome = if ($changed) { 'Changed' } else { 'NoChange' }
        return New-CpaStackResult -Operation upgrade -Success $true -Outcome $outcome -Changed $changed -Root $Root `
            -Extensions ([ordered]@{ upgrade = $run.Json })
    }
    if ($rolledBack) {
        $failureError = ConvertTo-CpaStackError -InputObject $innerError -Run $run -DefaultCode 'FormalSwitchFailedRolledBack' `
            -DefaultMessage 'Upgrade failed and the previous runtime was restored.' -DefaultPhase 'upgrade'
        Set-CpaStackValue -Object $run.Json -Name 'error' -Value $failureError
        return New-CpaStackResult -Operation upgrade -Success $false -Outcome RolledBack -Changed $false -Root $Root -RolledBack $true `
            -Error $failureError `
            -Extensions ([ordered]@{ upgrade = $run.Json })
    }
    $failureError = ConvertTo-CpaStackError -InputObject $innerError -Run $run -DefaultCode 'UpgradeFailed' `
        -DefaultMessage 'Upgrade failed.' -DefaultPhase 'upgrade'
    Set-CpaStackValue -Object $run.Json -Name 'error' -Value $failureError
    return New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $Root `
        -Error $failureError `
        -Extensions ([ordered]@{ upgrade = $run.Json })
}

Export-ModuleMember -Function Invoke-CpaStackUpgradeTransaction
