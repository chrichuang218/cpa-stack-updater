#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'doctor', 'plan', 'init', 'upgrade', 'start', 'register-root')]
    [string]$Command = 'status',

    [Alias('ControlRoot')]
    [string]$Root,

    [string]$SourceCpaRuntime,
    [string]$SourceCpaConfig,
    [string]$SourceManagerRuntime,
    [string]$SourceManagerData,
    [string]$LegacyStartScript,
    [string]$SecretsInputPath,
    [string]$DesktopShortcut,
    [switch]$UpdateDesktopShortcut,
    [switch]$ExposeToLan,
    [switch]$AllowUnknownVersionReplacement,
    [switch]$NoBrowser,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CpaStack.Common.ps1')

$resolvedRoot = $null
$updaterVersion = Get-CpaStackUpdaterVersion

function Get-JsonPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-PublicCommandError {
    param($Json, [int]$ExitCode, [string]$Operation)

    $errorValue = Get-JsonPropertyValue -Object $Json -Name 'error'
    if ($null -ne $errorValue) { return $errorValue }
    if ($ExitCode -ne 0) {
        return [ordered]@{
            code = ($Operation + 'Failed')
            message = "$Operation failed with exit code $ExitCode."
        }
    }
    return $null
}

function Invoke-BundledScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )

    $script = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Bundled script is missing: $script"
    }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $previousModulePath = $env:PSModulePath
    try {
        $env:PSModulePath = Get-CpaStackWindowsPowerShellModulePath
        $output = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File $script @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PSModulePath = $previousModulePath
    }
    $json = $null
    $combined = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try { $json = $combined | ConvertFrom-Json } catch {}
    foreach ($line in @($output | ForEach-Object { [string]$_ })) {
        if ($json) { break }
        $candidate = $line.Trim()
        if ($candidate.StartsWith('{') -and $candidate.EndsWith('}')) {
            try { $json = $candidate | ConvertFrom-Json } catch {}
        }
    }
    if ($exitCode -ne 0 -and -not $AllowNonZero) {
        $errorValue = Get-JsonPropertyValue -Object $json -Name 'Error'
        $errorMessage = Get-JsonPropertyValue -Object $errorValue -Name 'Message'
        $message = if ([string]::IsNullOrWhiteSpace([string]$errorMessage)) { $combined } else { [string]$errorMessage }
        throw "${Name} failed with exit code ${exitCode}: $message"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Json = $json
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-StatusResult {
    $result = Invoke-BundledScript -Name 'Get-CpaStackState.ps1' -Arguments @('-ControlRoot', $resolvedRoot) -AllowNonZero
    if (-not $result.Json) {
        throw 'Status command did not return a JSON document.'
    }
    return $result.Json
}

function Get-InitArguments {
    $arguments = @('-ControlRoot', $resolvedRoot)
    foreach ($pair in @(
        @('SourceCpaRuntime', $SourceCpaRuntime),
        @('SourceCpaConfig', $SourceCpaConfig),
        @('SourceManagerRuntime', $SourceManagerRuntime),
        @('SourceManagerData', $SourceManagerData),
        @('LegacyStartScript', $LegacyStartScript),
        @('SecretsInputPath', $SecretsInputPath),
        @('DesktopShortcut', $DesktopShortcut)
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pair[1])) {
            $arguments += @('-' + [string]$pair[0], [string]$pair[1])
        }
    }
    if ($UpdateDesktopShortcut) { $arguments += '-UpdateDesktopShortcut' }
    if ($ExposeToLan) { $arguments += '-ExposeToLan' }
    return $arguments
}

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

try {
    $resolvedRoot = Resolve-CpaStackControlRoot -RequestedRoot $Root
    $targetDrive = [System.IO.Path]::GetPathRoot($resolvedRoot)
    if ([string]::IsNullOrWhiteSpace($targetDrive) -or -not (Test-Path -LiteralPath $targetDrive)) {
        throw [System.IO.DriveNotFoundException]::new("Target drive does not exist: $targetDrive Choose an existing local NTFS/ReFS drive or mount it before retrying.")
    }
    $resolvedRoot = Assert-CpaStackSecureLocalRoot -Path $resolvedRoot
    switch ($Command) {
        { $_ -in @('status', 'doctor') } {
            $state = Get-StatusResult
            $stateError = Get-JsonPropertyValue -Object $state -Name 'Error'
            $statusResult = [ordered]@{
                schemaVersion = 1
                command = $Command
                success = [bool]$state.OverallHealthy
                changed = $false
                root = $resolvedRoot
                state = $state
                warnings = @()
                error = $stateError
            }
            Write-CommandResult -Value $statusResult
            if (-not $statusResult.success) { exit 1 }
            break
        }
        'plan' {
            $state = Get-StatusResult
            $stateError = Get-JsonPropertyValue -Object $state -Name 'Error'
            if ($stateError) {
                $stateErrorMessage = Get-JsonPropertyValue -Object $stateError -Name 'Message'
                if ([string]::IsNullOrWhiteSpace([string]$stateErrorMessage)) {
                    throw 'Status failed.'
                }
                throw "Status failed: $stateErrorMessage"
            }
            $actions = @()
            if ($state.InterruptedState) { $actions += 'recover-interrupted-operation' }
            $legacyAdoptionRequired = [bool](Get-JsonPropertyValue -Object $state -Name 'LegacyCanonicalAdoptionRequired')
            if ($legacyAdoptionRequired) {
                $actions += 'adopt-legacy-canonical-stack'
            } elseif ($state.MigrationRequired) {
                $actions += 'initialize-canonical-stack'
            }
            if ($state.CanonicalEstablished -and -not $state.InterruptedState) { $actions += 'check-and-upgrade-official-releases' }
            Write-CommandResult -Value ([ordered]@{
                schemaVersion = 1
                command = 'plan'
                success = $true
                changed = $false
                root = $resolvedRoot
                actions = $actions
                state = $state
                warnings = @('Plan is read-only. No service, file, shortcut, or setting was changed.')
                error = $null
            })
            break
        }
        'register-root' {
            $registerLock = $null
            try {
                $registerLock = Enter-CpaStackOperationLock -TimeoutSeconds 2
                $rootToRegister = Assert-CpaStackSecureLocalRoot -Path $resolvedRoot
                Set-CpaStackRegisteredRoot -ControlRoot $rootToRegister
            } finally {
                Exit-CpaStackOperationLock -Mutex $registerLock
            }
            Write-CommandResult -Value ([ordered]@{
                schemaVersion = 1
                command = 'register-root'
                success = $true
                changed = $true
                root = $rootToRegister
                warnings = @()
                error = $null
            })
            break
        }
        'init' {
            $init = Invoke-BundledScript -Name 'Initialize-CpaStack.ps1' -Arguments (Get-InitArguments) -AllowNonZero
            if (-not $init.Json) { throw 'Initialization returned no JSON result.' }
            $initSuccess = ($init.ExitCode -eq 0 -and [bool](Get-JsonPropertyValue -Object $init.Json -Name 'success'))
            Write-CommandResult -Value ([ordered]@{
                schemaVersion = 1
                command = 'init'
                success = $initSuccess
                changed = $initSuccess
                rolledBack = [bool](Get-JsonPropertyValue -Object $init.Json -Name 'rolledBack')
                root = $resolvedRoot
                initialization = $init.Json
                warnings = @((Get-JsonPropertyValue -Object $init.Json -Name 'journalCleanupWarning') | Where-Object { $_ })
                error = Get-PublicCommandError -Json $init.Json -ExitCode $init.ExitCode -Operation 'Initialization'
            })
            if (-not $initSuccess) { exit 1 }
            break
        }
        'upgrade' {
            $state = Get-StatusResult
            $initialization = $null
            $adoption = $null
            $adoptPendingPath = Join-Path $resolvedRoot 'state\adopt.pending.json'
            Assert-CpaStackChildPath -Root $resolvedRoot -Path $adoptPendingPath
            $hasAdoptPending = Test-Path -LiteralPath $adoptPendingPath -PathType Leaf
            $legacyAdoptionRequired = [bool](Get-JsonPropertyValue -Object $state -Name 'LegacyCanonicalAdoptionRequired') -or $hasAdoptPending
            if ($legacyAdoptionRequired) {
                $adopt = Invoke-BundledScript -Name 'Adopt-CpaStackLegacyCanonical.ps1' -Arguments @('-ControlRoot', $resolvedRoot) -AllowNonZero
                if (-not $adopt.Json) { throw 'Legacy canonical adoption returned no JSON result.' }
                $adoption = $adopt.Json
                $adoptionSuccess = ($adopt.ExitCode -eq 0 -and [bool](Get-JsonPropertyValue -Object $adoption -Name 'success'))
                if (-not $adoptionSuccess) {
                    Write-CommandResult -Value ([ordered]@{
                        schemaVersion = 1
                        command = 'upgrade'
                        success = $false
                        changed = [bool](Get-JsonPropertyValue -Object $adoption -Name 'changed')
                        rolledBack = $false
                        root = $resolvedRoot
                        adoption = $adoption
                        initialization = $null
                        upgrade = $null
                        warnings = @((Get-JsonPropertyValue -Object $adoption -Name 'journalCleanupWarning') | Where-Object { $_ })
                        error = Get-PublicCommandError -Json $adoption -ExitCode $adopt.ExitCode -Operation 'Legacy canonical adoption'
                    })
                    exit 1
                }
                $state = Get-StatusResult
            }
            $initializePendingPath = Join-Path $resolvedRoot 'state\initialize.pending.json'
            Assert-CpaStackChildPath -Root $resolvedRoot -Path $initializePendingPath
            $hasInitializePending = Test-Path -LiteralPath $initializePendingPath -PathType Leaf
            $migrationRequired = [bool](Get-JsonPropertyValue -Object $state -Name 'MigrationRequired')
            $stateHealthy = [bool](Get-JsonPropertyValue -Object $state -Name 'OverallHealthy')
            if ($migrationRequired -or $hasInitializePending) {
                if (-not $stateHealthy -and -not $hasInitializePending) {
                    throw 'The existing CPA stack is not healthy enough to migrate. Run status and fix the reported checks first.'
                }
                $init = Invoke-BundledScript -Name 'Initialize-CpaStack.ps1' -Arguments (Get-InitArguments) -AllowNonZero
                if (-not $init.Json) { throw 'Initialization returned no JSON result.' }
                $initialization = $init.Json
                $initSuccess = ($init.ExitCode -eq 0 -and [bool](Get-JsonPropertyValue -Object $initialization -Name 'success'))
                if (-not $initSuccess) {
                    Write-CommandResult -Value ([ordered]@{
                        schemaVersion = 1
                        command = 'upgrade'
                        success = $false
                        changed = $false
                        rolledBack = [bool](Get-JsonPropertyValue -Object $initialization -Name 'rolledBack')
                        root = $resolvedRoot
                        adoption = $adoption
                        initialization = $initialization
                        upgrade = $null
                        warnings = @((Get-JsonPropertyValue -Object $initialization -Name 'journalCleanupWarning') | Where-Object { $_ })
                        error = Get-PublicCommandError -Json $initialization -ExitCode $init.ExitCode -Operation 'Initialization'
                    })
                    exit 1
                }
                $state = Get-StatusResult
            }
            $upgradeArguments = @('-ControlRoot', $resolvedRoot)
            if ($AllowUnknownVersionReplacement) { $upgradeArguments += '-AllowUnknownVersionReplacement' }
            $upgrade = Invoke-BundledScript -Name 'Invoke-CpaStackUpgrade.ps1' -Arguments $upgradeArguments -AllowNonZero
            if (-not $upgrade.Json) { throw 'Upgrade returned no JSON result.' }
            $upgradeCpa = Get-JsonPropertyValue -Object $upgrade.Json -Name 'cpa'
            $upgradeManager = Get-JsonPropertyValue -Object $upgrade.Json -Name 'manager'
            $cpaSkipped = [bool](Get-JsonPropertyValue -Object $upgradeCpa -Name 'skipped')
            $managerSkipped = [bool](Get-JsonPropertyValue -Object $upgradeManager -Name 'skipped')
            $cpaRolledBack = [bool](Get-JsonPropertyValue -Object $upgradeCpa -Name 'rolledBack')
            $managerRolledBack = [bool](Get-JsonPropertyValue -Object $upgradeManager -Name 'rolledBack')
            $cleanupWarning = Get-JsonPropertyValue -Object $upgrade.Json -Name 'cleanupWarning'
            $journalCleanupWarning = Get-JsonPropertyValue -Object $upgrade.Json -Name 'journalCleanupWarning'
            $adoptionCleanupWarning = Get-JsonPropertyValue -Object $adoption -Name 'journalCleanupWarning'
            $initializationCleanupWarning = Get-JsonPropertyValue -Object $initialization -Name 'journalCleanupWarning'
            $launcherUpdated = [bool](Get-JsonPropertyValue -Object $upgrade.Json -Name 'launcherUpdated')
            $upgradeSuccess = ($upgrade.ExitCode -eq 0 -and [bool](Get-JsonPropertyValue -Object $upgrade.Json -Name 'success'))
            $cpaChanged = ($null -ne $upgradeCpa -and -not $cpaSkipped -and ($upgradeSuccess -or [bool](Get-JsonPropertyValue -Object $upgradeCpa -Name 'success')))
            $managerChanged = ($null -ne $upgradeManager -and -not $managerSkipped -and ($upgradeSuccess -or [bool](Get-JsonPropertyValue -Object $upgradeManager -Name 'success')))
            Write-CommandResult -Value ([ordered]@{
                schemaVersion = 1
                command = 'upgrade'
                success = $upgradeSuccess
                changed = [bool]($adoption -or $initialization -or $launcherUpdated -or $cpaChanged -or $managerChanged)
                rolledBack = [bool]($cpaRolledBack -or $managerRolledBack)
                root = $resolvedRoot
                adoption = $adoption
                initialization = $initialization
                upgrade = $upgrade.Json
                warnings = @(@($adoptionCleanupWarning, $initializationCleanupWarning, $cleanupWarning, $journalCleanupWarning) | Where-Object { $_ })
                error = Get-PublicCommandError -Json $upgrade.Json -ExitCode $upgrade.ExitCode -Operation 'Upgrade'
            })
            if (-not $upgradeSuccess) { exit 1 }
            break
        }
        'start' {
            $startRoot = Assert-CpaStackSecureLocalRoot -Path $resolvedRoot
            $marker = Ensure-CpaStackInstanceMarker -ControlRoot $startRoot
            $canonicalStartScript = Join-Path $startRoot 'ops\Start-CPA-Stack.ps1'
            $trustedStartScript = Join-Path $PSScriptRoot 'Start-CPA-Stack.ps1'
            $configPath = Join-Path $startRoot 'config\stack.psd1'
            $currentPath = Join-Path $startRoot 'state\current.json'
            foreach ($path in @($canonicalStartScript, $configPath, $currentPath)) {
                Assert-CpaStackChildPath -Root $startRoot -Path $path
                Assert-CpaStackPath -Path $path -PathType Leaf
            }
            Assert-CpaStackPath -Path $trustedStartScript -PathType Leaf
            $current = Read-CpaStackJson -Path $currentPath
            if ([System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\') -ine $startRoot -or [string]$current.instanceId -ne [string]$marker.instanceId) {
                throw 'The requested start root does not have matching canonical instance state.'
            }
            $arguments = @('-ConfigPath', $configPath)
            if ($NoBrowser) { $arguments += '-NoBrowser' }
            $start = Invoke-BundledScript -Name 'Start-CPA-Stack.ps1' -Arguments $arguments -AllowNonZero
            if (-not $start.Json) { throw 'Start returned no JSON result.' }
            $startSuccess = ($start.ExitCode -eq 0 -and [bool](Get-JsonPropertyValue -Object $start.Json -Name 'Success'))
            $startCpa = Get-JsonPropertyValue -Object $start.Json -Name 'Cpa'
            $startManager = Get-JsonPropertyValue -Object $start.Json -Name 'Manager'
            $startChanged = $startSuccess -and (
                [string](Get-JsonPropertyValue -Object $startCpa -Name 'Action') -eq 'Started' -or
                [string](Get-JsonPropertyValue -Object $startManager -Name 'Action') -eq 'Started' -or
                [string](Get-JsonPropertyValue -Object $start.Json -Name 'Browser') -eq 'Opened'
            )
            Write-CommandResult -Value ([ordered]@{
                schemaVersion = 1
                command = 'start'
                success = $startSuccess
                changed = [bool]$startChanged
                root = $resolvedRoot
                start = $start.Json
                warnings = @()
                error = Get-PublicCommandError -Json $start.Json -ExitCode $start.ExitCode -Operation 'Start'
            })
            if (-not $startSuccess) { exit 1 }
            break
        }
    }
} catch {
    $errorCode = switch ($_.Exception.GetType().FullName) {
        'System.IO.DriveNotFoundException' { 'TargetDriveNotFound' }
        'System.UnauthorizedAccessException' { 'AccessDenied' }
        default { 'CommandFailed' }
    }
    Write-CommandResult -Value ([ordered]@{
        schemaVersion = 1
        command = $Command
        success = $false
        changed = $false
        root = if ($resolvedRoot) { $resolvedRoot } else { $Root }
        warnings = @()
        error = [ordered]@{
            code = $errorCode
            type = $_.Exception.GetType().FullName
            message = $_.Exception.Message
        }
    })
    exit 1
}

exit 0
