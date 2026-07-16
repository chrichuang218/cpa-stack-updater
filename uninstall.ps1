#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CodexHome = $(if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }),
    [switch]$Yes
)

$entry = Join-Path $PSScriptRoot 'skills\cpa-safe-upgrade\scripts\Uninstall-CpaSafeUpgrade.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw 'The repository does not contain the bundled uninstaller.'
}
& $entry -CodexHome $CodexHome -Yes:$Yes
exit 0
