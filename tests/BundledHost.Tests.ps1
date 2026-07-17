$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repo 'skills\cpa-safe-upgrade\modules\CpaStack.BundledHost.psm1'
$bundledStarterPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-bundled-host-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    @'
[pscustomobject]@{ success = $true; mode = 'pretty' } | ConvertTo-Json
'@ | Set-Content -LiteralPath (Join-Path $temp 'pretty.ps1') -Encoding ASCII
    @'
Write-Output 'diagnostic line'
[pscustomobject]@{ success = $true; mode = 'single-line' } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $temp 'single.ps1') -Encoding ASCII
    @'
[pscustomobject]@{ success = $true; sequence = 1 } | ConvertTo-Json -Compress
[pscustomobject]@{ success = $true; sequence = 2 } | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath (Join-Path $temp 'multiple.ps1') -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $temp 'none.ps1') -Value 'Write-Output ''not json''' -Encoding ASCII
    @'
[pscustomobject]@{ success = $false; error = 'synthetic failure' } | ConvertTo-Json -Compress
[Console]::Error.WriteLine('synthetic stderr')
exit 7
'@ | Set-Content -LiteralPath (Join-Path $temp 'failure.ps1') -Encoding ASCII

    Import-Module $modulePath -Force
    $hostAdapter = New-CpaStackBundledHost -ScriptsRoot $temp

    $bundledStarter = [System.IO.File]::ReadAllText($bundledStarterPath, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-False ($bundledStarter -match '(?m)\bClear-Host\b|RawUI') 'Bundled starter does not own console layout or window state'
    Assert-True ($bundledStarter -match '(?s)if\s*\(\$InteractiveProgress\).+Write-Host') 'Bundled starter host output is explicitly gated behind InteractiveProgress'

    $pretty = Invoke-CpaStackBundled -HostAdapter $hostAdapter -Name 'pretty.ps1'
    Assert-Equal 'pretty' $pretty.Json.mode 'A single pretty-printed JSON object is accepted'
    Assert-Equal $null $pretty.ProtocolError 'A valid pretty JSON document has no protocol error'

    $single = Invoke-CpaStackBundled -HostAdapter $hostAdapter -Name 'single.ps1'
    Assert-Equal 'single-line' $single.Json.mode 'One JSON object line may follow non-JSON diagnostics'
    Assert-Equal $null $single.ProtocolError 'Exactly one JSON object line has no protocol error'

    $multiple = Invoke-CpaStackBundled -HostAdapter $hostAdapter -Name 'multiple.ps1'
    Assert-Equal $null $multiple.Json 'Multiple JSON documents are never selected arbitrarily'
    Assert-Equal 'MultipleJsonDocuments' $multiple.ProtocolError.code 'Multiple JSON documents return a stable protocol error'

    $none = Invoke-CpaStackBundled -HostAdapter $hostAdapter -Name 'none.ps1'
    Assert-Equal $null $none.Json 'Non-JSON output has no result document'
    Assert-Equal 'NoJsonDocument' $none.ProtocolError.code 'Non-JSON output returns a stable protocol error'

    $failure = Invoke-CpaStackBundled -HostAdapter $hostAdapter -Name 'failure.ps1'
    Assert-Equal 7 $failure.ExitCode 'A bundled failure preserves its process exit code'
    Assert-False ([bool]$failure.Json.success) 'A bundled failure still returns its JSON result for transaction classification'
    Assert-Equal 'synthetic failure' ([string]$failure.Json.error) 'A bundled failure JSON document is not replaced by stderr'
    Assert-Equal $null $failure.ProtocolError 'One failure JSON document remains protocol-valid'

    Assert-ThrowsMatch {
        Invoke-CpaStackBundled -HostAdapter $hostAdapter -Name '..\outside.ps1'
    } 'name is invalid' 'Bundled host rejects path traversal instead of resolving it'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
}

'Bundled host tests passed.'
