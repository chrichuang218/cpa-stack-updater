$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repo 'skills\cpa-safe-upgrade\modules'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-result-contract-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $temp 'managed root'
$secretSentinel = 'RESULT-CONTRACT-SECRET-7f41b9'

Import-Module (Join-Path $moduleRoot 'CpaStack.Inspection.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.UpgradeTransaction.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.MigrationTransaction.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.Recovery.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.Launcher.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.LanConfiguration.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.StateInspection.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.Result.psm1') -Force

function New-FakeRun {
    param(
        $Json,
        [int]$ExitCode = 0,
        [string[]]$Output = @(),
        [string]$Text = '',
        $ProtocolError = $null
    )

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Json = $Json
        Output = @($Output)
        Text = $Text
        ProtocolError = $ProtocolError
    }
}

function New-FakeHostAdapter {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Runs)

    $invoke = {
        param([string]$Name, [string[]]$Arguments)

        if (-not $Runs.Contains($Name)) {
            throw "Unexpected bundled script invocation: $Name"
        }
        $run = $Runs[$Name]
        if ($run -is [scriptblock]) {
            return & $run $Name $Arguments
        }
        return $run
    }.GetNewClosure()
    return [pscustomobject]@{ Invoke = $invoke }
}

function ConvertTo-ContractDocument {
    param([Parameter(Mandatory = $true)]$Value)

    return $Value | ConvertTo-Json -Depth 16 | ConvertFrom-Json
}

function Assert-ErrorShape {
    param(
        [Parameter(Mandatory = $true)]$ErrorObject,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $names = @($ErrorObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-Equal 'code,message,type,phase' ($names -join ',') $Message
}

function Assert-FailedResultError {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Phase,
        [int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $document = ConvertTo-ContractDocument -Value $Result
    Assert-False ([bool]$document.success) "$Message reports failure"
    Assert-ErrorShape -ErrorObject $document.error -Message "$Message uses the exact error contract"
    Assert-Equal $Code $document.error.code "$Message preserves the stable error code"
    Assert-Equal $Phase $document.error.phase "$Message identifies the failure phase"
    if ($PSBoundParameters.ContainsKey('ExitCode') -and $ExitCode -ne 0) {
        Assert-True ([string]$document.error.message -match ('(?i)\bExitCode\s*=\s*' + $ExitCode + '\b')) "$Message preserves the nonzero exit code"
    }
    Assert-False ([string]$document.error.message -match [regex]::Escape($secretSentinel)) "$Message does not expose captured secret output"
    return $document
}

function New-HealthyState {
    return [pscustomobject]@{
        SchemaVersion = 1
        OverallHealthy = $true
        CanonicalEstablished = $true
        MigrationRequired = $false
        LegacyCanonicalAdoptionRequired = $false
        InterruptedState = $false
        PendingOperations = @()
        Error = $null
    }
}

try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    Assert-Equal 'initialize' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @(
        'C:\fixture\state\initialize.pending.json',
        'C:\fixture\state\switch-manager.pending.json',
        'C:\fixture\rollback\pending-manager-0123456789abcdef0123456789abcdef'
    )).Kind 'Initialization recovery owns its switch journal and rollback slot'
    Assert-Equal 'upgrade' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @(
        'C:\fixture\state\upgrade.pending.json',
        'C:\fixture\state\switch-cpa.pending.json',
        'C:\fixture\rollback\pending-cpa-0123456789abcdef0123456789abcdef'
    )).Kind 'Upgrade recovery owns its switch journal and rollback slot'
    Assert-Equal 'upgrade' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @(
        'C:\fixture\state\switch-cpa.pending.json',
        'C:\fixture\rollback\pending-cpa-0123456789abcdef0123456789abcdef'
    )).Kind 'A surviving switch subtree routes to upgrade recovery'
    Assert-Equal 'lan' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @('C:\fixture\state\lan.pending.json')).Kind 'LAN journal has a dedicated recovery route'
    Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @(
        'C:\fixture\state\lan.pending.json',
        'C:\fixture\state\switch-cpa.pending.json'
    )).Kind 'Unrelated LAN and switch transactions remain ambiguous'
    Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @(
        'D:\foreign\state\upgrade.pending.json'
    )).Kind 'A journal basename outside the fixed state directory cannot select a recovery implementation'
    Assert-Equal 'ambiguous' (Get-CpaStackRecoveryPlan -Root 'C:\fixture' -PendingPaths @(
        'C:\fixture\state\initialize.pending.json',
        'D:\foreign\rollback\pending-manager-0123456789abcdef0123456789abcdef'
    )).Kind 'An initialization journal cannot claim a rollback artifact outside its fixed rollback directory'

    $createdError = ConvertTo-ContractDocument -Value (New-CpaStackError -Code 'CreatedFailure' -Message 'Created failure.' -Phase 'unit')
    Assert-ErrorShape -ErrorObject $createdError -Message 'New-CpaStackError always returns the exact contract'
    Assert-Equal 'CreatedFailure' $createdError.code 'New-CpaStackError preserves code'
    Assert-Equal 'Created failure.' $createdError.message 'New-CpaStackError preserves a safe message'

    $normalizedString = ConvertTo-ContractDocument -Value (ConvertTo-CpaStackError -InputObject 'Legacy string failure.' `
        -DefaultCode 'StringFailure' -DefaultMessage 'String operation failed.' -DefaultPhase 'unit' -ExitCode 17)
    Assert-ErrorShape -ErrorObject $normalizedString -Message 'String errors normalize to the exact contract'
    Assert-Equal 'StringFailure' $normalizedString.code 'String errors receive the caller default code'
    Assert-Equal 'Legacy string failure. ExitCode=17.' $normalizedString.message 'String errors retain a bounded summary and the exit code'

    $inspectionNoJsonAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json $null -ExitCode 31 `
            -Output @("apiKey=$secretSentinel", 'complete legacy output must not escape') `
            -Text "apiKey=$secretSentinel`r`ncomplete legacy output must not escape"
    })
    $inspectionNoJson = Invoke-CpaStackInspection -Root $root -HostAdapter $inspectionNoJsonAdapter
    [void](Assert-FailedResultError -Result $inspectionNoJson -Code 'InspectionFailed' -Phase 'inspection' -ExitCode 31 `
        -Message 'Inspection no-JSON failure')

    $inspectionStringBooleanAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = 'false'
            Error = $null
        }) -ExitCode 1
    })
    $inspectionStringBoolean = Invoke-CpaStackStateInspection -Root $root -HostAdapter $inspectionStringBooleanAdapter
    Assert-False ([bool]$inspectionStringBoolean.Success) 'Inspection rejects string values masquerading as booleans'
    Assert-Equal 'InspectionProtocolViolation' $inspectionStringBoolean.Error.code 'Inspection reports a protocol violation for a non-boolean health value'

    foreach ($inconsistentState in @(
        [pscustomobject]@{ Healthy = $true; ExitCode = 1 },
        [pscustomobject]@{ Healthy = $false; ExitCode = 0 }
    )) {
        $inspectionExitCodeAdapter = New-FakeHostAdapter -Runs ([ordered]@{
            'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
                SchemaVersion = 1
                OverallHealthy = [bool]$inconsistentState.Healthy
                Error = $null
            }) -ExitCode ([int]$inconsistentState.ExitCode)
        })
        $inspectionExitCode = Invoke-CpaStackStateInspection -Root $root -HostAdapter $inspectionExitCodeAdapter
        Assert-False ([bool]$inspectionExitCode.Success) 'Inspection rejects an exit code inconsistent with the health state'
        Assert-Equal 'InspectionProtocolViolation' $inspectionExitCode.Error.code 'Inspection reports a protocol violation for an inconsistent exit code'
    }

    $inspectionStringAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = $false
            CanonicalEstablished = $true
            PendingOperations = @()
            Error = 'Legacy inspection failure.'
        }) -ExitCode 1
    })
    $inspectionString = ConvertTo-ContractDocument -Value (Invoke-CpaStackInspection -Root $root -HostAdapter $inspectionStringAdapter)
    Assert-False ([bool]$inspectionString.success) 'A state Error makes inspection fail rather than reporting a successful blocked state'
    Assert-ErrorShape -ErrorObject $inspectionString.error -Message 'Inspection normalizes a legacy string Error'
    Assert-Equal 'InspectionFailed' $inspectionString.error.code 'Inspection assigns a stable code to a legacy string Error'
    Assert-Equal 'inspection' $inspectionString.error.phase 'Inspection assigns its phase to a legacy string Error'

    $inspectionRecoverAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = $false
            CanonicalEstablished = $false
            MigrationRequired = $true
            LegacyCanonicalAdoptionRequired = $true
            PendingOperations = @((Join-Path $root 'state\upgrade.pending.json'))
            Error = $null
        }) -ExitCode 1
    })
    $inspectionRecover = ConvertTo-ContractDocument -Value (Invoke-CpaStackInspection -Root $root -HostAdapter $inspectionRecoverAdapter)
    Assert-Equal 'recover' $inspectionRecover.requiredOperation 'Inspection prioritizes explicit recovery when a transaction is pending'

    $inspectionMigrateAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = $false
            CanonicalEstablished = $false
            MigrationRequired = $false
            LegacyCanonicalAdoptionRequired = $false
            PendingOperations = @()
            Error = $null
        }) -ExitCode 1
    })
    $inspectionMigrate = ConvertTo-ContractDocument -Value (Invoke-CpaStackInspection -Root $root -HostAdapter $inspectionMigrateAdapter)
    Assert-Equal 'migrate' $inspectionMigrate.requiredOperation 'Inspection requires migration when the canonical stack is not established'

    $inspectionUnhealthyAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = $false
            CanonicalEstablished = $true
            MigrationRequired = $false
            LegacyCanonicalAdoptionRequired = $false
            PendingOperations = @()
            Error = $null
        }) -ExitCode 1
    })
    $inspectionUnhealthy = ConvertTo-ContractDocument -Value (Invoke-CpaStackInspection -Root $root -HostAdapter $inspectionUnhealthyAdapter)
    Assert-True ($null -eq $inspectionUnhealthy.requiredOperation) 'Canonical unhealthy state does not invent an unsupported repair command'

    $upgradeAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json (New-HealthyState)
        'Invoke-CpaStackUpgrade.ps1' = New-FakeRun -Json ([pscustomobject]@{
            success = $false
            rolledBack = $false
            error = 'Legacy upgrade failure.'
        }) -ExitCode 23
    })
    $upgrade = Invoke-CpaStackUpgradeTransaction -Root $root -HostAdapter $upgradeAdapter
    $upgradeDocument = Assert-FailedResultError -Result $upgrade -Code 'UpgradeFailed' -Phase 'upgrade' -ExitCode 23 `
        -Message 'Upgrade string failure'
    Assert-Equal 'Legacy upgrade failure. ExitCode=23.' $upgradeDocument.error.message 'Upgrade retains the safe legacy string summary'

    $startAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json (New-HealthyState)
        'Start-CPA-Stack.ps1' = New-FakeRun -Json ([pscustomobject]@{
            Success = $false
            Error = [pscustomobject]@{
                Type = 'Legacy.StartFailure'
                Message = 'Legacy launcher failure.'
            }
        }) -ExitCode 9
    })
    $start = Invoke-CpaStackStartOperation -Root $root -HostAdapter $startAdapter -NoBrowser
    $startDocument = Assert-FailedResultError -Result $start -Code 'StartFailed' -Phase 'start' -ExitCode 9 `
        -Message 'Launcher PascalCase object failure'
    Assert-Equal 'Legacy.StartFailure' $startDocument.error.type 'Launcher preserves a safe PascalCase error type'
    Assert-Equal 'Legacy launcher failure. ExitCode=9.' $startDocument.error.message 'Launcher reads a PascalCase Message'

    $migrationFailureAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json (New-HealthyState)
        'Initialize-CpaStack.ps1' = New-FakeRun -Json ([pscustomobject]@{
            success = $false
            rolledBack = $false
            error = [pscustomobject]@{
                code = 'LegacyMigrationFailure'
                message = 'Legacy migration transaction failed.'
                type = 'Legacy.MigrationException'
                phase = 'switch'
            }
        }) -ExitCode 7
    })
    $migrationFailure = Invoke-CpaStackMigrationTransaction -Root $root -HostAdapter $migrationFailureAdapter
    $migrationFailureDocument = Assert-FailedResultError -Result $migrationFailure -Code 'LegacyMigrationFailure' -Phase 'switch' -ExitCode 7 `
        -Message 'Migration structured object failure'
    Assert-Equal 'Legacy.MigrationException' $migrationFailureDocument.error.type 'Migration preserves a safe structured error type'

    $migrationExecutionAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = {
            throw [System.IO.IOException]::new("apiKey=$secretSentinel must not escape")
        }
    })
    $migrationExecution = Invoke-CpaStackMigrationTransaction -Root $root -HostAdapter $migrationExecutionAdapter
    $migrationExecutionDocument = Assert-FailedResultError -Result $migrationExecution -Code 'MigrationFailed' -Phase 'migration' `
        -Message 'Migration execution exception'
    Assert-Equal 'System.IO.IOException' $migrationExecutionDocument.error.type 'Migration execution failures retain the exception type'

    $migrationInspectionFailureAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = $false
            Error = [pscustomobject]@{ Code = 'StatusFailed'; Message = 'Synthetic state failure.' }
        }) -ExitCode 1
    })
    $migrationInspectionFailure = Invoke-CpaStackMigrationTransaction -Root $root -HostAdapter $migrationInspectionFailureAdapter
    [void](Assert-FailedResultError -Result $migrationInspectionFailure -Code 'StatusFailed' -Phase 'inspection' `
        -Message 'Migration state failure blocks before any mutating script')

    $invalidRequestPath = Join-Path $temp 'invalid-request.json'
    [System.IO.File]::WriteAllText($invalidRequestPath, '{ invalid json', [System.Text.UTF8Encoding]::new($false))
    $invalidMigration = Invoke-CpaStackMigrationTransaction -Root $root -HostAdapter $migrationFailureAdapter -RequestPath $invalidRequestPath
    $invalidMigrationDocument = Assert-FailedResultError -Result $invalidMigration -Code 'InvalidMigrationRequest' -Phase 'request' `
        -Message 'Invalid migration request'
    Assert-True ([string]$invalidMigrationDocument.error.type -match 'Exception$') 'Invalid migration request retains its exception type'

    $migrationNoChangeAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json (New-HealthyState)
        'Initialize-CpaStack.ps1' = New-FakeRun -Json ([pscustomobject]@{
            success = $true
            changed = $false
            recoveredInterruptedState = $false
        })
    })
    $migrationNoChange = ConvertTo-ContractDocument -Value (Invoke-CpaStackMigrationTransaction -Root $root -HostAdapter $migrationNoChangeAdapter)
    Assert-True ([bool]$migrationNoChange.success) 'Successful idempotent migration succeeds'
    Assert-Equal 'NoChange' $migrationNoChange.outcome 'Explicit migration changed=false maps to NoChange'
    Assert-False ([bool]$migrationNoChange.changed) 'Explicit migration changed=false remains false'

    $migrationLegacySuccessAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json (New-HealthyState)
        'Initialize-CpaStack.ps1' = New-FakeRun -Json ([pscustomobject]@{
            success = $true
            recoveredInterruptedState = $false
        })
    })
    $migrationLegacySuccess = ConvertTo-ContractDocument -Value (Invoke-CpaStackMigrationTransaction -Root $root -HostAdapter $migrationLegacySuccessAdapter)
    Assert-Equal 'Changed' $migrationLegacySuccess.outcome 'Legacy successful migration without changed conservatively defaults to Changed'
    Assert-True ([bool]$migrationLegacySuccess.changed) 'Legacy successful migration without changed conservatively defaults to true'

    $recoveryInspectionAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json $null -ExitCode 32 `
            -Output @("secret=$secretSentinel", 'untrusted complete output') `
            -Text "secret=$secretSentinel`r`nuntrusted complete output"
    })
    $recoveryInspection = Invoke-CpaStackRecovery -Root $root -HostAdapter $recoveryInspectionAdapter
    [void](Assert-FailedResultError -Result $recoveryInspection -Code 'InspectionFailed' -Phase 'inspection' -ExitCode 32 `
        -Message 'Recovery failed inspection')

    $recoveryAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Get-CpaStackState.ps1' = New-FakeRun -Json ([pscustomobject]@{
            SchemaVersion = 1
            OverallHealthy = $false
            PendingOperations = @((Join-Path $root 'state\upgrade.pending.json'))
            InterruptedState = $true
            Error = $null
        }) -ExitCode 1
        'Invoke-CpaStackUpgrade.ps1' = New-FakeRun -Json ([pscustomobject]@{
            success = $false
            error = 'Legacy recovery failure.'
        }) -ExitCode 12
    })
    $recovery = Invoke-CpaStackRecovery -Root $root -HostAdapter $recoveryAdapter
    [void](Assert-FailedResultError -Result $recovery -Code 'RecoveryFailed' -Phase 'recovery' -ExitCode 12 `
        -Message 'Recovery string failure')

    $lanProtocolAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Set-CpaStackLan.ps1' = New-FakeRun -Json $null -ExitCode 41 `
            -Output @("Bearer $secretSentinel", 'two JSON documents') `
            -Text "Bearer $secretSentinel`r`ntwo JSON documents" `
            -ProtocolError ([pscustomobject]@{
                code = 'BundledProtocolViolation'
                message = 'Bundled script did not return exactly one JSON object.'
            })
    })
    $lanProtocol = Invoke-CpaStackLanOperation -Root $root -HostAdapter $lanProtocolAdapter -Action Set -Mode Lan
    $lanProtocolDocument = Assert-FailedResultError -Result $lanProtocol -Code 'BundledProtocolViolation' -Phase 'lan' -ExitCode 41 `
        -Message 'LAN bundled protocol failure'
    Assert-True ([string]$lanProtocolDocument.error.message -match '^Bundled script did not return exactly one JSON object\.') 'ProtocolError message takes precedence over captured output'

    $lanSensitiveErrorAdapter = New-FakeHostAdapter -Runs ([ordered]@{
        'Set-CpaStackLan.ps1' = New-FakeRun -Json ([pscustomobject]@{
            success = $false
            changed = $false
            rolledBack = $false
            error = "apiKey=$secretSentinel"
        }) -ExitCode 43
    })
    $lanSensitiveError = Invoke-CpaStackLanOperation -Root $root -HostAdapter $lanSensitiveErrorAdapter -Action Set -Mode Lan
    $lanSensitiveJson = $lanSensitiveError | ConvertTo-Json -Depth 16 -Compress
    Assert-False ($lanSensitiveJson -match [regex]::Escape($secretSentinel)) 'Normalized failure evidence does not retain the raw secret-bearing error'
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-TestPathWithRetry -Path $temp
    }
}

'Result contract tests passed.'
