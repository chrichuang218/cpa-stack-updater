$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
. $commonPath

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-process-lifecycle-' + [guid]::NewGuid().ToString('N'))
$captureProcess = $null
$managedProcessId = 0

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    $expectedExecutable = Join-Path $temp 'managed-service.exe'
    Set-Content -LiteralPath $expectedExecutable -Value 'fixture' -Encoding ASCII

    $originalListenerFunction = ${function:Get-CpaStackListener}
    $originalFileReadyFunction = ${function:Test-CpaStackFileReadyForReplacement}
    $script:hasExitedQueries = 0
    $script:stopCalled = $false
    $script:stopProcessCommandCalled = $false
    $script:fileProbeCalled = $false
    $script:connectionOwners = @()
    $fakeProcess = [pscustomobject]@{
        Id = 42420
        Handle = [IntPtr]::new(1)
        MainModule = [pscustomobject]@{ FileName = $expectedExecutable }
    }
    $fakeProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $script:stopCalled = $true
    }
    $fakeProcess | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
        $script:hasExitedQueries++
        return $script:hasExitedQueries -ge 3
    }
    function Get-CpaStackListener {
        param([int]$Port)
        return [pscustomobject]@{
            ProcessId = 42420
            ExecutablePath = $expectedExecutable
        }
    }
    function Stop-Process {
        param(
            [int]$Id,
            [switch]$Force,
            $ErrorAction
        )
        $script:stopProcessCommandCalled = $true
    }
    function Get-NetTCPConnection {
        param(
            [int]$LocalPort,
            [string]$State,
            $ErrorAction
        )
        return @($script:connectionOwners | ForEach-Object { [pscustomobject]@{ OwningProcess = [int]$_ } })
    }
    function Get-Process {
        param(
            [int]$Id,
            $ErrorAction
        )
        return $fakeProcess
    }
    function Test-CpaStackFileReadyForReplacement {
        param([string]$Path)
        $script:fileProbeCalled = $true
        throw [System.UnauthorizedAccessException]::new('Synthetic read-only executable fixture.')
    }

    try {
        Stop-CpaStackPort -Port 43117 -ExpectedPath $expectedExecutable -WaitSeconds 3
        Assert-True $script:stopCalled 'The expected listener process is stopped'
        Assert-False $script:stopProcessCommandCalled 'The fixed process handle is terminated instead of looking up a reusable PID'
        Assert-True ($script:hasExitedQueries -ge 3) 'Port shutdown waits for the original process to exit after its listener disappears'
        Assert-False $script:fileProbeCalled 'A read-only legacy executable is not write-probed when no replacement is requested'

        $script:hasExitedQueries = 0
        $script:stopCalled = $false
        $detachedProcess = [pscustomobject]@{
            Id = 42421
            Handle = [IntPtr]::new(2)
            MainModule = [pscustomobject]@{ FileName = $expectedExecutable }
        }
        $detachedProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            $script:stopCalled = $true
        }
        $detachedProcess | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
            $script:hasExitedQueries++
            return $script:hasExitedQueries -ge 3
        }
        function Get-CpaStackListener { param([int]$Port); return $null }
        Stop-CpaStackPort -Port 43117 -ExpectedPath $expectedExecutable -ExpectedProcess $detachedProcess -WaitSeconds 3
        Assert-True $script:stopCalled 'A fixed process is stopped even when its listener disappeared before Stop-CpaStackPort entered'
        Assert-True ($script:hasExitedQueries -ge 3) 'Pre-entry listener loss still waits for the fixed process to exit'

        $script:stopCalled = $false
        $alreadyExitedProcess = [pscustomobject]@{
            Id = 42422
            Handle = [IntPtr]::new(3)
            MainModule = [pscustomobject]@{ FileName = $expectedExecutable }
            HasExited = $true
        }
        $alreadyExitedProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            $script:stopCalled = $true
        }
        Stop-CpaStackPort -Port 43117 -ExpectedPath $expectedExecutable -ExpectedProcess $alreadyExitedProcess -WaitSeconds 3
        Assert-False $script:stopCalled 'An already-exited fixed process is accepted when the port remains free'

        $script:stopCalled = $false
        $script:hasExitedQueries = 0
        $script:connectionOwners = @(49999)
        function Get-CpaStackListener {
            param([int]$Port)
            return [pscustomobject]@{
                ProcessId = 49999
                ExecutablePath = (Join-Path $temp 'unexpected-service.exe')
            }
        }
        $ownerRejected = $false
        try {
            Stop-CpaStackPort -Port 43117 -ExpectedPath $expectedExecutable -ExpectedProcess $detachedProcess -WaitSeconds 3
        } catch {
            $ownerRejected = $_.Exception.Message -match 'unexpected process'
        }
        Assert-True $ownerRejected 'A replacement port owner is rejected instead of being terminated'
        Assert-True $script:stopCalled 'The detached fixed process is still terminated after a replacement owner is detected'
        $script:connectionOwners = @()
    } finally {
        Set-Item -LiteralPath Function:Get-CpaStackListener -Value $originalListenerFunction
        Set-Item -LiteralPath Function:Test-CpaStackFileReadyForReplacement -Value $originalFileReadyFunction
        Remove-Item -LiteralPath Function:Stop-Process -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath Function:Get-NetTCPConnection -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath Function:Get-Process -ErrorAction SilentlyContinue
    }
    $managedScript = Join-Path $temp 'start-managed-child.ps1'
    $captureScript = Join-Path $temp 'capture-child-output.ps1'
    $pidPath = Join-Path $temp 'managed.pid'
    $outputPath = Join-Path $temp 'capture.json'
    $captureStdoutPath = Join-Path $temp 'capture.stdout.log'
    $captureStderrPath = Join-Path $temp 'capture.stderr.log'

    Set-Content -LiteralPath $managedScript -Encoding ASCII -Value @'
param(
    [string]$CommonPath,
    [string]$PidPath
)
$ErrorActionPreference = 'Stop'
. $CommonPath
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$process = Start-CpaStackProcess `
    -FilePath $powershell `
    -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' `
    -WorkingDirectory (Split-Path -Parent $PidPath) `
    -MinimalEnvironment
[System.IO.File]::WriteAllText($PidPath, [string]$process.Id, [System.Text.UTF8Encoding]::new($false))
[pscustomobject]@{ success = $true; processId = $process.Id } | ConvertTo-Json -Compress
'@

    Set-Content -LiteralPath $captureScript -Encoding ASCII -Value @'
param(
    [string]$ManagedScript,
    [string]$CommonPath,
    [string]$PidPath,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ManagedScript -CommonPath $CommonPath -PidPath $PidPath 2>&1)
[System.IO.File]::WriteAllLines($OutputPath, @($output | ForEach-Object { [string]$_ }), [System.Text.UTF8Encoding]::new($false))
'@

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $captureArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ManagedScript "{1}" -CommonPath "{2}" -PidPath "{3}" -OutputPath "{4}"' -f `
        $captureScript, $managedScript, $commonPath, $pidPath, $outputPath
    $captureProcess = Start-Process -FilePath $powershell -ArgumentList $captureArguments -WindowStyle Hidden -RedirectStandardOutput $captureStdoutPath -RedirectStandardError $captureStderrPath -PassThru

    $pidDeadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $pidPath -PathType Leaf) -and (Get-Date) -lt $pidDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        $captureState = if ($captureProcess.HasExited) { "exited=$($captureProcess.ExitCode)" } else { 'still-running' }
        $capturedText = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { [System.IO.File]::ReadAllText($outputPath) } else { 'no-output' }
        $captureError = if (Test-Path -LiteralPath $captureStderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($captureStderrPath) } else { 'no-stderr' }
        throw "Nested managed process did not report its process id. Capture=$captureState Output=$capturedText Error=$captureError"
    }
    Assert-True (Test-Path -LiteralPath $pidPath -PathType Leaf) 'The nested managed process reports its process id'
    $managedProcessId = [int]([System.IO.File]::ReadAllText($pidPath).Trim())

    $captureExited = $captureProcess.WaitForExit(15000)
    Assert-True $captureExited 'Nested PowerShell output capture reaches EOF while the managed process remains alive'
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'The nested script result is captured'
    $capturedResult = [System.IO.File]::ReadAllText($outputPath) | ConvertFrom-Json
    Assert-True ([bool]$capturedResult.success) 'The nested managed-process launcher returns structured success'
    Assert-True ($null -ne (Get-Process -Id $managedProcessId -ErrorAction SilentlyContinue)) 'The managed process outlives the completed nested launcher'
    $managedProcess = Get-Process -Id $managedProcessId -ErrorAction Stop
    try {
        Stop-CpaStackStartedProcess -Process $managedProcess -ExpectedPath $powershell
    } finally {
        $managedProcess.Dispose()
    }
    Assert-True ($null -eq (Get-Process -Id $managedProcessId -ErrorAction SilentlyContinue)) 'A started process without a listener is stopped through its fixed process object'
    $managedProcessId = 0
    $captureProcess.Dispose()
    $captureProcess = $null
    Remove-Item -LiteralPath $pidPath, $outputPath -Force

    $standaloneSourcePath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
    $standaloneSource = [System.IO.File]::ReadAllText($standaloneSourcePath, [System.Text.UTF8Encoding]::new($false, $true))
    $nativeStart = $standaloneSource.IndexOf('function Initialize-CpaStackNativeProcessType {', [System.StringComparison]::Ordinal)
    $nativeEnd = $standaloneSource.IndexOf('function Get-ListenerProcess {', $nativeStart, [System.StringComparison]::Ordinal)
    Assert-True ($nativeStart -ge 0 -and $nativeEnd -gt $nativeStart) 'The standalone launcher process helper can be isolated for its runtime test'
    $standaloneFunctions = $standaloneSource.Substring($nativeStart, $nativeEnd - $nativeStart)
    $standaloneManagedScript = Join-Path $temp 'start-standalone-managed-child.ps1'
    $standalonePrefix = @'
param(
    [string]$CommonPath,
    [string]$PidPath
)
$ErrorActionPreference = 'Stop'
'@
    $standaloneSuffix = @'
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$process = Start-ManagedProcess `
    -FilePath $powershell `
    -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' `
    -WorkingDirectory (Split-Path -Parent $PidPath)
[System.IO.File]::WriteAllText($PidPath, [string]$process.Id, [System.Text.UTF8Encoding]::new($false))
[pscustomobject]@{ success = $true; processId = $process.Id } | ConvertTo-Json -Compress
'@
    [System.IO.File]::WriteAllText(
        $standaloneManagedScript,
        ($standalonePrefix + [Environment]::NewLine + $standaloneFunctions + [Environment]::NewLine + $standaloneSuffix),
        [System.Text.UTF8Encoding]::new($false))

    $captureArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ManagedScript "{1}" -CommonPath "{2}" -PidPath "{3}" -OutputPath "{4}"' -f `
        $captureScript, $standaloneManagedScript, $commonPath, $pidPath, $outputPath
    $captureProcess = Start-Process -FilePath $powershell -ArgumentList $captureArguments -WindowStyle Hidden -RedirectStandardOutput $captureStdoutPath -RedirectStandardError $captureStderrPath -PassThru
    $pidDeadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $pidPath -PathType Leaf) -and (Get-Date) -lt $pidDeadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $pidPath -PathType Leaf) 'The standalone launcher reports its managed process id'
    $managedProcessId = [int]([System.IO.File]::ReadAllText($pidPath).Trim())
    $captureExited = $captureProcess.WaitForExit(15000)
    Assert-True $captureExited 'Standalone launcher output reaches EOF while its managed process remains alive'
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'The standalone launcher result is captured'
    $capturedResult = [System.IO.File]::ReadAllText($outputPath) | ConvertFrom-Json
    Assert-True ([bool]$capturedResult.success) 'The standalone launcher returns structured success'
    Assert-True ($null -ne (Get-Process -Id $managedProcessId -ErrorAction SilentlyContinue)) 'The standalone managed process outlives its completed launcher'
} finally {
    if ($managedProcessId -gt 0) {
        Stop-Process -Id $managedProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $managedProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
    if ($null -ne $captureProcess) {
        try {
            if (-not $captureProcess.HasExited -and -not $captureProcess.WaitForExit(15000)) {
                $captureProcess.Kill()
                if (-not $captureProcess.WaitForExit(5000)) {
                    throw 'The nested PowerShell capture process could not be stopped before fixture cleanup.'
                }
            }
        } finally {
            $captureProcess.Dispose()
        }
    }
    Remove-TestPathWithRetry -Path $temp
}

'Process lifecycle tests passed.'
