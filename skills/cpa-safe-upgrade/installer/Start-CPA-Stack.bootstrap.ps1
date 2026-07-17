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
$starter = $null
foreach ($candidateHome in $candidateHomes) {
    $candidate = Join-Path ([System.IO.Path]::GetFullPath($candidateHome).TrimEnd('\')) 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $starter = $candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace($starter)) {
    throw 'Installed CPA Stack fast starter was not found in CODEX_HOME, the installer-managed home, or the default user Codex home.'
}

$interactiveConsole = $false
try { $interactiveConsole = -not [Console]::IsOutputRedirected } catch {}
if ($interactiveConsole) {
    try {
        $Host.UI.RawUI.WindowTitle = 'CPA Stack - Quick Start'
        $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
        $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Gray
        Clear-Host
    } catch {}
    Write-Host ''
    Write-Host '  CPA STACK' -ForegroundColor Cyan
    Write-Host '  ----------------------------------------' -ForegroundColor DarkCyan
    Write-Host '  Checking and starting CPA + Manager...' -ForegroundColor Gray
    Write-Host ''
}

$starterParameters = @{
    Fast = $true
    ReturnResult = $true
    ConfigPath = Join-Path $stackRoot 'config\stack.psd1'
    NoBrowser = [bool]$NoBrowser
    InteractiveProgress = $interactiveConsole
}
$output = @(& $starter @starterParameters)

$document = $null
try { $document = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json } catch {}
$exitCode = if ($null -ne $document -and [bool]$document.success) { 0 } else { 1 }
if (-not $interactiveConsole) {
    $output
    exit $exitCode
}
if ($exitCode -eq 0) {
    $start = if ($null -ne $document.PSObject.Properties['start']) { $document.start } else { $document }
    if ($null -ne $start) {
        Write-Host ("  CPA API  : {0} (port {1})" -f $start.Cpa.Action, $start.Cpa.Port) -ForegroundColor Green
        Write-Host ("  Manager  : {0} (port {1})" -f $start.Manager.Action, $start.Manager.Port) -ForegroundColor Green
        Write-Host ("  Browser  : {0}" -f $start.Browser) -ForegroundColor DarkGray
    }
    try { $Host.UI.RawUI.WindowTitle = 'CPA Stack - Running' } catch {}
    Write-Host ''
    Write-Host '  [OK] CPA Stack is ready' -ForegroundColor Green
    Write-Host '  You may close this window; services will keep running.' -ForegroundColor DarkGray
    Write-Host ''
} else {
    $message = if ($null -ne $document -and $null -ne $document.Error) { [string]$document.Error.Message } else { (($output | ForEach-Object { [string]$_ }) -join ' ') }
    try { $Host.UI.RawUI.WindowTitle = 'CPA Stack - Start Failed' } catch {}
    Write-Host '  [ERROR] Startup failed' -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($message)) { Write-Host ('  ' + $message) -ForegroundColor Yellow }
    Write-Host ''
}
exit $exitCode
