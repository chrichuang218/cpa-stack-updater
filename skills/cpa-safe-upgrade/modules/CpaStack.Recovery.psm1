Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.StateInspection.psm1') -Force

function Get-CpaStackRecoveryPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$PendingPaths
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $stateRoot = [System.IO.Path]::GetFullPath((Join-Path $rootFull 'state')).TrimEnd('\')
    $rollbackRoot = [System.IO.Path]::GetFullPath((Join-Path $rootFull 'rollback')).TrimEnd('\')
    $artifacts = @($PendingPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object {
        [System.IO.Path]::GetFullPath([string]$_).TrimEnd('\')
    } | Sort-Object -Unique)
    if ($artifacts.Count -eq 0) { return [pscustomobject]@{ Kind = $null; Artifacts = @() } }

    $journalKinds = New-Object System.Collections.Generic.List[string]
    $unknown = New-Object System.Collections.Generic.List[string]
    $hasSwitchArtifact = $false
    $hasRollbackArtifact = $false
    $hasInitializePrevious = $false
    $hasUpgradePrevious = $false
    $hasLanPrevious = $false
    $hasSwitchPrevious = $false
    foreach ($path in $artifacts) {
        $name = [System.IO.Path]::GetFileName($path)
        $parent = [System.IO.Path]::GetDirectoryName($path).TrimEnd('\')
        switch -Regex ($name) {
            '^adopt\.pending\.json$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $journalKinds.Add('adopt') }
                continue
            }
            '^initialize\.pending\.json$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $journalKinds.Add('initialize') }
                continue
            }
            '^initialize\.pending\.json\.previous$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $hasInitializePrevious = $true }
                continue
            }
            '^upgrade\.pending\.json$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $journalKinds.Add('upgrade') }
                continue
            }
            '^upgrade\.pending\.json\.previous$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $hasUpgradePrevious = $true }
                continue
            }
            '^lan\.pending\.json$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $journalKinds.Add('lan') }
                continue
            }
            '^lan\.pending\.json\.previous$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $hasLanPrevious = $true }
                continue
            }
            '^switch-(cpa|manager)\.pending\.json$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $hasSwitchArtifact = $true }
                continue
            }
            '^switch-(cpa|manager)\.pending\.json\.previous$' {
                if ($parent -ine $stateRoot) { $unknown.Add($path) } else { $hasSwitchPrevious = $true }
                continue
            }
            '^pending-(cpa|manager)-[0-9a-fA-F]{32}$' {
                if ($parent -ine $rollbackRoot) { $unknown.Add($path) } else { $hasRollbackArtifact = $true }
                continue
            }
            default { $unknown.Add($path) }
        }
    }
    if ($unknown.Count -gt 0) {
        return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @($unknown) }
    }

    $primaryKinds = @($journalKinds | Select-Object -Unique)
    if ($primaryKinds.Count -gt 1) {
        return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @() }
    }
    if ($primaryKinds.Count -eq 1) {
        $kind = [string]$primaryKinds[0]
        if ($hasInitializePrevious -and $kind -ne 'initialize') {
            return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @() }
        }
        if ($hasUpgradePrevious -and $kind -ne 'upgrade' -or
            $hasLanPrevious -and $kind -ne 'lan' -or
            $hasSwitchPrevious -and $kind -ne 'upgrade') {
            return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @() }
        }
        if ($kind -eq 'initialize') {
            return [pscustomobject]@{ Kind = 'initialize'; Artifacts = $artifacts; Unknown = @() }
        }
        if ($kind -eq 'upgrade') {
            return [pscustomobject]@{ Kind = 'upgrade'; Artifacts = $artifacts; Unknown = @() }
        }
        if ($hasSwitchArtifact -or $hasRollbackArtifact -or $hasSwitchPrevious) {
            return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @() }
        }
        return [pscustomobject]@{ Kind = $kind; Artifacts = $artifacts; Unknown = @() }
    }
    if (($hasUpgradePrevious -or $hasSwitchArtifact -or $hasSwitchPrevious -or $hasRollbackArtifact) -and -not $hasLanPrevious -and -not $hasInitializePrevious) {
        return [pscustomobject]@{ Kind = 'upgrade'; Artifacts = $artifacts; Unknown = @() }
    }
    if ($hasLanPrevious -and -not $hasUpgradePrevious -and -not $hasSwitchPrevious -and -not $hasInitializePrevious) {
        return [pscustomobject]@{ Kind = 'lan'; Artifacts = $artifacts; Unknown = @() }
    }
    if ($hasInitializePrevious) {
        return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @() }
    }
    return [pscustomobject]@{ Kind = 'ambiguous'; Artifacts = $artifacts; Unknown = @() }
}

function Get-CpaStackPendingArtifacts {
    param([string]$Root, $State)

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(ConvertTo-CpaStackList -Value (Get-CpaStackValue -Object $State -Name 'PendingOperations'))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $paths.Add([string]$path) }
    }
    $stateRoot = Join-Path $Root 'state'
    foreach ($name in @(
        'adopt.pending.json',
        'initialize.pending.json',
        'initialize.pending.json.previous',
        'upgrade.pending.json',
        'upgrade.pending.json.previous',
        'switch-cpa.pending.json',
        'switch-manager.pending.json',
        'switch-cpa.pending.json.previous',
        'switch-manager.pending.json.previous',
        'lan.pending.json',
        'lan.pending.json.previous'
    )) {
        $path = Join-Path $stateRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $paths.Add($path) }
    }
    $rollbackRoot = Join-Path $Root 'rollback'
    if (Test-Path -LiteralPath $rollbackRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -Force -LiteralPath $rollbackRoot -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue)) {
            $paths.Add($directory.FullName)
        }
    }
    return @($paths | ForEach-Object { [System.IO.Path]::GetFullPath([string]$_).TrimEnd('\') } | Sort-Object -Unique)
}

function Invoke-CpaStackRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter
    )

    $inspection = Invoke-CpaStackStateInspection -Root $Root -HostAdapter $HostAdapter `
        -DefaultMessage 'Recovery inspection failed.'
    if (-not $inspection.Success) {
        return New-CpaStackResult -Operation recover -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error $inspection.Error `
            -Extensions $(if ($null -eq $inspection.State) { @{} } else { [ordered]@{ state = $inspection.State } })
    }
    $state = $inspection.State
    $pendingPaths = @(Get-CpaStackPendingArtifacts -Root $Root -State $state)
    $plan = Get-CpaStackRecoveryPlan -Root $Root -PendingPaths $pendingPaths
    if ($null -eq $plan.Kind) {
        return New-CpaStackResult -Operation recover -Success $true -Outcome NoChange -Changed $false -Root $Root -Recovered $false `
            -Extensions ([ordered]@{ state = $state })
    }
    if ($plan.Kind -eq 'ambiguous') {
        return New-CpaStackResult -Operation recover -Success $false -Outcome ManualRecoveryRequired -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code 'AmbiguousPendingTransactions' -Message 'Pending artifacts do not form one supported transaction tree.' -Phase 'discovery') `
            -Extensions ([ordered]@{ state = $state; pendingArtifacts = @($plan.Artifacts) })
    }

    $script = $null
    $arguments = @('-ControlRoot', $Root)
    switch ($plan.Kind) {
        'adopt' { $script = 'Adopt-CpaStackLegacyCanonical.ps1'; $arguments += '-RecoverOnly' }
        'initialize' { $script = 'Initialize-CpaStack.ps1'; $arguments += '-RecoverOnly' }
        'upgrade' { $script = 'Invoke-CpaStackUpgrade.ps1'; $arguments += '-RecoverOnly' }
        'lan' { $script = 'Set-CpaStackLan.ps1'; $arguments += '-RecoverOnly' }
        default { throw "Unexpected recovery kind: $($plan.Kind)" }
    }
    $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name $script -Arguments $arguments
    if ($null -eq $run.Json -or $run.ExitCode -ne 0 -or -not [bool](Get-CpaStackValue -Object $run.Json -Name 'success' -Default $false)) {
        $innerError = if ($null -eq $run.Json) { $null } else { Get-CpaStackValue -Object $run.Json -Name 'error' }
        $failureError = ConvertTo-CpaStackError -InputObject $innerError -Run $run -DefaultCode 'RecoveryFailed' `
            -DefaultMessage 'Recovery failed.' -DefaultPhase 'recovery'
        if ($null -ne $run.Json) { Set-CpaStackValue -Object $run.Json -Name 'error' -Value $failureError }
        return New-CpaStackResult -Operation recover -Success $false -Outcome ManualRecoveryRequired -Changed $false -Root $Root `
            -Error $failureError `
            -Extensions ([ordered]@{ recovery = $run.Json; recoveryKind = $plan.Kind; pendingArtifacts = @($plan.Artifacts) })
    }

    $verifiedInspection = Invoke-CpaStackStateInspection -Root $Root -HostAdapter $HostAdapter `
        -DefaultMessage 'Recovery verification inspection failed.'
    $verifiedState = $verifiedInspection.State
    $remaining = @()
    if ($null -ne $verifiedState) { $remaining = @(Get-CpaStackPendingArtifacts -Root $Root -State $verifiedState) }
    if (-not $verifiedInspection.Success -or @($remaining).Count -gt 0 -or
        [bool](Get-CpaStackValue -Object $verifiedState -Name 'InterruptedState' -Default $true) -or
        -not [bool](Get-CpaStackValue -Object $verifiedState -Name 'OverallHealthy' -Default $false)) {
        $failureError = if (-not $verifiedInspection.Success) {
            $verifiedInspection.Error
        } else {
            New-CpaStackError -Code 'RecoveryVerificationFailed' `
                -Message 'Recovery returned but the stack is unhealthy or still has pending artifacts.' -Phase 'verification'
        }
        return New-CpaStackResult -Operation recover -Success $false -Outcome ManualRecoveryRequired -Changed $true -Root $Root -Recovered $false `
            -Error $failureError `
            -Extensions ([ordered]@{ recovery = $run.Json; recoveryKind = $plan.Kind; state = $verifiedState; pendingArtifacts = @($remaining) })
    }
    $recoveryRolledBack = [bool](Get-CpaStackValue -Object $run.Json -Name 'rolledBack' -Default $false)
    return New-CpaStackResult -Operation recover -Success $true -Outcome Changed -Changed $true -Root $Root -Recovered $true -RolledBack $recoveryRolledBack `
        -Extensions ([ordered]@{ recovery = $run.Json; recoveryKind = $plan.Kind; state = $verifiedState })
}

Export-ModuleMember -Function Get-CpaStackRecoveryPlan, Invoke-CpaStackRecovery
