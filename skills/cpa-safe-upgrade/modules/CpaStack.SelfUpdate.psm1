Set-StrictMode -Version Latest

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\CpaStack.Common.ps1')

$script:UpdaterRepository = 'chrichuang218/cpa-stack-updater'
$script:UpdaterAssetPrefix = 'cpa-stack-updater-v'

function ConvertTo-CpaStackUpdaterVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed -notmatch '^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)$') {
        throw "Updater version is not a stable semantic version: $Value"
    }
    return [Version]::new(
        [int]$matches['major'],
        [int]$matches['minor'],
        [int]$matches['patch'])
}

function Get-CpaStackSelfUpdateInstallation {
    $skillRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
    $skillsRoot = Split-Path -Parent $skillRoot
    $codexHome = Split-Path -Parent $skillsRoot
    $expectedSkill = Join-Path (Join-Path $codexHome 'skills') 'cpa-safe-upgrade'
    if ([System.IO.Path]::GetFileName($skillRoot) -cne 'cpa-safe-upgrade' -or
        [System.IO.Path]::GetFileName($skillsRoot) -cne 'skills' -or
        -not [string]::Equals($skillRoot, [System.IO.Path]::GetFullPath($expectedSkill).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Automatic updater self-update requires the installed Codex skill location.'
    }
    $versionPath = Join-Path $skillRoot 'VERSION'
    $markerPath = Join-Path $skillRoot '.cpa-stack-updater-installed.json'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'Automatic updater self-update requires an installer-owned skill.'
    }
    $version = [System.IO.File]::ReadAllText($versionPath, [System.Text.UTF8Encoding]::new($false, $true)).Trim()
    [void](ConvertTo-CpaStackUpdaterVersion -Value $version)
    return [pscustomobject]@{
        CodexHome = [System.IO.Path]::GetFullPath($codexHome).TrimEnd('\')
        SkillRoot = $skillRoot
        CliPath = Join-Path $skillRoot 'scripts\cpa-stack.ps1'
        CurrentVersion = $version
    }
}

function Get-CpaStackUpdaterLatestRelease {
    $maximumReleaseJsonBytes = 4194304
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-updater-release-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Invoke-CpaStackSecureDownload `
            -Uri "https://api.github.com/repos/$($script:UpdaterRepository)/releases/latest" `
            -Destination $temp `
            -MaximumBytes $maximumReleaseJsonBytes
        $document = Read-CpaStackJson -Path $temp
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $document -or $document -is [array] -or
        [bool]$document.draft -or [bool]$document.prerelease) {
        throw 'Latest updater release metadata is not a stable release object.'
    }
    $tag = [string]$document.tag_name
    if ($tag -notmatch '^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)$') {
        throw 'Latest updater release tag is not a stable vMAJOR.MINOR.PATCH tag.'
    }
    $version = [string]$matches['version']
    [void](ConvertTo-CpaStackUpdaterVersion -Value $version)
    [void](Assert-CpaStackGitHubReleaseUrl `
        -Uri ([string]$document.html_url) `
        -Repository $script:UpdaterRepository `
        -Tag $tag)
    return [pscustomobject]@{
        Repository = $script:UpdaterRepository
        Tag = $tag
        Version = $version
        PublishedAt = [string]$document.published_at
        ReleaseUrl = [string]$document.html_url
        Document = $document
    }
}

function Get-CpaStackUpdaterReleaseAsset {
    param([Parameter(Mandatory = $true)]$Release)

    $expectedAssetName = $script:UpdaterAssetPrefix + [string]$Release.Version + '.zip'
    $assets = @($Release.Document.assets)
    $packages = @($assets | Where-Object { [string]$_.name -ceq $expectedAssetName })
    $checksums = @($assets | Where-Object { [string]$_.name -ceq 'checksums.txt' })
    if ($packages.Count -ne 1 -or $checksums.Count -ne 1) {
        throw "Updater release $($Release.Tag) must contain exactly $expectedAssetName and checksums.txt."
    }
    $asset = $packages[0]
    $checksumAsset = $checksums[0]
    [Int64]$assetSize = 0
    [Int64]$checksumsSize = 0
    if (-not [Int64]::TryParse([string]$asset.size, [ref]$assetSize) -or $assetSize -lt 1 -or $assetSize -gt 67108864) {
        throw 'Updater release archive size is missing or exceeds 64 MiB.'
    }
    if (-not [Int64]::TryParse([string]$checksumAsset.size, [ref]$checksumsSize) -or $checksumsSize -lt 1 -or $checksumsSize -gt 1048576) {
        throw 'Updater checksums size is missing or exceeds 1 MiB.'
    }
    foreach ($digest in @([string]$asset.digest, [string]$checksumAsset.digest)) {
        if ($digest -notmatch '^sha256:[0-9A-Fa-f]{64}$') {
            throw 'Updater release assets require GitHub SHA256 digests.'
        }
    }
    [void](Assert-CpaStackGitHubReleaseUrl -Uri ([string]$asset.browser_download_url) `
        -Repository $script:UpdaterRepository -Tag ([string]$Release.Tag) -AssetName $expectedAssetName)
    [void](Assert-CpaStackGitHubReleaseUrl -Uri ([string]$checksumAsset.browser_download_url) `
        -Repository $script:UpdaterRepository -Tag ([string]$Release.Tag) -AssetName 'checksums.txt')
    return [pscustomobject]@{
        AssetName = $expectedAssetName
        AssetUrl = [string]$asset.browser_download_url
        AssetSize = $assetSize
        AssetDigest = [string]$asset.digest
        ChecksumsUrl = [string]$checksumAsset.browser_download_url
        ChecksumsSize = $checksumsSize
        ChecksumsDigest = [string]$checksumAsset.digest
    }
}

function Save-CpaStackUpdaterRelease {
    param(
        [Parameter(Mandatory = $true)]$Release,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$Download
    )

    $asset = Get-CpaStackUpdaterReleaseAsset -Release $Release
    if ($null -eq $Download) {
        $Download = {
            param([string]$Uri, [string]$Path, [Int64]$MaximumBytes)
            Invoke-CpaStackSecureDownload -Uri $Uri -Destination $Path -MaximumBytes $MaximumBytes
        }.GetNewClosure()
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $archivePath = Join-Path $Destination $asset.AssetName
    $checksumsPath = Join-Path $Destination 'checksums.txt'
    $null = & $Download $asset.AssetUrl $archivePath $asset.AssetSize
    $null = & $Download $asset.ChecksumsUrl $checksumsPath $asset.ChecksumsSize
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $checksumsPath -PathType Leaf)) {
        throw 'Updater release download did not produce both required assets.'
    }
    $archiveHash = Get-CpaStackFileHash -Path $archivePath
    $checksumsHash = Get-CpaStackFileHash -Path $checksumsPath
    if ($archiveHash -cne $asset.AssetDigest.Substring(7).ToUpperInvariant() -or
        $checksumsHash -cne $asset.ChecksumsDigest.Substring(7).ToUpperInvariant()) {
        throw 'Updater release GitHub digest verification failed.'
    }
    $expectedHash = Get-CpaStackExpectedSha256 -ChecksumsPath $checksumsPath -AssetName $asset.AssetName
    if ($archiveHash -cne $expectedHash) {
        throw 'Updater release checksums.txt verification failed.'
    }
    $extracted = Join-Path $Destination 'extracted'
    Expand-CpaStackSafeArchive -ArchivePath $archivePath -DestinationPath $extracted `
        -MaximumEntries 500 -MaximumUncompressedBytes 134217728
    $rootName = $script:UpdaterAssetPrefix + [string]$Release.Version
    $releaseRoot = Join-Path $extracted $rootName
    $topLevel = @(Get-ChildItem -LiteralPath $extracted -Force)
    if ($topLevel.Count -ne 1 -or -not $topLevel[0].PSIsContainer -or $topLevel[0].Name -cne $rootName) {
        throw 'Updater release archive must contain exactly one versioned root directory.'
    }
    foreach ($required in @(
        (Join-Path $releaseRoot 'install.ps1'),
        (Join-Path $releaseRoot 'VERSION'),
        (Join-Path $releaseRoot 'skills\cpa-safe-upgrade\VERSION'),
        (Join-Path $releaseRoot 'skills\cpa-safe-upgrade\SKILL.md')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Updater release is incomplete: $required"
        }
    }
    $repositoryVersion = [System.IO.File]::ReadAllText((Join-Path $releaseRoot 'VERSION'), [System.Text.UTF8Encoding]::new($false, $true)).Trim()
    $skillVersion = [System.IO.File]::ReadAllText((Join-Path $releaseRoot 'skills\cpa-safe-upgrade\VERSION'), [System.Text.UTF8Encoding]::new($false, $true)).Trim()
    if ($repositoryVersion -cne [string]$Release.Version -or $skillVersion -cne [string]$Release.Version) {
        throw 'Updater release tag, repository VERSION, and skill VERSION do not match.'
    }
    $reparse = @(Get-ChildItem -LiteralPath $releaseRoot -Recurse -Force | Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ($reparse.Count -gt 0) {
        throw 'Updater release contains a reparse point after extraction.'
    }
    return $releaseRoot
}

function Invoke-CpaStackInstallerJson {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][ValidateSet('Check', 'Update')][string]$Action,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$StackRoot
    )

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $InstallerPath -Action $Action -CodexHome $CodexHome -StackRoot $StackRoot -Json 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { if ($?) { 0 } else { 1 } } else { [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    try { $document = $text | ConvertFrom-Json -ErrorAction Stop } catch { $document = $null }
    if ($null -eq $document -or $document -is [array] -or $exitCode -ne 0 -or -not [bool]$document.success) {
        throw "Updater installer $Action failed its structured result contract."
    }
    return $document
}

function Invoke-CpaStackUpdaterInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseRoot,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$StackRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $installer = Join-Path $ReleaseRoot 'install.ps1'
    $check = Invoke-CpaStackInstallerJson -InstallerPath $installer -Action Check -CodexHome $CodexHome -StackRoot $StackRoot
    if ([string]$check.sourceVersion -cne $ExpectedVersion) {
        throw 'Updater installer Check returned an unexpected source version.'
    }
    if (-not [bool]$check.updateAvailable -and [string]$check.installedVersion -ceq $ExpectedVersion) {
        return $check
    }
    $update = Invoke-CpaStackInstallerJson -InstallerPath $installer -Action Update -CodexHome $CodexHome -StackRoot $StackRoot
    if ([string]$update.installedVersion -cne $ExpectedVersion -or [string]$update.sourceVersion -cne $ExpectedVersion) {
        throw 'Updater installer Update did not commit the expected version.'
    }
    return $update
}

function New-CpaStackSelfUpdateHost {
    return [pscustomobject]@{
        GetRelease = { Get-CpaStackUpdaterLatestRelease }.GetNewClosure()
        SaveRelease = {
            param($Release, [string]$Destination)
            Save-CpaStackUpdaterRelease -Release $Release -Destination $Destination
        }.GetNewClosure()
        Install = {
            param([string]$ReleaseRoot, [string]$CodexHome, [string]$StackRoot, [string]$ExpectedVersion)
            Invoke-CpaStackUpdaterInstaller -ReleaseRoot $ReleaseRoot -CodexHome $CodexHome `
                -StackRoot $StackRoot -ExpectedVersion $ExpectedVersion
        }.GetNewClosure()
    }
}

function Invoke-CpaStackSelfUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$StackRoot,
        $Installation,
        $HostAdapter
    )

    $phase = 'location'
    $temp = $null
    $release = $null
    try {
        if ($null -eq $Installation) { $Installation = Get-CpaStackSelfUpdateInstallation }
        if ($null -eq $HostAdapter) { $HostAdapter = New-CpaStackSelfUpdateHost }
        foreach ($name in @('GetRelease', 'SaveRelease', 'Install')) {
            if ($null -eq $HostAdapter.PSObject.Properties[$name] -or $HostAdapter.$name -isnot [scriptblock]) {
                throw "Self-update host adapter is missing $name."
            }
        }
        $current = ConvertTo-CpaStackUpdaterVersion -Value ([string]$Installation.CurrentVersion)
        $phase = 'release-check'
        $getRelease = $HostAdapter.GetRelease
        $release = & $getRelease
        $latest = ConvertTo-CpaStackUpdaterVersion -Value ([string]$release.Version)
        if ($latest -le $current) {
            return [pscustomobject]@{
                success = $true
                changed = $false
                currentVersion = [string]$Installation.CurrentVersion
                latestVersion = [string]$Installation.CurrentVersion
                availableVersion = [string]$release.Version
                installedCliPath = [string]$Installation.CliPath
                error = $null
            }
        }
        $phase = 'download'
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-updater-self-' + [guid]::NewGuid().ToString('N'))
        $saveRelease = $HostAdapter.SaveRelease
        $releaseRoot = & $saveRelease $release $temp
        if ([string]::IsNullOrWhiteSpace([string]$releaseRoot)) {
            throw 'Self-update release preparation returned no local release root.'
        }
        $phase = 'install'
        $install = $HostAdapter.Install
        $installResult = & $install ([string]$releaseRoot) ([string]$Installation.CodexHome) $StackRoot ([string]$release.Version)
        if ($null -eq $installResult -or -not [bool]$installResult.success) {
            throw 'Self-update installer did not report success.'
        }
        $installedVersionPath = Join-Path ([string]$Installation.SkillRoot) 'VERSION'
        $installedVersion = [System.IO.File]::ReadAllText($installedVersionPath, [System.Text.UTF8Encoding]::new($false, $true)).Trim()
        if ($installedVersion -cne [string]$release.Version) {
            throw 'Self-update installed VERSION does not match the latest release.'
        }
        return [pscustomobject]@{
            success = $true
            changed = $true
            currentVersion = [string]$Installation.CurrentVersion
            latestVersion = [string]$release.Version
            availableVersion = [string]$release.Version
            installedCliPath = Join-Path ([string]$Installation.SkillRoot) 'scripts\cpa-stack.ps1'
            error = $null
        }
    } catch {
        $code = switch ($phase) {
            'location' { 'UpdaterLocationInvalid' }
            'release-check' { 'UpdaterReleaseCheckFailed' }
            'download' { 'UpdaterReleaseValidationFailed' }
            'install' { 'UpdaterInstallFailed' }
            default { 'UpdaterSelfUpdateFailed' }
        }
        return [pscustomobject]@{
            success = $false
            changed = $false
            currentVersion = if ($null -ne $Installation) { [string]$Installation.CurrentVersion } else { $null }
            latestVersion = if ($null -ne $release) { [string]$release.Version } else { $null }
            availableVersion = if ($null -ne $release) { [string]$release.Version } else { $null }
            installedCliPath = if ($null -ne $Installation) { [string]$Installation.CliPath } else { $null }
            error = [pscustomobject]@{
                code = $code
                message = 'Updater self-update failed before the CPA runtime upgrade.'
                type = $_.Exception.GetType().FullName
                phase = $phase
            }
        }
    } finally {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function ConvertTo-CpaStackUpdaterVersion, Get-CpaStackUpdaterLatestRelease, `
    Save-CpaStackUpdaterRelease, Invoke-CpaStackUpdaterInstaller, New-CpaStackSelfUpdateHost, `
    Invoke-CpaStackSelfUpdate
