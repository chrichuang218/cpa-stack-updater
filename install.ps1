#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CodexHome = $(if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }),
    [string]$StackRoot
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'skills\cpa-safe-upgrade'
$skillsRoot = Join-Path ([System.IO.Path]::GetFullPath($CodexHome).TrimEnd('\')) 'skills'
$installed = Join-Path $skillsRoot 'cpa-safe-upgrade'
$staging = Join-Path $skillsRoot ('cpa-safe-upgrade.staging-' + [guid]::NewGuid().ToString('N'))
$previous = Join-Path $skillsRoot 'cpa-safe-upgrade.previous'
$common = Join-Path $source 'scripts\CpaStack.Common.ps1'

if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf) -or -not (Test-Path -LiteralPath $common -PathType Leaf)) {
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
        updaterVersion = $updaterVersion
        installedAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path (Get-InstallMarkerPath -Root $Root)
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

    $acl = Get-Acl -LiteralPath $locatorFull -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) {
        throw "CPA stack root locator ACL is not protected: $locatorPath"
    }

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $ownerText = [string]$acl.Owner
        $ownerSid = if ($ownerText -match '^S-1-') {
            $ownerText
        } else {
            [System.Security.Principal.NTAccount]::new($ownerText).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
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
    foreach ($rule in $acl.Access) {
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

$operationLock = $null
$installLock = $null
$swapped = $false
$hadInstalled = $false
$launcherUpdated = $false
$legacyCanonicalAdoptionRequired = $false
try {
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 2
    $installLock = Enter-CpaStackOperationLock -Name 'CPAStackSkillInstall' -TimeoutSeconds 2
    Assert-SafeSkillTree
    $stackRootSpecified = -not [string]::IsNullOrWhiteSpace($StackRoot)
    if ($stackRootSpecified) {
        $registeredRoot = Assert-CpaStackSecureLocalRoot -Path $StackRoot
    } else {
        $registeredRoot = Get-ProtectedRegisteredRoot
    }
    New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
    Copy-Item -LiteralPath $source -Destination $staging -Recurse -Force

    $sourceManifest = Get-Manifest -Root $source
    $stagingManifest = Get-Manifest -Root $staging
    if ((ConvertTo-Json $sourceManifest -Depth 4 -Compress) -cne (ConvertTo-Json $stagingManifest -Depth 4 -Compress)) {
        throw 'Skill staging verification failed.'
    }
    Write-InstallMarker -Root $staging
    Protect-CpaStackPrivateDirectory -Path $staging

    if (Test-Path -LiteralPath $previous) {
        if (-not (Test-OwnedSkillDirectory -Root $previous)) {
            throw "Refusing to delete an unowned previous-skill directory: $previous"
        }
        Remove-Item -LiteralPath $previous -Recurse -Force
    }
    if (Test-Path -LiteralPath $installed) {
        if (-not (Test-OwnedSkillDirectory -Root $installed)) {
            Assert-LegacySkillDirectory -Root $installed
            Write-InstallMarker -Root $installed
        }
        $hadInstalled = $true
        Move-Item -LiteralPath $installed -Destination $previous
    }
    try {
        Move-Item -LiteralPath $staging -Destination $installed
        $swapped = $true
    } catch {
        if (-not (Test-Path -LiteralPath $installed) -and (Test-Path -LiteralPath $previous)) {
            Move-Item -LiteralPath $previous -Destination $installed
        }
        throw
    }

    if ($registeredRoot) {
        $markerExists = Test-Path -LiteralPath (Join-Path $registeredRoot '.cpa-stack-instance.json') -PathType Leaf
        $currentExists = Test-Path -LiteralPath (Join-Path $registeredRoot 'state\current.json') -PathType Leaf
        if ($markerExists -and -not $currentExists) {
            throw 'The requested stack root has an instance marker but no current state.'
        }
        if ($markerExists -and $currentExists) {
            $launcherSync = Sync-CpaStackCanonicalLauncher -ControlRoot $registeredRoot -SourcePath (Join-Path $installed 'scripts\Start-CPA-Stack.ps1')
            $launcherUpdated = [bool]$launcherSync.changed
        } elseif ($currentExists) {
            $legacyCanonicalAdoptionRequired = $true
        }
        if ($stackRootSpecified) {
            Set-CpaStackRegisteredRoot -ControlRoot $registeredRoot
        }
    }

    [pscustomobject]@{
        success = $true
        updaterVersion = $updaterVersion
        installedSkill = $installed
        stableCliPath = Join-Path $installed 'scripts\cpa-stack.ps1'
        stableUninstallPath = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
        previousSkill = if (Test-Path -LiteralPath $previous) { $previous } else { $null }
        registeredRoot = $registeredRoot
        launcherUpdated = $launcherUpdated
        legacyCanonicalAdoptionRequired = $legacyCanonicalAdoptionRequired
        fileCount = $sourceManifest.Count
    } | ConvertTo-Json -Depth 4
} catch {
    if ($swapped) {
        if (Test-Path -LiteralPath $installed) {
            if (-not (Test-OwnedSkillDirectory -Root $installed)) {
                throw "Install failed and the newly installed directory lost its ownership marker. Manual recovery is required. Original error: $($_.Exception.Message)"
            }
            Remove-Item -LiteralPath $installed -Recurse -Force -ErrorAction Stop
        }
        if ($hadInstalled -and (Test-Path -LiteralPath $previous)) {
            Move-Item -LiteralPath $previous -Destination $installed -ErrorAction Stop
        }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    Exit-CpaStackOperationLock -Mutex $installLock
    Exit-CpaStackOperationLock -Mutex $operationLock
}
