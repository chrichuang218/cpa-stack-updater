#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
$path=Join-Path $repo 'skills\cpa-safe-upgrade\scripts\Switch-ManagerRuntime.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Equal 0 $errors.Count 'Manager switch parses'
$main=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
$prepare=@($main.Body.Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('Manager rollback executable snapshot hash validation failed.')})
Assert-Equal 1 $prepare.Count 'Program backup is prepared once, before the switch try block'
$stop=$main.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Stop-CpaStackPort'},$true)
$backup=$main.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Copy-ManagerDataSnapshot'},$true)
Assert-True ($prepare[0].Extent.EndOffset -lt $stop.Extent.StartOffset) 'Program backup completes before stopping Manager'
Assert-True ($stop.Extent.EndOffset -lt $backup.Extent.StartOffset) 'Database and data.key backup remains after stop'
$prepareBlock=[scriptblock]::Create($prepare[0].Extent.Text)
$ControlRoot=Join-Path ([IO.Path]::GetTempPath()) ('cpa-backup-order-'+[guid]::NewGuid().ToString('N'))
$SourceRuntime=Join-Path $ControlRoot 'source'
$rollbackRoot=Join-Path $ControlRoot 'rollback\last-known-good\manager-plus'
$pending=Join-Path $ControlRoot ('rollback\pending-manager-'+('1'*32))
$snapshotStaging=Join-Path $ControlRoot ('rollback\staging-manager-'+('1'*32))
$sameRuntime=$true; $sameData=$true
New-Item -ItemType Directory -Path (Join-Path $SourceRuntime 'data') -Force | Out-Null
$exe=Join-Path $SourceRuntime 'cpa-manager-plus.exe'
[IO.File]::WriteAllText($exe,'fixture old program')
[IO.File]::WriteAllText((Join-Path $SourceRuntime 'server.log'),'fixture log')
[IO.File]::WriteAllText((Join-Path $SourceRuntime 'data\usage.sqlite'),'fixture data; must not copy online')
$result=@{oldHash=Get-CpaStackFileHash -Path $exe}
try {
    & $prepareBlock
    Assert-Equal $result.oldHash (Get-CpaStackFileHash -Path (Join-Path $snapshotStaging 'runtime\cpa-manager-plus.exe')) 'Prepared program is identical'
    Assert-False (Test-Path (Join-Path $snapshotStaging 'runtime\data')) 'Preparation does not copy live database'
    Assert-False (Test-Path (Join-Path $snapshotStaging 'runtime\server.log')) 'Preparation excludes logs'
    [IO.File]::WriteAllText($exe,'unexpected program change')
    Assert-Throws { & $prepareBlock } 'A bad program backup fails before stop'
} finally { Remove-Item -LiteralPath $ControlRoot -Recurse -Force }
'Manager backup placement checks passed.'
