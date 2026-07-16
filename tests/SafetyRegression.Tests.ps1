$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
. $commonPath

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-safety-regression-' + [guid]::NewGuid().ToString('N'))
$rootJunction = $null
$ancestorJunction = $null
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    $assetName = 'cpa-windows-amd64.zip'
    $hash = -join ('a' * 64)
    $bareChecksumPath = Join-Path $temp 'checksums-bare.txt'
    $dotChecksumPath = Join-Path $temp 'checksums-dot.txt'
    $nestedChecksumPath = Join-Path $temp 'checksums-nested.txt'

    Set-Content -LiteralPath $bareChecksumPath -Value ($hash + '  ' + $assetName) -Encoding ASCII
    Assert-Equal $hash.ToUpperInvariant() (Get-CpaStackExpectedSha256 -ChecksumsPath $bareChecksumPath -AssetName $assetName) 'Bare checksum asset name is accepted'

    Set-Content -LiteralPath $dotChecksumPath -Value ($hash + '  ./' + $assetName) -Encoding ASCII
    Assert-Equal $hash.ToUpperInvariant() (Get-CpaStackExpectedSha256 -ChecksumsPath $dotChecksumPath -AssetName $assetName) 'Exact dot-slash checksum prefix is accepted'

    Set-Content -LiteralPath $nestedChecksumPath -Value ($hash + '  dist/' + $assetName) -Encoding ASCII
    Assert-ThrowsMatch {
        Get-CpaStackExpectedSha256 -ChecksumsPath $nestedChecksumPath -AssetName $assetName
    } 'does not contain a SHA256' 'A checksum entry under a subdirectory is rejected'

    $trustedUri = Assert-CpaStackTrustedDownloadUri -Uri 'https://github.com/example/project'
    Assert-Equal 'github.com' $trustedUri.IdnHost 'An exact trusted GitHub host is accepted'
    foreach ($untrustedUri in @(
        'http://github.com/example/project',
        'https://user@github.com/example/project',
        'https://github.com:444/example/project',
        'https://github.com./example/project',
        'https://example.com/example/project',
        'https://github.com/example/project#fragment'
    )) {
        Assert-Throws {
            Assert-CpaStackTrustedDownloadUri -Uri $untrustedUri
        } "Untrusted download URI is rejected: $untrustedUri"
    }

    $releaseUrl = 'https://github.com/example/project/releases/tag/v1.2.3'
    $releaseAssetUrl = 'https://github.com/example/project/releases/download/v1.2.3/package.zip'
    Assert-CpaStackGitHubReleaseUrl -Uri $releaseUrl -Repository 'example/project' -Tag 'v1.2.3' | Out-Null
    Assert-CpaStackGitHubReleaseUrl -Uri $releaseAssetUrl -Repository 'example/project' -Tag 'v1.2.3' -AssetName 'package.zip' | Out-Null
    foreach ($mismatchedUrl in @(
        'https://github.com/other/project/releases/download/v1.2.3/package.zip',
        'https://github.com/example/other/releases/download/v1.2.3/package.zip',
        'https://github.com/example/project/releases/download/v9.9.9/package.zip',
        'https://github.com/example/project/releases/download/v1.2.3/other.zip',
        'https://github.com/example/project/releases/download/v1.2.3/package.zip?source=other'
    )) {
        Assert-ThrowsMatch {
            Assert-CpaStackGitHubReleaseUrl -Uri $mismatchedUrl -Repository 'example/project' -Tag 'v1.2.3' -AssetName 'package.zip'
        } 'GitHub release URL' "Release asset URL remains bound to its expected identity: $mismatchedUrl"
    }

    $oversizedReleaseDestination = Join-Path $temp 'oversized-release'
    $oversizedRelease = [pscustomobject]@{
        Repository = 'example/project'
        Tag = 'v1.2.3'
        ReleaseUrl = $releaseUrl
        AssetName = 'package.zip'
        AssetUrl = $releaseAssetUrl
        AssetSize = 1073741825
        ChecksumsUrl = 'https://github.com/example/project/releases/download/v1.2.3/checksums.txt'
        ChecksumsSize = 100
    }
    Assert-ThrowsMatch {
        Save-CpaStackRelease -Release $oversizedRelease -Destination $oversizedReleaseDestination
    } 'metadata exceeds the 1 GiB safety limit' 'Oversized release metadata is rejected before download'
    Assert-False (Test-Path -LiteralPath $oversizedReleaseDestination) 'An oversized release does not create a destination directory'

    $boundedInput = [System.IO.MemoryStream]::new([byte[]](1, 2, 3, 4))
    $boundedOutput = [System.IO.MemoryStream]::new()
    try {
        Assert-Equal 4 (Copy-CpaStackBoundedStream -InputStream $boundedInput -OutputStream $boundedOutput -MaximumBytes 4) 'A stream exactly at the byte limit is accepted'
        Assert-Equal 4 $boundedOutput.Length 'The complete bounded stream is written'
    } finally {
        $boundedOutput.Dispose()
        $boundedInput.Dispose()
    }

    $oversizedInput = [System.IO.MemoryStream]::new([byte[]](1, 2, 3, 4, 5))
    $oversizedOutput = [System.IO.MemoryStream]::new()
    try {
        Assert-ThrowsMatch {
            Copy-CpaStackBoundedStream -InputStream $oversizedInput -OutputStream $oversizedOutput -MaximumBytes 4
        } 'exceeded the 4 byte safety limit' 'A stream over the byte limit is rejected before oversized content is committed'
        Assert-True ($oversizedOutput.Length -le 4) 'The bounded stream writer never writes beyond the hard limit'
    } finally {
        $oversizedOutput.Dispose()
        $oversizedInput.Dispose()
    }

    $oldHash = -join ('1' * 64)
    $newHash = -join ('2' * 64)
    $switchCases = @(
        [pscustomobject]@{ Recorded = $newHash; Active = $newHash; Expected = 'commit-new' },
        [pscustomobject]@{ Recorded = $oldHash; Active = $oldHash; Expected = 'restore-old' },
        [pscustomobject]@{ Recorded = $oldHash; Active = $newHash; Expected = 'restore-old' }
    )
    foreach ($case in $switchCases) {
        $actual = Resolve-CpaStackSwitchDisposition -RecordedHash $case.Recorded -ActiveHash $case.Active -OldHash $oldHash -NewHash $newHash
        Assert-Equal $case.Expected $actual "Switch disposition for recorded=$($case.Recorded.Substring(0, 1)) active=$($case.Active.Substring(0, 1))"
    }
    Assert-ThrowsMatch {
        Resolve-CpaStackSwitchDisposition -RecordedHash $newHash -ActiveHash $oldHash -OldHash $oldHash -NewHash $newHash
    } 'Switch recovery state is ambiguous' 'A new recorded hash with the old active binary is ambiguous'

    $rootTarget = Join-Path $temp 'root-target'
    $rootJunction = Join-Path $temp 'root-junction'
    New-Item -ItemType Directory -Force -Path $rootTarget | Out-Null
    New-Item -ItemType Junction -Path $rootJunction -Target $rootTarget | Out-Null
    Assert-ThrowsMatch {
        Assert-CpaStackSecureLocalRoot -Path $rootJunction
    } 'must not be or cross a reparse point' 'A managed root junction is rejected'

    $ancestorTarget = Join-Path $temp 'ancestor-target'
    $ancestorJunction = Join-Path $temp 'ancestor-junction'
    New-Item -ItemType Directory -Force -Path $ancestorTarget | Out-Null
    New-Item -ItemType Junction -Path $ancestorJunction -Target $ancestorTarget | Out-Null
    $childThroughJunction = Join-Path $ancestorJunction 'child'
    New-Item -ItemType Directory -Force -Path $childThroughJunction | Out-Null
    Assert-ThrowsMatch {
        Assert-CpaStackSecureLocalRoot -Path $childThroughJunction
    } 'must not be or cross a reparse point' 'A managed root below an ancestor junction is rejected'

    $systemChild = Join-Path ([Environment]::GetFolderPath('Windows')) ('Temp\CPAStack-' + [guid]::NewGuid().ToString('N'))
    Assert-ThrowsMatch {
        Assert-CpaStackSecureLocalRoot -Path $systemChild
    } 'Windows or Program Files' 'A managed root below the Windows directory is rejected'

    $profileChild = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('CPAStack-Test-' + [guid]::NewGuid().ToString('N'))
    Assert-Equal ([System.IO.Path]::GetFullPath($profileChild).TrimEnd('\')) (Assert-CpaStackSecureLocalRoot -Path $profileChild) 'A dedicated directory below LocalAppData remains supported'
} finally {
    foreach ($junction in @($ancestorJunction, $rootJunction)) {
        if (-not [string]::IsNullOrWhiteSpace($junction) -and (Test-Path -LiteralPath $junction)) {
            [System.IO.Directory]::Delete($junction)
        }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

'Safety regression tests passed.'
