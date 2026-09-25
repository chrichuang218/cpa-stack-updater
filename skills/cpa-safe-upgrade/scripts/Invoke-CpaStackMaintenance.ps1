#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [Parameter(Mandatory = $true)][ValidateSet('CleanupDerived')][string]$Action,
    [switch]$RecoverOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CpaStack.Common.ps1')
Import-Module (Join-Path $PSScriptRoot '..\modules\CpaStack.BundledHost.psm1')
$bundledHost = New-CpaStackBundledHost -ScriptsRoot $PSScriptRoot

$operationLock = $null
$instanceId = $null
$journalPath = Join-Path $ControlRoot 'state\maintenance.pending.json'
$journalPreviousPath = $journalPath + '.previous'
$resultPath = Join-Path $ControlRoot 'state\maintenance-result.json'
$result = [ordered]@{
    format_version = 1
    operation = 'cleanup-derived'
    success = $false
    changed = $false
    rolledBack = $false
    recovered = $false
    managerStopped = $false
    managerRestarted = $false
    databaseVerified = $false
    backupRetained = $false
    warnings = @()
    error = $null
}

function New-MaintenanceError {
    param([string]$Code, [string]$Message, [string]$Phase, [string]$Type)

    return [ordered]@{
        code = $Code
        message = $Message
        type = $Type
        phase = $Phase
    }
}

function Invoke-BundledJson {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )

    $run = Invoke-CpaStackBundled -HostAdapter $bundledHost -Name ([IO.Path]::GetFileName($Script)) -Arguments $Arguments
    if ($null -eq $run.Json -or ($run.ExitCode -ne 0 -and -not $AllowNonZero)) {
        throw "Bundled maintenance dependency returned an invalid result contract. ExitCode=$($run.ExitCode)."
    }
    return $run
}

function Get-MaintenanceState {
    param([switch]$AllowUnhealthy)

    $run = Invoke-BundledJson -Script (Join-Path $PSScriptRoot 'Get-CpaStackState.ps1') `
        -Arguments @('-ControlRoot', $ControlRoot) -AllowNonZero
    if (-not $AllowUnhealthy -and ([int]$run.ExitCode -ne 0 -or -not [bool]$run.Json.OverallHealthy)) {
        throw 'Canonical stack preflight is not healthy enough for offline maintenance.'
    }
    return $run.Json
}

function Get-MaintenanceInstanceId {
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
    $currentPath = Join-Path $ControlRoot 'state\current.json'
    $current = Read-CpaStackJson -Path $currentPath
    if ([string]$current.instanceId -cne [string]$marker.instanceId -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$current.canonicalRoot), $ControlRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Canonical current state does not match the instance marker.'
    }
    return [string]$marker.instanceId
}

function Get-MaintenanceContext {
    param([Parameter(Mandatory = $true)]$State)

    if (-not [bool]$State.CanonicalEstablished -or [bool]$State.InterruptedState -or
        @($State.PendingOperations).Count -gt 0) {
        throw 'Offline maintenance requires an established canonical stack with no pending transaction.'
    }
    if (-not [bool]$State.Manager.Healthy -or -not [bool]$State.Manager.Expected.ExecutableHashMatchesCurrent -or
        -not [bool]$State.Manager.Database.PathMatches -or -not [bool]$State.Security.ManagerDataTree.Protected) {
        throw 'Manager runtime, database, or protected data-tree validation failed.'
    }
    if ([int]$State.Manager.ListenerCount -ne 1 -or @($State.Manager.Listeners).Count -ne 1 -or
        -not [bool]$State.Manager.Listeners[0].PathMatches) {
        throw 'Manager formal port is not owned by exactly one canonical process.'
    }

    $executable = [System.IO.Path]::GetFullPath([string]$State.Manager.Expected.Executable)
    $workingDirectory = [System.IO.Path]::GetFullPath([string]$State.Manager.Expected.WorkingDirectory)
    $dataDirectory = [System.IO.Path]::GetFullPath([string]$State.Manager.Expected.DataDirectory)
    $database = [System.IO.Path]::GetFullPath([string]$State.Manager.Expected.Database)
    $dataKey = Join-Path $dataDirectory 'data.key'
    foreach ($path in @($executable, $workingDirectory, $dataDirectory, $database, $dataKey)) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $path
    }
    Assert-CpaStackPath -Path $executable -PathType Leaf
    Assert-CpaStackPath -Path $workingDirectory
    Assert-CpaStackPath -Path $dataDirectory
    Assert-CpaStackPath -Path $database -PathType Leaf
    Assert-CpaStackPath -Path $dataKey -PathType Leaf
    Assert-CpaStackPrivateTree -Root $dataDirectory -Description 'Protected Manager data' -AllowInheritedDescendants

    $executableHash = Get-CpaStackFileHash -Path $executable
    $dataKeyHash = Get-CpaStackFileHash -Path $dataKey
    if ([string]::IsNullOrWhiteSpace($executableHash) -or [string]::IsNullOrWhiteSpace($dataKeyHash)) {
        throw 'Manager executable or data.key hash could not be established.'
    }
    return [pscustomobject]@{
        Executable = $executable
        ExecutableHash = $executableHash
        WorkingDirectory = $workingDirectory
        DataDirectory = $dataDirectory
        Database = $database
        DataKey = $dataKey
        DataKeyHash = $dataKeyHash
        Port = [int]$State.Manager.Port
        BindAddress = [string]$State.Manager.Expected.BindAddress
        ProcessId = [int]$State.Manager.Listeners[0].ProcessId
    }
}

function Stop-MaintenanceManager {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$ExpectedProcessId = 0
    )

    $listener = Get-CpaStackListener -Port $Context.Port
    if ($null -eq $listener) { return $false }
    if ($ExpectedProcessId -gt 0 -and [int]$listener.ProcessId -ne $ExpectedProcessId) {
        Write-Error -Message 'Manager process identity changed after maintenance preflight.' `
            -ErrorId 'MaintenanceProcessChanged' -Category SecurityError -TargetObject $listener -ErrorAction Stop
    }
    [void](Wait-CpaStackTrustedListener -Port $Context.Port -ExpectedPath $Context.Executable `
        -ExpectedProcessId $listener.ProcessId -ExpectedHash $Context.ExecutableHash `
        -AllowedAddresses @($Context.BindAddress) -Seconds 2)
    $process = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $Context.Executable
    try {
        Stop-CpaStackPort -Port $Context.Port -ExpectedPath $Context.Executable `
            -ExpectedProcess $process -RequireExecutableWriteAccess -WaitSeconds 20
    } finally {
        if ($process -is [System.IDisposable]) { $process.Dispose() }
    }
    return $true
}

function Start-MaintenanceStack {
    $output = @(& (Join-Path $PSScriptRoot 'Start-CPA-Stack.ps1') `
        -ConfigPath (Join-Path $ControlRoot 'config\stack.psd1') -NoBrowser `
        -OperationLockHandle $operationLock -RecoveryMode -InProcess -ReturnResult)
    $text = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try { $document = $text | ConvertFrom-Json -ErrorAction Stop } catch { $document = $null }
    if ($null -eq $document -or -not [bool]$document.Success) {
        throw 'Canonical stack did not restart successfully after offline maintenance.'
    }
    return $document
}

function Test-MaintenanceDatabase {
    param([Parameter(Mandatory = $true)][string]$Database, [string]$BaselinePath)

    $arguments = @('-DatabasePath', $Database)
    if (-not [string]::IsNullOrWhiteSpace($BaselinePath)) { $arguments += @('-BaselineJsonPath', $BaselinePath) }
    $run = Invoke-BundledJson -Script (Join-Path $PSScriptRoot 'Test-ManagerData.ps1') -Arguments $arguments -AllowNonZero
    if ([int]$run.ExitCode -ne 0 -or -not [bool]$run.Json.success) {
        throw 'Manager database integrity or authoritative-data validation failed.'
    }
    return $run.Json
}

function Write-MaintenanceJournal {
    param([Parameter(Mandatory = $true)]$Journal, [Parameter(Mandatory = $true)][string]$Phase)

    $Journal.phase = $Phase
    $Journal.updatedAt = [DateTimeOffset]::Now.ToString('o')
    Write-CpaStackJson -Value $Journal -Path $journalPath
}

function New-MaintenanceBackup {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$OperationId)

    $staging = Join-Path $ControlRoot ('rollback\staging-maintenance-' + $OperationId)
    $pending = Join-Path $ControlRoot ('rollback\pending-maintenance-' + $OperationId)
    $backupDatabase = Join-Path $staging 'usage.sqlite'
    $backupResult = Join-Path $staging 'sqlite-backup.json'
    $backupDataKey = Join-Path $staging 'data.key'
    $manifestPath = Join-Path $staging 'manifest.json'
    foreach ($path in @($staging, $pending)) { Assert-CpaStackChildPath -Root $ControlRoot -Path $path }
    Assert-CpaStackPathBudget -Paths @($staging, $pending) -PathType Container
    Assert-CpaStackPathBudget -Paths @($backupDatabase, $backupResult, $backupDataKey, $manifestPath) -PathType Leaf
    Assert-CpaStackFreeSpace -Path $ControlRoot -MinimumBytes ([Math]::Max(1073741824L, ((Get-Item -LiteralPath $Context.Database).Length * 3L)))

    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    $baseline = Invoke-CpaStackSqliteBackup -Source $Context.Database -Destination $backupDatabase -ResultPath $backupResult
    Copy-Item -LiteralPath $Context.DataKey -Destination $backupDataKey
    $manifest = [ordered]@{
        schemaVersion = 1
        operation = 'cleanup-derived'
        operationId = $OperationId
        instanceId = $instanceId
        canonicalRoot = $ControlRoot
        executable = $Context.Executable
        executableSha256 = $Context.ExecutableHash
        database = $Context.Database
        backupDatabaseSha256 = Get-CpaStackFileHash -Path $backupDatabase
        dataKeySha256 = $Context.DataKeyHash
        managerPort = $Context.Port
        bindAddress = $Context.BindAddress
        capturedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-CpaStackJson -Value $manifest -Path $manifestPath
    Protect-CpaStackPrivateTree -Root $staging
    Move-CpaStackDirectoryWithRetry -SourcePath $staging -DestinationPath $pending
    return [pscustomobject]@{
        PendingPath = $pending
        BaselinePath = Join-Path $pending 'sqlite-backup.json'
        DatabasePath = Join-Path $pending 'usage.sqlite'
        Manifest = $manifest
        Baseline = $baseline
    }
}

function Read-MaintenanceBackup {
    param([Parameter(Mandatory = $true)]$Journal)

    if ([int]$Journal.schemaVersion -ne 1 -or [string]$Journal.operation -cne 'cleanup-derived' -or
        [string]$Journal.instanceId -cne $instanceId -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Journal.canonicalRoot), $ControlRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Maintenance journal does not match this canonical stack.'
    }

    $candidatePaths = @([string]$Journal.backupPath, [string]$Journal.retainedPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    foreach ($candidatePath in $candidatePaths) {
        $candidate = [System.IO.Path]::GetFullPath($candidatePath)
        Assert-CpaStackChildPath -Root $ControlRoot -Path $candidate
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        try {
            Assert-CpaStackPrivateTree -Root $candidate -Description 'Maintenance rollback backup' -AllowInheritedDescendants
            $manifest = Read-CpaStackJson -Path (Join-Path $candidate 'manifest.json')
            $backupDatabase = Join-Path $candidate 'usage.sqlite'
            $backupDataKey = Join-Path $candidate 'data.key'
            $manifestRoot = [System.IO.Path]::GetFullPath([string]$manifest.canonicalRoot).TrimEnd('\')
            $manifestExecutable = [System.IO.Path]::GetFullPath([string]$manifest.executable)
            $manifestDatabase = [System.IO.Path]::GetFullPath([string]$manifest.database)
            $expectedExecutable = Join-Path $ControlRoot 'runtime\manager-plus\cpa-manager-plus.exe'
            $expectedDatabase = Join-Path $ControlRoot 'data\manager-plus\usage.sqlite'
            if ([int]$manifest.schemaVersion -ne 1 -or
                [string]$manifest.operation -cne 'cleanup-derived' -or
                -not [string]::Equals($manifestRoot, $ControlRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($manifestExecutable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($manifestDatabase, $expectedDatabase, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]$manifest.operationId -cne [string]$Journal.operationId -or
                [string]$manifest.instanceId -cne $instanceId -or
                (Get-CpaStackFileHash -Path $backupDatabase) -cne [string]$manifest.backupDatabaseSha256 -or
                (Get-CpaStackFileHash -Path $backupDataKey) -cne [string]$manifest.dataKeySha256) {
                continue
            }
            [void](Test-MaintenanceDatabase -Database $backupDatabase)
            return [pscustomobject]@{
                PendingPath = $candidate
                BaselinePath = Join-Path $candidate 'sqlite-backup.json'
                DatabasePath = $backupDatabase
                Manifest = $manifest
            }
        } catch {
            continue
        }
    }
    throw 'Maintenance rollback backup failed its instance, path, or hash validation.'
}

function Restore-MaintenanceDatabase {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Backup)

    [void](Stop-MaintenanceManager -Context $Context)
    $restorePath = $Context.Database + '.maintenance-restore-' + [guid]::NewGuid().ToString('N')
    $failedPath = $Context.Database + '.maintenance-failed-' + [guid]::NewGuid().ToString('N')
    Assert-CpaStackChildPath -Root $ControlRoot -Path $restorePath
    Assert-CpaStackChildPath -Root $ControlRoot -Path $failedPath
    try {
        Copy-Item -LiteralPath $Backup.DatabasePath -Destination $restorePath
        if ((Get-CpaStackFileHash -Path $restorePath) -cne [string]$Backup.Manifest.backupDatabaseSha256) {
            throw 'Maintenance restore staging hash does not match the validated backup.'
        }
        foreach ($suffix in @('-wal', '-shm')) {
            $sidecar = $Context.Database + $suffix
            if (Test-Path -LiteralPath $sidecar -PathType Leaf) { Remove-Item -LiteralPath $sidecar -Force }
        }
        [System.IO.File]::Replace($restorePath, $Context.Database, $failedPath, $true)
        Protect-CpaStackSecretFile -Path $Context.Database
        Protect-CpaStackPrivateTree -Root $Context.DataDirectory
        if ((Get-CpaStackFileHash -Path $Context.Database) -cne [string]$Backup.Manifest.backupDatabaseSha256) {
            throw 'Restored Manager database hash does not match the validated backup.'
        }
        [void](Test-MaintenanceDatabase -Database $Context.Database -BaselinePath $Backup.BaselinePath)
        if (Test-Path -LiteralPath $failedPath -PathType Leaf) { Remove-Item -LiteralPath $failedPath -Force }
    } finally {
        if (Test-Path -LiteralPath $restorePath -PathType Leaf) { Remove-Item -LiteralPath $restorePath -Force -ErrorAction SilentlyContinue }
    }
}

function Retain-MaintenanceBackup {
    param([Parameter(Mandatory = $true)]$Backup, [Parameter(Mandatory = $true)][string]$OperationId)

    $retained = Join-Path $ControlRoot 'rollback\last-known-good\maintenance'
    $previous = $retained + '.previous-' + $OperationId
    Assert-CpaStackChildPath -Root $ControlRoot -Path $retained
    Assert-CpaStackChildPath -Root $ControlRoot -Path $previous
    $retainedParent = Split-Path -Parent $retained
    New-Item -ItemType Directory -Force -Path $retainedParent | Out-Null
    Protect-CpaStackPrivateDirectory -Path $retainedParent
    $source = [System.IO.Path]::GetFullPath([string]$Backup.PendingPath)
    if ([string]::Equals($source, [System.IO.Path]::GetFullPath($retained), [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.backupRetained = $true
        return $retained
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        if (Test-Path -LiteralPath $retained -PathType Container) {
            $manifest = Read-CpaStackJson -Path (Join-Path $retained 'manifest.json')
            if ([string]$manifest.operationId -ceq $OperationId -and [string]$manifest.instanceId -ceq $instanceId) {
                $result.backupRetained = $true
                return $retained
            }
        }
        throw 'Maintenance backup is missing from both pending and retained slots.'
    }
    $rotated = $false
    try {
        if (Test-Path -LiteralPath $retained -PathType Container) {
            Move-CpaStackDirectoryWithRetry -SourcePath $retained -DestinationPath $previous
            $rotated = $true
        }
        Move-CpaStackDirectoryWithRetry -SourcePath $source -DestinationPath $retained
    } catch {
        if ($rotated -and -not (Test-Path -LiteralPath $retained) -and (Test-Path -LiteralPath $previous -PathType Container)) {
            Move-CpaStackDirectoryWithRetry -SourcePath $previous -DestinationPath $retained
        }
        throw
    }
    if (Test-Path -LiteralPath $previous -PathType Container) {
        try { Remove-Item -LiteralPath $previous -Recurse -Force } catch { $result.warnings += 'The previous maintenance backup could not be removed.' }
    }
    $result.backupRetained = $true
    return $retained
}

function Complete-MaintenanceCommit {
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $retainedPath = Join-Path $ControlRoot 'rollback\last-known-good\maintenance'
    $Journal.retainedPath = $retainedPath
    Write-MaintenanceJournal -Journal $Journal -Phase committing
    $Journal.backupPath = Retain-MaintenanceBackup -Backup $Backup -OperationId $OperationId
    Write-MaintenanceJournal -Journal $Journal -Phase committed
    Remove-MaintenanceJournal
}

function Remove-MaintenanceJournal {
    foreach ($path in @($journalPreviousPath, $journalPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
}

function Recover-InterruptedMaintenance {
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return $false }
    $journal = Read-CpaStackJson -Path $journalPath
    if ([string]$journal.operationId -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$journal.phase -cnotin @('prepared', 'source-stopped', 'cleaned', 'validated', 'committing', 'committed')) {
        throw 'Maintenance journal has an invalid transaction identity or phase.'
    }
    $expectedBackup = Join-Path $ControlRoot ('rollback\pending-maintenance-' + $journal.operationId)
    $pendingArtifacts = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'state') -File -Filter '*.pending.json*' -Force)
    $pendingArtifacts += @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'rollback') -Directory -Filter 'pending-*' -Force)
    foreach ($artifact in $pendingArtifacts) {
        if ($artifact.FullName -notin @($journalPath, $journalPreviousPath, $expectedBackup)) {
            throw 'Maintenance recovery requires a single bound transaction.'
        }
    }
    if (Test-Path -LiteralPath $journalPreviousPath -PathType Leaf) {
        $previous = Read-CpaStackJson -Path $journalPreviousPath
        foreach ($field in @('schemaVersion', 'operation', 'operationId', 'instanceId', 'canonicalRoot')) {
            if ([string]$previous.$field -cne [string]$journal.$field) {
                throw 'Previous maintenance journal belongs to a different transaction.'
            }
        }
    }
    $backup = Read-MaintenanceBackup -Journal $journal
    $context = [pscustomobject]@{
        Executable = [System.IO.Path]::GetFullPath([string]$backup.Manifest.executable)
        ExecutableHash = [string]$backup.Manifest.executableSha256
        WorkingDirectory = Split-Path -Parent ([string]$backup.Manifest.executable)
        DataDirectory = Split-Path -Parent ([string]$backup.Manifest.database)
        Database = [System.IO.Path]::GetFullPath([string]$backup.Manifest.database)
        DataKey = Join-Path (Split-Path -Parent ([string]$backup.Manifest.database)) 'data.key'
        DataKeyHash = [string]$backup.Manifest.dataKeySha256
        Port = [int]$backup.Manifest.managerPort
        BindAddress = [string]$backup.Manifest.bindAddress
    }
    # A validated database may already be serving new writes after a restart/result failure.
    # Revalidate and commit it; restoring the old backup here would discard those writes.
    if ([string]$journal.phase -in @('validated', 'committing', 'committed')) {
        if ((Get-CpaStackFileHash -Path $context.Executable) -cne $context.ExecutableHash -or
            (Get-CpaStackFileHash -Path $context.DataKey) -cne $context.DataKeyHash) {
            throw 'Validated maintenance runtime or data.key no longer matches its bound transaction.'
        }
        [void](Test-MaintenanceDatabase -Database $context.Database -BaselinePath $backup.BaselinePath)
        $result.databaseVerified = $true
    } else {
        Restore-MaintenanceDatabase -Context $context -Backup $backup
        $result.rolledBack = $true
        $result.databaseVerified = $true
    }
    [void](Start-MaintenanceStack)
    Complete-MaintenanceCommit -Backup $backup -Journal $journal -OperationId ([string]$journal.operationId)
    $result.changed = $true
    $result.recovered = $true
    $result.managerRestarted = $true
    return $true
}

try {
    if ($Action -cne 'CleanupDerived') { throw 'Unsupported maintenance action.' }
    $ControlRoot = [System.IO.Path]::GetFullPath($ControlRoot).TrimEnd('\')
    $journalPath = Join-Path $ControlRoot 'state\maintenance.pending.json'
    $journalPreviousPath = $journalPath + '.previous'
    $resultPath = Join-Path $ControlRoot 'state\maintenance-result.json'
    $operationLock = Enter-CpaStackOperationLock
    Assert-CpaStackPath -Path $ControlRoot
    $instanceId = Get-MaintenanceInstanceId

    try {
        [void](Recover-InterruptedMaintenance)
    } catch {
        $result.error = New-MaintenanceError -Code 'MaintenanceRollbackFailed' `
            -Message 'Interrupted maintenance could not validate or recover its bound database backup.' `
            -Phase 'rollback' -Type $_.Exception.GetType().FullName
        throw
    }
    if ($RecoverOnly) {
        $result.success = $true
    } else {
        $state = Get-MaintenanceState
        $context = Get-MaintenanceContext -State $state
        $operationId = [guid]::NewGuid().ToString('N')
        $backup = New-MaintenanceBackup -Context $context -OperationId $operationId
        $journal = [pscustomobject][ordered]@{
            schemaVersion = 1
            operation = 'cleanup-derived'
            operationId = $operationId
            instanceId = $instanceId
            canonicalRoot = $ControlRoot
            phase = 'prepared'
            backupPath = $backup.PendingPath
            retainedPath = $null
            createdAt = [DateTimeOffset]::Now.ToString('o')
            updatedAt = [DateTimeOffset]::Now.ToString('o')
        }
        Write-MaintenanceJournal -Journal $journal -Phase prepared

        $failureStage = 'stop'
        try {
            $result.managerStopped = Stop-MaintenanceManager -Context $context -ExpectedProcessId $context.ProcessId
            if (-not $result.managerStopped) { throw 'Canonical Manager was not running at maintenance stop.' }
            Write-MaintenanceJournal -Journal $journal -Phase 'source-stopped'

            $failureStage = 'cleanup'
            $previousPreference = $ErrorActionPreference
            Push-Location -LiteralPath $context.WorkingDirectory
            try {
                $ErrorActionPreference = 'Continue'
                $cleanupOutput = @(& $context.Executable cleanup-derived --db-path $context.Database 2>&1)
                $cleanupExitCode = if ($null -eq $LASTEXITCODE) { if ($?) { 0 } else { 1 } } else { [int]$LASTEXITCODE }
            } finally {
                $ErrorActionPreference = $previousPreference
                Pop-Location
            }
            if ($cleanupExitCode -ne 0) {
                throw "Manager cleanup-derived failed. ExitCode=$cleanupExitCode."
            }
            $result.changed = $true
            Write-MaintenanceJournal -Journal $journal -Phase cleaned

            $failureStage = 'validation'
            if ((Get-CpaStackFileHash -Path $context.Executable) -cne $context.ExecutableHash -or
                (Get-CpaStackFileHash -Path $context.DataKey) -cne $context.DataKeyHash) {
                throw 'Manager executable or data.key changed during offline maintenance.'
            }
            [void](Test-MaintenanceDatabase -Database $context.Database -BaselinePath $backup.BaselinePath)
            $result.databaseVerified = $true
            Write-MaintenanceJournal -Journal $journal -Phase validated

            $failureStage = 'restart'
            [void](Start-MaintenanceStack)
            $result.managerRestarted = $true
            $failureStage = 'commit'
            Complete-MaintenanceCommit -Backup $backup -Journal $journal -OperationId $operationId
            $result.success = $true
        } catch {
            $maintenanceFailure = $_
            $maintenanceCode = [string]$maintenanceFailure.FullyQualifiedErrorId
            if ($maintenanceCode -like 'MaintenanceProcessChanged*') {
                try {
                    $validatedBackup = Read-MaintenanceBackup -Journal $journal
                    Complete-MaintenanceCommit -Backup $validatedBackup -Journal $journal -OperationId $operationId
                    $result.error = New-MaintenanceError -Code 'MaintenanceProcessChanged' `
                        -Message 'Manager process identity changed after preflight; maintenance stopped without touching the replacement process.' `
                        -Phase 'stop' -Type $maintenanceFailure.Exception.GetType().FullName
                } catch {
                    $result.error = New-MaintenanceError -Code 'MaintenanceRollbackFailed' `
                        -Message 'Manager identity changed and the prepared maintenance transaction could not be closed safely.' `
                        -Phase 'rollback' -Type $_.Exception.GetType().FullName
                }
            } elseif ($failureStage -ceq 'commit') {
                $result.error = New-MaintenanceError -Code 'MaintenanceCommitIncomplete' `
                    -Message 'Validated maintenance completed, but its journal commit did not finish; rerun maintenance to converge.' `
                    -Phase 'commit' -Type $maintenanceFailure.Exception.GetType().FullName
            } else {
                try {
                    $validatedBackup = Read-MaintenanceBackup -Journal $journal
                    Restore-MaintenanceDatabase -Context $context -Backup $validatedBackup
                    [void](Start-MaintenanceStack)
                    $result.managerRestarted = $true
                    Complete-MaintenanceCommit -Backup $validatedBackup -Journal $journal -OperationId $operationId
                    $result.rolledBack = $true
                    $result.changed = $false
                    $failureCode = switch ($failureStage) {
                        'stop' { 'MaintenanceStopFailed' }
                        'cleanup' { 'CleanupDerivedFailed' }
                        'validation' { 'MaintenanceValidationFailed' }
                        'restart' { 'MaintenanceRestartFailed' }
                        default { 'MaintenanceFailed' }
                    }
                    $result.error = New-MaintenanceError -Code $failureCode `
                        -Message "Offline maintenance failed during $failureStage and the validated database backup was restored." `
                        -Phase $failureStage -Type $maintenanceFailure.Exception.GetType().FullName
                } catch {
                    $result.rolledBack = $false
                    $result.error = New-MaintenanceError -Code 'MaintenanceRollbackFailed' `
                        -Message 'Offline maintenance failed and automatic database restoration did not complete.' `
                        -Phase 'rollback' -Type $_.Exception.GetType().FullName
                }
            }
        }
    }
} catch {
    if ($null -eq $result.error) {
        $result.error = New-MaintenanceError -Code 'MaintenancePreflightFailed' `
            -Message ('Offline maintenance could not pass its safety preflight: ' + $_.Exception.Message) `
            -Phase 'preflight' -Type $_.Exception.GetType().FullName
    }
} finally {
    try {
        if (Test-Path -LiteralPath (Split-Path -Parent $resultPath) -PathType Container) {
            Write-CpaStackJson -Value $result -Path $resultPath
        }
    } catch {
        $result.warnings += 'Maintenance result file could not be persisted.'
    }
    Exit-CpaStackOperationLock -Mutex $operationLock
}

$result | ConvertTo-Json -Depth 12 -Compress
if (-not $result.success) { exit 1 }
exit 0
