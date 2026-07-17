Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CpaStack.Result.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.BundledHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CpaStack.StateInspection.psm1') -Force

function Get-RequiredRequestValue {
    param($Object, [string]$Name, [string]$Context)

    $value = Get-CpaStackValue -Object $Object -Name $Name
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "$Context is missing required field '$Name'."
    }
    return [string]$value
}

function Assert-OnlyRequestFields {
    param($Object, [string[]]$Allowed, [string]$Context)

    foreach ($property in @($Object.PSObject.Properties)) {
        if ($Allowed -cnotcontains [string]$property.Name) {
            throw "$Context contains unsupported field '$($property.Name)'."
        }
    }
}

function Read-CpaStackMigrationRequest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Migration request file does not exist: $full"
    }
    $text = [System.IO.File]::ReadAllText($full, [System.Text.UTF8Encoding]::new($false, $true))
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 1048576) {
        throw 'Migration request must be a non-empty JSON document no larger than 1 MiB.'
    }
    $request = $text | ConvertFrom-Json
    if ($null -eq $request -or $request -is [array]) { throw 'Migration request must be a JSON object.' }
    Assert-OnlyRequestFields -Object $request -Allowed @('schemaVersion', 'sourceMode', 'source', 'secretsInputPath', 'ports') -Context 'Migration request'
    if ([int](Get-CpaStackValue -Object $request -Name 'schemaVersion' -Default 0) -ne 1) {
        throw 'Migration request schemaVersion must be 1.'
    }
    $mode = Get-RequiredRequestValue -Object $request -Name 'sourceMode' -Context 'Migration request'
    if ($mode -notin @('Auto', 'Explicit')) { throw "Migration sourceMode is unsupported: $mode" }
    if ($mode -eq 'Explicit') {
        $source = Get-CpaStackValue -Object $request -Name 'source'
        if ($null -eq $source -or $source -is [array]) { throw 'Explicit migration requires a source object.' }
        Assert-OnlyRequestFields -Object $source -Allowed @('cpaRuntime', 'cpaConfig', 'managerRuntime', 'managerData', 'legacyStartScript') -Context 'Migration source'
        foreach ($name in @('cpaRuntime', 'cpaConfig', 'managerRuntime', 'managerData')) {
            [void](Get-RequiredRequestValue -Object $source -Name $name -Context 'Migration source')
        }
        $secretsPath = [string](Get-CpaStackValue -Object $request -Name 'secretsInputPath')
        $legacyStart = [string](Get-CpaStackValue -Object $source -Name 'legacyStartScript')
        if ([string]::IsNullOrWhiteSpace($secretsPath) -and [string]::IsNullOrWhiteSpace($legacyStart)) {
            throw 'Explicit migration requires secretsInputPath or source.legacyStartScript.'
        }
    }
    $ports = Get-CpaStackValue -Object $request -Name 'ports'
    if ($ports) {
        Assert-OnlyRequestFields -Object $ports -Allowed @('cpa', 'manager') -Context 'Migration ports'
        foreach ($name in @('cpa', 'manager')) {
            $value = [int](Get-CpaStackValue -Object $ports -Name $name -Default 0)
            if ($value -lt 1 -or $value -gt 65535) { throw "Migration port '$name' is invalid." }
        }
        if ([int]$ports.cpa -eq [int]$ports.manager) { throw 'CPA and Manager formal ports must differ.' }
    }
    return $request
}

function Invoke-CpaStackMigrationTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [string]$RequestPath
    )

    try {
        $request = if ([string]::IsNullOrWhiteSpace($RequestPath)) {
            [pscustomobject]@{ schemaVersion = 1; sourceMode = 'Auto'; source = $null; secretsInputPath = $null; ports = $null }
        } else {
            Read-CpaStackMigrationRequest -Path $RequestPath
        }
    } catch {
        return New-CpaStackResult -Operation migrate -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (ConvertTo-CpaStackError -InputObject $_ -DefaultCode 'InvalidMigrationRequest' `
                -DefaultMessage 'Migration request validation failed.' -DefaultPhase 'request')
    }

    try {
        $inspection = Invoke-CpaStackStateInspection -Root $Root -HostAdapter $HostAdapter `
            -DefaultMessage 'Migration preflight inspection failed.'
        if (-not $inspection.Success) {
            return New-CpaStackResult -Operation migrate -Success $false -Outcome Blocked -Changed $false -Root $Root `
                -Error $inspection.Error `
                -Extensions $(if ($null -eq $inspection.State) { @{} } else { [ordered]@{ state = $inspection.State } })
        }
        $state = $inspection.State
        $pendingOperations = @(ConvertTo-CpaStackList -Value (Get-CpaStackValue -Object $state -Name 'PendingOperations'))
        if ($pendingOperations.Count -gt 0) {
            return New-CpaStackResult -Operation migrate -Success $false -Outcome RecoveryRequired -Changed $false -Root $Root `
                -Error (New-CpaStackError -Code 'RecoveryRequired' -Message 'A pending transaction must be recovered explicitly before migration.' -Phase 'preflight') `
                -Extensions ([ordered]@{ state = $state })
        }
        $adoptionRequired = $null -ne $state -and [bool](Get-CpaStackValue -Object $state -Name 'LegacyCanonicalAdoptionRequired' -Default $false)
        if ($adoptionRequired -and [string]$request.sourceMode -eq 'Auto') {
            $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Adopt-CpaStackLegacyCanonical.ps1' -Arguments @('-ControlRoot', $Root)
        } else {
            $arguments = @('-ControlRoot', $Root)
            if ([string]$request.sourceMode -eq 'Explicit') {
                $source = $request.source
                foreach ($pair in @(
                    [pscustomobject]@{ Name = 'SourceCpaRuntime'; Value = [string]$source.cpaRuntime },
                    [pscustomobject]@{ Name = 'SourceCpaConfig'; Value = [string]$source.cpaConfig },
                    [pscustomobject]@{ Name = 'SourceManagerRuntime'; Value = [string]$source.managerRuntime },
                    [pscustomobject]@{ Name = 'SourceManagerData'; Value = [string]$source.managerData },
                    [pscustomobject]@{ Name = 'LegacyStartScript'; Value = [string](Get-CpaStackValue -Object $source -Name 'legacyStartScript') },
                    [pscustomobject]@{ Name = 'SecretsInputPath'; Value = [string]$request.secretsInputPath }
                )) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$pair.Value)) {
                        $arguments += ('-' + [string]$pair.Name)
                        $arguments += [string]$pair.Value
                    }
                }
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$request.secretsInputPath)) {
                $arguments += @('-SecretsInputPath', [string]$request.secretsInputPath)
            }
            $requestPorts = Get-CpaStackValue -Object $request -Name 'ports'
            if ($requestPorts) {
                $arguments += @('-CpaPort', [string][int]$requestPorts.cpa)
                $arguments += @('-ManagerPort', [string][int]$requestPorts.manager)
            }
            $run = Invoke-CpaStackBundled -HostAdapter $HostAdapter -Name 'Initialize-CpaStack.ps1' -Arguments $arguments
        }
        if ($null -eq $run.Json) {
            return New-CpaStackResult -Operation migrate -Success $false -Outcome Blocked -Changed $false -Root $Root `
                -Error (ConvertTo-CpaStackError -Run $run -DefaultCode 'MigrationFailed' `
                    -DefaultMessage 'Migration returned no JSON document.' -DefaultPhase 'migration')
        }
        $success = $run.ExitCode -eq 0 -and [bool](Get-CpaStackValue -Object $run.Json -Name 'success' -Default $false)
        $rolledBack = [bool](Get-CpaStackValue -Object $run.Json -Name 'rolledBack' -Default $false)
        if ($success) {
            $changedValue = Get-CpaStackValue -Object $run.Json -Name 'changed'
            $changed = if ($null -eq $changedValue) { $true } else { [bool]$changedValue }
            return New-CpaStackResult -Operation migrate -Success $true -Outcome $(if ($changed) { 'Changed' } else { 'NoChange' }) -Changed $changed -Root $Root `
                -Recovered ([bool](Get-CpaStackValue -Object $run.Json -Name 'recoveredInterruptedState' -Default $false)) `
                -Extensions ([ordered]@{ migration = $run.Json })
        }
        $innerError = Get-CpaStackValue -Object $run.Json -Name 'error'
        $failureError = ConvertTo-CpaStackError -InputObject $innerError -Run $run -DefaultCode 'MigrationFailed' `
            -DefaultMessage 'Migration failed.' -DefaultPhase 'migration'
        Set-CpaStackValue -Object $run.Json -Name 'error' -Value $failureError
        return New-CpaStackResult -Operation migrate -Success $false -Outcome $(if ($rolledBack) { 'RolledBack' } else { 'Blocked' }) `
            -Changed $false -Root $Root -RolledBack $rolledBack `
            -Error $failureError `
            -Extensions ([ordered]@{ migration = $run.Json })
    } catch {
        return New-CpaStackResult -Operation migrate -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (ConvertTo-CpaStackError -InputObject $_ -DefaultCode 'MigrationFailed' `
                -DefaultMessage 'Migration execution failed.' -DefaultPhase 'migration')
    }
}

Export-ModuleMember -Function Read-CpaStackMigrationRequest, Invoke-CpaStackMigrationTransaction
