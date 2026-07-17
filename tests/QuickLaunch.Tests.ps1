$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$bootstrapPath = Join-Path $repo 'skills\cpa-safe-upgrade\installer\Start-CPA-Stack.bootstrap.ps1'
$starterPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$bootstrap = [System.IO.File]::ReadAllText($bootstrapPath, $utf8)
$starter = [System.IO.File]::ReadAllText($starterPath, $utf8)

Assert-True ($bootstrap -match 'Start-CPA-Stack\.ps1') 'Quick launch delegates directly to the bundled starter instead of the full transaction CLI'
Assert-True ($bootstrap -match '(?s)\$starterParameters\s*=\s*@\{.+Fast\s*=\s*\$true.+ReturnResult\s*=\s*\$true') 'Quick launch explicitly selects the direct fast-start contract'
Assert-True ($bootstrap -match '&\s+\$starter\s+@starterParameters') 'Quick launch invokes the bundled starter with named parameter splatting'
Assert-True ($bootstrap -match 'InteractiveProgress\s*=\s*\$interactiveConsole') 'Interactive quick launch streams stage output from the same visible PowerShell process'
Assert-False ($bootstrap -match '\b(?:Start-Job|Start-Process)\b') 'Quick launch does not create a second PowerShell host'
Assert-False ($bootstrap -match 'scripts\\cpa-stack\.ps1') 'Quick launch bypasses full cpa-stack start preflight'
Assert-True ($starter -match 'function Write-CpaStackStartProgress') 'Bundled starter emits progress through a protocol-safe file channel'
Assert-True ($starter -match '\[switch\]\$Fast') 'Bundled starter exposes an explicit fast mode'
foreach ($stage in @('Validating stack configuration', 'Checking CPA API', 'Checking Manager')) {
    Assert-True ($starter.Contains($stage)) "Bundled starter reports the '$stage' stage"
}

'Quick launch tests passed.'
