$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$module = Join-Path $repo 'skills\cpa-safe-upgrade\modules\CpaStack.SelfUpdate.psm1'
Import-Module $module -Force
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-self-update-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    Assert-Equal '1.1.0' ([string](ConvertTo-CpaStackUpdaterVersion -Value '1.1.0')) 'Stable updater versions parse'
    Assert-Throws { ConvertTo-CpaStackUpdaterVersion -Value '1.1.0-beta' } 'Prerelease updater versions are rejected'

    $releaseDirectory = Join-Path $temp 'release'
    $package = & (Join-Path $repo 'tools\New-ReleasePackage.ps1') -DestinationDirectory $releaseDirectory
    Assert-True (Test-Path -LiteralPath $package.assetPath -PathType Leaf) 'Release packager creates the updater archive'
    Assert-True (Test-Path -LiteralPath $package.checksumsPath -PathType Leaf) 'Release packager creates checksums.txt'
    $assetDigest = 'sha256:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $package.assetPath).Hash.ToLowerInvariant()
    $checksumsDigest = 'sha256:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $package.checksumsPath).Hash.ToLowerInvariant()
    $tag = 'v' + [string]$package.version
    $assetUrl = "https://github.com/chrichuang218/cpa-stack-updater/releases/download/$tag/$($package.assetName)"
    $checksumsUrl = "https://github.com/chrichuang218/cpa-stack-updater/releases/download/$tag/checksums.txt"
    $release = [pscustomobject]@{
        Repository = 'chrichuang218/cpa-stack-updater'
        Tag = $tag
        Version = [string]$package.version
        PublishedAt = '2026-07-18T00:00:00Z'
        ReleaseUrl = "https://github.com/chrichuang218/cpa-stack-updater/releases/tag/$tag"
        Document = [pscustomobject]@{
            assets = @(
                [pscustomobject]@{ name = [string]$package.assetName; size = (Get-Item -LiteralPath $package.assetPath).Length; digest = $assetDigest; browser_download_url = $assetUrl },
                [pscustomobject]@{ name = 'checksums.txt'; size = (Get-Item -LiteralPath $package.checksumsPath).Length; digest = $checksumsDigest; browser_download_url = $checksumsUrl }
            )
        }
    }
    $download = {
        param([string]$Uri, [string]$Path, [Int64]$MaximumBytes)
        $source = if ($Uri.EndsWith('/checksums.txt', [System.StringComparison]::Ordinal)) { $package.checksumsPath } else { $package.assetPath }
        if ((Get-Item -LiteralPath $source).Length -gt $MaximumBytes) { throw 'Fixture download exceeds its advertised limit.' }
        Copy-Item -LiteralPath $source -Destination $Path -Force
    }.GetNewClosure()
    $prepared = Save-CpaStackUpdaterRelease -Release $release -Destination (Join-Path $temp 'prepared') -Download $download
    Assert-True (Test-Path -LiteralPath (Join-Path $prepared 'install.ps1') -PathType Leaf) 'Validated updater release exposes its local installer'
    Assert-Equal ([string]$package.version) ([System.IO.File]::ReadAllText((Join-Path $prepared 'VERSION')).Trim()) 'Validated updater release preserves its bound version'

    $badRelease = $release.PSObject.Copy()
    $badDocument = $release.Document.PSObject.Copy()
    $badAssets = @($release.Document.assets | ForEach-Object { $_.PSObject.Copy() })
    $badAssets[0].digest = 'sha256:' + ('0' * 64)
    $badDocument.assets = $badAssets
    $badRelease.Document = $badDocument
    Assert-Throws {
        Save-CpaStackUpdaterRelease -Release $badRelease -Destination (Join-Path $temp 'bad-digest') -Download $download
    } 'Updater release rejects a mismatched GitHub digest'

    $installedSkill = Join-Path $temp 'installed\skills\cpa-safe-upgrade'
    New-Item -ItemType Directory -Force -Path (Join-Path $installedSkill 'scripts') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $installedSkill 'VERSION'), '1.0.0', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $installedSkill 'scripts\cpa-stack.ps1'), '# fixture', [System.Text.Encoding]::ASCII)
    $installation = [pscustomobject]@{
        CodexHome = Split-Path -Parent (Split-Path -Parent $installedSkill)
        SkillRoot = $installedSkill
        CliPath = Join-Path $installedSkill 'scripts\cpa-stack.ps1'
        CurrentVersion = '1.0.0'
    }
    $olderHost = [pscustomobject]@{
        GetRelease = { [pscustomobject]@{ Version = '0.9.0' } }
        SaveRelease = { throw 'SaveRelease must not run for an older remote version.' }
        Install = { throw 'Install must not run for an older remote version.' }
    }
    $older = Invoke-CpaStackSelfUpdate -StackRoot (Join-Path $temp 'stack') -Installation $installation -HostAdapter $olderHost
    Assert-True ([bool]$older.success) 'Older remote updater metadata does not block the current updater'
    Assert-False ([bool]$older.changed) 'Older remote updater metadata performs no write'
    Assert-Equal '1.0.0' ([string]$older.latestVersion) 'Older remote updater does not replace the installed after-version'
    Assert-Equal '0.9.0' ([string]$older.availableVersion) 'Older remote updater remains observable as the available release'

    $releaseRoot = Split-Path -Parent $package.assetPath
    $newerHost = [pscustomobject]@{
        GetRelease = { [pscustomobject]@{ Version = '1.1.0' } }
        SaveRelease = { param($Release, $Destination); return $releaseRoot }.GetNewClosure()
        Install = {
            param($ReleaseRoot, $CodexHome, $StackRoot, $ExpectedVersion)
            [System.IO.File]::WriteAllText((Join-Path $installedSkill 'VERSION'), $ExpectedVersion, [System.Text.Encoding]::ASCII)
            return [pscustomobject]@{ success = $true; installedVersion = $ExpectedVersion }
        }.GetNewClosure()
    }
    $newer = Invoke-CpaStackSelfUpdate -StackRoot (Join-Path $temp 'stack') -Installation $installation -HostAdapter $newerHost
    Assert-True ([bool]$newer.success) 'Newer updater release installs successfully through the host seam'
    Assert-True ([bool]$newer.changed) 'Newer updater release requests CLI re-execution'
    Assert-Equal '1.1.0' ([string]$newer.latestVersion) 'Newer updater result reports the installed version'

    $failingHost = [pscustomobject]@{
        GetRelease = { throw 'synthetic release query failure' }
        SaveRelease = { throw 'unreachable' }
        Install = { throw 'unreachable' }
    }
    $failed = Invoke-CpaStackSelfUpdate -StackRoot (Join-Path $temp 'stack') -Installation $installation -HostAdapter $failingHost
    Assert-False ([bool]$failed.success) 'Updater release query failure is explicit'
    Assert-Equal 'UpdaterReleaseCheckFailed' ([string]$failed.error.code) 'Updater release query failure has a stable code'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
}

'Self-update tests passed.'
