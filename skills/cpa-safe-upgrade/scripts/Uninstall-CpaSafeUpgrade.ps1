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

$skillsRoot = Join-Path ([System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')) 'skills'
$targets = @(
    (Join-Path $skillsRoot 'cpa-safe-upgrade'),
    (Join-Path $skillsRoot 'cpa-safe-upgrade.previous')
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
    if ($items.Count -eq 0) {
        Remove-Item -LiteralPath $Root -Force -ErrorAction Stop
        return
    }
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
    Assert-CpaStackPathNoReparseAncestors -Path $skillsFull -Description 'Skill uninstall path'
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 2
    $installLock = Enter-CpaStackOperationLock -Name 'CPAStackSkillInstall' -TimeoutSeconds 2
    if (Test-Path -LiteralPath $skillsFull -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $skillsFull -Force -ErrorAction Stop) {
            if ($item.Name -cmatch '^cpa-safe-upgrade\.retiring-[0-9a-f]{32}$') {
                throw "An unfinished retiring skill transaction requires manual recovery before uninstall can continue: $($item.FullName)"
            }
            if ($item.Name -cmatch '^cpa-safe-upgrade\.(?:staging|retained)-[0-9a-f]{32}$') {
                if (-not $item.PSIsContainer) {
                    throw "Skill transaction target is not a directory: $($item.FullName)"
                }
                $targets += $item.FullName
            }
        }
    }
    $existing = @()
    foreach ($target in $targets) {
        $full = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        Assert-CpaStackPathNoReparseAncestors -Path $full -Description 'Skill uninstall target'
        $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\')
        $name = [System.IO.Path]::GetFileName($full)
        $validName = (
            $name -ceq 'cpa-safe-upgrade' -or
            $name -ceq 'cpa-safe-upgrade.previous' -or
            $name -cmatch '^cpa-safe-upgrade\.(?:staging|retained)-[0-9a-f]{32}$'
        )
        if (-not [string]::Equals($parent, $skillsFull, [System.StringComparison]::OrdinalIgnoreCase) -or -not $validName) {
            throw "Unsafe uninstall target: $full"
        }
        if (Test-Path -LiteralPath $full) {
            if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                throw "Uninstall target is not a directory: $full"
            }
            if (@(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop).Count -gt 0) {
                Assert-OwnedSkillDirectory -Root $full
            }
            $existing += $full
        }
    }

    foreach ($full in $existing) {
        Assert-SkillDirectoryReplaceable -Root $full
    }

    $removed = @()
    $removalOrder = @($existing | Sort-Object { if ([System.IO.Path]::GetFileName($_) -ceq 'cpa-safe-upgrade') { 1 } else { 0 } })
    foreach ($full in $removalOrder) {
        Remove-OwnedSkillDirectory -Root $full
        $removed += $full
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
