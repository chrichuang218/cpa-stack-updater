$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$sourceRepo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('cpa-stack-tests-' + [guid]::NewGuid().ToString('N'))
$pluginRootJunction = $null
$managerDataJunction = $null
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $fixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $sourceRepo `
        -DestinationRepository (Join-Path $temp 'repository') `
        -LocalAppDataRoot (Join-Path $temp 'local-app-data')
    . (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
    $cjkSuffix = -join @([char]0x6D4B, [char]0x8BD5)
    $safeRoot = Join-Path $temp ('CPA Stack ' + $cjkSuffix)
    New-Item -ItemType Directory -Force -Path $safeRoot | Out-Null

    Assert-Throws { Assert-CpaStackSecureLocalRoot -Path ([System.IO.Path]::GetPathRoot($safeRoot)) } 'Drive root must be rejected'
    Assert-Throws { Assert-CpaStackSecureLocalRoot -Path '\\server\share\CPAStack' } 'UNC path must be rejected'
    Assert-Equal ([System.IO.Path]::GetFullPath($safeRoot).TrimEnd('\')) (Assert-CpaStackSecureLocalRoot -Path $safeRoot) 'Dedicated local root is accepted'

    Protect-CpaStackPrivateDirectory -Path $safeRoot
    $acl = Get-Acl -LiteralPath $safeRoot
    Assert-True $acl.AreAccessRulesProtected 'Managed root ACL inheritance is disabled'
    $ownerSid = [System.Security.Principal.NTAccount]::new([string]$acl.Owner).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Assert-Equal ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) $ownerSid 'Managed root owner is the current Windows user'

    $pluginSource = Join-Path $temp 'plugin-source'
    $pluginNested = Join-Path $pluginSource 'nested'
    $pluginDestination = Join-Path $temp 'plugin-destination'
    New-Item -ItemType Directory -Force -Path $pluginNested | Out-Null
    Set-Content -LiteralPath (Join-Path $pluginSource 'plugin.ps1') -Value '# plugin fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pluginNested 'helper.ps1') -Value '# nested plugin fixture' -Encoding ASCII
    Copy-CpaStackPluginTree -Source $pluginSource -Destination $pluginDestination
    Assert-CpaStackPrivateTree -Root $pluginDestination -Description 'Test plugins'
    Assert-True (Test-Path -LiteralPath (Join-Path $pluginDestination 'nested\helper.ps1') -PathType Leaf) 'Plugin copy preserves nested files'
    $pluginManifest = Get-CpaStackTreeManifest -Root $pluginDestination
    $repeatPluginManifest = Get-CpaStackTreeManifest -Root $pluginDestination
    Assert-Equal $pluginManifest.sha256 $repeatPluginManifest.sha256 'Tree manifest digest is deterministic'
    $nestedManifestEntry = @($pluginManifest.entries | Where-Object { $_.relativePath -eq 'nested\helper.ps1' })
    Assert-Equal 1 $nestedManifestEntry.Count 'Tree manifest records each relative plugin path'
    Assert-Equal 'file' $nestedManifestEntry[0].type 'Tree manifest records the entry type'
    Assert-True ([Int64]$nestedManifestEntry[0].length -gt 0) 'Tree manifest records file length'
    Assert-True ([string]$nestedManifestEntry[0].sha256 -match '^[0-9A-F]{64}$') 'Tree manifest records file SHA256'
    Set-Content -LiteralPath (Join-Path $pluginDestination 'nested\helper.ps1') -Value '# changed nested plugin fixture' -Encoding ASCII
    $changedPluginManifest = Get-CpaStackTreeManifest -Root $pluginDestination
    Assert-False ($changedPluginManifest.sha256 -eq $pluginManifest.sha256) 'Tree manifest changes when candidate content changes'

    $untrustedSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $pluginFile = Join-Path $pluginDestination 'plugin.ps1'
    $fileAcl = Get-Acl -LiteralPath $pluginFile
    [void]$fileAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::Write,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $pluginFile -AclObject $fileAcl
    Assert-ThrowsMatch {
        Assert-CpaStackPrivateTree -Root $pluginDestination -Description 'Test plugins'
    } 'unexpected identity' 'An explicit untrusted write ACE on a plugin file is rejected'

    Protect-CpaStackPrivateTree -Root $pluginDestination
    $pluginSubdirectory = Join-Path $pluginDestination 'nested'
    $directoryAcl = Get-Acl -LiteralPath $pluginSubdirectory
    [void]$directoryAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::Write,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $pluginSubdirectory -AclObject $directoryAcl
    Assert-ThrowsMatch {
        Assert-CpaStackPrivateTree -Root $pluginDestination -Description 'Test plugins'
    } 'unexpected identity' 'An explicit untrusted write ACE on a plugin subdirectory is rejected'
    Protect-CpaStackPrivateTree -Root $pluginDestination

    $pluginJunctionTarget = Join-Path $temp 'plugin-junction-target'
    $pluginRootJunction = Join-Path $temp 'plugin-root-junction'
    $rejectedPluginCopy = Join-Path $temp 'rejected-plugin-copy'
    New-Item -ItemType Directory -Force -Path $pluginJunctionTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $pluginJunctionTarget 'external.ps1') -Value '# external plugin fixture' -Encoding ASCII
    New-Item -ItemType Junction -Path $pluginRootJunction -Target $pluginJunctionTarget | Out-Null
    Assert-ThrowsMatch {
        Copy-CpaStackPluginTree -Source $pluginRootJunction -Destination $rejectedPluginCopy
    } 'reparse point' 'A plugins root junction is rejected before copying executable code'
    Assert-False (Test-Path -LiteralPath $rejectedPluginCopy) 'A rejected plugins junction does not create a destination tree'

    $managerData = Join-Path $temp 'manager-data'
    Protect-CpaStackPrivateDirectory -Path $managerData
    foreach ($name in @('usage.sqlite', 'data.key', 'usage.sqlite-wal', 'usage.sqlite-shm')) {
        Set-Content -LiteralPath (Join-Path $managerData $name) -Value 'manager data fixture' -Encoding ASCII
    }
    $walAcl = Get-Acl -LiteralPath (Join-Path $managerData 'usage.sqlite-wal')
    Assert-False $walAcl.AreAccessRulesProtected 'Manager WAL inherits the protected data-root ACL'
    Assert-CpaStackPrivateTree -Root $managerData -Description 'Manager data fixture' -AllowInheritedDescendants
    Assert-ThrowsMatch {
        Assert-CpaStackPrivateTree -Root $managerData -Description 'Manager data fixture'
    } 'ACL inheritance is enabled' 'Strict private-tree checks still reject inherited descendants by default'

    [void]$walAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::Write,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath (Join-Path $managerData 'usage.sqlite-wal') -AclObject $walAcl
    Assert-ThrowsMatch {
        Assert-CpaStackPrivateTree -Root $managerData -Description 'Manager data fixture' -AllowInheritedDescendants
    } 'unexpected identity' 'Manager WAL rejects an explicit untrusted write ACE'
    Protect-CpaStackPrivateTree -Root $managerData

    $managerJunctionTarget = Join-Path $temp 'manager-junction-target'
    $managerDataJunction = Join-Path $managerData 'external-data'
    New-Item -ItemType Directory -Force -Path $managerJunctionTarget | Out-Null
    New-Item -ItemType Junction -Path $managerDataJunction -Target $managerJunctionTarget | Out-Null
    Assert-ThrowsMatch {
        Assert-CpaStackPrivateTree -Root $managerData -Description 'Manager data fixture' -AllowInheritedDescendants
    } 'reparse point' 'Manager data rejects a nested junction'
    [System.IO.Directory]::Delete($managerDataJunction)
    $managerDataJunction = $null

    $legacyManagerParent = Join-Path $temp 'legacy-manager-parent'
    Protect-CpaStackPrivateDirectory -Path $legacyManagerParent
    $legacyManagerRuntime = Join-Path $legacyManagerParent 'runtime'
    $legacyManagerData = Join-Path $legacyManagerParent 'data'
    New-Item -ItemType Directory -Force -Path $legacyManagerRuntime, $legacyManagerData | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyManagerRuntime 'cpa-manager-plus.exe') -Value 'legacy manager executable' -Encoding ASCII
    foreach ($name in @('usage.sqlite', 'data.key', 'usage.sqlite-wal', 'usage.sqlite-shm')) {
        Set-Content -LiteralPath (Join-Path $legacyManagerData $name) -Value 'legacy manager data' -Encoding ASCII
    }
    Protect-CpaStackPrivateTree -Root $legacyManagerRuntime
    Protect-CpaStackPrivateTree -Root $legacyManagerData
    Assert-CpaStackLegacyManagerSource -Runtime $legacyManagerRuntime -Data $legacyManagerData
    $legacyManagerParentAcl = Get-Acl -LiteralPath $legacyManagerParent
    [void]$legacyManagerParentAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyManagerParent -AclObject $legacyManagerParentAcl
    Assert-ThrowsMatch {
        Assert-CpaStackLegacyManagerSource -Runtime $legacyManagerRuntime -Data $legacyManagerData
    } 'replace descendants' 'Legacy Manager rejects DELETE_CHILD on the runtime/data parent'
    Protect-CpaStackPrivateDirectory -Path $legacyManagerParent

    $legacyGrandparent = Join-Path $temp 'legacy-grandparent'
    New-Item -ItemType Directory -Force -Path $legacyGrandparent | Out-Null
    Protect-CpaStackPrivateDirectory -Path $legacyGrandparent
    $legacyParent = Join-Path $legacyGrandparent 'legacy-read-parent'
    New-Item -ItemType Directory -Force -Path $legacyParent | Out-Null
    Protect-CpaStackPrivateDirectory -Path $legacyParent
    $usersSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $legacyParentAcl = Get-Acl -LiteralPath $legacyParent
    [void]$legacyParentAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $usersSid,
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyParent -AclObject $legacyParentAcl
    $legacyRuntime = Join-Path $legacyParent 'runtime'
    $legacyAuth = Join-Path $legacyRuntime 'auth'
    $legacyPlugins = Join-Path $legacyRuntime 'plugins'
    New-Item -ItemType Directory -Force -Path $legacyAuth, $legacyPlugins | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyRuntime 'cli-proxy-api.exe') -Value 'legacy executable fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $legacyRuntime 'config.yaml') -Value "host: `"127.0.0.1`"`r`nport: 8317" -Encoding ASCII
    $legacyAuthFile = Join-Path $legacyAuth 'account.json'
    $legacyPluginFile = Join-Path $legacyPlugins 'plugin.ps1'
    Set-Content -LiteralPath $legacyAuthFile -Value '{}' -Encoding ASCII
    Set-Content -LiteralPath $legacyPluginFile -Value '# legacy plugin' -Encoding ASCII
    $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($legacyPath in @($legacyRuntime, $legacyAuth, $legacyPlugins, (Join-Path $legacyRuntime 'cli-proxy-api.exe'), (Join-Path $legacyRuntime 'config.yaml'), $legacyAuthFile, $legacyPluginFile)) {
        $legacyAcl = Get-Acl -LiteralPath $legacyPath
        $legacyAcl.SetOwner($currentUserSid)
        Set-Acl -LiteralPath $legacyPath -AclObject $legacyAcl
    }
    $inheritedUsersRead = @(Get-Acl -LiteralPath $legacyAuthFile).Access | Where-Object {
        $_.IsInherited -and $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $usersSid.Value
    }
    Assert-True (@($inheritedUsersRead).Count -gt 0) 'Legacy fixture has an inherited Users read ACE'
    Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')

    $legacyPluginAcl = Get-Acl -LiteralPath $legacyPluginFile
    [void]$legacyPluginAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::Write,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyPluginFile -AclObject $legacyPluginAcl
    Assert-ThrowsMatch {
        Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')
    } 'mutable access' 'Legacy plugins reject a non-trusted write ACE without laundering it'
    Protect-CpaStackSecretFile -Path $legacyPluginFile

    $legacyAuthAcl = Get-Acl -LiteralPath $legacyAuthFile
    [void]$legacyAuthAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::Modify,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyAuthFile -AclObject $legacyAuthAcl
    Assert-ThrowsMatch {
        Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')
    } 'mutable access' 'Legacy auth rejects a non-trusted mutable ACE without laundering it'
    Protect-CpaStackSecretFile -Path $legacyAuthFile

    $legacyRuntimeAcl = Get-Acl -LiteralPath $legacyRuntime
    [void]$legacyRuntimeAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        ([System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles),
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyRuntime -AclObject $legacyRuntimeAcl
    Assert-ThrowsMatch {
        Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')
    } 'mutable access' 'Legacy runtime parent rejects non-trusted child replacement rights'
    Protect-CpaStackPrivateDirectory -Path $legacyRuntime
    Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')

    $legacyParentAcl = Get-Acl -LiteralPath $legacyParent
    [void]$legacyParentAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyParent -AclObject $legacyParentAcl
    Assert-ThrowsMatch {
        Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')
    } 'replace descendants' 'Legacy source rejects DELETE_CHILD on its immediate parent'
    Protect-CpaStackPrivateDirectory -Path $legacyParent

    $legacyGrandparentAcl = Get-Acl -LiteralPath $legacyGrandparent
    [void]$legacyGrandparentAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $legacyGrandparent -AclObject $legacyGrandparentAcl
    Assert-ThrowsMatch {
        Assert-CpaStackLegacyCpaSource -Runtime $legacyRuntime -ConfigPath (Join-Path $legacyRuntime 'config.yaml')
    } 'replace descendants' 'Legacy source rejects DELETE_CHILD on a higher ancestor'

    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $safeRoot -AllowCreate
    Assert-True ([string]$marker.instanceId -match '^[0-9a-f]{32}$') 'Instance marker has an id'
    [void](Ensure-CpaStackInstanceMarker -ControlRoot $safeRoot)

    $allowed = Join-Path $safeRoot 'work\current'
    Assert-CpaStackChildPath -Root $safeRoot -Path $allowed
    Assert-Throws { Assert-CpaStackChildPath -Root $safeRoot -Path (Join-Path $safeRoot 'data\unrelated') } 'Unmanaged data slot is rejected'
    Assert-Throws { Assert-CpaStackChildPath -Root $safeRoot -Path (Join-Path $safeRoot 'work\other') } 'Unmanaged work slot is rejected'

    $lock = Enter-CpaStackOperationLock -Name ('test-' + [guid]::NewGuid().ToString('N'))
    try {
        Assert-Throws { Enter-CpaStackOperationLock -Name ([System.IO.Path]::GetFileNameWithoutExtension($lock.Name)) } 'Second lock holder is rejected'
    } finally {
        Exit-CpaStackOperationLock -Mutex $lock
    }

    $pathPrefix = ([System.IO.Path]::GetFullPath($temp).TrimEnd('\') + '\')
    $containerAtLimit = $pathPrefix + ('d' * (247 - $pathPrefix.Length))
    $leafAtLimit = $pathPrefix + ('f' * (259 - $pathPrefix.Length))
    Assert-CpaStackPathBudget -Paths @($containerAtLimit) -PathType Container
    Assert-CpaStackPathBudget -Paths @($leafAtLimit) -PathType Leaf
    Assert-ThrowsMatch { Assert-CpaStackPathBudget -Paths @($containerAtLimit + 'x') -PathType Container } '247' 'Directory path budget rejects 248 characters'
    Assert-ThrowsMatch { Assert-CpaStackPathBudget -Paths @($leafAtLimit + 'x') -PathType Leaf } '259' 'File path budget rejects 260 characters'

    $jsonAtLimit = $pathPrefix + ('j' * (222 - $pathPrefix.Length))
    Assert-CpaStackJsonWritePathBudget -Paths @($jsonAtLimit)
    Assert-ThrowsMatch { Assert-CpaStackJsonWritePathBudget -Paths @($jsonAtLimit + 'x') } '259' 'Atomic JSON temp suffix is included in the preflight budget'
    $slotAtLimit = $pathPrefix + ('s' * (205 - $pathPrefix.Length))
    Assert-CpaStackPathBudget -Paths @($slotAtLimit + '.previous-' + ('0' * 32)) -PathType Container
    Assert-ThrowsMatch { Assert-CpaStackPathBudget -Paths @(($slotAtLimit + 'x') + '.previous-' + ('0' * 32)) -PathType Container } '247' 'Directory-slot previous suffix is included in the preflight budget'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $badZip = Join-Path $temp 'bad.zip'
    $stream = [System.IO.File]::Open($badZip, [System.IO.FileMode]::Create)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('../escape.txt')
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.Write('blocked') } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    Assert-Throws { Expand-CpaStackSafeArchive -ArchivePath $badZip -DestinationPath (Join-Path $temp 'bad-out') } 'ZIP traversal is rejected'
} finally {
    if ($managerDataJunction -and (Test-Path -LiteralPath $managerDataJunction)) {
        [System.IO.Directory]::Delete($managerDataJunction)
    }
    if ($pluginRootJunction -and (Test-Path -LiteralPath $pluginRootJunction)) {
        [System.IO.Directory]::Delete($pluginRootJunction)
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

'Path safety tests passed.'
