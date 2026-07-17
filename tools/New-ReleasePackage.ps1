#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$version = [System.IO.File]::ReadAllText((Join-Path $repo 'VERSION'), [System.Text.UTF8Encoding]::new($false, $true)).Trim()
if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "Release packaging requires a stable semantic VERSION: $version"
}
$skillVersion = [System.IO.File]::ReadAllText((Join-Path $repo 'skills\cpa-safe-upgrade\VERSION'), [System.Text.UTF8Encoding]::new($false, $true)).Trim()
if ($skillVersion -cne $version) {
    throw 'Repository and skill VERSION files do not match.'
}
$destination = [System.IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\')
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$rootName = 'cpa-stack-updater-v' + $version
$assetName = $rootName + '.zip'
$assetPath = Join-Path $destination $assetName
$checksumsPath = Join-Path $destination 'checksums.txt'
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-updater-package-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $staging $rootName

try {
    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
    foreach ($file in @(
        'CHANGELOG.md',
        'LICENSE',
        'README.md',
        'README.en.md',
        'SECURITY.md',
        'VERSION',
        'cpa-stack.ps1',
        'install.ps1',
        'uninstall.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $packageRoot $file) -Force
    }
    foreach ($directory in @('docs', 'skills')) {
        Copy-Item -LiteralPath (Join-Path $repo $directory) -Destination (Join-Path $packageRoot $directory) -Recurse -Force
    }
    Remove-Item -LiteralPath $assetPath, $checksumsPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $assetPath -CompressionLevel Optimal
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToUpperInvariant()
    [System.IO.File]::WriteAllText(
        $checksumsPath,
        ($hash + ' *' + $assetName + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        version = $version
        assetName = $assetName
        assetPath = $assetPath
        sha256 = $hash
        checksumsPath = $checksumsPath
    }
} finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
