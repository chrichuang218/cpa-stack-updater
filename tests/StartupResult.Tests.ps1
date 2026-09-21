#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# Exercise the actual result expression with the shapes returned by normal and fast startup.
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$expression = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.PipelineAst] -and
    $node.Extent.Text.StartsWith('[pscustomobject]@{') -and
    $node.Extent.Text.Contains('PreviousProcessId =') -and $node.Extent.Text.Contains('Success = $true')
}, $true)
Assert-True ($null -ne $expression) 'Locate the production startup result expression'
$emit = [scriptblock]::Create($expression.Extent.Text)
$settings = @{ Cpa = @{ Port = 1; Executable = 'fixture-cpa' }; Manager = @{ Port = 2; Executable = 'fixture-manager'; DataDirectory = 'fixture-data' } }
$modelCount = 1
$collectorEnabled = $true
$collectorState = 'running'
$browserAction = 'Skipped'
foreach ($Fast in @($false, $true)) {
    $cpaResult = [pscustomobject]@{ Action = 'Started'; ProcessId = 10 }
    $managerResult = [pscustomobject]@{ Action = 'Started'; ProcessId = 20 }
    if ($Fast) {
        $cpaResult | Add-Member PreviousProcessId '8'
        $managerResult | Add-Member PreviousProcessId '9'
    }
    $result = (& $emit) | ConvertFrom-Json
    Assert-True $result.Success 'Healthy startup produces a success result'
    Assert-Equal $(if ($Fast) { '8' } else { $null }) $result.Cpa.PreviousProcessId 'Previous CPA PID is only supplied by fast startup'
    Assert-Equal $(if ($Fast) { '9' } else { $null }) $result.Manager.PreviousProcessId 'Previous Manager PID is only supplied by fast startup'
}
'Startup result tests passed.'
