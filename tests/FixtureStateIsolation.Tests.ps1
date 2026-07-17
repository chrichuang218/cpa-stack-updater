#requires -Version 5.1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

function Get-LocatorSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    $item = Get-Item -Force -LiteralPath $Path
    return [ordered]@{
        length = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        lastWriteUtcTicks = [long]$item.LastWriteTimeUtc.Ticks
    } | ConvertTo-Json -Compress
}

$sourceRepo = Split-Path -Parent $PSScriptRoot
$productionLocator = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\root.json'
$productionBefore = Get-LocatorSnapshot -Path $productionLocator
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-fixture-state-isolation-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $fixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $sourceRepo `
        -DestinationRepository (Join-Path $temp 'repository') `
        -LocalAppDataRoot (Join-Path $temp 'local-app-data')
    . (Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

    $fixtureLocator = Get-CpaStackRootLocatorPath
    Assert-False ([string]::Equals(
        [System.IO.Path]::GetFullPath($fixtureLocator),
        [System.IO.Path]::GetFullPath($productionLocator),
        [System.StringComparison]::OrdinalIgnoreCase)) 'Fixture locator differs from the current-user production locator'
    Assert-True ([System.IO.Path]::GetFullPath($fixtureLocator).StartsWith(
        [System.IO.Path]::GetFullPath($fixture.LocalAppData).TrimEnd('\') + '\',
        [System.StringComparison]::OrdinalIgnoreCase)) 'Fixture locator stays inside its rewritten state home'

    $stackRoot = Join-Path $temp 'isolated stack'
    New-Item -ItemType Directory -Force -Path $stackRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $stackRoot
    Set-CpaStackRegisteredRoot -ControlRoot $stackRoot
    Assert-True (Test-Path -LiteralPath $fixtureLocator -PathType Leaf) 'Fixture registration writes only its isolated locator'
    $registered = Read-CpaStackJson -Path $fixtureLocator
    Assert-Equal ([System.IO.Path]::GetFullPath($stackRoot).TrimEnd('\')) ([System.IO.Path]::GetFullPath([string]$registered.root).TrimEnd('\')) 'Fixture locator records the isolated stack root'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
}

Assert-Equal $productionBefore (Get-LocatorSnapshot -Path $productionLocator) 'Fixture registration leaves the production locator byte- and timestamp-identical'

'Fixture state isolation tests passed.'
