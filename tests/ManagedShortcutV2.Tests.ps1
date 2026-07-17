$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repo 'skills\cpa-safe-upgrade\modules\CpaStack.ManagedShortcut.psm1'
Import-Module $modulePath -Force

function Get-TestTreeSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
        [System.Security.AccessControl.AccessControlSections]::Group -bor
        [System.Security.AccessControl.AccessControlSections]::Access
    $items = @((Get-Item -Force -LiteralPath $Path)) + @(Get-ChildItem -Force -LiteralPath $Path -Recurse)
    return @(
        $items | ForEach-Object {
            $hash = if (-not $_.PSIsContainer) { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash } else { '' }
            $writeTicks = if ($_.PSIsContainer) { '' } else { $_.LastWriteTimeUtc.Ticks }
            $sddl = (Get-TestPathAcl -Path $_.FullName).GetSecurityDescriptorSddlForm($sections)
            '{0}|{1}|{2}|{3}|{4}' -f $_.FullName, [bool]$_.PSIsContainer, $writeTicks, $hash, $sddl
        } | Sort-Object
    )
}

function Read-TestShortcut {
    param([Parameter(Mandatory = $true)][string]$Path)

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

function Write-TestShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [int]$WindowStyle = 1,
        [string]$IconPath = '',
        [string]$Description = ''
    )

    $shell = $null
    $link = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($Path)
        $link.TargetPath = $TargetPath
        $link.Arguments = $Arguments
        $link.WorkingDirectory = $WorkingDirectory
        $link.WindowStyle = $WindowStyle
        $link.Description = $Description
        if ($IconPath) { $link.IconLocation = $IconPath + ',0' }
        $link.Save()
    } finally {
        foreach ($comObject in @($link, $shell)) {
            if ($null -ne $comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
        }
    }
}

function New-TestCanonicalRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$InstanceId
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Protect-TestDirectory -Path $Root
    foreach ($directory in @((Join-Path $Root 'ops'), (Join-Path $Root 'state'))) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $Root 'ops\Start-CPA-Stack.ps1') -Value '# launcher fixture' -Encoding ASCII
    [ordered]@{
        schemaVersion = 1
        instanceId = $InstanceId
        root = $Root
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root '.cpa-stack-instance.json') -Encoding UTF8
    [ordered]@{
        schemaVersion = 1
        instanceId = $InstanceId
        canonicalRoot = $Root
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'state\current.json') -Encoding UTF8
    foreach ($path in @(
        (Join-Path $Root 'ops'),
        (Join-Path $Root 'state'),
        (Join-Path $Root 'ops\Start-CPA-Stack.ps1'),
        (Join-Path $Root '.cpa-stack-instance.json'),
        (Join-Path $Root 'state\current.json')
    )) {
        Set-TestCurrentUserOwner -Path $path
    }
}

function Get-TestPathAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
        [System.Security.AccessControl.AccessControlSections]::Group -bor
        [System.Security.AccessControl.AccessControlSections]::Access
    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) {
        return [System.Security.AccessControl.DirectorySecurity]::new($item.FullName, $sections)
    }
    return [System.Security.AccessControl.FileSecurity]::new($item.FullName, $sections)
}

function Set-TestPathAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSystemSecurity]$Acl
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($item.PSIsContainer) {
        if ($null -ne $extensions) {
            [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]$item, [System.Security.AccessControl.DirectorySecurity]$Acl)
        } else {
            ([System.IO.DirectoryInfo]$item).SetAccessControl([System.Security.AccessControl.DirectorySecurity]$Acl)
        }
        return
    }
    if ($null -ne $extensions) {
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]$item, [System.Security.AccessControl.FileSecurity]$Acl)
    } else {
        ([System.IO.FileInfo]$item).SetAccessControl([System.Security.AccessControl.FileSecurity]$Acl)
    }
}

function Set-TestCurrentUserOwner {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = Get-TestPathAcl -Path $Path
    $acl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    Set-TestPathAcl -Path $Path -Acl $acl
}

function Protect-TestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
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
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-TestPathAcl -Path $Path -Acl $acl
}

function Add-TestUntrustedAllowRule {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
    $acl = Get-TestPathAcl -Path $Path
    $inheritance = if ($item.PSIsContainer) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
        [System.Security.AccessControl.FileSystemRights]::Modify,
        $inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-TestPathAcl -Path $Path -Acl $acl
}

function Assert-TestTrustConflict {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Desktop,
        [Parameter(Mandatory = $true)][string]$Shortcut,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $rootSnapshot = @(Get-TestTreeSnapshot -Path $Root)
    $desktopSnapshot = @(Get-TestTreeSnapshot -Path $Desktop)
    $checked = Invoke-CpaStackManagedShortcut -Action Check -Root $Root -DesktopDirectory $Desktop -ShortcutPath $Shortcut
    Assert-Equal 'Conflict' ([string]$checked.status) "$Description is reported as a conflict"
    Assert-False ([bool]$checked.changed) "$Description Check remains read-only"
    Assert-Equal ($rootSnapshot -join "`n") (@(Get-TestTreeSnapshot -Path $Root) -join "`n") "$Description Check preserves root bytes, mtimes, owners, and DACLs"
    Assert-Equal ($desktopSnapshot -join "`n") (@(Get-TestTreeSnapshot -Path $Desktop) -join "`n") "$Description Check preserves the desktop"
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $Root -DesktopDirectory $Desktop -ShortcutPath $Shortcut)
    } 'conflict|refus' "$Description Ensure fails closed"
    Assert-Equal ($rootSnapshot -join "`n") (@(Get-TestTreeSnapshot -Path $Root) -join "`n") "$Description rejected Ensure preserves root bytes, mtimes, owners, and DACLs"
    Assert-Equal ($desktopSnapshot -join "`n") (@(Get-TestTreeSnapshot -Path $Desktop) -join "`n") "$Description rejected Ensure preserves the desktop"
}

function Get-TestFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.Security.AccessControl.FileSecurity](Get-TestPathAcl -Path $Path)
}

function Set-TestFileAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Security.AccessControl.FileSecurity]$Acl
    )

    Set-TestPathAcl -Path $Path -Acl $Acl
}

$shortcutTestWork = Join-Path $PSScriptRoot 'work'
$wshProbeRoot = Join-Path $shortcutTestWork 'cpa-shortcut-wsh-probe-policy'
$wshProbePath = Join-Path $wshProbeRoot 'CPA Probe.lnk'
$wshProbeLauncher = Join-Path $wshProbeRoot 'Start-CPA-Stack.ps1'
$wshShortcutSupported = $false
$wshProbeCleanupBlocked = $false
if (Test-Path -LiteralPath $wshProbeRoot) {
    try {
        Remove-TestPathWithRetry -Path $wshProbeRoot
    } catch {
        Write-Host 'Managed shortcut v2 tests skipped: endpoint policy retains the PowerShell WSH probe.'
        Remove-Module CpaStack.ManagedShortcut -ErrorAction SilentlyContinue
        return
    }
}
try {
    New-Item -ItemType Directory -Force -Path $wshProbeRoot | Out-Null
    Set-Content -LiteralPath $wshProbeLauncher -Value '# WSH policy probe' -Encoding ASCII
    $wshPowerShell = [System.IO.Path]::GetFullPath((Get-Command powershell.exe -ErrorAction Stop).Source)
    $wshArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $wshProbeLauncher
    Write-TestShortcut -Path $wshProbePath -TargetPath $wshPowerShell -Arguments $wshArguments -WorkingDirectory $wshProbeRoot -WindowStyle 7
    Start-Sleep -Milliseconds 250
    $wshProbe = Read-TestShortcut -Path $wshProbePath
    $wshShortcutSupported = [string]::Equals([string]$wshProbe.TargetPath, $wshPowerShell, [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]$wshProbe.Arguments -ceq $wshArguments -and [int]$wshProbe.WindowStyle -eq 7
} finally {
    try {
        Remove-TestPathWithRetry -Path $wshProbeRoot
    } catch {
        $wshProbeCleanupBlocked = $true
        $wshShortcutSupported = $false
    }
}
if (-not $wshShortcutSupported) {
    $reason = if ($wshProbeCleanupBlocked) { 'retains' } else { 'rewrites' }
    Write-Host "Managed shortcut v2 tests skipped: endpoint policy $reason PowerShell WSH shortcuts."
    Remove-Module CpaStack.ManagedShortcut -ErrorAction SilentlyContinue
    return
}

$testHome = Join-Path $shortcutTestWork ('cpa-managed-shortcut-v2-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $testHome 'managed-root'
$desktop = Join-Path $testHome 'Desktop'
$shortcut = Join-Path $desktop 'CPA Local Start.lnk'
$instanceId = [guid]::NewGuid().ToString('N')

try {
    New-Item -ItemType Directory -Force -Path $desktop | Out-Null
    New-TestCanonicalRoot -Root $root -InstanceId $instanceId

    $rootBefore = @(Get-TestTreeSnapshot -Path $root)
    $desktopBefore = @(Get-TestTreeSnapshot -Path $desktop)
    $absent = Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut

    Assert-Equal 'Absent' ([string]$absent.status) 'Check reports an absent desktop shortcut'
    Assert-False ([bool]$absent.changed) 'Check never reports a write for an absent shortcut'
    Assert-Equal ($rootBefore -join "`n") (@(Get-TestTreeSnapshot -Path $root) -join "`n") 'Check does not mutate the managed root'
    Assert-Equal ($desktopBefore -join "`n") (@(Get-TestTreeSnapshot -Path $desktop) -join "`n") 'Check does not mutate the desktop'

    $instanceDriftRoot = Join-Path $testHome 'instance-drift-root'
    $instanceDriftDesktop = Join-Path $testHome 'Instance Drift Desktop'
    $instanceDriftShortcut = Join-Path $instanceDriftDesktop 'CPA Instance Drift.lnk'
    New-Item -ItemType Directory -Force -Path $instanceDriftDesktop | Out-Null
    New-TestCanonicalRoot -Root $instanceDriftRoot -InstanceId ([guid]::NewGuid().ToString('N'))
    $instanceDriftCurrentPath = Join-Path $instanceDriftRoot 'state\current.json'
    $instanceDriftCurrent = [System.IO.File]::ReadAllText($instanceDriftCurrentPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    $instanceDriftCurrent.instanceId = [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($instanceDriftCurrentPath, ($instanceDriftCurrent | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Assert-TestTrustConflict -Root $instanceDriftRoot -Desktop $instanceDriftDesktop -Shortcut $instanceDriftShortcut -Description 'current-state instance drift'

    foreach ($aclCase in @(
        [pscustomobject]@{ Name = 'managed root ACL drift'; RelativePath = '' },
        [pscustomobject]@{ Name = 'ops directory ACL drift'; RelativePath = 'ops' },
        [pscustomobject]@{ Name = 'state directory ACL drift'; RelativePath = 'state' },
        [pscustomobject]@{ Name = 'marker ACL drift'; RelativePath = '.cpa-stack-instance.json' },
        [pscustomobject]@{ Name = 'current-state ACL drift'; RelativePath = 'state\current.json' },
        [pscustomobject]@{ Name = 'launcher ACL drift'; RelativePath = 'ops\Start-CPA-Stack.ps1' }
    )) {
        $caseToken = ([string]$aclCase.Name).Replace(' ', '-')
        $aclRoot = Join-Path $testHome ($caseToken + '-root')
        $aclDesktop = Join-Path $testHome ($caseToken + '-desktop')
        $aclShortcut = Join-Path $aclDesktop 'CPA ACL Drift.lnk'
        New-Item -ItemType Directory -Force -Path $aclDesktop | Out-Null
        New-TestCanonicalRoot -Root $aclRoot -InstanceId ([guid]::NewGuid().ToString('N'))
        $aclTarget = if ([string]::IsNullOrEmpty([string]$aclCase.RelativePath)) { $aclRoot } else { Join-Path $aclRoot ([string]$aclCase.RelativePath) }
        Add-TestUntrustedAllowRule -Path $aclTarget
        Assert-TestTrustConflict -Root $aclRoot -Desktop $aclDesktop -Shortcut $aclShortcut -Description ([string]$aclCase.Name)
    }

    # A non-elevated Windows token cannot assign a foreign owner to a real fixture file.
    # The public ACL matrix above covers descriptor wiring; this checks the owner predicate directly.
    $ownerDriftAcl = New-Object System.Security.AccessControl.FileSecurity
    $ownerDriftAcl.SetAccessRuleProtection($true, $false)
    $ownerDriftAcl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )) {
        [void]$ownerDriftAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        ))
    }
    $managedShortcutModule = Get-Module -Name CpaStack.ManagedShortcut -ErrorAction Stop
    $ownerDriftTrusted = & $managedShortcutModule {
        param([System.Security.AccessControl.FileSystemSecurity]$Acl)
        Test-CpaStackManagedShortcutTrustedSecurityDescriptor -Acl $Acl
    } $ownerDriftAcl
    Assert-False ([bool]$ownerDriftTrusted) 'A trusted DACL with a foreign owner is rejected'

    foreach ($identityCase in @(
        [pscustomobject]@{ Name = 'marker root drift'; RelativePath = '.cpa-stack-instance.json'; Property = 'root' },
        [pscustomobject]@{ Name = 'current canonical-root drift'; RelativePath = 'state\current.json'; Property = 'canonicalRoot' }
    )) {
        $identityToken = ([string]$identityCase.Name).Replace(' ', '-')
        $identityRoot = Join-Path $testHome ($identityToken + '-root')
        $identityDesktop = Join-Path $testHome ($identityToken + '-desktop')
        $identityShortcut = Join-Path $identityDesktop 'CPA Identity Drift.lnk'
        New-Item -ItemType Directory -Force -Path $identityDesktop | Out-Null
        New-TestCanonicalRoot -Root $identityRoot -InstanceId ([guid]::NewGuid().ToString('N'))
        $identityPath = Join-Path $identityRoot ([string]$identityCase.RelativePath)
        $identityState = [System.IO.File]::ReadAllText($identityPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
        $identityProperty = [string]$identityCase.Property
        $identityState.$identityProperty = Join-Path $testHome 'another-managed-root'
        [System.IO.File]::WriteAllText($identityPath, ($identityState | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
        Assert-TestTrustConflict -Root $identityRoot -Desktop $identityDesktop -Shortcut $identityShortcut -Description ([string]$identityCase.Name)
    }

    $junctionRoot = Join-Path $testHome 'ops-junction-root'
    $junctionDesktop = Join-Path $testHome 'Ops Junction Desktop'
    $junctionShortcut = Join-Path $junctionDesktop 'CPA Junction Drift.lnk'
    $outsideOps = Join-Path $testHome 'outside-ops'
    New-Item -ItemType Directory -Force -Path $junctionRoot, (Join-Path $junctionRoot 'state'), $junctionDesktop, $outsideOps | Out-Null
    Protect-TestDirectory -Path $junctionRoot
    $junctionInstanceId = [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath (Join-Path $outsideOps 'Start-CPA-Stack.ps1') -Value '# redirected launcher fixture' -Encoding ASCII
    [ordered]@{ schemaVersion = 1; instanceId = $junctionInstanceId; root = $junctionRoot } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $junctionRoot '.cpa-stack-instance.json') -Encoding UTF8
    [ordered]@{ schemaVersion = 1; instanceId = $junctionInstanceId; canonicalRoot = $junctionRoot } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $junctionRoot 'state\current.json') -Encoding UTF8
    [void](New-Item -ItemType Junction -Path (Join-Path $junctionRoot 'ops') -Target $outsideOps)
    Assert-TestTrustConflict -Root $junctionRoot -Desktop $junctionDesktop -Shortcut $junctionShortcut -Description 'ops launcher reparse drift'

    $legacyIconDirectory = Join-Path $testHome 'legacy assets'
    New-Item -ItemType Directory -Force -Path $legacyIconDirectory | Out-Null
    $legacyIcon = Join-Path $legacyIconDirectory 'legacy.ico'
    Set-Content -LiteralPath $legacyIcon -Value 'synthetic icon fixture' -Encoding ASCII

    $created = Invoke-CpaStackManagedShortcut -Action Ensure -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut -LegacyIconPath $legacyIcon
    Assert-Equal 'Matching' ([string]$created.status) 'Ensure creates a matching managed shortcut'
    Assert-True ([bool]$created.changed) 'First Ensure reports a change'
    Assert-True (Test-Path -LiteralPath $shortcut -PathType Leaf) 'First Ensure creates the desktop shortcut'

    $launcher = [System.IO.Path]::GetFullPath((Join-Path $root 'ops\Start-CPA-Stack.ps1'))
    $ops = [System.IO.Path]::GetFullPath((Join-Path $root 'ops')).TrimEnd('\')
    $managedIcon = [System.IO.Path]::GetFullPath((Join-Path $root 'assets\cpa-shortcut.ico'))
    $link = Read-TestShortcut -Path $shortcut
    $preferredPowerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -eq $preferredPowerShell) { $preferredPowerShell = Get-Command powershell.exe -ErrorAction Stop }
    Assert-Equal ([System.IO.Path]::GetFullPath($preferredPowerShell.Source)) ([System.IO.Path]::GetFullPath($link.TargetPath)) 'Managed shortcut prefers PowerShell 7 and falls back to Windows PowerShell'
    Assert-Equal ('-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}"' -f $launcher) $link.Arguments 'Managed shortcut keeps the visible launcher open for execution status'
    Assert-Equal $ops ([System.IO.Path]::GetFullPath($link.WorkingDirectory).TrimEnd('\')) 'Managed shortcut uses the canonical ops working directory'
    Assert-Equal 1 $link.WindowStyle 'Managed shortcut opens a normal visible launcher window'
    Assert-Equal 'Quick-start CPA and Manager with visible status' $link.Description 'Managed shortcut describes its visible quick-start behavior'
    Assert-True (Test-Path -LiteralPath $managedIcon -PathType Leaf) 'Legacy icon is copied into the managed root'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyIcon).Hash (Get-FileHash -Algorithm SHA256 -LiteralPath $managedIcon).Hash 'Managed icon preserves the legacy icon bytes'
    Assert-True ($link.IconLocation.StartsWith($managedIcon + ',', [System.StringComparison]::OrdinalIgnoreCase)) 'Final shortcut uses the managed icon copy'
    Assert-False ($link.IconLocation.Contains($legacyIcon)) 'Final shortcut does not depend on the legacy icon path'

    $ownershipPath = Join-Path $root 'state\managed-shortcut.json'
    Assert-True (Test-Path -LiteralPath $ownershipPath -PathType Leaf) 'Ensure writes shortcut ownership state'
    $ownership = [System.IO.File]::ReadAllText($ownershipPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    Assert-Equal 'schemaVersion,instanceId,path,contractVersion,fingerprint' (@($ownership.PSObject.Properties.Name) -join ',') 'Ownership state contains only the v2 contract fields'
    Assert-Equal 1 ([int]$ownership.schemaVersion) 'Ownership state uses schema version 1'
    Assert-Equal $instanceId ([string]$ownership.instanceId) 'Ownership state is bound to the stack instance'
    Assert-Equal ([System.IO.Path]::GetFullPath($shortcut)) ([string]$ownership.path) 'Ownership state records the managed desktop shortcut'
    Assert-Equal 3 ([int]$ownership.contractVersion) 'Ownership state records shortcut contract version 3'
    Assert-True ([string]$ownership.fingerprint -match '^[0-9A-F]{64}$') 'Ownership state records a SHA256 contract fingerprint'
    Assert-True ([bool](Get-TestFileAcl -Path $ownershipPath).AreAccessRulesProtected) 'Ownership state has a protected DACL'

    $matching = Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut
    Assert-Equal 'Matching' ([string]$matching.status) 'Check recognizes the created shortcut and ownership state'
    Assert-False ([bool]$matching.changed) 'Matching Check remains read-only'
    Assert-False (($created | ConvertTo-Json -Depth 5).Contains('-File')) 'Results do not expose raw shortcut arguments'

    $shortcutHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $shortcut).Hash
    $shortcutWriteBefore = (Get-Item -LiteralPath $shortcut).LastWriteTimeUtc.Ticks
    $ownershipHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipPath).Hash
    $ownershipWriteBefore = (Get-Item -LiteralPath $ownershipPath).LastWriteTimeUtc.Ticks
    Start-Sleep -Milliseconds 1100
    $unchanged = Invoke-CpaStackManagedShortcut -Action Ensure -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut
    Assert-Equal 'Matching' ([string]$unchanged.status) 'Second Ensure keeps the shortcut matching'
    Assert-False ([bool]$unchanged.changed) 'Second Ensure reports zero writes'
    Assert-Equal $shortcutHashBefore (Get-FileHash -Algorithm SHA256 -LiteralPath $shortcut).Hash 'Second Ensure preserves shortcut hash'
    Assert-Equal $shortcutWriteBefore (Get-Item -LiteralPath $shortcut).LastWriteTimeUtc.Ticks 'Second Ensure preserves shortcut mtime'
    Assert-Equal $ownershipHashBefore (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipPath).Hash 'Second Ensure preserves ownership hash'
    Assert-Equal $ownershipWriteBefore (Get-Item -LiteralPath $ownershipPath).LastWriteTimeUtc.Ticks 'Second Ensure preserves ownership mtime'

    $priorOwnership = [System.IO.File]::ReadAllText($ownershipPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    $priorOwnership.contractVersion = 2
    $priorOwnership.fingerprint = ('A' * 64)
    [System.IO.File]::WriteAllText($ownershipPath, ($priorOwnership | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Assert-Equal 'Drifted' ([string](Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut).status) 'A known prior shortcut contract is repairable drift, not an ownership conflict'
    [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut)
    $upgradedOwnership = [System.IO.File]::ReadAllText($ownershipPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    Assert-Equal 3 ([int]$upgradedOwnership.contractVersion) 'Ensure upgrades a known prior shortcut contract to the current version'

    Write-TestShortcut -Path $shortcut -TargetPath ([System.IO.Path]::GetFullPath((Get-Command notepad.exe -ErrorAction Stop).Source)) -WorkingDirectory $desktop
    $driftHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $shortcut).Hash
    $driftWrite = (Get-Item -LiteralPath $shortcut).LastWriteTimeUtc.Ticks
    $driftOwnershipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipPath).Hash
    $driftOwnershipWrite = (Get-Item -LiteralPath $ownershipPath).LastWriteTimeUtc.Ticks
    $drifted = Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut
    Assert-Equal 'Drifted' ([string]$drifted.status) 'Registered shortcut contract changes are reported as drift'
    Assert-False ([bool]$drifted.changed) 'Drift Check remains read-only'
    Assert-Equal $driftHash (Get-FileHash -Algorithm SHA256 -LiteralPath $shortcut).Hash 'Drift Check preserves shortcut hash'
    Assert-Equal $driftWrite (Get-Item -LiteralPath $shortcut).LastWriteTimeUtc.Ticks 'Drift Check preserves shortcut mtime'
    Assert-Equal $driftOwnershipHash (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipPath).Hash 'Drift Check preserves ownership hash'
    Assert-Equal $driftOwnershipWrite (Get-Item -LiteralPath $ownershipPath).LastWriteTimeUtc.Ticks 'Drift Check preserves ownership mtime'

    $repaired = Invoke-CpaStackManagedShortcut -Action Ensure -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut
    Assert-Equal 'Matching' ([string]$repaired.status) 'Ensure repairs a registered drifted shortcut'
    Assert-True ([bool]$repaired.changed) 'Drift repair reports a change'
    Assert-False ([bool]$repaired.adopted) 'Repair is not reported as adoption'
    Assert-Equal $driftOwnershipHash (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipPath).Hash 'Link-only repair preserves ownership hash'
    Assert-Equal $driftOwnershipWrite (Get-Item -LiteralPath $ownershipPath).LastWriteTimeUtc.Ticks 'Link-only repair preserves ownership mtime'
    Assert-Equal 'Matching' ([string](Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut).status) 'Check recognizes the repaired shortcut'

    Remove-Item -LiteralPath $shortcut -Force
    $missing = Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut
    Assert-Equal 'Drifted' ([string]$missing.status) 'Missing registered shortcut is reported as drift'
    Assert-False ([bool]$missing.changed) 'Missing-link Check does not recreate the shortcut'
    Assert-False (Test-Path -LiteralPath $shortcut) 'Missing-link Check is strictly read-only'
    [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut)
    Assert-Equal 'Matching' ([string](Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath $shortcut).status) 'Ensure recreates a missing registered shortcut'
    Assert-Equal $driftOwnershipHash (Get-FileHash -Algorithm SHA256 -LiteralPath $ownershipPath).Hash 'Missing-link repair preserves matching ownership state'

    $adoptRoot = Join-Path $testHome 'adopt-root'
    $adoptDesktop = Join-Path $testHome 'Adopt Desktop'
    $adoptShortcut = Join-Path $adoptDesktop 'Existing CPA.lnk'
    $adoptInstanceId = [guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Force -Path $adoptDesktop | Out-Null
    New-TestCanonicalRoot -Root $adoptRoot -InstanceId $adoptInstanceId
    $adoptLegacyLauncher = [System.IO.Path]::GetFullPath((Join-Path $testHome 'old managed root\ops\Start-CPA-Stack.ps1'))
    $adoptOps = [System.IO.Path]::GetFullPath((Join-Path $adoptRoot 'ops')).TrimEnd('\')
    $adoptLegacyIcon = Join-Path $legacyIconDirectory 'adopt-legacy.ico'
    Set-Content -LiteralPath $adoptLegacyIcon -Value 'adopt icon fixture' -Encoding ASCII
    $powershellPath = [System.IO.Path]::GetFullPath((Get-Command powershell.exe -ErrorAction Stop).Source)
    Write-TestShortcut -Path $adoptShortcut -TargetPath $powershellPath -Arguments ('-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}"' -f $adoptLegacyLauncher) -WorkingDirectory (Split-Path -Parent $adoptLegacyLauncher) -WindowStyle 7 -IconPath $adoptLegacyIcon

    $adoptHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptShortcut).Hash
    $adoptRootBefore = @(Get-TestTreeSnapshot -Path $adoptRoot)
    $adoptable = Invoke-CpaStackManagedShortcut -Action Check -Root $adoptRoot -DesktopDirectory $adoptDesktop -ShortcutPath $adoptShortcut
    Assert-Equal 'Adoptable' ([string]$adoptable.status) 'Unregistered shortcut to the canonical launcher is adoptable'
    Assert-False ([bool]$adoptable.changed) 'Adoptable Check remains read-only'
    Assert-Equal $adoptHashBefore (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptShortcut).Hash 'Adoptable Check preserves the existing shortcut'
    Assert-Equal ($adoptRootBefore -join "`n") (@(Get-TestTreeSnapshot -Path $adoptRoot) -join "`n") 'Adoptable Check does not write ownership or icon state'

    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $adoptRoot -DesktopDirectory $adoptDesktop -ShortcutPath $adoptShortcut)
    } 'AdoptExisting' 'Ensure requires explicit authorization before adopting an existing shortcut'
    Assert-Equal $adoptHashBefore (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptShortcut).Hash 'Unauthorized adoption preserves the existing shortcut'
    Assert-False (Test-Path -LiteralPath (Join-Path $adoptRoot 'state\managed-shortcut.json')) 'Unauthorized adoption does not write ownership state'

    $adopted = Invoke-CpaStackManagedShortcut -Action Ensure -Root $adoptRoot -DesktopDirectory $adoptDesktop -ShortcutPath $adoptShortcut -AdoptExisting
    Assert-Equal 'Matching' ([string]$adopted.status) 'Authorized adoption creates a matching managed shortcut'
    Assert-True ([bool]$adopted.changed) 'Authorized adoption reports a change'
    Assert-True ([bool]$adopted.adopted) 'Authorized adoption is explicit in the result'
    Assert-True (Test-Path -LiteralPath ([string]$adopted.backupPath) -PathType Leaf) 'Authorized adoption retains a backup of the prior shortcut'
    Assert-Equal $adoptHashBefore (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$adopted.backupPath)).Hash 'Adoption backup preserves the prior shortcut bytes'
    $adoptedLink = Read-TestShortcut -Path $adoptShortcut
    $adoptManagedIcon = [System.IO.Path]::GetFullPath((Join-Path $adoptRoot 'assets\cpa-shortcut.ico'))
    Assert-True ($adoptedLink.IconLocation.StartsWith($adoptManagedIcon + ',', [System.StringComparison]::OrdinalIgnoreCase)) 'Adoption moves the legacy icon dependency into the managed root'
    Assert-False ($adoptedLink.IconLocation.Contains($adoptLegacyIcon)) 'Adopted shortcut no longer references its legacy icon'
    Assert-Equal 'Matching' ([string](Invoke-CpaStackManagedShortcut -Action Check -Root $adoptRoot -DesktopDirectory $adoptDesktop -ShortcutPath $adoptShortcut).status) 'Check recognizes an adopted shortcut'

    $adoptOwnershipPath = Join-Path $adoptRoot 'state\managed-shortcut.json'
    $unsafeOwnershipAcl = New-Object System.Security.AccessControl.FileSecurity
    $unsafeOwnershipAcl.SetAccessRuleProtection($false, $false)
    $unsafeOwnershipAcl.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    [void]$unsafeOwnershipAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-TestFileAcl -Path $adoptOwnershipPath -Acl $unsafeOwnershipAcl
    Assert-False ([bool](Get-TestFileAcl -Path $adoptOwnershipPath).AreAccessRulesProtected) 'ACL fixture makes ownership state unsafe'
    $unsafeShortcutHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptShortcut).Hash
    $unsafeOwnershipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptOwnershipPath).Hash
    $unsafeOwnership = Invoke-CpaStackManagedShortcut -Action Check -Root $adoptRoot -DesktopDirectory $adoptDesktop -ShortcutPath $adoptShortcut
    Assert-Equal 'Conflict' ([string]$unsafeOwnership.status) 'Unprotected ownership state is a conflict'
    Assert-False ([bool]$unsafeOwnership.changed) 'Unsafe ownership Check remains read-only'
    Assert-False ([bool](Get-TestFileAcl -Path $adoptOwnershipPath).AreAccessRulesProtected) 'Check does not silently repair ownership ACLs'
    Assert-Equal $unsafeOwnershipHash (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptOwnershipPath).Hash 'Unsafe ownership Check preserves state bytes'
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $adoptRoot -DesktopDirectory $adoptDesktop -ShortcutPath $adoptShortcut)
    } 'conflict|refus' 'Ensure refuses untrusted ownership state'
    Assert-Equal $unsafeShortcutHash (Get-FileHash -Algorithm SHA256 -LiteralPath $adoptShortcut).Hash 'Rejected unsafe ownership preserves the shortcut'

    $conflictRoot = Join-Path $testHome 'conflict-root'
    $conflictDesktop = Join-Path $testHome 'Conflict Desktop'
    $conflictShortcut = Join-Path $conflictDesktop 'Unrelated Tool.lnk'
    New-Item -ItemType Directory -Force -Path $conflictDesktop | Out-Null
    New-TestCanonicalRoot -Root $conflictRoot -InstanceId ([guid]::NewGuid().ToString('N'))
    Write-TestShortcut -Path $conflictShortcut -TargetPath ([System.IO.Path]::GetFullPath((Get-Command notepad.exe -ErrorAction Stop).Source)) -WorkingDirectory $conflictDesktop
    $conflictHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $conflictShortcut).Hash
    $conflictRootBefore = @(Get-TestTreeSnapshot -Path $conflictRoot)
    $conflict = Invoke-CpaStackManagedShortcut -Action Check -Root $conflictRoot -DesktopDirectory $conflictDesktop -ShortcutPath $conflictShortcut
    Assert-Equal 'Conflict' ([string]$conflict.status) 'Unknown unregistered shortcut is a conflict'
    Assert-False ([bool]$conflict.changed) 'Conflict Check remains read-only'
    Assert-Equal $conflictHash (Get-FileHash -Algorithm SHA256 -LiteralPath $conflictShortcut).Hash 'Conflict Check preserves the unknown shortcut'
    Assert-Equal ($conflictRootBefore -join "`n") (@(Get-TestTreeSnapshot -Path $conflictRoot) -join "`n") 'Conflict Check does not create managed state'
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $conflictRoot -DesktopDirectory $conflictDesktop -ShortcutPath $conflictShortcut -AdoptExisting)
    } 'conflict|refus' 'Ensure refuses to overwrite an unknown shortcut even with AdoptExisting'
    Assert-Equal $conflictHash (Get-FileHash -Algorithm SHA256 -LiteralPath $conflictShortcut).Hash 'Rejected conflict remains byte-for-byte unchanged'
    Assert-False (Test-Path -LiteralPath (Join-Path $conflictRoot 'state\managed-shortcut.json')) 'Rejected conflict does not gain ownership state'

    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath (Join-Path $testHome 'Outside Desktop.lnk'))
    } 'direct \.lnk child' 'Shortcut paths outside the selected current-user Desktop are rejected'
    $nestedDesktop = Join-Path $desktop 'nested'
    New-Item -ItemType Directory -Force -Path $nestedDesktop | Out-Null
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Check -Root $root -DesktopDirectory $desktop -ShortcutPath (Join-Path $nestedDesktop 'Nested.lnk'))
    } 'direct \.lnk child' 'Nested Desktop shortcut paths are rejected'

    $reparseRoot = Join-Path $testHome 'reparse-root'
    $reparseDesktop = Join-Path $testHome 'Reparse Desktop'
    $outsideAssets = Join-Path $testHome 'outside-assets'
    New-Item -ItemType Directory -Force -Path $reparseDesktop, $outsideAssets | Out-Null
    New-TestCanonicalRoot -Root $reparseRoot -InstanceId ([guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Junction -Path (Join-Path $reparseRoot 'assets') -Target $outsideAssets)
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $reparseRoot -DesktopDirectory $reparseDesktop -ShortcutPath (Join-Path $reparseDesktop 'Reparse.lnk') -LegacyIconPath $legacyIcon)
    } 'reparse' 'Managed root reparse points cannot redirect icon writes outside the root'
    Assert-Equal 0 @(Get-ChildItem -Force -LiteralPath $outsideAssets).Count 'Rejected reparse path does not write outside the managed root'
    Assert-False (Test-Path -LiteralPath (Join-Path $reparseDesktop 'Reparse.lnk')) 'Rejected reparse path does not create a desktop shortcut'

    $verifyRoot = Join-Path $testHome 'verification-root'
    $verifyDesktop = Join-Path $testHome 'Verification Desktop'
    $verifyShortcut = Join-Path $verifyDesktop 'Verification Failure.lnk'
    New-Item -ItemType Directory -Force -Path $verifyDesktop | Out-Null
    New-TestCanonicalRoot -Root $verifyRoot -InstanceId ([guid]::NewGuid().ToString('N'))
    $verifyAssets = Join-Path $verifyRoot 'assets'
    New-Item -ItemType Directory -Force -Path $verifyAssets | Out-Null
    $verifyManagedIcon = Join-Path $verifyAssets 'cpa-shortcut.ico'
    Set-Content -LiteralPath $verifyManagedIcon -Value 'preexisting managed icon' -Encoding ASCII
    $verifyManagedIconHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyManagedIcon).Hash
    $replacementLegacyIcon = Join-Path $legacyIconDirectory 'replacement.ico'
    Set-Content -LiteralPath $replacementLegacyIcon -Value 'replacement icon' -Encoding ASCII
    $corruptStore = [pscustomobject]@{
        Write = {
            param([string]$Path, $Contract)
            [System.IO.File]::WriteAllText($Path, 'corrupt shortcut fixture', [System.Text.Encoding]::ASCII)
        }
        Read = {
            param([string]$Path)
            [pscustomobject]@{
                TargetPath = 'C:\Windows\System32\notepad.exe'
                Arguments = ''
                WorkingDirectory = ''
                WindowStyle = 1
                IconLocation = ''
                Description = ''
            }
        }
    }
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $verifyRoot -DesktopDirectory $verifyDesktop -ShortcutPath $verifyShortcut -LegacyIconPath $replacementLegacyIcon -ShortcutStore $corruptStore)
    } 'staged.*verification' 'Ensure rejects a shortcut that fails adapter read-back verification'
    Assert-False (Test-Path -LiteralPath $verifyShortcut) 'Failed read-back does not commit a desktop shortcut'
    Assert-False (Test-Path -LiteralPath (Join-Path $verifyRoot 'state\managed-shortcut.json')) 'Failed read-back does not write ownership state'
    Assert-Equal $verifyManagedIconHash (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyManagedIcon).Hash 'Failed read-back restores the preexisting managed icon'
    Assert-Equal 0 @(Get-ChildItem -Force -LiteralPath $verifyDesktop).Count 'Failed read-back removes its staged desktop file'

    [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $verifyRoot -DesktopDirectory $verifyDesktop -ShortcutPath $verifyShortcut)
    $verifyShortcutHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyShortcut).Hash
    $verifyOwnershipPath = Join-Path $verifyRoot 'state\managed-shortcut.json'
    $verifyOwnershipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyOwnershipPath).Hash
    Assert-ThrowsMatch {
        [void](Invoke-CpaStackManagedShortcut -Action Ensure -Root $verifyRoot -DesktopDirectory $verifyDesktop -ShortcutPath $verifyShortcut -LegacyIconPath $replacementLegacyIcon -ShortcutStore $corruptStore)
    } 'staged.*verification' 'Drift repair also requires adapter read-back verification'
    Assert-Equal $verifyShortcutHash (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyShortcut).Hash 'Failed drift repair preserves the registered shortcut'
    Assert-Equal $verifyOwnershipHash (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyOwnershipPath).Hash 'Failed drift repair preserves ownership state'
    Assert-Equal $verifyManagedIconHash (Get-FileHash -Algorithm SHA256 -LiteralPath $verifyManagedIcon).Hash 'Failed drift repair restores the registered managed icon'

    'Managed shortcut v2 tests passed.'
} finally {
    Remove-Module CpaStack.ManagedShortcut -ErrorAction SilentlyContinue
    Remove-TestPathWithRetry -Path $testHome
}
