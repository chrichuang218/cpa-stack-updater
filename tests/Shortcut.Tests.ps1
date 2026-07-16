$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

$ops = Join-Path ([System.IO.Path]::GetTempPath()) 'cpa shortcut contract\ops'
$startScript = Join-Path $ops 'Start-CPA-Stack.ps1'
$contract = Get-CpaStackCanonicalShortcutContract -StartScript $startScript -WorkingDirectory $ops

Assert-True ([string]$contract.Arguments -match '(?i)(?:^|\s)-WindowStyle\s+Hidden(?:\s|$)') 'Canonical shortcut arguments hide the PowerShell window'
Assert-True ([string]$contract.Arguments -match '(?i)(?:^|\s)-NonInteractive(?:\s|$)') 'Canonical shortcut launch is non-interactive'
Assert-True ([string]$contract.Arguments -match ('-File\s+"' + [regex]::Escape([System.IO.Path]::GetFullPath($startScript)) + '"$')) 'Canonical shortcut quotes a start script path containing spaces'
Assert-Equal ([System.IO.Path]::GetFullPath((Get-Command powershell.exe -ErrorAction Stop).Source)) ([System.IO.Path]::GetFullPath([string]$contract.TargetPath)) 'Canonical shortcut targets Windows PowerShell'
Assert-Equal ([System.IO.Path]::GetFullPath($ops).TrimEnd('\')) ([string]$contract.WorkingDirectory) 'Canonical shortcut uses the canonical working directory'
Assert-Equal 7 ([int]$contract.WindowStyle) 'Canonical shortcut minimizes the shell bootstrap before PowerShell hides itself'

$validShortcut = [pscustomobject]@{
    TargetPath = $contract.TargetPath
    Arguments = $contract.Arguments
    WorkingDirectory = $contract.WorkingDirectory
    WindowStyle = $contract.WindowStyle
}
[void](Assert-CpaStackCanonicalShortcutContract -Shortcut $validShortcut -StartScript $startScript -WorkingDirectory $ops)

$visibleShortcut = $validShortcut.PSObject.Copy()
$visibleShortcut.Arguments = ([string]$visibleShortcut.Arguments).Replace('-WindowStyle Hidden ', '')
Assert-ThrowsMatch {
    [void](Assert-CpaStackCanonicalShortcutContract -Shortcut $visibleShortcut -StartScript $startScript -WorkingDirectory $ops)
} 'hidden-window launch contract' 'Shortcut verification rejects a visible PowerShell launch'

$normalWindowShortcut = $validShortcut.PSObject.Copy()
$normalWindowShortcut.WindowStyle = 1
Assert-ThrowsMatch {
    [void](Assert-CpaStackCanonicalShortcutContract -Shortcut $normalWindowShortcut -StartScript $startScript -WorkingDirectory $ops)
} 'hidden-window launch contract' 'Shortcut verification rejects a normal WSH window style'

'Shortcut tests passed.'
