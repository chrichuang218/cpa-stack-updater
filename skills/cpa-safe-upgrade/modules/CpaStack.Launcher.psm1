Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.StateInspection.psm1') -Force

function Invoke-CpaStackStartOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [switch]$NoBrowser
    )

    $inspection = Invoke-CpaStackStateInspection -Root $Root -HostAdapter $HostAdapter `
        -DefaultMessage 'Start preflight inspection failed.'
    if (-not $inspection.Success) {
        return New-CpaStackResult -Operation start -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error $inspection.Error `
            -Extensions $(if ($null -eq $inspection.State) { @{} } else { [ordered]@{ state = $inspection.State } })
    }
    $state = $inspection.State
    $pendingOperations = @(ConvertTo-CpaStackList -Value (Get-CpaStackValue -Object $state -Name 'PendingOperations'))
    if ($pendingOperations.Count -gt 0) {
        return New-CpaStackResult -Operation start -Success $false -Outcome RecoveryRequired -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'RecoveryRequired' -Message 'A pending transaction must be recovered before start.' -Phase 'preflight') `
            -Extensions ([ordered]@{ state = $state })
    }
    if (-not [bool](Get-CpaStackValue -Object $state -Name 'CanonicalEstablished' -Default $false)) {
        return New-CpaStackResult -Operation start -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'CanonicalStackRequired' -Message 'Start requires an established canonical stack.' -Phase 'preflight') `
            -Extensions ([ordered]@{ state = $state })
    }
    $configPath = Join-Path $Root 'config\stack.psd1'
    $arguments = @('-ConfigPath', $configPath)
    if ($NoBrowser) { $arguments += '-NoBrowser' }
    $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Start-CPA-Stack.ps1' -Arguments $arguments
    if ($null -eq $run.Json) {
        return New-CpaStackResult -Operation start -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (ConvertTo-CpaStackError -Run $run -DefaultCode 'StartFailed' `
                -DefaultMessage 'Start returned no JSON document.' -DefaultPhase 'start')
    }
    $success = $run.ExitCode -eq 0 -and [bool](Get-CpaStackValue -Object $run.Json -Name 'Success' -Default $false)
    $cpa = Get-CpaStackValue -Object $run.Json -Name 'Cpa'
    $manager = Get-CpaStackValue -Object $run.Json -Name 'Manager'
    $browser = [string](Get-CpaStackValue -Object $run.Json -Name 'Browser')
    $changed = $success -and (
        [string](Get-CpaStackValue -Object $cpa -Name 'Action') -eq 'Started' -or
        [string](Get-CpaStackValue -Object $manager -Name 'Action') -eq 'Started' -or
        $browser -eq 'Opened'
    )
    if (-not $success) {
        $innerError = Get-CpaStackValue -Object $run.Json -Name 'Error'
        $failureError = ConvertTo-CpaStackError -InputObject $innerError -Run $run -DefaultCode 'StartFailed' `
            -DefaultMessage 'Start failed.' -DefaultPhase 'start'
        Set-CpaStackValue -Object $run.Json -Name 'Error' -Value $failureError
        return New-CpaStackResult -Operation start -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error $failureError `
            -Extensions ([ordered]@{ start = $run.Json })
    }
    return New-CpaStackResult -Operation start -Success $true -Outcome $(if ($changed) { 'Changed' } else { 'NoChange' }) `
        -Changed $changed -Root $Root -Extensions ([ordered]@{ start = $run.Json })
}

Export-ModuleMember -Function Invoke-CpaStackStartOperation
