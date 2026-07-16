#requires -Version 5.1

$entry = Join-Path $PSScriptRoot 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw "CPA Stack Updater entrypoint is missing: $entry"
}
& $entry @args
exit $LASTEXITCODE
