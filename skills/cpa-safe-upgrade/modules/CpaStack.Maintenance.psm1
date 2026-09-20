#requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force

function Invoke-CpaStackMaintenanceOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [Parameter(Mandatory = $true)][ValidateSet('CleanupDerived')][string]$Action
    )

    $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Invoke-CpaStackMaintenance.ps1' `
        -Arguments @('-ControlRoot', $Root, '-Action', $Action)
    if ($null -eq $run.Json) {
        return New-CpaStackResult -Operation maintenance -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'MaintenanceProtocolViolation' `
                -Message 'Maintenance returned no structured result.' -Phase 'maintenance')
    }

    $document = $run.Json
    $formatVersion = [int](Get-CpaStackValue -Object $document -Name 'format_version' -Default 0)
    $operation = [string](Get-CpaStackValue -Object $document -Name 'operation')
    $successProperty = $document.PSObject.Properties['success']
    $success = $null -ne $successProperty -and $successProperty.Value -is [bool] -and [bool]$successProperty.Value
    $expectedExitCode = if ($success) { 0 } else { 1 }
    if ($formatVersion -ne 1 -or $operation -cne 'cleanup-derived' -or
        $null -eq $successProperty -or $successProperty.Value -isnot [bool] -or
        [int]$run.ExitCode -ne $expectedExitCode) {
        return New-CpaStackResult -Operation maintenance -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'MaintenanceProtocolViolation' `
                -Message 'Maintenance returned an invalid result contract or exit code.' -Phase 'maintenance')
    }

    $changed = [bool](Get-CpaStackValue -Object $document -Name 'changed' -Default $false)
    $rolledBack = [bool](Get-CpaStackValue -Object $document -Name 'rolledBack' -Default $false)
    $recovered = [bool](Get-CpaStackValue -Object $document -Name 'recovered' -Default $false)
    $warnings = @(ConvertTo-CpaStackList -Value (Get-CpaStackValue -Object $document -Name 'warnings'))
    if (-not $success) {
        $innerError = Get-CpaStackValue -Object $document -Name 'error'
        $error = ConvertTo-CpaStackError -InputObject $innerError -Run $run `
            -DefaultCode 'MaintenanceFailed' -DefaultMessage 'Offline Manager maintenance failed.' -DefaultPhase 'maintenance'
        Set-CpaStackValue -Object $document -Name 'error' -Value $error
        return New-CpaStackResult -Operation maintenance -Success $false `
            -Outcome $(if ($rolledBack) { 'RolledBack' } else { 'Blocked' }) `
            -Changed $changed -Root $Root -RolledBack $rolledBack -Recovered $recovered -Warnings $warnings -Error $error `
            -Extensions ([ordered]@{ maintenance = $document })
    }

    return New-CpaStackResult -Operation maintenance -Success $true `
        -Outcome $(if ($changed -or $recovered) { 'Changed' } else { 'NoChange' }) `
        -Changed ($changed -or $recovered) -Root $Root -Recovered $recovered -Warnings $warnings `
        -Extensions ([ordered]@{ maintenance = $document })
}

Export-ModuleMember -Function Invoke-CpaStackMaintenanceOperation
