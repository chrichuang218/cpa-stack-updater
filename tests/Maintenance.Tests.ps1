$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$modules = Join-Path $repo 'skills\cpa-safe-upgrade\modules'
Import-Module (Join-Path $modules 'CpaStack.Maintenance.psm1') -Force

function New-MaintenanceHost {
    param($Document, [int]$ExitCode = 0, $ProtocolError = $null)

    $invoke = {
        param([string]$Name, [string[]]$Arguments)
        return [pscustomobject]@{
            ExitCode = $ExitCode
            Json = $Document
            ProtocolError = $ProtocolError
            Output = @()
            Text = ''
        }
    }.GetNewClosure()
    return [pscustomobject]@{ Invoke = $invoke }
}

$successDocument = [pscustomobject]@{
    format_version = 1
    operation = 'cleanup-derived'
    success = $true
    changed = $true
    rolledBack = $false
    recovered = $false
    managerStopped = $true
    managerRestarted = $true
    databaseVerified = $true
    error = $null
}
$success = Invoke-CpaStackMaintenanceOperation -Root 'C:\fixture' -HostAdapter (New-MaintenanceHost -Document $successDocument) -Action CleanupDerived
Assert-True ([bool]$success.success) 'Successful cleanup is reported through the v2 envelope'
Assert-Equal 'maintenance' $success.operation 'Maintenance identifies the public operation'
Assert-Equal 'Changed' $success.outcome 'Successful cleanup changes maintenance state'
Assert-True ([bool]$success.maintenance.databaseVerified) 'Maintenance preserves verification evidence'

$failureDocument = [pscustomobject]@{
    format_version = 1
    operation = 'cleanup-derived'
    success = $false
    changed = $false
    rolledBack = $true
    recovered = $false
    error = [pscustomobject]@{
        code = 'CleanupDerivedFailed'
        message = 'Offline maintenance failed and the database was restored.'
        phase = 'cleanup'
    }
}
$failure = Invoke-CpaStackMaintenanceOperation -Root 'C:\fixture' -HostAdapter (New-MaintenanceHost -Document $failureDocument -ExitCode 1) -Action CleanupDerived
Assert-False ([bool]$failure.success) 'Failed cleanup cannot masquerade as success'
Assert-Equal 'RolledBack' $failure.outcome 'A restored cleanup failure is reported as rolled back'
Assert-Equal 'CleanupDerivedFailed' $failure.error.code 'Maintenance preserves the stable inner error code'

$protocolFailure = Invoke-CpaStackMaintenanceOperation -Root 'C:\fixture' -HostAdapter (
    New-MaintenanceHost -Document $null -ExitCode 1 -ProtocolError ([pscustomobject]@{ code = 'NoJsonDocument' })
) -Action CleanupDerived
Assert-False ([bool]$protocolFailure.success) 'Missing JSON is an explicit maintenance failure'
Assert-Equal 'MaintenanceProtocolViolation' $protocolFailure.error.code 'Maintenance protocol failures have a stable code'

'Maintenance tests passed.'
