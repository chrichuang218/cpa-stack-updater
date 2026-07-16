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
$transactionId = [guid]::NewGuid().ToString('N')
$staging = Join-Path $skillsRoot ('cpa-safe-upgrade.staging-' + $transactionId)
$retained = Join-Path $skillsRoot ('cpa-safe-upgrade.retained-' + $transactionId)
$retiring = Join-Path $skillsRoot ('cpa-safe-upgrade.retiring-' + $transactionId)
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
    $expectedParent = [System.IO.Path]::GetFullPath($skillsRoot).TrimEnd('\')
    Assert-CpaStackPathNoReparseAncestors -Path $expectedParent -Description 'Skill installation path'
    Assert-CpaStackPathNoReparseAncestors -Path $full -Description 'Skill transaction path'
    if (-not [string]::Equals($parent, $expectedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Skill transaction path is outside the skills directory: $Path"
    }

    $name = [System.IO.Path]::GetFileName($full)
    $validName = switch ($Kind) {
        'Installed' { $name -ceq 'cpa-safe-upgrade' }
        'Previous' { $name -ceq 'cpa-safe-upgrade.previous' }
        'Staging' { $name -cmatch '^cpa-safe-upgrade\.staging-[0-9a-f]{32}$' }
        'Retained' { $name -cmatch '^cpa-safe-upgrade\.retained-[0-9a-f]{32}$' }
        'Retiring' { $name -cmatch '^cpa-safe-upgrade\.retiring-[0-9a-f]{32}$' }
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

function Remove-OwnedSkillTransactionDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained')][string]$Kind
    )

    $full = Assert-SkillSlotPath -Path $Path -Kind $Kind
    if (-not (Test-Path -LiteralPath $full)) { return }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Skill transaction cleanup target is not a directory: $full"
    }
    $items = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
    if ($items.Count -eq 0) {
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
        return
    }
    if (-not (Test-OwnedSkillDirectory -Root $full)) {
        throw "Refusing to delete an unowned or unsafe skill transaction directory: $full"
    }
    $markerPath = Get-InstallMarkerPath -Root $full
    foreach ($item in $items) {
        if ([string]::Equals($item.FullName, $markerPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $full -Force -ErrorAction Stop
}

function Get-SkillTransactionDirectories {
    param([Parameter(Mandatory = $true)][ValidateSet('Staging', 'Retained', 'Retiring')][string]$Kind)

    if (-not (Test-Path -LiteralPath $skillsRoot -PathType Container)) {
        return @()
    }
    $pattern = switch ($Kind) {
        'Staging' { '^cpa-safe-upgrade\.staging-[0-9a-f]{32}$' }
        'Retained' { '^cpa-safe-upgrade\.retained-[0-9a-f]{32}$' }
        'Retiring' { '^cpa-safe-upgrade\.retiring-[0-9a-f]{32}$' }
    }
    return @(
        Get-ChildItem -LiteralPath $skillsRoot -Force -ErrorAction Stop |
            Where-Object { $_.Name -cmatch $pattern } |
            ForEach-Object { Assert-SkillSlotPath -Path $_.FullName -Kind $Kind }
    )
}

function Clear-StaleSkillTransactionDirectories {
    $retiringDirectories = @(Get-SkillTransactionDirectories -Kind Retiring)
    if ($retiringDirectories.Count -gt 0) {
        throw "An unfinished retiring skill transaction requires manual recovery before installation can continue: $($retiringDirectories -join ', ')"
    }

    foreach ($kind in @('Staging', 'Retained')) {
        foreach ($path in @(Get-SkillTransactionDirectories -Kind $kind)) {
            try {
                Remove-OwnedSkillTransactionDirectory -Path $path -Kind $kind
            } catch {
                $kindLabel = $kind.ToLowerInvariant()
                throw "Could not clean a stale $kindLabel transaction directory '$path'. Close editors or terminals using it, then retry. The active skill was not changed. Error: $($_.Exception.Message)"
            }
        }
    }
}

function Remove-TransactionalLegacyMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('Previous', 'Retiring')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedHash
    )

    $full = Assert-SkillSlotPath -Path $Root -Kind $Kind
    if (-not (Test-OwnedSkillDirectory -Root $full)) {
        throw "Refusing to remove a transactional marker from an unowned directory: $full"
    }
    $markerPath = Get-InstallMarkerPath -Root $full
    if ((Get-CpaStackFileHash -Path $markerPath) -cne $ExpectedHash) {
        throw "Transactional legacy ownership marker changed during install: $markerPath"
    }
    $marker = Read-CpaStackJson -Path $markerPath
    if ([string]$marker.updaterVersion -cne $updaterVersion) {
        throw "Transactional legacy ownership marker has an unexpected updater version: $markerPath"
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    Assert-LegacySkillDirectory -Root $full
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

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($RequireProtected -and -not $acl.AreAccessRulesProtected) {
        throw "Canonical stack root ACL inheritance is not protected: $Path"
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
        throw "Canonical install path owner could not be verified: $Path"
    }
    if ($ownerSid -ne $currentSid) {
        throw "Canonical install path is not owned by the current Windows user: $Path"
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
            throw "Canonical install path contains an unresolvable allow principal: $Path"
        }
        if (-not $allowedSids.ContainsKey($sid)) {
            throw "Canonical install path grants access to an unexpected identity: $Path ($sid)"
        }
    }
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
        return [pscustomobject]@{ adopted = $false; legacyAdoptionRequired = $false; syncLauncher = $false }
    }
    $markerPath = Join-Path $ControlRoot '.cpa-stack-instance.json'
    $currentPath = Join-Path $ControlRoot 'state\current.json'
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
        throw 'The requested stack root has an instance marker but no current state.'
    }
    if ($markerExists -and $currentExists) {
        [void](Assert-AdoptedCanonicalInstallRoot -ControlRoot $ControlRoot)
        return [pscustomobject]@{ adopted = $true; legacyAdoptionRequired = $false; syncLauncher = $true }
    }
    return [pscustomobject]@{
        adopted = $false
        legacyAdoptionRequired = $currentExists
        syncLauncher = $false
    }
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
$retainedCleanupWarning = $null
$coreCommitted = $false
$postCommitWarnings = New-Object 'System.Collections.Generic.List[object]'
$registrationUpdated = $null
$launcherSynchronized = $null
$launcherUpdated = $false
$legacyCanonicalAdoptionRequired = $false
try {
    Assert-CpaStackPathNoReparseAncestors -Path $skillsRoot -Description 'Skill installation path'
    $operationLock = Enter-CpaStackOperationLock -TimeoutSeconds 2
    $installLock = Enter-CpaStackOperationLock -Name 'CPAStackSkillInstall' -TimeoutSeconds 2
    Assert-SafeSkillTree
    $stackRootSpecified = -not [string]::IsNullOrWhiteSpace($StackRoot)
    if ($stackRootSpecified) {
        $registeredRoot = Assert-CpaStackSecureLocalRoot -Path $StackRoot
    } else {
        $registeredRoot = Get-ProtectedRegisteredRoot
    }
    $rootPlan = Get-CpaStackInstallRootPlan -ControlRoot $registeredRoot
    $legacyCanonicalAdoptionRequired = [bool]$rootPlan.legacyAdoptionRequired
    New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
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

    $sourceManifest = Get-Manifest -Root $source
    $stagingManifest = @(Get-Manifest -Root $staging | Where-Object { $_.path -cne '.cpa-stack-updater-installed.json' })
    if ((ConvertTo-Json $sourceManifest -Depth 4 -Compress) -cne (ConvertTo-Json $stagingManifest -Depth 4 -Compress)) {
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
    if (Test-Path -LiteralPath $previous) {
        [void](Assert-SkillSlotPath -Path $previous -Kind Previous)
    }
    if ((Test-Path -LiteralPath $installed) -and -not (Test-Path -LiteralPath $installed -PathType Container)) {
        throw "Installed skill slot is not a directory: $installed"
    }
    if (Test-Path -LiteralPath $installed -PathType Container) {
        if (-not (Test-OwnedSkillDirectory -Root $installed)) {
            Assert-LegacySkillDirectory -Root $installed
            $installedWasLegacy = $true
            $legacyInstalledTransaction = $true
        }
        Move-SkillDirectoryWithRetry -SourcePath $installed -SourceKind Installed -DestinationPath $retiring -DestinationKind Retiring
        $installedAtRetiring = $true

        if ($installedWasLegacy) {
            Assert-LegacySkillDirectory -Root $retiring
        } elseif (-not (Test-OwnedSkillDirectory -Root $retiring)) {
            throw "Retiring skill directory is not safely owned: $retiring"
        }

        if ($hadPrevious) {
            Move-SkillDirectoryWithRetry -SourcePath $previous -SourceKind Previous -DestinationPath $retained -DestinationKind Retained
            $previousAtRetained = $true
        }
        Move-SkillDirectoryWithRetry -SourcePath $retiring -SourceKind Retiring -DestinationPath $previous -DestinationKind Previous
        $installedAtRetiring = $false
        $installedAtPrevious = $true

        if ($installedWasLegacy) {
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
        }
        if (-not (Test-OwnedSkillDirectory -Root $previous)) {
            throw "Previous skill directory is not safely owned after retirement: $previous"
        }
    }

    Move-SkillDirectoryWithRetry -SourcePath $staging -SourceKind Staging -DestinationPath $installed -DestinationKind Installed
    $swapped = $true
    if (-not (Test-OwnedSkillDirectory -Root $installed)) {
        throw "Newly installed skill directory is not safely owned: $installed"
    }
    $coreCommitted = $true

    if ([bool]$rootPlan.syncLauncher) {
        try {
            [void](Assert-AdoptedCanonicalInstallRoot -ControlRoot $registeredRoot)
            $launcherSync = Sync-CpaStackCanonicalLauncher -ControlRoot $registeredRoot -SourcePath (Join-Path $installed 'scripts\Start-CPA-Stack.ps1')
            $launcherUpdated = [bool]$launcherSync.changed
            $launcherSynchronized = $true
        } catch {
            $launcherSynchronized = $false
            [void]$postCommitWarnings.Add([pscustomobject]@{
                step = 'launcherSync'
                message = $_.Exception.Message
            })
        }
    }

    if ($stackRootSpecified) {
        try {
            Set-CpaStackRegisteredRoot -ControlRoot $registeredRoot
            $registrationUpdated = $true
        } catch {
            $registrationUpdated = $false
            [void]$postCommitWarnings.Add([pscustomobject]@{
                step = 'registration'
                message = $_.Exception.Message
            })
        }
    }

    if ($previousAtRetained) {
        try {
            Remove-OwnedSkillTransactionDirectory -Path $retained -Kind Retained
            $previousAtRetained = $false
        } catch {
            $retainedCleanupWarning = $_.Exception.Message
            [void]$postCommitWarnings.Add([pscustomobject]@{
                step = 'retainedCleanup'
                message = $retainedCleanupWarning
            })
        }
    }

    [pscustomobject]@{
        success = $true
        complete = ($postCommitWarnings.Count -eq 0)
        coreCommitted = $true
        updaterVersion = $updaterVersion
        installedSkill = $installed
        stableCliPath = Join-Path $installed 'scripts\cpa-stack.ps1'
        stableUninstallPath = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
        previousSkill = if (Test-Path -LiteralPath $previous) { $previous } else { $null }
        registeredRoot = $registeredRoot
        launcherUpdated = $launcherUpdated
        launcherSynchronized = $launcherSynchronized
        registrationUpdated = $registrationUpdated
        legacyCanonicalAdoptionRequired = $legacyCanonicalAdoptionRequired
        retainedPrevious = if (Test-Path -LiteralPath $retained -PathType Container) { $retained } else { $null }
        cleanupWarning = $retainedCleanupWarning
        postCommitWarnings = @($postCommitWarnings.ToArray())
        fileCount = $sourceManifest.Count
    } | ConvertTo-Json -Depth 4
} catch {
    $installError = $_.Exception
    if ($coreCommitted) {
        throw "CPA skill core commit succeeded, but installer result reporting failed. The new skill was not rolled back. Error: $($installError.Message)"
    }
    $recoveryError = $null
    try {
        if ($swapped) {
            if (-not (Test-OwnedSkillDirectory -Root $installed)) {
                throw "The newly installed directory lost its ownership marker: $installed"
            }
            Move-SkillDirectoryWithRetry -SourcePath $installed -SourceKind Installed -DestinationPath $staging -DestinationKind Staging
            $swapped = $false
        }

        if ($installedAtPrevious) {
            if ($legacyMarkerAdded) {
                Remove-TransactionalLegacyMarker -Root $previous -Kind Previous -ExpectedHash $legacyMarkerHash
                $legacyMarkerAdded = $false
            } elseif ($legacyInstalledTransaction) {
                Assert-LegacySkillDirectory -Root $previous
            } elseif (-not (Test-OwnedSkillDirectory -Root $previous)) {
                throw "Previous skill directory is not safely owned: $previous"
            }
            Move-SkillDirectoryWithRetry -SourcePath $previous -SourceKind Previous -DestinationPath $installed -DestinationKind Installed
            $installedAtPrevious = $false
        } elseif ($installedAtRetiring) {
            if ($legacyMarkerAdded) {
                Remove-TransactionalLegacyMarker -Root $retiring -Kind Retiring -ExpectedHash $legacyMarkerHash
                $legacyMarkerAdded = $false
            } elseif ($legacyInstalledTransaction) {
                Assert-LegacySkillDirectory -Root $retiring
            } elseif (-not (Test-OwnedSkillDirectory -Root $retiring)) {
                throw "Retiring skill directory is not safely owned: $retiring"
            }
            Move-SkillDirectoryWithRetry -SourcePath $retiring -SourceKind Retiring -DestinationPath $installed -DestinationKind Installed
            $installedAtRetiring = $false
        }

        if ($previousAtRetained) {
            if (Test-Path -LiteralPath $previous) {
                throw "Previous-skill slot is occupied during recovery: $previous"
            }
            if (-not (Test-OwnedSkillDirectory -Root $retained)) {
                throw "Retained previous skill directory is not safely owned: $retained"
            }
            Move-SkillDirectoryWithRetry -SourcePath $retained -SourceKind Retained -DestinationPath $previous -DestinationKind Previous
            $previousAtRetained = $false
        }
    } catch {
        $recoveryError = $_.Exception
    }
    if ($null -ne $recoveryError) {
        throw "Install failed and automatic recovery could not restore the original skill slots. Original error: $($installError.Message) Recovery error: $($recoveryError.Message) No process was terminated."
    }
    throw $installError
} finally {
    $stagingCleanupError = $null
    if (Test-Path -LiteralPath $staging) {
        try {
            Remove-OwnedSkillTransactionDirectory -Path $staging -Kind Staging
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
