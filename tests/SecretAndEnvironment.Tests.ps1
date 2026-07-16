$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
. $commonPath

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-secret-env-tests-' + [guid]::NewGuid().ToString('N'))
$sentinel = 'SYNTHETIC_SECRET_SENTINEL_42'
$previousSynthetic = [Environment]::GetEnvironmentVariable('CPA_STACK_SYNTHETIC_SECRET', 'Process')
$previousHttpsProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process')
$process = $null
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $temp 'config') | Out-Null
    $badSecrets = Join-Path $temp 'config\secrets.local.json'
    Set-Content -LiteralPath $badSecrets -Value ('{"cpaClientApiKey":"' + $sentinel + '",BROKEN') -Encoding UTF8
    $secretError = $null
    try {
        [void](Get-CpaStackSecrets -ControlRoot $temp)
    } catch {
        $secretError = $_.Exception.Message
    }
    Assert-Equal 'Canonical secrets file is not valid UTF-8 JSON.' $secretError 'Malformed secret JSON returns a fixed error'
    Assert-False (([string]$secretError).Contains($sentinel)) 'Malformed secret JSON never echoes its contents'

    $captureScript = Join-Path $temp 'capture-environment.ps1'
    $capturePath = Join-Path $temp 'captured.json'
    @'
param([string]$OutputPath)
[pscustomobject]@{
    syntheticPresent = -not [string]::IsNullOrEmpty($env:CPA_STACK_SYNTHETIC_SECRET)
    proxyCredentialPresent = (-not [string]::IsNullOrEmpty($env:HTTPS_PROXY) -and $env:HTTPS_PROXY.Contains('SYNTHETIC_SECRET_SENTINEL_42'))
    explicitValue = $env:CPA_STACK_EXPLICIT_VALUE
    systemRootPresent = -not [string]::IsNullOrEmpty($env:SystemRoot)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $OutputPath -Encoding ASCII
'@ | Set-Content -LiteralPath $captureScript -Encoding ASCII

    [Environment]::SetEnvironmentVariable('CPA_STACK_SYNTHETIC_SECRET', $sentinel, 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', ('https://user:' + $sentinel + '@127.0.0.1:9'), 'Process')
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}"' -f $captureScript, $capturePath
    $process = Start-CpaStackProcess -FilePath $powershell -Arguments $arguments -WorkingDirectory $temp -Environment @{ CPA_STACK_EXPLICIT_VALUE = 'allowed-override' } -MinimalEnvironment
    $processExited = $process.WaitForExit(15000)
    Assert-True $processExited 'Minimal-environment child exits within the test timeout'
    $process.WaitForExit()
    Assert-Equal 0 $process.ExitCode 'Minimal-environment child exits successfully'
    $captured = Get-Content -Raw -LiteralPath $capturePath | ConvertFrom-Json
    Assert-False ([bool]$captured.syntheticPresent) 'Unrelated parent secrets are not inherited by candidates'
    Assert-False ([bool]$captured.proxyCredentialPresent) 'Proxy URLs with embedded credentials are not inherited by managed processes'
    Assert-Equal 'allowed-override' $captured.explicitValue 'Explicit candidate environment values are preserved'
    Assert-True ([bool]$captured.systemRootPresent) 'Required Windows environment values are preserved'
} finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        } finally {
            $process.Dispose()
        }
    }
    [Environment]::SetEnvironmentVariable('CPA_STACK_SYNTHETIC_SECRET', $previousSynthetic, 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $previousHttpsProxy, 'Process')
    Remove-TestPathWithRetry -Path $temp
}

'Secret and environment tests passed.'
