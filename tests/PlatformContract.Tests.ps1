#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$repo=Split-Path -Parent $PSScriptRoot
$skill=Join-Path $repo 'skills\cpa-safe-upgrade'
Import-Module (Join-Path $skill 'modules\CpaStack.ManagedShortcut.psm1') -Force
Import-Module (Join-Path $skill 'modules\CpaStack.Recovery.psm1') -Force
Import-Module (Join-Path $skill 'modules\CpaStack.BundledHost.psm1') -Force -Global
$temp=Join-Path ([IO.Path]::GetTempPath()) ('cpa-platform-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $temp 'host.ps1'), '[pscustomobject]@{major=$PSVersionTable.PSVersion.Major;edition=$PSVersionTable.PSEdition}|ConvertTo-Json -Compress')
    $run=Invoke-CpaStackBundled -HostAdapter (New-CpaStackBundledHost -ScriptsRoot $temp) -Name 'host.ps1'
    Assert-Equal 0 $run.ExitCode 'Bundled host exits successfully'
    Assert-True ($run.Json.major -ge 7) 'Children run under PS7'
    Assert-Equal 'Core' $run.Json.edition 'No Desktop edition fallback'
    $shortcutModule=Get-Module CpaStack.ManagedShortcut
    $hostPath=& $shortcutModule { Get-CpaStackPreferredPowerShellPath }
    Assert-Equal 'pwsh.exe' ([IO.Path]::GetFileName($hostPath)) 'New shortcuts use PS7'
    & $shortcutModule {
        function Get-Command { $null }
        try {
            $failed=$false
            try { [void](Get-CpaStackPreferredPowerShellPath) } catch { $failed=$_.Exception.Message -match 'PowerShell 7 is required' }
            if (-not $failed) { throw 'Missing PS7 must fail, not fall back.' }
        } finally { Remove-Item Function:\Get-Command }
    }
    Assert-False (Test-Path (Join-Path $skill 'scripts\Set-CpaStackLan.ps1')) 'LAN implementation removed'
    $cli=Join-Path $skill 'scripts\cpa-stack.ps1'
    $output=@(& $hostPath -NoLogo -NoProfile -NonInteractive -File $cli lan -Root $temp -Json 2>&1)
    Assert-True ($LASTEXITCODE -ne 0) 'CLI rejects removed LAN command before runtime actions'
    $plan=Get-CpaStackRecoveryPlan -Root $temp -PendingPaths @((Join-Path $temp 'state\lan.pending.json'))
    Assert-Equal 'ambiguous' $plan.Kind 'Old LAN transaction is blocked, never ignored or executed'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
'PS7 and removed-LAN contract checks passed.'
