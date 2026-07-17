#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CodexHome = $(if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }),
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
if (-not $Yes) {
    throw 'Pass -Yes to uninstall the Codex skill. CPA runtimes and data are never removed.'
}

$common = Join-Path $PSScriptRoot 'CpaStack.Common.ps1'
if (-not (Test-Path -LiteralPath $common -PathType Leaf)) {
    throw 'The installed skill does not contain its shared safety library.'
}
. $common
$updaterVersion = Get-CpaStackUpdaterVersion

$codexHomeFull = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$skillsRoot = Join-Path $codexHomeFull 'skills'
$slotStateRoot = Join-Path $codexHomeFull 'cpa-stack-updater'
$slotRoot = Join-Path $slotStateRoot 'skill-slots'
$targets = @(
    (Join-Path $skillsRoot 'cpa-safe-upgrade'),
    (Join-Path $skillsRoot 'cpa-safe-upgrade.previous'),
    (Join-Path $slotRoot 'previous')
)

function Assert-OwnedSkillDirectory {
    param([string]$Root)
    $item = Get-Item -Force -LiteralPath $Root
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to uninstall through a reparse point: $Root"
    }
    foreach ($child in Get-ChildItem -Force -LiteralPath $Root -Recurse -ErrorAction Stop) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to uninstall a skill tree containing a reparse point: $($child.FullName)"
        }
    }
    $markerPath = Join-Path $Root '.cpa-stack-updater-installed.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Refusing to remove an unowned skill directory: $Root"
    }
    $marker = Read-CpaStackJson -Path $markerPath
    if ([int]$marker.schemaVersion -ne 1 -or [string]$marker.product -cne 'cpa-stack-updater' -or [string]$marker.skill -cne 'cpa-safe-upgrade') {
        throw "Skill ownership marker is invalid: $markerPath"
    }
    Assert-PrivateUninstallPath -Path $Root -PathType Container -RequireProtectedAcl
    Assert-PrivateUninstallPath -Path $markerPath -PathType Leaf
}

function Assert-PrivateUninstallPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Leaf', 'Container')][string]$PathType,
        [switch]$RequireProtectedAcl
    )

    Assert-CpaStackPath -Path $Path -PathType $PathType
    $item = Get-Item -Force -LiteralPath $Path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Uninstall path must not be a reparse point: $Path"
    }
    $acl = Get-CpaStackFileSystemAcl -Path $Path
    if ($RequireProtectedAcl -and -not $acl.AreAccessRulesProtected) {
        throw "Uninstall path ACL inheritance is not protected: $Path"
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ((Get-CpaStackAclOwnerSid -Acl $acl) -ne $currentSid) {
        throw "Uninstall path is not owned by the current Windows user: $Path"
    }
    $allowedSids = @{}
    foreach ($identity in Get-CpaStackPrivateIdentities) { $allowedSids[$identity.Value] = $true }
    foreach ($rule in Get-CpaStackAclAccessRules -Acl $acl) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        if (-not $allowedSids.ContainsKey($sid)) {
            throw "Uninstall path grants access to an unexpected identity: $Path ($sid)"
        }
    }
}

function Assert-SkillDirectoryReplaceable {
    param([Parameter(Mandatory = $true)][string]$Root)

    if ($null -eq ('CpaStackUpdater.UninstallDeleteProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CpaStackUpdater
{
    public static class UninstallDeleteProbe
    {
        private const uint DeleteAccess = 0x00010000;
        private const uint FileReadAttributes = 0x00000080;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        public static SafeFileHandle Open(string path, bool directory)
        {
            SafeFileHandle handle = CreateFile(
                path,
                DeleteAccess | FileReadAttributes,
                FileShare.Read | FileShare.Write | FileShare.Delete,
                IntPtr.Zero,
                OpenExisting,
                directory ? FileFlagBackupSemantics : FileAttributeNormal,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            return handle;
        }
    }
}
'@
    }

    $items = @((Get-Item -Force -LiteralPath $Root)) + @(Get-ChildItem -Force -LiteralPath $Root -Recurse -ErrorAction Stop)
    foreach ($item in $items) {
        try {
            $handle = [CpaStackUpdater.UninstallDeleteProbe]::Open($item.FullName, [bool]$item.PSIsContainer)
            $handle.Dispose()
        } catch {
            throw "Could not prepare the CPA skill for uninstall. Close editors or terminals using files under '$Root', then retry. No owned directory was deleted. Locked path: $($item.FullName) Error: $($_.Exception.Message)"
        }
    }
}

function Remove-OwnedSkillDirectory {
    param([Parameter(Mandatory = $true)][string]$Root)

    $items = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)
    Assert-OwnedSkillDirectory -Root $Root
    $markerPath = Join-Path $Root '.cpa-stack-updater-installed.json'
    foreach ($item in $items) {
        if ([string]::Equals($item.FullName, $markerPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $Root -Force -ErrorAction Stop
}

$operationLock = $null
$installLock = $null
try {
    $skillsFull = [System.IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')
    $slotStateFull = [System.IO.Path]::GetFullPath($slotStateRoot).TrimEnd('\')
    $slotFull = [System.IO.Path]::GetFullPath($slotRoot).TrimEnd('\')
    Assert-CpaStackPathNoReparseAncestors -Path $skillsFull -Description 'Skill uninstall path'
    Assert-CpaStackPathNoReparseAncestors -Path $slotStateFull -Description 'Skill uninstall slot state path'
    Assert-CpaStackPathNoReparseAncestors -Path $slotFull -Description 'Skill uninstall slot path'
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 15
    $installLock = Enter-CpaStackOperationLock -Name 'CPAStackSkillInstall' -TimeoutSeconds 15

    if (Test-Path -LiteralPath $skillsFull -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $skillsFull -Force -ErrorAction Stop) {
            if ($item.Name -cmatch '^cpa-safe-upgrade\.(?:staging|retained|retiring)-[0-9a-f]{32}(?:\.claim\.json)?$') {
                throw "An unjournaled legacy skill transaction artifact requires manual recovery before uninstall: $($item.FullName)"
            }
        }
    }

    if (Test-Path -LiteralPath $slotStateFull) {
        if (-not (Test-Path -LiteralPath $slotStateFull -PathType Container)) {
            throw "Updater slot state root is not a directory: $slotStateFull"
        }
        Assert-PrivateUninstallPath -Path $slotStateFull -PathType Container -RequireProtectedAcl
        $unexpectedState = @(Get-ChildItem -LiteralPath $slotStateFull -Force -ErrorAction Stop | Where-Object { $_.Name -cne 'skill-slots' })
        if ($unexpectedState.Count -gt 0) {
            throw "Updater slot state contains foreign content; no skill was removed: $($unexpectedState.FullName -join ', ')"
        }
    }

    if (Test-Path -LiteralPath $slotFull) {
        if (-not (Test-Path -LiteralPath $slotFull -PathType Container)) {
            throw "Updater skill slot root is not a directory: $slotFull"
        }
        Assert-PrivateUninstallPath -Path $slotFull -PathType Container -RequireProtectedAcl
        foreach ($pendingName in @('install.pending.json', 'legacy-previous-relocation.pending.json')) {
            $pendingPath = Join-Path $slotFull $pendingName
            if (Test-Path -LiteralPath $pendingPath) {
                throw "Pending installer recovery must complete before uninstall; no skill was removed: $pendingPath"
            }
        }
        $unexpectedSlots = @(Get-ChildItem -LiteralPath $slotFull -Force -ErrorAction Stop | Where-Object { $_.Name -cne 'previous' })
        if ($unexpectedSlots.Count -gt 0) {
            throw "Updater skill slot root contains an unclaimed or foreign artifact; no skill was removed: $($unexpectedSlots.FullName -join ', ')"
        }
    }

    $existing = @()
    foreach ($target in $targets) {
        $full = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        Assert-CpaStackPathNoReparseAncestors -Path $full -Description 'Skill uninstall target'
        $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\')
        $name = [System.IO.Path]::GetFileName($full)
        $validDiscoveryTarget = [string]::Equals($parent, $skillsFull, [System.StringComparison]::OrdinalIgnoreCase) -and
            $name -in @('cpa-safe-upgrade', 'cpa-safe-upgrade.previous')
        $validSlotTarget = [string]::Equals($parent, $slotFull, [System.StringComparison]::OrdinalIgnoreCase) -and
            $name -ceq 'previous'
        if (-not $validDiscoveryTarget -and -not $validSlotTarget) {
            throw "Unsafe uninstall target: $full"
        }
        if (Test-Path -LiteralPath $full) {
            if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                throw "Uninstall target is not a directory: $full"
            }
            Assert-OwnedSkillDirectory -Root $full
            $existing += $full
        }
    }

    foreach ($full in $existing) {
        Assert-SkillDirectoryReplaceable -Root $full
    }
    foreach ($parent in @($slotFull, $slotStateFull)) {
        if (Test-Path -LiteralPath $parent -PathType Container) {
            Assert-SkillDirectoryReplaceable -Root $parent
        }
    }

    $removed = @()
    $removalOrder = @($existing | Sort-Object { if ([System.IO.Path]::GetFileName($_) -ceq 'cpa-safe-upgrade') { 1 } else { 0 } })
    foreach ($full in $removalOrder) {
        Remove-OwnedSkillDirectory -Root $full
        $removed += $full
    }

    if (Test-Path -LiteralPath $slotFull -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $slotFull -Force -ErrorAction Stop).Count -ne 0) {
            throw 'Updater skill slot root is not empty after owned-slot removal.'
        }
        Remove-Item -LiteralPath $slotFull -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $slotStateFull -PathType Container) {
        if (@(Get-ChildItem -LiteralPath $slotStateFull -Force -ErrorAction Stop).Count -ne 0) {
            throw 'Updater slot state root contains foreign content after owned-slot removal.'
        }
        Remove-Item -LiteralPath $slotStateFull -Force -ErrorAction Stop
    }

    [pscustomobject]@{
        success = $true
        updaterVersion = $updaterVersion
        removed = $removed
        stackDataTouched = $false
    } | ConvertTo-Json -Depth 3
} finally {
    Exit-CpaStackOperationLock -Mutex $installLock
    Exit-CpaStackOperationLock -Mutex $operationLock
}
