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

    $capturePath = Join-Path $temp 'captured.txt'

    [Environment]::SetEnvironmentVariable('CPA_STACK_SYNTHETIC_SECRET', $sentinel, 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', ('https://user:' + $sentinel + '@127.0.0.1:9'), 'Process')
    $commandPrompt = (Get-Command cmd.exe -ErrorAction Stop).Source
    $arguments = '/d /c set > "{0}"' -f $capturePath
    $process = Start-CpaStackProcess -FilePath $commandPrompt -Arguments $arguments -WorkingDirectory $temp -Environment @{ CPA_STACK_EXPLICIT_VALUE = 'allowed-override' } -MinimalEnvironment
    $processExited = $process.WaitForExit(15000)
    Assert-True $processExited 'Minimal-environment child exits within the test timeout'
    $process.WaitForExit()
    Assert-Equal 0 $process.ExitCode 'Minimal-environment child exits successfully'
    $captured = [System.IO.File]::ReadAllText($capturePath)
    Assert-False ($captured -match '(?im)^CPA_STACK_SYNTHETIC_SECRET=') 'Unrelated parent secrets are not inherited by candidates'
    Assert-False ($captured -match '(?im)^HTTPS_PROXY=') 'Proxy URLs with embedded credentials are not inherited by managed processes'
    Assert-False $captured.Contains($sentinel) 'The child environment does not contain the synthetic secret sentinel'
    Assert-True ($captured -match '(?im)^CPA_STACK_EXPLICIT_VALUE=allowed-override\r?$') 'Explicit candidate environment values are preserved'
    Assert-True ($captured -match '(?im)^SystemRoot=.+\r?$') 'Required Windows environment values are preserved'
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
