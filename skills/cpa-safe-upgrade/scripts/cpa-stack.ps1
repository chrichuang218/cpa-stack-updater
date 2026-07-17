#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'doctor', 'plan', 'init', 'migrate', 'recover', 'upgrade', 'start', 'shortcut', 'lan', 'register-root')]
    [string]$Command = 'status',

    [Alias('ControlRoot')]
    [string]$Root,

    [string]$SourceCpaRuntime,
    [string]$SourceCpaConfig,
    [string]$SourceManagerRuntime,
    [string]$SourceManagerData,
    [string]$LegacyStartScript,
    [string]$SecretsInputPath,
    [string]$RequestPath,
    [ValidateSet('Check', 'Ensure', 'Set')]
    [string]$Action,
    [ValidateSet('Loopback', 'Lan')]
    [string]$Mode,
    [string]$ShortcutPath,
    [switch]$AdoptExisting,
    [string]$DesktopShortcut,
    [switch]$UpdateDesktopShortcut,
    [switch]$ExposeToLan,
    [switch]$AllowUnknownVersionReplacement,
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

$commonParameterNames = @(
    'Command', 'Root', 'Json',
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
    'ErrorVariable', 'WarningVariable', 'InformationVariable',
    'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction'
)
$commandParameterNames = switch ($Command) {
    { $_ -in @('status', 'doctor', 'plan', 'recover', 'register-root') } { @(); break }
    'init' {
        @('SourceCpaRuntime', 'SourceCpaConfig', 'SourceManagerRuntime', 'SourceManagerData',
            'LegacyStartScript', 'SecretsInputPath', 'RequestPath', 'DesktopShortcut',
            'UpdateDesktopShortcut', 'ExposeToLan')
        break
    }
    'migrate' { @('RequestPath'); break }
    'upgrade' {
        @('SourceCpaRuntime', 'SourceCpaConfig', 'SourceManagerRuntime', 'SourceManagerData',
            'LegacyStartScript', 'SecretsInputPath', 'DesktopShortcut', 'UpdateDesktopShortcut',
            'ExposeToLan', 'AllowUnknownVersionReplacement')
        break
    }
    'start' { @('NoBrowser'); break }
    'shortcut' { @('Action', 'ShortcutPath', 'AdoptExisting'); break }
    'lan' { @('Action', 'Mode'); break }
}
$allowedParameterNames = @($commonParameterNames) + @($commandParameterNames)
$unsupportedParameterNames = @($PSBoundParameters.Keys | Where-Object { [string]$_ -notin $allowedParameterNames })
if ($unsupportedParameterNames.Count -gt 0) {
    $unsupportedRoot = if ([string]::IsNullOrWhiteSpace($Root)) { '<unresolved>' } else { [string]$Root }
    $unsupportedResult = New-CpaStackResult -Operation $(if ($Command -in @('doctor', 'plan')) { 'status' } elseif ($Command -eq 'init') { 'migrate' } else { $Command }) `
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

    # v0.1 command names remain as explicit v2 compatibility mappings for one release.
    $hostAdapter = New-CpaStackBundledHost -ScriptsRoot $PSScriptRoot
    if ($Command -in @('status', 'doctor', 'plan')) {
        $compatibilityWarnings = @()
        if ($Command -ne 'status') {
            $compatibilityWarnings += "Command '$Command' is a legacy alias outside the v1 supported interface; use 'status'."
        }
        $inspection = Invoke-CpaStackInspection -Root $resolvedRoot -HostAdapter $hostAdapter -Operation status -Warnings $compatibilityWarnings
        if ($Command -ne 'status') {
            $inspection['deprecatedCommand'] = $Command
        }
        Write-CommandResult -Value $inspection
        if (-not [bool]$inspection.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'init') {
        if ($UpdateDesktopShortcut -or $ExposeToLan -or -not [string]::IsNullOrWhiteSpace($DesktopShortcut)) {
            $legacySplit = New-CpaStackResult -Operation migrate -Success $false -Outcome Blocked -Changed $false -Root $resolvedRoot `
                -Warnings @("Command 'init' is a legacy alias outside the v1 supported interface; use 'migrate'.") `
                -Error (New-CpaStackError -Code 'OperationSplitRequired' -Message 'Shortcut and LAN changes must use their explicit v2 operations.') `
                -Extensions ([ordered]@{ deprecatedCommand = 'init' })
            Write-CommandResult -Value $legacySplit
            exit 1
        }
        $legacyRequestPath = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace($RequestPath)) {
                $legacyRequestPath = $RequestPath
            } elseif (@($SourceCpaRuntime, $SourceCpaConfig, $SourceManagerRuntime, $SourceManagerData) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) {
                foreach ($required in @(
                    [pscustomobject]@{ Name = 'SourceCpaRuntime'; Value = $SourceCpaRuntime },
                    [pscustomobject]@{ Name = 'SourceCpaConfig'; Value = $SourceCpaConfig },
                    [pscustomobject]@{ Name = 'SourceManagerRuntime'; Value = $SourceManagerRuntime },
                    [pscustomobject]@{ Name = 'SourceManagerData'; Value = $SourceManagerData }
                )) {
                    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
                        throw "Deprecated init requires a complete explicit source. Missing=$($required.Name)"
                    }
                }
                $legacyRequestPath = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-migrate-compat-' + [guid]::NewGuid().ToString('N') + '.json')
                $legacyRequest = [ordered]@{
                    schemaVersion = 1
                    sourceMode = 'Explicit'
                    source = [ordered]@{
                        cpaRuntime = $SourceCpaRuntime
                        cpaConfig = $SourceCpaConfig
                        managerRuntime = $SourceManagerRuntime
                        managerData = $SourceManagerData
                        legacyStartScript = $LegacyStartScript
                    }
                    secretsInputPath = $SecretsInputPath
                }
                [System.IO.File]::WriteAllText($legacyRequestPath, ($legacyRequest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
            } elseif (-not [string]::IsNullOrWhiteSpace($SecretsInputPath)) {
                $legacyRequestPath = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-migrate-compat-' + [guid]::NewGuid().ToString('N') + '.json')
                $legacyRequest = [ordered]@{
                    schemaVersion = 1
                    sourceMode = 'Auto'
                    source = $null
                    secretsInputPath = $SecretsInputPath
                    ports = $null
                }
                [System.IO.File]::WriteAllText($legacyRequestPath, ($legacyRequest | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
            }
            $legacyMigration = Invoke-CpaStackMigrationTransaction -Root $resolvedRoot -HostAdapter $hostAdapter -RequestPath $legacyRequestPath
            $legacyMigration.warnings = @($legacyMigration.warnings) + @("Command 'init' is a legacy alias outside the v1 supported interface; use 'migrate'.")
            $legacyMigration['deprecatedCommand'] = 'init'
            Write-CommandResult -Value $legacyMigration
            if (-not $legacyMigration.success) { exit 1 }
            exit 0
        } finally {
            if ($legacyRequestPath -and $legacyRequestPath -ne $RequestPath -and (Test-Path -LiteralPath $legacyRequestPath)) {
                Remove-Item -LiteralPath $legacyRequestPath -Force
            }
        }
    }
    if ($Command -eq 'upgrade') {
        $splitArguments = @(@(
                $SourceCpaRuntime,
                $SourceCpaConfig,
                $SourceManagerRuntime,
                $SourceManagerData,
                $LegacyStartScript,
                $SecretsInputPath,
                $DesktopShortcut
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($splitArguments.Count -gt 0 -or $UpdateDesktopShortcut -or $ExposeToLan) {
            $splitResult = New-CpaStackResult -Operation upgrade -Success $false -Outcome Blocked -Changed $false -Root $resolvedRoot `
                -Error (New-CpaStackError -Code 'OperationSplitRequired' -Message 'Migration, shortcut, and LAN changes must be authorized through their explicit v2 operations.')
            Write-CommandResult -Value $splitResult
            exit 1
        }
        $upgradeResult = Invoke-CpaStackUpgradeTransaction -Root $resolvedRoot -HostAdapter $hostAdapter `
            -AllowUnknownVersionReplacement:$AllowUnknownVersionReplacement
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
        if ([string]::IsNullOrWhiteSpace($ShortcutPath)) {
            $shortcutName = 'CPA ' + (-join @(
                [char]0x672C, [char]0x5730, [char]0x542F, [char]0x52A8,
                [char]0xFF08, [char]0x65B0, [char]0x7248, [char]0xFF09
            )) + '.lnk'
            $ShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName
        }
        try {
            $shortcutInner = Invoke-CpaStackManagedShortcut -Action $Action -Root $resolvedRoot -ShortcutPath $ShortcutPath -AdoptExisting:$AdoptExisting
            $shortcutResult = New-CpaStackResult -Operation shortcut -Success $true -Outcome $(if ([bool]$shortcutInner.changed) { 'Changed' } else { 'NoChange' }) `
                -Changed ([bool]$shortcutInner.changed) -Root $resolvedRoot -Extensions ([ordered]@{ shortcut = $shortcutInner })
        } catch {
            $shortcutCode = if ($_.Exception.Message -match '(?i)adoptable|conflict|unknown') { 'ShortcutOwnershipConflict' } else { 'ShortcutOperationFailed' }
            $shortcutResult = New-CpaStackResult -Operation shortcut -Success $false -Outcome Blocked -Changed $false -Root $resolvedRoot `
                -Error (New-CpaStackError -Code $shortcutCode -Message $_.Exception.Message -Type $_.Exception.GetType().FullName)
        }
        Write-CommandResult -Value $shortcutResult
        if (-not $shortcutResult.success) { exit 1 }
        exit 0
    }
    if ($Command -eq 'register-root') {
        $registerLock = $null
        try {
            $registerLock = Enter-CpaStackOperationLock -TimeoutSeconds 2
            Set-CpaStackRegisteredRoot -ControlRoot $resolvedRoot
        } finally {
            Exit-CpaStackOperationLock -Mutex $registerLock
        }
        $registerResult = New-CpaStackResult -Operation register-root -Success $true -Outcome Changed -Changed $true -Root $resolvedRoot `
            -Warnings @("Command 'register-root' is a legacy alias outside the v1 supported interface; install.ps1 manages root registration.")
        Write-CommandResult -Value $registerResult
        exit 0
    }

} catch {
    $errorCode = switch ($_.Exception.GetType().FullName) {
        'System.IO.DriveNotFoundException' { 'TargetDriveNotFound' }
        'System.UnauthorizedAccessException' { 'AccessDenied' }
        default { 'CommandFailed' }
    }
    $failedOperation = switch ($Command) {
        { $_ -in @('doctor', 'plan') } { 'status'; break }
        'init' { 'migrate'; break }
        default { $Command }
    }
    $failureRoot = if ($resolvedRoot) { [string]$resolvedRoot } elseif (-not [string]::IsNullOrWhiteSpace($Root)) { [string]$Root } else { '<unresolved>' }
    Write-CommandResult -Value (New-CpaStackResult -Operation $failedOperation -Success $false -Outcome Blocked -Changed $false `
        -Root $failureRoot `
        -Error (New-CpaStackError -Code $errorCode -Type $_.Exception.GetType().FullName -Message $_.Exception.Message))
    exit 1
}

exit 0
