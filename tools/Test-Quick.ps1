#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$timer = [Diagnostics.Stopwatch]::StartNew()
foreach ($path in @(Get-ChildItem $repo -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '\\.git\\' })) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Syntax error in $($path.Name): $($errors[0].Message)" }
}
foreach ($test in @('PlatformContract.Tests.ps1', 'SharedRuntime.Tests.ps1', 'AuthLogBoundary.Tests.ps1', 'GitHubAuthentication.Tests.ps1', 'RecoveryPhase.Tests.ps1', 'UpgradeFlow.Tests.ps1', 'ManagerBackupPlacement.Tests.ps1', 'ManagerSetupRetry.Tests.ps1')) {
    & (Join-Path (Join-Path $repo 'tests') $test)
}
& python -B -m unittest discover -s (Join-Path $repo 'tests') -p 'test_*.py' -q
if ($LASTEXITCODE -ne 0) { throw 'SQLite backup checks failed.' }
'Quick checks passed in {0:N2}s. Extended integration tests were not run.' -f $timer.Elapsed.TotalSeconds
