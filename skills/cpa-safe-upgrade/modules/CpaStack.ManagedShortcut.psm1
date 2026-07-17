Set-StrictMode -Version Latest

$script:ShortcutContractVersion = 3

function Get-CpaStackPreferredPowerShellPath {
    foreach ($name in @('pwsh.exe', 'powershell.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [System.IO.Path]::GetFullPath([string]$command.Source)
        }
    }
    throw 'PowerShell 7 or Windows PowerShell 5.1 is required for the desktop shortcut.'
}

function Get-CpaStackManagedFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Assert-CpaStackManagedChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($pathFull -ieq $rootFull -or -not $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Managed shortcut state path is outside the managed root.'
    }
    Assert-CpaStackManagedPathNoReparse -Root $rootFull -Path $pathFull
}

function Assert-CpaStackManagedPathNoReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($pathFull -ine $rootFull -and -not $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Managed path is outside the managed root.'
    }
    $cursor = $rootFull
    $paths = @($cursor)
    if ($pathFull -ine $rootFull) {
        $relative = $pathFull.Substring($rootFull.Length + 1)
        foreach ($segment in $relative.Split('\')) {
            if ([string]::IsNullOrWhiteSpace($segment)) { continue }
            $cursor = Join-Path $cursor $segment
            $paths += $cursor
        }
    }
    foreach ($candidate in $paths) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $item = Get-Item -Force -LiteralPath $candidate -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Managed shortcut paths must not contain a reparse point.'
        }
    }
}

function Assert-CpaStackManagedRootNoReparse {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $volumeRoot = [System.IO.Path]::GetPathRoot($rootFull)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw 'Managed root must have a local filesystem root.'
    }
    $cursor = $volumeRoot
    $paths = @($cursor)
    $relative = $rootFull.Substring($volumeRoot.Length)
    foreach ($segment in $relative.Split('\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $cursor = Join-Path $cursor $segment
        $paths += $cursor
    }
    foreach ($candidate in $paths) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $item = Get-Item -Force -LiteralPath $candidate -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Managed root paths must not contain a reparse point.'
        }
    }
}

function New-CpaStackWshShortcutStore {
    $read = {
        param([string]$Path)

        $shell = $null
        $link = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($Path)
            return [pscustomobject]@{
                TargetPath = [string]$link.TargetPath
                Arguments = [string]$link.Arguments
                WorkingDirectory = [string]$link.WorkingDirectory
                WindowStyle = [int]$link.WindowStyle
                IconLocation = [string]$link.IconLocation
                Description = [string]$link.Description
            }
        } finally {
            foreach ($comObject in @($link, $shell)) {
                if ($null -ne $comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
                }
            }
        }
    }
    $write = {
        param([string]$Path, $Contract)

        $shell = $null
        $link = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($Path)
            $link.TargetPath = [string]$Contract.TargetPath
            $link.Arguments = [string]$Contract.Arguments
            $link.WorkingDirectory = [string]$Contract.WorkingDirectory
            $link.WindowStyle = [int]$Contract.WindowStyle
            $link.Description = [string]$Contract.Description
            if (-not [string]::IsNullOrWhiteSpace([string]$Contract.IconPath)) {
                $link.IconLocation = ([string]$Contract.IconPath + ',0')
            }
            $link.Save()
        } finally {
            foreach ($comObject in @($link, $shell)) {
                if ($null -ne $comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
                }
            }
        }
    }
    return [pscustomobject]@{ Read = $read; Write = $write }
}

function Assert-CpaStackShortcutStore {
    param([Parameter(Mandatory = $true)]$ShortcutStore)

    foreach ($name in @('Read', 'Write')) {
        $property = $ShortcutStore.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [scriptblock]) {
            throw 'ShortcutStore must provide Read and Write scriptblock operations.'
        }
    }
}

function Read-CpaStackShortcut {
    param(
        [Parameter(Mandatory = $true)]$ShortcutStore,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $reader = $ShortcutStore.Read
    return & $reader $Path
}

function Write-CpaStackShortcut {
    param(
        [Parameter(Mandatory = $true)]$ShortcutStore,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Contract
    )

    $writer = $ShortcutStore.Write
    & $writer $Path $Contract
}

function Get-CpaStackManagedShortcutContract {
    param([Parameter(Mandatory = $true)]$Context)

    if ($Context.LauncherPath.IndexOf('"') -ge 0) {
        throw 'Canonical launcher path must not contain a quote.'
    }
    $powershell = Get-CpaStackPreferredPowerShellPath
    $iconPath = Join-Path $Context.Root 'assets\cpa-shortcut.ico'
    Assert-CpaStackManagedChildPath -Root $Context.Root -Path $iconPath
    return [pscustomobject]@{
        TargetPath = $powershell
        Arguments = '-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}"' -f $Context.LauncherPath
        WorkingDirectory = [System.IO.Path]::GetFullPath((Join-Path $Context.Root 'ops')).TrimEnd('\')
        WindowStyle = 1
        IconPath = if (Test-Path -LiteralPath $iconPath -PathType Leaf) { [System.IO.Path]::GetFullPath($iconPath) } else { '' }
        Description = 'Quick-start CPA and Manager with visible status'
    }
}

function Get-CpaStackManagedShortcutFingerprint {
    param([Parameter(Mandatory = $true)]$Contract)

    $canonical = @(
        'contractVersion=' + $script:ShortcutContractVersion,
        'target=' + ([System.IO.Path]::GetFullPath([string]$Contract.TargetPath).ToUpperInvariant()),
        'arguments=' + [string]$Contract.Arguments,
        'workingDirectory=' + ([System.IO.Path]::GetFullPath([string]$Contract.WorkingDirectory).TrimEnd('\').ToUpperInvariant()),
        'windowStyle=' + [string][int]$Contract.WindowStyle,
        'icon=' + $(if ([string]::IsNullOrWhiteSpace([string]$Contract.IconPath)) { '' } else { [System.IO.Path]::GetFullPath([string]$Contract.IconPath).ToUpperInvariant() }),
        'description=' + [string]$Contract.Description
    ) -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Get-CpaStackShortcutIconPath {
    param([string]$IconLocation)

    if ([string]::IsNullOrWhiteSpace($IconLocation)) { return '' }
    $value = $IconLocation.Trim()
    if ($value -match '^(?<path>.*),(?<index>-?\d+)$') {
        $value = [string]$Matches['path']
    }
    return $value.Trim().Trim('"')
}

function Test-CpaStackShortcutMatchesContract {
    param(
        [Parameter(Mandatory = $true)]$Shortcut,
        [Parameter(Mandatory = $true)]$Contract
    )

    $actualTarget = try { [System.IO.Path]::GetFullPath([string]$Shortcut.TargetPath) } catch { '' }
    $actualWorking = try { [System.IO.Path]::GetFullPath([string]$Shortcut.WorkingDirectory).TrimEnd('\') } catch { '' }
    $expectedIcon = if ([string]::IsNullOrWhiteSpace([string]$Contract.IconPath)) { '' } else { [System.IO.Path]::GetFullPath([string]$Contract.IconPath) }
    $actualIcon = Get-CpaStackShortcutIconPath -IconLocation ([string]$Shortcut.IconLocation)
    if (-not [string]::IsNullOrWhiteSpace($actualIcon)) {
        $actualIcon = try { [System.IO.Path]::GetFullPath($actualIcon) } catch { '' }
    }
    return (
        [string]::Equals($actualTarget, [System.IO.Path]::GetFullPath([string]$Contract.TargetPath), [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]$Shortcut.Arguments -ceq [string]$Contract.Arguments -and
        [string]::Equals($actualWorking, [System.IO.Path]::GetFullPath([string]$Contract.WorkingDirectory).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -and
        [int]$Shortcut.WindowStyle -eq [int]$Contract.WindowStyle -and
        [string]::Equals($actualIcon, $expectedIcon, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]$Shortcut.Description -ceq [string]$Contract.Description
    )
}

function Test-CpaStackShortcutReferencesLauncher {
    param(
        [Parameter(Mandatory = $true)]$Shortcut,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Contract
    )

    $actualTarget = try { [System.IO.Path]::GetFullPath([string]$Shortcut.TargetPath) } catch { '' }
    if ([string]::Equals($actualTarget, $Context.LauncherPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $allowedPowerShellPaths = @(
        foreach ($name in @('pwsh.exe', 'powershell.exe')) {
            $command = Get-Command $name -ErrorAction SilentlyContinue
            if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
                [System.IO.Path]::GetFullPath([string]$command.Source)
            }
        }
    )
    if (@($allowedPowerShellPaths | Where-Object { [string]::Equals($actualTarget, $_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
        return $false
    }
    $launcherPattern = '(?i)(?:^|\s)-File\s+"' + [regex]::Escape($Context.LauncherPath) + '"\s*$'
    if ([string]$Shortcut.Arguments -match $launcherPattern) {
        return $true
    }

    # A prior managed root is safe to adopt because Ensure backs it up before
    # replacing it, and the recognized command can only launch the CPA starter.
    $legacyPattern = '(?i)^\s*-NoLogo\s+-NoProfile\s+(?:-NonInteractive\s+)?(?:-NoExit\s+)?(?:-WindowStyle\s+(?:Hidden|Minimized|Normal)\s+)?-ExecutionPolicy\s+Bypass\s+-File\s+"[^\"]+\\ops\\Start-CPA-Stack\.ps1"\s*$'
    if ([string]$Shortcut.Arguments -match $legacyPattern) {
        return $true
    }
    $originalLauncherPattern = '(?i)^\s*-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-NoExit\s+-File\s+"[^\"]+\\CPA-Stack\.ps1"\s+-Action\s+Restart\s*$'
    return [string]$Shortcut.Arguments -match $originalLauncherPattern
}

function Get-CpaStackManagedShortcutAcl {
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

function Set-CpaStackManagedShortcutAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($item.PSIsContainer) {
        if ($Acl -isnot [System.Security.AccessControl.DirectorySecurity]) {
            throw 'Managed shortcut directory requires a directory DACL.'
        }
        if ($null -ne $extensions) {
            [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]$item, [System.Security.AccessControl.DirectorySecurity]$Acl)
        } else {
            ([System.IO.DirectoryInfo]$item).SetAccessControl([System.Security.AccessControl.DirectorySecurity]$Acl)
        }
        return
    }
    if ($Acl -isnot [System.Security.AccessControl.FileSecurity]) {
        throw 'Managed shortcut file requires a file DACL.'
    }
    if ($null -ne $extensions) {
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]$item, [System.Security.AccessControl.FileSecurity]$Acl)
    } else {
        ([System.IO.FileInfo]$item).SetAccessControl([System.Security.AccessControl.FileSecurity]$Acl)
    }
}

function Test-CpaStackManagedShortcutPrivateAcl {
    param([Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl)

    if (-not $Acl.AreAccessRulesProtected) { return $false }
    try {
        $ownerSid = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $false
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($ownerSid -cne $currentSid) { return $false }
    $expected = @{
        $currentSid = $false
        'S-1-5-18' = $false
        'S-1-5-32-544' = $false
    }
    $rules = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne $expected.Count) { return $false }
    foreach ($rule in $rules) {
        $sid = [string]$rule.IdentityReference.Value
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
            $rule.InheritanceFlags -ne [System.Security.AccessControl.InheritanceFlags]::None -or
            $rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None -or
            $rule.IsInherited -or -not $expected.ContainsKey($sid) -or $expected[$sid]) {
            return $false
        }
        $expected[$sid] = $true
    }
    return @($expected.Values | Where-Object { -not $_ }).Count -eq 0
}

function Test-CpaStackManagedShortcutTrustedSecurityDescriptor {
    param(
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl,
        [switch]$RequireProtected
    )

    try {
        if ($RequireProtected -and -not $Acl.AreAccessRulesProtected) { return $false }
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $ownerSid = $Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -cne $currentSid) { return $false }
        $expectedSids = @{
            $currentSid = $false
            'S-1-5-18' = $false
            'S-1-5-32-544' = $false
        }
        $rules = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        if ($rules.Count -ne $expectedSids.Count) { return $false }
        foreach ($rule in $rules) {
            $sid = [string]$rule.IdentityReference.Value
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
                $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
                -not $expectedSids.ContainsKey($sid) -or $expectedSids[$sid]) {
                return $false
            }
            $expectedSids[$sid] = $true
        }
        return @($expectedSids.Values | Where-Object { -not $_ }).Count -eq 0
    } catch {
        return $false
    }
}

function Test-CpaStackManagedShortcutTrustedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireProtected
    )

    try {
        $acl = Get-CpaStackManagedShortcutAcl -Path $Path
        return Test-CpaStackManagedShortcutTrustedSecurityDescriptor -Acl $acl -RequireProtected:$RequireProtected
    } catch {
        return $false
    }
}

function New-CpaStackManagedShortcutTrustState {
    param(
        [Parameter(Mandatory = $true)][bool]$Trusted,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$InstanceId = ''
    )

    return [pscustomobject]@{
        Trusted = $Trusted
        Reason = $Reason
        InstanceId = $InstanceId
    }
}

function Get-CpaStackManagedShortcutTrustState {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $opsPath = Join-Path $rootFull 'ops'
    $statePath = Join-Path $rootFull 'state'
    $launcherPath = Join-Path $opsPath 'Start-CPA-Stack.ps1'
    $markerPath = Join-Path $rootFull '.cpa-stack-instance.json'
    $currentPath = Join-Path $statePath 'current.json'
    $paths = @(
        [pscustomobject]@{ Path = $rootFull; Type = 'Container'; Protected = $true },
        [pscustomobject]@{ Path = $opsPath; Type = 'Container'; Protected = $false },
        [pscustomobject]@{ Path = $statePath; Type = 'Container'; Protected = $false },
        [pscustomobject]@{ Path = $markerPath; Type = 'Leaf'; Protected = $false },
        [pscustomobject]@{ Path = $currentPath; Type = 'Leaf'; Protected = $false },
        [pscustomobject]@{ Path = $launcherPath; Type = 'Leaf'; Protected = $false }
    )

    try {
        Assert-CpaStackManagedRootNoReparse -Root $rootFull
        foreach ($entry in $paths) {
            if (-not (Test-Path -LiteralPath $entry.Path -PathType $entry.Type)) {
                return New-CpaStackManagedShortcutTrustState -Trusted $false -Reason 'CanonicalPathMissing'
            }
            if ([string]::Equals([string]$entry.Path, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                Assert-CpaStackManagedPathNoReparse -Root $rootFull -Path $rootFull
            } else {
                Assert-CpaStackManagedChildPath -Root $rootFull -Path $entry.Path
            }
            if (-not (Test-CpaStackManagedShortcutTrustedAcl -Path $entry.Path -RequireProtected:([bool]$entry.Protected))) {
                return New-CpaStackManagedShortcutTrustState -Trusted $false -Reason 'CanonicalAclInvalid'
            }
        }
    } catch {
        return New-CpaStackManagedShortcutTrustState -Trusted $false -Reason 'CanonicalPathUntrusted'
    }

    try {
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $marker = [System.IO.File]::ReadAllText($markerPath, $utf8) | ConvertFrom-Json -ErrorAction Stop
        $current = [System.IO.File]::ReadAllText($currentPath, $utf8) | ConvertFrom-Json -ErrorAction Stop
        $markerRoot = [System.IO.Path]::GetFullPath([string]$marker.root).TrimEnd('\')
        $currentRoot = [System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\')
        $instanceId = [string]$marker.instanceId
        if ([int]$marker.schemaVersion -ne 1 -or
            [int]$current.schemaVersion -ne 1 -or
            $instanceId -notmatch '^[0-9a-fA-F]{32}$' -or
            [string]$current.instanceId -cne $instanceId -or
            -not [string]::Equals($markerRoot, $rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($currentRoot, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return New-CpaStackManagedShortcutTrustState -Trusted $false -Reason 'CanonicalInstanceInvalid'
        }
        return New-CpaStackManagedShortcutTrustState -Trusted $true -Reason 'CanonicalInstanceTrusted' -InstanceId $instanceId
    } catch {
        return New-CpaStackManagedShortcutTrustState -Trusted $false -Reason 'CanonicalInstanceUnreadable'
    }
}

function Assert-CpaStackManagedShortcutTrustedContext {
    param([Parameter(Mandatory = $true)]$Context)

    $trust = Get-CpaStackManagedShortcutTrustState -Root $Context.Root
    if (-not $trust.Trusted -or [string]$trust.InstanceId -cne [string]$Context.InstanceId) {
        throw 'Managed shortcut trust context changed; refusing to write.'
    }
}

function Protect-CpaStackManagedShortcutFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = Get-CpaStackManagedShortcutAcl -Path $Path
    if (Test-CpaStackManagedShortcutPrivateAcl -Acl $current) { return }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    foreach ($sid in @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-CpaStackManagedShortcutAcl -Path $Path -Acl $acl
}

function Write-CpaStackManagedShortcutOwnership {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    $path = $Context.OwnershipPath
    Assert-CpaStackManagedChildPath -Root $Context.Root -Path $path
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $payload = [ordered]@{
        schemaVersion = 1
        instanceId = $Context.InstanceId
        path = $Context.ShortcutPath
        contractVersion = $script:ShortcutContractVersion
        fingerprint = $Fingerprint
    }
    $temporary = Join-Path $parent ('.managed-shortcut-' + [guid]::NewGuid().ToString('N') + '.json')
    $replaceBackup = Join-Path $parent ('.managed-shortcut-previous-' + [guid]::NewGuid().ToString('N') + '.json')
    $destinationExisted = Test-Path -LiteralPath $path -PathType Leaf
    $committed = $false
    $completed = $false
    try {
        [System.IO.File]::WriteAllText($temporary, ($payload | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        Protect-CpaStackManagedShortcutFile -Path $temporary
        if ($destinationExisted) {
            [System.IO.File]::Replace($temporary, $path, $replaceBackup)
        } else {
            [System.IO.File]::Move($temporary, $path)
        }
        $committed = $true
        if (-not (Test-CpaStackManagedShortcutPrivateAcl -Acl (Get-CpaStackManagedShortcutAcl -Path $path))) {
            throw 'Managed shortcut ownership state is not protected.'
        }
        $completed = $true
    } finally {
        if (-not $completed -and $committed) {
            if ($destinationExisted -and (Test-Path -LiteralPath $replaceBackup -PathType Leaf)) {
                $failedState = Join-Path $parent ('.managed-shortcut-failed-' + [guid]::NewGuid().ToString('N') + '.json')
                try {
                    [System.IO.File]::Replace($replaceBackup, $path, $failedState)
                } finally {
                    if (Test-Path -LiteralPath $failedState) { Remove-Item -LiteralPath $failedState -Force -ErrorAction SilentlyContinue }
                }
            } elseif (-not $destinationExisted -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-CpaStackManagedShortcutOwnership {
    param([Parameter(Mandatory = $true)]$Context)

    if (-not (Test-Path -LiteralPath $Context.OwnershipPath -PathType Leaf)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($Context.OwnershipPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Copy-CpaStackManagedShortcutIcon {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    $sourceFull = [System.IO.Path]::GetFullPath($SourcePath)
    if ([System.IO.Path]::GetExtension($sourceFull) -ine '.ico' -or -not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
        throw 'Legacy shortcut icon must be an existing .ico file.'
    }
    $sourceItem = Get-Item -Force -LiteralPath $sourceFull
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Legacy shortcut icon must not be a reparse point.'
    }
    $assets = Join-Path $Context.Root 'assets'
    $destination = Join-Path $assets 'cpa-shortcut.ico'
    Assert-CpaStackManagedChildPath -Root $Context.Root -Path $destination
    if ((Get-CpaStackManagedFileHash -Path $sourceFull) -eq (Get-CpaStackManagedFileHash -Path $destination)) {
        return $destination
    }
    if (-not (Test-Path -LiteralPath $assets -PathType Container)) {
        New-Item -ItemType Directory -Path $assets -Force | Out-Null
    }
    $temporary = Join-Path $assets ('.cpa-shortcut-' + [guid]::NewGuid().ToString('N') + '.ico')
    $replaceBackup = Join-Path $assets ('.cpa-shortcut-previous-' + [guid]::NewGuid().ToString('N') + '.ico')
    $destinationExisted = Test-Path -LiteralPath $destination -PathType Leaf
    $committed = $false
    $completed = $false
    try {
        [System.IO.File]::WriteAllBytes($temporary, [System.IO.File]::ReadAllBytes($sourceFull))
        Protect-CpaStackManagedShortcutFile -Path $temporary
        if ($destinationExisted) {
            [System.IO.File]::Replace($temporary, $destination, $replaceBackup)
        } else {
            [System.IO.File]::Move($temporary, $destination)
        }
        $committed = $true
        if ((Get-CpaStackManagedFileHash -Path $sourceFull) -ne (Get-CpaStackManagedFileHash -Path $destination)) {
            throw 'Managed shortcut icon copy failed verification.'
        }
        $completed = $true
    } finally {
        if (-not $completed -and $committed) {
            if ($destinationExisted -and (Test-Path -LiteralPath $replaceBackup -PathType Leaf)) {
                $failedIcon = Join-Path $assets ('.cpa-shortcut-failed-' + [guid]::NewGuid().ToString('N') + '.ico')
                try {
                    [System.IO.File]::Replace($replaceBackup, $destination, $failedIcon)
                } finally {
                    if (Test-Path -LiteralPath $failedIcon) { Remove-Item -LiteralPath $failedIcon -Force -ErrorAction SilentlyContinue }
                }
            } elseif (-not $destinationExisted -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
    return $destination
}

function Backup-CpaStackManagedShortcut {
    param([Parameter(Mandatory = $true)]$Context)

    $backupDirectory = Join-Path $Context.Root 'state\shortcut-backups'
    $backupPath = Join-Path $backupDirectory ('adopted-' + [guid]::NewGuid().ToString('N') + '.lnk')
    Assert-CpaStackManagedChildPath -Root $Context.Root -Path $backupPath
    if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
    }
    $temporary = Join-Path $backupDirectory ('.adopted-' + [guid]::NewGuid().ToString('N') + '.lnk')
    try {
        [System.IO.File]::WriteAllBytes($temporary, [System.IO.File]::ReadAllBytes($Context.ShortcutPath))
        Protect-CpaStackManagedShortcutFile -Path $temporary
        if ((Get-CpaStackManagedFileHash -Path $temporary) -ne (Get-CpaStackManagedFileHash -Path $Context.ShortcutPath)) {
            throw 'Desktop shortcut backup failed verification.'
        }
        [System.IO.File]::Move($temporary, $backupPath)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    if ((Get-CpaStackManagedFileHash -Path $backupPath) -ne (Get-CpaStackManagedFileHash -Path $Context.ShortcutPath)) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        throw 'Desktop shortcut backup failed verification.'
    }
    return $backupPath
}

function Get-CpaStackManagedShortcutStatus {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ShortcutStore
    )

    if (-not $Context.TrustState.Trusted) {
        return [pscustomobject]@{ Status = 'Conflict'; Reason = [string]$Context.TrustState.Reason; Contract = $null; Fingerprint = $null; Shortcut = $null }
    }

    $shortcutPresent = Test-Path -LiteralPath $Context.ShortcutPath
    $shortcutExists = Test-Path -LiteralPath $Context.ShortcutPath -PathType Leaf
    if ($shortcutPresent -and -not $shortcutExists) {
        return [pscustomobject]@{ Status = 'Conflict'; Reason = 'ShortcutPathIsNotAFile'; Contract = $null; Fingerprint = $null; Shortcut = $null }
    }
    $ownershipPresent = Test-Path -LiteralPath $Context.OwnershipPath
    $ownershipExists = Test-Path -LiteralPath $Context.OwnershipPath -PathType Leaf
    if ($ownershipPresent -and -not $ownershipExists) {
        return [pscustomobject]@{ Status = 'Conflict'; Reason = 'OwnershipPathIsNotAFile'; Contract = $null; Fingerprint = $null; Shortcut = $null }
    }
    $ownership = $null
    if ($ownershipExists) {
        try {
            Assert-CpaStackManagedChildPath -Root $Context.Root -Path $Context.OwnershipPath
            $ownershipAcl = Get-CpaStackManagedShortcutAcl -Path $Context.OwnershipPath
            if (-not (Test-CpaStackManagedShortcutPrivateAcl -Acl $ownershipAcl)) {
                return [pscustomobject]@{ Status = 'Conflict'; Reason = 'OwnershipAclInvalid'; Contract = $null; Fingerprint = $null; Shortcut = $null }
            }
            $ownership = Read-CpaStackManagedShortcutOwnership -Context $Context
        } catch {
            return [pscustomobject]@{ Status = 'Conflict'; Reason = 'OwnershipStateUnreadable'; Contract = $null; Fingerprint = $null; Shortcut = $null }
        }
        if ($null -eq $ownership) {
            return [pscustomobject]@{ Status = 'Conflict'; Reason = 'OwnershipStateInvalid'; Contract = $null; Fingerprint = $null; Shortcut = $null }
        }
    }
    if (-not $shortcutExists -and $null -eq $ownership) {
        return [pscustomobject]@{ Status = 'Absent'; Reason = 'ShortcutAndOwnershipMissing'; Contract = $null; Fingerprint = $null }
    }
    $contract = Get-CpaStackManagedShortcutContract -Context $Context
    $fingerprint = Get-CpaStackManagedShortcutFingerprint -Contract $contract
    if ($null -eq $ownership) {
        try {
            $shortcut = Read-CpaStackShortcut -ShortcutStore $ShortcutStore -Path $Context.ShortcutPath
        } catch {
            return [pscustomobject]@{ Status = 'Conflict'; Reason = 'ShortcutUnreadable'; Contract = $contract; Fingerprint = $fingerprint; Shortcut = $null }
        }
        if (Test-CpaStackShortcutReferencesLauncher -Shortcut $shortcut -Context $Context -Contract $contract) {
            return [pscustomobject]@{ Status = 'Adoptable'; Reason = 'CanonicalLauncherWithoutOwnership'; Contract = $contract; Fingerprint = $fingerprint; Shortcut = $shortcut }
        }
        return [pscustomobject]@{ Status = 'Conflict'; Reason = 'ShortcutIsNotManaged'; Contract = $contract; Fingerprint = $fingerprint; Shortcut = $shortcut }
    }
    $ownershipNames = @($ownership.PSObject.Properties.Name)
    $ownershipContractVersion = [int]$ownership.contractVersion
    $ownershipValid = (
        ($ownershipNames -join ',') -ceq 'schemaVersion,instanceId,path,contractVersion,fingerprint' -and
        [int]$ownership.schemaVersion -eq 1 -and
        [string]$ownership.instanceId -ceq $Context.InstanceId -and
        [string]::Equals([string]$ownership.path, $Context.ShortcutPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        $ownershipContractVersion -ge 1 -and
        $ownershipContractVersion -le $script:ShortcutContractVersion
    )
    if (-not $ownershipValid) {
        return [pscustomobject]@{ Status = 'Conflict'; Reason = 'OwnershipStateInvalid'; Contract = $contract; Fingerprint = $fingerprint }
    }
    if (-not $shortcutExists) {
        return [pscustomobject]@{ Status = 'Drifted'; Reason = 'ManagedShortcutMissing'; Contract = $contract; Fingerprint = $fingerprint; Ownership = $ownership }
    }
    try {
        $shortcut = Read-CpaStackShortcut -ShortcutStore $ShortcutStore -Path $Context.ShortcutPath
    } catch {
        return [pscustomobject]@{ Status = 'Drifted'; Reason = 'ManagedShortcutUnreadable'; Contract = $contract; Fingerprint = $fingerprint; Ownership = $ownership }
    }
    if ($ownershipContractVersion -eq $script:ShortcutContractVersion -and
        [string]$ownership.fingerprint -ceq $fingerprint -and
        (Test-CpaStackShortcutMatchesContract -Shortcut $shortcut -Contract $contract)) {
        return [pscustomobject]@{ Status = 'Matching'; Reason = 'ContractMatches'; Contract = $contract; Fingerprint = $fingerprint; Ownership = $ownership }
    }
    return [pscustomobject]@{ Status = 'Drifted'; Reason = 'ManagedShortcutContractDrift'; Contract = $contract; Fingerprint = $fingerprint; Ownership = $ownership }
}

function New-CpaStackManagedShortcutResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][bool]$Changed,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Reason,
        [bool]$Adopted = $false,
        [string]$BackupPath = ''
    )

    return [pscustomobject]@{
        operation = 'shortcut'
        success = $true
        status = $Status
        changed = $Changed
        path = $Path
        reason = $Reason
        adopted = $Adopted
        backupPath = if ([string]::IsNullOrWhiteSpace($BackupPath)) { $null } else { $BackupPath }
    }
}

function Get-CpaStackManagedShortcutContext {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$DesktopDirectory,
        [Parameter(Mandatory = $true)][string]$ShortcutPath
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $desktopFull = [System.IO.Path]::GetFullPath($DesktopDirectory).TrimEnd('\')
    $shortcutFull = [System.IO.Path]::GetFullPath($ShortcutPath)
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw 'Managed root does not exist.'
    }
    $filesystemRoot = [System.IO.Path]::GetPathRoot($rootFull).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($filesystemRoot) -or $rootFull -ieq $filesystemRoot -or $rootFull.StartsWith('\\')) {
        throw 'Managed root must be a non-root local path.'
    }
    if (-not (Test-Path -LiteralPath $desktopFull -PathType Container)) {
        throw 'Desktop directory does not exist.'
    }
    $desktopItem = Get-Item -Force -LiteralPath $desktopFull
    if (($desktopItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Desktop directory must not be a reparse point.'
    }
    if ([System.IO.Path]::GetExtension($shortcutFull) -ine '.lnk' -or
        -not [string]::Equals([System.IO.Path]::GetDirectoryName($shortcutFull).TrimEnd('\'), $desktopFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Managed shortcut must be a direct .lnk child of the current user Desktop.'
    }
    if (Test-Path -LiteralPath $shortcutFull) {
        $shortcutItem = Get-Item -Force -LiteralPath $shortcutFull
        if (($shortcutItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Managed desktop shortcut must not be a reparse point.'
        }
    }

    $launcher = Join-Path $rootFull 'ops\Start-CPA-Stack.ps1'
    $trustState = Get-CpaStackManagedShortcutTrustState -Root $rootFull

    return [pscustomobject]@{
        Root = $rootFull
        Desktop = $desktopFull
        ShortcutPath = $shortcutFull
        LauncherPath = [System.IO.Path]::GetFullPath($launcher)
        InstanceId = [string]$trustState.InstanceId
        OwnershipPath = Join-Path $rootFull 'state\managed-shortcut.json'
        TrustState = $trustState
    }
}

function Invoke-CpaStackManagedShortcutWriteTransaction {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$ShortcutStore,
        [Parameter(Mandatory = $true)]$Status,
        [string]$LegacyIconPath = ''
    )

    $isAdoption = [string]$Status.Status -eq 'Adoptable'
    $shortcutExisted = Test-Path -LiteralPath $Context.ShortcutPath -PathType Leaf
    $originalHash = if ($shortcutExisted) { Get-CpaStackManagedFileHash -Path $Context.ShortcutPath } else { $null }
    $temporaryShortcut = Join-Path $Context.Desktop ('.cpa-shortcut-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $replaceBackup = Join-Path $Context.Desktop ('.cpa-shortcut-replaced-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $persistentBackup = $null

    $managedIconPath = Join-Path $Context.Root 'assets\cpa-shortcut.ico'
    Assert-CpaStackManagedChildPath -Root $Context.Root -Path $managedIconPath
    $managedIconExisted = Test-Path -LiteralPath $managedIconPath -PathType Leaf
    $managedIconBytes = if ($managedIconExisted) { [System.IO.File]::ReadAllBytes($managedIconPath) } else { $null }
    $managedIconHash = if ($managedIconExisted) { Get-CpaStackManagedFileHash -Path $managedIconPath } else { $null }

    $shortcutCommitted = $false
    $completed = $false
    try {
        Assert-CpaStackManagedShortcutTrustedContext -Context $Context
        if ($isAdoption) {
            $persistentBackup = Backup-CpaStackManagedShortcut -Context $Context
        }

        $iconSource = $LegacyIconPath
        if ($isAdoption -and [string]::IsNullOrWhiteSpace($iconSource)) {
            $existingIcon = Get-CpaStackShortcutIconPath -IconLocation ([string]$Status.Shortcut.IconLocation)
            if (-not [string]::IsNullOrWhiteSpace($existingIcon) -and
                [System.IO.Path]::GetExtension($existingIcon) -ieq '.ico' -and
                (Test-Path -LiteralPath $existingIcon -PathType Leaf)) {
                $iconSource = $existingIcon
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($iconSource)) {
            [void](Copy-CpaStackManagedShortcutIcon -Context $Context -SourcePath $iconSource)
        }

        $contract = Get-CpaStackManagedShortcutContract -Context $Context
        $fingerprint = Get-CpaStackManagedShortcutFingerprint -Contract $contract
        Write-CpaStackShortcut -ShortcutStore $ShortcutStore -Path $temporaryShortcut -Contract $contract
        if (-not (Test-Path -LiteralPath $temporaryShortcut -PathType Leaf)) {
            throw 'ShortcutStore did not create the staged shortcut.'
        }
        $staged = Read-CpaStackShortcut -ShortcutStore $ShortcutStore -Path $temporaryShortcut
        if (-not (Test-CpaStackShortcutMatchesContract -Shortcut $staged -Contract $contract)) {
            throw 'Staged desktop shortcut failed contract verification.'
        }

        Assert-CpaStackManagedShortcutTrustedContext -Context $Context
        if ($shortcutExisted) {
            if ((Get-CpaStackManagedFileHash -Path $Context.ShortcutPath) -cne $originalHash) {
                throw 'Desktop shortcut changed while Ensure was staging its replacement.'
            }
            [System.IO.File]::Replace($temporaryShortcut, $Context.ShortcutPath, $replaceBackup)
        } else {
            if (Test-Path -LiteralPath $Context.ShortcutPath) {
                throw 'Desktop shortcut changed while Ensure was staging its replacement.'
            }
            [System.IO.File]::Move($temporaryShortcut, $Context.ShortcutPath)
        }
        $shortcutCommitted = $true

        $committed = Read-CpaStackShortcut -ShortcutStore $ShortcutStore -Path $Context.ShortcutPath
        if (-not (Test-CpaStackShortcutMatchesContract -Shortcut $committed -Contract $contract)) {
            throw 'Committed desktop shortcut failed contract verification.'
        }

        Assert-CpaStackManagedShortcutTrustedContext -Context $Context
        $ownershipProperty = $Status.PSObject.Properties['Ownership']
        $ownership = if ($null -eq $ownershipProperty) { $null } else { $ownershipProperty.Value }
        if ($null -eq $ownership -or [string]$ownership.fingerprint -cne $fingerprint) {
            Write-CpaStackManagedShortcutOwnership -Context $Context -Fingerprint $fingerprint
        }

        $reason = switch ([string]$Status.Status) {
            'Absent' { 'ShortcutCreated' }
            'Adoptable' { 'ShortcutAdopted' }
            'Drifted' { 'ShortcutRepaired' }
            default { throw 'Unsupported managed shortcut write state.' }
        }
        $completed = $true
        return New-CpaStackManagedShortcutResult -Status 'Matching' -Changed $true -Path $Context.ShortcutPath -Reason $reason -Adopted $isAdoption -BackupPath $persistentBackup
    } finally {
        if (-not $completed) {
            if ($shortcutCommitted) {
                if ($shortcutExisted -and (Test-Path -LiteralPath $replaceBackup -PathType Leaf)) {
                    $failedReplacement = Join-Path $Context.Desktop ('.cpa-shortcut-failed-' + [guid]::NewGuid().ToString('N') + '.lnk')
                    try {
                        if (Test-Path -LiteralPath $Context.ShortcutPath -PathType Leaf) {
                            [System.IO.File]::Replace($replaceBackup, $Context.ShortcutPath, $failedReplacement)
                        } else {
                            [System.IO.File]::Move($replaceBackup, $Context.ShortcutPath)
                        }
                    } finally {
                        if (Test-Path -LiteralPath $failedReplacement) {
                            Remove-Item -LiteralPath $failedReplacement -Force -ErrorAction SilentlyContinue
                        }
                    }
                } elseif (-not $shortcutExisted -and (Test-Path -LiteralPath $Context.ShortcutPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $Context.ShortcutPath -Force -ErrorAction SilentlyContinue
                }
            }

            if ($managedIconExisted) {
                if ((Get-CpaStackManagedFileHash -Path $managedIconPath) -cne $managedIconHash) {
                    [System.IO.File]::WriteAllBytes($managedIconPath, $managedIconBytes)
                    Protect-CpaStackManagedShortcutFile -Path $managedIconPath
                }
            } elseif (Test-Path -LiteralPath $managedIconPath -PathType Leaf) {
                Remove-Item -LiteralPath $managedIconPath -Force -ErrorAction SilentlyContinue
            }

            if ($persistentBackup -and (Test-Path -LiteralPath $persistentBackup -PathType Leaf)) {
                Remove-Item -LiteralPath $persistentBackup -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($temporary in @($temporaryShortcut, $replaceBackup)) {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-CpaStackManagedShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Ensure')][string]$Action,
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$DesktopDirectory = [Environment]::GetFolderPath('Desktop'),
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [switch]$AdoptExisting,
        [string]$LegacyIconPath = '',
        $ShortcutStore
    )

    $context = Get-CpaStackManagedShortcutContext -Root $Root -DesktopDirectory $DesktopDirectory -ShortcutPath $ShortcutPath
    if ($null -eq $ShortcutStore) {
        $ShortcutStore = New-CpaStackWshShortcutStore
    }
    Assert-CpaStackShortcutStore -ShortcutStore $ShortcutStore
    $status = Get-CpaStackManagedShortcutStatus -Context $context -ShortcutStore $ShortcutStore

    if ($Action -eq 'Check') {
        return New-CpaStackManagedShortcutResult -Status $status.Status -Changed $false -Path $context.ShortcutPath -Reason $status.Reason
    }
    if ($status.Status -eq 'Matching') {
        return New-CpaStackManagedShortcutResult -Status 'Matching' -Changed $false -Path $context.ShortcutPath -Reason 'AlreadyMatching'
    }
    if ($status.Status -eq 'Adoptable' -and -not $AdoptExisting) {
        throw 'Existing canonical shortcut is adoptable only with explicit AdoptExisting authorization.'
    }
    if ($status.Status -eq 'Conflict') {
        throw 'Managed shortcut conflict; refusing to overwrite an unknown or invalid shortcut.'
    }
    if ($status.Status -notin @('Absent', 'Adoptable', 'Drifted')) {
        throw 'Managed shortcut state cannot be ensured safely.'
    }

    return Invoke-CpaStackManagedShortcutWriteTransaction -Context $context -ShortcutStore $ShortcutStore -Status $status -LegacyIconPath $LegacyIconPath
}
Export-ModuleMember -Function Invoke-CpaStackManagedShortcut
