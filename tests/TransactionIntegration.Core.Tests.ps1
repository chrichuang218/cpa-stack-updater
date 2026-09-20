#requires -Version 7.0

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'TransactionIntegration.Tests.ps1') -Case Core
exit $(if ($?) { 0 } else { 1 })
