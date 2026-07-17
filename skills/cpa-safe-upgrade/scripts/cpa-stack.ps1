#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'migrate', 'recover', 'upgrade', 'start', 'shortcut', 'lan')]
    [string]$Command = 'status',

    [Alias('ControlRoot')]
    [string]$Root,

    [string]$RequestPath,
    [ValidateSet('Check', 'Ensure', 'Set')]
    [string]$Action,
    [ValidateSet('Loopback', 'Lan')]
    [string]$Mode,
    [string]$ShortcutPath,
    [switch]$NoBrowser,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CpaStack.Common.ps1')
$moduleRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
Import-Module (Join-Path $moduleRoot 'CpaStack.Inspection.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.UpgradeTransaction.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.MigrationTransaction.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.Recovery.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.Launcher.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.LanConfiguration.psm1') -Force
Import-Module (Join-Path $moduleRoot 'CpaStack.ManagedShortcut.psm1') -Force -Global
Import-Module (Join-Path $moduleRoot 'CpaStack.Result.psm1') -Force -Global
Import-Module (Join-Path $moduleRoot 'CpaStack.BundledHost.psm1') -Force -Global
Import-Module (Join-Path $moduleRoot 'CpaStack.SelfUpdate.psm1') -Force

$resolvedRoot = $null
$updaterVersion = Get-CpaStackUpdaterVersion

function Write-CommandResult {
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $Value['updaterVersion'] = $updaterVersion
    } elseif ($null -eq $Value.PSObject.Properties['updaterVersion']) {
        $Value | Add-Member -NotePropertyName updaterVersion -NotePropertyValue $updaterVersion
    }
    if ($Json) {
        $Value | ConvertTo-Json -Depth 16 -Compress
    } else {
        $Value | ConvertTo-Json -Depth 16
    }
}

function Get-CpaStackDefaultDesktopShortcutPath {
    $shortcutName = 'CPA ' + (-join @(
        [char]0x672C, [char]0x5730, [char]0x542F, [char]0x52A8
    )) + '.lnk'
    return Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName
}

function Get-CpaStackLegacyDesktopShortcutPath {
    $shortcutName = 'CPA ' + (-join @(
        [char]0x672C, [char]0x5730, [char]0x542F, [char]0x52A8,
        [char]0xFF08, [char]0x65B0, [char]0x7248, [char]0xFF09
    )) + '.lnk'
    return Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName
}

function Invoke-CpaStackDesktopShortcutOperation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Ensure')][string]$ShortcutAction,
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-CpaStackDefaultDesktopShortcutPath
    }
    $bundledIcon = Join-Path (Split-Path -Parent $moduleRoot) 'assets\cpa-frontend.ico'
    $legacyPath = Get-CpaStackLegacyDesktopShortcutPath
    $ownershipPath = Join-Path $Root 'state\managed-shortcut.json'
    $relocatedOwnershipPath = Join-Path $Root ('state\managed-shortcut.previous-name.' + [guid]::NewGuid().ToString('N') + '.json')
    $relocatingManagedShortcut = $false
    $ensureSucceeded = $false
    try {
        if ($ShortcutAction -eq 'Ensure' -and
            [string]::Equals([System.IO.Path]::GetFullPath($Path), [System.IO.Path]::GetFullPath((Get-CpaStackDefaultDesktopShortcutPath)), [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $ownershipPath -PathType Leaf) -and
            (Test-Path -LiteralPath $legacyPath -PathType Leaf)) {
            $legacyStatus = Invoke-CpaStackManagedShortcut -Action Check -Root $Root -ShortcutPath $legacyPath
            if ([string]$legacyStatus.status -eq 'Matching') {
                [System.IO.File]::Move($ownershipPath, $relocatedOwnershipPath)
                $relocatingManagedShortcut = $true
            }
        }

        $shortcutInner = Invoke-CpaStackManagedShortcut -Action $ShortcutAction -Root $Root -ShortcutPath $Path `
            -AdoptExisting:($ShortcutAction -eq 'Ensure') `
            -LegacyIconPath $(if (Test-Path -LiteralPath $bundledIcon -PathType Leaf) { $bundledIcon } else { '' })
        $ensureSucceeded = $true
        $warnings = @()
        if ($relocatingManagedShortcut) {
            try { Remove-Item -LiteralPath $legacyPath -Force -ErrorAction Stop } catch { $warnings += 'The old desktop shortcut name could not be removed after the new shortcut was created.' }
            Remove-Item -LiteralPath $relocatedOwnershipPath -Force -ErrorAction SilentlyContinue
            $shortcutInner | Add-Member -NotePropertyName renamedFrom -NotePropertyValue $legacyPath
        }
        return New-CpaStackResult -Operation shortcut -Success $true -Outcome $(if ([bool]$shortcutInner.changed) { 'Changed' } else { 'NoChange' }) `
            -Changed ([bool]$shortcutInner.changed) -Root $Root -Warnings $warnings -Extensions ([ordered]@{ shortcut = $shortcutInner })
    } catch {
        if ($relocatingManagedShortcut -and -not $ensureSucceeded -and (Test-Path -LiteralPath $relocatedOwnershipPath -PathType Leaf)) {
            if (Test-Path -LiteralPath $ownershipPath) { Remove-Item -LiteralPath $ownershipPath -Force -ErrorAction SilentlyContinue }
            [System.IO.File]::Move($relocatedOwnershipPath, $ownershipPath)
        }
        $shortcutCode = if ($_.Exception.Message -match '(?i)adoptable|conflict|unknown') { 'ShortcutOwnershipConflict' } else { 'ShortcutOperationFailed' }
        return New-CpaStackResult -Operation shortcut -Success $false -Outcome Blocked -Changed $false -Root $Root `
            -Error (New-CpaStackError -Code $shortcutCode -Message $_.Exception.Message -Type $_.Exception.GetType().FullName)
    }
}

function Add-AutomaticUpgradeStep {
    param(
        [Parameter(Mandatory = $true)]$Steps,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)]$Result
    )

    $error = Get-CpaStackValue -Object $Result -Name 'error'
    $Steps.Add([ordered]@{
        operation = $Operation
        success = [bool](Get-CpaStackValue -Object $Result -Name 'success' -Default $false)
        outcome = [string](Get-CpaStackValue -Object $Result -Name 'outcome' -Default 'Blocked')
        changed = [bool](Get-CpaStackValue -Object $Result -Name 'changed' -Default $false)
        rolledBack = [bool](Get-CpaStackValue -Object $Result -Name 'rolledBack' -Default $false)
        recovered = [bool](Get-CpaStackValue -Object $Result -Name 'recovered' -Default $false)
        errorCode = [string](Get-CpaStackValue -Object $error -Name 'code')
    })
}

function Get-CpaStackUpdaterReexecEvidence {
    $guardName = 'CPA_STACK_UPDATER_REEXEC'
    $fromName = 'CPA_STACK_UPDATER_FROM_VERSION'
    $toName = 'CPA_STACK_UPDATER_TO_VERSION'
    $guard = [string][Environment]::GetEnvironmentVariable($guardName, 'Process')
    if ([string]::IsNullOrWhiteSpace($guard)) { return $null }
    $from = [string][Environment]::GetEnvironmentVariable($fromName, 'Process')
    $to = [string][Environment]::GetEnvironmentVariable($toName, 'Process')
    foreach ($name in @($guardName, $fromName, $toName)) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    if ($guard -cne '1' -or [string]::IsNullOrWhiteSpace($from) -or $to -cne $updaterVersion) {
        throw 'Updater re-execution evidence does not match the installed updater version.'
    }
    return [pscustomobject]@{
        success = $true
        changed = $true
        currentVersion = $from
        latestVersion = $to
        availableVersion = $to
        installedCliPath = Join-Path $PSScriptRoot 'cpa-stack.ps1'
        error = $null
    }
}

function New-CpaStackUpdaterStep {
    param([Parameter(Mandatory = $true)]$Evidence)

    $error = Get-CpaStackValue -Object $Evidence -Name 'error'
    return [ordered]@{
        operation = 'updater'
        success = [bool](Get-CpaStackValue -Object $Evidence -Name 'success' -Default $false)
        outcome = if ([bool](Get-CpaStackValue -Object $Evidence -Name 'success' -Default $false)) {
            if ([bool](Get-CpaStackValue -Object $Evidence -Name 'changed' -Default $false)) { 'Changed' } else { 'NoChange' }
        } else { 'Blocked' }
        changed = [bool](Get-CpaStackValue -Object $Evidence -Name 'changed' -Default $false)
        rolledBack = $false
        recovered = $false
        errorCode = [string](Get-CpaStackValue -Object $error -Name 'code')
    }
}

function New-CpaStackUpdaterFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Evidence
    )

    $step = New-CpaStackUpdaterStep -Evidence $Evidence
    $changed = [bool](Get-CpaStackValue -Object $Evidence -Name 'changed' -Default $false)
    return New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $changed -Root $Root `
        -Error (Get-CpaStackValue -Object $Evidence -Name 'error') `
        -Extensions ([ordered]@{
            updater = [ordered]@{
                before = [string](Get-CpaStackValue -Object $Evidence -Name 'currentVersion')
                after = [string](Get-CpaStackValue -Object $Evidence -Name 'latestVersion')
                available = [string](Get-CpaStackValue -Object $Evidence -Name 'availableVersion')
                changed = $changed
            }
            automation = [ordered]@{ failedStep = 'updater'; steps = @($step) }
        })
}

function Invoke-CpaStackUpgradeReexec {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$RequestPath,
        [Parameter(Mandatory = $true)][string]$FromVersion,
        [Parameter(Mandatory = $true)][string]$ToVersion
    )

    $engine = [string](Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf) -or
        [System.IO.Path]::GetFileName($engine) -notin @('powershell.exe', 'pwsh.exe')) {
        throw 'Current PowerShell host cannot be used for updater re-execution.'
    }
    $cli = Join-Path $PSScriptRoot 'cpa-stack.ps1'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
        throw 'Updated CPA stack CLI is missing after updater installation.'
    }
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $cli, 'upgrade', '-Root', $Root)
    if (-not [string]::IsNullOrWhiteSpace($RequestPath)) { $arguments += @('-RequestPath', $RequestPath) }
    if ($Json) { $arguments += '-Json' }
    [Environment]::SetEnvironmentVariable('CPA_STACK_UPDATER_REEXEC', '1', 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_UPDATER_FROM_VERSION', $FromVersion, 'Process')
    [Environment]::SetEnvironmentVariable('CPA_STACK_UPDATER_TO_VERSION', $ToVersion, 'Process')
    & $engine @arguments
    $childExitCode = if ($null -eq $LASTEXITCODE) { if ($?) { 0 } else { 1 } } else { [int]$LASTEXITCODE }
    exit $childExitCode
}

function Complete-AutomaticUpgradeResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Steps,
        $UpdaterEvidence
    )

    $changed = [bool](Get-CpaStackValue -Object $Result -Name 'changed' -Default $false)
    $recovered = [bool](Get-CpaStackValue -Object $Result -Name 'recovered' -Default $false)
    foreach ($step in $Steps) {
        $changed = $changed -or [bool]$step.changed
        $recovered = $recovered -or [bool]$step.recovered
    }
    Set-CpaStackValue -Object $Result -Name 'changed' -Value $changed
    Set-CpaStackValue -Object $Result -Name 'recovered' -Value $recovered
    if ([bool](Get-CpaStackValue -Object $Result -Name 'success' -Default $false)) {
        Set-CpaStackValue -Object $Result -Name 'outcome' -Value $(if ($changed) { 'Changed' } else { 'NoChange' })
    }
    Set-CpaStackValue -Object $Result -Name 'automation' -Value ([ordered]@{ steps = @($Steps) })
    if ($null -ne $UpdaterEvidence) {
        Set-CpaStackValue -Object $Result -Name 'updater' -Value ([ordered]@{
            before = [string](Get-CpaStackValue -Object $UpdaterEvidence -Name 'currentVersion')
            after = [string](Get-CpaStackValue -Object $UpdaterEvidence -Name 'latestVersion')
            available = [string](Get-CpaStackValue -Object $UpdaterEvidence -Name 'availableVersion')
            changed = [bool](Get-CpaStackValue -Object $UpdaterEvidence -Name 'changed' -Default $false)
        })
    }
    return $Result
}

function New-AutomaticUpgradeStepFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FailedStep,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Steps,
        $UpdaterEvidence
    )

    $outcome = [string](Get-CpaStackValue -Object $Result -Name 'outcome' -Default 'Blocked')
    if ($outcome -notin @('RolledBack', 'Blocked', 'RecoveryRequired', 'ManualRecoveryRequired')) { $outcome = 'Blocked' }
    $changed = @($Steps | Where-Object { [bool]$_.changed }).Count -gt 0
    $extensions = [ordered]@{ automation = [ordered]@{ failedStep = $FailedStep; steps = @($Steps) } }
    if ($null -ne $UpdaterEvidence) {
        $extensions['updater'] = [ordered]@{
            before = [string](Get-CpaStackValue -Object $UpdaterEvidence -Name 'currentVersion')
            after = [string](Get-CpaStackValue -Object $UpdaterEvidence -Name 'latestVersion')
            available = [string](Get-CpaStackValue -Object $UpdaterEvidence -Name 'availableVersion')
            changed = [bool](Get-CpaStackValue -Object $UpdaterEvidence -Name 'changed' -Default $false)
        }
    }
    return New-CpaStackResult -Operation upgrade -Success $false -Outcome $outcome -Changed $changed -Root $Root `
        -RolledBack ([bool](Get-CpaStackValue -Object $Result -Name 'rolledBack' -Default $false)) `
        -Recovered (@($Steps | Where-Object { [bool]$_.recovered }).Count -gt 0) `
        -Error (Get-CpaStackValue -Object $Result -Name 'error') `
        -Extensions $extensions
}

function Invoke-CpaStackAutomaticUpgrade {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$HostAdapter,
        [string]$RequestPath,
        $UpdaterEvidence
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $UpdaterEvidence) { $steps.Add((New-CpaStackUpdaterStep -Evidence $UpdaterEvidence)) }
    $recoveryAttempted = $false
    $migrationAttempted = $false

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $upgrade = Invoke-CpaStackUpgradeTransaction -Root $Root -HostAdapter $HostAdapter `
            -AllowUnknownVersionReplacement:$true
        if ([bool](Get-CpaStackValue -Object $upgrade -Name 'success' -Default $false)) {
            Add-AutomaticUpgradeStep -Steps $steps -Operation upgrade -Result $upgrade
            $shortcutResult = Invoke-CpaStackDesktopShortcutOperation -ShortcutAction Ensure -Root $Root
            Add-AutomaticUpgradeStep -Steps $steps -Operation shortcut -Result $shortcutResult
            Set-CpaStackValue -Object $upgrade -Name 'shortcut' -Value (Get-CpaStackValue -Object $shortcutResult -Name 'shortcut')
            if (-not [bool](Get-CpaStackValue -Object $shortcutResult -Name 'success' -Default $false)) {
                $shortcutError = Get-CpaStackValue -Object $shortcutResult -Name 'error'
                $warnings = @(Get-CpaStackValue -Object $upgrade -Name 'warnings' -Default @())
                $warnings += "CPA upgrade succeeded, but desktop shortcut maintenance failed: $([string](Get-CpaStackValue -Object $shortcutError -Name 'code'))"
                Set-CpaStackValue -Object $upgrade -Name 'warnings' -Value $warnings
            }
            return Complete-AutomaticUpgradeResult -Result $upgrade -Steps $steps -UpdaterEvidence $UpdaterEvidence
        }

        $upgradeOutcome = [string](Get-CpaStackValue -Object $upgrade -Name 'outcome')
        $upgradeError = Get-CpaStackValue -Object $upgrade -Name 'error'
        $upgradeErrorCode = [string](Get-CpaStackValue -Object $upgradeError -Name 'code')

        if ($upgradeOutcome -eq 'RecoveryRequired' -and -not $recoveryAttempted) {
            Add-AutomaticUpgradeStep -Steps $steps -Operation 'upgrade-preflight' -Result $upgrade
            $recovery = Invoke-CpaStackRecovery -Root $Root -HostAdapter $HostAdapter
            Add-AutomaticUpgradeStep -Steps $steps -Operation recover -Result $recovery
            $recoveryAttempted = $true
            if (-not [bool](Get-CpaStackValue -Object $recovery -Name 'success' -Default $false)) {
                return New-AutomaticUpgradeStepFailure -Root $Root -FailedStep recover -Result $recovery -Steps $steps -UpdaterEvidence $UpdaterEvidence
            }
            continue
        }

        if ($upgradeErrorCode -eq 'MigrationRequired' -and -not $migrationAttempted) {
            Add-AutomaticUpgradeStep -Steps $steps -Operation 'upgrade-preflight' -Result $upgrade
            $migration = Invoke-CpaStackMigrationTransaction -Root $Root -HostAdapter $HostAdapter -RequestPath $RequestPath
            if ([string](Get-CpaStackValue -Object $migration -Name 'outcome') -eq 'RecoveryRequired' -and -not $recoveryAttempted) {
                Add-AutomaticUpgradeStep -Steps $steps -Operation 'migrate-preflight' -Result $migration
                $recovery = Invoke-CpaStackRecovery -Root $Root -HostAdapter $HostAdapter
                Add-AutomaticUpgradeStep -Steps $steps -Operation recover -Result $recovery
                $recoveryAttempted = $true
                if (-not [bool](Get-CpaStackValue -Object $recovery -Name 'success' -Default $false)) {
                    return New-AutomaticUpgradeStepFailure -Root $Root -FailedStep recover -Result $recovery -Steps $steps -UpdaterEvidence $UpdaterEvidence
                }
                $migration = Invoke-CpaStackMigrationTransaction -Root $Root -HostAdapter $HostAdapter -RequestPath $RequestPath
            }
            Add-AutomaticUpgradeStep -Steps $steps -Operation migrate -Result $migration
            $migrationAttempted = $true
            if (-not [bool](Get-CpaStackValue -Object $migration -Name 'success' -Default $false)) {
                return New-AutomaticUpgradeStepFailure -Root $Root -FailedStep migrate -Result $migration -Steps $steps -UpdaterEvidence $UpdaterEvidence
            }
            continue
        }

        Add-AutomaticUpgradeStep -Steps $steps -Operation upgrade -Result $upgrade
        return Complete-AutomaticUpgradeResult -Result $upgrade -Steps $steps -UpdaterEvidence $UpdaterEvidence
    }

    $retryFailure = New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $Root `
        -Error (New-CpaStackError -Code 'AutomaticUpgradeRetryLimit' -Message 'Automatic upgrade did not converge within its bounded recovery and migration retries.' -Phase 'orchestration')
    Add-AutomaticUpgradeStep -Steps $steps -Operation upgrade -Result $retryFailure
    return Complete-AutomaticUpgradeResult -Result $retryFailure -Steps $steps -UpdaterEvidence $UpdaterEvidence
}

$commonParameterNames = @(
    'Command', 'Root', 'Json',
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable',
    'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction'
)
$commandParameterNames = switch ($Command) {
    { $_ -in @('status', 'recover') } { @(); break }
    'migrate' { @('RequestPath'); break }
    'upgrade' { @('RequestPath'); break }
    'start' { @('NoBrowser'); break }
    'shortcut' { @('Action', 'ShortcutPath'); break }
    'lan' { @('Action', 'Mode'); break }
}
$allowedParameterNames = @($commonParameterNames) + @($commandParameterNames)
$unsupportedParameterNames = @($PSBoundParameters.Keys | Where-Object { [string]$_ -notin $allowedParameterNames })
if ($unsupportedParameterNames.Count -gt 0) {
    $unsupportedRoot = if ([string]::IsNullOrWhiteSpace($Root)) { '<unresolved>' } else { [string]$Root }
    $unsupportedResult = New-CpaStackResult -Operation $Command `
        -Success $false -Outcome Blocked -Changed $false -Root $unsupportedRoot `
        -Error (New-CpaStackError -Code 'UnsupportedCommandParameter' `
            -Message ("Command '$Command' does not accept: " + (($unsupportedParameterNames | Sort-Object) -join ', ')))
    Write-CommandResult -Value $unsupportedResult
    exit 1
}

try {
    $resolvedRoot = Resolve-CpaStackControlRoot -RequestedRoot $Root
    $targetDrive = [System.IO.Path]::GetPathRoot($resolvedRoot)
    if ([string]::IsNullOrWhiteSpace($targetDrive) -or -not (Test-Path -LiteralPath $targetDrive)) {
        throw [System.IO.DriveNotFoundException]::new("Target drive does not exist: $targetDrive Choose an existing local NTFS/ReFS drive or mount it before retrying.")
    }
    $resolvedRoot = Assert-CpaStackSecureLocalRoot -Path $resolvedRoot

    $hostAdapter = New-CpaStackBundledHost -ScriptsRoot $PSScriptRoot
    if ($Command -eq 'status') {
        $inspection = Invoke-CpaStackInspection -Root $resolvedRoot -HostAdapter $hostAdapter -Operation status
        Write-CommandResult -Value $inspection
        if (-not [bool]$inspection.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'upgrade') {
        try {
            $updaterEvidence = Get-CpaStackUpdaterReexecEvidence
        } catch {
            $updaterEvidence = [pscustomobject]@{
                success = $false
                changed = $false
                currentVersion = $null
                latestVersion = $updaterVersion
                availableVersion = $updaterVersion
                error = [pscustomobject]@{
                    code = 'UpdaterReexecInvalid'
                    message = 'Updater re-execution validation failed before the CPA runtime upgrade.'
                    type = $_.Exception.GetType().FullName
                    phase = 'updater-reexec'
                }
            }
        }
        if ($null -eq $updaterEvidence) {
            $updaterEvidence = Invoke-CpaStackSelfUpdate -StackRoot $resolvedRoot
        }
        if (-not [bool](Get-CpaStackValue -Object $updaterEvidence -Name 'success' -Default $false)) {
            $updaterFailure = New-CpaStackUpdaterFailure -Root $resolvedRoot -Evidence $updaterEvidence
            Write-CommandResult -Value $updaterFailure
            exit 1
        }
        if ([bool](Get-CpaStackValue -Object $updaterEvidence -Name 'changed' -Default $false) -and
            [string](Get-CpaStackValue -Object $updaterEvidence -Name 'latestVersion') -cne $updaterVersion) {
            try {
                Invoke-CpaStackUpgradeReexec -Root $resolvedRoot -RequestPath $RequestPath `
                    -FromVersion ([string](Get-CpaStackValue -Object $updaterEvidence -Name 'currentVersion')) `
                    -ToVersion ([string](Get-CpaStackValue -Object $updaterEvidence -Name 'latestVersion'))
            } catch {
                $reexecFailure = [pscustomobject]@{
                    success = $false
                    changed = $true
                    currentVersion = [string](Get-CpaStackValue -Object $updaterEvidence -Name 'currentVersion')
                    latestVersion = [string](Get-CpaStackValue -Object $updaterEvidence -Name 'latestVersion')
                    availableVersion = [string](Get-CpaStackValue -Object $updaterEvidence -Name 'availableVersion')
                    error = [pscustomobject]@{
                        code = 'UpdaterReexecFailed'
                        message = 'The updater was installed, but the new CLI could not be started.'
                        type = $_.Exception.GetType().FullName
                        phase = 'updater-reexec'
                    }
                }
                Write-CommandResult -Value (New-CpaStackUpdaterFailure -Root $resolvedRoot -Evidence $reexecFailure)
                exit 1
            }
        }
        $upgradeResult = Invoke-CpaStackAutomaticUpgrade -Root $resolvedRoot -HostAdapter $hostAdapter `
            -RequestPath $RequestPath -UpdaterEvidence $updaterEvidence
        Write-CommandResult -Value $upgradeResult
        if (-not $upgradeResult.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'migrate') {
        $migrationResult = Invoke-CpaStackMigrationTransaction -Root $resolvedRoot -HostAdapter $hostAdapter -RequestPath $RequestPath
        Write-CommandResult -Value $migrationResult
        if (-not $migrationResult.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'recover') {
        $recoveryResult = Invoke-CpaStackRecovery -Root $resolvedRoot -HostAdapter $hostAdapter
        Write-CommandResult -Value $recoveryResult
        if (-not $recoveryResult.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'start') {
        $startResult = Invoke-CpaStackStartOperation -Root $resolvedRoot -HostAdapter $hostAdapter -NoBrowser:$NoBrowser
        Write-CommandResult -Value $startResult
        if (-not $startResult.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'lan') {
        if ($Action -ne 'Set' -or [string]::IsNullOrWhiteSpace($Mode)) {
            $invalidLan = New-CpaStackResult -Operation lan -Success $false -Outcome Blocked -Changed $false -Root $resolvedRoot `
                -Error (New-CpaStackError -Code 'InvalidLanRequest' -Message "LAN requires '-Action Set -Mode Loopback|Lan'.")
            Write-CommandResult -Value $invalidLan
            exit 1
        }
        $lanResult = Invoke-CpaStackLanOperation -Root $resolvedRoot -HostAdapter $hostAdapter -Action $Action -Mode $Mode
        Write-CommandResult -Value $lanResult
        if (-not $lanResult.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'shortcut') {
        if ($Action -notin @('Check', 'Ensure')) {
            $invalidShortcut = New-CpaStackResult -Operation shortcut -Success $false -Outcome Blocked -Changed $false -Root $resolvedRoot `
                -Error (New-CpaStackError -Code 'InvalidShortcutRequest' -Message "Shortcut requires '-Action Check|Ensure'.")
            Write-CommandResult -Value $invalidShortcut
            exit 1
        }
        $shortcutResult = Invoke-CpaStackDesktopShortcutOperation -ShortcutAction $Action -Root $resolvedRoot -Path $ShortcutPath
        Write-CommandResult -Value $shortcutResult
        if (-not $shortcutResult.success) { exit 1 }
        exit 0
    }
} catch {
    $errorCode = switch ($_.Exception.GetType().FullName) {
        'System.IO.DriveNotFoundException' { 'TargetDriveNotFound' }
        'System.UnauthorizedAccessException' { 'AccessDenied' }
        default { 'CommandFailed' }
    }
    $failureRoot = if ($resolvedRoot) { [string]$resolvedRoot } elseif (-not [string]::IsNullOrWhiteSpace($Root)) { [string]$Root } else { '<unresolved>' }
    Write-CommandResult -Value (New-CpaStackResult -Operation $Command -Success $false -Outcome Blocked -Changed $false `
        -Root $failureRoot `
        -Error (New-CpaStackError -Code $errorCode -Type $_.Exception.GetType().FullName -Message $_.Exception.Message))
    exit 1
}

exit 0
