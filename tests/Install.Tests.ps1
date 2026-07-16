$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $repo 'install.ps1'
$uninstallScript = Join-Path $repo 'uninstall.ps1'
$expectedVersion = (Get-Content -Raw -LiteralPath (Join-Path $repo 'VERSION')).Trim()
$commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
. $commonPath

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-install-tests-' + [guid]::NewGuid().ToString('N'))
$locatorPath = Get-CpaStackRootLocatorPath
$locatorExisted = Test-Path -LiteralPath $locatorPath -PathType Leaf
$locatorBytes = if ($locatorExisted) { [System.IO.File]::ReadAllBytes($locatorPath) } else { $null }
$locatorSddl = if ($locatorExisted) { (Get-Acl -LiteralPath $locatorPath).Sddl } else { $null }
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $usedRoots = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    $unusedLetter = @('Q', 'Y', 'X', 'W') | Where-Object { $usedRoots -notcontains $_ } | Select-Object -First 1
    if ($unusedLetter) {
        $invalidHome = Join-Path $temp 'invalid-root-home'
        Assert-Throws {
            & $installScript -CodexHome $invalidHome -StackRoot ("${unusedLetter}:\CPA-Stack")
        } 'Installer rejects a missing target drive before swapping the skill'
        Assert-False (Test-Path -LiteralPath (Join-Path $invalidHome 'skills\cpa-safe-upgrade')) 'Failed root validation leaves no installed skill'
    }
    $customStackRoot = Join-Path $temp 'managed stack root'
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

    $updateResult = (& $installScript -CodexHome $temp) | ConvertFrom-Json
    Assert-True ([bool]$updateResult.success) 'Installer can atomically update an owned skill'
    Assert-Equal ([System.IO.Path]::GetFullPath($customStackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$updateResult.registeredRoot).TrimEnd('\')) 'A later parameterless install keeps using the protected registered root'
    Assert-True ([bool]$updateResult.launcherUpdated) 'A later parameterless skill update refreshes a stale canonical launcher'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $installed 'scripts\Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path (Join-Path $customStackRoot 'ops\Start-CPA-Stack.ps1')) 'Canonical launcher matches the newly installed skill'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'skills\cpa-safe-upgrade.previous\.cpa-stack-updater-installed.json') -PathType Leaf) 'Atomic update retains one owned previous skill'

    $stableUninstall = Join-Path $installed 'scripts\Uninstall-CpaSafeUpgrade.ps1'
    $uninstallText = & $stableUninstall -CodexHome $temp -Yes
    $uninstall = $uninstallText | ConvertFrom-Json
    Assert-True ([bool]$uninstall.success) 'Uninstaller reports success'
    Assert-False (Test-Path -LiteralPath $installed) 'Skill is removed'
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

    $fixtureRepo = Join-Path $temp 'unsafe-source-fixture'
    New-Item -ItemType Directory -Force -Path $fixtureRepo | Out-Null
    Copy-Item -LiteralPath $installScript -Destination (Join-Path $fixtureRepo 'install.ps1')
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination (Join-Path $fixtureRepo 'VERSION')
    Copy-Item -LiteralPath (Join-Path $repo 'skills') -Destination (Join-Path $fixtureRepo 'skills') -Recurse
    $unsafeAuth = Join-Path $fixtureRepo 'skills\cpa-safe-upgrade\auth'
    New-Item -ItemType Directory -Force -Path $unsafeAuth | Out-Null
    Set-Content -LiteralPath (Join-Path $unsafeAuth 'credentials.json') -Value '{"credential":"synthetic-test-value"}' -Encoding ASCII
    Assert-ThrowsMatch {
        & (Join-Path $fixtureRepo 'install.ps1') -CodexHome (Join-Path $temp 'unsafe-source-home')
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
    if ($locatorExisted) {
        [System.IO.File]::WriteAllBytes($locatorPath, $locatorBytes)
        $restoredAcl = Get-Acl -LiteralPath $locatorPath
        $restoredAcl.SetSecurityDescriptorSddlForm($locatorSddl)
        Set-Acl -LiteralPath $locatorPath -AclObject $restoredAcl
    } elseif (Test-Path -LiteralPath $locatorPath -PathType Leaf) {
        Remove-Item -LiteralPath $locatorPath -Force
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

'Install tests passed.'
