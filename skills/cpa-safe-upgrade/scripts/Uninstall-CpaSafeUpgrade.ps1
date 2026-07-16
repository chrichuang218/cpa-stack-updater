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

$operationLock = $null
$installLock = $null
try {
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 2
    $installLock = Enter-CpaStackOperationLock -Name 'CPAStackSkillInstall' -TimeoutSeconds 2
    $skillsFull = [System.IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')
    $existing = @()
    foreach ($target in $targets) {
        $full = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        if (-not $full.StartsWith($skillsFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe uninstall target: $full"
        }
        if (Test-Path -LiteralPath $full) {
            Assert-OwnedSkillDirectory -Root $full
            $existing += $full
        }
    }

    $removed = @()
    foreach ($full in $existing) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
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
