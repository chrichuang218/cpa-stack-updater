$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$sourceRepo = Split-Path -Parent $PSScriptRoot
$expectedVersion = (Get-Content -Raw -LiteralPath (Join-Path $sourceRepo 'VERSION')).Trim()
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-install-tests-' + [guid]::NewGuid().ToString('N'))
$stackTestParent = Join-Path $HOME ('.cpa-stack-install-tests-' + [guid]::NewGuid().ToString('N'))
$fixtureRepo = Join-Path $temp 'repository'
$fixtureLocalAppData = Join-Path $temp 'local-app-data'
$codexHomeJunction = $null
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $fixture = New-CpaStackUpdaterTestFixture -SourceRepository $sourceRepo -DestinationRepository $fixtureRepo -LocalAppDataRoot $fixtureLocalAppData
    $repo = $fixture.Repository
    $installScript = Join-Path $repo 'install.ps1'
    $uninstallScript = Join-Path $repo 'uninstall.ps1'
    $commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
    . $commonPath
    $locatorPath = Get-CpaStackRootLocatorPath
    $productionLocatorPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\root.json'
    Assert-False ([string]::Equals($locatorPath, $productionLocatorPath, [System.StringComparison]::OrdinalIgnoreCase)) 'Install tests never use the production root locator'
    Assert-True ([System.IO.Path]::GetFullPath($locatorPath).StartsWith($fixture.LocalAppData + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Install tests keep the root locator inside isolated LocalApplicationData'
    Protect-CpaStackPrivateDirectory -Path $stackTestParent
    $usedRoots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    $unusedLetter = @('Q', 'Y', 'X', 'W') | Where-Object { $usedRoots -notcontains $_ } | Select-Object -First 1
    if ($unusedLetter) {
        $invalidHome = Join-Path $temp 'invalid-root-home'
        Assert-Throws {
            & $installScript -CodexHome $invalidHome -StackRoot ("${unusedLetter}:\CPA-Stack")
        } 'Installer rejects a missing target drive before swapping the skill'
        Assert-False (Test-Path -LiteralPath (Join-Path $invalidHome 'skills\cpa-safe-upgrade')) 'Failed root validation leaves no installed skill'
    }

    $lockedHome = Join-Path $temp 'locked-legacy-home'
    $lockedSkillsRoot = Join-Path $lockedHome 'skills'
    $lockedInstalled = Join-Path $lockedSkillsRoot 'cpa-safe-upgrade'
    $lockedPrevious = Join-Path $lockedSkillsRoot 'cpa-safe-upgrade.previous'
    $sourceSkill = Join-Path $repo 'skills\cpa-safe-upgrade'
    New-Item -ItemType Directory -Force -Path $lockedSkillsRoot | Out-Null
    Copy-Item -LiteralPath $sourceSkill -Destination $lockedInstalled -Recurse
    Copy-Item -LiteralPath $sourceSkill -Destination $lockedPrevious -Recurse
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        product = 'cpa-stack-updater'
        skill = 'cpa-safe-upgrade'
        updaterVersion = $expectedVersion
        installedAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path (Join-Path $lockedPrevious '.cpa-stack-updater-installed.json')
    $previousSentinel = Join-Path $lockedPrevious 'previous-sentinel.txt'
    Set-Content -LiteralPath $previousSentinel -Value 'preserve-existing-previous' -Encoding ASCII

    $legacyLock = [System.IO.File]::Open(
        (Join-Path $lockedInstalled 'SKILL.md'),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        Assert-ThrowsMatch {
            & $installScript -CodexHome $lockedHome -StackRoot (Join-Path $temp 'locked managed root')
        } 'Close editors or terminals' 'Installer gives actionable guidance when an editor prevents replacing the legacy skill'
        Assert-False (Test-Path -LiteralPath (Join-Path $lockedInstalled '.cpa-stack-updater-installed.json')) 'A failed locked legacy install leaves no ownership marker behind'
        Assert-True (Test-Path -LiteralPath $previousSentinel -PathType Leaf) 'A failed locked legacy install preserves the existing previous slot'
        Assert-Equal 'preserve-existing-previous' (Get-Content -Raw -LiteralPath $previousSentinel).Trim() 'The existing previous slot is not changed before the installed skill can move'
    } finally {
        $legacyLock.Dispose()
    }

    $unlockedResult = (& $installScript -CodexHome $lockedHome -StackRoot (Join-Path $temp 'locked managed root')) | ConvertFrom-Json
    Assert-True ([bool]$unlockedResult.success) 'Installer succeeds after the editor lock is released'
    Assert-True (Test-Path -LiteralPath (Join-Path $lockedInstalled '.cpa-stack-updater-installed.json') -PathType Leaf) 'Successful retry installs an owned skill'
    Assert-True (Test-Path -LiteralPath (Join-Path $lockedPrevious '.cpa-stack-updater-installed.json') -PathType Leaf) 'Successful retry claims the retired legacy skill only after it moved'
    $leftoverTransactionSlots = @(Get-ChildItem -LiteralPath $lockedSkillsRoot -Directory -Force | Where-Object { $_.Name -match '^cpa-safe-upgrade\.(?:staging|retained|retiring)-' })
    Assert-Equal 0 $leftoverTransactionSlots.Count 'Successful retry leaves no transaction directories'

    $customStackRoot = Join-Path $stackTestParent 'managed stack root'
    $resultText = & $installScript -CodexHome $temp -StackRoot $customStackRoot
    $result = $resultText | ConvertFrom-Json
    Assert-True ([bool]$result.success) 'Installer reports success'
    Assert-Equal $expectedVersion $result.updaterVersion 'Installer reports the updater version'
    Assert-Equal ([System.IO.Path]::GetFullPath($customStackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$result.registeredRoot).TrimEnd('\')) 'Installer registers a valid custom stack root'
    $registeredLocator = Read-CpaStackJson -Path $locatorPath
    Assert-Equal ([System.IO.Path]::GetFullPath($customStackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$registeredLocator.root).TrimEnd('\')) 'Custom stack root is written to the protected locator'
    $installed = Join-Path $temp 'skills\cpa-safe-upgrade'
    Assert-True (Test-Path -LiteralPath (Join-Path $installed 'SKILL.md') -PathType Leaf) 'Skill is installed'
    Assert-True (Test-Path -LiteralPath (Join-Path $installed 'scripts\cpa-stack.ps1') -PathType Leaf) 'CLI is installed with skill'
    Assert-Equal (Join-Path $installed 'scripts\cpa-stack.ps1') ([string]$result.stableCliPath) 'Installer returns the stable human CLI path'
    Assert-True (Test-Path -LiteralPath ([string]$result.stableUninstallPath) -PathType Leaf) 'Installer returns an installed uninstaller path'
    $markerPath = Join-Path $installed '.cpa-stack-updater-installed.json'
    Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) 'Installer writes an ownership marker'
    $marker = Read-CpaStackJson -Path $markerPath
    Assert-Equal 1 $marker.schemaVersion 'Ownership marker schema is stable'
    Assert-Equal 'cpa-stack-updater' $marker.product 'Ownership marker names the product'
    Assert-Equal 'cpa-safe-upgrade' $marker.skill 'Ownership marker names the skill'
    Assert-Equal $expectedVersion $marker.updaterVersion 'Ownership marker records the updater version'

    $staleRetained = Join-Path $temp 'skills\cpa-safe-upgrade.retained-00000000000000000000000000000001'
    New-Item -ItemType Directory -Path $staleRetained | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $staleRetained $item.Name) -Recurse -Force
    }
    $staleMarkerPath = Join-Path $staleRetained '.cpa-stack-updater-installed.json'
    Assert-True (Test-Path -LiteralPath $staleMarkerPath -PathType Leaf) 'Synthetic retained slot copies its ownership marker'
    $staleMarker = Read-CpaStackJson -Path $staleMarkerPath
    Assert-Equal 'cpa-stack-updater' $staleMarker.product 'Synthetic retained slot has a valid product marker'
    Assert-Equal 'cpa-safe-upgrade' $staleMarker.skill 'Synthetic retained slot has a valid skill marker'
    $installedHashBeforeStaleCleanup = Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')
    $staleRetainedLock = [System.IO.File]::Open(
        (Join-Path $staleRetained 'SKILL.md'),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        Assert-ThrowsMatch {
            & $installScript -CodexHome $temp -StackRoot $customStackRoot
        } 'stale retained transaction directory' 'Installer blocks before swap when an older retained slot is still locked'
    } finally {
        $staleRetainedLock.Dispose()
    }
    Assert-Equal $installedHashBeforeStaleCleanup (Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')) 'Failed stale-slot cleanup leaves the active skill unchanged'
    Assert-False (Test-Path -LiteralPath (Join-Path $temp 'skills\cpa-safe-upgrade.previous')) 'Failed stale-slot cleanup does not rotate the rollback slot'
    Assert-True (Test-Path -LiteralPath $staleMarkerPath -PathType Leaf) 'Partial stale-slot cleanup preserves ownership evidence for a safe retry'
    $staleCleanupRetry = (& $installScript -CodexHome $temp -StackRoot $customStackRoot) | ConvertFrom-Json
    Assert-True ([bool]$staleCleanupRetry.success) 'Retry succeeds after the stale retained slot is unlocked'
    Assert-True ([bool]$staleCleanupRetry.complete) 'Retry reports complete only after all stale retained slots are gone'
    Assert-False (Test-Path -LiteralPath $staleRetained) 'Retry removes the stale retained slot'

    $emptyRetained = Join-Path $temp 'skills\cpa-safe-upgrade.retained-00000000000000000000000000000003'
    New-Item -ItemType Directory -Path $emptyRetained | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $emptyRetained $item.Name) -Recurse -Force
    }
    $installedHashBeforeDirectoryLock = Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')
    $retainedDirectoryHandle = Open-TestDirectoryWithoutDeleteShare -Path $emptyRetained
    try {
        Assert-ThrowsMatch {
            & $installScript -CodexHome $temp -StackRoot $customStackRoot
        } 'stale retained transaction directory' 'Installer reports a directory-handle cleanup failure before swap'
    } finally {
        $retainedDirectoryHandle.Dispose()
    }
    Assert-Equal $installedHashBeforeDirectoryLock (Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')) 'Directory-handle cleanup failure leaves the active skill unchanged'
    Assert-True (Test-Path -LiteralPath $emptyRetained -PathType Container) 'Locked transaction root remains for retry'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $emptyRetained -Force).Count) 'Failed final directory removal leaves only an empty fixed transaction root'
    $emptyCleanupRetry = (& $installScript -CodexHome $temp -StackRoot $customStackRoot) | ConvertFrom-Json
    Assert-True ([bool]$emptyCleanupRetry.complete) 'Retry safely removes an empty fixed transaction root'
    Assert-False (Test-Path -LiteralPath $emptyRetained) 'Empty transaction root is gone after retry'

    $unprotectedLocatorAcl = Get-Acl -LiteralPath $locatorPath
    $unprotectedLocatorAcl.SetAccessRuleProtection($false, $true)
    Set-Acl -LiteralPath $locatorPath -AclObject $unprotectedLocatorAcl
    $untrustedLocatorHome = Join-Path $temp 'untrusted-locator-home'
    Assert-ThrowsMatch {
        & $installScript -CodexHome $untrustedLocatorHome
    } 'root locator ACL is not protected' 'Installer refuses an unprotected registered-root locator'
    Assert-False (Test-Path -LiteralPath (Join-Path $untrustedLocatorHome 'skills\cpa-safe-upgrade')) 'Untrusted locator rejection happens before installing the skill'

    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        root = [System.IO.Path]::GetPathRoot($temp)
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path $locatorPath
    Protect-CpaStackSecretFile -Path $locatorPath
    $unsafeLocatorHome = Join-Path $temp 'unsafe-locator-home'
    Assert-ThrowsMatch {
        & $installScript -CodexHome $unsafeLocatorHome
    } 'Registered CPA stack root failed safety validation' 'Installer does not trust an arbitrary path from a protected locator'
    Assert-False (Test-Path -LiteralPath (Join-Path $unsafeLocatorHome 'skills\cpa-safe-upgrade')) 'Unsafe registered root rejection happens before installing the skill'
    Set-CpaStackRegisteredRoot -ControlRoot $customStackRoot

    New-Item -ItemType Directory -Force -Path (Join-Path $customStackRoot 'state') | Out-Null
    Write-CpaStackJson -Value ([ordered]@{ schemaVersion = 1; canonicalRoot = $customStackRoot }) -Path (Join-Path $customStackRoot 'state\current.json')
    $legacyInstallResult = (& $installScript -CodexHome $temp) | ConvertFrom-Json
    Assert-True ([bool]$legacyInstallResult.success) 'Installer accepts an earlier canonical root for later transactional adoption'
    Assert-Equal ([System.IO.Path]::GetFullPath($customStackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$legacyInstallResult.registeredRoot).TrimEnd('\')) 'Parameterless install safely resolves the protected registered root'
    Assert-True ([bool]$legacyInstallResult.legacyCanonicalAdoptionRequired) 'Installer reports that the earlier canonical root still needs adoption'
    Assert-False ([bool]$legacyInstallResult.launcherUpdated) 'Installer does not rewrite an unadopted canonical launcher'

    $stackInstanceId = [guid]::NewGuid().ToString('N')
    Write-CpaStackJson -Value ([ordered]@{ schemaVersion = 1; instanceId = $stackInstanceId; root = $customStackRoot }) -Path (Join-Path $customStackRoot '.cpa-stack-instance.json')
    Write-CpaStackJson -Value ([ordered]@{ schemaVersion = 1; instanceId = $stackInstanceId; canonicalRoot = $customStackRoot }) -Path (Join-Path $customStackRoot 'state\current.json')
    foreach ($directory in @('ops', 'state')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $customStackRoot $directory) | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $customStackRoot 'ops\Start-CPA-Stack.ps1') -Value '# stale synthetic launcher' -Encoding ASCII
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        instanceId = $stackInstanceId
        canonicalRoot = $customStackRoot
    }) -Path (Join-Path $customStackRoot 'state\current.json')

    Protect-CpaStackPrivateDirectory -Path $customStackRoot
    Protect-CpaStackPrivateDirectory -Path (Join-Path $customStackRoot 'ops')
    Protect-CpaStackPrivateDirectory -Path (Join-Path $customStackRoot 'state')
    foreach ($protectedFile in @(
        (Join-Path $customStackRoot '.cpa-stack-instance.json'),
        (Join-Path $customStackRoot 'state\current.json'),
        (Join-Path $customStackRoot 'ops\Start-CPA-Stack.ps1')
    )) {
        Protect-CpaStackSecretFile -Path $protectedFile
    }

    $stackParent = Split-Path -Parent $customStackRoot
    Protect-CpaStackPrivateDirectory -Path $stackParent
    $stackParentSddl = (Get-Acl -LiteralPath $stackParent).Sddl
    $installedHashBeforeAncestorDrift = Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')
    try {
        $driftedParentAcl = Get-Acl -LiteralPath $stackParent
        $parentReplacementRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
            [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$driftedParentAcl.AddAccessRule($parentReplacementRule)
        Set-Acl -LiteralPath $stackParent -AclObject $driftedParentAcl
        Assert-ThrowsMatch {
            & $installScript -CodexHome $temp
        } 'replace descendants' 'Parameterless update rejects a parent ACL that lets Everyone replace the canonical root'
        Assert-Equal $installedHashBeforeAncestorDrift (Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')) 'Ancestor ACL preflight failure leaves the installed skill unchanged'
    } finally {
        $restoredParentAcl = Get-Acl -LiteralPath $stackParent
        $restoredParentAcl.SetSecurityDescriptorSddlForm($stackParentSddl)
        Set-Acl -LiteralPath $stackParent -AclObject $restoredParentAcl
    }

    $installedHashBeforeAclDrift = Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')
    $opsPath = Join-Path $customStackRoot 'ops'
    $driftedOpsAcl = Get-Acl -LiteralPath $opsPath
    $unexpectedRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$driftedOpsAcl.AddAccessRule($unexpectedRule)
    Set-Acl -LiteralPath $opsPath -AclObject $driftedOpsAcl
    Assert-ThrowsMatch {
        & $installScript -CodexHome $temp
    } 'unexpected identity' 'Parameterless update rejects canonical ops ACL drift before swapping the skill'
    Assert-Equal $installedHashBeforeAclDrift (Get-CpaStackFileHash -Path (Join-Path $installed 'SKILL.md')) 'ACL preflight failure leaves the installed skill unchanged'
    Protect-CpaStackPrivateDirectory -Path $opsPath

    $updateResult = (& $installScript -CodexHome $temp) | ConvertFrom-Json
    Assert-True ([bool]$updateResult.success) 'Installer can atomically update an owned skill'
    Assert-Equal ([System.IO.Path]::GetFullPath($customStackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$updateResult.registeredRoot).TrimEnd('\')) 'A later parameterless install keeps using the protected registered root'
    Assert-True ([bool]$updateResult.launcherUpdated) 'A later parameterless skill update refreshes a stale canonical launcher'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $installed 'scripts\Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path (Join-Path $customStackRoot 'ops\Start-CPA-Stack.ps1')) 'Canonical launcher matches the newly installed skill'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'skills\cpa-safe-upgrade.previous\.cpa-stack-updater-installed.json') -PathType Leaf) 'Atomic update retains one owned previous skill'

    $installedSkillPath = Join-Path $installed 'SKILL.md'
    $oldInstalledText = [System.IO.File]::ReadAllText($installedSkillPath, [System.Text.UTF8Encoding]::new($false, $true)) + "`r`n# synthetic previous skill`r`n"
    [System.IO.File]::WriteAllText($installedSkillPath, $oldInstalledText, [System.Text.UTF8Encoding]::new($false))
    $oldInstalledHash = Get-CpaStackFileHash -Path $installedSkillPath
    $canonicalLauncher = Join-Path $customStackRoot 'ops\Start-CPA-Stack.ps1'
    Set-Content -LiteralPath $canonicalLauncher -Value '# stale before post-commit locator failure' -Encoding ASCII
    Protect-CpaStackSecretFile -Path $canonicalLauncher
    $locatorBeforeLockedUpdate = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($locatorPath))
    $locatorLock = [System.IO.File]::Open(
        $locatorPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $lockedLocatorResult = (& $installScript -CodexHome $temp -StackRoot $customStackRoot) | ConvertFrom-Json
    } finally {
        $locatorLock.Dispose()
    }
    Assert-True ([bool]$lockedLocatorResult.success) 'Locator write failure does not roll back the committed skill'
    Assert-False ([bool]$lockedLocatorResult.complete) 'Locator write failure reports an incomplete post-commit result'
    Assert-True ([bool]$lockedLocatorResult.coreCommitted) 'Locator write failure reports that the core skill commit succeeded'
    Assert-True ([bool]$lockedLocatorResult.launcherSynchronized) 'Launcher synchronization completes before the locked locator update'
    Assert-False ([bool]$lockedLocatorResult.registrationUpdated) 'Locked locator reports that registration was not updated'
    Assert-True (@($lockedLocatorResult.postCommitWarnings | Where-Object { $_.step -ceq 'registration' }).Count -eq 1) 'Locked locator returns a structured registration warning'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $repo 'skills\cpa-safe-upgrade\SKILL.md')) (Get-CpaStackFileHash -Path $installedSkillPath) 'Core commit leaves the newly installed skill active'
    Assert-Equal $oldInstalledHash (Get-CpaStackFileHash -Path (Join-Path $temp 'skills\cpa-safe-upgrade.previous\SKILL.md')) 'Previous slot contains the skill that was active before the core commit'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $installed 'scripts\Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path $canonicalLauncher) 'Post-commit launcher matches the new skill even when registration fails'
    Assert-Equal $locatorBeforeLockedUpdate ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($locatorPath))) 'Locked locator content remains unchanged'

    $junctionTargetHome = Join-Path $temp 'junction-target-home'
    $junctionInstalled = Join-Path $junctionTargetHome 'skills\cpa-safe-upgrade'
    New-Item -ItemType Directory -Force -Path $junctionInstalled | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $junctionInstalled $item.Name) -Recurse -Force
    }
    $junctionMarkerHash = Get-CpaStackFileHash -Path (Join-Path $junctionInstalled '.cpa-stack-updater-installed.json')
    $junctionHome = Join-Path $stackTestParent 'junction-codex-home'
    $codexHomeJunction = New-Item -ItemType Junction -Path $junctionHome -Target $junctionTargetHome
    Assert-ThrowsMatch {
        & $installScript -CodexHome $junctionHome -StackRoot $customStackRoot
    } 'reparse point' 'Installer rejects a CodexHome path that crosses an ancestor junction before writing'
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $junctionHome -Yes
    } 'reparse point' 'Uninstaller rejects a CodexHome path that crosses an ancestor junction before deleting'
    Assert-Equal $junctionMarkerHash (Get-CpaStackFileHash -Path (Join-Path $junctionInstalled '.cpa-stack-updater-installed.json')) 'Junction rejection preserves the external target byte-for-byte'
    [System.IO.Directory]::Delete($codexHomeJunction.FullName)
    $codexHomeJunction = $null

    $uninstallRetained = Join-Path $temp 'skills\cpa-safe-upgrade.retained-00000000000000000000000000000002'
    New-Item -ItemType Directory -Path $uninstallRetained | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $installed -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $uninstallRetained $item.Name) -Recurse -Force
    }
    $stableUninstall = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
    $uninstallLock = [System.IO.File]::Open(
        (Join-Path $uninstallRetained 'SKILL.md'),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        Assert-ThrowsMatch {
            & $stableUninstall -CodexHome $temp -Yes
        } 'Close editors or terminals' 'Uninstaller refuses a locked transaction slot before deleting any owned directory'
    } finally {
        $uninstallLock.Dispose()
    }
    Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) 'Failed uninstall preflight preserves the active skill marker'
    Assert-True (Test-Path -LiteralPath (Join-Path $uninstallRetained '.cpa-stack-updater-installed.json') -PathType Leaf) 'Failed uninstall preflight preserves the retained marker'
    $uninstallText = & $stableUninstall -CodexHome $temp -Yes
    $uninstall = $uninstallText | ConvertFrom-Json
    Assert-True ([bool]$uninstall.success) 'Uninstaller reports success'
    Assert-False (Test-Path -LiteralPath $installed) 'Skill is removed'
    Assert-False (Test-Path -LiteralPath $uninstallRetained) 'Uninstaller removes an owned retained transaction slot'
    Assert-False ([bool]$uninstall.stackDataTouched) 'Uninstaller never touches stack data'

    New-Item -ItemType Directory -Force -Path $installed | Out-Null
    $sentinel = Join-Path $installed 'keep.txt'
    Set-Content -LiteralPath $sentinel -Value 'keep' -Encoding ASCII
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $temp -Yes
    } 'Refusing to remove an unowned skill directory' 'Uninstaller rejects a directory without its ownership marker'
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) 'Rejected unowned data is preserved'

    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        product = 'not-cpa-stack-updater'
        skill = 'cpa-safe-upgrade'
    }) -Path $markerPath
    Assert-ThrowsMatch {
        & $uninstallScript -CodexHome $temp -Yes
    } 'Skill ownership marker is invalid' 'Uninstaller rejects an invalid ownership marker'
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) 'A directory with an invalid marker is preserved'

    Remove-Item -LiteralPath $installed -Recurse -Force
    New-Item -ItemType Directory -Force -Path $installed | Out-Null
    Set-Content -LiteralPath $sentinel -Value 'keep' -Encoding ASCII
    Assert-ThrowsMatch {
        & $installScript -CodexHome $temp
    } 'Refusing to replace an unowned directory' 'Installer rejects an unrelated directory without an ownership marker'
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) 'Installer preserves a rejected unowned directory'
    Remove-Item -LiteralPath $installed -Recurse -Force

    $recoveryFixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $sourceRepo `
        -DestinationRepository (Join-Path $temp 'recovery-fixture') `
        -LocalAppDataRoot (Join-Path $temp 'recovery-local-app-data')
    $recoveryInstall = Join-Path $recoveryFixture.Repository 'install.ps1'
    $recoveryHome = Join-Path $temp 'recovery-home'
    $recoveryRoot = Join-Path $stackTestParent 'recovery managed root'
    [void]((& $recoveryInstall -CodexHome $recoveryHome -StackRoot $recoveryRoot) | ConvertFrom-Json)
    $recoveryInstalled = Join-Path $recoveryHome 'skills\cpa-safe-upgrade'
    [System.IO.File]::AppendAllText((Join-Path $recoveryInstalled 'SKILL.md'), "`r`n# synthetic first generation`r`n", [System.Text.UTF8Encoding]::new($false))
    [void]((& $recoveryInstall -CodexHome $recoveryHome -StackRoot $recoveryRoot) | ConvertFrom-Json)
    $recoveryPrevious = Join-Path $recoveryHome 'skills\cpa-safe-upgrade.previous'
    [System.IO.File]::AppendAllText((Join-Path $recoveryInstalled 'SKILL.md'), "`r`n# synthetic second generation`r`n", [System.Text.UTF8Encoding]::new($false))
    $expectedInstalledHash = Get-CpaStackFileHash -Path (Join-Path $recoveryInstalled 'SKILL.md')
    $expectedPreviousHash = Get-CpaStackFileHash -Path (Join-Path $recoveryPrevious 'SKILL.md')
    $failureNeedle = '    Move-SkillDirectoryWithRetry -SourcePath $staging -SourceKind Staging -DestinationPath $installed -DestinationKind Installed'
    $failureInstallerText = [System.IO.File]::ReadAllText($recoveryInstall, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-Equal 1 ([regex]::Matches($failureInstallerText, [regex]::Escape($failureNeedle)).Count) 'Failure injection targets exactly one pre-core-commit seam'
    $failureReplacement = "    if (`$env:CPA_STACK_TEST_FAIL_BEFORE_CORE_COMMIT -ceq '1') { throw 'synthetic pre-core-commit failure' }`r`n$failureNeedle"
    $failureInstallerText = $failureInstallerText.Replace($failureNeedle, $failureReplacement)
    [System.IO.File]::WriteAllText($recoveryInstall, $failureInstallerText, [System.Text.UTF8Encoding]::new($false))
    $previousFailurePoint = [Environment]::GetEnvironmentVariable('CPA_STACK_TEST_FAIL_BEFORE_CORE_COMMIT', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_BEFORE_CORE_COMMIT', '1', 'Process')
        Assert-ThrowsMatch {
            & $recoveryInstall -CodexHome $recoveryHome -StackRoot $recoveryRoot
        } 'synthetic pre-core-commit failure' 'Failure injection reaches the installed/previous/retained recovery branch'
    } finally {
        [Environment]::SetEnvironmentVariable('CPA_STACK_TEST_FAIL_BEFORE_CORE_COMMIT', $previousFailurePoint, 'Process')
    }
    Assert-Equal $expectedInstalledHash (Get-CpaStackFileHash -Path (Join-Path $recoveryInstalled 'SKILL.md')) 'Recovery restores the previously active installed slot byte-for-byte'
    Assert-Equal $expectedPreviousHash (Get-CpaStackFileHash -Path (Join-Path $recoveryPrevious 'SKILL.md')) 'Recovery restores the previous rollback slot byte-for-byte'
    $recoveryTransactionSlots = @(Get-ChildItem -LiteralPath (Join-Path $recoveryHome 'skills') -Directory -Force | Where-Object { $_.Name -match '^cpa-safe-upgrade\.(?:staging|retained|retiring)-' })
    Assert-Equal 0 $recoveryTransactionSlots.Count 'Successful recovery leaves no transaction directories'

    $unsafeSourceRepo = Join-Path $temp 'unsafe-source-fixture'
    New-Item -ItemType Directory -Force -Path $unsafeSourceRepo | Out-Null
    Copy-Item -LiteralPath $installScript -Destination (Join-Path $unsafeSourceRepo 'install.ps1')
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination (Join-Path $unsafeSourceRepo 'VERSION')
    Copy-Item -LiteralPath (Join-Path $repo 'skills') -Destination (Join-Path $unsafeSourceRepo 'skills') -Recurse
    $unsafeAuth = Join-Path $unsafeSourceRepo 'skills\cpa-safe-upgrade\auth'
    New-Item -ItemType Directory -Force -Path $unsafeAuth | Out-Null
    Set-Content -LiteralPath (Join-Path $unsafeAuth 'credentials.json') -Value '{"credential":"synthetic-test-value"}' -Encoding ASCII
    Assert-ThrowsMatch {
        & (Join-Path $unsafeSourceRepo 'install.ps1') -CodexHome (Join-Path $temp 'unsafe-source-home')
    } 'forbidden runtime or secret files' 'Installer rejects credentials hidden under a sensitive directory segment'

    $sharedLock = Enter-CpaStackOperationLock
    try {
        Assert-Equal 'CPAStackSafeOperation.lock' ([System.IO.Path]::GetFileName($sharedLock.Name)) 'The operation lock uses the shared lock name'
        Assert-ThrowsMatch {
            & $installScript -CodexHome (Join-Path $temp 'locked-install')
        } 'Another CPA stack operation is already running' 'Installer participates in the shared stack operation lock'
        Assert-ThrowsMatch {
            & $uninstallScript -CodexHome (Join-Path $temp 'locked-uninstall') -Yes
        } 'Another CPA stack operation is already running' 'Uninstaller participates in the shared stack operation lock'
    } finally {
        Exit-CpaStackOperationLock -Mutex $sharedLock
    }
} finally {
    if ($codexHomeJunction -and (Test-Path -LiteralPath $codexHomeJunction.FullName)) {
        [System.IO.Directory]::Delete($codexHomeJunction.FullName)
    }
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
    if (Test-Path -LiteralPath $stackTestParent) { Remove-TestPathWithRetry -Path $stackTestParent }
}

'Install tests passed.'
