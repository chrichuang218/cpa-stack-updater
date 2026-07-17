#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$stackRoot = Split-Path -Parent $PSScriptRoot
$installedCodexHome = [System.Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('__CPA_STACK_CODEX_HOME_BASE64__')
)
$candidateHomes = @(
    $env:CODEX_HOME
    $installedCodexHome
    (Join-Path $HOME '.codex')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
$cli = $null
foreach ($candidateHome in $candidateHomes) {
    $candidate = Join-Path ([System.IO.Path]::GetFullPath($candidateHome).TrimEnd('\')) 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $cli = $candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace($cli)) {
    throw 'Installed CPA Stack Updater CLI was not found in CODEX_HOME, the installer-managed home, or the default user Codex home.'
}

if ($NoBrowser) {
    & $cli start -Root $stackRoot -NoBrowser
} else {
    & $cli start -Root $stackRoot
}
exit $LASTEXITCODE
