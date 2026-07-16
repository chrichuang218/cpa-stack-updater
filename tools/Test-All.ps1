#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

foreach ($test in @(
    'tests\Static.Tests.ps1',
    'tests\PathSafety.Tests.ps1',
    'tests\SafetyRegression.Tests.ps1',
    'tests\SecretAndEnvironment.Tests.ps1',
    'tests\Adoption.Tests.ps1',
    'tests\Install.Tests.ps1',
    'tests\Cli.Tests.ps1',
    'tests\TransactionIntegration.Tests.ps1'
)) {
    Write-Host "Running $test"
    & (Join-Path $repo $test)
}

$python = Get-Command python -ErrorAction Stop
$pythonHexOutput = @(& $python.Source -c 'import sys; print(sys.hexversion)' 2>&1)
$pythonExitCode = $LASTEXITCODE
$pythonHexVersionText = (@($pythonHexOutput | ForEach-Object { [string]$_ }) -join '').Trim()
$pythonHexVersion = 0L
if ($pythonExitCode -ne 0 -or
    -not [long]::TryParse($pythonHexVersionText, [ref]$pythonHexVersion) -or
    $pythonHexVersion -lt 0x030A00F0) {
    throw "Python 3.10 or newer is required for tests. HexVersion=$pythonHexVersionText"
}
& $python.Source -m py_compile (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\backup_sqlite.py')
if ($LASTEXITCODE -ne 0) { throw 'Python syntax validation failed.' }
& $python.Source -m unittest discover -s (Join-Path $repo 'tests') -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Python regression tests failed.' }

Write-Host 'All tests passed.'
