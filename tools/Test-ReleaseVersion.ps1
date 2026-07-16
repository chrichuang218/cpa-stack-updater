#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$version = ([System.IO.File]::ReadAllText((Join-Path $repo 'VERSION'), [System.Text.UTF8Encoding]::new($false, $true))).Trim()
$skillVersion = ([System.IO.File]::ReadAllText((Join-Path $repo 'skills\cpa-safe-upgrade\VERSION'), [System.Text.UTF8Encoding]::new($false, $true))).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid VERSION: $version"
}
if ($skillVersion -ne $version) {
    throw "Skill VERSION does not match repository VERSION. Repository=$version Skill=$skillVersion"
}
$changeLog = [System.IO.File]::ReadAllText((Join-Path $repo 'CHANGELOG.md'), [System.Text.UTF8Encoding]::new($false, $true))
$headingPattern = '(?m)^##\s+' + [regex]::Escape($version) + '\s+-\s+(.+)$'
$heading = [regex]::Match($changeLog, $headingPattern)
if (-not $heading.Success) {
    throw "CHANGELOG.md has no heading for VERSION $version."
}
if ($env:GITHUB_REF_TYPE -eq 'tag') {
    $expectedTag = 'v' + $version
    if ($env:GITHUB_REF_NAME -cne $expectedTag) {
        throw "Release tag must match VERSION. Expected=$expectedTag Actual=$($env:GITHUB_REF_NAME)"
    }
    if ($heading.Groups[1].Value -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw 'A release tag requires a dated CHANGELOG entry.'
    }
}

Write-Host "Release version checks passed: $version"
