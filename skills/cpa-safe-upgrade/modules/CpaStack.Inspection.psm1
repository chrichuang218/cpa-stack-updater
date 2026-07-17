Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.ManagedShortcut.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.StateInspection.psm1') -Force

function Invoke-CpaStackInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [string]$Operation = 'status',
        [object[]]$Warnings = @()
    )

    $inspection = Invoke-CpaStackStateInspection -Root $Root -HostAdapter $HostAdapter `
        -DefaultMessage 'Stack inspection returned no valid state document.'
    if (-not $inspection.Success) {
        return New-CpaStackResult -Operation $Operation -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Warnings $Warnings -Error $inspection.Error `
            -Extensions $(if ($null -eq $inspection.State) { @{} } else { [ordered]@{ state = $inspection.State } })
    }
    $run = $inspection.Run
    $healthy = [bool](Get-CpaStackValue -Object $run.Json -Name 'OverallHealthy' -Default $false)
    $pendingOperations = @(ConvertTo-CpaStackList -Value (Get-CpaStackValue -Object $run.Json -Name 'PendingOperations'))
    $canonical = [bool](Get-CpaStackValue -Object $run.Json -Name 'CanonicalEstablished' -Default $false)
    $migration = [bool](Get-CpaStackValue -Object $run.Json -Name 'MigrationRequired' -Default $false)
    $adoption = [bool](Get-CpaStackValue -Object $run.Json -Name 'LegacyCanonicalAdoptionRequired' -Default $false)
    $requiredOperation = if ($pendingOperations.Count -gt 0) {
        'recover'
    } elseif (-not $canonical -or $migration -or $adoption) {
        'migrate'
    } else {
        $null
    }
    $shortcutState = [pscustomobject]@{ operation = 'shortcut'; success = $true; status = 'Absent'; changed = $false; reason = 'NoManagedShortcut' }
    $shortcutPath = $null
    $ownershipPath = Join-Path $Root 'state\managed-shortcut.json'
    if (Test-Path -LiteralPath $ownershipPath -PathType Leaf) {
        try {
            $ownership = [System.IO.File]::ReadAllText($ownershipPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
            $shortcutPath = [string](Get-CpaStackValue -Object $ownership -Name 'path')
        } catch {
            $shortcutState = [pscustomobject]@{ operation = 'shortcut'; success = $true; status = 'Conflict'; changed = $false; reason = 'OwnershipUnreadable' }
        }
    } else {
        $startup = Get-CpaStackValue -Object $run.Json -Name 'Startup'
        $legacyShortcut = Get-CpaStackValue -Object $startup -Name 'Shortcut'
        $shortcutPath = [string](Get-CpaStackValue -Object $legacyShortcut -Name 'Path')
    }
    if (-not [string]::IsNullOrWhiteSpace($shortcutPath)) {
        try {
            $shortcutState = Invoke-CpaStackManagedShortcut -Action Check -Root $Root -ShortcutPath $shortcutPath
        } catch {
            $shortcutState = [pscustomobject]@{ operation = 'shortcut'; success = $true; status = 'Conflict'; changed = $false; reason = $_.Exception.Message }
        }
    }
    $security = Get-CpaStackValue -Object $run.Json -Name 'Security'
    $cpaLoopback = [bool](Get-CpaStackValue -Object $security -Name 'CpaLoopbackOnly' -Default $false)
    $managerLoopback = [bool](Get-CpaStackValue -Object $security -Name 'ManagerLoopbackOnly' -Default $false)
    $lanState = [pscustomobject]@{
        mode = if ($cpaLoopback -and $managerLoopback) { 'Loopback' } elseif ($null -ne $security) { 'Lan' } else { 'Unknown' }
        cpaLoopbackOnly = $cpaLoopback
        managerLoopbackOnly = $managerLoopback
    }
    return New-CpaStackResult -Operation $Operation -Success $true -Outcome $(if ($healthy) { 'Healthy' } else { 'Blocked' }) `
        -Changed $false -Root $Root -Warnings $Warnings `
        -Extensions ([ordered]@{ requiredOperation = $requiredOperation; state = $run.Json; shortcut = $shortcutState; lan = $lanState })
}

Export-ModuleMember -Function Invoke-CpaStackInspection
