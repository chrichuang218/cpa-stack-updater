Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force

function Invoke-CpaStackLanOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [Parameter(Mandatory = $true)][ValidateSet('Set')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Loopback', 'Lan')][string]$Mode
    )

    $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Set-CpaStackLan.ps1' -Arguments @(
        '-ControlRoot', $Root,
        '-Mode', $Mode
    )
    if ($null -eq $run.Json) {
        return New-CpaStackResult -Operation lan -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (ConvertTo-CpaStackError -Run $run -DefaultCode 'LanConfigurationFailed' `
                -DefaultMessage 'LAN configuration returned no JSON document.' -DefaultPhase 'lan')
    }
    $success = $run.ExitCode -eq 0 -and [bool](Get-CpaStackValue -Object $run.Json -Name 'success' -Default $false)
    $changed = [bool](Get-CpaStackValue -Object $run.Json -Name 'changed' -Default $false)
    $rolledBack = [bool](Get-CpaStackValue -Object $run.Json -Name 'rolledBack' -Default $false)
    if ($success) {
        return New-CpaStackResult -Operation lan -Success $true -Outcome $(if ($changed) { 'Changed' } else { 'NoChange' }) `
            -Changed $changed -Root $Root -Extensions ([ordered]@{ lan = $run.Json })
    }
    $innerError = Get-CpaStackValue -Object $run.Json -Name 'error'
    $failureError = ConvertTo-CpaStackError -InputObject $innerError -Run $run -DefaultCode 'LanConfigurationFailed' `
        -DefaultMessage 'LAN configuration failed.' -DefaultPhase 'lan'
    Set-CpaStackValue -Object $run.Json -Name 'error' -Value $failureError
    return New-CpaStackResult -Operation lan -Success $false -Outcome $(if ($rolledBack) { 'RolledBack' } else { 'Blocked' }) `
        -Changed $false -Root $Root -RolledBack $rolledBack `
        -Error $failureError `
        -Extensions ([ordered]@{ lan = $run.Json })
}

Export-ModuleMember -Function Invoke-CpaStackLanOperation
