#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [ValidateSet('Loopback', 'Lan')][string]$Mode,
    [switch]$RecoverOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CpaStack.Common.ps1')

$hasMode = -not [string]::IsNullOrWhiteSpace($Mode)
if ([bool]$RecoverOnly -eq $hasMode) {
    throw 'Specify exactly one of -Mode or -RecoverOnly.'
}

$ControlRoot = Assert-CpaStackSecureLocalRoot -Path (Resolve-CpaStackControlRoot -RequestedRoot $ControlRoot)
$stackConfigPath = Join-Path $ControlRoot 'config\stack.psd1'
$currentPath = Join-Path $ControlRoot 'state\current.json'
$journalPath = Join-Path $ControlRoot 'state\lan.pending.json'
$operationId = [guid]::NewGuid().ToString('N')
$backupRoot = Join-Path $ControlRoot ('rollback\lan\' + $operationId)
$operationLock = $null
$switchStarted = $false
$pendingTransaction = $null
$expectedInstanceId = $null
$transactionBackupSnapshot = $null
$result = [ordered]@{
    success = $false
    changed = $false
    rolledBack = $false
    recoveredInterruptedState = $false
    mode = if ($RecoverOnly) { 'Recover' } else { $Mode }
    bindAddress = if ($RecoverOnly) { $null } elseif ($Mode -eq 'Lan') { '0.0.0.0' } else { '127.0.0.1' }
    cleanupWarning = $null
    error = $null
}

function Resolve-StackPath {
    param([string]$Value)
    if ([System.IO.Path]::IsPathRooted($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    return [System.IO.Path]::GetFullPath((Join-Path $ControlRoot $Value))
}

function Test-LanPathEqual {
    param([string]$Left, [string]$Right)

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd('\'),
        [System.IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-LanObjectValue {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-Utf8TextHash {
    param([Parameter(Mandatory = $true)][string]$Content)

    return Get-LanBytesHash -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Content))
}

function Get-LanBytesHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Assert-LanHash {
    param([string]$Value, [string]$Description)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "$Description is not a SHA256 value."
    }
    return $Value.ToUpperInvariant()
}

function Replace-SingleConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $matches = @($regex.Matches($Content))
    if ($matches.Count -ne 1) { throw "$Description must occur exactly once." }
    return $regex.Replace($Content, $Replacement, 1)
}

function Write-ProtectedTextAtomic {
    param([string]$Path, [string]$Content)

    Write-ProtectedBytesAtomic -Path $Path -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Content))
}

function Write-ProtectedBytesAtomic {
    param([string]$Path, [byte[]]$Bytes)

    $temp = $Path + '.new-' + [guid]::NewGuid().ToString('N')
    $replaceBackup = $Path + '.replace-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllBytes($temp, $Bytes)
        Protect-CpaStackSecretFile -Path $temp
        [System.IO.File]::Replace($temp, $Path, $replaceBackup)
        Protect-CpaStackSecretFile -Path $Path
        if (Test-Path -LiteralPath $replaceBackup) { [System.IO.File]::Delete($replaceBackup) }
    } finally {
        if (Test-Path -LiteralPath $temp) { [System.IO.File]::Delete($temp) }
        if (Test-Path -LiteralPath $replaceBackup) { [System.IO.File]::Delete($replaceBackup) }
    }
}

function Stop-ExpectedFormalProcess {
    param([int]$Port, [string]$ExpectedExecutable, [string]$ExpectedSha256)

    $listener = Get-CpaStackListener -Port $Port
    if (-not $listener) { return }
    if (-not (Test-LanPathEqual -Left ([string]$listener.ExecutablePath) -Right $ExpectedExecutable)) {
        throw "Unexpected process owns formal port $Port."
    }
    if ((Get-CpaStackFileHash -Path $ExpectedExecutable) -cne $ExpectedSha256) {
        throw "The executable on formal port $Port changed after the LAN transaction was prepared."
    }
    $process = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $ExpectedExecutable
    try {
        Stop-CpaStackPort -Port $Port -ExpectedPath $ExpectedExecutable -ExpectedProcess $process -RequireExecutableWriteAccess
    } finally {
        if ($process -is [System.IDisposable]) { $process.Dispose() }
    }
}

function Invoke-CanonicalStart {
    param([string]$ConfigPath)

    $output = @(& (Join-Path $PSScriptRoot 'Start-CPA-Stack.ps1') `
        -ConfigPath $ConfigPath `
        -NoBrowser `
        -OperationLockHandle $operationLock `
        -RecoveryMode `
        -InProcess 2>&1)
    $text = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $start = $text | ConvertFrom-Json
    if (-not [bool]$start.Success) { throw 'Canonical start did not report success.' }
    return $start
}

function Get-StackState {
    $output = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot 'Get-CpaStackState.ps1') -ControlRoot $ControlRoot 2>&1)
    $text = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Canonical status returned no JSON document.' }
    return $text | ConvertFrom-Json
}

function Assert-StackRuntimeHealthy {
    $state = Get-StackState
    $security = Get-LanObjectValue -Object $state -Name 'Security'
    $rootAcl = Get-LanObjectValue -Object $security -Name 'RootAcl'
    $managerData = Get-LanObjectValue -Object $security -Name 'ManagerDataTree'
    $integrity = Get-LanObjectValue -Object $security -Name 'Integrity'
    $cpa = Get-LanObjectValue -Object $state -Name 'Cpa'
    $manager = Get-LanObjectValue -Object $state -Name 'Manager'
    $pendingPaths = @(Get-LanObjectValue -Object $state -Name 'PendingOperations')
    $expectedJournal = [System.IO.Path]::GetFullPath($journalPath)
    $matchingPending = @($pendingPaths | Where-Object {
        Test-LanPathEqual -Left ([string]$_) -Right $expectedJournal
    })
    if (-not [bool](Get-LanObjectValue -Object $cpa -Name 'Healthy') -or
        -not [bool](Get-LanObjectValue -Object $manager -Name 'Healthy') -or
        -not [bool](Get-LanObjectValue -Object $rootAcl -Name 'Protected') -or
        -not [bool](Get-LanObjectValue -Object $managerData -Name 'Protected') -or
        -not [bool](Get-LanObjectValue -Object $integrity -Name 'Ready') -or
        $pendingPaths.Count -ne 1 -or $matchingPending.Count -ne 1) {
        throw 'Canonical stack did not satisfy the trusted runtime contract while the LAN journal was pending.'
    }
    return $state
}

function Get-LanCpaConfigPortFromText {
    param([Parameter(Mandatory = $true)][string]$Content)

    $matches = @([regex]::Matches($Content, '(?m)^port:\s*(?<port>\d+)\s*(?:#.*)?$'))
    if ($matches.Count -ne 1) { throw 'CPA config must contain exactly one explicit port.' }
    $port = 0
    if (-not [int]::TryParse($matches[0].Groups['port'].Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'CPA config contains an invalid port.'
    }
    return $port
}

function Get-LanCpaConfigHostFromText {
    param([Parameter(Mandatory = $true)][string]$Content)

    $matches = @([regex]::Matches($Content, '(?m)^host:\s*["'']?(?<host>[^"''#\s]+)'))
    if ($matches.Count -ne 1) { throw 'CPA config must contain exactly one explicit host.' }
    return [string]$matches[0].Groups['host'].Value
}

function Get-LanJournalMetadata {
    param($Journal)

    $operationId = [string](Get-LanObjectValue -Object $Journal -Name 'operationId')
    $instanceId = [string](Get-LanObjectValue -Object $Journal -Name 'instanceId')
    $phase = [string](Get-LanObjectValue -Object $Journal -Name 'phase')
    $mode = [string](Get-LanObjectValue -Object $Journal -Name 'mode')
    $oldCpaAddress = [string](Get-LanObjectValue -Object $Journal -Name 'oldCpaAddress')
    $oldManagerAddress = [string](Get-LanObjectValue -Object $Journal -Name 'oldManagerAddress')
    $newAddress = [string](Get-LanObjectValue -Object $Journal -Name 'newAddress')
    $createdAt = [string](Get-LanObjectValue -Object $Journal -Name 'createdAt')
    $updatedAt = [string](Get-LanObjectValue -Object $Journal -Name 'updatedAt')
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if ([int](Get-LanObjectValue -Object $Journal -Name 'schemaVersion') -ne 3 -or
        [string](Get-LanObjectValue -Object $Journal -Name 'operation') -cne 'set-lan-exposure' -or
        $operationId -notmatch '^[0-9a-fA-F]{32}$' -or
        $instanceId -notmatch '^[0-9a-fA-F]{32}$' -or
        [string]::IsNullOrWhiteSpace($expectedInstanceId) -or
        $instanceId -cne $expectedInstanceId -or
        $phase -notin @('prepared', 'configs-written', 'services-restarted', 'verified', 'recovering') -or
        $mode -notin @('Loopback', 'Lan') -or
        $newAddress -cne $(if ($mode -eq 'Lan') { '0.0.0.0' } else { '127.0.0.1' }) -or
        $oldCpaAddress -notin @('127.0.0.1', '0.0.0.0') -or
        $oldManagerAddress -notin @('127.0.0.1', '0.0.0.0') -or
        -not [DateTimeOffset]::TryParse($createdAt, [ref]$parsedTimestamp) -or
        -not [DateTimeOffset]::TryParse($updatedAt, [ref]$parsedTimestamp)) {
        throw 'LAN journal metadata is invalid or belongs to another transaction.'
    }

    $expectedBackupRoot = Join-Path $ControlRoot ('rollback\lan\' + $operationId)
    $expectedStackBackup = Join-Path $expectedBackupRoot 'stack.psd1'
    $expectedCpaBackup = Join-Path $expectedBackupRoot 'config.yaml'
    $expectedCpaRuntime = Join-Path $ControlRoot 'runtime\cli-proxy-api'
    $expectedCpaExecutable = Join-Path $expectedCpaRuntime 'cli-proxy-api.exe'
    $expectedCpaData = Join-Path $expectedCpaRuntime 'auth'
    $expectedCpaConfig = Join-Path $expectedCpaRuntime 'config.yaml'
    $expectedManagerRuntime = Join-Path $ControlRoot 'runtime\manager-plus'
    $expectedManagerExecutable = Join-Path $expectedManagerRuntime 'cpa-manager-plus.exe'
    $expectedManagerData = Join-Path $ControlRoot 'data\manager-plus'
    $expectedManagerConfig = $stackConfigPath
    $journalRoot = [string](Get-LanObjectValue -Object $Journal -Name 'canonicalRoot')
    $journalBackupRoot = [string](Get-LanObjectValue -Object $Journal -Name 'backupRoot')
    $journalStackConfig = [string](Get-LanObjectValue -Object $Journal -Name 'stackConfigPath')
    $journalCurrent = [string](Get-LanObjectValue -Object $Journal -Name 'currentPath')
    $journalCpaRuntime = [string](Get-LanObjectValue -Object $Journal -Name 'cpaRuntimePath')
    $journalCpaExecutable = [string](Get-LanObjectValue -Object $Journal -Name 'cpaExecutablePath')
    $journalCpaData = [string](Get-LanObjectValue -Object $Journal -Name 'cpaDataPath')
    $journalCpaConfig = [string](Get-LanObjectValue -Object $Journal -Name 'cpaConfigPath')
    $journalManagerRuntime = [string](Get-LanObjectValue -Object $Journal -Name 'managerRuntimePath')
    $journalManagerExecutable = [string](Get-LanObjectValue -Object $Journal -Name 'managerExecutablePath')
    $journalManagerData = [string](Get-LanObjectValue -Object $Journal -Name 'managerDataPath')
    $journalManagerConfig = [string](Get-LanObjectValue -Object $Journal -Name 'managerConfigPath')
    $cpaPort = [int](Get-LanObjectValue -Object $Journal -Name 'cpaPort')
    $managerPort = [int](Get-LanObjectValue -Object $Journal -Name 'managerPort')

    $fixedPaths = @(
        @($journalRoot, $ControlRoot),
        @($journalBackupRoot, $expectedBackupRoot),
        @($journalStackConfig, $stackConfigPath),
        @($journalCurrent, $currentPath),
        @($journalCpaRuntime, $expectedCpaRuntime),
        @($journalCpaExecutable, $expectedCpaExecutable),
        @($journalCpaData, $expectedCpaData),
        @($journalCpaConfig, $expectedCpaConfig),
        @($journalManagerRuntime, $expectedManagerRuntime),
        @($journalManagerExecutable, $expectedManagerExecutable),
        @($journalManagerData, $expectedManagerData),
        @($journalManagerConfig, $expectedManagerConfig)
    )
    foreach ($pair in $fixedPaths) {
        if (-not (Test-LanPathEqual -Left ([string]$pair[0]) -Right ([string]$pair[1]))) {
            throw 'LAN journal paths do not match the fixed canonical transaction slots.'
        }
    }
    foreach ($path in @(
        $expectedBackupRoot, $expectedStackBackup, $expectedCpaBackup, $stackConfigPath, $currentPath,
        $expectedCpaRuntime, $expectedCpaExecutable, $expectedCpaData, $expectedCpaConfig,
        $expectedManagerRuntime, $expectedManagerExecutable, $expectedManagerData
    )) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $path
    }
    if ($cpaPort -lt 1 -or $cpaPort -gt 65535 -or $managerPort -lt 1 -or $managerPort -gt 65535 -or $cpaPort -eq $managerPort) {
        throw 'LAN journal ports are invalid.'
    }

    $metadata = [pscustomobject][ordered]@{
        Journal = $Journal
        OperationId = $operationId.ToLowerInvariant()
        InstanceId = $instanceId.ToLowerInvariant()
        Phase = $phase
        Mode = $mode
        OldCpaAddress = $oldCpaAddress
        OldManagerAddress = $oldManagerAddress
        NewAddress = $newAddress
        CreatedAt = $createdAt
        BackupRoot = [System.IO.Path]::GetFullPath($expectedBackupRoot)
        StackBackup = [System.IO.Path]::GetFullPath($expectedStackBackup)
        CpaBackup = [System.IO.Path]::GetFullPath($expectedCpaBackup)
        StackConfig = [System.IO.Path]::GetFullPath($stackConfigPath)
        CurrentPath = [System.IO.Path]::GetFullPath($currentPath)
        CpaRuntime = [System.IO.Path]::GetFullPath($expectedCpaRuntime)
        CpaExecutable = [System.IO.Path]::GetFullPath($expectedCpaExecutable)
        CpaData = [System.IO.Path]::GetFullPath($expectedCpaData)
        CpaConfig = [System.IO.Path]::GetFullPath($expectedCpaConfig)
        CpaPort = $cpaPort
        ManagerRuntime = [System.IO.Path]::GetFullPath($expectedManagerRuntime)
        ManagerExecutable = [System.IO.Path]::GetFullPath($expectedManagerExecutable)
        ManagerData = [System.IO.Path]::GetFullPath($expectedManagerData)
        ManagerConfig = [System.IO.Path]::GetFullPath($expectedManagerConfig)
        ManagerPort = $managerPort
        StackBeforeHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'stackConfigBeforeSha256')) -Description 'LAN journal stack before hash'
        StackTargetHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'stackConfigTargetSha256')) -Description 'LAN journal stack target hash'
        CpaBeforeHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'cpaConfigBeforeSha256')) -Description 'LAN journal CPA before hash'
        CpaTargetHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'cpaConfigTargetSha256')) -Description 'LAN journal CPA target hash'
        CurrentHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'currentSha256')) -Description 'LAN journal current-state hash'
        CpaExecutableHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'cpaExecutableSha256')) -Description 'LAN journal CPA executable hash'
        ManagerExecutableHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'managerExecutableSha256')) -Description 'LAN journal Manager executable hash'
        BackupStackHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'backupStackSha256')) -Description 'LAN journal stack backup hash'
        BackupCpaHash = Assert-LanHash -Value ([string](Get-LanObjectValue -Object $Journal -Name 'backupCpaSha256')) -Description 'LAN journal CPA backup hash'
    }
    $metadata | Add-Member -NotePropertyName ImmutableFingerprint -NotePropertyValue (([ordered]@{
        operationId = $metadata.OperationId
        instanceId = $metadata.InstanceId
        canonicalRoot = $ControlRoot.ToLowerInvariant()
        mode = $metadata.Mode
        oldCpaAddress = $metadata.OldCpaAddress
        oldManagerAddress = $metadata.OldManagerAddress
        newAddress = $metadata.NewAddress
        createdAt = $metadata.CreatedAt
        backupRoot = $metadata.BackupRoot.ToLowerInvariant()
        stackConfig = $metadata.StackConfig.ToLowerInvariant()
        currentPath = $metadata.CurrentPath.ToLowerInvariant()
        cpaRuntime = $metadata.CpaRuntime.ToLowerInvariant()
        cpaExecutable = $metadata.CpaExecutable.ToLowerInvariant()
        cpaData = $metadata.CpaData.ToLowerInvariant()
        cpaConfig = $metadata.CpaConfig.ToLowerInvariant()
        cpaPort = $metadata.CpaPort
        managerRuntime = $metadata.ManagerRuntime.ToLowerInvariant()
        managerExecutable = $metadata.ManagerExecutable.ToLowerInvariant()
        managerData = $metadata.ManagerData.ToLowerInvariant()
        managerConfig = $metadata.ManagerConfig.ToLowerInvariant()
        managerPort = $metadata.ManagerPort
        stackBefore = $metadata.StackBeforeHash
        stackTarget = $metadata.StackTargetHash
        cpaBefore = $metadata.CpaBeforeHash
        cpaTarget = $metadata.CpaTargetHash
        current = $metadata.CurrentHash
        cpaExecutableHash = $metadata.CpaExecutableHash
        managerExecutableHash = $metadata.ManagerExecutableHash
        backupStack = $metadata.BackupStackHash
        backupCpa = $metadata.BackupCpaHash
    } | ConvertTo-Json -Compress))
    return $metadata
}

function Assert-LanStackDescriptor {
    param($Stack, $Metadata)

    $actual = [ordered]@{
        CpaRuntime = Resolve-StackPath -Value ([string]$Stack.Cpa.WorkingDirectory)
        CpaExecutable = Resolve-StackPath -Value ([string]$Stack.Cpa.Executable)
        CpaConfig = Resolve-StackPath -Value ([string]$Stack.Cpa.Config)
        CpaPort = [int]$Stack.Cpa.Port
        ManagerRuntime = Resolve-StackPath -Value ([string]$Stack.Manager.WorkingDirectory)
        ManagerExecutable = Resolve-StackPath -Value ([string]$Stack.Manager.Executable)
        ManagerData = Resolve-StackPath -Value ([string]$Stack.Manager.DataDirectory)
        ManagerPort = [int]$Stack.Manager.Port
    }
    foreach ($name in @('CpaRuntime', 'CpaExecutable', 'CpaConfig', 'ManagerRuntime', 'ManagerExecutable', 'ManagerData')) {
        if (-not (Test-LanPathEqual -Left ([string]$actual[$name]) -Right ([string]$Metadata.$name))) {
            throw "LAN stack descriptor changed its fixed $name slot."
        }
    }
    if ($actual.CpaPort -ne $Metadata.CpaPort -or $actual.ManagerPort -ne $Metadata.ManagerPort) {
        throw 'LAN stack descriptor changed a fixed formal port.'
    }
}

function Assert-LanCanonicalDescriptor {
    param($Metadata)

    foreach ($directory in @($Metadata.CpaRuntime, $Metadata.CpaData, $Metadata.ManagerRuntime, $Metadata.ManagerData)) {
        Assert-CpaStackPath -Path $directory
    }
    foreach ($file in @($Metadata.StackConfig, $Metadata.CurrentPath, $Metadata.CpaConfig, $Metadata.CpaExecutable, $Metadata.ManagerExecutable)) {
        Assert-CpaStackPath -Path $file -PathType Leaf
    }
    if ((Get-CpaStackFileHash -Path $Metadata.CurrentPath) -cne $Metadata.CurrentHash) {
        throw 'Current stack state changed after the LAN transaction was prepared.'
    }
    $currentState = Read-CpaStackJson -Path $Metadata.CurrentPath
    $currentCpa = Get-LanObjectValue -Object $currentState -Name 'cpa'
    $currentManager = Get-LanObjectValue -Object $currentState -Name 'manager'
    if ([string](Get-LanObjectValue -Object $currentState -Name 'instanceId') -cne $Metadata.InstanceId -or
        -not (Test-LanPathEqual -Left ([string](Get-LanObjectValue -Object $currentState -Name 'canonicalRoot')) -Right $ControlRoot) -or
        -not (Test-LanPathEqual -Left ([string](Get-LanObjectValue -Object $currentCpa -Name 'executable')) -Right $Metadata.CpaExecutable) -or
        -not (Test-LanPathEqual -Left ([string](Get-LanObjectValue -Object $currentManager -Name 'executable')) -Right $Metadata.ManagerExecutable) -or
        [string](Get-LanObjectValue -Object $currentCpa -Name 'sha256') -cne $Metadata.CpaExecutableHash -or
        [string](Get-LanObjectValue -Object $currentManager -Name 'sha256') -cne $Metadata.ManagerExecutableHash) {
        throw 'Current stack state does not match the immutable LAN runtime descriptor.'
    }
    if ((Get-CpaStackFileHash -Path $Metadata.CpaExecutable) -cne $Metadata.CpaExecutableHash -or
        (Get-CpaStackFileHash -Path $Metadata.ManagerExecutable) -cne $Metadata.ManagerExecutableHash) {
        throw 'A canonical executable changed after the LAN transaction was prepared.'
    }

    $activeStackHash = Get-CpaStackFileHash -Path $Metadata.StackConfig
    $activeCpaHash = Get-CpaStackFileHash -Path $Metadata.CpaConfig
    if ($activeStackHash -notin @($Metadata.StackBeforeHash, $Metadata.StackTargetHash) -or
        $activeCpaHash -notin @($Metadata.CpaBeforeHash, $Metadata.CpaTargetHash)) {
        throw 'Active LAN configuration does not match either the recorded before or target state.'
    }
    $activeStack = Import-PowerShellDataFile -LiteralPath $Metadata.StackConfig
    Assert-LanStackDescriptor -Stack $activeStack -Metadata $Metadata
    $cpaText = [System.IO.File]::ReadAllText($Metadata.CpaConfig, [System.Text.UTF8Encoding]::new($false, $true))
    if ((Get-LanCpaConfigPortFromText -Content $cpaText) -ne $Metadata.CpaPort -or
        (Get-LanCpaConfigHostFromText -Content $cpaText) -notin @($Metadata.OldCpaAddress, $Metadata.NewAddress) -or
        [string]$activeStack.Manager.BindAddress -notin @($Metadata.OldManagerAddress, $Metadata.NewAddress)) {
        throw 'Active LAN configuration changed a fixed port or contains an unrecorded bind address.'
    }

    $otherStatePending = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'state') -File -Filter '*.pending.json' -ErrorAction SilentlyContinue | Where-Object {
        -not (Test-LanPathEqual -Left $_.FullName -Right $journalPath)
    })
    $otherRollbackPending = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'rollback') -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue)
    if ($otherStatePending.Count -gt 0 -or $otherRollbackPending.Count -gt 0) {
        throw 'LAN recovery found another pending stack transaction.'
    }
    return [pscustomobject]@{
        ActiveStackHash = $activeStackHash
        ActiveCpaHash = $activeCpaHash
    }
}

function Read-LanJournalArtifact {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $memory = [System.IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally {
            $memory.Dispose()
        }
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = $text | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($Path)
            Hash = Get-LanBytesHash -Bytes $bytes
            Document = $document
            Text = $text
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-LanPhasePair {
    param([string]$CurrentPhase, [string]$PreviousPhase, [bool]$HasPrevious)

    $valid = switch ($CurrentPhase) {
        'prepared' { -not $HasPrevious }
        'configs-written' { $HasPrevious -and $PreviousPhase -ceq 'prepared' }
        'services-restarted' { $HasPrevious -and $PreviousPhase -ceq 'configs-written' }
        'verified' { $HasPrevious -and $PreviousPhase -ceq 'services-restarted' }
        'recovering' { $HasPrevious -and $PreviousPhase -in @('prepared', 'configs-written', 'services-restarted', 'verified') }
        default { $false }
    }
    if (-not $valid) { throw 'LAN current/.previous journals do not form a legal adjacent phase pair.' }
}

function Read-ValidatedLanJournalPair {
    param([switch]$AllowAbsent)

    $previousPath = $journalPath + '.previous'
    $hasCurrent = Test-Path -LiteralPath $journalPath -PathType Leaf
    $hasPrevious = Test-Path -LiteralPath $previousPath -PathType Leaf
    if (-not $hasCurrent) {
        if ($hasPrevious) { throw 'An orphaned LAN .previous journal requires manual recovery.' }
        if ($AllowAbsent) { return $null }
        throw 'The LAN transaction journal is missing.'
    }

    $currentArtifact = Read-LanJournalArtifact -Path $journalPath
    $currentMetadata = Get-LanJournalMetadata -Journal $currentArtifact.Document
    $previousArtifact = $null
    $previousMetadata = $null
    if ($hasPrevious) {
        $previousArtifact = Read-LanJournalArtifact -Path $previousPath
        $previousMetadata = Get-LanJournalMetadata -Journal $previousArtifact.Document
        if ($currentMetadata.ImmutableFingerprint -cne $previousMetadata.ImmutableFingerprint) {
            throw 'LAN current/.previous journals belong to different immutable transactions.'
        }
    }
    Assert-LanPhasePair -CurrentPhase $currentMetadata.Phase -PreviousPhase $(if ($previousMetadata) { $previousMetadata.Phase } else { $null }) -HasPrevious $hasPrevious
    $active = Assert-LanCanonicalDescriptor -Metadata $currentMetadata
    return [pscustomobject]@{
        Current = $currentArtifact
        Previous = $previousArtifact
        Metadata = $currentMetadata
        ActiveStackHash = $active.ActiveStackHash
        ActiveCpaHash = $active.ActiveCpaHash
    }
}

function Assert-LanBoundJournalPair {
    param($Bound)

    $actual = Read-ValidatedLanJournalPair
    if ($actual.Current.Hash -cne $Bound.Current.Hash -or
        (($null -eq $actual.Previous) -ne ($null -eq $Bound.Previous)) -or
        ($null -ne $actual.Previous -and $actual.Previous.Hash -cne $Bound.Previous.Hash)) {
        throw 'LAN journal artifacts changed after their descriptors were fixed.'
    }
    return $actual
}

function Write-LanJournal {
    param($Journal)

    if ($null -ne (Read-ValidatedLanJournalPair -AllowAbsent)) {
        throw 'A LAN configuration transaction is already pending.'
    }
    $metadata = Get-LanJournalMetadata -Journal $Journal
    if ($metadata.Phase -cne 'prepared') { throw 'A new LAN journal must start in the prepared phase.' }
    [void](Assert-LanCanonicalDescriptor -Metadata $metadata)
    Write-CpaStackJson -Value $Journal -Path $journalPath
    Protect-CpaStackSecretFile -Path $journalPath
    $written = Read-ValidatedLanJournalPair
    if ($written.Metadata.Phase -cne 'prepared' -or $null -ne $written.Previous) {
        throw 'The prepared LAN journal did not persist as a single validated artifact.'
    }
}

function Set-LanJournalPhase {
    param($Journal, [string]$Phase)

    $before = Read-ValidatedLanJournalPair
    $requested = Get-LanJournalMetadata -Journal $Journal
    if ($requested.ImmutableFingerprint -cne $before.Metadata.ImmutableFingerprint) {
        throw 'The in-memory LAN transaction no longer matches the persisted journal.'
    }
    if ($before.Metadata.Phase -ceq $Phase) {
        $Journal.phase = $Phase
        return
    }
    $allowed = switch ($before.Metadata.Phase) {
        'prepared' { $Phase -in @('configs-written', 'recovering') }
        'configs-written' { $Phase -in @('services-restarted', 'recovering') }
        'services-restarted' { $Phase -in @('verified', 'recovering') }
        'verified' { $Phase -ceq 'recovering' }
        default { $false }
    }
    if (-not $allowed) { throw "Illegal LAN journal phase transition: $($before.Metadata.Phase) -> $Phase." }

    $updated = $before.Current.Text | ConvertFrom-Json -ErrorAction Stop
    $updated.phase = $Phase
    $updated.updatedAt = [DateTimeOffset]::Now.ToString('o')
    Write-CpaStackJson -Value $updated -Path $journalPath
    Protect-CpaStackSecretFile -Path $journalPath
    $after = Read-ValidatedLanJournalPair
    if ($after.Metadata.Phase -cne $Phase -or $null -eq $after.Previous -or $after.Previous.Hash -cne $before.Current.Hash) {
        throw 'LAN journal phase rotation did not preserve the validated predecessor.'
    }
    $Journal.phase = $Phase
    $Journal.updatedAt = [string]$updated.updatedAt
}

function Open-LanBackupSnapshot {
    param($Metadata)

    $stackStream = $null
    $cpaStream = $null
    try {
        Assert-CpaStackPath -Path $Metadata.BackupRoot
        Assert-CpaStackPath -Path $Metadata.StackBackup -PathType Leaf
        Assert-CpaStackPath -Path $Metadata.CpaBackup -PathType Leaf
        Assert-CpaStackPrivateTree -Root $Metadata.BackupRoot
        $stackStream = [System.IO.File]::Open($Metadata.StackBackup, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $cpaStream = [System.IO.File]::Open($Metadata.CpaBackup, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $stackMemory = [System.IO.MemoryStream]::new()
        $cpaMemory = [System.IO.MemoryStream]::new()
        try {
            $stackStream.CopyTo($stackMemory)
            $cpaStream.CopyTo($cpaMemory)
            $stackBytes = $stackMemory.ToArray()
            $cpaBytes = $cpaMemory.ToArray()
        } finally {
            $stackMemory.Dispose()
            $cpaMemory.Dispose()
        }
        $stackText = [System.Text.UTF8Encoding]::new($false, $true).GetString($stackBytes)
        $cpaText = [System.Text.UTF8Encoding]::new($false, $true).GetString($cpaBytes)
        if ((Get-LanBytesHash -Bytes $stackBytes) -cne $Metadata.BackupStackHash -or
            (Get-LanBytesHash -Bytes $cpaBytes) -cne $Metadata.BackupCpaHash -or
            $Metadata.BackupStackHash -cne $Metadata.StackBeforeHash -or
            $Metadata.BackupCpaHash -cne $Metadata.CpaBeforeHash) {
            throw 'LAN backup hashes do not match the write-ahead journal.'
        }
        $backupStack = Import-PowerShellDataFile -LiteralPath $Metadata.StackBackup
        Assert-LanStackDescriptor -Stack $backupStack -Metadata $Metadata
        if ([string]$backupStack.Manager.BindAddress -cne $Metadata.OldManagerAddress -or
            (Get-LanCpaConfigHostFromText -Content $cpaText) -cne $Metadata.OldCpaAddress -or
            (Get-LanCpaConfigPortFromText -Content $cpaText) -ne $Metadata.CpaPort) {
            throw 'LAN backups do not contain the recorded pre-transaction addresses and port.'
        }
        return [pscustomobject]@{
            StackStream = $stackStream
            CpaStream = $cpaStream
            StackBytes = $stackBytes
            CpaBytes = $cpaBytes
            StackText = $stackText
            CpaText = $cpaText
            StackHash = $Metadata.BackupStackHash
            CpaHash = $Metadata.BackupCpaHash
        }
    } catch {
        if ($null -ne $stackStream) { $stackStream.Dispose() }
        if ($null -ne $cpaStream) { $cpaStream.Dispose() }
        throw
    }
}

function Assert-LanBackupSnapshotLocked {
    param($Snapshot, $Metadata)

    if ($null -eq $Snapshot -or $null -eq $Snapshot.StackStream -or $null -eq $Snapshot.CpaStream -or
        -not $Snapshot.StackStream.CanRead -or -not $Snapshot.CpaStream.CanRead -or
        $Snapshot.StackHash -cne $Metadata.BackupStackHash -or $Snapshot.CpaHash -cne $Metadata.BackupCpaHash) {
        throw 'The fixed LAN backup snapshot is no longer locked and usable.'
    }
}

function Close-LanBackupSnapshot {
    param($Snapshot)

    if ($null -eq $Snapshot) { return }
    if ($null -ne $Snapshot.StackStream) { $Snapshot.StackStream.Dispose() }
    if ($null -ne $Snapshot.CpaStream) { $Snapshot.CpaStream.Dispose() }
}

function Remove-LanJournalArtifacts {
    param($Bound)

    $actual = Assert-LanBoundJournalPair -Bound $Bound
    if ($null -ne $actual.Previous) {
        if ((Get-CpaStackFileHash -Path $actual.Previous.Path) -cne $actual.Previous.Hash) {
            throw 'The LAN previous journal changed before cleanup.'
        }
        Remove-Item -LiteralPath $actual.Previous.Path -Force -ErrorAction Stop
    }
    if ((Get-CpaStackFileHash -Path $actual.Current.Path) -cne $actual.Current.Hash) {
        throw 'The LAN current journal changed before cleanup.'
    }
    Remove-Item -LiteralPath $actual.Current.Path -Force -ErrorAction Stop
    if ((Test-Path -LiteralPath $journalPath) -or (Test-Path -LiteralPath ($journalPath + '.previous'))) {
        throw 'LAN journal cleanup did not remove the hash-bound artifacts.'
    }
}

function Remove-LanBackupBestEffort {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        $result.cleanupWarning = $_.Exception.Message
    }
}

function Invoke-LanRecoveryFromJournal {
    param($Journal)

    $trusted = Read-ValidatedLanJournalPair
    $requested = Get-LanJournalMetadata -Journal $Journal
    if ($requested.ImmutableFingerprint -cne $trusted.Metadata.ImmutableFingerprint) {
        throw 'The requested LAN recovery does not match the validated pending transaction.'
    }
    $backupSnapshot = Open-LanBackupSnapshot -Metadata $trusted.Metadata
    try {
        Set-LanJournalPhase -Journal $Journal -Phase 'recovering'
        $trusted = Read-ValidatedLanJournalPair
        Assert-LanBackupSnapshotLocked -Snapshot $backupSnapshot -Metadata $trusted.Metadata
        $requiresRestore = ($trusted.ActiveStackHash -cne $trusted.Metadata.StackBeforeHash -or
            $trusted.ActiveCpaHash -cne $trusted.Metadata.CpaBeforeHash)
        $alreadyHealthy = $false
        if (-not $requiresRestore) {
            try {
                [void](Assert-StackRuntimeHealthy)
                $alreadyHealthy = $true
            } catch {
                $alreadyHealthy = $false
            }
        }

        if ($requiresRestore -or -not $alreadyHealthy) {
            [void](Assert-LanBoundJournalPair -Bound $trusted)
            Assert-LanBackupSnapshotLocked -Snapshot $backupSnapshot -Metadata $trusted.Metadata
            Stop-ExpectedFormalProcess -Port $trusted.Metadata.ManagerPort `
                -ExpectedExecutable $trusted.Metadata.ManagerExecutable `
                -ExpectedSha256 $trusted.Metadata.ManagerExecutableHash

            [void](Assert-LanBoundJournalPair -Bound $trusted)
            Assert-LanBackupSnapshotLocked -Snapshot $backupSnapshot -Metadata $trusted.Metadata
            Stop-ExpectedFormalProcess -Port $trusted.Metadata.CpaPort `
                -ExpectedExecutable $trusted.Metadata.CpaExecutable `
                -ExpectedSha256 $trusted.Metadata.CpaExecutableHash

            [void](Assert-LanBoundJournalPair -Bound $trusted)
            Assert-LanBackupSnapshotLocked -Snapshot $backupSnapshot -Metadata $trusted.Metadata
            if ($requiresRestore) {
                [void](Assert-LanBoundJournalPair -Bound $trusted)
                Write-ProtectedBytesAtomic -Path $trusted.Metadata.StackConfig -Bytes $backupSnapshot.StackBytes
                [void](Assert-LanBoundJournalPair -Bound $trusted)
                Write-ProtectedBytesAtomic -Path $trusted.Metadata.CpaConfig -Bytes $backupSnapshot.CpaBytes
                [void](Assert-LanBoundJournalPair -Bound $trusted)
            }
            [void](Invoke-CanonicalStart -ConfigPath $trusted.Metadata.StackConfig)
        }
        [void](Assert-StackRuntimeHealthy)
        $cleanupBound = Read-ValidatedLanJournalPair
        Remove-LanJournalArtifacts -Bound $cleanupBound
        Close-LanBackupSnapshot -Snapshot $backupSnapshot
        $backupSnapshot = $null
        Remove-LanBackupBestEffort -Path $trusted.Metadata.BackupRoot
        $result.success = $true
        $result.changed = $true
        $result.rolledBack = $true
        $result.recoveredInterruptedState = $true
        $result.mode = 'Recover'
        $result.bindAddress = if ($trusted.Metadata.OldCpaAddress -eq $trusted.Metadata.OldManagerAddress) { $trusted.Metadata.OldCpaAddress } else { $null }
    } finally {
        Close-LanBackupSnapshot -Snapshot $backupSnapshot
    }
}

try {
    foreach ($path in @($stackConfigPath, $currentPath, $journalPath, $backupRoot)) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $path
    }
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 5
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
    $current = Read-CpaStackJson -Path $currentPath
    if ([string]$current.instanceId -ne [string]$marker.instanceId -or
        -not (Test-LanPathEqual -Left ([string]$current.canonicalRoot) -Right $ControlRoot)) {
        throw 'Canonical state does not match the requested instance.'
    }
    $expectedInstanceId = [string]$marker.instanceId

    if ($RecoverOnly) {
        $existingLanTransaction = Read-ValidatedLanJournalPair -AllowAbsent
        if ($null -eq $existingLanTransaction) {
            $result.success = $true
        } else {
            $pendingTransaction = $existingLanTransaction.Current.Document
            Invoke-LanRecoveryFromJournal -Journal $pendingTransaction
        }
    } else {
        $existingLanTransaction = Read-ValidatedLanJournalPair -AllowAbsent
        if ($null -ne $existingLanTransaction) { throw 'A LAN configuration transaction is already pending.' }

        $stack = Get-CpaStackConfig -ControlRoot $ControlRoot
        $cpaConfigPath = Resolve-StackPath -Value ([string]$stack.Cpa.Config)
        Assert-CpaStackChildPath -Root $ControlRoot -Path $cpaConfigPath
        Assert-CpaStackPath -Path $stackConfigPath -PathType Leaf
        Assert-CpaStackPath -Path $cpaConfigPath -PathType Leaf
        $targetAddress = [string]$result.bindAddress
        $currentCpaAddress = Get-CpaStackConfigHost -ConfigPath $cpaConfigPath
        $currentManagerAddress = [string]$stack.Manager.BindAddress
        $pending = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'state') -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
        $rollbackPending = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'rollback') -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue)
        if ($pending.Count -gt 0 -or $rollbackPending.Count -gt 0) {
            throw "Another stack transaction is pending: $(@($pending.Name) + @($rollbackPending.Name) -join ', ')"
        }
        $baselineState = Get-StackState
        if (-not [bool](Get-LanObjectValue -Object $baselineState -Name 'OverallHealthy')) {
            throw 'Canonical stack must be healthy before confirming or changing LAN configuration.'
        }
        if ($currentCpaAddress -eq $targetAddress -and $currentManagerAddress -eq $targetAddress) {
            $result.success = $true
        } else {
            $stackBytes = [System.IO.File]::ReadAllBytes($stackConfigPath)
            $cpaBytes = [System.IO.File]::ReadAllBytes($cpaConfigPath)
            $stackText = [System.Text.UTF8Encoding]::new($false, $true).GetString($stackBytes)
            $cpaText = [System.Text.UTF8Encoding]::new($false, $true).GetString($cpaBytes)
            $newStackText = Replace-SingleConfigValue -Content $stackText `
                -Pattern "^\s*BindAddress\s*=\s*'[^']*'\s*$" `
                -Replacement ("        BindAddress = '" + $targetAddress + "'") `
                -Description 'Manager BindAddress setting'
            $newCpaText = Replace-SingleConfigValue -Content $cpaText `
                -Pattern '^host:\s*["'']?[^"''#\s]+["'']?\s*(?:#.*)?$' `
                -Replacement ('host: "' + $targetAddress + '"') `
                -Description 'CPA host setting'

            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            Protect-CpaStackPrivateDirectory -Path $backupRoot
            $stackBackup = Join-Path $backupRoot 'stack.psd1'
            $cpaBackup = Join-Path $backupRoot 'config.yaml'
            [System.IO.File]::WriteAllBytes($stackBackup, $stackBytes)
            [System.IO.File]::WriteAllBytes($cpaBackup, $cpaBytes)
            Protect-CpaStackSecretFile -Path $stackBackup
            Protect-CpaStackSecretFile -Path $cpaBackup
            Assert-CpaStackPrivateTree -Root $backupRoot

            $cpaRuntime = Resolve-StackPath -Value ([string]$stack.Cpa.WorkingDirectory)
            $cpaExe = Resolve-StackPath -Value ([string]$stack.Cpa.Executable)
            $cpaData = Join-Path $cpaRuntime 'auth'
            $managerRuntime = Resolve-StackPath -Value ([string]$stack.Manager.WorkingDirectory)
            $managerExe = Resolve-StackPath -Value ([string]$stack.Manager.Executable)
            $managerData = Resolve-StackPath -Value ([string]$stack.Manager.DataDirectory)
            $now = [DateTimeOffset]::Now.ToString('o')
            $pendingTransaction = [pscustomobject][ordered]@{
                schemaVersion = 3
                operation = 'set-lan-exposure'
                operationId = $operationId
                instanceId = [string]$marker.instanceId
                canonicalRoot = $ControlRoot
                phase = 'prepared'
                mode = $Mode
                oldCpaAddress = $currentCpaAddress
                oldManagerAddress = $currentManagerAddress
                newAddress = $targetAddress
                backupRoot = $backupRoot
                stackConfigPath = $stackConfigPath
                currentPath = $currentPath
                cpaRuntimePath = $cpaRuntime
                cpaExecutablePath = $cpaExe
                cpaDataPath = $cpaData
                cpaConfigPath = $cpaConfigPath
                cpaPort = [int]$stack.Cpa.Port
                managerRuntimePath = $managerRuntime
                managerExecutablePath = $managerExe
                managerDataPath = $managerData
                managerConfigPath = $stackConfigPath
                managerPort = [int]$stack.Manager.Port
                stackConfigBeforeSha256 = Get-LanBytesHash -Bytes $stackBytes
                stackConfigTargetSha256 = Get-Utf8TextHash -Content $newStackText
                cpaConfigBeforeSha256 = Get-LanBytesHash -Bytes $cpaBytes
                cpaConfigTargetSha256 = Get-Utf8TextHash -Content $newCpaText
                currentSha256 = Get-CpaStackFileHash -Path $currentPath
                cpaExecutableSha256 = Get-CpaStackFileHash -Path $cpaExe
                managerExecutableSha256 = Get-CpaStackFileHash -Path $managerExe
                backupStackSha256 = Get-CpaStackFileHash -Path $stackBackup
                backupCpaSha256 = Get-CpaStackFileHash -Path $cpaBackup
                createdAt = $now
                updatedAt = $now
            }
            Write-LanJournal -Journal $pendingTransaction
            $switchStarted = $true
            $prepared = Read-ValidatedLanJournalPair
            $transactionBackupSnapshot = Open-LanBackupSnapshot -Metadata $prepared.Metadata

            [void](Assert-LanBoundJournalPair -Bound $prepared)
            Assert-LanBackupSnapshotLocked -Snapshot $transactionBackupSnapshot -Metadata $prepared.Metadata
            Write-ProtectedTextAtomic -Path $stackConfigPath -Content $newStackText
            [void](Assert-LanBoundJournalPair -Bound $prepared)
            Assert-LanBackupSnapshotLocked -Snapshot $transactionBackupSnapshot -Metadata $prepared.Metadata
            Write-ProtectedTextAtomic -Path $cpaConfigPath -Content $newCpaText
            [void](Assert-LanBoundJournalPair -Bound $prepared)
            Set-LanJournalPhase -Journal $pendingTransaction -Phase 'configs-written'

            $stopBound = Read-ValidatedLanJournalPair
            Assert-LanBackupSnapshotLocked -Snapshot $transactionBackupSnapshot -Metadata $stopBound.Metadata
            [void](Assert-LanBoundJournalPair -Bound $stopBound)
            Stop-ExpectedFormalProcess -Port $stopBound.Metadata.ManagerPort `
                -ExpectedExecutable $stopBound.Metadata.ManagerExecutable `
                -ExpectedSha256 $stopBound.Metadata.ManagerExecutableHash
            [void](Assert-LanBoundJournalPair -Bound $stopBound)
            Assert-LanBackupSnapshotLocked -Snapshot $transactionBackupSnapshot -Metadata $stopBound.Metadata
            Stop-ExpectedFormalProcess -Port $stopBound.Metadata.CpaPort `
                -ExpectedExecutable $stopBound.Metadata.CpaExecutable `
                -ExpectedSha256 $stopBound.Metadata.CpaExecutableHash
            [void](Assert-LanBoundJournalPair -Bound $stopBound)
            Assert-LanBackupSnapshotLocked -Snapshot $transactionBackupSnapshot -Metadata $stopBound.Metadata
            [void](Invoke-CanonicalStart -ConfigPath $stackConfigPath)
            Set-LanJournalPhase -Journal $pendingTransaction -Phase 'services-restarted'
            [void](Assert-StackRuntimeHealthy)
            Set-LanJournalPhase -Journal $pendingTransaction -Phase 'verified'
            $cleanupBound = Read-ValidatedLanJournalPair
            Remove-LanJournalArtifacts -Bound $cleanupBound
            Close-LanBackupSnapshot -Snapshot $transactionBackupSnapshot
            $transactionBackupSnapshot = $null
            Remove-LanBackupBestEffort -Path $backupRoot
            $result.success = $true
            $result.changed = $true
        }
    }
}
catch {
    $failure = $_.Exception.Message
    Close-LanBackupSnapshot -Snapshot $transactionBackupSnapshot
    $transactionBackupSnapshot = $null
    if (-not $RecoverOnly -and $switchStarted -and (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        try {
            $pendingTransaction = Read-CpaStackJson -Path $journalPath
            Invoke-LanRecoveryFromJournal -Journal $pendingTransaction
            $result.success = $false
            $result.changed = $false
            $result.recoveredInterruptedState = $false
            $result.mode = $Mode
            $result.bindAddress = if ($Mode -eq 'Lan') { '0.0.0.0' } else { '127.0.0.1' }
        } catch {
            $failure += ' Automatic LAN rollback also failed: ' + $_.Exception.Message
        }
    }
    if (-not $result.success) {
        $result.error = [ordered]@{
            code = if ($result.rolledBack) { 'LanApplyFailedRolledBack' } elseif ($RecoverOnly -or $switchStarted) { 'LanRecoveryFailed' } else { 'LanConfigurationFailed' }
            message = $failure
        }
    }
}
finally {
    Close-LanBackupSnapshot -Snapshot $transactionBackupSnapshot
    Exit-CpaStackOperationLock -Mutex $operationLock
}

$result | ConvertTo-Json -Depth 8 -Compress
if ($result.success) { exit 0 }
exit 1
