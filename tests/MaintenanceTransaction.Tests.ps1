#requires -Version 5.1

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'TransactionIntegration.Tests.ps1') -Case Maintenance
exit $(if ($?) { 0 } else { 1 })
