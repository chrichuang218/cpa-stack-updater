Set-StrictMode -Version 2.0

function Get-CpaStackWindowsPowerShellModulePath {
    $paths = @()
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if (-not [string]::IsNullOrWhiteSpace($documents)) {
        $paths += Join-Path $documents 'WindowsPowerShell\Modules'
    }
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $paths += Join-Path $programFiles 'WindowsPowerShell\Modules'
    }
    $windows = [Environment]::GetFolderPath('Windows')
    if (-not [string]::IsNullOrWhiteSpace($windows)) {
        $paths += Join-Path $windows 'System32\WindowsPowerShell\v1.0\Modules'
    }
    if ($paths.Count -eq 0) { throw 'Windows PowerShell module paths are unavailable.' }
    return (@($paths | Select-Object -Unique) -join [System.IO.Path]::PathSeparator)
}

function Get-CpaStackUpdaterVersion {
    param([switch]$Optional)

    $versionPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        if ($Optional) { return $null }
        throw "CPA Stack Updater version file is missing: $versionPath"
    }
    $version = [System.IO.File]::ReadAllText($versionPath, [System.Text.UTF8Encoding]::new($false, $true)).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw 'CPA Stack Updater version is invalid.'
    }
    return $version
}

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = Get-CpaStackWindowsPowerShellModulePath
}

function Get-CpaStackDefaultRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CPA_STACK_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:CPA_STACK_ROOT)
    }

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'LOCALAPPDATA is unavailable. Pass -ControlRoot or set CPA_STACK_ROOT.'
    }
    return Join-Path $localAppData 'CPAStack'
}

function Get-CpaStackRootLocatorPath {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'LOCALAPPDATA is unavailable.'
    }
    return Join-Path $localAppData 'CPAStack\root.json'
}

function Resolve-CpaStackControlRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        return [System.IO.Path]::GetFullPath($RequestedRoot).TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CPA_STACK_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:CPA_STACK_ROOT).TrimEnd('\')
    }
    $locatorPath = Get-CpaStackRootLocatorPath
    if (Test-Path -LiteralPath $locatorPath -PathType Leaf) {
        $locator = Read-CpaStackJson -Path $locatorPath
        if ($null -eq $locator.PSObject.Properties['root'] -or [string]::IsNullOrWhiteSpace([string]$locator.root)) {
            throw "CPA stack root locator is invalid: $locatorPath"
        }
        return [System.IO.Path]::GetFullPath([string]$locator.root).TrimEnd('\')
    }
    return (Get-CpaStackDefaultRoot).TrimEnd('\')
}

function Set-CpaStackRegisteredRoot {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    $locatorPath = Get-CpaStackRootLocatorPath
    $parent = Split-Path -Parent $locatorPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $payload = [ordered]@{
        schemaVersion = 1
        root = $root
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-CpaStackJson -Value $payload -Path $locatorPath
    Protect-CpaStackSecretFile -Path $locatorPath
}

function Assert-CpaStackSecureLocalRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) {
        throw "CPA stack data must be stored on a local ACL-capable volume, not a UNC path: $full"
    }

    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root) -or $root -eq $full) {
        throw "Refusing to use a filesystem root as the CPA stack directory: $full"
    }

    $driveLetter = $root.TrimEnd('\').TrimEnd(':')
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
    if (-not $volume) {
        throw "Could not inspect the filesystem for $full. Use a local NTFS or ReFS volume."
    }
    if ([string]$volume.FileSystemType -notin @('NTFS', 'ReFS')) {
        throw "CPA stack data requires NTFS or ReFS permissions. $root uses $($volume.FileSystemType)."
    }

    $userRoot = [Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($userRoot) -and [System.IO.Path]::GetFullPath($userRoot).TrimEnd('\') -ieq $full.TrimEnd('\')) {
        throw "Refusing to use the user profile root as the CPA stack directory: $full"
    }
    $systemRoots = @(
        [Environment]::GetFolderPath('Windows'),
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
    foreach ($systemRoot in $systemRoots) {
        if ($full.TrimEnd('\') -ieq $systemRoot -or $full.StartsWith($systemRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to use a Windows or Program Files directory as the CPA stack root: $full"
        }
    }

    $cursor = $full.TrimEnd('\')
    while ($cursor -and $cursor -ne [System.IO.Path]::GetPathRoot($cursor).TrimEnd('\')) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "CPA stack root must not be or cross a reparse point: $cursor"
            }
        }
        if (Test-Path -LiteralPath (Join-Path $cursor '.git')) {
            throw "CPA stack runtime must not be created inside a Git worktree: $full"
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full.TrimEnd('\')
}

function Get-CpaStackInstanceMarkerPath {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)
    return Join-Path $ControlRoot '.cpa-stack-instance.json'
}

function Ensure-CpaStackInstanceMarker {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [switch]$AllowCreate
    )

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    $markerPath = Get-CpaStackInstanceMarkerPath -ControlRoot $root
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $marker = Read-CpaStackJson -Path $markerPath
        if ([int]$marker.schemaVersion -ne 1 -or [string]$marker.instanceId -notmatch '^[0-9a-fA-F]{32}$') {
            throw "CPA stack instance marker is invalid: $markerPath"
        }
        if ([System.IO.Path]::GetFullPath([string]$marker.root).TrimEnd('\') -ine $root) {
            throw "CPA stack instance marker belongs to a different root."
        }
        return $marker
    }
    if (-not $AllowCreate) {
        throw "CPA stack instance marker is missing: $markerPath"
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        $unexpected = @(Get-ChildItem -Force -LiteralPath $root -ErrorAction Stop | Where-Object { $_.Name -notin @('locks', 'root.json') })
        if ($unexpected.Count -gt 0) {
            throw "Refusing to create a new instance marker in a non-empty CPA stack root: $root"
        }
    }

    $marker = [ordered]@{
        schemaVersion = 1
        instanceId = [guid]::NewGuid().ToString('N')
        root = $root
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-CpaStackJson -Value $marker -Path $markerPath
    Protect-CpaStackSecretFile -Path $markerPath
    return [pscustomobject]$marker
}

function Assert-CpaStackFreeSpace {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Int64]$MinimumBytes = 1073741824
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $drive = Get-PSDrive -Name $root.TrimEnd('\').TrimEnd(':') -PSProvider FileSystem -ErrorAction Stop
    if ([Int64]$drive.Free -lt $MinimumBytes) {
        throw "Insufficient free space on $root. Required at least $MinimumBytes bytes, available $($drive.Free)."
    }
}

function Enter-CpaStackOperationLock {
    param(
        [string]$Name = "CPAStackSafeOperation",
        [int]$TimeoutSeconds = 0
    )

    $lockDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\locks'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $lockPath = Join-Path $lockDirectory ($Name + '.lock')
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $metadata = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID`nstarted=$([DateTimeOffset]::Now.ToString('o'))`n")
            $stream.SetLength(0)
            $stream.Write($metadata, 0, $metadata.Length)
            $stream.Flush()
            return $stream
        } catch [System.IO.IOException] {
            if ($TimeoutSeconds -le 0 -or [DateTime]::UtcNow -ge $deadline) {
                throw "Another CPA stack operation is already running."
            }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}

function Exit-CpaStackOperationLock {
    param($Mutex)

    if ($null -eq $Mutex) { return }
    $Mutex.Dispose()
}

function Get-CpaStackListener {
    param([Parameter(Mandatory = $true)][int]$Port)

    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if ($connections.Count -eq 0) {
        return $null
    }

    $owners = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($owners.Count -ne 1) {
        throw "Port $Port has multiple listener owners and cannot be handled safely."
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owners[0])" -ErrorAction SilentlyContinue
    if (-not $process) {
        throw "Port $Port is listening, but its process owner could not be resolved safely."
    }

    $addresses = @($connections | Select-Object -ExpandProperty LocalAddress -Unique)

    return [pscustomobject]@{
        Port           = $Port
        LocalAddress   = if ($addresses.Count -eq 1) { [string]$addresses[0] } else { $null }
        LocalAddresses = $addresses
        ListenerCount  = $connections.Count
        ProcessId      = [int]$process.ProcessId
        Name           = [string]$process.Name
        ExecutablePath = [string]$process.ExecutablePath
    }
}

function Get-CpaStackCandidateProtectedPorts {
    param([int[]]$FormalPort = @())

    $protected = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($port in @(8317, 8318, 18317, 18318) + @($FormalPort)) {
        if ($port -lt 1 -or $port -gt 65535) {
            throw "Protected candidate port is outside the valid TCP range: $port"
        }
        [void]$protected.Add([int]$port)
    }

    $configured = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_PROTECTED_PORTS', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        foreach ($token in @($configured -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $port = 0
            if (-not [int]::TryParse($token, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw "CPA_STACK_TEST_PROTECTED_PORTS contains an invalid TCP port: $token"
            }
            [void]$protected.Add($port)
        }
    }

    return @($protected | Sort-Object)
}

function Get-CpaStackActiveListenerPorts {
    $connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    $ports = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($connection in $connections) {
        if ($null -eq $connection -or $null -eq $connection.PSObject.Properties['LocalPort']) { continue }
        [void]$ports.Add([int]$connection.LocalPort)
    }
    return $ports
}

function Assert-CpaStackCandidatePort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [int[]]$FormalPort = @()
    )

    $protected = @(Get-CpaStackCandidateProtectedPorts -FormalPort $FormalPort)
    if ($Port -in $protected) {
        $kind = if ($Port -in @($FormalPort)) { 'formal' } else { 'protected' }
        throw "Candidate port $Port is a $kind port and cannot be used."
    }
    if ($Port -lt 49152) {
        throw "Candidate port $Port is outside the high dynamic TCP range."
    }
    if ($Port -in @(Get-CpaStackActiveListenerPorts)) {
        throw "Candidate port $Port already has an active listener."
    }
    return [pscustomobject]@{
        Safe = $true
        BindAddress = '127.0.0.1'
        Port = $Port
    }
}

function New-CpaStackCandidatePortPlan {
    [CmdletBinding()]
    param(
        [int[]]$FormalPort = @(),
        [string[]]$Name = @('CpaCandidate', 'ManagerCandidate')
    )

    if (@($Name).Count -lt 1) { throw 'At least one candidate port role is required.' }
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($role in @($Name)) {
        if ([string]::IsNullOrWhiteSpace($role) -or -not $seenNames.Add($role)) {
            throw 'Candidate port role names must be non-empty and unique.'
        }
    }

    $unavailable = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($port in @(Get-CpaStackCandidateProtectedPorts -FormalPort $FormalPort)) { [void]$unavailable.Add([int]$port) }
    foreach ($port in @(Get-CpaStackActiveListenerPorts)) { [void]$unavailable.Add([int]$port) }

    $random = [System.Random]::new(([BitConverter]::ToInt32([guid]::NewGuid().ToByteArray(), 0) -band 0x7fffffff))
    $reservations = [System.Collections.Generic.List[System.Net.Sockets.TcpListener]]::new()
    $selected = [System.Collections.Generic.List[int]]::new()
    try {
        foreach ($role in @($Name)) {
            $reservation = $null
            for ($attempt = 0; $attempt -lt 512; $attempt++) {
                $port = $random.Next(49152, 65536)
                if ($unavailable.Contains($port)) { continue }
                $candidate = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
                $candidate.ExclusiveAddressUse = $true
                try {
                    $candidate.Start()
                    $reservation = $candidate
                    break
                } catch [System.Net.Sockets.SocketException] {
                    $candidate.Stop()
                    [void]$unavailable.Add($port)
                }
            }
            if ($null -eq $reservation) {
                throw "Could not reserve a safe high loopback port for candidate role '$role'."
            }
            $selectedPort = ([System.Net.IPEndPoint]$reservation.LocalEndpoint).Port
            $reservations.Add($reservation)
            $selected.Add($selectedPort)
            [void]$unavailable.Add($selectedPort)
        }

        $ports = [ordered]@{}
        for ($index = 0; $index -lt $Name.Count; $index++) {
            $ports[[string]$Name[$index]] = [int]$selected[$index]
        }
        return [pscustomobject]@{
            BindAddress = '127.0.0.1'
            Ports = [pscustomobject]$ports
            AllPorts = @($selected)
        }
    } finally {
        foreach ($reservation in @($reservations)) { $reservation.Stop() }
    }
}

function Wait-CpaStackTrustedListener {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][int]$ExpectedProcessId,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedHash,
        [string[]]$AllowedAddresses = @(),
        [int]$Seconds = 40
    )

    $expectedFullPath = [System.IO.Path]::GetFullPath($ExpectedPath)
    $expectedHashValue = $ExpectedHash.ToUpperInvariant()
    $allowed = @($AllowedAddresses | ForEach-Object {
        $value = ([string]$_).Trim().TrimStart('[').TrimEnd(']')
        if (-not $value) { return }
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed)) {
            if ($parsed.Equals([System.Net.IPAddress]::Any) -or $parsed.Equals([System.Net.IPAddress]::IPv6Any)) {
                '0.0.0.0'
                '::'
            } else {
                $parsed.ToString()
            }
        } elseif ($value -ieq 'localhost') {
            '127.0.0.1'
            '::1'
        } else {
            try {
                [System.Net.Dns]::GetHostAddresses($value) | ForEach-Object { $_.ToString() }
            } catch {
                throw "A configured listener hostname could not be resolved safely."
            }
        }
    } | Where-Object { $_ } | Select-Object -Unique)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $listener = Get-CpaStackListener -Port $Port
        if (-not $listener) {
            Start-Sleep -Milliseconds 200
            continue
        }
        if ($listener.ProcessId -ne $ExpectedProcessId -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$listener.ExecutablePath), $expectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Port $Port is owned by an unexpected process before credentialed validation."
        }
        if ((Get-CpaStackFileHash -Path $listener.ExecutablePath) -ne $expectedHashValue) {
            throw "The executable listening on port $Port failed its expected hash check."
        }
        $actualAddresses = @($listener.LocalAddresses | ForEach-Object {
            $value = ([string]$_).Trim().TrimStart('[').TrimEnd(']')
            $parsed = $null
            if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed)) { $parsed.ToString() } else { $value.ToLowerInvariant() }
        } | Where-Object { $_ } | Select-Object -Unique)
        if ($actualAddresses.Count -eq 0) {
            throw "Port $Port has no verifiable listener address."
        }
        if ($allowed.Count -gt 0 -and @($actualAddresses | Where-Object { $allowed -notcontains $_ }).Count -gt 0) {
            throw "Port $Port is listening on an address that is not authorized for this operation."
        }
        return $listener
    }
    throw "The expected process did not claim port $Port within $Seconds seconds."
}

function Get-CpaStackFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Write-CpaStackJson {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 12
    )

    Assert-CpaStackJsonWritePathBudget -Paths @($Path)
    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth $Depth
    $temp = $Path + ".tmp-" + [guid]::NewGuid().ToString("N")
    try {
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temp, $Path, ($Path + ".previous"))
        } else {
            [System.IO.File]::Move($temp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Sync-CpaStackCanonicalLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    Assert-CpaStackPath -Path $SourcePath -PathType Leaf
    $sourceItem = Get-Item -Force -LiteralPath $SourcePath
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The bundled canonical launcher source must not be a reparse point.'
    }
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $root
    $currentPath = Join-Path $root 'state\current.json'
    Assert-CpaStackChildPath -Root $root -Path $currentPath
    $current = Read-CpaStackJson -Path $currentPath
    if ([string]$current.instanceId -ne [string]$marker.instanceId -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\'), $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Canonical launcher synchronization refused mismatched instance state.'
    }

    $destination = Join-Path $root 'ops\Start-CPA-Stack.ps1'
    Assert-CpaStackChildPath -Root $root -Path $destination
    $sourceHash = Get-CpaStackFileHash -Path $SourcePath
    $previousHash = Get-CpaStackFileHash -Path $destination
    if ($previousHash -eq $sourceHash) {
        return [pscustomobject]@{ changed = $false; path = $destination; sha256 = $sourceHash }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    $temporary = $destination + '.tmp-' + [guid]::NewGuid().ToString('N')
    $backup = $destination + '.previous-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllBytes($temporary, [System.IO.File]::ReadAllBytes($SourcePath))
        Protect-CpaStackSecretFile -Path $temporary
        if ((Get-CpaStackFileHash -Path $temporary) -ne $sourceHash) {
            throw 'Canonical launcher staging hash mismatch.'
        }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Protect-CpaStackSecretFile -Path $destination
            [System.IO.File]::Replace($temporary, $destination, $backup)
        } else {
            [System.IO.File]::Move($temporary, $destination)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
    if ((Get-CpaStackFileHash -Path $destination) -ne $sourceHash) {
        throw 'Canonical launcher synchronization did not preserve the bundled hash.'
    }
    return [pscustomobject]@{ changed = $true; path = $destination; sha256 = $sourceHash; previousSha256 = $previousHash }
}

function Get-CpaStackCanonicalShortcutContract {
    param(
        [Parameter(Mandatory = $true)][string]$StartScript,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    if ($StartScript.IndexOf('"') -ge 0) {
        throw 'Canonical start script path must not contain a quote.'
    }
    $startScriptFull = [System.IO.Path]::GetFullPath($StartScript)
    $workingDirectoryFull = [System.IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\')
    $powershell = [System.IO.Path]::GetFullPath((Get-Command powershell.exe -ErrorAction Stop).Source)
    return [pscustomobject]@{
        TargetPath = $powershell
        Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $startScriptFull
        WorkingDirectory = $workingDirectoryFull
        WindowStyle = 7
    }
}

function Assert-CpaStackCanonicalShortcutContract {
    param(
        [Parameter(Mandatory = $true)]$Shortcut,
        [Parameter(Mandatory = $true)][string]$StartScript,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $contract = Get-CpaStackCanonicalShortcutContract -StartScript $StartScript -WorkingDirectory $WorkingDirectory
    $actualWorkingDirectory = try {
        [System.IO.Path]::GetFullPath([string]$Shortcut.WorkingDirectory).TrimEnd('\')
    } catch {
        ''
    }
    if (-not [string]::Equals([string]$Shortcut.TargetPath, [string]$contract.TargetPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$Shortcut.Arguments -cne [string]$contract.Arguments -or
        -not [string]::Equals($actualWorkingDirectory, [string]$contract.WorkingDirectory, [System.StringComparison]::OrdinalIgnoreCase) -or
        [int]$Shortcut.WindowStyle -ne [int]$contract.WindowStyle) {
        throw 'Canonical desktop shortcut does not match the hidden-window launch contract.'
    }
    return $contract
}

function Set-CpaStackCanonicalShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$StartScript,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$IconPath = ''
    )

    if ([System.IO.Path]::GetExtension($ShortcutPath) -ine '.lnk') {
        throw 'Canonical desktop shortcut must use the .lnk extension.'
    }
    Assert-CpaStackPath -Path $ShortcutPath -PathType Leaf
    Assert-CpaStackPath -Path $StartScript -PathType Leaf
    Assert-CpaStackPath -Path $WorkingDirectory -PathType Container
    $contract = Get-CpaStackCanonicalShortcutContract -StartScript $StartScript -WorkingDirectory $WorkingDirectory
    $wsh = $null
    $link = $null
    $verify = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $link = $wsh.CreateShortcut($ShortcutPath)
        $link.TargetPath = $contract.TargetPath
        $link.Arguments = $contract.Arguments
        $link.WorkingDirectory = $contract.WorkingDirectory
        $link.WindowStyle = [int]$contract.WindowStyle
        if ($IconPath -and (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            $link.IconLocation = "$IconPath,0"
        }
        $link.Save()
        $verify = $wsh.CreateShortcut($ShortcutPath)
        [void](Assert-CpaStackCanonicalShortcutContract -Shortcut $verify -StartScript $StartScript -WorkingDirectory $WorkingDirectory)
        return $contract
    } finally {
        foreach ($comObject in @($verify, $link, $wsh)) {
            if ($null -ne $comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
}

function Read-CpaStackJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required JSON file does not exist: $Path"
    }
    $json = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
    return $json | ConvertFrom-Json
}

function Read-CpaStackSecretJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = 'Secrets file'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description does not exist."
    }
    try {
        $json = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
        return $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "$Description is not valid UTF-8 JSON."
    }
}

function Get-CpaStackConfig {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $path = Join-Path $ControlRoot "config\stack.psd1"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Stack config does not exist: $path"
    }
    return Import-PowerShellDataFile -LiteralPath $path
}

function Get-CpaStackSecrets {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    return Read-CpaStackSecretJson -Path (Join-Path $ControlRoot "config\secrets.local.json") -Description 'Canonical secrets file'
}

function Get-CpaStackLegacySecret {
    param(
        [Parameter(Mandatory = $true)][string]$StartScript,
        [Parameter(Mandatory = $true)][ValidateSet("managerAdminKey", "cpaManagementKey")][string]$VariableName
    )

    $content = [System.IO.File]::ReadAllText($StartScript)
    $pattern = '(?m)^\s*\$' + [regex]::Escape($VariableName) + '\s*=\s*(["''])(?<value>.*?)\1\s*$'
    $match = [regex]::Match($content, $pattern)
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups["value"].Value)) {
        throw "Could not read `$${VariableName} from $StartScript"
    }
    return $match.Groups["value"].Value
}

function Get-CpaStackClientApiKey {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $inside = $false
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match "^api-keys\s*:\s*$") {
            $inside = $true
            continue
        }
        if ($inside -and $line -match "^[A-Za-z0-9_-]+\s*:") {
            break
        }
        if ($inside -and $line -match '^\s*-\s*(["'']?)(?<value>.+?)\1\s*$') {
            $value = $matches["value"].Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }
    throw "No CPA client API key was found in $ConfigPath"
}

function Get-CpaStackConfigHost {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    Assert-CpaStackPath -Path $ConfigPath -PathType Leaf
    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false, $true))
    $hostMatches = @([regex]::Matches($content, '(?m)^host:\s*["'']?(?<host>[^"''#\s]+)'))
    if ($hostMatches.Count -ne 1) {
        throw 'CPA config must contain exactly one explicit host.'
    }
    return [string]$hostMatches[0].Groups['host'].Value
}

function Get-CpaStackPrivateIdentities {
    return @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )
}

function Get-CpaStackFileSystemAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
        [System.Security.AccessControl.AccessControlSections]::Group -bor
        [System.Security.AccessControl.AccessControlSections]::Access
    if ($item.PSIsContainer) {
        return [System.Security.AccessControl.DirectorySecurity]::new($item.FullName, $sections)
    }
    return [System.Security.AccessControl.FileSecurity]::new($item.FullName, $sections)
}

function Get-CpaStackAclOwnerSid {
    param([Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl)

    return $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
}

function Get-CpaStackAclAccessRules {
    param([Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl)

    return @($Acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    ))
}

function Set-CpaStackFileSystemAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($item.PSIsContainer) {
        if ($Acl -isnot [System.Security.AccessControl.DirectorySecurity]) {
            throw "A directory ACL is required for $Path"
        }
        if ($null -ne $extensions) {
            [System.IO.FileSystemAclExtensions]::SetAccessControl(
                [System.IO.DirectoryInfo]$item,
                [System.Security.AccessControl.DirectorySecurity]$Acl
            )
        } else {
            ([System.IO.DirectoryInfo]$item).SetAccessControl([System.Security.AccessControl.DirectorySecurity]$Acl)
        }
        return
    }

    if ($Acl -isnot [System.Security.AccessControl.FileSecurity]) {
        throw "A file ACL is required for $Path"
    }
    if ($null -ne $extensions) {
        [System.IO.FileSystemAclExtensions]::SetAccessControl(
            [System.IO.FileInfo]$item,
            [System.Security.AccessControl.FileSecurity]$Acl
        )
    } else {
        ([System.IO.FileInfo]$item).SetAccessControl([System.Security.AccessControl.FileSecurity]$Acl)
    }
}

function Test-CpaStackPrivateAcl {
    param(
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl,
        [switch]$Directory
    )

    if (-not $Acl.AreAccessRulesProtected) { return $false }
    try {
        $ownerSid = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $false
    }
    if ($ownerSid -ne [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { return $false }

    $expectedSids = @{}
    foreach ($identity in Get-CpaStackPrivateIdentities) {
        $expectedSids[$identity.Value] = $false
    }
    $rules = @(Get-CpaStackAclAccessRules -Acl $Acl)
    if ($rules.Count -ne $expectedSids.Count) { return $false }

    $expectedInheritance = if ($Directory) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne $expectedInheritance -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
            $rule.IsInherited) {
            return $false
        }
        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            return $false
        }
        if (-not $expectedSids.ContainsKey($sid) -or $expectedSids[$sid]) { return $false }
        $expectedSids[$sid] = $true
    }
    return @($expectedSids.Values | Where-Object { -not $_ }).Count -eq 0
}

function Protect-CpaStackSecretFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = Get-CpaStackFileSystemAcl -Path $Path
    if (Test-CpaStackPrivateAcl -Acl $current) { return }

    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    foreach ($account in Get-CpaStackPrivateIdentities) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-CpaStackFileSystemAcl -Path $Path -Acl $acl
}

function Protect-CpaStackPrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
    $current = Get-CpaStackFileSystemAcl -Path $Path
    if (Test-CpaStackPrivateAcl -Acl $current -Directory) { return }

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    foreach ($account in Get-CpaStackPrivateIdentities) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-CpaStackFileSystemAcl -Path $Path -Acl $acl
}

function Get-CpaStackTreeItemsNoReparse {
    param([Parameter(Mandatory = $true)][string]$Root)

    Assert-CpaStackPath -Path $Root
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $items = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $queue.Enqueue([System.IO.Path]::GetFullPath($Root))
    while ($queue.Count -gt 0) {
        $path = $queue.Dequeue()
        $item = Get-Item -Force -LiteralPath $path
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A protected CPA stack tree contains a reparse point: $path"
        }
        [void]$items.Add($item)
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -Force -LiteralPath $item.FullName) {
                $queue.Enqueue($child.FullName)
            }
        }
    }
    return @($items)
}

function Assert-CpaStackPathNoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = 'Legacy CPA source'
    )

    $cursor = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $filesystemRoot = [System.IO.Path]::GetPathRoot($cursor).TrimEnd('\')
    while ($cursor -and $cursor -ne $filesystemRoot) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Description must not be or cross a reparse point: $cursor"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-CpaStackLegacySourceAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = 'Legacy CPA source path'
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point: $($item.FullName)"
    }
    $acl = Get-CpaStackFileSystemAcl -Path $item.FullName
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trustedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    try {
        $trustedInstallerSid = [System.Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller').Translate([System.Security.Principal.SecurityIdentifier]).Value
        $trustedSids += $trustedInstallerSid
    } catch {}
    try {
        $ownerSid = Get-CpaStackAclOwnerSid -Acl $acl
    } catch {
        throw "$Description owner could not be verified: $($item.FullName)"
    }
    if ($trustedSids -notcontains $ownerSid) {
        throw "$Description has an unexpected owner: $($item.FullName)"
    }

    [Int64]$safeReadMask = [Int64](
        [System.Security.AccessControl.FileSystemRights]::ReadData -bor
        [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::ExecuteFile -bor
        [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::ReadPermissions -bor
        [System.Security.AccessControl.FileSystemRights]::Synchronize
    )
    foreach ($rule in Get-CpaStackAclAccessRules -Acl $acl | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow }) {
        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            $sid = $null
        }
        if ($trustedSids -contains $sid) { continue }
        [Int64]$rights = [Int64]$rule.FileSystemRights
        if (($rights -band (-bnot $safeReadMask)) -ne 0) {
            $principal = if ($sid) { $sid } else { [string]$rule.IdentityReference }
            throw "$Description grants a non-trusted identity mutable access: $($item.FullName) ($principal)"
        }
    }
}

function Assert-CpaStackLegacyAncestorAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = 'Legacy CPA source ancestor'
    )

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trustedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    try {
        $trustedInstallerSid = [System.Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller').Translate([System.Security.Principal.SecurityIdentifier]).Value
        $trustedSids += $trustedInstallerSid
    } catch {}
    [Int64]$replacementMask = [Int64](
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    $cursor = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path).TrimEnd('\'))
    $filesystemRoot = [System.IO.Path]::GetPathRoot($cursor).TrimEnd('\')
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -Force -LiteralPath $cursor -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description is a reparse point: $($item.FullName)"
        }
        $acl = Get-CpaStackFileSystemAcl -Path $item.FullName
        try {
            $ownerSid = Get-CpaStackAclOwnerSid -Acl $acl
        } catch {
            throw "$Description owner could not be verified: $($item.FullName)"
        }
        if ($trustedSids -notcontains $ownerSid) {
            throw "$Description has an unexpected owner: $($item.FullName)"
        }
        foreach ($rule in Get-CpaStackAclAccessRules -Acl $acl | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow }) {
            if (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) {
                continue
            }
            try {
                $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            } catch {
                $sid = $null
            }
            if ($trustedSids -contains $sid) { continue }
            [Int64]$rights = [Int64]$rule.FileSystemRights
            [Int64]$effectiveReplacementMask = $replacementMask
            if ($cursor.TrimEnd('\') -ine $filesystemRoot) {
                $effectiveReplacementMask = $effectiveReplacementMask -bor [Int64][System.Security.AccessControl.FileSystemRights]::Delete
            }
            if (($rights -band $effectiveReplacementMask) -ne 0) {
                $principal = if ($sid) { $sid } else { [string]$rule.IdentityReference }
                throw "$Description lets a non-trusted identity replace descendants: $($item.FullName) ($principal)"
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-CpaStackLegacySourceTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Description = 'Legacy CPA source tree'
    )

    foreach ($item in @(Get-CpaStackTreeItemsNoReparse -Root $Root)) {
        Assert-CpaStackLegacySourceAcl -Path $item.FullName -Description $Description
    }
}

function Assert-CpaStackLegacyCpaSource {
    param(
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    Assert-CpaStackPath -Path $Runtime
    Assert-CpaStackPathNoReparseAncestors -Path $Runtime
    Assert-CpaStackLegacyAncestorAcl -Path $Runtime -Description 'Legacy CPA runtime ancestor'
    Assert-CpaStackLegacySourceAcl -Path $Runtime -Description 'Legacy CPA runtime'

    $executable = Join-Path $Runtime 'cli-proxy-api.exe'
    Assert-CpaStackPath -Path $executable -PathType Leaf
    Assert-CpaStackLegacySourceAcl -Path $executable -Description 'Legacy CPA executable'

    $auth = Join-Path $Runtime 'auth'
    Assert-CpaStackPath -Path $auth
    Assert-CpaStackLegacySourceTree -Root $auth -Description 'Legacy CPA auth tree'

    $plugins = Join-Path $Runtime 'plugins'
    if (Test-Path -LiteralPath $plugins) {
        Assert-CpaStackPath -Path $plugins
        Assert-CpaStackLegacySourceTree -Root $plugins -Description 'Legacy CPA plugins tree'
    }

    Assert-CpaStackPath -Path $ConfigPath -PathType Leaf
    Assert-CpaStackPathNoReparseAncestors -Path $ConfigPath
    Assert-CpaStackLegacyAncestorAcl -Path $ConfigPath -Description 'Legacy CPA config ancestor'
    $configParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($ConfigPath))
    Assert-CpaStackLegacySourceAcl -Path $configParent -Description 'Legacy CPA config parent'
    Assert-CpaStackLegacySourceAcl -Path $ConfigPath -Description 'Legacy CPA config'
}

function Assert-CpaStackLegacyManagerSource {
    param(
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][string]$Data
    )

    Assert-CpaStackPath -Path $Runtime
    Assert-CpaStackPathNoReparseAncestors -Path $Runtime -Description 'Legacy Manager runtime'
    Assert-CpaStackLegacyAncestorAcl -Path $Runtime -Description 'Legacy Manager runtime ancestor'
    Assert-CpaStackLegacySourceTree -Root $Runtime -Description 'Legacy Manager runtime tree'

    $executable = Join-Path $Runtime 'cpa-manager-plus.exe'
    Assert-CpaStackPath -Path $executable -PathType Leaf

    Assert-CpaStackPath -Path $Data
    Assert-CpaStackPathNoReparseAncestors -Path $Data -Description 'Legacy Manager data'
    Assert-CpaStackLegacyAncestorAcl -Path $Data -Description 'Legacy Manager data ancestor'
    Assert-CpaStackLegacySourceTree -Root $Data -Description 'Legacy Manager data tree'
    Assert-CpaStackPath -Path (Join-Path $Data 'usage.sqlite') -PathType Leaf
    Assert-CpaStackPath -Path (Join-Path $Data 'data.key') -PathType Leaf
}

function Get-CpaStackTreeManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeDirectoryNames = @(),
        [string[]]$ExcludeFileNames = @()
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $items = @(Get-CpaStackTreeItemsNoReparse -Root $rootFull)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $canonicalEntries = New-Object 'System.Collections.Generic.List[string]'
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    foreach ($item in $items) {
        $fullName = [System.IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
        if ($fullName -ieq $rootFull) { continue }
        $relative = $fullName.Substring($rootFull.Length + 1)
        $topLevelName = ($relative -split '\\', 2)[0]
        if ($ExcludeDirectoryNames -contains $topLevelName) { continue }
        if (-not $item.PSIsContainer -and $ExcludeFileNames -contains $item.Name) { continue }
        $encodedPath = [Convert]::ToBase64String($utf8.GetBytes($relative))
        if ($item.PSIsContainer) {
            [void]$entries.Add([pscustomobject][ordered]@{
                relativePath = $relative
                type = 'directory'
                length = $null
                sha256 = $null
            })
            [void]$canonicalEntries.Add("D|$encodedPath")
            continue
        }

        $before = Get-Item -Force -LiteralPath $item.FullName -ErrorAction Stop
        if (($before.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "CPA stack manifest encountered a reparse point: $($before.FullName)"
        }
        [Int64]$length = $before.Length
        [Int64]$writeTicks = $before.LastWriteTimeUtc.Ticks
        $sha256 = Get-CpaStackFileHash -Path $before.FullName
        $after = Get-Item -Force -LiteralPath $before.FullName -ErrorAction Stop
        if (($after.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [Int64]$after.Length -ne $length -or [Int64]$after.LastWriteTimeUtc.Ticks -ne $writeTicks) {
            throw "CPA stack file changed while its manifest was being captured: $($before.FullName)"
        }
        [void]$entries.Add([pscustomobject][ordered]@{
            relativePath = $relative
            type = 'file'
            length = $length
            sha256 = $sha256
        })
        [void]$canonicalEntries.Add("F|$encodedPath|$length|$sha256")
    }
    $canonicalEntries.Sort([System.StringComparer]::Ordinal)
    $canonical = "CPA-STACK-TREE-MANIFEST-V1`n" + (($canonicalEntries.ToArray()) -join "`n") + "`n"
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digestBytes = $algorithm.ComputeHash($utf8.GetBytes($canonical))
    } finally {
        $algorithm.Dispose()
    }
    $digest = ([BitConverter]::ToString($digestBytes)).Replace('-', '')
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        entryCount = $entries.Count
        entries = $entries.ToArray()
        sha256 = $digest
    }
}

function Assert-CpaStackPrivateTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Description = 'Protected CPA stack tree',
        [switch]$AllowInheritedDescendants
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($item in @(Get-CpaStackTreeItemsNoReparse -Root $Root)) {
        $acl = Get-CpaStackFileSystemAcl -Path $item.FullName
        $itemFull = [System.IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
        $isRoot = [string]::Equals($itemFull, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $acl.AreAccessRulesProtected -and ($isRoot -or -not $AllowInheritedDescendants)) {
            throw "$Description ACL inheritance is enabled: $($item.FullName)"
        }
        try {
            $ownerSid = Get-CpaStackAclOwnerSid -Acl $acl
        } catch {
            throw "$Description owner could not be verified: $($item.FullName)"
        }
        $allowedOwnerSids = if ($AllowInheritedDescendants -and -not $isRoot) { $allowedSids } else { @($currentSid) }
        if ($allowedOwnerSids -notcontains $ownerSid) {
            throw "$Description has an unexpected owner: $($item.FullName)"
        }
        foreach ($rule in Get-CpaStackAclAccessRules -Acl $acl | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow }) {
            try {
                $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            } catch {
                throw "$Description has an unresolvable allow principal: $($item.FullName)"
            }
            if ($allowedSids -notcontains $sid) {
                throw "$Description grants access to an unexpected identity: $($item.FullName)"
            }
        }
    }
}

function Protect-CpaStackPrivateTree {
    param([Parameter(Mandatory = $true)][string]$Root)

    $items = @(Get-CpaStackTreeItemsNoReparse -Root $Root)
    foreach ($directory in @($items | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length })) {
        Protect-CpaStackPrivateDirectory -Path $directory.FullName
    }
    foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
        Protect-CpaStackSecretFile -Path $file.FullName
    }
    Assert-CpaStackPrivateTree -Root $Root
}

function Initialize-CpaStackNativeProcessType {
    if ($null -ne ('CpaStack.NativeProcessV1' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CpaStack
{
    public static class NativeProcessV1
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint WaitObject0 = 0x00000000;
        private static readonly IntPtr ProcThreadAttributeHandleList = new IntPtr(0x00020002);

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public int Size;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public int Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public uint ProcessId;
            public uint ThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        private static SafeFileHandle OpenNull(uint access)
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.InheritHandle = true;
            SafeFileHandle handle = CreateFile(
                "NUL",
                access,
                FileShareRead | FileShareWrite | FileShareDelete,
                ref attributes,
                OpenExisting,
                FileAttributeNormal,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Could not open the Windows null device for managed-process isolation.");
            }
            return handle;
        }

        private static IntPtr BuildEnvironmentBlock(IDictionary environment, out int characterCount)
        {
            List<string> entries = new List<string>();
            foreach (DictionaryEntry entry in environment)
            {
                string name = Convert.ToString(entry.Key);
                string value = Convert.ToString(entry.Value);
                if (String.IsNullOrEmpty(name) || name.IndexOf('=') >= 0 || name.IndexOf('\0') >= 0 || value.IndexOf('\0') >= 0)
                {
                    throw new InvalidOperationException("Managed-process environment contains an invalid name or value.");
                }
                entries.Add(name + "=" + value);
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            StringBuilder block = new StringBuilder();
            foreach (string entry in entries)
            {
                block.Append(entry);
                block.Append('\0');
            }
            block.Append('\0');
            string text = block.ToString();
            characterCount = text.Length;
            return Marshal.StringToHGlobalUni(text);
        }

        private static void ZeroAndFreeEnvironment(IntPtr environment, int characterCount)
        {
            if (environment == IntPtr.Zero) { return; }
            for (int offset = 0; offset < characterCount * 2; offset += 2)
            {
                Marshal.WriteInt16(environment, offset, 0);
            }
            Marshal.FreeHGlobal(environment);
        }

        public static Process Start(string filePath, string arguments, string workingDirectory, IDictionary environment)
        {
            return Start(filePath, arguments, workingDirectory, environment, null);
        }

        public static Process Start(
            string filePath,
            string arguments,
            string workingDirectory,
            IDictionary environment,
            Action<Process> registerBeforeResume)
        {
            if (String.IsNullOrWhiteSpace(filePath) || filePath.IndexOf('"') >= 0)
            {
                throw new ArgumentException("Managed-process executable path is invalid.", "filePath");
            }
            if (String.IsNullOrWhiteSpace(workingDirectory))
            {
                throw new ArgumentException("Managed-process working directory is required.", "workingDirectory");
            }
            if (environment == null)
            {
                throw new ArgumentNullException("environment");
            }

            SafeFileHandle standardInput = null;
            SafeFileHandle standardOutput = null;
            SafeFileHandle standardError = null;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            int environmentCharacters = 0;
            ProcessInformation processInformation = new ProcessInformation();
            Process process = null;
            bool processCreated = false;
            bool processResumed = false;
            bool registrationAttempted = false;
            bool registrationCompleted = false;
            bool attributeListInitialized = false;

            try
            {
                standardInput = OpenNull(GenericRead);
                standardOutput = OpenNull(GenericWrite);
                standardError = OpenNull(GenericWrite);

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not size the managed-process handle list.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not initialize the managed-process handle list.");
                }
                attributeListInitialized = true;

                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, standardInput.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size, standardOutput.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, standardError.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributeHandleList,
                    handleList,
                    new IntPtr(IntPtr.Size * 3),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restrict managed-process inherited handles.");
                }

                environmentBlock = BuildEnvironmentBlock(environment, out environmentCharacters);
                StartupInfoEx startupInfo = new StartupInfoEx();
                startupInfo.StartupInfo.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                startupInfo.StartupInfo.Flags = (int)StartfUseStdHandles;
                startupInfo.StartupInfo.StandardInput = standardInput.DangerousGetHandle();
                startupInfo.StartupInfo.StandardOutput = standardOutput.DangerousGetHandle();
                startupInfo.StartupInfo.StandardError = standardError.DangerousGetHandle();
                startupInfo.AttributeList = attributeList;

                string command = "\"" + filePath + "\"";
                if (!String.IsNullOrWhiteSpace(arguments)) { command += " " + arguments; }
                StringBuilder commandLine = new StringBuilder(command);
                uint flags = CreateSuspended | CreateUnicodeEnvironment | ExtendedStartupInfoPresent | CreateNoWindow;
                if (!CreateProcess(
                    filePath,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    flags,
                    environmentBlock,
                    workingDirectory,
                    ref startupInfo,
                    out processInformation))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Managed process could not be started.");
                }
                processCreated = true;
                process = Process.GetProcessById((int)processInformation.ProcessId);
                IntPtr processHandle = process.Handle;
                if (registerBeforeResume != null)
                {
                    registrationAttempted = true;
                    registerBeforeResume(process);
                    registrationCompleted = true;
                }
                if (ResumeThread(processInformation.Thread) == UInt32.MaxValue)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Managed process could not be resumed.");
                }
                processResumed = true;
                return process;
            }
            catch (Exception startupError)
            {
                Exception cleanupError = null;
                if (processCreated && !processResumed && processInformation.Process != IntPtr.Zero)
                {
                    if (!TerminateProcess(processInformation.Process, 1))
                    {
                        cleanupError = new Win32Exception(Marshal.GetLastWin32Error(), "A suspended managed process could not be terminated after startup failed.");
                    }
                    else if (WaitForSingleObject(processInformation.Process, 5000) != WaitObject0)
                    {
                        cleanupError = new InvalidOperationException("A suspended managed process did not exit after startup failed.");
                    }
                }
                if (process != null) { process.Dispose(); }
                if (cleanupError != null)
                {
                    throw new AggregateException(
                        "Managed-process startup failed and suspended-process cleanup also failed.",
                        startupError,
                        cleanupError);
                }
                if (registrationAttempted && !registrationCompleted)
                {
                    throw new InvalidOperationException(
                        "Started-process registration failed; the exact suspended process was terminated before it could execute.",
                        startupError);
                }
                throw;
            }
            finally
            {
                ZeroAndFreeEnvironment(environmentBlock, environmentCharacters);
                if (processInformation.Thread != IntPtr.Zero) { CloseHandle(processInformation.Thread); }
                if (processInformation.Process != IntPtr.Zero) { CloseHandle(processInformation.Process); }
                if (attributeListInitialized) { DeleteProcThreadAttributeList(attributeList); }
                if (handleList != IntPtr.Zero) { Marshal.FreeHGlobal(handleList); }
                if (attributeList != IntPtr.Zero) { Marshal.FreeHGlobal(attributeList); }
                if (standardError != null) { standardError.Dispose(); }
                if (standardOutput != null) { standardOutput.Dispose(); }
                if (standardInput != null) { standardInput.Dispose(); }
            }
        }
    }
}
'@
}

function Start-CpaStackProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = "",
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [string[]]$RemoveEnvironment = @(),
        [switch]$MinimalEnvironment,
        [scriptblock]$StartedProcessRegistration
    )

    $processEnvironment = @{}
    if ($MinimalEnvironment) {
        $allowedNames = @(
            'SystemRoot', 'WINDIR', 'COMSPEC', 'TEMP', 'TMP', 'PATH', 'PATHEXT',
            'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA',
            'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
            'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER',
            'NO_PROXY', 'no_proxy',
            'SSL_CERT_FILE', 'SSL_CERT_DIR'
        )
        $allowedValues = @{}
        foreach ($name in $allowedNames) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($null -ne $value) { $allowedValues[$name] = $value }
        }
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $proxyUri = $null
            if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$proxyUri) -and
                $proxyUri.Scheme -in @('http', 'https', 'socks5') -and
                [string]::IsNullOrEmpty($proxyUri.UserInfo) -and
                [string]::IsNullOrEmpty($proxyUri.Query) -and
                [string]::IsNullOrEmpty($proxyUri.Fragment) -and
                -not [string]::IsNullOrWhiteSpace($proxyUri.Host)) {
                $allowedValues[$name] = $value
            }
        }
        foreach ($name in $allowedValues.Keys) {
            $processEnvironment[$name] = [string]$allowedValues[$name]
        }
    } else {
        foreach ($entry in [Environment]::GetEnvironmentVariables([System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
            $processEnvironment[[string]$entry.Key] = [string]$entry.Value
        }
    }
    foreach ($name in $RemoveEnvironment) {
        [void]$processEnvironment.Remove($name)
    }
    foreach ($name in $Environment.Keys) {
        $processEnvironment[$name] = [string]$Environment[$name]
    }

    Initialize-CpaStackNativeProcessType
    if ($null -eq $StartedProcessRegistration) {
        return [CpaStack.NativeProcessV1]::Start($FilePath, $Arguments, $WorkingDirectory, $processEnvironment)
    }
    $registrationCallback = $StartedProcessRegistration
    $registrationScript = {
        param([System.Diagnostics.Process]$Process)
        & $registrationCallback $Process | Out-Null
    }.GetNewClosure()
    $registrationAction = [System.Action[System.Diagnostics.Process]]$registrationScript
    return [CpaStack.NativeProcessV1]::Start(
        $FilePath,
        $Arguments,
        $WorkingDirectory,
        $processEnvironment,
        $registrationAction)
}

function Stop-CpaStackStartedProcess {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [int]$WaitSeconds = 10
    )

    try {
        $Process.Refresh()
        if ([bool]$Process.HasExited) { return }
        $actualPath = [System.IO.Path]::GetFullPath([string]$Process.MainModule.FileName)
        $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath)
        if (-not [string]::Equals($actualPath, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Started process path changed before cleanup: $actualPath"
        }
        $Process.Kill()
        if (-not $Process.WaitForExit($WaitSeconds * 1000)) {
            throw "Started process did not exit within $WaitSeconds seconds: $expectedFull"
        }
    } catch {
        try {
            $Process.Refresh()
            if ([bool]$Process.HasExited) { return }
        } catch {}
        throw
    }
}

function Get-CpaStackFixedListenerProcess {
    param(
        [Parameter(Mandatory = $true)]$Listener,
        [Parameter(Mandatory = $true)][string]$ExpectedPath
    )

    $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath)
    if ([int]$Listener.ProcessId -le 0 -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Listener.ExecutablePath), $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The listener does not match the expected executable.'
    }

    $process = Get-Process -Id ([int]$Listener.ProcessId) -ErrorAction Stop
    try {
        [void]$process.Handle
        $actualPath = [System.IO.Path]::GetFullPath([string]$process.MainModule.FileName)
        if ([int]$process.Id -ne [int]$Listener.ProcessId -or
            -not [string]::Equals($actualPath, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The listener process identity changed before its handle was fixed.'
        }
        return $process
    } catch {
        if ($process -is [System.IDisposable]) { $process.Dispose() }
        throw
    }
}

function Stop-CpaStackProcessesByExecutablePath {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [int]$WaitSeconds = 10
    )

    $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath)
    $escapedName = [System.IO.Path]::GetFileName($expectedFull).Replace("'", "''")
    $processRecords = @(Get-CimInstance Win32_Process -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue)
    $matchingRecords = @($processRecords | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        [string]::Equals([System.IO.Path]::GetFullPath([string]$_.ExecutablePath), $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)
    })

    $stopped = 0
    foreach ($record in $matchingRecords) {
        $process = Get-Process -Id ([int]$record.ProcessId) -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        try {
            [void]$process.Handle
            if (-not [bool]$process.HasExited) {
                $actualPath = [System.IO.Path]::GetFullPath([string]$process.MainModule.FileName)
                if (-not [string]::Equals($actualPath, $expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Process identity changed while quarantining executable: $expectedFull"
                }
            }
            Stop-CpaStackStartedProcess -Process $process -ExpectedPath $expectedFull -WaitSeconds $WaitSeconds
            $stopped++
        } finally {
            if ($process -is [System.IDisposable]) { $process.Dispose() }
        }
    }
    return $stopped
}

function Test-CpaStackFileReadyForReplacement {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $true
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        return $true
    } catch [System.IO.IOException] {
        return $false
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Stop-CpaStackPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$ExpectedPath = "",
        [int]$WaitSeconds = 10,
        [switch]$RequireExecutableWriteAccess,
        $ExpectedProcess
    )

    $listener = Get-CpaStackListener -Port $Port
    if (-not $listener -and $null -eq $ExpectedProcess) {
        return
    }
    if ($listener -and $ExpectedPath -and $listener.ExecutablePath -ine $ExpectedPath -and $null -eq $ExpectedProcess) {
        throw "Port $Port is owned by an unexpected process: $($listener.ExecutablePath)"
    }

    $ownedProcess = $ExpectedProcess
    $disposeOwnedProcess = $false
    if ($null -eq $ownedProcess) {
        $ownedProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $listener.ExecutablePath
        $disposeOwnedProcess = $true
    }

    $timer = $null
    try {
        [void]$ownedProcess.Handle
        $processExited = [bool]$ownedProcess.HasExited
        if ($processExited) {
            $verifiedPath = if ($ExpectedPath) { $ExpectedPath } elseif ($listener) { [string]$listener.ExecutablePath } else { $null }
            if ([string]::IsNullOrWhiteSpace($verifiedPath)) {
                throw "The fixed process for port $Port exited without a verified executable path."
            }
            $ownedProcessPath = [System.IO.Path]::GetFullPath($verifiedPath)
        } else {
            try {
                $ownedProcessPath = [System.IO.Path]::GetFullPath([string]$ownedProcess.MainModule.FileName)
            } catch {
                try { $ownedProcess.Refresh() } catch {}
                if (-not [bool]$ownedProcess.HasExited) { throw }
                $processExited = $true
                $verifiedPath = if ($ExpectedPath) { $ExpectedPath } elseif ($listener) { [string]$listener.ExecutablePath } else { $null }
                if ([string]::IsNullOrWhiteSpace($verifiedPath)) { throw }
                $ownedProcessPath = [System.IO.Path]::GetFullPath($verifiedPath)
            }
        }
        if ($ExpectedPath -and
            -not [string]::Equals($ownedProcessPath, [System.IO.Path]::GetFullPath($ExpectedPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The fixed process for port $Port does not match the expected executable."
        }

        if (-not $processExited) {
            $ownedProcess.Kill()
        }

        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $processRunning = -not [bool]$ownedProcess.HasExited
        while ($timer.Elapsed.TotalSeconds -lt $WaitSeconds) {
            $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
            $owners = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
            if ($owners.Count -gt 0 -and ($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$ownedProcess.Id)) {
                throw "Port $Port was claimed by an unexpected process while the expected process was stopping."
            }

            $processRunning = -not [bool]$ownedProcess.HasExited
            $fileReady = (-not $RequireExecutableWriteAccess) -or (Test-CpaStackFileReadyForReplacement -Path $ExpectedPath)
            if (-not $processRunning -and $connections.Count -eq 0 -and $fileReady) {
                return
            }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        if ($null -ne $timer) { $timer.Stop() }
        if ($disposeOwnedProcess -and $ownedProcess -is [System.IDisposable]) { $ownedProcess.Dispose() }
    }
    if ($processRunning) {
        throw "Process on port $Port did not fully exit within $WaitSeconds seconds."
    }
    if ($RequireExecutableWriteAccess -and -not (Test-CpaStackFileReadyForReplacement -Path $ExpectedPath)) {
        throw "Executable for port $Port remained locked after the process exited."
    }
    throw "Process on port $Port did not stop within $WaitSeconds seconds."
}

function Invoke-CpaStackHttpJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet("GET", "POST")][string]$Method = "GET",
        [hashtable]$Headers = @{},
        [string]$Body = "",
        [int]$TimeoutSec = 10
    )

    $parameters = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        TimeoutSec  = $TimeoutSec
        ErrorAction = "Stop"
    }
    if ($Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body
    }
    return Invoke-RestMethod @parameters
}

function Wait-CpaStackHttpJson {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [int]$Seconds = 30
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-CpaStackHttpJson -Uri $Uri -Headers $Headers -TimeoutSec 3
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out waiting for $Uri. Last error: $lastError"
}

function Get-CpaStackManagerSetupBaseline {
    param(
        [Parameter(Mandatory = $true)][int]$ManagerPort,
        [Parameter(Mandatory = $true)][string]$ManagerAdminKey
    )

    $config = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/config" -Headers @{ Authorization = "Bearer $ManagerAdminKey" }
    if ($null -eq $config.config -or $null -eq $config.config.cpaConnection -or $null -eq $config.config.collector -or
        [string]::IsNullOrWhiteSpace([string]$config.config.cpaConnection.cpaBaseUrl) -or
        $null -eq $config.config.collector.enabled -or $null -eq $config.config.collector.pollIntervalMs -or
        $null -eq $config.cpaUsage -or $null -eq $config.cpaUsage.usageStatisticsEnabled) {
        throw "Manager setup baseline is incomplete on port $ManagerPort."
    }
    $cpaBaseUrl = [string]$config.config.cpaConnection.cpaBaseUrl
    $parsedBaseUrl = $null
    if (-not [Uri]::TryCreate($cpaBaseUrl, [UriKind]::Absolute, [ref]$parsedBaseUrl) -or
        $parsedBaseUrl.Scheme -notin @('http', 'https') -or -not $parsedBaseUrl.IsLoopback -or
        -not [string]::IsNullOrWhiteSpace($parsedBaseUrl.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($parsedBaseUrl.Query) -or
        -not [string]::IsNullOrWhiteSpace($parsedBaseUrl.Fragment)) {
        throw "Manager CPA base URL must be a secret-free loopback HTTP(S) URL before it can be journaled."
    }
    return [pscustomobject]@{
        cpaBaseUrl = $cpaBaseUrl
        collectorEnabled = [bool]$config.config.collector.enabled
        pollIntervalMs = [int]$config.config.collector.pollIntervalMs
        usageStatisticsEnabled = [bool]$config.cpaUsage.usageStatisticsEnabled
    }
}

function Assert-CpaStackManagerSetupBaseline {
    param(
        [Parameter(Mandatory = $true)][int]$ManagerPort,
        [Parameter(Mandatory = $true)][string]$ManagerAdminKey,
        [Parameter(Mandatory = $true)]$Expected
    )

    $actual = Get-CpaStackManagerSetupBaseline -ManagerPort $ManagerPort -ManagerAdminKey $ManagerAdminKey
    foreach ($field in @("cpaBaseUrl", "collectorEnabled", "pollIntervalMs", "usageStatisticsEnabled")) {
        if ([string]$actual.$field -cne [string]$Expected.$field) {
            throw "Manager setup baseline was not restored for field $field."
        }
    }
    return $actual
}

function Set-CpaStackManagerCollector {
    param(
        [Parameter(Mandatory = $true)][int]$ManagerPort,
        [Parameter(Mandatory = $true)][int]$CpaPort,
        [Parameter(Mandatory = $true)][string]$ManagerAdminKey,
        [Parameter(Mandatory = $true)][string]$CpaManagementKey,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        $Baseline = $null
    )

    $cpaBaseUrl = if ($null -ne $Baseline -and $Baseline.cpaBaseUrl) { [string]$Baseline.cpaBaseUrl } else { "http://127.0.0.1:$CpaPort" }
    $pollIntervalMs = if ($null -ne $Baseline -and $null -ne $Baseline.pollIntervalMs) { [int]$Baseline.pollIntervalMs } else { 500 }
    $usageStatisticsEnabled = if ($null -ne $Baseline -and $null -ne $Baseline.usageStatisticsEnabled) { [bool]$Baseline.usageStatisticsEnabled } else { $true }
    $payload = @{
        cpaBaseUrl                  = $cpaBaseUrl
        managementKey              = $CpaManagementKey
        requestMonitoringEnabled   = $Enabled
        ensureUsageStatisticsEnabled = $usageStatisticsEnabled
        pollIntervalMs             = $pollIntervalMs
    } | ConvertTo-Json -Compress
    $headers = @{ Authorization = "Bearer $ManagerAdminKey" }
    $response = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/setup" -Method POST -Headers $headers -Body $payload -TimeoutSec 20
    if (-not $response.ok) {
        throw "Manager setup returned ok=false on port $ManagerPort."
    }
    $config = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/config" -Headers $headers
    if ($null -eq $config.config -or $null -eq $config.config.collector -or $null -eq $config.config.collector.enabled) {
        throw "Manager config does not expose config.collector.enabled on port $ManagerPort."
    }
    if ([bool]$config.config.collector.enabled -ne $Enabled) {
        throw "Manager collector state on port $ManagerPort did not become $Enabled."
    }
    return $config
}

function Assert-CpaStackTrustedDownloadUri {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) {
        throw 'Download URL must be an absolute URI.'
    }
    if ($parsed.Scheme -cne 'https') {
        throw 'Only HTTPS downloads are allowed.'
    }
    if (-not $parsed.IsDefaultPort -or $parsed.Port -ne 443) {
        throw 'Download URLs must use the default HTTPS port.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) {
        throw 'Download URLs must not contain user information.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.Fragment)) {
        throw 'Download URLs must not contain a fragment.'
    }

    $allowedHosts = @('api.github.com', 'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
    $hostName = $parsed.IdnHost.ToLowerInvariant()
    if ($allowedHosts -cnotcontains $hostName) {
        throw "Download host is not trusted: $hostName"
    }
    return $parsed
}

function Copy-CpaStackBoundedStream {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$InputStream,
        [Parameter(Mandatory = $true)][System.IO.Stream]$OutputStream,
        [Parameter(Mandatory = $true)][ValidateRange(1, [Int64]::MaxValue)][Int64]$MaximumBytes
    )

    $buffer = New-Object byte[] 65536
    [Int64]$totalBytes = 0
    while (($read = $InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if ($totalBytes -gt ($MaximumBytes - $read)) {
            throw "Download exceeded the $MaximumBytes byte safety limit."
        }
        $OutputStream.Write($buffer, 0, $read)
        $totalBytes += $read
    }
    return $totalBytes
}

function Invoke-CpaStackSecureDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][ValidateRange(1, [Int64]::MaxValue)][Int64]$MaximumBytes,
        [ValidateRange(0, 10)][int]$MaximumRedirects = 5
    )

    $currentUri = Assert-CpaStackTrustedDownloadUri -Uri $Uri
    $parent = Split-Path -Parent $Destination
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw 'Download destination must include a parent directory.'
    }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $partial = $Destination + '.partial-' + [guid]::NewGuid().ToString('N')

    try {
        for ($redirectCount = 0; $redirectCount -le $MaximumRedirects; $redirectCount++) {
            $currentUri = Assert-CpaStackTrustedDownloadUri -Uri $currentUri.AbsoluteUri
            $request = [System.Net.HttpWebRequest]::CreateHttp($currentUri)
            $request.Method = 'GET'
            $request.AllowAutoRedirect = $false
            $request.AutomaticDecompression = [System.Net.DecompressionMethods]::None
            $request.PreAuthenticate = $false
            $request.UseDefaultCredentials = $false
            $request.UserAgent = 'cpa-stack-updater'
            $request.Timeout = 300000
            $request.ReadWriteTimeout = 300000
            $request.MaximumResponseHeadersLength = 64

            $response = $null
            try {
                $response = [System.Net.HttpWebResponse]$request.GetResponse()
                $statusCode = [int]$response.StatusCode
                if ($statusCode -in @(301, 302, 303, 307, 308)) {
                    if ($redirectCount -ge $MaximumRedirects) {
                        throw "Download exceeded the $MaximumRedirects redirect safety limit."
                    }
                    $location = [string]$response.Headers['Location']
                    if ([string]::IsNullOrWhiteSpace($location)) {
                        throw 'Download redirect did not provide a Location header.'
                    }
                    $nextUri = $null
                    if (-not [Uri]::TryCreate($currentUri, $location, [ref]$nextUri)) {
                        throw 'Download redirect provided an invalid Location header.'
                    }
                    $currentUri = Assert-CpaStackTrustedDownloadUri -Uri $nextUri.AbsoluteUri
                    continue
                }
                if ($statusCode -ne 200) {
                    throw "Download returned unexpected HTTP status $statusCode."
                }
                if ($response.ContentLength -gt $MaximumBytes) {
                    throw "Download Content-Length exceeds the $MaximumBytes byte safety limit."
                }

                $inputStream = $null
                $outputStream = $null
                try {
                    $inputStream = $response.GetResponseStream()
                    $outputStream = New-Object System.IO.FileStream(
                        $partial,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None
                    )
                    Copy-CpaStackBoundedStream -InputStream $inputStream -OutputStream $outputStream -MaximumBytes $MaximumBytes | Out-Null
                    $outputStream.Flush()
                } finally {
                    if ($null -ne $outputStream) { $outputStream.Dispose() }
                    if ($null -ne $inputStream) { $inputStream.Dispose() }
                }

                Move-Item -LiteralPath $partial -Destination $Destination -Force
                if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
                    throw 'Download did not produce the expected destination file.'
                }
                return
            } catch [System.Net.WebException] {
                throw 'HTTPS download request failed.'
            } finally {
                if ($null -ne $response) { $response.Dispose() }
            }
        }
        throw 'Download did not complete within the redirect safety limit.'
    } finally {
        if (Test-Path -LiteralPath $partial -PathType Leaf) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-CpaStackGitHubRepository {
    param([Parameter(Mandatory = $true)][string]$Repository)

    if ($Repository -cnotmatch '^(?<owner>[A-Za-z0-9](?:[A-Za-z0-9.-]{0,99}))/(?<repo>[A-Za-z0-9_.-]{1,100})$') {
        throw "Invalid GitHub repository name: $Repository"
    }
    if ($matches['owner'] -in @('.', '..') -or $matches['repo'] -in @('.', '..')) {
        throw "Invalid GitHub repository name: $Repository"
    }
    return [pscustomobject]@{
        Owner = [string]$matches['owner']
        Name = [string]$matches['repo']
    }
}

function Assert-CpaStackGitHubReleaseUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag,
        [string]$AssetName
    )

    $repositoryParts = Assert-CpaStackGitHubRepository -Repository $Repository
    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag.Length -gt 128 -or $Tag -match '[\x00-\x1F\x7F]') {
        throw 'GitHub release tag is invalid.'
    }
    $parsed = Assert-CpaStackTrustedDownloadUri -Uri $Uri
    if ($parsed.IdnHost -cne 'github.com' -or -not [string]::IsNullOrEmpty($parsed.Query)) {
        throw 'GitHub release URL must be an unqualified github.com URL.'
    }

    $owner = [Uri]::EscapeDataString($repositoryParts.Owner)
    $repo = [Uri]::EscapeDataString($repositoryParts.Name)
    $escapedTag = [Uri]::EscapeDataString($Tag)
    if ([string]::IsNullOrWhiteSpace($AssetName)) {
        $expectedPath = "/$owner/$repo/releases/tag/$escapedTag"
    } else {
        if ([System.IO.Path]::GetFileName($AssetName) -cne $AssetName -or $AssetName.Length -gt 255) {
            throw 'GitHub release asset name is invalid.'
        }
        $expectedPath = "/$owner/$repo/releases/download/$escapedTag/$([Uri]::EscapeDataString($AssetName))"
    }
    if ($parsed.AbsolutePath -cne $expectedPath) {
        throw 'GitHub release URL does not match the expected repository, tag, and asset.'
    }
    return $parsed
}

function Get-CpaStackLatestRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$AssetPattern
    )

    Assert-CpaStackGitHubRepository -Repository $Repository | Out-Null
    $maximumReleaseJsonBytes = 4194304
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    $ghReady = $false
    if ($gh) {
        & $gh.Source auth status --hostname github.com 2>$null | Out-Null
        $ghReady = ($LASTEXITCODE -eq 0)
    }
    if ($ghReady) {
        $json = @(& $gh.Source api --hostname github.com "repos/$Repository/releases/latest" 2>&1) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub CLI could not query the latest release for ${Repository}: $json"
        }
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt $maximumReleaseJsonBytes) {
            throw 'GitHub release JSON exceeds the 4 MiB safety limit.'
        }
        $release = $json | ConvertFrom-Json
    } else {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("cpa-release-" + [guid]::NewGuid().ToString("N") + ".json")
        try {
            Invoke-CpaStackSecureDownload -Uri "https://api.github.com/repos/$Repository/releases/latest" -Destination $temp -MaximumBytes $maximumReleaseJsonBytes
            $release = Read-CpaStackJson -Path $temp
        } finally {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
    $assets = @($release.assets | Where-Object { $_.name -match $AssetPattern })
    $checksumAssets = @($release.assets | Where-Object { $_.name -ceq 'checksums.txt' })
    if ($assets.Count -ne 1 -or $checksumAssets.Count -ne 1) {
        throw "Release $($release.tag_name) in $Repository does not contain the expected Windows asset and checksums.txt."
    }
    $asset = $assets[0]
    $checksums = $checksumAssets[0]
    [Int64]$assetSize = 0
    [Int64]$checksumsSize = 0
    if ($null -eq $asset.PSObject.Properties['size'] -or -not [Int64]::TryParse([string]$asset.size, [ref]$assetSize) -or $assetSize -lt 1) {
        throw 'GitHub release asset size is missing or invalid.'
    }
    if ($null -eq $checksums.PSObject.Properties['size'] -or -not [Int64]::TryParse([string]$checksums.size, [ref]$checksumsSize) -or $checksumsSize -lt 1) {
        throw 'GitHub checksums asset size is missing or invalid.'
    }
    Assert-CpaStackGitHubReleaseUrl -Uri ([string]$release.html_url) -Repository $Repository -Tag ([string]$release.tag_name) | Out-Null
    Assert-CpaStackGitHubReleaseUrl -Uri ([string]$asset.browser_download_url) -Repository $Repository -Tag ([string]$release.tag_name) -AssetName ([string]$asset.name) | Out-Null
    Assert-CpaStackGitHubReleaseUrl -Uri ([string]$checksums.browser_download_url) -Repository $Repository -Tag ([string]$release.tag_name) -AssetName ([string]$checksums.name) | Out-Null
    return [pscustomobject]@{
        Repository        = $Repository
        Tag               = [string]$release.tag_name
        PublishedAt       = [string]$release.published_at
        ReleaseUrl        = [string]$release.html_url
        AssetName         = [string]$asset.name
        AssetUrl          = [string]$asset.browser_download_url
        AssetSize         = $assetSize
        AssetDigest       = [string]$asset.digest
        ChecksumsUrl      = [string]$checksums.browser_download_url
        ChecksumsSize     = $checksumsSize
        ChecksumsDigest   = [string]$checksums.digest
    }
}

function Save-CpaStackRelease {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $archiveLimit = 1073741824
    $checksumsLimit = 1048576
    if ($null -eq $Release.PSObject.Properties['AssetSize'] -or [Int64]$Release.AssetSize -lt 1 -or [Int64]$Release.AssetSize -gt $archiveLimit) {
        throw 'Release archive metadata exceeds the 1 GiB safety limit or is invalid.'
    }
    if ($null -eq $Release.PSObject.Properties['ChecksumsSize'] -or [Int64]$Release.ChecksumsSize -lt 1 -or [Int64]$Release.ChecksumsSize -gt $checksumsLimit) {
        throw 'checksums.txt metadata exceeds the 1 MiB safety limit or is invalid.'
    }
    Assert-CpaStackGitHubReleaseUrl -Uri ([string]$Release.ReleaseUrl) -Repository ([string]$Release.Repository) -Tag ([string]$Release.Tag) | Out-Null
    Assert-CpaStackGitHubReleaseUrl -Uri ([string]$Release.AssetUrl) -Repository ([string]$Release.Repository) -Tag ([string]$Release.Tag) -AssetName ([string]$Release.AssetName) | Out-Null
    Assert-CpaStackGitHubReleaseUrl -Uri ([string]$Release.ChecksumsUrl) -Repository ([string]$Release.Repository) -Tag ([string]$Release.Tag) -AssetName 'checksums.txt' | Out-Null

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $archive = Join-Path $Destination $Release.AssetName
    $checksums = Join-Path $Destination "checksums.txt"
    Invoke-CpaStackSecureDownload -Uri $Release.AssetUrl -Destination $archive -MaximumBytes $archiveLimit
    Invoke-CpaStackSecureDownload -Uri $Release.ChecksumsUrl -Destination $checksums -MaximumBytes $checksumsLimit

    $actualArchiveHash = Get-CpaStackFileHash -Path $archive
    $actualChecksumsHash = Get-CpaStackFileHash -Path $checksums
    if ($Release.ChecksumsDigest -and $Release.ChecksumsDigest -match '^sha256:(?<hash>[0-9A-Fa-f]{64})$' -and $actualChecksumsHash -ne $matches['hash'].ToUpperInvariant()) {
        throw 'GitHub digest mismatch for checksums.txt.'
    }
    $expectedHash = Get-CpaStackExpectedSha256 -ChecksumsPath $checksums -AssetName ([string]$Release.AssetName)
    if ($actualArchiveHash -ne $expectedHash) {
        throw "Checksum mismatch for $($Release.AssetName). Expected $expectedHash, got $actualArchiveHash."
    }
    if ($Release.AssetDigest -and $Release.AssetDigest -match "^sha256:(?<hash>[0-9A-Fa-f]{64})$" -and $actualArchiveHash -ne $matches["hash"].ToUpperInvariant()) {
        throw "GitHub asset digest mismatch for $($Release.AssetName)."
    }

    $extracted = Join-Path $Destination "extracted"
    Expand-CpaStackSafeArchive -ArchivePath $archive -DestinationPath $extracted
    $exe = Get-ChildItem -LiteralPath $extracted -Recurse -File -Filter "*.exe" |
        Where-Object { $_.Name -in @("cli-proxy-api.exe", "cpa-manager-plus.exe") } |
        Select-Object -First 1
    if (-not $exe) {
        throw "No expected executable was found after extracting $($Release.AssetName)."
    }
    $packageRoot = Split-Path -Parent $exe.FullName
    $manifest = [ordered]@{
        repository      = $Release.Repository
        tag             = $Release.Tag
        publishedAt     = $Release.PublishedAt
        releaseUrl      = $Release.ReleaseUrl
        assetName       = $Release.AssetName
        archiveSha256   = $actualArchiveHash
        executable      = $exe.Name
        executableSha256 = Get-CpaStackFileHash -Path $exe.FullName
        packageRoot     = $packageRoot
    }
    Write-CpaStackJson -Value $manifest -Path (Join-Path $Destination "release.json")
    return [pscustomobject]$manifest
}

function Get-CpaStackExpectedSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$ChecksumsPath,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    Assert-CpaStackPath -Path $ChecksumsPath -PathType Leaf
    if ([System.IO.Path]::GetFileName($AssetName) -cne $AssetName -or $AssetName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "Checksum lookup requires an exact asset file name: $AssetName"
    }
    $pattern = '^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?:\./)?' + [regex]::Escape($AssetName) + '$'
    foreach ($line in [System.IO.File]::ReadLines($ChecksumsPath)) {
        $match = [regex]::Match([string]$line, $pattern)
        if ($match.Success) {
            return $match.Groups['hash'].Value.ToUpperInvariant()
        }
    }
    throw "checksums.txt does not contain a SHA256 for $AssetName."
}

function Expand-CpaStackSafeArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$MaximumEntries = 10000,
        [Int64]$MaximumUncompressedBytes = 1073741824
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destination = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\')
    $stream = [System.IO.File]::OpenRead($ArchivePath)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            if ($zip.Entries.Count -gt $MaximumEntries) {
                throw "Archive contains too many entries: $($zip.Entries.Count)."
            }
            [Int64]$total = 0
            foreach ($entry in $zip.Entries) {
                $total += [Int64]$entry.Length
                if ($total -gt $MaximumUncompressedBytes) {
                    throw "Archive exceeds the uncompressed size limit of $MaximumUncompressedBytes bytes."
                }
                $name = [string]$entry.FullName
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                if ([System.IO.Path]::IsPathRooted($name)) {
                    throw "Archive contains an absolute path: $name"
                }
                if ($name -match ':') {
                    throw "Archive entry contains a Windows alternate-stream or drive separator: $name"
                }
                $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                if ($unixType -eq 0xA000) {
                    throw "Archive contains a symbolic link: $name"
                }
                $target = [System.IO.Path]::GetFullPath((Join-Path $destination $name))
                if (-not ($target -eq $destination -or $target.StartsWith($destination + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
                    throw "Archive entry escapes the extraction directory: $name"
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }

    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $destination -Force
}

function Copy-CpaStackTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$ExcludeDirectoryNames = @(),
        [string[]]$ExcludeFileNames = @()
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -Force -LiteralPath $Source) {
        if ($item.PSIsContainer -and $ExcludeDirectoryNames -contains $item.Name) {
            continue
        }
        if (-not $item.PSIsContainer -and $ExcludeFileNames -contains $item.Name) {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
    }
}

function Copy-CpaStackAuthTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](Get-CpaStackTreeItemsNoReparse -Root $Source)
    Copy-CpaStackTree -Source $Source -Destination $Destination -ExcludeDirectoryNames @("logs")
    Protect-CpaStackPrivateTree -Root $Destination
}

function Copy-CpaStackPluginTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](Get-CpaStackTreeItemsNoReparse -Root $Source)
    Copy-CpaStackTree -Source $Source -Destination $Destination
    Protect-CpaStackPrivateTree -Root $Destination
}

function Assert-CpaStackPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("Leaf", "Container")][string]$PathType = "Container"
    )

    if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) {
        throw "Required path does not exist: $Path"
    }
}

function Assert-CpaStackChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($pathFull -ieq $rootFull -or -not $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the managed root. Root=$Root Path=$Path"
    }

    $relative = $pathFull.Substring($rootFull.Length + 1)
    $segments = @($relative.Split('\') | Where-Object { $_ })
    $allowedPatterns = @(
        '^assets\\[^\\]+(?:\\.*)?$',
        '^config\\[^\\]+(?:\\.*)?$',
        '^data\\manager-plus(?:\\.*)?$',
        '^logs\\[^\\]+(?:\\.*)?$',
        '^ops\\[^\\]+(?:\\.*)?$',
        '^releases\\current(?:\\.*)?$',
        '^rollback\\(?:last-known-good|legacy-migration|lan\\[0-9a-fA-F]{32}|(?:staging|pending)-(?:cpa|manager)-[0-9a-fA-F]{32})(?:\\.*)?$',
        '^runtime\\(?:cli-proxy-api|manager-plus)(?:\\.*)?$',
        '^state\\[^\\]+(?:\\.*)?$',
        '^work\\(?:current|cpa-(?:candidate|\d{1,5})-[0-9a-fA-F]{32}|manager-(?:candidate|\d{1,5})-[0-9a-fA-F]{32}|manager-formal-verification-[0-9a-fA-F]{32}|mv-[0-9a-fA-F]{32})(?:\\.*)?$'
    )
    if ($segments.Count -lt 2 -or -not ($allowedPatterns | Where-Object { $relative -match $_ } | Select-Object -First 1)) {
        throw "Managed paths must name a fixed slot below the control root. Path=$Path"
    }

    $current = $rootFull
    if (Test-Path -LiteralPath $current) {
        $rootItem = Get-Item -Force -LiteralPath $current
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Managed root must not be a reparse point: $current"
        }
    }
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }
        $item = Get-Item -Force -LiteralPath $current
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Managed path crosses a reparse point: $current"
        }
    }
}

function Assert-CpaStackPathBudget {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [ValidateSet('Leaf', 'Container')][string]$PathType = 'Leaf'
    )

    $maximumLength = if ($PathType -eq 'Container') { 247 } else { 259 }
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'Path budget validation received an empty path.' }
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if ($fullPath.Length -gt $maximumLength) {
            throw "Path exceeds the Windows PowerShell 5.1 $PathType budget of $maximumLength characters: $fullPath"
        }
    }
}

function Assert-CpaStackJsonWritePathBudget {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    foreach ($path in $Paths) {
        Assert-CpaStackPathBudget -Paths @(
            $path,
            ($path + '.previous'),
            ($path + '.tmp-' + ('0' * 32))
        ) -PathType Leaf
        Assert-CpaStackPathBudget -Paths @((Split-Path -Parent ([System.IO.Path]::GetFullPath($path)))) -PathType Container
    }
}

function Assert-CpaStackProjectedTreePathBudget {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$ExcludeDirectoryNames = @(),
        [string[]]$ExcludeFileNames = @()
    )

    $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    Assert-CpaStackPathBudget -Paths @($destinationFull) -PathType Container
    foreach ($item in @(Get-CpaStackTreeItemsNoReparse -Root $sourceFull)) {
        $itemFull = [System.IO.Path]::GetFullPath($item.FullName).TrimEnd('\')
        if ($itemFull -ieq $sourceFull) { continue }
        $relative = $itemFull.Substring($sourceFull.Length + 1)
        $topLevelName = ($relative -split '\\', 2)[0]
        if ($ExcludeDirectoryNames -contains $topLevelName) { continue }
        if (-not $item.PSIsContainer -and $ExcludeFileNames -contains $item.Name) { continue }
        $projected = Join-Path $destinationFull $relative
        $projectedType = if ($item.PSIsContainer) { 'Container' } else { 'Leaf' }
        Assert-CpaStackPathBudget -Paths @($projected) -PathType $projectedType
    }
}

function Resolve-CpaStackSwitchDisposition {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$RecordedHash,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ActiveHash,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$OldHash,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$NewHash
    )

    $recorded = $RecordedHash.ToUpperInvariant()
    $active = $ActiveHash.ToUpperInvariant()
    $old = $OldHash.ToUpperInvariant()
    $new = $NewHash.ToUpperInvariant()
    if ($recorded -eq $new -and $active -eq $new) {
        return 'commit-new'
    }
    if ($recorded -eq $old -and $active -in @($old, $new)) {
        return 'restore-old'
    }
    throw "Switch recovery state is ambiguous. Recorded=$recorded Active=$active Old=$old New=$new"
}

function Commit-CpaStackDirectorySlot {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [Parameter(Mandatory = $true)][string]$PendingPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Assert-CpaStackChildPath -Root $ControlRoot -Path $PendingPath
    Assert-CpaStackChildPath -Root $ControlRoot -Path $DestinationPath
    Assert-CpaStackPath -Path $PendingPath
    Assert-CpaStackPathBudget -Paths @($PendingPath, $DestinationPath, ($DestinationPath + '.previous-' + ('0' * 32))) -PathType Container
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DestinationPath) | Out-Null

    $previousPath = $DestinationPath + ".previous-" + [guid]::NewGuid().ToString("N")
    $movedPrevious = $false
    if (Test-Path -LiteralPath $DestinationPath) {
        Move-Item -LiteralPath $DestinationPath -Destination $previousPath -ErrorAction Stop
        $movedPrevious = $true
    }
    try {
        Move-Item -LiteralPath $PendingPath -Destination $DestinationPath -ErrorAction Stop
    } catch {
        if ($movedPrevious -and -not (Test-Path -LiteralPath $DestinationPath) -and (Test-Path -LiteralPath $previousPath)) {
            Move-Item -LiteralPath $previousPath -Destination $DestinationPath -ErrorAction Stop
            $movedPrevious = $false
        }
        throw
    }

    $cleanupWarning = $null
    if ($movedPrevious -and (Test-Path -LiteralPath $previousPath)) {
        try {
            Remove-Item -LiteralPath $previousPath -Recurse -Force -ErrorAction Stop
            $movedPrevious = $false
        } catch {
            $cleanupWarning = $_.Exception.Message
        }
    }
    return [pscustomobject]@{
        committed = $true
        destination = $DestinationPath
        cleanupWarning = $cleanupWarning
        previousRetained = if ($movedPrevious) { $previousPath } else { $null }
    }
}

function Get-CpaStackPythonCommand {
    $candidates = @()
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $candidates += [pscustomobject]@{ Path = $python.Source; Prefix = @() }
    }
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        $candidates += [pscustomobject]@{ Path = $launcher.Source; Prefix = @('-3') }
    }
    foreach ($candidate in $candidates) {
        $output = @(& $candidate.Path @($candidate.Prefix) --version 2>&1) -join ' '
        if ($LASTEXITCODE -eq 0 -and $output -match 'Python\s+(?<version>\d+\.\d+(?:\.\d+)?)') {
            $version = [version]$matches['version']
            if ($version -ge [version]'3.10') {
                return $candidate
            }
        }
    }
    throw "Python 3.10 or newer is required for a consistent SQLite online backup."
}

function Invoke-CpaStackSqliteBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ResultPath
    )

    Assert-CpaStackPath -Path $Source -PathType Leaf
    if (Test-Path -LiteralPath $Destination) {
        throw "SQLite backup destination already exists: $Destination"
    }
    $python = Get-CpaStackPythonCommand
    $script = Join-Path $PSScriptRoot "backup_sqlite.py"
    $arguments = @()
    $arguments += $python.Prefix
    $arguments += $script
    $arguments += @("--source", $Source, "--destination", $Destination)
    $output = @(& $python.Path @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "SQLite backup helper returned no output."
    }
    [System.IO.File]::WriteAllText($ResultPath, $text, [System.Text.UTF8Encoding]::new($false))
    $result = $text | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $result.success) {
        $detail = if ($null -ne $result.error -and -not [string]::IsNullOrWhiteSpace([string]$result.error.message)) {
            " $([string]$result.error.type): $([string]$result.error.message)"
        } else {
            ''
        }
        throw "SQLite online backup failed.$detail See $ResultPath"
    }
    return $result
}

function Assert-CpaStackManagerRecoveryState {
    param(
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][string]$Data,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutableSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedDataKeySha256,
        [Parameter(Mandatory = $true)]$ExpectedSnapshot,
        [Parameter(Mandatory = $true)][string]$VerificationRoot
    )

    $executable = Join-Path $Runtime 'cpa-manager-plus.exe'
    $database = Join-Path $Data 'usage.sqlite'
    $dataKey = Join-Path $Data 'data.key'
    if ((Get-CpaStackFileHash -Path $executable) -cne $ExpectedExecutableSha256.ToUpperInvariant()) {
        throw 'Legacy Manager recovery executable changed after the source was stopped.'
    }
    if ((Get-CpaStackFileHash -Path $dataKey) -cne $ExpectedDataKeySha256.ToUpperInvariant()) {
        throw 'Legacy Manager recovery data.key changed after the source was stopped.'
    }

    if (Test-Path -LiteralPath $VerificationRoot) {
        throw "Manager recovery verification directory already exists: $VerificationRoot"
    }
    New-Item -ItemType Directory -Path $VerificationRoot | Out-Null
    $actual = Invoke-CpaStackSqliteBackup `
        -Source $database `
        -Destination (Join-Path $VerificationRoot 'usage.sqlite') `
        -ResultPath (Join-Path $VerificationRoot 'sqlite-verification.json')
    if (-not [bool]$actual.snapshot.quick_check.ok) {
        throw 'Legacy Manager recovery database quick_check failed.'
    }
    if ([bool]$ExpectedSnapshot.snapshot.usage_events.exists -and -not [bool]$actual.snapshot.usage_events.exists) {
        throw 'Legacy Manager recovery lost the required usage_events table.'
    }
    if ([Int64]$actual.snapshot.usage_events.count -lt [Int64]$ExpectedSnapshot.snapshot.usage_events.count) {
        throw 'Legacy Manager recovery usage_events count regressed below the rollback baseline.'
    }
    foreach ($field in @('max_id', 'max_timestamp_ms')) {
        $expectedValue = $ExpectedSnapshot.snapshot.usage_events.$field
        $actualValue = $actual.snapshot.usage_events.$field
        if ($null -ne $expectedValue -and ($null -eq $actualValue -or [Int64]$actualValue -lt [Int64]$expectedValue)) {
            throw "Legacy Manager recovery usage watermark regressed below the rollback baseline: $field"
        }
    }

    foreach ($table in @('settings', 'model_prices')) {
        $expectedCount = $ExpectedSnapshot.snapshot.critical_table_counts.$table
        if ($null -eq $expectedCount) { continue }
        $actualCount = $actual.snapshot.critical_table_counts.$table
        if ($null -eq $actualCount -or [Int64]$actualCount -lt [Int64]$expectedCount) {
            throw "Legacy Manager recovery required business table regressed below the rollback baseline: $table"
        }
    }
    return $actual
}

function Assert-CpaStackManagerRecoverySource {
    param(
        [Parameter(Mandatory = $true)][string]$Runtime,
        [Parameter(Mandatory = $true)][string]$Data,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutableSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedDataKeySha256,
        [Parameter(Mandatory = $true)]$ExpectedSnapshot,
        [Parameter(Mandatory = $true)][string]$VerificationRoot
    )

    Assert-CpaStackLegacyManagerSource -Runtime $Runtime -Data $Data
    return Assert-CpaStackManagerRecoveryState @PSBoundParameters
}
