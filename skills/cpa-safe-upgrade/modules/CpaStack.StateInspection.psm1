Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force

function Invoke-CpaStackStateInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [string]$DefaultMessage = 'Stack inspection failed.'
    )

    $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Get-CpaStackState.ps1' -Arguments @('-ControlRoot', $Root)
    if ($null -eq $run.Json) {
        return [pscustomobject]@{
            Success = $false
            Run = $run
            State = $null
            Error = ConvertTo-CpaStackError -Run $run -DefaultCode 'InspectionFailed' `
                -DefaultMessage $DefaultMessage -DefaultPhase 'inspection'
        }
    }

    $state = $run.Json
    $stateError = Get-CpaStackValue -Object $state -Name 'Error'
    $overallHealthyProperty = $state.PSObject.Properties['OverallHealthy']
    $schemaVersion = [int](Get-CpaStackValue -Object $state -Name 'SchemaVersion' -Default 0)
    if ($null -ne $stateError) {
        $error = ConvertTo-CpaStackError -InputObject $stateError -Run $run -DefaultCode 'InspectionFailed' `
            -DefaultMessage $DefaultMessage -DefaultPhase 'inspection'
        Set-CpaStackValue -Object $state -Name 'Error' -Value $error
        return [pscustomobject]@{ Success = $false; Run = $run; State = $state; Error = $error }
    }
    $overallHealthyIsBoolean = $null -ne $overallHealthyProperty -and $overallHealthyProperty.Value -is [bool]
    $expectedExitCode = if ($overallHealthyIsBoolean -and [bool]$overallHealthyProperty.Value) { 0 } else { 1 }
    if ($schemaVersion -ne 1 -or -not $overallHealthyIsBoolean -or [int]$run.ExitCode -ne $expectedExitCode) {
        $error = ConvertTo-CpaStackError -Run $run -DefaultCode 'InspectionProtocolViolation' `
            -DefaultMessage 'Stack inspection returned an invalid state document or exit code.' -DefaultPhase 'inspection'
        return [pscustomobject]@{ Success = $false; Run = $run; State = $state; Error = $error }
    }
    return [pscustomobject]@{ Success = $true; Run = $run; State = $state; Error = $null }
}

Export-ModuleMember -Function Invoke-CpaStackStateInspection
