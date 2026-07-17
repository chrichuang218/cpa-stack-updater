#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Check', 'Update')]
    [string]$Action = 'Update',
    [string]$CodexHome = $(if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }),
    [string]$StackRoot,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'skills\cpa-safe-upgrade'
$codexHomeFull = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$skillsRoot = Join-Path $codexHomeFull 'skills'
$installed = Join-Path $skillsRoot 'cpa-safe-upgrade'
$legacyPrevious = Join-Path $skillsRoot 'cpa-safe-upgrade.previous'
$slotStateRoot = Join-Path $codexHomeFull 'cpa-stack-updater'
$slotRoot = Join-Path $slotStateRoot 'skill-slots'
$transactionId = [guid]::NewGuid().ToString('N')
$staging = Join-Path $slotRoot ('staging-' + $transactionId)
$retained = Join-Path $slotRoot ('retained-' + $transactionId)
$retiring = Join-Path $slotRoot ('retiring-' + $transactionId)
$previous = Join-Path $slotRoot 'previous'
$installJournal = Join-Path $slotRoot 'install.pending.json'
$relocationJournal = Join-Path $slotRoot 'legacy-previous-relocation.pending.json'
$installJournalWrite = $installJournal + '.write'
$relocationJournalWrite = $relocationJournal + '.write'
$transactionClaimName = '.cpa-stack-transaction-claim.json'
$launcherWriteSuffix = '.cpa-stack-updater.write'
$common = Join-Path $source 'scripts\CpaStack.Common.ps1'
$bootstrapSource = Join-Path $source 'installer\Start-CPA-Stack.bootstrap.ps1'

if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf) -or
    -not (Test-Path -LiteralPath $common -PathType Leaf) -or
    -not (Test-Path -LiteralPath $bootstrapSource -PathType Leaf)) {
    throw 'The repository does not contain a complete cpa-safe-upgrade skill.'
}
. $common
$updaterVersion = Get-CpaStackUpdaterVersion
$repositoryVersion = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION'), [System.Text.UTF8Encoding]::new($false, $true)).Trim()
if ($repositoryVersion -ne $updaterVersion) {
    throw 'Repository VERSION does not match the bundled skill VERSION.'
}

function Get-Manifest {
    param([string]$Root)
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $full -Recurse -File -Force |
            ForEach-Object {
                [pscustomobject]@{
                    path = $_.FullName.Substring($full.Length).TrimStart('\')
                    length = $_.Length
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToUpperInvariant()
                }
            } |
            Sort-Object path
    )
}

function Get-ComparableManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    return @(
        Get-Manifest -Root $Root |
            Where-Object { $_.path -notin @('.cpa-stack-updater-installed.json', $transactionClaimName) }
    )
}

function Get-ByteArraySha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToUpperInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Invoke-AtomicFileReplaceNoBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ReplacementPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if ($null -eq ('CpaStackUpdater.AtomicFileReplace' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CpaStackUpdater
{
    public static class AtomicFileReplace
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ReplaceFile(
            string replacedFileName,
            string replacementFileName,
            string backupFileName,
            uint replaceFlags,
            IntPtr exclude,
            IntPtr reserved);

        public static void Replace(string replacementPath, string destinationPath)
        {
            if (!ReplaceFile(destinationPath, replacementPath, null, 0, IntPtr.Zero, IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@
    }

    [CpaStackUpdater.AtomicFileReplace]::Replace(
        [System.IO.Path]::GetFullPath($ReplacementPath),
        [System.IO.Path]::GetFullPath($DestinationPath)
    )
}

function Get-OrdinalSortedManifestEntries {
    param([Parameter(Mandatory = $true)]$Manifest)

    $lookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($Manifest)) {
        $path = [string]$entry.path
        if ($lookup.ContainsKey($path)) { throw "Manifest contains a duplicate path: $path" }
        $lookup[$path] = $entry
        [void]$paths.Add($path)
    }
    $paths.Sort([System.StringComparer]::Ordinal)
    return @($paths | ForEach-Object { $lookup[$_] })
}

function Get-ManifestSha256 {
    param([Parameter(Mandatory = $true)]$Manifest)

    $lines = @(Get-OrdinalSortedManifestEntries -Manifest $Manifest | ForEach-Object {
        $encodedPath = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$_.path))
        $encodedPath + ':' + [string][long]$_.length + ':' + ([string]$_.sha256).ToUpperInvariant()
    })
    $canonical = ($lines -join "`n") + "`n"
    return Get-ByteArraySha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($canonical))
}

function Test-CanonicalPathEqual {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return [string]::IsNullOrWhiteSpace($Left) -and [string]::IsNullOrWhiteSpace($Right)
    }
    try {
        $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\')
        $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
    } catch {
        return $false
    }
    return [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RenderedLauncherBootstrap {
    $template = [System.IO.File]::ReadAllText($bootstrapSource, [System.Text.UTF8Encoding]::new($false, $true))
    $token = '__CPA_STACK_CODEX_HOME_BASE64__'
    if ([regex]::Matches($template, [regex]::Escape($token)).Count -ne 1) {
        throw 'Launcher bootstrap template must contain exactly one CodexHome token.'
    }
    $codexHomeFull = [System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
    $encodedHome = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($codexHomeFull))
    $rendered = $template.Replace($token, $encodedHome)
    return ,([System.Text.UTF8Encoding]::new($false).GetBytes($rendered))
}

function Test-ManifestEqual {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    $leftEntries = @(Get-OrdinalSortedManifestEntries -Manifest $Left)
    $rightEntries = @(Get-OrdinalSortedManifestEntries -Manifest $Right)
    if ($leftEntries.Count -ne $rightEntries.Count) { return $false }
    for ($index = 0; $index -lt $leftEntries.Count; $index++) {
        if ([string]$leftEntries[$index].path -cne [string]$rightEntries[$index].path -or
            [long]$leftEntries[$index].length -ne [long]$rightEntries[$index].length -or
            [string]$leftEntries[$index].sha256 -cne [string]$rightEntries[$index].sha256) {
            return $false
        }
    }
    return $true
}

function Get-SkillVersion {
    param([Parameter(Mandatory = $true)][string]$Root)

    $path = Join-Path $Root 'VERSION'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $value = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true)).Trim()
    if ($value -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { return $null }
    return $value
}

function Get-SkillInstallAssessment {
    param([Parameter(Mandatory = $true)]$SourceManifest)

    if (-not (Test-Path -LiteralPath $installed)) {
        return [pscustomobject]@{
            installedVersion = $null
            updateAvailable = $true
            owned = $false
        }
    }
    if (-not (Test-Path -LiteralPath $installed -PathType Container)) {
        throw "Installed skill slot is not a directory: $installed"
    }

    $owned = Test-OwnedSkillDirectory -Root $installed
    if (-not $owned) { Assert-LegacySkillDirectory -Root $installed }
    $installedVersion = Get-SkillVersion -Root $installed
    $installedManifest = @(Get-ComparableManifest -Root $installed)
    $manifestCurrent = Test-ManifestEqual -Left $SourceManifest -Right $installedManifest
    return [pscustomobject]@{
        installedVersion = $installedVersion
        updateAvailable = (-not $owned -or [string]$installedVersion -cne [string]$updaterVersion -or -not $manifestCurrent)
        owned = $owned
    }
}

function Assert-SafeSkillTree {
    $sensitiveSegments = @('auth', 'config', 'data', 'logs', 'releases', 'rollback', 'runtime', 'work')
    $reparse = @(Get-ChildItem -LiteralPath $source -Recurse -Force | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparse.Count -gt 0) {
        throw "The skill source contains a reparse point: $($reparse.FullName -join ', ')"
    }
    $forbidden = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force | Where-Object {
        $relative = $_.FullName.Substring([System.IO.Path]::GetFullPath($source).TrimEnd('\').Length).TrimStart('\')
        $segments = @($relative.Split('\') | ForEach-Object { $_.ToLowerInvariant() })
        $_.Name -match '(?i)(secrets\.local|data\.key|usage\.sqlite|\.env$|\.log$)' -or
        $_.Extension -in @('.db', '.sqlite', '.zip', '.exe') -or
        @($segments | Where-Object { $_ -in $sensitiveSegments }).Count -gt 0
    })
    if ($forbidden.Count -gt 0) {
        throw "The skill source contains forbidden runtime or secret files: $($forbidden.Name -join ', ')"
    }
}

function Get-InstallMarkerPath {
    param([string]$Root)
    return Join-Path $Root '.cpa-stack-updater-installed.json'
}

function Test-OwnedSkillDirectory {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    $rootItem = Get-Item -Force -LiteralPath $Root
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $reparse = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparse.Count -gt 0) { return $false }
    $markerPath = Get-InstallMarkerPath -Root $Root
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    try {
        $marker = Read-CpaStackJson -Path $markerPath
        return ([int]$marker.schemaVersion -eq 1 -and [string]$marker.product -ceq 'cpa-stack-updater' -and [string]$marker.skill -ceq 'cpa-safe-upgrade')
    } catch {
        return $false
    }
}

function Assert-LegacySkillDirectory {
    param([string]$Root)
    $markerPath = Get-InstallMarkerPath -Root $Root
    if (Test-Path -LiteralPath $markerPath) {
        throw "Refusing to claim a legacy skill directory containing an invalid ownership marker: $Root"
    }
    $skillPath = Join-Path $Root 'SKILL.md'
    $commonPath = Join-Path $Root 'scripts\CpaStack.Common.ps1'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf) -or -not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
        throw "Refusing to replace an unowned directory: $Root"
    }
    $rootItem = Get-Item -Force -LiteralPath $Root
    $reparse = @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 })
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $reparse.Count -gt 0) {
        throw "Refusing to claim a legacy skill directory containing a reparse point: $Root"
    }
    $skillText = [System.IO.File]::ReadAllText($skillPath, [System.Text.UTF8Encoding]::new($false, $true))
    if ($skillText -notmatch '(?s)^---\s*\r?\nname:\s*cpa-safe-upgrade\s*\r?\ndescription:') {
        throw "Refusing to replace a directory that is not a cpa-safe-upgrade skill: $Root"
    }
    $sensitiveSegments = @('auth', 'config', 'data', 'logs', 'releases', 'rollback', 'runtime', 'work')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $forbidden = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $relative = $_.FullName.Substring($rootFull.Length).TrimStart('\')
        $segments = @($relative.Split('\') | ForEach-Object { $_.ToLowerInvariant() })
        $_.Name -match '(?i)(secrets\.local|data\.key|usage\.sqlite|\.env$|\.log$)' -or
        $_.Extension -in @('.db', '.sqlite', '.zip', '.exe') -or
        @($segments | Where-Object { $_ -in $sensitiveSegments }).Count -gt 0
    })
    if ($forbidden.Count -gt 0) {
        throw "Refusing to claim a legacy skill directory that contains runtime or private data: $Root"
    }
}

function Write-InstallMarker {
    param([string]$Root)
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        product = 'cpa-stack-updater'
        skill = 'cpa-safe-upgrade'
        transactionId = $transactionId
        updaterVersion = $updaterVersion
        installedAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path (Get-InstallMarkerPath -Root $Root)
}

function Assert-SkillSlotPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Staging', 'Retained', 'Retiring')][string]$Kind
    )

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\')
    $expectedParent = if ($Kind -ceq 'Installed') {
        [System.IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')
    } else {
        [System.IO.Path]::GetFullPath($slotRoot).TrimEnd('\')
    }
    Assert-CpaStackPathNoReparseAncestors -Path $expectedParent -Description 'Skill slot parent path'
    Assert-CpaStackPathNoReparseAncestors -Path $full -Description 'Skill transaction path'
    if (-not [string]::Equals($parent, $expectedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Skill transaction path is outside the skills directory: $Path"
    }

    $name = [System.IO.Path]::GetFileName($full)
    $validName = switch ($Kind) {
        'Installed' { $name -ceq 'cpa-safe-upgrade' }
        'Previous' { $name -ceq 'previous' }
        'Staging' { $name -cmatch '^staging-[0-9a-f]{32}$' }
        'Retained' { $name -cmatch '^retained-[0-9a-f]{32}$' }
        'Retiring' { $name -cmatch '^retiring-[0-9a-f]{32}$' }
    }
    if (-not $validName) {
        throw "Skill transaction path does not match its fixed slot: $Path"
    }

    foreach ($candidate in @($expectedParent, $full)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -Force -LiteralPath $candidate
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Skill transaction path must not cross a reparse point: $candidate"
            }
        }
    }
    return $full
}

function Test-RetriableSkillMoveError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.IO.IOException] -or $exception -is [System.UnauthorizedAccessException]) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return ([string]$ErrorRecord.FullyQualifiedErrorId -match '(?i)(IOError|UnauthorizedAccess)')
}

function Move-SkillDirectoryWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Staging', 'Retained', 'Retiring')][string]$SourceKind,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Staging', 'Retained', 'Retiring')][string]$DestinationKind,
        [int]$MaximumAttempts = 4
    )

    $sourceFull = Assert-SkillSlotPath -Path $SourcePath -Kind $SourceKind
    $destinationFull = Assert-SkillSlotPath -Path $DestinationPath -Kind $DestinationKind
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
        throw "Skill move source does not exist: $sourceFull"
    }
    if (Test-Path -LiteralPath $destinationFull) {
        throw "Skill move destination already exists: $destinationFull"
    }

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            [System.IO.Directory]::Move($sourceFull, $destinationFull)
            return
        } catch {
            $moveError = $_
            if (-not (Test-RetriableSkillMoveError -ErrorRecord $moveError)) {
                throw
            }
            if (-not (Test-Path -LiteralPath $sourceFull -PathType Container) -or (Test-Path -LiteralPath $destinationFull)) {
                throw "Skill directory move reached an ambiguous state. Source=$sourceFull Destination=$destinationFull"
            }
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Milliseconds (200 * $attempt)
                continue
            }
            throw "Could not move the installed CPA skill after $MaximumAttempts attempts. Close editors or terminals using files under '$sourceFull', then retry. No process was terminated. Original error: $($moveError.Exception.Message)"
        }
    }
}

function New-SkillSlotDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$CanonicalSlot,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Target')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidateSet('Owned', 'Legacy')][string]$Ownership
    )

    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Skill slot descriptor root is not a directory: $full"
    }
    $manifest = @(Get-ComparableManifest -Root $full)
    $markerPath = Get-InstallMarkerPath -Root $full
    $markerHash = if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        Get-CpaStackFileHash -Path $markerPath
    } else {
        $null
    }
    if ($Ownership -ceq 'Owned' -and $markerHash -notmatch '^[0-9A-F]{64}$') {
        throw "Owned skill descriptor has no valid ownership marker: $full"
    }
    if ($Ownership -ceq 'Legacy' -and -not [string]::IsNullOrWhiteSpace($markerHash)) {
        throw "Legacy skill descriptor unexpectedly has an ownership marker: $full"
    }
    return [pscustomobject][ordered]@{
        path = [System.IO.Path]::GetFullPath($CanonicalSlot).TrimEnd('\')
        kind = $Kind
        ownership = $Ownership
        markerSha256 = $markerHash
        manifest = $manifest
        manifestSha256 = Get-ManifestSha256 -Manifest $manifest
    }
}

function Assert-SkillSlotDescriptorDocument {
    param(
        [Parameter(Mandatory = $true)]$Descriptor,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Target')][string]$ExpectedKind
    )

    if ($Descriptor -is [array] -or
        -not (Test-CanonicalPathEqual -Left ([string]$Descriptor.path) -Right $ExpectedPath) -or
        [string]$Descriptor.kind -cne $ExpectedKind -or
        [string]$Descriptor.ownership -notin @('Owned', 'Legacy') -or
        [string]$Descriptor.manifestSha256 -notmatch '^[0-9A-F]{64}$') {
        throw "Skill install journal contains an invalid $ExpectedKind slot descriptor."
    }
    if ([string]$Descriptor.ownership -ceq 'Owned') {
        if ([string]$Descriptor.markerSha256 -notmatch '^[0-9A-F]{64}$') {
            throw "Owned $ExpectedKind slot descriptor has an invalid marker hash."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Descriptor.markerSha256)) {
        throw "Legacy $ExpectedKind slot descriptor must not contain a marker hash."
    }

    $paths = @{}
    foreach ($entry in @($Descriptor.manifest)) {
        $relative = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathRooted($relative) -or
            @($relative.Split('\') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
            $relative -in @('.cpa-stack-updater-installed.json', $transactionClaimName) -or
            [long]$entry.length -lt 0 -or
            [string]$entry.sha256 -notmatch '^[0-9A-F]{64}$' -or
            $paths.ContainsKey($relative)) {
            throw "Skill install journal contains an invalid $ExpectedKind manifest entry."
        }
        $paths[$relative] = $true
    }
    if ((Get-ManifestSha256 -Manifest @($Descriptor.manifest)) -cne [string]$Descriptor.manifestSha256) {
        throw "Skill install journal $ExpectedKind manifest hash is invalid."
    }
    return $Descriptor
}

function Assert-SkillSlotMatchesDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Descriptor,
        [AllowNull()][string]$AllowedLegacyMarkerSha256
    )

    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Claimed skill artifact is not a directory: $full"
    }
    $rootItem = Get-Item -Force -LiteralPath $full
    $reparse = @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $reparse.Count -gt 0) {
        throw "Claimed skill artifact contains a reparse point: $full"
    }
    $manifest = @(Get-ComparableManifest -Root $full)
    if (-not (Test-ManifestEqual -Left @($Descriptor.manifest) -Right $manifest) -or
        (Get-ManifestSha256 -Manifest $manifest) -cne [string]$Descriptor.manifestSha256) {
        throw "Claimed skill artifact manifest changed or contains foreign files: $full"
    }
    $markerPath = Get-InstallMarkerPath -Root $full
    $actualMarkerHash = Get-CpaStackFileHash -Path $markerPath
    if ([string]$Descriptor.ownership -ceq 'Owned') {
        if ($actualMarkerHash -cne [string]$Descriptor.markerSha256 -or -not (Test-OwnedSkillDirectory -Root $full)) {
            throw "Claimed skill artifact ownership marker changed: $full"
        }
    } elseif ([string]::IsNullOrWhiteSpace($AllowedLegacyMarkerSha256)) {
        if (-not [string]::IsNullOrWhiteSpace($actualMarkerHash)) {
            throw "Legacy claimed skill artifact gained an unexpected marker: $full"
        }
        Assert-LegacySkillDirectory -Root $full
    } elseif ($AllowedLegacyMarkerSha256 -notmatch '^[0-9A-F]{64}$' -or $actualMarkerHash -cne $AllowedLegacyMarkerSha256) {
        throw "Transactional legacy marker changed on claimed skill artifact: $full"
    }
    return $full
}

function Get-SkillTransactionClaimPath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId
    )

    return (Get-JournalTransactionPathFromId -TransactionId $ExpectedTransactionId -Kind $Kind) + '.claim.json'
}

function Write-SkillTransactionClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)]$Descriptor
    )

    [void](Assert-SkillSlotMatchesDescriptor -Root $Root -Descriptor $Descriptor)
    $artifactPath = Get-JournalTransactionPathFromId -TransactionId $ExpectedTransactionId -Kind $Kind
    $claimPath = Get-SkillTransactionClaimPath -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId
    if (Test-Path -LiteralPath $claimPath) {
        throw "Skill transaction claim already exists: $claimPath"
    }
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        product = 'cpa-stack-updater'
        operation = 'skill-install-artifact'
        transactionId = $ExpectedTransactionId
        kind = $Kind
        canonicalParent = [System.IO.Path]::GetFullPath($slotRoot).TrimEnd('\')
        artifactPath = $artifactPath
        descriptorPath = [string]$Descriptor.path
        descriptorKind = [string]$Descriptor.kind
        ownership = [string]$Descriptor.ownership
        markerSha256 = $Descriptor.markerSha256
        manifest = @($Descriptor.manifest)
        manifestSha256 = [string]$Descriptor.manifestSha256
    }) -Path $claimPath
    Protect-CpaStackSecretFile -Path $claimPath
    [void](Assert-SkillTransactionClaim -Root $Root -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId -Descriptor $Descriptor)
}

function Assert-SkillTransactionClaimDocument {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)]$Descriptor
    )

    $claimPath = Get-SkillTransactionClaimPath -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId
    if (-not (Test-Path -LiteralPath $claimPath -PathType Leaf)) {
        throw "Claimed skill transaction artifact has no sidecar claim: $claimPath"
    }
    $claimItem = Get-Item -Force -LiteralPath $claimPath
    if (($claimItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Skill transaction sidecar claim is a reparse point: $claimPath"
    }
    $claimAcl = Get-CpaStackFileSystemAcl -Path $claimPath
    if (-not (Test-CpaStackPrivateAcl -Acl $claimAcl)) {
        throw "Skill transaction sidecar claim ACL is not private: $claimPath"
    }
    $claim = Read-CpaStackJson -Path $claimPath
    $expectedArtifactPath = Get-JournalTransactionPathFromId -TransactionId $ExpectedTransactionId -Kind $Kind
    if ([int]$claim.schemaVersion -ne 1 -or
        [string]$claim.product -cne 'cpa-stack-updater' -or
        [string]$claim.operation -cne 'skill-install-artifact' -or
        [string]$claim.transactionId -cne $ExpectedTransactionId -or
        [string]$claim.kind -cne $Kind -or
        -not (Test-CanonicalPathEqual -Left ([string]$claim.canonicalParent) -Right $slotRoot) -or
        -not (Test-CanonicalPathEqual -Left ([string]$claim.artifactPath) -Right $expectedArtifactPath) -or
        -not (Test-CanonicalPathEqual -Left ([string]$claim.descriptorPath) -Right ([string]$Descriptor.path)) -or
        [string]$claim.descriptorKind -cne [string]$Descriptor.kind -or
        [string]$claim.ownership -cne [string]$Descriptor.ownership -or
        [string]$claim.markerSha256 -cne [string]$Descriptor.markerSha256 -or
        [string]$claim.manifestSha256 -cne [string]$Descriptor.manifestSha256 -or
        -not (Test-ManifestEqual -Left @($claim.manifest) -Right @($Descriptor.manifest))) {
        throw "Skill transaction sidecar claim is foreign or invalid: $claimPath"
    }
    return $claim
}

function Assert-SkillTransactionClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)]$Descriptor,
        [AllowNull()][string]$AllowedLegacyMarkerSha256
    )

    [void](Assert-SkillSlotMatchesDescriptor -Root $Root -Descriptor $Descriptor -AllowedLegacyMarkerSha256 $AllowedLegacyMarkerSha256)
    return Assert-SkillTransactionClaimDocument -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId -Descriptor $Descriptor
}

function Remove-SkillTransactionClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)]$Descriptor,
        [AllowNull()][string]$AllowedLegacyMarkerSha256
    )

    [void](Assert-SkillTransactionClaim -Root $Root -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId -Descriptor $Descriptor -AllowedLegacyMarkerSha256 $AllowedLegacyMarkerSha256)
    Remove-Item -LiteralPath (Get-SkillTransactionClaimPath -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId) -Force -ErrorAction Stop
    [void](Assert-SkillSlotMatchesDescriptor -Root $Root -Descriptor $Descriptor -AllowedLegacyMarkerSha256 $AllowedLegacyMarkerSha256)
}

function Remove-ClaimedSkillTransactionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId,
        [Parameter(Mandatory = $true)]$Descriptor
    )

    $full = Assert-SkillSlotPath -Path $Path -Kind $Kind
    if (-not (Test-Path -LiteralPath $full)) { return }
    [void](Assert-SkillTransactionClaim -Root $full -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId -Descriptor $Descriptor)
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    Remove-Item -LiteralPath (Get-SkillTransactionClaimPath -Kind $Kind -ExpectedTransactionId $ExpectedTransactionId) -Force -ErrorAction Stop
}

function Get-SkillTransactionDirectories {
    param([Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind)

    if (-not (Test-Path -LiteralPath $slotRoot -PathType Container)) {
        return @()
    }
    $pattern = switch ($Kind) {
        'Staging' { '^staging-[0-9a-f]{32}$' }
        'Retained' { '^retained-[0-9a-f]{32}$' }
        'Retiring' { '^retiring-[0-9a-f]{32}$' }
    }
    return @(
        Get-ChildItem -LiteralPath $slotRoot -Force -ErrorAction Stop |
            Where-Object { $_.Name -cmatch $pattern } |
            ForEach-Object { Assert-SkillSlotPath -Path $_.FullName -Kind $Kind }
    )
}

function Clear-StaleSkillTransactionDirectories {
    $artifacts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($kind in @('Staging', 'Retained', 'Retiring')) {
        foreach ($path in @(Get-SkillTransactionDirectories -Kind $kind)) { [void]$artifacts.Add($path) }
    }
    if (Test-Path -LiteralPath $slotRoot -PathType Container) {
        foreach ($claim in @(Get-ChildItem -LiteralPath $slotRoot -Force -File -ErrorAction Stop | Where-Object {
            $_.Name -cmatch '^(?:staging|retained|retiring)-[0-9a-f]{32}\.claim\.json$'
        })) { [void]$artifacts.Add($claim.FullName) }
    }
    if ($artifacts.Count -gt 0) {
        throw "Unreferenced skill transaction artifacts require manual recovery; no directory was deleted: $($artifacts -join ', ')"
    }
}

function Initialize-SkillSlotRoot {
    foreach ($path in @($slotStateRoot, $slotRoot)) {
        Assert-CpaStackPathNoReparseAncestors -Path $path -Description 'Installer skill slot path'
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
            Protect-CpaStackPrivateDirectory -Path $path
        }
        Assert-CpaStackInstallAcl -Path $path -PathType Container -RequireProtected
    }
}

function Initialize-SkillDiscoveryRoot {
    Assert-CpaStackPathNoReparseAncestors -Path $skillsRoot -Description 'Codex skill discovery root'
    if (-not (Test-Path -LiteralPath $skillsRoot)) {
        New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
    } elseif (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
        throw "Codex skill discovery root is not a directory: $skillsRoot"
    }
    $skillsAcl = Get-CpaStackFileSystemAcl -Path $skillsRoot
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ((Get-CpaStackAclOwnerSid -Acl $skillsAcl) -ne $currentSid) {
        throw "Codex skill discovery root is not owned by the current Windows user: $skillsRoot"
    }
    Protect-CpaStackPrivateDirectory -Path $skillsRoot
    Assert-CpaStackInstallAcl -Path $skillsRoot -PathType Container -RequireProtected
}

function Read-LegacyPreviousRelocationJournal {
    param(
        [switch]$Optional,
        [string]$Path = $relocationJournal
    )

    $journalPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $journalPath)) {
        if ($Optional) { return $null }
        throw "Legacy previous relocation journal is missing: $journalPath"
    }
    Assert-CpaStackInstallAcl -Path $journalPath -PathType Leaf
    $journal = Read-CpaStackJson -Path $journalPath
    if ([int]$journal.schemaVersion -ne 1 -or
        [string]$journal.product -cne 'cpa-stack-updater' -or
        [string]$journal.operation -cne 'legacy-skill-slot-relocation' -or
        [string]$journal.transactionId -notmatch '^[0-9a-f]{32}$' -or
        [string]$journal.phase -notin @('Prepared', 'Committed') -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.canonicalCodexHome) -Right $codexHomeFull) -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.canonicalSkillsRoot) -Right $skillsRoot) -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.canonicalSlotRoot) -Right $slotRoot) -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.sourcePath) -Right $legacyPrevious) -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.targetPath) -Right $previous) -or
        $null -eq $journal.descriptor) {
        throw 'Legacy previous relocation journal is invalid.'
    }
    [void](Assert-SkillSlotDescriptorDocument -Descriptor $journal.descriptor -ExpectedPath $previous -ExpectedKind Previous)
    if ([string]$journal.descriptor.ownership -cne 'Owned') {
        throw 'Legacy previous relocation source must be installer-owned.'
    }
    return $journal
}

function Write-LegacyPreviousRelocationJournal {
    param([Parameter(Mandatory = $true)]$Journal)

    $temporary = $relocationJournalWrite
    if (Test-Path -LiteralPath $temporary) {
        throw "Legacy previous relocation journal has an unresolved write artifact: $temporary"
    }
    try {
        [System.IO.File]::WriteAllText($temporary, ($Journal | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        Protect-CpaStackSecretFile -Path $temporary
        if (Test-Path -LiteralPath $relocationJournal -PathType Leaf) {
            Protect-CpaStackSecretFile -Path $relocationJournal
            Invoke-AtomicFileReplaceNoBackup -ReplacementPath $temporary -DestinationPath $relocationJournal
        } else {
            [System.IO.File]::Move($temporary, $relocationJournal)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    Protect-CpaStackSecretFile -Path $relocationJournal
    [void](Read-LegacyPreviousRelocationJournal)
}

function Get-LegacyPreviousRelocationPending {
    $journal = Read-LegacyPreviousRelocationJournal -Optional
    return $null -ne $journal -or (Test-Path -LiteralPath $legacyPrevious)
}

function Invoke-LegacyPreviousRelocation {
    $journal = Read-LegacyPreviousRelocationJournal -Optional
    if ($null -eq $journal) {
        if (-not (Test-Path -LiteralPath $legacyPrevious)) { return $false }
        if (-not (Test-Path -LiteralPath $legacyPrevious -PathType Container)) {
            throw "Legacy previous skill slot is not a directory: $legacyPrevious"
        }
        if (Test-Path -LiteralPath $previous) {
            throw 'Legacy previous skill relocation target is already occupied; no slot was moved.'
        }
        Assert-CpaStackPathNoReparseAncestors -Path $legacyPrevious -Description 'Legacy previous skill slot'
        Assert-CpaStackPathNoReparseAncestors -Path $previous -Description 'Protected previous skill slot'
        Assert-CpaStackInstallAcl -Path $legacyPrevious -PathType Container
        if (-not (Test-OwnedSkillDirectory -Root $legacyPrevious)) {
            throw 'Legacy previous skill slot is not safely installer-owned; no relocation was performed.'
        }
        $descriptor = New-SkillSlotDescriptor -Root $legacyPrevious -CanonicalSlot $previous -Kind Previous -Ownership Owned
        Initialize-SkillDiscoveryRoot
        Initialize-SkillSlotRoot
        $journal = [pscustomobject][ordered]@{
            schemaVersion = 1
            product = 'cpa-stack-updater'
            operation = 'legacy-skill-slot-relocation'
            transactionId = [guid]::NewGuid().ToString('N')
            phase = 'Prepared'
            canonicalCodexHome = $codexHomeFull
            canonicalSkillsRoot = [System.IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')
            canonicalSlotRoot = [System.IO.Path]::GetFullPath($slotRoot).TrimEnd('\')
            sourcePath = [System.IO.Path]::GetFullPath($legacyPrevious).TrimEnd('\')
            targetPath = [System.IO.Path]::GetFullPath($previous).TrimEnd('\')
            descriptor = $descriptor
        }
        Write-LegacyPreviousRelocationJournal -Journal $journal
    }

    $sourceExists = Test-Path -LiteralPath $legacyPrevious -PathType Container
    $targetExists = Test-Path -LiteralPath $previous -PathType Container
    if ($sourceExists -and $targetExists) {
        throw 'Legacy previous relocation found both source and target slots; no path was changed.'
    }
    if (-not $sourceExists -and -not $targetExists) {
        throw 'Legacy previous relocation cannot locate its journal-bound slot.'
    }
    if ($sourceExists) {
        [void](Assert-SkillSlotMatchesDescriptor -Root $legacyPrevious -Descriptor $journal.descriptor)
        [System.IO.Directory]::Move($legacyPrevious, $previous)
    }
    [void](Assert-SkillSlotMatchesDescriptor -Root $previous -Descriptor $journal.descriptor)
    $journal.phase = 'Committed'
    Write-LegacyPreviousRelocationJournal -Journal $journal
    [void](Read-LegacyPreviousRelocationJournal)
    Remove-Item -LiteralPath $relocationJournal -Force -ErrorAction Stop
    return $true
}

function Remove-TransactionalLegacyMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedTransactionId,
        [AllowNull()][string]$ExpectedHash
    )

    $full = Assert-SkillSlotPath -Path $Root -Kind $Kind
    if (-not (Test-OwnedSkillDirectory -Root $full)) {
        throw "Refusing to remove a transactional marker from an unowned directory: $full"
    }
    $markerPath = Get-InstallMarkerPath -Root $full
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash) -and
        ($ExpectedHash -notmatch '^[0-9A-F]{64}$' -or (Get-CpaStackFileHash -Path $markerPath) -cne $ExpectedHash)) {
        throw "Transactional legacy ownership marker changed during install: $markerPath"
    }
    $marker = Read-CpaStackJson -Path $markerPath
    if ([string]$marker.transactionId -cne $ExpectedTransactionId) {
        throw "Transactional legacy ownership marker belongs to a different install: $markerPath"
    }
    if ([string]$marker.updaterVersion -cne $updaterVersion) {
        throw "Transactional legacy ownership marker has an unexpected updater version: $markerPath"
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    Assert-LegacySkillDirectory -Root $full
}

function New-SkillInstallJournalDocument {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][bool]$HadInstalled,
        [Parameter(Mandatory = $true)][bool]$HadPrevious,
        [Parameter(Mandatory = $true)][bool]$InstalledWasLegacy,
        [AllowNull()]$OriginalInstalled,
        [AllowNull()]$OriginalPrevious,
        [Parameter(Mandatory = $true)]$Target
    )

    $requestedRoot = if ([bool]$Plan.stackRootSpecified) {
        [System.IO.Path]::GetFullPath([string]$Plan.registeredRoot).TrimEnd('\')
    } else {
        $null
    }
    $intentRoot = if ([bool]$Plan.manageLauncher -or [bool]$Plan.stackRootSpecified -or [bool]$Plan.rootPlan.preinitializeRequired) {
        [System.IO.Path]::GetFullPath([string]$Plan.registeredRoot).TrimEnd('\')
    } else {
        $null
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 3
        product = 'cpa-stack-updater'
        operation = 'install'
        transactionId = $transactionId
        phase = 'Prepared'
        canonicalCodexHome = $codexHomeFull
        canonicalSkillsRoot = [System.IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')
        canonicalSlotRoot = [System.IO.Path]::GetFullPath($slotRoot).TrimEnd('\')
        requestedStackRootSpecified = [bool]$Plan.stackRootSpecified
        requestedStackRoot = $requestedRoot
        intentRoot = $intentRoot
        launcherIntent = [bool]$Plan.manageLauncher
        registrationIntent = [bool]$Plan.stackRootSpecified
        rootPreinitializeIntent = [bool]([bool]$Plan.stackRootSpecified -and [bool]$Plan.rootPlan.preinitializeRequired)
        hadInstalled = $HadInstalled
        hadPrevious = $HadPrevious
        installedWasLegacy = $InstalledWasLegacy
        installedOwnedBeforeTransaction = [bool]($HadInstalled -and -not $InstalledWasLegacy)
        legacyMarkerPending = $false
        legacyMarkerAdded = $false
        legacyMarkerSha256 = $null
        sourceVersion = $updaterVersion
        originalInstalled = $OriginalInstalled
        originalPrevious = $OriginalPrevious
        target = $Target
        postCommit = [pscustomobject][ordered]@{
            rootReady = -not [bool]([bool]$Plan.stackRootSpecified -and [bool]$Plan.rootPlan.preinitializeRequired)
            launcherVerified = -not [bool]$Plan.manageLauncher
            registrationVerified = -not [bool]$Plan.stackRootSpecified
        }
    }
}

function Write-SkillInstallJournalDocument {
    param([Parameter(Mandatory = $true)]$Journal)

    $temporary = $installJournalWrite
    if (Test-Path -LiteralPath $temporary) {
        throw "Skill install journal has an unresolved write artifact: $temporary"
    }
    try {
        [System.IO.File]::WriteAllText($temporary, ($Journal | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        Protect-CpaStackSecretFile -Path $temporary
        if (Test-Path -LiteralPath $installJournal -PathType Leaf) {
            Protect-CpaStackSecretFile -Path $installJournal
            Invoke-AtomicFileReplaceNoBackup -ReplacementPath $temporary -DestinationPath $installJournal
        } else {
            [System.IO.File]::Move($temporary, $installJournal)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
    Protect-CpaStackSecretFile -Path $installJournal
    $written = Read-SkillInstallJournal
    if ([string]$written.transactionId -cne [string]$Journal.transactionId -or [string]$written.phase -cne [string]$Journal.phase) {
        throw 'Skill install journal verification failed.'
    }
}

function Write-SkillInstallJournal {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Prepared', 'RetiringInstalled', 'RetainingPrevious', 'MovingActiveToPrevious', 'Committing', 'Committed')]
        [string]$Phase,
        [bool]$LegacyMarkerAdded = $false,
        [AllowNull()][string]$LegacyMarkerSha256
    )

    if ($LegacyMarkerAdded -and $LegacyMarkerSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'Legacy marker journal state requires a valid SHA-256 hash.'
    }
    if (-not $LegacyMarkerAdded -and -not [string]::IsNullOrWhiteSpace($LegacyMarkerSha256)) {
        throw 'Legacy marker journal hash cannot exist before the marker is added.'
    }
    $Journal.phase = $Phase
    if ($LegacyMarkerAdded) { $Journal.legacyMarkerPending = $false }
    $Journal.legacyMarkerAdded = $LegacyMarkerAdded
    $Journal.legacyMarkerSha256 = if ($LegacyMarkerAdded) { $LegacyMarkerSha256 } else { $null }
    Write-SkillInstallJournalDocument -Journal $Journal
}

function Read-SkillInstallJournal {
    param(
        [switch]$Optional,
        [string]$Path = $installJournal
    )

    $journalPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $journalPath)) {
        if ($Optional) { return $null }
        throw "Skill install journal is missing: $journalPath"
    }
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "Skill install journal is not a regular file: $journalPath"
    }
    $item = Get-Item -Force -LiteralPath $journalPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Skill install journal must not be a reparse point.'
    }
    $acl = Get-CpaStackFileSystemAcl -Path $journalPath
    if (-not (Test-CpaStackPrivateAcl -Acl $acl)) {
        throw 'Skill install journal ACL is not private.'
    }
    $journal = Read-CpaStackJson -Path $journalPath
    $validPhase = [string]$journal.phase -in @('Prepared', 'RetiringInstalled', 'RetainingPrevious', 'MovingActiveToPrevious', 'Committing', 'Committed')
    $legacyMarkerStateValid = if ([bool]$journal.legacyMarkerPending) {
        -not [bool]$journal.legacyMarkerAdded -and [string]::IsNullOrWhiteSpace([string]$journal.legacyMarkerSha256)
    } elseif ([bool]$journal.legacyMarkerAdded) {
        [string]$journal.legacyMarkerSha256 -match '^[0-9A-F]{64}$'
    } else {
        [string]::IsNullOrWhiteSpace([string]$journal.legacyMarkerSha256)
    }
    $preexistingOwnershipValid = if ($journal.hadInstalled -is [bool] -and [bool]$journal.hadInstalled) {
        [bool]$journal.installedOwnedBeforeTransaction -ne [bool]$journal.installedWasLegacy
    } else {
        -not [bool]$journal.installedOwnedBeforeTransaction -and -not [bool]$journal.installedWasLegacy
    }
    $requestedRootValid = if ($journal.requestedStackRootSpecified -is [bool] -and [bool]$journal.requestedStackRootSpecified) {
        -not [string]::IsNullOrWhiteSpace([string]$journal.requestedStackRoot) -and
        (Test-CanonicalPathEqual -Left ([string]$journal.requestedStackRoot) -Right ([string]$journal.intentRoot))
    } else {
        [string]::IsNullOrWhiteSpace([string]$journal.requestedStackRoot)
    }
    if ([int]$journal.schemaVersion -ne 3 -or
        [string]$journal.product -cne 'cpa-stack-updater' -or
        [string]$journal.operation -cne 'install' -or
        [string]$journal.transactionId -notmatch '^[0-9a-f]{32}$' -or
        [string]$journal.sourceVersion -cne $updaterVersion -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.canonicalCodexHome) -Right $codexHomeFull) -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.canonicalSkillsRoot) -Right $skillsRoot) -or
        -not (Test-CanonicalPathEqual -Left ([string]$journal.canonicalSlotRoot) -Right $slotRoot) -or
        -not $validPhase -or
        $journal.requestedStackRootSpecified -isnot [bool] -or
        $journal.launcherIntent -isnot [bool] -or
        $journal.registrationIntent -isnot [bool] -or
        $journal.rootPreinitializeIntent -isnot [bool] -or
        -not $requestedRootValid -or
        ([bool]$journal.registrationIntent -ne [bool]$journal.requestedStackRootSpecified) -or
        ([bool]$journal.rootPreinitializeIntent -and (-not [bool]$journal.requestedStackRootSpecified -or -not [bool]$journal.launcherIntent)) -or
        (([bool]$journal.launcherIntent -or [bool]$journal.registrationIntent -or [bool]$journal.rootPreinitializeIntent) -and [string]::IsNullOrWhiteSpace([string]$journal.intentRoot)) -or
        $journal.hadInstalled -isnot [bool] -or
        $journal.hadPrevious -isnot [bool] -or
        $journal.installedWasLegacy -isnot [bool] -or
        $journal.installedOwnedBeforeTransaction -isnot [bool] -or
        $journal.legacyMarkerPending -isnot [bool] -or
        $journal.legacyMarkerAdded -isnot [bool] -or
        -not $legacyMarkerStateValid -or
        -not $preexistingOwnershipValid -or
        (([bool]$journal.legacyMarkerPending -or [bool]$journal.legacyMarkerAdded) -and -not [bool]$journal.installedWasLegacy) -or
        $null -eq $journal.postCommit -or
        $journal.postCommit.rootReady -isnot [bool] -or
        $journal.postCommit.launcherVerified -isnot [bool] -or
        $journal.postCommit.registrationVerified -isnot [bool] -or
        (-not [bool]$journal.rootPreinitializeIntent -and -not [bool]$journal.postCommit.rootReady) -or
        (-not [bool]$journal.launcherIntent -and -not [bool]$journal.postCommit.launcherVerified) -or
        (-not [bool]$journal.registrationIntent -and -not [bool]$journal.postCommit.registrationVerified) -or
        ([bool]$journal.hadInstalled -and $null -eq $journal.originalInstalled) -or
        (-not [bool]$journal.hadInstalled -and $null -ne $journal.originalInstalled) -or
        ([bool]$journal.hadPrevious -and $null -eq $journal.originalPrevious) -or
        (-not [bool]$journal.hadPrevious -and $null -ne $journal.originalPrevious) -or
        $null -eq $journal.target) {
        throw 'Skill install journal is invalid.'
    }
    if ($null -ne $journal.originalInstalled) {
        [void](Assert-SkillSlotDescriptorDocument -Descriptor $journal.originalInstalled -ExpectedPath $installed -ExpectedKind Installed)
        if (([string]$journal.originalInstalled.ownership -ceq 'Legacy') -ne [bool]$journal.installedWasLegacy) {
            throw 'Skill install journal installed ownership descriptor is inconsistent.'
        }
    }
    if ($null -ne $journal.originalPrevious) {
        [void](Assert-SkillSlotDescriptorDocument -Descriptor $journal.originalPrevious -ExpectedPath $previous -ExpectedKind Previous)
        if ([string]$journal.originalPrevious.ownership -cne 'Owned') {
            throw 'Skill install journal previous descriptor must be owned.'
        }
    }
    [void](Assert-SkillSlotDescriptorDocument -Descriptor $journal.target -ExpectedPath $installed -ExpectedKind Target)
    if ([string]$journal.target.ownership -cne 'Owned' -or
        -not (Test-ManifestEqual -Left @($journal.target.manifest) -Right @($sourceManifest)) -or
        [string]$journal.target.manifestSha256 -cne (Get-ManifestSha256 -Manifest $sourceManifest)) {
        throw 'Skill install journal target does not match the bundled source manifest.'
    }
    if (-not [string]::IsNullOrWhiteSpace($StackRoot)) {
        if (-not [bool]$journal.requestedStackRootSpecified -or
            -not (Test-CanonicalPathEqual -Left $StackRoot -Right ([string]$journal.requestedStackRoot))) {
            throw 'The pending skill install journal belongs to a different explicit StackRoot; no recovery or write was performed.'
        }
    }
    return $journal
}

function Get-SkillInstallJournalIdentityHash {
    param([Parameter(Mandatory = $true)]$Journal)

    $identity = [ordered]@{
        schemaVersion = [int]$Journal.schemaVersion
        product = [string]$Journal.product
        operation = [string]$Journal.operation
        transactionId = [string]$Journal.transactionId
        canonicalCodexHome = [string]$Journal.canonicalCodexHome
        canonicalSkillsRoot = [string]$Journal.canonicalSkillsRoot
        canonicalSlotRoot = [string]$Journal.canonicalSlotRoot
        requestedStackRootSpecified = [bool]$Journal.requestedStackRootSpecified
        requestedStackRoot = [string]$Journal.requestedStackRoot
        intentRoot = [string]$Journal.intentRoot
        launcherIntent = [bool]$Journal.launcherIntent
        registrationIntent = [bool]$Journal.registrationIntent
        rootPreinitializeIntent = [bool]$Journal.rootPreinitializeIntent
        hadInstalled = [bool]$Journal.hadInstalled
        hadPrevious = [bool]$Journal.hadPrevious
        installedWasLegacy = [bool]$Journal.installedWasLegacy
        installedOwnedBeforeTransaction = [bool]$Journal.installedOwnedBeforeTransaction
        sourceVersion = [string]$Journal.sourceVersion
        originalInstalled = $Journal.originalInstalled
        originalPrevious = $Journal.originalPrevious
        target = $Journal.target
    }
    $json = $identity | ConvertTo-Json -Depth 10 -Compress
    return Get-ByteArraySha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Assert-SkillInstallJournalWritePair {
    param(
        [Parameter(Mandatory = $true)]$Current,
        [Parameter(Mandatory = $true)]$Write
    )

    if ((Get-SkillInstallJournalIdentityHash -Journal $Current) -cne (Get-SkillInstallJournalIdentityHash -Journal $Write)) {
        throw 'Skill install journal write artifact belongs to a different transaction or intent.'
    }
    $phases = @('Prepared', 'RetiringInstalled', 'RetainingPrevious', 'MovingActiveToPrevious', 'Committing', 'Committed')
    $currentIndex = [Array]::IndexOf($phases, [string]$Current.phase)
    $writeIndex = [Array]::IndexOf($phases, [string]$Write.phase)
    if ($currentIndex -lt 0 -or $writeIndex -lt $currentIndex -or $writeIndex -gt ($currentIndex + 1)) {
        throw 'Skill install journal write artifact is not the same or next transaction phase.'
    }
}

function Get-LegacyRelocationJournalIdentityHash {
    param([Parameter(Mandatory = $true)]$Journal)

    $identity = [ordered]@{
        schemaVersion = [int]$Journal.schemaVersion
        product = [string]$Journal.product
        operation = [string]$Journal.operation
        transactionId = [string]$Journal.transactionId
        canonicalCodexHome = [string]$Journal.canonicalCodexHome
        canonicalSkillsRoot = [string]$Journal.canonicalSkillsRoot
        canonicalSlotRoot = [string]$Journal.canonicalSlotRoot
        sourcePath = [string]$Journal.sourcePath
        targetPath = [string]$Journal.targetPath
        descriptor = $Journal.descriptor
    }
    $json = $identity | ConvertTo-Json -Depth 10 -Compress
    return Get-ByteArraySha256 -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Assert-LegacyRelocationJournalWritePair {
    param(
        [Parameter(Mandatory = $true)]$Current,
        [Parameter(Mandatory = $true)]$Write
    )

    if ((Get-LegacyRelocationJournalIdentityHash -Journal $Current) -cne (Get-LegacyRelocationJournalIdentityHash -Journal $Write)) {
        throw 'Legacy previous relocation journal write artifact belongs to a different transaction.'
    }
    $phases = @('Prepared', 'Committed')
    $currentIndex = [Array]::IndexOf($phases, [string]$Current.phase)
    $writeIndex = [Array]::IndexOf($phases, [string]$Write.phase)
    if ($currentIndex -lt 0 -or $writeIndex -lt $currentIndex -or $writeIndex -gt ($currentIndex + 1)) {
        throw 'Legacy previous relocation journal write artifact is not the same or next transaction phase.'
    }
}

function Get-SkillSlotNamespaceState {
    $state = [ordered]@{
        installJournal = $null
        installJournalCurrent = $null
        installJournalWrite = $null
        installJournalWriteSha256 = $null
        relocationJournal = $null
        relocationJournalCurrent = $null
        relocationJournalWrite = $null
        relocationJournalWriteSha256 = $null
        legacyPreviousRelocationPending = $false
    }

    if (Test-Path -LiteralPath $slotStateRoot) {
        if (-not (Test-Path -LiteralPath $slotStateRoot -PathType Container)) {
            throw "Updater slot state root is not a directory: $slotStateRoot"
        }
        Assert-CpaStackInstallAcl -Path $slotStateRoot -PathType Container -RequireProtected
        $unexpectedState = @(Get-ChildItem -LiteralPath $slotStateRoot -Force -ErrorAction Stop | Where-Object { $_.Name -cne 'skill-slots' })
        if ($unexpectedState.Count -gt 0) {
            throw "Updater slot state contains a foreign or orphan sibling; no managed write was performed: $($unexpectedState.FullName -join ', ')"
        }
    }
    if (-not (Test-Path -LiteralPath $slotRoot)) {
        $state.legacyPreviousRelocationPending = Test-Path -LiteralPath $legacyPrevious
        return [pscustomobject]$state
    }
    if (-not (Test-Path -LiteralPath $slotRoot -PathType Container)) {
        throw "Updater skill slot root is not a directory: $slotRoot"
    }
    Assert-CpaStackInstallAcl -Path $slotRoot -PathType Container -RequireProtected

    $state.installJournalCurrent = Read-SkillInstallJournal -Optional
    $state.installJournalWrite = Read-SkillInstallJournal -Optional -Path $installJournalWrite
    if ($null -ne $state.installJournalCurrent -and $null -ne $state.installJournalWrite) {
        Assert-SkillInstallJournalWritePair -Current $state.installJournalCurrent -Write $state.installJournalWrite
    }
    $state.installJournal = if ($null -ne $state.installJournalCurrent) { $state.installJournalCurrent } else { $state.installJournalWrite }
    if ($null -ne $state.installJournalWrite) {
        $state.installJournalWriteSha256 = Get-CpaStackFileHash -Path $installJournalWrite
    }

    $state.relocationJournalCurrent = Read-LegacyPreviousRelocationJournal -Optional
    $state.relocationJournalWrite = Read-LegacyPreviousRelocationJournal -Optional -Path $relocationJournalWrite
    if ($null -ne $state.relocationJournalCurrent -and $null -ne $state.relocationJournalWrite) {
        Assert-LegacyRelocationJournalWritePair -Current $state.relocationJournalCurrent -Write $state.relocationJournalWrite
    }
    $state.relocationJournal = if ($null -ne $state.relocationJournalCurrent) { $state.relocationJournalCurrent } else { $state.relocationJournalWrite }
    if ($null -ne $state.relocationJournalWrite) {
        $state.relocationJournalWriteSha256 = Get-CpaStackFileHash -Path $relocationJournalWrite
    }

    if ($null -ne $state.installJournal -and ($null -ne $state.relocationJournal -or (Test-Path -LiteralPath $legacyPrevious))) {
        throw 'Install and legacy previous relocation transactions overlap; no recovery write was performed.'
    }

    $allowed = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($previous, $installJournal, $installJournalWrite, $relocationJournal, $relocationJournalWrite)) {
        $allowed[[System.IO.Path]::GetFullPath($path)] = $true
    }
    if ($null -ne $state.installJournal) {
        foreach ($kind in @('Staging', 'Retained', 'Retiring')) {
            $artifact = Get-JournalTransactionPath -Journal $state.installJournal -Kind $kind
            $claim = Get-SkillTransactionClaimPath -Kind $kind -ExpectedTransactionId ([string]$state.installJournal.transactionId)
            $allowed[[System.IO.Path]::GetFullPath($artifact)] = $true
            $allowed[[System.IO.Path]::GetFullPath($claim)] = $true
        }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $slotRoot -Force -ErrorAction Stop)) {
        if (-not $allowed.ContainsKey([System.IO.Path]::GetFullPath($item.FullName))) {
            throw "Updater skill slot root contains a foreign or orphan sibling; no managed write was performed: $($item.FullName)"
        }
    }

    if (Test-Path -LiteralPath $previous) {
        if (-not (Test-Path -LiteralPath $previous -PathType Container)) {
            throw "Previous-skill slot is not a directory: $previous"
        }
        [void](Assert-SkillSlotPath -Path $previous -Kind Previous)
        if ($null -eq $state.installJournal -and -not (Test-OwnedSkillDirectory -Root $previous)) {
            throw "Previous-skill slot is not safely installer-owned: $previous"
        }
    }

    $state.legacyPreviousRelocationPending = $null -ne $state.relocationJournal -or (Test-Path -LiteralPath $legacyPrevious)
    return [pscustomobject]$state
}

function Promote-StandaloneSkillJournalWriteResidues {
    param([Parameter(Mandatory = $true)]$State)

    if ($null -ne $State.installJournalWrite -and $null -eq $State.installJournalCurrent) {
        $journal = $State.installJournalWrite
        if ([string]$journal.phase -cne 'Prepared') {
            throw 'A standalone skill install journal write artifact is not in the Prepared phase.'
        }
        $journalStaging = Get-JournalTransactionPath -Journal $journal -Kind Staging
        [void](Assert-JournalTargetArtifact -Journal $journal -Root $journalStaging)
        [void](Assert-SkillTransactionClaim -Root $journalStaging -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.target)
        if ([bool]$journal.hadInstalled) {
            [void](Assert-SkillSlotMatchesDescriptor -Root $installed -Descriptor $journal.originalInstalled)
        } elseif (Test-Path -LiteralPath $installed) {
            throw 'Standalone first-install journal write artifact unexpectedly has an installed slot.'
        }
        if ([bool]$journal.hadPrevious) {
            [void](Assert-SkillSlotMatchesDescriptor -Root $previous -Descriptor $journal.originalPrevious)
        } elseif (Test-Path -LiteralPath $previous) {
            throw 'Standalone install journal write artifact unexpectedly has a previous slot.'
        }
        if ((Get-CpaStackFileHash -Path $installJournalWrite) -cne [string]$State.installJournalWriteSha256) {
            throw 'Skill install journal write artifact changed after validation.'
        }
        [System.IO.File]::Move($installJournalWrite, $installJournal)
        Protect-CpaStackSecretFile -Path $installJournal
        [void](Read-SkillInstallJournal)
    }

    if ($null -ne $State.relocationJournalWrite -and $null -eq $State.relocationJournalCurrent) {
        $journal = $State.relocationJournalWrite
        if ([string]$journal.phase -cne 'Prepared') {
            throw 'A standalone legacy relocation journal write artifact is not in the Prepared phase.'
        }
        if (-not (Test-Path -LiteralPath $legacyPrevious -PathType Container) -or (Test-Path -LiteralPath $previous)) {
            throw 'Standalone legacy relocation journal write artifact does not match the prepared slot state.'
        }
        [void](Assert-SkillSlotMatchesDescriptor -Root $legacyPrevious -Descriptor $journal.descriptor)
        if ((Get-CpaStackFileHash -Path $relocationJournalWrite) -cne [string]$State.relocationJournalWriteSha256) {
            throw 'Legacy relocation journal write artifact changed after validation.'
        }
        [System.IO.File]::Move($relocationJournalWrite, $relocationJournal)
        Protect-CpaStackSecretFile -Path $relocationJournal
        [void](Read-LegacyPreviousRelocationJournal)
    }
}

function Remove-ValidatedSkillJournalWriteResidues {
    param([Parameter(Mandatory = $true)]$State)

    foreach ($entry in @(
        [pscustomobject]@{ Path = $installJournalWrite; Sha256 = $State.installJournalWriteSha256 },
        [pscustomobject]@{ Path = $relocationJournalWrite; Sha256 = $State.relocationJournalWriteSha256 }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$entry.Sha256) -or -not (Test-Path -LiteralPath $entry.Path)) { continue }
        if ((Get-CpaStackFileHash -Path $entry.Path) -cne [string]$entry.Sha256) {
            throw "Journal write artifact changed after validation: $($entry.Path)"
        }
        Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
    }
}

function Remove-ValidatedLegacyRelocationWriteBeforeRecovery {
    param([Parameter(Mandatory = $true)]$State)

    if ($null -eq $State.relocationJournalCurrent -or $null -eq $State.relocationJournalWrite) { return }
    $sourceExists = Test-Path -LiteralPath $legacyPrevious -PathType Container
    $targetExists = Test-Path -LiteralPath $previous -PathType Container
    if ($sourceExists -eq $targetExists) {
        throw 'Legacy relocation journal write cleanup found an ambiguous slot state.'
    }
    $boundRoot = if ($sourceExists) { $legacyPrevious } else { $previous }
    [void](Assert-SkillSlotMatchesDescriptor -Root $boundRoot -Descriptor $State.relocationJournalCurrent.descriptor)
    if ((Get-CpaStackFileHash -Path $relocationJournalWrite) -cne [string]$State.relocationJournalWriteSha256) {
        throw 'Legacy relocation journal write artifact changed after validation.'
    }
    Remove-Item -LiteralPath $relocationJournalWrite -Force -ErrorAction Stop
}

function Remove-SkillInstallJournal {
    if (-not (Test-Path -LiteralPath $installJournal)) { return }
    [void](Read-SkillInstallJournal)
    Remove-Item -LiteralPath $installJournal -Force -ErrorAction Stop
}

function Get-JournalTransactionPath {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind
    )

    return Get-JournalTransactionPathFromId -TransactionId ([string]$Journal.transactionId) -Kind $Kind
}

function Get-JournalTransactionPathFromId {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$TransactionId,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind
    )

    $suffix = $Kind.ToLowerInvariant()
    $path = Join-Path $slotRoot ($suffix + '-' + $TransactionId)
    return Assert-SkillSlotPath -Path $path -Kind $Kind
}

function Restore-JournalSkillOwnership {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Previous', 'Retiring')][string]$Kind
    )

    $descriptor = $Journal.originalInstalled
    $allowedMarker = Get-JournalLegacyMarkerValidationHash -Journal $Journal -Root $Root
    [void](Assert-SkillSlotMatchesDescriptor -Root $Root -Descriptor $descriptor -AllowedLegacyMarkerSha256 $allowedMarker)
    if ([bool]$Journal.installedOwnedBeforeTransaction) {
        return
    }
    if (-not [bool]$Journal.installedWasLegacy) {
        throw 'Skill install journal has no recoverable preexisting ownership state.'
    }
    if ([string]::IsNullOrWhiteSpace($allowedMarker)) { Assert-LegacySkillDirectory -Root $Root }
}

function Get-JournalLegacyMarkerValidationHash {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if (-not [bool]$Journal.installedWasLegacy) { return $null }
    $markerPath = Get-InstallMarkerPath -Root $Root
    $actualHash = Get-CpaStackFileHash -Path $markerPath
    if ([string]::IsNullOrWhiteSpace($actualHash)) {
        if ([bool]$Journal.legacyMarkerAdded) {
            throw "Journal-bound transactional legacy marker is missing: $markerPath"
        }
        return $null
    }
    if ([bool]$Journal.legacyMarkerAdded) {
        if ($actualHash -cne [string]$Journal.legacyMarkerSha256) {
            throw "Journal-bound transactional legacy marker hash changed: $markerPath"
        }
        return $actualHash
    }
    if (-not [bool]$Journal.legacyMarkerPending) {
        throw "Legacy artifact contains a marker not declared by the pending journal: $markerPath"
    }
    $marker = Read-CpaStackJson -Path $markerPath
    if ([string]$marker.transactionId -cne [string]$Journal.transactionId -or
        [string]$marker.updaterVersion -cne [string]$Journal.sourceVersion) {
        throw "Pending transactional legacy marker is foreign to the journal: $markerPath"
    }
    return $actualHash
}

function Assert-JournalTargetArtifact {
    param(
        [Parameter(Mandatory = $true)]$Journal,
        [Parameter(Mandatory = $true)][string]$Root
    )

    [void](Assert-SkillSlotMatchesDescriptor -Root $Root -Descriptor $Journal.target)
    $marker = Read-CpaStackJson -Path (Get-InstallMarkerPath -Root $Root)
    if ([string]$marker.transactionId -cne [string]$Journal.transactionId -or
        [string]$marker.updaterVersion -cne [string]$Journal.sourceVersion) {
        throw "Target skill ownership marker is foreign to the pending journal: $Root"
    }
}

function Assert-NoForeignSkillTransactionArtifacts {
    param([Parameter(Mandatory = $true)]$Journal)

    $allowedClaims = @{}
    foreach ($kind in @('Staging', 'Retained', 'Retiring')) {
        $expected = Get-JournalTransactionPath -Journal $Journal -Kind $kind
        $allowedClaims[(Get-SkillTransactionClaimPath -Kind $kind -ExpectedTransactionId ([string]$Journal.transactionId))] = $true
        foreach ($path in @(Get-SkillTransactionDirectories -Kind $kind)) {
            if (-not (Test-CanonicalPathEqual -Left $path -Right $expected)) {
                throw "A foreign $kind skill transaction artifact is present; no recovery write was performed: $path"
            }
        }
    }
    if (Test-Path -LiteralPath $slotRoot -PathType Container) {
        foreach ($claim in @(Get-ChildItem -LiteralPath $slotRoot -Force -File -ErrorAction Stop | Where-Object {
            $_.Name -cmatch '^(?:staging|retained|retiring)-[0-9a-f]{32}\.claim\.json$'
        })) {
            if (-not $allowedClaims.ContainsKey($claim.FullName)) {
                throw "A foreign skill transaction sidecar is present; no recovery write was performed: $($claim.FullName)"
            }
        }
    }
}

function Recover-SkillInstallJournal {
    param([switch]$FinalizeCommitted)

    $journal = Read-SkillInstallJournal -Optional
    if ($null -eq $journal) { return [pscustomobject]@{ recovered = $false; committed = $false } }

    $journalStaging = Get-JournalTransactionPath -Journal $journal -Kind Staging
    $journalRetained = Get-JournalTransactionPath -Journal $journal -Kind Retained
    $journalRetiring = Get-JournalTransactionPath -Journal $journal -Kind Retiring
    $journalStagingClaim = Get-SkillTransactionClaimPath -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId)
    $journalRetainedClaim = Get-SkillTransactionClaimPath -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId)
    $journalRetiringClaim = Get-SkillTransactionClaimPath -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId)
    $stagingExists = Test-Path -LiteralPath $journalStaging -PathType Container
    $installedExists = Test-Path -LiteralPath $installed -PathType Container
    $committed = ([string]$journal.phase -ceq 'Committed') -or
        ([string]$journal.phase -ceq 'Committing' -and $installedExists -and -not $stagingExists)

    [void](Assert-NoForeignSkillTransactionArtifacts -Journal $journal)
    if (Test-Path -LiteralPath $journalStaging) {
        [void](Assert-JournalTargetArtifact -Journal $journal -Root $journalStaging)
        [void](Assert-SkillTransactionClaim -Root $journalStaging -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.target)
    } elseif (Test-Path -LiteralPath $journalStagingClaim -PathType Leaf) {
        [void](Assert-SkillTransactionClaimDocument -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.target)
    }
    if (Test-Path -LiteralPath $journalRetained) {
        if ($null -eq $journal.originalPrevious) {
            throw 'Skill install journal has a retained artifact without an original previous descriptor.'
        }
        [void](Assert-SkillTransactionClaim -Root $journalRetained -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalPrevious)
    } elseif (Test-Path -LiteralPath $journalRetainedClaim -PathType Leaf) {
        if ($null -eq $journal.originalPrevious) {
            throw 'Skill install journal has a retained claim without an original previous descriptor.'
        }
        [void](Assert-SkillTransactionClaimDocument -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalPrevious)
    }
    if (Test-Path -LiteralPath $journalRetiring) {
        if ($null -eq $journal.originalInstalled) {
            throw 'Skill install journal has a retiring artifact without an original installed descriptor.'
        }
        [void](Assert-SkillTransactionClaim -Root $journalRetiring -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalInstalled)
    }

    if ($committed) {
        if (-not $installedExists) { throw 'Committed skill install journal does not have an installed target slot.' }
        [void](Assert-JournalTargetArtifact -Journal $journal -Root $installed)
        $installedClaim = $journalStagingClaim
        if (Test-Path -LiteralPath $installedClaim) {
            [void](Assert-SkillTransactionClaim -Root $installed -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.target)
        }
        if (Test-Path -LiteralPath $journalRetiring) {
            throw 'Committed skill install journal unexpectedly retains an active retiring slot.'
        }
        if (Test-Path -LiteralPath $journalStaging) {
            throw 'Committed skill install journal unexpectedly retains a staging slot.'
        }
        if ([bool]$journal.hadInstalled) {
            if (-not (Test-Path -LiteralPath $previous -PathType Container)) {
                throw 'Committed skill install journal cannot locate the retired original installed slot.'
            }
            $previousLegacyMarkerHash = Get-JournalLegacyMarkerValidationHash -Journal $journal -Root $previous
            [void](Assert-SkillSlotMatchesDescriptor `
                -Root $previous -Descriptor $journal.originalInstalled `
                -AllowedLegacyMarkerSha256 $previousLegacyMarkerHash)
            $previousClaim = $journalRetiringClaim
            if (Test-Path -LiteralPath $previousClaim) {
                [void](Assert-SkillTransactionClaim `
                    -Root $previous -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) `
                    -Descriptor $journal.originalInstalled `
                    -AllowedLegacyMarkerSha256 $previousLegacyMarkerHash)
            }
        }
        if (-not $FinalizeCommitted) {
            return [pscustomobject]@{ recovered = $true; committed = $true; journal = $journal }
        }
        if (-not [bool]$journal.postCommit.rootReady -or
            -not [bool]$journal.postCommit.launcherVerified -or
            -not [bool]$journal.postCommit.registrationVerified) {
            throw 'Committed skill install journal still has unverified post-commit work.'
        }
        if (Test-Path -LiteralPath $installedClaim) {
            Remove-SkillTransactionClaim -Root $installed -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.target
        }
        if ([bool]$journal.hadInstalled -and (Test-Path -LiteralPath $journalRetiringClaim)) {
            Remove-SkillTransactionClaim `
                -Root $previous -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) `
                -Descriptor $journal.originalInstalled `
                -AllowedLegacyMarkerSha256 $previousLegacyMarkerHash
        }
        if (Test-Path -LiteralPath $journalRetained) {
            Remove-ClaimedSkillTransactionDirectory `
                -Path $journalRetained -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) `
                -Descriptor $journal.originalPrevious
        } elseif (Test-Path -LiteralPath $journalRetainedClaim -PathType Leaf) {
            [void](Assert-SkillTransactionClaimDocument -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalPrevious)
            Remove-Item -LiteralPath $journalRetainedClaim -Force -ErrorAction Stop
        }
        Remove-SkillInstallJournal
        return [pscustomobject]@{ recovered = $true; committed = $true; journal = $journal }
    }

    if ([bool]$journal.hadInstalled) {
        if ($installedExists) {
            if (Test-Path -LiteralPath $journalRetiring) {
                throw 'Skill install recovery found both installed and retiring active slots.'
            }
            Restore-JournalSkillOwnership -Journal $journal -Root $installed -Kind Installed
            if (Test-Path -LiteralPath $journalRetiringClaim) {
                [void](Assert-SkillTransactionClaim -Root $installed -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalInstalled)
            }
        } elseif (Test-Path -LiteralPath $journalRetiring -PathType Container) {
            Restore-JournalSkillOwnership -Journal $journal -Root $journalRetiring -Kind Retiring
        } elseif ((Test-Path -LiteralPath $previous -PathType Container) -and
            [string]$journal.phase -in @('MovingActiveToPrevious', 'Committing')) {
            Restore-JournalSkillOwnership -Journal $journal -Root $previous -Kind Previous
            $previousLegacyMarkerHash = Get-JournalLegacyMarkerValidationHash -Journal $journal -Root $previous
            if (Test-Path -LiteralPath $journalRetiringClaim) {
                [void](Assert-SkillTransactionClaim `
                    -Root $previous -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) `
                    -Descriptor $journal.originalInstalled `
                    -AllowedLegacyMarkerSha256 $previousLegacyMarkerHash)
            }
        } else {
            throw 'Skill install journal cannot locate the crash-time active skill.'
        }
    } elseif (Test-Path -LiteralPath $installed) {
        throw 'First-install journal unexpectedly has an installed slot before commit.'
    }

    if ([bool]$journal.hadPrevious) {
        if (Test-Path -LiteralPath $journalRetained -PathType Container) {
            $previousWillReturnToInstalled = [bool]$journal.hadInstalled -and
                -not $installedExists -and
                -not (Test-Path -LiteralPath $journalRetiring) -and
                [string]$journal.phase -in @('MovingActiveToPrevious', 'Committing')
            if ((Test-Path -LiteralPath $previous) -and -not $previousWillReturnToInstalled) {
                throw 'Skill install recovery cannot restore retained previous into an occupied slot.'
            }
        } elseif (-not (Test-Path -LiteralPath $previous -PathType Container)) {
            throw 'Skill install journal cannot locate the previous rollback skill.'
        } elseif ((Test-Path -LiteralPath $previous -PathType Container) -and [string]$journal.phase -in @('Prepared', 'RetiringInstalled', 'RetainingPrevious')) {
            [void](Assert-SkillSlotMatchesDescriptor -Root $previous -Descriptor $journal.originalPrevious)
            if (Test-Path -LiteralPath $journalRetainedClaim) {
                [void](Assert-SkillTransactionClaim -Root $previous -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalPrevious)
            }
        }
    } elseif (Test-Path -LiteralPath $journalRetained) {
        throw 'Skill install journal unexpectedly has a retained previous slot.'
    }

    if ([bool]$journal.hadInstalled) {
        if ($installedExists) {
            if (Test-Path -LiteralPath $journalRetiringClaim) {
                Remove-SkillTransactionClaim -Root $installed -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalInstalled
            }
        } elseif (Test-Path -LiteralPath $journalRetiring -PathType Container) {
            Move-SkillDirectoryWithRetry -SourcePath $journalRetiring -SourceKind Retiring -DestinationPath $installed -DestinationKind Installed
            Remove-SkillTransactionClaim -Root $installed -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalInstalled
        } else {
            $previousLegacyMarkerHash = Get-JournalLegacyMarkerValidationHash -Journal $journal -Root $previous
            if (Test-Path -LiteralPath $journalRetiringClaim) {
                Remove-SkillTransactionClaim `
                    -Root $previous -Kind Retiring -ExpectedTransactionId ([string]$journal.transactionId) `
                    -Descriptor $journal.originalInstalled `
                    -AllowedLegacyMarkerSha256 $previousLegacyMarkerHash
            }
            if (-not [string]::IsNullOrWhiteSpace($previousLegacyMarkerHash)) {
                Remove-TransactionalLegacyMarker `
                    -Root $previous -Kind Previous -ExpectedTransactionId ([string]$journal.transactionId) `
                    -ExpectedHash $previousLegacyMarkerHash
            }
            Move-SkillDirectoryWithRetry -SourcePath $previous -SourceKind Previous -DestinationPath $installed -DestinationKind Installed
        }
    }

    if ([bool]$journal.hadPrevious -and (Test-Path -LiteralPath $journalRetained -PathType Container)) {
        Move-SkillDirectoryWithRetry -SourcePath $journalRetained -SourceKind Retained -DestinationPath $previous -DestinationKind Previous
        Remove-SkillTransactionClaim -Root $previous -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalPrevious
    } elseif ([bool]$journal.hadPrevious -and (Test-Path -LiteralPath $journalRetainedClaim)) {
        Remove-SkillTransactionClaim -Root $previous -Kind Retained -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.originalPrevious
    }

    if (Test-Path -LiteralPath $journalStaging) {
        Remove-ClaimedSkillTransactionDirectory `
            -Path $journalStaging -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) `
            -Descriptor $journal.target
    } elseif (Test-Path -LiteralPath $journalStagingClaim -PathType Leaf) {
        [void](Assert-SkillTransactionClaimDocument -Kind Staging -ExpectedTransactionId ([string]$journal.transactionId) -Descriptor $journal.target)
        Remove-Item -LiteralPath $journalStagingClaim -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $journalRetiring) {
        throw 'Skill install recovery left a retiring slot behind.'
    }
    Remove-SkillInstallJournal
    return [pscustomobject]@{ recovered = $true; committed = $false; journal = $journal }
}

function Get-ProtectedRegisteredRoot {
    $locatorPath = Get-CpaStackRootLocatorPath
    if (-not (Test-Path -LiteralPath $locatorPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $locatorPath) {
            throw "CPA stack root locator is not a regular file: $locatorPath"
        }
        return $null
    }

    $locatorFull = [System.IO.Path]::GetFullPath($locatorPath)
    $localAppData = [System.IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')
    if (-not $locatorFull.StartsWith($localAppData + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "CPA stack root locator is outside LocalAppData: $locatorPath"
    }

    $cursor = $locatorFull
    while ($true) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "CPA stack root locator must not cross a reparse point: $cursor"
            }
        }
        if ([string]::Equals($cursor.TrimEnd('\'), $localAppData, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $cursor, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "CPA stack root locator path could not be validated: $locatorPath"
        }
        $cursor = $parent
    }

    $acl = Get-CpaStackFileSystemAcl -Path $locatorFull
    if (-not $acl.AreAccessRulesProtected) {
        throw "CPA stack root locator ACL is not protected: $locatorPath"
    }

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $ownerSid = Get-CpaStackAclOwnerSid -Acl $acl
    } catch {
        throw "CPA stack root locator owner could not be verified: $locatorPath"
    }
    if ($ownerSid -ne $currentSid) {
        throw "CPA stack root locator is not owned by the current Windows user: $locatorPath"
    }

    $allowedSids = @{}
    foreach ($identity in Get-CpaStackPrivateIdentities) {
        $allowedSids[$identity.Value] = $true
    }
    foreach ($rule in Get-CpaStackAclAccessRules -Acl $acl) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            throw "CPA stack root locator contains an unresolvable allow principal: $locatorPath"
        }
        if (-not $allowedSids.ContainsKey($sid)) {
            throw "CPA stack root locator grants access to an unexpected identity: $sid"
        }
    }

    try {
        $locator = Read-CpaStackJson -Path $locatorFull
        if ($null -eq $locator -or $locator -is [array]) {
            throw 'Unexpected locator document type.'
        }
        $schemaProperty = $locator.PSObject.Properties['schemaVersion']
        $rootProperty = $locator.PSObject.Properties['root']
        if ($null -eq $schemaProperty -or [int]$schemaProperty.Value -ne 1 -or
            $null -eq $rootProperty -or $rootProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$rootProperty.Value)) {
            throw 'Unexpected locator schema.'
        }
        $recordedRoot = [string]$rootProperty.Value
    } catch {
        throw "CPA stack root locator is invalid and will not be trusted: $locatorPath"
    }

    try {
        return Assert-CpaStackSecureLocalRoot -Path $recordedRoot
    } catch {
        throw "Registered CPA stack root failed safety validation: $($_.Exception.Message)"
    }
}

function Assert-CpaStackInstallAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Leaf', 'Container')][string]$PathType,
        [switch]$RequireProtected
    )

    Assert-CpaStackPath -Path $Path -PathType $PathType
    $item = Get-Item -Force -LiteralPath $Path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Canonical install path must not be a reparse point: $Path"
    }

    $acl = Get-CpaStackFileSystemAcl -Path $Path
    if ($RequireProtected -and -not $acl.AreAccessRulesProtected) {
        throw "Canonical stack root ACL inheritance is not protected: $Path"
    }

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $ownerSid = Get-CpaStackAclOwnerSid -Acl $acl
    } catch {
        throw "Canonical install path owner could not be verified: $Path"
    }
    if ($ownerSid -ne $currentSid) {
        throw "Canonical install path is not owned by the current Windows user: $Path"
    }

    $allowedSids = @{}
    foreach ($identity in Get-CpaStackPrivateIdentities) {
        $allowedSids[$identity.Value] = $true
    }
    foreach ($rule in Get-CpaStackAclAccessRules -Acl $acl) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }
        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            throw "Canonical install path contains an unresolvable allow principal: $Path"
        }
        if (-not $allowedSids.ContainsKey($sid)) {
            throw "Canonical install path grants access to an unexpected identity: $Path ($sid)"
        }
    }
}

function Get-InstallerLauncherWriteArtifactPath {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    return (Join-Path ([System.IO.Path]::GetFullPath($ControlRoot).TrimEnd('\')) ('ops\Start-CPA-Stack.ps1' + $launcherWriteSuffix))
}

function Get-InstallerLauncherWriteArtifact {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $ops = Join-Path ([System.IO.Path]::GetFullPath($ControlRoot).TrimEnd('\')) 'ops'
    if (-not (Test-Path -LiteralPath $ops -PathType Container)) { return $null }
    $artifactPath = Get-InstallerLauncherWriteArtifactPath -ControlRoot $ControlRoot
    foreach ($item in @(Get-ChildItem -LiteralPath $ops -Force -ErrorAction Stop | Where-Object {
        $_.Name -cne 'Start-CPA-Stack.ps1' -and $_.Name -cmatch '^Start-CPA-Stack\.ps1\.'
    })) {
        if (-not [string]::Equals($item.FullName, $artifactPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Canonical launcher directory contains a foreign or orphan launcher artifact; no managed write was performed: $($item.FullName)"
        }
    }
    if (-not (Test-Path -LiteralPath $artifactPath)) { return $null }
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Canonical launcher write artifact is not a regular file: $artifactPath"
    }
    Assert-CpaStackInstallAcl -Path $artifactPath -PathType Leaf
    $expectedHash = Get-ByteArraySha256 -Bytes (Get-RenderedLauncherBootstrap)
    $actualHash = Get-CpaStackFileHash -Path $artifactPath
    if ($actualHash -cne $expectedHash) {
        throw "Canonical launcher write artifact is foreign to the current CodexHome intent: $artifactPath"
    }
    return [pscustomobject]@{
        path = $artifactPath
        sha256 = $actualHash
    }
}

function New-InstallerPreinitializedRoot {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    if (Test-Path -LiteralPath $root) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Requested CPA stack root is not a directory: $root"
        }
        Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
        $unexpected = @(Get-ChildItem -Force -LiteralPath $root -ErrorAction Stop)
        if ($unexpected.Count -gt 0) {
            throw "Refusing to pre-initialize a non-empty CPA stack root: $root"
        }
    } else {
        New-Item -ItemType Directory -Path $root | Out-Null
        Protect-CpaStackPrivateDirectory -Path $root
        Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
    }

    $bootstrapHash = Get-ByteArraySha256 -Bytes (Get-RenderedLauncherBootstrap)
    $markerPath = Join-Path $root '.cpa-stack-instance.json'
    $marker = [ordered]@{
        schemaVersion = 1
        instanceId = [guid]::NewGuid().ToString('N')
        root = $root
        createdAt = [DateTimeOffset]::Now.ToString('o')
        preinitializedBy = 'cpa-stack-updater'
        preinitializedSchemaVersion = 1
        launcherExpectedSha256 = $bootstrapHash
    }
    Write-CpaStackJson -Value $marker -Path $markerPath
    Protect-CpaStackSecretFile -Path $markerPath
    [void](Ensure-CpaStackInstanceMarker -ControlRoot $root)
    return [pscustomobject]$marker
}

function Assert-InstallerPreinitializedRoot {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
    $markerPath = Join-Path $root '.cpa-stack-instance.json'
    Assert-CpaStackInstallAcl -Path $markerPath -PathType Leaf
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $root
    if ([string]$marker.preinitializedBy -cne 'cpa-stack-updater' -or
        [int]$marker.preinitializedSchemaVersion -ne 1 -or
        [string]$marker.launcherExpectedSha256 -notmatch '^[0-9A-F]{64}$') {
        throw "CPA stack root is not an installer-owned pre-initialized root: $root"
    }

    $ops = Join-Path $root 'ops'
    if (Test-Path -LiteralPath $ops) {
        Assert-CpaStackInstallAcl -Path $ops -PathType Container -RequireProtected
        [void](Get-InstallerLauncherWriteArtifact -ControlRoot $root)
        $allowedLauncherWriteName = [System.IO.Path]::GetFileName((Get-InstallerLauncherWriteArtifactPath -ControlRoot $root))
        $unexpectedOpsItems = @(Get-ChildItem -Force -LiteralPath $ops -ErrorAction Stop | Where-Object {
            $_.Name -cne 'Start-CPA-Stack.ps1' -and $_.Name -cne $allowedLauncherWriteName
        })
        if ($unexpectedOpsItems.Count -gt 0) {
            throw "Installer pre-initialized ops directory contains unexpected content: $ops"
        }
        $launcherPath = Join-Path $ops 'Start-CPA-Stack.ps1'
        if (Test-Path -LiteralPath $launcherPath) {
            Assert-CpaStackInstallAcl -Path $launcherPath -PathType Leaf
        }
    }
    $allowedRootItems = @('.cpa-stack-instance.json', 'ops')
    $unexpectedRootItems = @(Get-ChildItem -Force -LiteralPath $root -ErrorAction Stop | Where-Object { $_.Name -notin $allowedRootItems })
    if ($unexpectedRootItems.Count -gt 0) {
        throw "Installer pre-initialized root contains unexpected content: $root"
    }
    return $marker
}

function Get-LauncherAssessment {
    param(
        [string]$ControlRoot,
        [bool]$Managed
    )

    $bootstrapBytes = Get-RenderedLauncherBootstrap
    $expectedHash = Get-ByteArraySha256 -Bytes $bootstrapBytes
    $launcherWriteArtifact = $null
    if (-not $Managed -or [string]::IsNullOrWhiteSpace($ControlRoot)) {
        return [pscustomobject]@{
            state = 'NotConfigured'
            path = $null
            expectedSha256 = $expectedHash
            actualSha256 = $null
        }
    }

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    if (Test-Path -LiteralPath $root) {
        Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
        $ops = Join-Path $root 'ops'
        if (Test-Path -LiteralPath $ops) {
            Assert-CpaStackInstallAcl -Path $ops -PathType Container -RequireProtected
            $launcherWriteArtifact = Get-InstallerLauncherWriteArtifact -ControlRoot $root
        }
    }
    if ($null -eq $launcherWriteArtifact) {
        $launcherWriteArtifact = Get-InstallerLauncherWriteArtifact -ControlRoot $root
    }
    $path = Join-Path $root 'ops\Start-CPA-Stack.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            state = if ($null -ne $launcherWriteArtifact) { 'RecoveryPending' } else { 'Missing' }
            path = $path
            expectedSha256 = $expectedHash
            actualSha256 = $null
        }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            state = 'Drifted'
            path = $path
            expectedSha256 = $expectedHash
            actualSha256 = $null
        }
    }
    $item = Get-Item -Force -LiteralPath $path
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{
            state = 'Drifted'
            path = $path
            expectedSha256 = $expectedHash
            actualSha256 = $null
        }
    }

    $actualHash = Get-CpaStackFileHash -Path $path
    return [pscustomobject]@{
        state = if ($null -ne $launcherWriteArtifact) { 'RecoveryPending' } elseif ($actualHash -ceq $expectedHash) { 'Current' } else { 'Drifted' }
        path = $path
        expectedSha256 = $expectedHash
        actualSha256 = $actualHash
    }
}

function Sync-InstallerLauncherBootstrap {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    $rootCreated = -not (Test-Path -LiteralPath $root)
    if ($rootCreated) {
        New-Item -ItemType Directory -Path $root | Out-Null
        Protect-CpaStackPrivateDirectory -Path $root
    } else {
        Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
    }

    $ops = Join-Path $root 'ops'
    if (-not (Test-Path -LiteralPath $ops)) {
        New-Item -ItemType Directory -Path $ops | Out-Null
        Protect-CpaStackPrivateDirectory -Path $ops
    } else {
        Assert-CpaStackInstallAcl -Path $ops -PathType Container -RequireProtected
    }

    $sourceItem = Get-Item -Force -LiteralPath $bootstrapSource
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The launcher bootstrap source must not be a reparse point.'
    }
    $destination = Join-Path $ops 'Start-CPA-Stack.ps1'
    if ((Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw "Launcher bootstrap path is not a regular file: $destination"
    }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Assert-CpaStackInstallAcl -Path $destination -PathType Leaf
    }

    $bootstrapBytes = Get-RenderedLauncherBootstrap
    $expectedHash = Get-ByteArraySha256 -Bytes $bootstrapBytes
    $actualHash = Get-CpaStackFileHash -Path $destination
    $writeArtifact = Get-InstallerLauncherWriteArtifact -ControlRoot $root
    if ($actualHash -ceq $expectedHash) {
        if ($null -ne $writeArtifact) {
            if ((Get-CpaStackFileHash -Path ([string]$writeArtifact.path)) -cne $expectedHash) {
                throw 'Launcher bootstrap write artifact changed after validation.'
            }
            Remove-Item -LiteralPath ([string]$writeArtifact.path) -Force -ErrorAction Stop
        }
        return [pscustomobject]@{ changed = ($null -ne $writeArtifact); path = $destination; sha256 = $expectedHash }
    }

    if ($null -eq $writeArtifact) {
        $temporary = Get-InstallerLauncherWriteArtifactPath -ControlRoot $root
        if (Test-Path -LiteralPath $temporary) {
            throw "Canonical launcher write artifact is unresolved: $temporary"
        }
        [System.IO.File]::WriteAllBytes($temporary, $bootstrapBytes)
        Protect-CpaStackSecretFile -Path $temporary
        if ((Get-CpaStackFileHash -Path $temporary) -cne $expectedHash) {
            throw 'Launcher bootstrap staging hash mismatch.'
        }
        $writeArtifact = Get-InstallerLauncherWriteArtifact -ControlRoot $root
    }
    $temporary = [string]$writeArtifact.path
    if ((Get-CpaStackFileHash -Path $temporary) -cne $expectedHash) {
        throw 'Launcher bootstrap write artifact changed after validation.'
    }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Protect-CpaStackSecretFile -Path $destination
        Invoke-AtomicFileReplaceNoBackup -ReplacementPath $temporary -DestinationPath $destination
    } else {
        [System.IO.File]::Move($temporary, $destination)
    }
    Protect-CpaStackSecretFile -Path $destination
    if ((Get-CpaStackFileHash -Path $destination) -cne $expectedHash) {
        throw 'Launcher bootstrap synchronization failed verification.'
    }
    return [pscustomobject]@{ changed = $true; path = $destination; sha256 = $expectedHash; previousSha256 = $actualHash }
}

function Write-InstallPublicResult {
    param([Parameter(Mandatory = $true)]$Value)

    $Value | ConvertTo-Json -Depth 6
}

function Assert-AdoptedCanonicalInstallRoot {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    $opsPath = Join-Path $root 'ops'
    $statePath = Join-Path $root 'state'
    $markerPath = Join-Path $root '.cpa-stack-instance.json'
    $currentPath = Join-Path $statePath 'current.json'
    $launcherPath = Join-Path $opsPath 'Start-CPA-Stack.ps1'

    Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
    Assert-CpaStackInstallAcl -Path $opsPath -PathType Container
    Assert-CpaStackInstallAcl -Path $statePath -PathType Container
    Assert-CpaStackInstallAcl -Path $markerPath -PathType Leaf
    Assert-CpaStackInstallAcl -Path $currentPath -PathType Leaf
    if (Test-Path -LiteralPath $launcherPath) {
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            throw "Canonical launcher path is not a regular file: $launcherPath"
        }
        Assert-CpaStackInstallAcl -Path $launcherPath -PathType Leaf
    }

    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $root
    $current = Read-CpaStackJson -Path $currentPath
    if ([string]$current.instanceId -ne [string]$marker.instanceId) {
        throw 'Canonical marker and current state instance ids do not match.'
    }
    try {
        $currentRoot = [System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\')
    } catch {
        throw 'Canonical current state contains an invalid root path.'
    }
    if (-not [string]::Equals($currentRoot, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Canonical current state belongs to a different root.'
    }

    return [pscustomobject]@{
        root = $root
        markerPath = $markerPath
        currentPath = $currentPath
        launcherPath = $launcherPath
    }
}

function Get-CpaStackInstallRootPlan {
    param([string]$ControlRoot)

    if ([string]::IsNullOrWhiteSpace($ControlRoot)) {
        return [pscustomobject]@{
            adopted = $false
            preinitialized = $false
            preinitializeRequired = $false
            legacyAdoptionRequired = $false
            syncLauncher = $false
        }
    }
    $root = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
    $markerPath = Join-Path $root '.cpa-stack-instance.json'
    $currentPath = Join-Path $root 'state\current.json'
    $markerAny = Test-Path -LiteralPath $markerPath
    $currentAny = Test-Path -LiteralPath $currentPath
    $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf
    $currentExists = Test-Path -LiteralPath $currentPath -PathType Leaf
    if ($markerAny -and -not $markerExists) {
        throw "Canonical instance marker is not a regular file: $markerPath"
    }
    if ($currentAny -and -not $currentExists) {
        throw "Canonical current state is not a regular file: $currentPath"
    }
    if ($markerExists -and -not $currentExists) {
        [void](Assert-InstallerPreinitializedRoot -ControlRoot $root)
        return [pscustomobject]@{
            adopted = $false
            preinitialized = $true
            preinitializeRequired = $false
            legacyAdoptionRequired = $false
            syncLauncher = $true
        }
    }
    if ($markerExists -and $currentExists) {
        [void](Assert-AdoptedCanonicalInstallRoot -ControlRoot $root)
        return [pscustomobject]@{
            adopted = $true
            preinitialized = $false
            preinitializeRequired = $false
            legacyAdoptionRequired = $false
            syncLauncher = $true
        }
    }
    if ($currentExists) {
        return [pscustomobject]@{
            adopted = $false
            preinitialized = $false
            preinitializeRequired = $false
            legacyAdoptionRequired = $true
            syncLauncher = $false
        }
    }
    if (Test-Path -LiteralPath $root) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw "Requested CPA stack root is not a directory: $root"
        }
        Assert-CpaStackInstallAcl -Path $root -PathType Container -RequireProtected
        $unexpected = @(Get-ChildItem -Force -LiteralPath $root -ErrorAction Stop)
        if ($unexpected.Count -gt 0) {
            throw "Refusing to claim a non-empty CPA stack root without trusted instance state: $root"
        }
    }
    return [pscustomobject]@{
        adopted = $false
        preinitialized = $false
        preinitializeRequired = $true
        legacyAdoptionRequired = $false
        syncLauncher = $false
    }
}

function Get-InstallExecutionPlan {
    param(
        [AllowNull()]$PendingJournal = $(Read-SkillInstallJournal -Optional),
        [bool]$LegacyPreviousRelocationPending = $(Get-LegacyPreviousRelocationPending)
    )

    $skill = Get-SkillInstallAssessment -SourceManifest $sourceManifest
    $installRecoveryPending = $null -ne $PendingJournal
    $recoveryPending = $installRecoveryPending -or $LegacyPreviousRelocationPending
    $stackRootSpecified = if ($installRecoveryPending) {
        [bool]$PendingJournal.requestedStackRootSpecified
    } else {
        -not [string]::IsNullOrWhiteSpace($StackRoot)
    }
    $registeredBefore = Get-ProtectedRegisteredRoot
    $registeredRoot = if ($installRecoveryPending -and -not [string]::IsNullOrWhiteSpace([string]$PendingJournal.intentRoot)) {
        Assert-CpaStackSecureLocalRoot -Path ([string]$PendingJournal.intentRoot)
    } elseif ($stackRootSpecified) {
        Assert-CpaStackSecureLocalRoot -Path $StackRoot
    } else {
        $registeredBefore
    }
    $rootPlan = Get-CpaStackInstallRootPlan -ControlRoot $registeredRoot
    $existingLauncher = if ([string]::IsNullOrWhiteSpace($registeredRoot)) {
        $false
    } else {
        Test-Path -LiteralPath (Join-Path $registeredRoot 'ops\Start-CPA-Stack.ps1')
    }
    $blocked = [bool]$rootPlan.legacyAdoptionRequired
    $launcherIntent = if ($installRecoveryPending) { [bool]$PendingJournal.launcherIntent } else { [bool]($stackRootSpecified -or $rootPlan.syncLauncher -or $existingLauncher) }
    $registrationIntent = if ($installRecoveryPending) { [bool]$PendingJournal.registrationIntent } else { $stackRootSpecified }
    $manageLauncher = [bool](-not $blocked -and $launcherIntent)
    $launcher = Get-LauncherAssessment -ControlRoot $registeredRoot -Managed $manageLauncher
    $registrationRequired = [bool](-not $blocked -and $registrationIntent -and (
        [string]::IsNullOrWhiteSpace($registeredBefore) -or
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath($registeredBefore).TrimEnd('\'),
            [System.IO.Path]::GetFullPath($registeredRoot).TrimEnd('\'),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ))
    $launcherUpdateRequired = [bool]($manageLauncher -and [string]$launcher.state -ne 'Current')
    return [pscustomobject]@{
        skill = $skill
        stackRootSpecified = $stackRootSpecified
        registeredRoot = $registeredRoot
        rootPlan = $rootPlan
        manageLauncher = $manageLauncher
        launcher = $launcher
        registrationIntent = $registrationIntent
        legacyPreviousRelocationPending = $LegacyPreviousRelocationPending
        registrationRequired = $registrationRequired
        skillUpdateRequired = [bool]$skill.updateAvailable
        launcherUpdateRequired = $launcherUpdateRequired
        recoveryPending = $recoveryPending
        blocked = $blocked
        updateAvailable = [bool]($blocked -or [bool]$skill.updateAvailable -or $launcherUpdateRequired -or $registrationRequired -or $recoveryPending)
    }
}

function Write-NoChangeInstallResult {
    param([Parameter(Mandatory = $true)]$Plan)

    Write-InstallPublicResult -Value ([ordered]@{
        schemaVersion = 2
        operation = 'install'
        action = 'Update'
        success = $true
        outcome = 'NoChange'
        changed = $false
        installedVersion = $Plan.skill.installedVersion
        sourceVersion = $updaterVersion
        updateAvailable = $false
        launcherState = [string]$Plan.launcher.state
        launcherPath = $Plan.launcher.path
        launcherExpectedSha256 = $Plan.launcher.expectedSha256
        launcherActualSha256 = $Plan.launcher.actualSha256
        warnings = @()
        error = $null
        complete = $true
        coreCommitted = $false
        updaterVersion = $updaterVersion
        installedSkill = $installed
        stableCliPath = Join-Path $installed 'scripts\cpa-stack.ps1'
        stableUninstallPath = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
        previousSkill = if (Test-Path -LiteralPath $previous) { $previous } else { $null }
        registeredRoot = $Plan.registeredRoot
        registrationRequired = [bool]$Plan.registrationRequired
        launcherUpdated = $false
        launcherSynchronized = [bool]$Plan.manageLauncher
        registrationUpdated = $false
        recoveryPending = [bool]$Plan.recoveryPending
        legacyCanonicalAdoptionRequired = [bool]$Plan.rootPlan.legacyAdoptionRequired
        retainedPrevious = $null
        cleanupWarning = $null
        postCommitWarnings = @()
        fileCount = $sourceManifest.Count
    })
}

function Write-ManualActionRequiredInstallResult {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Update')][string]$RequestedAction
    )

    Write-InstallPublicResult -Value ([ordered]@{
        schemaVersion = 2
        operation = 'install'
        action = $RequestedAction
        success = $false
        outcome = 'ManualActionRequired'
        blocked = $true
        changed = $false
        installedVersion = $Plan.skill.installedVersion
        sourceVersion = $updaterVersion
        updateAvailable = $true
        recoveryPending = [bool]$Plan.recoveryPending
        launcherState = [string]$Plan.launcher.state
        launcherPath = $Plan.launcher.path
        launcherExpectedSha256 = $Plan.launcher.expectedSha256
        launcherActualSha256 = $Plan.launcher.actualSha256
        registeredRoot = $Plan.registeredRoot
        registrationRequired = $false
        legacyCanonicalAdoptionRequired = $true
        warnings = @()
        error = [ordered]@{
            code = 'LegacyCanonicalAdoptionRequired'
            step = 'rootValidation'
            message = 'The requested root has legacy current state but no trusted instance marker. Adopt it explicitly before installer launcher or registration writes are allowed.'
        }
    })
}

Assert-CpaStackPathNoReparseAncestors -Path $skillsRoot -Description 'Skill installation path'
Assert-CpaStackPathNoReparseAncestors -Path $slotRoot -Description 'Protected skill slot path'
Assert-SafeSkillTree
$sourceManifest = @(Get-ComparableManifest -Root $source)
$initialSlotState = Get-SkillSlotNamespaceState
$installPlan = Get-InstallExecutionPlan `
    -PendingJournal $initialSlotState.installJournal `
    -LegacyPreviousRelocationPending ([bool]$initialSlotState.legacyPreviousRelocationPending)

if ([bool]$installPlan.blocked) {
    Write-ManualActionRequiredInstallResult -Plan $installPlan -RequestedAction $Action
    return
}

if ($Action -eq 'Check') {
    Write-InstallPublicResult -Value ([ordered]@{
        schemaVersion = 2
        operation = 'install'
        action = 'Check'
        success = $true
        outcome = 'NoChange'
        changed = $false
        installedVersion = $installPlan.skill.installedVersion
        sourceVersion = $updaterVersion
        updateAvailable = [bool]$installPlan.updateAvailable
        recoveryPending = [bool]$installPlan.recoveryPending
        launcherState = [string]$installPlan.launcher.state
        launcherPath = $installPlan.launcher.path
        launcherExpectedSha256 = $installPlan.launcher.expectedSha256
        launcherActualSha256 = $installPlan.launcher.actualSha256
        registeredRoot = $installPlan.registeredRoot
        registrationRequired = [bool]$installPlan.registrationRequired
        warnings = @()
        error = $null
    })
    return
}

if (-not $installPlan.updateAvailable) {
    Write-NoChangeInstallResult -Plan $installPlan
    return
}

$operationLock = $null
$installLock = $null
$swapped = $false
$installedAtRetiring = $false
$installedAtPrevious = $false
$previousAtRetained = $false
$legacyInstalledTransaction = $false
$legacyMarkerAdded = $false
$legacyMarkerHash = $null
$coreCommitted = $false
$coreCommittedThisRun = $false
$registrationUpdated = $null
$launcherSynchronized = $null
$launcherUpdated = $false
$legacyCanonicalAdoptionRequired = $false
$journalRecovered = $false
$legacyPreviousRelocated = $false
$activeInstallJournal = $null
$targetDescriptor = $null
$currentStep = 'lock'
try {
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 15
    $installLock = Enter-CpaStackOperationLock -Name 'CPAStackSkillInstall' -TimeoutSeconds 15
    $currentStep = 'recovery'
    $lockedSlotState = Get-SkillSlotNamespaceState
    Promote-StandaloneSkillJournalWriteResidues -State $lockedSlotState
    $lockedSlotState = Get-SkillSlotNamespaceState
    Remove-ValidatedLegacyRelocationWriteBeforeRecovery -State $lockedSlotState
    $pendingJournal = $lockedSlotState.installJournal
    $pendingRelocationJournal = $lockedSlotState.relocationJournal
    if ($null -ne $pendingJournal -and ($null -ne $pendingRelocationJournal -or (Test-Path -LiteralPath $legacyPrevious))) {
        throw 'Install and legacy previous relocation journals overlap; no recovery write was performed.'
    }
    $legacyPreviousRelocated = Invoke-LegacyPreviousRelocation
    $journalRecovery = Recover-SkillInstallJournal
    Remove-ValidatedSkillJournalWriteResidues -State $lockedSlotState
    $journalRecovered = [bool]([bool]$journalRecovery.recovered -or $legacyPreviousRelocated)
    $coreCommitted = [bool]$journalRecovery.committed
    if ($coreCommitted) { $activeInstallJournal = $journalRecovery.journal }
    $postRecoverySlotState = Get-SkillSlotNamespaceState
    $installPlan = Get-InstallExecutionPlan `
        -PendingJournal $postRecoverySlotState.installJournal `
        -LegacyPreviousRelocationPending ([bool]$postRecoverySlotState.legacyPreviousRelocationPending)
    if ([bool]$installPlan.blocked) {
        Write-ManualActionRequiredInstallResult -Plan $installPlan -RequestedAction $Action
        return
    }
    if (-not $installPlan.updateAvailable -and -not $journalRecovered) {
        Write-NoChangeInstallResult -Plan $installPlan
        return
    }
    $skillUpdateRequired = [bool]$installPlan.skillUpdateRequired
    $stackRootSpecified = [bool]$installPlan.stackRootSpecified
    $registeredRoot = [string]$installPlan.registeredRoot
    $rootPlan = $installPlan.rootPlan
    $manageLauncher = [bool]$installPlan.manageLauncher
    $registrationIntent = [bool]$installPlan.registrationIntent
    $registrationRequired = [bool]$installPlan.registrationRequired
    $legacyCanonicalAdoptionRequired = [bool]$rootPlan.legacyAdoptionRequired
    if ($skillUpdateRequired) {
        $currentStep = 'skillCommit'
        Initialize-SkillDiscoveryRoot
        Initialize-SkillSlotRoot
        Clear-StaleSkillTransactionDirectories
    foreach ($slot in @(
        @{ Path = $installed; Kind = 'Installed' },
        @{ Path = $previous; Kind = 'Previous' },
        @{ Path = $staging; Kind = 'Staging' },
        @{ Path = $retained; Kind = 'Retained' },
        @{ Path = $retiring; Kind = 'Retiring' }
    )) {
        [void](Assert-SkillSlotPath -Path $slot.Path -Kind $slot.Kind)
    }
    foreach ($transactionPath in @($staging, $retained, $retiring)) {
        if (Test-Path -LiteralPath $transactionPath) {
            throw "Skill transaction path already exists: $transactionPath"
        }
    }

    New-Item -ItemType Directory -Path $staging | Out-Null
    Protect-CpaStackPrivateDirectory -Path $staging
    Write-InstallMarker -Root $staging
    foreach ($item in Get-ChildItem -Force -LiteralPath $source) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $staging $item.Name) -Recurse -Force
    }

    $stagingManifest = @(Get-ComparableManifest -Root $staging)
    if (-not (Test-ManifestEqual -Left $sourceManifest -Right $stagingManifest)) {
        throw 'Skill staging verification failed.'
    }

    $hadPrevious = Test-Path -LiteralPath $previous -PathType Container
    if ((Test-Path -LiteralPath $previous) -and -not $hadPrevious) {
        throw "Previous-skill slot is not a directory: $previous"
    }
    if ($hadPrevious -and -not (Test-OwnedSkillDirectory -Root $previous)) {
        throw "Refusing to retain an unowned previous-skill directory: $previous"
    }

    $installedWasLegacy = $false
    $hadInstalled = Test-Path -LiteralPath $installed -PathType Container
    if (Test-Path -LiteralPath $previous) {
        [void](Assert-SkillSlotPath -Path $previous -Kind Previous)
    }
    if ((Test-Path -LiteralPath $installed) -and -not (Test-Path -LiteralPath $installed -PathType Container)) {
        throw "Installed skill slot is not a directory: $installed"
    }
    if ($hadInstalled) {
        if (-not (Test-OwnedSkillDirectory -Root $installed)) {
            Assert-LegacySkillDirectory -Root $installed
            $installedWasLegacy = $true
            $legacyInstalledTransaction = $true
        }
    }

    $targetDescriptor = New-SkillSlotDescriptor -Root $staging -CanonicalSlot $installed -Kind Target -Ownership Owned
    $originalInstalledDescriptor = if ($hadInstalled) {
        New-SkillSlotDescriptor `
            -Root $installed -CanonicalSlot $installed -Kind Installed `
            -Ownership $(if ($installedWasLegacy) { 'Legacy' } else { 'Owned' })
    } else { $null }
    $originalPreviousDescriptor = if ($hadPrevious) {
        New-SkillSlotDescriptor -Root $previous -CanonicalSlot $previous -Kind Previous -Ownership Owned
    } else { $null }
    $activeInstallJournal = New-SkillInstallJournalDocument `
        -Plan $installPlan `
        -HadInstalled $hadInstalled `
        -HadPrevious $hadPrevious `
        -InstalledWasLegacy $installedWasLegacy `
        -OriginalInstalled $originalInstalledDescriptor `
        -OriginalPrevious $originalPreviousDescriptor `
        -Target $targetDescriptor
    Write-SkillTransactionClaim -Root $staging -Kind Staging -ExpectedTransactionId $transactionId -Descriptor $targetDescriptor
    Write-SkillInstallJournal -Journal $activeInstallJournal -Phase Prepared
    if ($hadInstalled) {
        Write-SkillTransactionClaim `
            -Root $installed -Kind Retiring -ExpectedTransactionId $transactionId `
            -Descriptor $originalInstalledDescriptor
        Write-SkillInstallJournal -Journal $activeInstallJournal -Phase RetiringInstalled
        Move-SkillDirectoryWithRetry -SourcePath $installed -SourceKind Installed -DestinationPath $retiring -DestinationKind Retiring
        $installedAtRetiring = $true
        [void](Assert-SkillTransactionClaim `
            -Root $retiring -Kind Retiring -ExpectedTransactionId $transactionId `
            -Descriptor $originalInstalledDescriptor)

        if ($hadPrevious) {
            Write-SkillTransactionClaim `
                -Root $previous -Kind Retained -ExpectedTransactionId $transactionId `
                -Descriptor $originalPreviousDescriptor
            Write-SkillInstallJournal -Journal $activeInstallJournal -Phase RetainingPrevious
            Move-SkillDirectoryWithRetry -SourcePath $previous -SourceKind Previous -DestinationPath $retained -DestinationKind Retained
            $previousAtRetained = $true
            [void](Assert-SkillTransactionClaim `
                -Root $retained -Kind Retained -ExpectedTransactionId $transactionId `
                -Descriptor $originalPreviousDescriptor)
        }
        Write-SkillInstallJournal -Journal $activeInstallJournal -Phase MovingActiveToPrevious
        Move-SkillDirectoryWithRetry -SourcePath $retiring -SourceKind Retiring -DestinationPath $previous -DestinationKind Previous
        $installedAtRetiring = $false
        $installedAtPrevious = $true
        Remove-SkillTransactionClaim `
            -Root $previous -Kind Retiring -ExpectedTransactionId $transactionId `
            -Descriptor $originalInstalledDescriptor

        if ($installedWasLegacy) {
            $activeInstallJournal.legacyMarkerPending = $true
            Write-SkillInstallJournalDocument -Journal $activeInstallJournal
            try {
                Write-InstallMarker -Root $previous
            } catch {
                $markerPath = Get-InstallMarkerPath -Root $previous
                if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                    $legacyMarkerAdded = $true
                    $legacyMarkerHash = Get-CpaStackFileHash -Path $markerPath
                }
                throw
            }
            $legacyMarkerAdded = $true
            $legacyMarkerHash = Get-CpaStackFileHash -Path (Get-InstallMarkerPath -Root $previous)
            Write-SkillInstallJournal `
                -Journal $activeInstallJournal `
                -Phase MovingActiveToPrevious `
                -LegacyMarkerAdded $legacyMarkerAdded `
                -LegacyMarkerSha256 $legacyMarkerHash
        }
        if (-not (Test-OwnedSkillDirectory -Root $previous)) {
            throw "Previous skill directory is not safely owned after retirement: $previous"
        }
    }

    Write-SkillInstallJournal `
        -Journal $activeInstallJournal `
        -Phase Committing `
        -LegacyMarkerAdded $legacyMarkerAdded `
        -LegacyMarkerSha256 $legacyMarkerHash
    Move-SkillDirectoryWithRetry -SourcePath $staging -SourceKind Staging -DestinationPath $installed -DestinationKind Installed
    $swapped = $true
    [void](Assert-JournalTargetArtifact -Journal $activeInstallJournal -Root $installed)
    [void](Assert-SkillTransactionClaim `
        -Root $installed -Kind Staging -ExpectedTransactionId $transactionId `
        -Descriptor $targetDescriptor)
    $coreCommitted = $true
    $coreCommittedThisRun = $true
    Write-SkillInstallJournal `
        -Journal $activeInstallJournal `
        -Phase Committed `
        -LegacyMarkerAdded $legacyMarkerAdded `
        -LegacyMarkerSha256 $legacyMarkerHash
    }

    $rootPreinitializePending = if ($null -ne $activeInstallJournal) {
        [bool]$activeInstallJournal.rootPreinitializeIntent -and -not [bool]$activeInstallJournal.postCommit.rootReady
    } else {
        [bool]($stackRootSpecified -and [bool]$rootPlan.preinitializeRequired)
    }
    if ($rootPreinitializePending) {
        $currentStep = 'rootPreinitialize'
        if ([bool]$rootPlan.preinitializeRequired) {
            [void](New-InstallerPreinitializedRoot -ControlRoot $registeredRoot)
        } elseif (-not [bool]$rootPlan.preinitialized -and -not [bool]$rootPlan.adopted) {
            throw 'Pending installer root initialization no longer targets a trusted root.'
        }
        $rootPlan = Get-CpaStackInstallRootPlan -ControlRoot $registeredRoot
        if (-not [bool]$rootPlan.preinitialized -and -not [bool]$rootPlan.adopted) {
            throw 'Installer root initialization did not produce a trusted root.'
        }
        if ($null -ne $activeInstallJournal) {
            $activeInstallJournal.postCommit.rootReady = $true
            Write-SkillInstallJournalDocument -Journal $activeInstallJournal
        }
    }

    if ($manageLauncher) {
        $currentStep = 'launcherSync'
        $launcherSynchronized = $false
        $launcherSync = Sync-InstallerLauncherBootstrap -ControlRoot $registeredRoot
        $launcherUpdated = [bool]$launcherSync.changed
        $launcherSynchronized = $true
        $verifiedLauncher = Get-LauncherAssessment -ControlRoot $registeredRoot -Managed $true
        if ([string]$verifiedLauncher.state -cne 'Current') {
            throw 'Installer launcher synchronization did not verify the intended launcher.'
        }
        if ($null -ne $activeInstallJournal) {
            $activeInstallJournal.postCommit.launcherVerified = $true
            Write-SkillInstallJournalDocument -Journal $activeInstallJournal
        }
    }

    if ($registrationRequired) {
        $currentStep = 'registration'
        $registrationUpdated = $false
        Set-CpaStackRegisteredRoot -ControlRoot $registeredRoot
        $registrationUpdated = $true
    }
    if ($registrationIntent) {
        $registeredAfter = Get-ProtectedRegisteredRoot
        if ([string]::IsNullOrWhiteSpace($registeredAfter) -or
            -not (Test-CanonicalPathEqual -Left $registeredAfter -Right $registeredRoot)) {
            throw 'Installer root registration did not verify the intended root.'
        }
        if ($null -ne $activeInstallJournal) {
            $activeInstallJournal.postCommit.registrationVerified = $true
            Write-SkillInstallJournalDocument -Journal $activeInstallJournal
        }
    }

    $currentStep = 'finalVerification'
    $finalLauncher = Get-LauncherAssessment -ControlRoot $registeredRoot -Managed $manageLauncher
    if ($manageLauncher -and [string]$finalLauncher.state -cne 'Current') {
        throw 'Installer post-commit verification found an unfinished launcher synchronization.'
    }
    if ($registrationIntent) {
        $registeredAfter = Get-ProtectedRegisteredRoot
        if ([string]::IsNullOrWhiteSpace($registeredAfter) -or
            -not (Test-CanonicalPathEqual -Left $registeredAfter -Right $registeredRoot)) {
            throw 'Installer post-commit verification found an unfinished root registration.'
        }
    }
    if ($null -ne $activeInstallJournal -and
        (-not [bool]$activeInstallJournal.postCommit.rootReady -or
        -not [bool]$activeInstallJournal.postCommit.launcherVerified -or
        -not [bool]$activeInstallJournal.postCommit.registrationVerified)) {
        throw 'Installer post-commit journal still contains unfinished work.'
    }

    if ($coreCommitted) {
        $currentStep = 'journalFinalize'
        [void](Recover-SkillInstallJournal -FinalizeCommitted)
        $previousAtRetained = $false
    }

    $installedVersion = Get-SkillVersion -Root $installed
    $changed = [bool]($skillUpdateRequired -or $launcherUpdated -or $registrationUpdated -or $journalRecovered)
    $currentStep = 'result'
    Write-InstallPublicResult -Value ([ordered]@{
        schemaVersion = 2
        operation = 'install'
        action = 'Update'
        success = $true
        outcome = if ($changed) { 'Changed' } else { 'NoChange' }
        changed = $changed
        installedVersion = $installedVersion
        sourceVersion = $updaterVersion
        updateAvailable = $false
        recovered = $journalRecovered
        launcherState = [string]$finalLauncher.state
        launcherPath = $finalLauncher.path
        launcherExpectedSha256 = $finalLauncher.expectedSha256
        launcherActualSha256 = $finalLauncher.actualSha256
        warnings = @()
        error = $null
        complete = $true
        coreCommitted = $coreCommitted
        updaterVersion = $updaterVersion
        installedSkill = $installed
        stableCliPath = Join-Path $installed 'scripts\cpa-stack.ps1'
        stableUninstallPath = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
        previousSkill = if (Test-Path -LiteralPath $previous) { $previous } else { $null }
        registeredRoot = $registeredRoot
        registrationRequired = $false
        launcherUpdated = $launcherUpdated
        launcherSynchronized = $launcherSynchronized
        registrationUpdated = $registrationUpdated
        recoveryPending = $false
        legacyCanonicalAdoptionRequired = $legacyCanonicalAdoptionRequired
        retainedPrevious = $null
        cleanupWarning = $null
        postCommitWarnings = @()
        fileCount = $sourceManifest.Count
    })
} catch {
    $installError = $_.Exception
    $recoveryError = $null
    if (-not $coreCommitted -and (Test-Path -LiteralPath $installJournal -PathType Leaf)) {
        try {
            $failedTransactionRecovery = Recover-SkillInstallJournal
            if ([bool]$failedTransactionRecovery.committed) {
                $coreCommitted = $true
                $coreCommittedThisRun = $true
                $activeInstallJournal = $failedTransactionRecovery.journal
            }
        } catch {
            $recoveryError = $_.Exception
        }
    }
    if ($coreCommitted) {
        $failurePlan = $installPlan
        $failureAssessmentError = $null
        try {
            $failurePlan = Get-InstallExecutionPlan
        } catch {
            $failureAssessmentError = $_.Exception.Message
        }
        try {
            Write-InstallPublicResult -Value ([ordered]@{
                schemaVersion = 2
                operation = 'install'
                action = 'Update'
                success = $false
                outcome = 'Failed'
                changed = [bool]($coreCommittedThisRun -or $launcherUpdated -or $registrationUpdated)
                installedVersion = Get-SkillVersion -Root $installed
                sourceVersion = $updaterVersion
                updateAvailable = $true
                recoveryPending = Test-Path -LiteralPath $installJournal -PathType Leaf
                recovered = $journalRecovered
                launcherState = [string]$failurePlan.launcher.state
                launcherPath = $failurePlan.launcher.path
                launcherExpectedSha256 = $failurePlan.launcher.expectedSha256
                launcherActualSha256 = $failurePlan.launcher.actualSha256
                warnings = @()
                error = [ordered]@{
                    code = 'InstallerStepFailed'
                    step = $currentStep
                    message = $installError.Message
                    type = $installError.GetType().FullName
                    assessmentError = $failureAssessmentError
                }
                complete = $false
                coreCommitted = $true
                updaterVersion = $updaterVersion
                installedSkill = $installed
                stableCliPath = Join-Path $installed 'scripts\cpa-stack.ps1'
                stableUninstallPath = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
                previousSkill = if (Test-Path -LiteralPath $previous) { $previous } else { $null }
                registeredRoot = $failurePlan.registeredRoot
                registrationRequired = [bool]$failurePlan.registrationRequired
                launcherUpdated = $launcherUpdated
                launcherSynchronized = $launcherSynchronized
                registrationUpdated = $registrationUpdated
                legacyCanonicalAdoptionRequired = $legacyCanonicalAdoptionRequired
                retainedPrevious = if (Test-Path -LiteralPath $retained -PathType Container) { $retained } else { $null }
                cleanupWarning = $null
                postCommitWarnings = @()
                fileCount = $sourceManifest.Count
            })
        } catch {
            throw "CPA skill core commit succeeded, but failure reporting also failed. The committed journal was retained. Original error: $($installError.Message) Reporting error: $($_.Exception.Message)"
        }
        throw $installError
    }
    if ($null -ne $recoveryError) {
        throw "Install failed and automatic recovery could not restore the original skill slots. Original error: $($installError.Message) Recovery error: $($recoveryError.Message) No process was terminated."
    }
    throw $installError
} finally {
    $stagingCleanupError = $null
    if (Test-Path -LiteralPath $staging) {
        try {
            if ($null -eq $targetDescriptor) {
                throw 'Staging cleanup has no validated target descriptor.'
            }
            Remove-ClaimedSkillTransactionDirectory `
                -Path $staging -Kind Staging -ExpectedTransactionId $transactionId `
                -Descriptor $targetDescriptor
        } catch {
            $stagingCleanupError = $_.Exception.Message
        }
    }
    Exit-CpaStackOperationLock -Mutex $installLock
    Exit-CpaStackOperationLock -Mutex $operationLock
    if ($stagingCleanupError) {
        Write-Warning "Installer left a protected staging directory because safe cleanup failed: $stagingCleanupError"
    }
}
