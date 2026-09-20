#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$scripts=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts'
. (Join-Path $scripts 'CpaStack.Common.ps1')
Import-Module (Join-Path $scripts '..\modules\CpaStack.BundledHost.psm1') -Force

function Get-TestDefinition {
    param([string]$File,[string]$Name)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $File),[ref]$tokens,[ref]$errors)
    Assert-Equal 0 $errors.Count 'Source parses'
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    Assert-True ($null -ne $fn) "Shared function exists: $Name"
    $fn.Extent.Text
}

Assert-Equal 42 (Get-RequiredMapValue -Map @{port=42} -Name port -Context fixture) 'Shared required value'
Assert-Equal fallback (Get-OptionalMapValue -Map @{} -Name missing -DefaultValue fallback) 'Shared optional value'
Assert-Throws { Get-RequiredMapValue -Map @{} -Name missing -Context fixture } 'Missing required value still fails'
Assert-Equal 28337 (ConvertTo-Port -Value '28337' -Context fixture) 'Shared port conversion'
Assert-Throws { ConvertTo-Port -Value 65536 -Context fixture } 'Invalid port still fails'
Assert-True (Test-PathEqual -Left 'C:\fixture\a' -Right 'c:\FIXTURE\a') 'Windows paths compare case-insensitively'

# Compile the unchanged shared native launcher, and launch only an immediately exiting test host.
. ([scriptblock]::Create((Get-TestDefinition -File 'Start-CPA-Stack.ps1' -Name 'Start-ManagedProcess')))
$process=Start-ManagedProcess -FilePath (Get-Command pwsh.exe).Source -Arguments '-NoLogo -NoProfile -NonInteractive -Command "exit 0"' -WorkingDirectory ([IO.Path]::GetTempPath())
try {
    Assert-True ($process.WaitForExit(10000)) 'Shared native launcher starts a child without inherited output pipes'
    Assert-Equal 0 $process.ExitCode 'Native child exits successfully'
} finally { if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(3000)}; $process.Dispose() }

foreach($file in @('Initialize-CpaStack.ps1','Invoke-CpaStackUpgrade.ps1')) { & {
    . ([scriptblock]::Create((Get-TestDefinition -File $file -Name 'Invoke-InProcessPowerShellJson')))
    $result=[ordered]@{diagnostics=@()}; $diagnosticStage='fixture'
    function Add-UpgradeDiagnostic { param($Diagnostic) $result.diagnostics += $Diagnostic }
    function Invoke-ParameterProbe {
        param([string]$Text,[int[]]$Ports,[object]$Capability,[switch]$InProcess,[switch]$Enabled)
        [pscustomobject]@{Text=$Text;Ports=$Ports;SameObject=[object]::ReferenceEquals($Capability,$expectedCapability);InProcess=[bool]$InProcess;Enabled=[bool]$Enabled}|ConvertTo-Json -Compress
    }
    $expectedCapability=[object]::new()
    $parameters=@{Text='-literal value with spaces';Ports=@(28337,28338);Capability=$expectedCapability;Enabled=$false}
    $probe=Invoke-InProcessPowerShellJson -Script 'Invoke-ParameterProbe' -Parameters $parameters
    Assert-Equal $parameters.Text $probe.Text 'Dash-prefixed values are values, not switches'
    Assert-Equal 2 $probe.Ports.Count 'Arrays survive in-process splatting'
    Assert-True $probe.SameObject 'Live capabilities are not serialized'
    Assert-True $probe.InProcess 'In-process execution remains explicit'
    Assert-False $probe.Enabled 'False switches stay false'
    Assert-False ($parameters.ContainsKey('InProcess')) 'Caller parameter tables are not mutated'

    . ([scriptblock]::Create((Get-TestDefinition -File $file -Name 'Invoke-ChildPowerShellJson')))
    $bundledHost=[pscustomobject]@{Invoke={param($Name,$Arguments) [pscustomobject]@{Json=[pscustomobject]@{ok=$false};ExitCode=7;Text='fixture failure'}}}
    Assert-Throws { Invoke-ChildPowerShellJson -Script 'fixture.ps1' -Arguments @() } 'Nonzero child exit remains a failure'
    if($file -eq 'Invoke-CpaStackUpgrade.ps1') {
        $probe=Invoke-ChildPowerShellJson -Script 'fixture.ps1' -Arguments @() -AllowNonZero
        Assert-False $probe.ok 'Expected nonzero status still exposes its result'
    }
    $bundledHost=[pscustomobject]@{Invoke={param($Name,$Arguments) [pscustomobject]@{Json=$null;ExitCode=0;Text='not json'}}}
    Assert-Throws { Invoke-ChildPowerShellJson -Script 'fixture.ps1' -Arguments @() } 'Missing JSON remains a failure'
} }
& {
    . ([scriptblock]::Create((Get-TestDefinition -File 'Invoke-CpaStackMaintenance.ps1' -Name 'Invoke-BundledJson')))
    $bundledHost=[pscustomobject]@{Invoke={param($Name,$Arguments) [pscustomobject]@{Json=[pscustomobject]@{success=$false};ExitCode=7;Text='fixture failure'}}}
    Assert-Throws { Invoke-BundledJson -Script 'fixture.ps1' } 'Maintenance rejects unexpected nonzero exits'
    $run=Invoke-BundledJson -Script 'fixture.ps1' -AllowNonZero
    Assert-Equal 7 $run.ExitCode 'Maintenance retains exit code for classification'
    Assert-False $run.Json.success 'Maintenance retains failure JSON'
    $bundledHost=[pscustomobject]@{Invoke={param($Name,$Arguments) [pscustomobject]@{Json=$null;ExitCode=0;Text='not json'}}}
    Assert-Throws { Invoke-BundledJson -Script 'fixture.ps1' -AllowNonZero } 'Maintenance cannot accept missing JSON'
}
'Shared runtime and invocation checks passed.'
