$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

function Invoke-InstallJson {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Update')][string]$Action,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StackRoot
    )

    $parameters = @{
        Action = $Action
        CodexHome = $CodexHome
        Json = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($StackRoot)) { $parameters.StackRoot = $StackRoot }
    $text = @(& $Script @parameters)
    return (($text | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-TestFileSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $full)) { return '<missing>' }
    return @(Get-ChildItem -Force -LiteralPath $full -Recurse -File) | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($full.Length).TrimStart('\')
            length = $_.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
            lastWriteUtcTicks = $_.LastWriteTimeUtc.Ticks
        }
    } | ConvertTo-Json -Depth 4 -Compress
}

$sourceRepo = Split-Path -Parent $PSScriptRoot
$expectedVersion = (Get-Content -Raw -LiteralPath (Join-Path $sourceRepo 'VERSION')).Trim()
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-install-compat-tests-' + [guid]::NewGuid().ToString('N'))
$stackTestParent = Join-Path $HOME ('.cpa-stack-install-compat-tests-' + [guid]::NewGuid().ToString('N'))
$codexHomeJunction = $null
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $fixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $sourceRepo `
        -DestinationRepository (Join-Path $temp 'repository') `
        -LocalAppDataRoot (Join-Path $temp 'local-app-data')
    $repo = $fixture.Repository
    $installScript = Join-Path $repo 'install.ps1'
    $uninstallScript = Join-Path $repo 'uninstall.ps1'
    . (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

    $locatorPath = Get-CpaStackRootLocatorPath
    $productionLocatorPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\root.json'
    Assert-False ([string]::Equals($locatorPath, $productionLocatorPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Compatibility tests never use the production root locator'
    Assert-True ([System.IO.Path]::GetFullPath($locatorPath).StartsWith($fixture.LocalAppData.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Compatibility tests keep state and locks inside isolated LocalApplicationData'

    Protect-CpaStackPrivateDirectory -Path $stackTestParent
    $codexHome = Join-Path $temp 'codex-home'
    $stackRoot = Join-Path $stackTestParent 'managed stack'
    Assert-True ([System.IO.Path]::GetFullPath($stackRoot).StartsWith([System.IO.Path]::GetFullPath($stackTestParent).TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Compatibility stack root stays inside its unique fixture parent'

    $usedRoots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    $unusedLetter = @(90..68 | ForEach-Object { ([char]$_).ToString() } | Where-Object { $usedRoots -notcontains $_ } | Select-Object -First 1)
    if ($unusedLetter.Count -ne 1) { throw 'Install compatibility tests require one unused drive letter.' }
    $missingDriveHome = Join-Path $temp 'missing-drive-home'
    Assert-Throws {
        [void](Invoke-InstallJson -Script $installScript -Action Update -CodexHome $missingDriveHome -StackRoot ("$($unusedLetter[0]):\CPA-Stack"))
    } 'Installer rejects a missing target drive before swapping the skill'
    Assert-False (Test-Path -LiteralPath (Join-Path $missingDriveHome 'skills\cpa-safe-upgrade')) 'Missing-drive validation leaves CodexHome untouched'

    $first = Invoke-InstallJson -Script $installScript -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 2 ([int]$first.schemaVersion) 'Installer returns schema v2'
    Assert-Equal 'install' ([string]$first.operation) 'Installer identifies the public operation'
    Assert-Equal 'Update' ([string]$first.action) 'Installer reports the requested action'
    Assert-Equal 'Changed' ([string]$first.outcome) 'First Update reports a change'
    Assert-True ([bool]$first.changed) 'First Update reports managed writes'
    Assert-True ([bool]$first.success) 'First Update succeeds'
    Assert-Equal $expectedVersion ([string]$first.sourceVersion) 'Installer reports the repository version'
    Assert-Equal ([string]$first.sourceVersion) ([string]$first.installedVersion) 'First Update installs the source version'
    Assert-Equal 'Current' ([string]$first.launcherState) 'First Update installs the current launcher contract'

    $installed = Join-Path $codexHome 'skills\cpa-safe-upgrade'
    $slotStateRoot = Join-Path $codexHome 'cpa-stack-updater'
    $slotRoot = Join-Path $slotStateRoot 'skill-slots'
    $launcher = Join-Path $stackRoot 'ops\Start-CPA-Stack.ps1'
    Assert-Equal ([System.IO.Path]::GetFullPath($launcher)) ([System.IO.Path]::GetFullPath([string]$first.launcherPath)) 'Installer returns the stable launcher bootstrap path'
    Assert-True (Test-Path -LiteralPath $launcher -PathType Leaf) 'Installer creates the stable launcher bootstrap'
    Assert-Equal ([string]$first.launcherExpectedSha256) ([string]$first.launcherActualSha256) 'Installer reports a current bootstrap hash'
    Assert-Equal ([string]$first.launcherExpectedSha256) (Get-CpaStackFileHash -Path $launcher) 'Installed bootstrap matches the rendered bootstrap contract'
    $launcherText = [System.IO.File]::ReadAllText($launcher, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($launcherText -match 'CODEX_HOME') 'Stable bootstrap locates the installed Codex skill'
    Assert-True ($launcherText -match 'cpa-stack\.ps1') 'Stable bootstrap delegates to the installed CLI'
    Assert-True (Test-Path -LiteralPath ([string]$first.stableUninstallPath) -PathType Leaf) 'Installer returns the stable uninstaller path'

    Assert-True (Test-Path -LiteralPath $slotRoot -PathType Container) 'Installer keeps rollback slots outside the discoverable skills root'
    $slotsBeforeNoChange = Get-TestFileSnapshot -Root $slotStateRoot
    $noChange = Invoke-InstallJson -Script $installScript -Action Update -CodexHome $codexHome -StackRoot $stackRoot
    Assert-Equal 2 ([int]$noChange.schemaVersion) 'NoChange Update keeps the schema v2 result contract'
    Assert-Equal 'NoChange' ([string]$noChange.outcome) 'Repeated Update reports NoChange'
    Assert-False ([bool]$noChange.changed) 'NoChange Update reports zero writes'
    Assert-Equal $slotsBeforeNoChange (Get-TestFileSnapshot -Root $slotStateRoot) 'NoChange does not rewrite the protected rollback-slot state'

    foreach ($relative in @('runtime\runtime-sentinel.txt', 'data\manager-sentinel.txt')) {
        $path = Join-Path $stackRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -LiteralPath $path -Value ('preserve-' + $relative) -Encoding ASCII
    }
    $instanceMarker = Read-CpaStackJson -Path (Join-Path $stackRoot '.cpa-stack-instance.json')
    $stateRoot = Join-Path $stackRoot 'state'
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $stateRoot
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        instanceId = [string]$instanceMarker.instanceId
        canonicalRoot = $stackRoot
    }) -Path (Join-Path $stateRoot 'current.json')
    Protect-CpaStackSecretFile -Path (Join-Path $stateRoot 'current.json')
    $stackBeforeSafetyFailures = Get-TestFileSnapshot -Root $stackRoot

    $unprotectedLocatorAcl = Get-CpaStackFileSystemAcl -Path $locatorPath
    $unprotectedLocatorAcl.SetAccessRuleProtection($false, $true)
    Set-CpaStackFileSystemAcl -Path $locatorPath -Acl $unprotectedLocatorAcl
    $untrustedLocatorHome = Join-Path $temp 'untrusted-locator-home'
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $installScript -Action Update -CodexHome $untrustedLocatorHome -StackRoot '')
    } 'root locator ACL is not protected' 'Installer refuses an unprotected registered-root locator'
    Assert-False (Test-Path -LiteralPath (Join-Path $untrustedLocatorHome 'skills\cpa-safe-upgrade')) 'Untrusted locator rejection happens before installing the skill'
    Set-CpaStackRegisteredRoot -ControlRoot $stackRoot

    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        root = [System.IO.Path]::GetPathRoot($temp)
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path $locatorPath
    Protect-CpaStackSecretFile -Path $locatorPath
    $unsafeLocatorHome = Join-Path $temp 'unsafe-locator-home'
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $installScript -Action Update -CodexHome $unsafeLocatorHome -StackRoot '')
    } 'Registered CPA stack root failed safety validation' 'Installer does not trust an arbitrary path from a protected locator'
    Assert-False (Test-Path -LiteralPath (Join-Path $unsafeLocatorHome 'skills\cpa-safe-upgrade')) 'Unsafe registered root rejection happens before installing the skill'
    Set-CpaStackRegisteredRoot -ControlRoot $stackRoot

    $installedHashBeforeAclDrift = Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')
    $opsPath = Join-Path $stackRoot 'ops'
    $driftedOpsAcl = Get-CpaStackFileSystemAcl -Path $opsPath
    $unexpectedRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$driftedOpsAcl.AddAccessRule($unexpectedRule)
    Set-CpaStackFileSystemAcl -Path $opsPath -Acl $driftedOpsAcl
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $installScript -Action Update -CodexHome $codexHome -StackRoot '')
    } 'unexpected identity' 'Parameterless Update rejects canonical ops ACL drift before swapping the skill'
    Assert-Equal $installedHashBeforeAclDrift (Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')) 'ACL preflight failure leaves the installed skill unchanged'
    Protect-CpaStackPrivateDirectory -Path $opsPath

    $junctionTargetHome = Join-Path $temp 'junction-target-home'
    $junctionInstalled = Join-Path $junctionTargetHome 'skills\cpa-safe-upgrade'
    New-Item -ItemType Directory -Force -Path $junctionInstalled | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $junctionInstalled $item.Name) -Recurse -Force
    }
    $junctionTargetBefore = Get-TestFileSnapshot -Root $junctionTargetHome
    $junctionHome = Join-Path $stackTestParent 'junction-codex-home'
    $codexHomeJunction = New-Item -ItemType Junction -Path $junctionHome -Target $junctionTargetHome
    Assert-ThrowsMatch {
        [void](Invoke-InstallJson -Script $installScript -Action Update -CodexHome $junctionHome -StackRoot $stackRoot)
    } 'reparse point' 'Installer rejects a CodexHome path that crosses an ancestor junction before writing'
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $junctionHome -Yes
    } 'reparse point' 'Uninstaller rejects a CodexHome path that crosses an ancestor junction before deleting'
    Assert-Equal $junctionTargetBefore (Get-TestFileSnapshot -Root $junctionTargetHome) 'Junction rejection preserves the external target byte-for-byte'
    [System.IO.Directory]::Delete($codexHomeJunction.FullName)
    $codexHomeJunction = $null

    $uninstallPrevious = Join-Path $slotRoot 'previous'
    New-Item -ItemType Directory -Path $uninstallPrevious | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $uninstallPrevious $item.Name) -Recurse -Force
    }
    Protect-CpaStackPrivateTree -Root $uninstallPrevious

    $stableUninstall = [string]$first.stableUninstallPath

    foreach ($pendingName in @('install.pending.json', 'legacy-previous-relocation.pending.json')) {
        $pendingPath = Join-Path $slotRoot $pendingName
        Set-Content -LiteralPath $pendingPath -Value '{}' -Encoding UTF8
        Protect-CpaStackSecretFile -Path $pendingPath
        $codexBeforePendingBlock = Get-TestFileSnapshot -Root $codexHome
        Assert-ThrowsMatch {
            & $stableUninstall -CodexHome $codexHome -Yes
        } 'Pending installer recovery must complete' "Uninstaller refuses pending transaction journal $pendingName"
        Assert-Equal $codexBeforePendingBlock (Get-TestFileSnapshot -Root $codexHome) "Pending journal $pendingName blocks uninstall with zero CodexHome writes"
        Assert-Equal $stackBeforeSafetyFailures (Get-TestFileSnapshot -Root $stackRoot) "Pending journal $pendingName leaves StackRoot unchanged"
        Remove-Item -LiteralPath $pendingPath -Force
    }

    $foreignClaim = Join-Path $slotRoot ('retained-' + [guid]::NewGuid().ToString('N') + '.claim.json')
    Set-Content -LiteralPath $foreignClaim -Value '{}' -Encoding UTF8
    Protect-CpaStackSecretFile -Path $foreignClaim
    $codexBeforeForeignClaimBlock = Get-TestFileSnapshot -Root $codexHome
    Assert-ThrowsMatch {
        & $stableUninstall -CodexHome $codexHome -Yes
    } 'unclaimed or foreign artifact' 'Uninstaller refuses a foreign transaction claim before removing owned skills'
    Assert-Equal $codexBeforeForeignClaimBlock (Get-TestFileSnapshot -Root $codexHome) 'Foreign transaction claim blocks uninstall with zero CodexHome writes'
    Assert-Equal $stackBeforeSafetyFailures (Get-TestFileSnapshot -Root $stackRoot) 'Foreign transaction claim leaves StackRoot unchanged'
    Remove-Item -LiteralPath $foreignClaim -Force

    $uninstallLock = [System.IO.File]::Open(
        (Join-Path $uninstallPrevious 'SKILL.md'),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        Assert-ThrowsMatch {
            & $stableUninstall -CodexHome $codexHome -Yes
        } 'Close editors or terminals' 'Uninstaller refuses a locked rollback slot before deleting any owned directory'
    } finally {
        $uninstallLock.Dispose()
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $installed '.cpa-stack-updater-installed.json') -PathType Leaf) 'Failed uninstall preflight preserves the active ownership marker'
    Assert-True (Test-Path -LiteralPath (Join-Path $uninstallPrevious '.cpa-stack-updater-installed.json') -PathType Leaf) 'Failed uninstall preflight preserves the rollback-slot ownership marker'
    $uninstall = (& $stableUninstall -CodexHome $codexHome -Yes) | ConvertFrom-Json
    Assert-True ([bool]$uninstall.success) 'Uninstaller reports success after the lock is released'
    Assert-False ([bool]$uninstall.stackDataTouched) 'Uninstaller reports that stack data was not touched'
    Assert-False (Test-Path -LiteralPath $installed) 'Uninstaller removes the owned active skill'
    Assert-False (Test-Path -LiteralPath $uninstallPrevious) 'Uninstaller removes the owned rollback slot'
    Assert-False (Test-Path -LiteralPath $slotRoot) 'Uninstaller removes the empty protected rollback-slot root'
    Assert-False (Test-Path -LiteralPath $slotStateRoot) 'Uninstaller removes the empty updater slot-state root'
    Assert-Equal $stackBeforeSafetyFailures (Get-TestFileSnapshot -Root $stackRoot) 'Successful skill uninstall leaves StackRoot byte- and timestamp-identical'

    $legacyCodexHome = Join-Path $temp 'legacy-previous-codex-home'
    $legacyPrevious = Join-Path $legacyCodexHome 'skills\cpa-safe-upgrade.previous'
    New-Item -ItemType Directory -Path $legacyPrevious -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $repo 'skills\cpa-safe-upgrade') -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $legacyPrevious $item.Name) -Recurse -Force
    }
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        product = 'cpa-stack-updater'
        skill = 'cpa-safe-upgrade'
    }) -Path (Join-Path $legacyPrevious '.cpa-stack-updater-installed.json')
    Protect-CpaStackPrivateTree -Root $legacyPrevious
    $legacyUninstall = (& $uninstallScript -CodexHome $legacyCodexHome -Yes) | ConvertFrom-Json
    Assert-True ([bool]$legacyUninstall.success) 'Uninstaller remains compatible with the legacy discoverable previous slot'
    Assert-False (Test-Path -LiteralPath $legacyPrevious) 'Uninstaller removes the owned legacy previous slot'
    Assert-Equal $stackBeforeSafetyFailures (Get-TestFileSnapshot -Root $stackRoot) 'Legacy previous-slot uninstall leaves StackRoot unchanged'

    New-Item -ItemType Directory -Force -Path $installed | Out-Null
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $codexHome -Yes
    } 'Refusing to remove an unowned skill directory' 'Uninstaller rejects an empty fixed target without an ownership marker'
    Assert-True (Test-Path -LiteralPath $installed -PathType Container) 'Rejected empty unowned target is preserved'
    $unownedSentinel = Join-Path $installed 'keep.txt'
    Set-Content -LiteralPath $unownedSentinel -Value 'keep' -Encoding ASCII
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $codexHome -Yes
    } 'Refusing to remove an unowned skill directory' 'Uninstaller rejects a directory without its ownership marker'
    Assert-True (Test-Path -LiteralPath $unownedSentinel -PathType Leaf) 'Rejected unowned data is preserved'

    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        product = 'not-cpa-stack-updater'
        skill = 'cpa-safe-upgrade'
    }) -Path (Join-Path $installed '.cpa-stack-updater-installed.json')
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $codexHome -Yes
    } 'Skill ownership marker is invalid' 'Uninstaller rejects an invalid ownership marker'
    Assert-True (Test-Path -LiteralPath $unownedSentinel -PathType Leaf) 'A directory with an invalid marker is preserved'

    $sharedLock = Enter-CpaStackOperationLock
    try {
        Assert-Equal 'CPAStackSafeOperation.lock' ([System.IO.Path]::GetFileName($sharedLock.Name)) 'Installer and uninstaller use the shared operation lock'
        Assert-ThrowsMatch {
            [void](Invoke-InstallJson `
                -Script $installScript `
                -Action Update `
                -CodexHome (Join-Path $temp 'shared-lock-install-home') `
                -StackRoot $stackRoot)
        } 'Another CPA stack operation is already running' 'Installer participates in the shared stack operation lock'
        Assert-ThrowsMatch {
            & $uninstallScript -CodexHome (Join-Path $temp 'shared-lock-uninstall-home') -Yes
        } 'Another CPA stack operation is already running' 'Uninstaller participates in the shared stack operation lock'
    } finally {
        Exit-CpaStackOperationLock -Mutex $sharedLock
    }

    Assert-Equal $stackBeforeSafetyFailures (Get-TestFileSnapshot -Root $stackRoot) 'Installer and uninstaller safety failures leave stack runtime and data byte- and timestamp-identical'
} finally {
    if ($codexHomeJunction -and (Test-Path -LiteralPath $codexHomeJunction.FullName)) {
        [System.IO.Directory]::Delete($codexHomeJunction.FullName)
    }
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
    if (Test-Path -LiteralPath $stackTestParent) { Remove-TestPathWithRetry -Path $stackTestParent }
}

'Install compatibility and safety tests passed.'
