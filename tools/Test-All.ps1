#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'CpaStack.ProductionGuard.psm1') -Force

function Get-CpaStackProductionArtifactSnapshot {
    param(
        [string[]]$ProductionRoot,
        [string]$ProductionStateHome,
        [object[]]$ListenerSnapshot,
        [int[]]$ProductionPort
    )

    $filePaths = New-Object System.Collections.Generic.List[string]
    $directoryPaths = New-Object System.Collections.Generic.List[string]
    $locatorPath = Join-Path $ProductionStateHome 'root.json'
    if (Test-Path -LiteralPath $locatorPath -PathType Leaf) { $filePaths.Add($locatorPath) }
    $lockDirectory = Join-Path $ProductionStateHome 'locks'
    $operationLockPath = Join-Path $lockDirectory 'CPAStackSafeOperation.lock'
    if (Test-Path -LiteralPath $lockDirectory -PathType Container) { $directoryPaths.Add($lockDirectory) }
    if (Test-Path -LiteralPath $operationLockPath -PathType Leaf) { $filePaths.Add($operationLockPath) }
    foreach ($listener in @($ListenerSnapshot | Where-Object { [int]$_.LocalPort -in $ProductionPort })) {
        if (-not [string]::IsNullOrWhiteSpace([string]$listener.ExecutablePath) -and
            (Test-Path -LiteralPath ([string]$listener.ExecutablePath) -PathType Leaf)) {
            $filePaths.Add([string]$listener.ExecutablePath)
        }
    }
    foreach ($root in @($ProductionRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $directoryPaths.Add($root)
        $parent = Split-Path -Parent $root
        if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent -PathType Container)) {
            $directoryPaths.Add($parent)
        }
        foreach ($relative in @('.cpa-stack-instance.json', 'state\current.json', 'config\stack.psd1', 'ops\Start-CPA-Stack.ps1')) {
            $path = Join-Path $root $relative
            if (Test-Path -LiteralPath $path -PathType Leaf) { $filePaths.Add($path) }
        }
        foreach ($relative in @('state', 'config', 'ops', 'runtime', 'data')) {
            $path = Join-Path $root $relative
            if (Test-Path -LiteralPath $path -PathType Container) { $directoryPaths.Add($path) }
        }

        $currentPath = Join-Path $root 'state\current.json'
        if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
            $current = Read-CpaStackJson -Path $currentPath
            foreach ($recordedExecutable in @([string]$current.cpa.executable, [string]$current.manager.executable)) {
                if ([string]::IsNullOrWhiteSpace($recordedExecutable)) { continue }
                $executable = if ([System.IO.Path]::IsPathRooted($recordedExecutable)) { $recordedExecutable } else { Join-Path $root $recordedExecutable }
                if (Test-Path -LiteralPath $executable -PathType Leaf) {
                    $filePaths.Add($executable)
                }
            }
        }
        $stackPath = Join-Path $root 'config\stack.psd1'
        if (Test-Path -LiteralPath $stackPath -PathType Leaf) {
            $stack = Import-PowerShellDataFile -LiteralPath $stackPath
            $cpaConfig = if ([System.IO.Path]::IsPathRooted([string]$stack.Cpa.Config)) {
                [string]$stack.Cpa.Config
            } else {
                Join-Path $root ([string]$stack.Cpa.Config)
            }
            if (Test-Path -LiteralPath $cpaConfig -PathType Leaf) { $filePaths.Add($cpaConfig) }
            $managerData = if ([System.IO.Path]::IsPathRooted([string]$stack.Manager.DataDirectory)) {
                [string]$stack.Manager.DataDirectory
            } else {
                Join-Path $root ([string]$stack.Manager.DataDirectory)
            }
            $dataKey = Join-Path $managerData 'data.key'
            if (Test-Path -LiteralPath $dataKey -PathType Leaf) { $filePaths.Add($dataKey) }
        }
    }

    $accessSections = [System.Security.AccessControl.AccessControlSections]'Owner,Group,Access'
    $files = foreach ($path in @($filePaths | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Sort-Object -Unique)) {
        $item = Get-Item -LiteralPath $path -Force
        $acl = Get-CpaStackFileSystemAcl -Path $path
        [ordered]@{
            path = $item.FullName
            length = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            sddl = $acl.GetSecurityDescriptorSddlForm($accessSections)
        }
    }
    $directories = foreach ($path in @($directoryPaths | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)) {
        $acl = Get-CpaStackFileSystemAcl -Path $path
        [ordered]@{ path = $path; sddl = $acl.GetSecurityDescriptorSddlForm($accessSections) }
    }
    return ([ordered]@{ files = @($files); directories = @($directories) } | ConvertTo-Json -Depth 6 -Compress)
}

function Assert-CpaStackProductionBaseline {
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][string]$ArtifactBaseline,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ProductionRoot,
        [Parameter(Mandatory = $true)][string]$ProductionStateHome,
        [Parameter(Mandatory = $true)][int[]]$ProductionPort,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $comparison = Compare-CpaStackProductionListenerSnapshot -Guard $Guard
    if (-not $comparison.Unchanged) {
        throw "Production listener ownership changed $Stage."
    }
    $artifacts = Get-CpaStackProductionArtifactSnapshot `
        -ProductionRoot $ProductionRoot `
        -ProductionStateHome $ProductionStateHome `
        -ListenerSnapshot $comparison.After `
        -ProductionPort $ProductionPort
    if ($ArtifactBaseline -cne $artifacts) {
        throw "Production control files, executables, or protected ACLs changed $Stage."
    }
}

function ConvertTo-CpaStackTestBase64 {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function Invoke-CpaStackIsolatedPowerShellTest {
    param(
        [Parameter(Mandatory = $true)][string]$TestPath,
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][string]$CommonPath,
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][int[]]$ProtectedPort,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 1200
    )

    New-Item -ItemType Directory -Force -Path $CaseRoot | Out-Null
    $testTemp = Join-Path $CaseRoot 'temp'
    $testStateBoundary = Join-Path $CaseRoot 'fixture-state-boundary'
    $testStackRoot = Join-Path $CaseRoot 'isolated-stack-root'
    $testStackConfigDirectory = Join-Path $testStackRoot 'config'
    New-Item -ItemType Directory -Force -Path $testTemp, $testStateBoundary, $testStackConfigDirectory | Out-Null
    $isolatedPortPlan = New-CpaStackTestPortPlan -Guard $Guard -Name @('IsolatedRootCpa', 'IsolatedRootManager')
    $isolatedRootPorts = @(
        [int]$isolatedPortPlan.Ports.IsolatedRootCpa,
        [int]$isolatedPortPlan.Ports.IsolatedRootManager
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $testStackConfigDirectory 'stack.psd1'),
        ("@{ Cpa = @{ Port = " + $isolatedRootPorts[0] + " }; Manager = @{ Port = " + $isolatedRootPorts[1] + " } }"),
        [System.Text.UTF8Encoding]::new($false))
    [void](Assert-CpaStackTestIsolation `
        -Guard $Guard `
        -TestRoot $CaseRoot `
        -TestStateHome $testStateBoundary `
        -TestPort $isolatedRootPorts)

    $readyPath = Join-Path $CaseRoot 'runner.ready'
    $goPath = Join-Path $CaseRoot 'runner.go'
    $stdoutPath = Join-Path $CaseRoot 'runner.stdout.log'
    $stderrPath = Join-Path $CaseRoot 'runner.stderr.log'
    $protectedPorts = @($ProtectedPort + $isolatedRootPorts | Sort-Object -Unique) -join ','
    $requestedHost = if ($PSVersionTable.PSEdition -eq 'Core') {
        Join-Path $PSHOME 'pwsh.exe'
    } else {
        Join-Path $PSHOME 'powershell.exe'
    }
    if (-not (Test-Path -LiteralPath $requestedHost -PathType Leaf)) {
        throw "The requested PowerShell test host is unavailable: $requestedHost"
    }
    $expectedEdition = [string]$PSVersionTable.PSEdition
    $expectedVersion = [string]$PSVersionTable.PSVersion
    $payload = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
function Decode([string]`$Value) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Value)) }
`$testPath = Decode '$(ConvertTo-CpaStackTestBase64 -Value ([System.IO.Path]::GetFullPath($TestPath)))'
`$testStackRoot = Decode '$(ConvertTo-CpaStackTestBase64 -Value $testStackRoot)'
`$commonPath = Decode '$(ConvertTo-CpaStackTestBase64 -Value ([System.IO.Path]::GetFullPath($CommonPath)))'
`$expectedEdition = Decode '$(ConvertTo-CpaStackTestBase64 -Value $expectedEdition)'
`$expectedVersion = Decode '$(ConvertTo-CpaStackTestBase64 -Value $expectedVersion)'
if ([string]`$PSVersionTable.PSEdition -cne `$expectedEdition -or
    [string]`$PSVersionTable.PSVersion -cne `$expectedVersion) {
    throw "PowerShell test host mismatch. Expected=`$expectedEdition/`$expectedVersion Actual=`$(`$PSVersionTable.PSEdition)/`$(`$PSVersionTable.PSVersion)"
}
`$resolvedRoot = & { param([string]`$Path); . `$Path; Resolve-CpaStackControlRoot } `$commonPath
if (-not [string]::Equals(
    [System.IO.Path]::GetFullPath(`$testStackRoot).TrimEnd('\'),
    [System.IO.Path]::GetFullPath(`$resolvedRoot).TrimEnd('\'),
    [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Isolated test root resolution escaped its case root: `$resolvedRoot"
}
try {
    & `$testPath
    `$testSucceeded = `$?
    if (-not `$testSucceeded) { exit 1 }
    exit 0
} catch {
    [Console]::Error.WriteLine(`$_.Exception.ToString())
    if (-not [string]::IsNullOrWhiteSpace([string]`$_.ScriptStackTrace)) {
        [Console]::Error.WriteLine([string]`$_.ScriptStackTrace)
    }
    exit 1
}
"@
    $encodedPayload = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($payload))
    $wrapper = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
function Decode([string]`$Value) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Value)) }
`$requestedHost = Decode '$(ConvertTo-CpaStackTestBase64 -Value $requestedHost)'
`$readyPath = Decode '$(ConvertTo-CpaStackTestBase64 -Value $readyPath)'
`$goPath = Decode '$(ConvertTo-CpaStackTestBase64 -Value $goPath)'
`$testTemp = Decode '$(ConvertTo-CpaStackTestBase64 -Value $testTemp)'
`$testStackRoot = Decode '$(ConvertTo-CpaStackTestBase64 -Value $testStackRoot)'
`$protectedPorts = Decode '$(ConvertTo-CpaStackTestBase64 -Value $protectedPorts)'
[Environment]::SetEnvironmentVariable('CPA_STACK_ROOT', `$testStackRoot, 'Process')
[Environment]::SetEnvironmentVariable('CPA_STACK_TEST_ROOT', `$testTemp, 'Process')
[Environment]::SetEnvironmentVariable('CPA_STACK_TEST_PROTECTED_PORTS', `$protectedPorts, 'Process')
[Environment]::SetEnvironmentVariable('TEMP', `$testTemp, 'Process')
[Environment]::SetEnvironmentVariable('TMP', `$testTemp, 'Process')
[System.IO.File]::WriteAllText(`$readyPath, [string]`$PID, [System.Text.Encoding]::ASCII)
`$deadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not (Test-Path -LiteralPath `$goPath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge `$deadline) { throw 'Test runner registration gate timed out.' }
    Start-Sleep -Milliseconds 25
}
& `$requestedHost -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '$encodedPayload'
`$childExitCode = if (`$null -eq `$LASTEXITCODE) { if (`$?) { 0 } else { 1 } } else { [int]`$LASTEXITCODE }
exit `$childExitCode
"@
    $encodedWrapper = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))
    $process = $null
    try {
        $process = Start-Process `
            -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedWrapper) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $process.HasExited -and [DateTime]::UtcNow -lt $readyDeadline) {
            Start-Sleep -Milliseconds 25
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            throw "Isolated test runner did not reach its registration gate: $TestPath"
        }
        [void](Register-CpaStackTestProcess -Guard $Guard -Process $process)
        [System.IO.File]::WriteAllText($goPath, 'go', [System.Text.Encoding]::ASCII)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Isolated test exceeded its $TimeoutSeconds second timeout: $TestPath"
        }
        $process.WaitForExit()
        $process.Refresh()
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            if ([int]$process.ExitCode -eq 0) {
                Write-Host $stderr.TrimEnd()
            } else {
                Write-Host $stderr.TrimEnd() -ForegroundColor DarkRed
            }
        }
        if ([int]$process.ExitCode -ne 0) {
            throw "Isolated test failed with exit code $($process.ExitCode): $TestPath"
        }
    } finally {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    [void]$process.WaitForExit(10000)
                }
            } finally {
                $process.Dispose()
            }
        }
    }
}

function Invoke-CpaStackGuardedTestCase {
    param(
        [Parameter(Mandatory = $true)][string]$TestPath,
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][string]$CommonPath,
        [Parameter(Mandatory = $true)]$BaselineGuard,
        [Parameter(Mandatory = $true)][string]$ArtifactBaseline,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ProductionRoot,
        [Parameter(Mandatory = $true)][string]$ProductionStateHome,
        [Parameter(Mandatory = $true)][int[]]$ProductionPort
    )

    Assert-CpaStackProductionBaseline `
        -Guard $BaselineGuard `
        -ArtifactBaseline $ArtifactBaseline `
        -ProductionRoot $ProductionRoot `
        -ProductionStateHome $ProductionStateHome `
        -ProductionPort $ProductionPort `
        -Stage "before test '$TestPath'"

    $caseSnapshot = @(Get-CpaStackListenerSnapshot)
    $caseProductionListeners = @($caseSnapshot | Where-Object { [int]$_.LocalPort -in $ProductionPort })
    $caseGuard = New-CpaStackProductionGuard `
        -ProductionRoot $ProductionRoot `
        -ProductionStateHome @($ProductionStateHome) `
        -ProductionPort $ProductionPort `
        -ProductionProcessId @($caseProductionListeners | ForEach-Object { [int]$_.OwningProcess }) `
        -ListenerSnapshot $caseSnapshot
    $testError = $null
    try {
        Invoke-CpaStackIsolatedPowerShellTest `
            -TestPath $TestPath `
            -CaseRoot $CaseRoot `
            -CommonPath $CommonPath `
            -Guard $caseGuard `
            -ProtectedPort $ProductionPort
    } catch {
        $testError = $_
    } finally {
        try {
            Close-CpaStackProductionGuard -Guard $caseGuard
        } catch {
            if ($null -eq $testError) {
                $testError = $_
            } else {
                $testError = [System.Management.Automation.ErrorRecord]::new(
                    [System.AggregateException]::new(
                        "Test execution and test-process cleanup both failed.",
                        $testError.Exception,
                        $_.Exception),
                    'CpaStackTestAndCleanupFailed',
                    [System.Management.Automation.ErrorCategory]::OperationStopped,
                    $TestPath)
            }
        }
    }

    $productionError = $null
    try {
        Assert-CpaStackProductionBaseline `
            -Guard $BaselineGuard `
            -ArtifactBaseline $ArtifactBaseline `
            -ProductionRoot $ProductionRoot `
            -ProductionStateHome $ProductionStateHome `
            -ProductionPort $ProductionPort `
            -Stage "while running test '$TestPath'"
    } catch {
        $productionError = $_
    }
    if ($null -ne $productionError) {
        if ($null -ne $testError) {
            throw [System.AggregateException]::new(
                "Test failed and the production baseline changed: $TestPath",
                $testError.Exception,
                $productionError.Exception)
        }
        throw $productionError
    }
    if ($null -ne $testError) { throw $testError }
}

$listenerSnapshot = @(Get-CpaStackListenerSnapshot)
$productionStateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack'
$productionRegistration = Get-CpaStackProductionRegistration -ProductionStateHome $productionStateHome
$productionRoots = @($productionRegistration.Roots)
$productionPorts = @($productionRegistration.ProtectedPorts)
$productionListeners = @($listenerSnapshot | Where-Object { [int]$_.LocalPort -in $productionPorts })
$productionGuard = New-CpaStackProductionGuard `
    -ProductionRoot $productionRoots `
    -ProductionStateHome @($productionStateHome) `
    -ProductionPort $productionPorts `
    -ProductionProcessId @($productionListeners | ForEach-Object { [int]$_.OwningProcess }) `
    -ListenerSnapshot $listenerSnapshot
$previousProtectedPorts = $env:CPA_STACK_TEST_PROTECTED_PORTS
$env:CPA_STACK_TEST_PROTECTED_PORTS = @($productionGuard.ProtectedPorts) -join ','
$productionArtifactsBefore = Get-CpaStackProductionArtifactSnapshot `
    -ProductionRoot $productionRoots `
    -ProductionStateHome $productionStateHome `
    -ListenerSnapshot $listenerSnapshot `
    -ProductionPort $productionPorts
$suiteRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cst-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $suiteRoot | Out-Null
[void](Assert-CpaStackTestIsolation `
    -Guard $productionGuard `
    -TestRoot $suiteRoot `
    -TestStateHome (Join-Path $suiteRoot 'local-app-data'))

try {
    $tests = @(
        'tests\ProductionGuard.Tests.ps1',
        'tests\FixtureStateIsolation.Tests.ps1',
        'tests\BundledHost.Tests.ps1',
        'tests\ResultContract.Tests.ps1',
        'tests\InitializeRecoverySafety.Tests.ps1',
        'tests\DynamicPorts.Tests.ps1',
        'tests\ManagedShortcutV2.Tests.ps1',
        'tests\LanConfiguration.Tests.ps1',
        'tests\CliV2.Tests.ps1',
        'tests\Static.Tests.ps1',
        'tests\Shortcut.Tests.ps1',
        'tests\PathSafety.Tests.ps1',
        'tests\SafetyRegression.Tests.ps1',
        'tests\SecretAndEnvironment.Tests.ps1',
        'tests\ProcessLifecycle.Tests.ps1',
        'tests\Adoption.Tests.ps1',
        'tests\InstallV2.Tests.ps1',
        'tests\Install.Tests.ps1',
        'tests\TransactionIntegration.Tests.ps1'
    )
    $testIndex = 0
    foreach ($test in $tests) {
        $testIndex++
        Write-Host "Running $test"
        if ($test -cin @(
            'tests\InitializeRecoverySafety.Tests.ps1',
            'tests\InstallV2.Tests.ps1',
            'tests\Install.Tests.ps1'
        )) {
            # These tests own their ProductionGuard lifecycle and isolated temp
            # roots. Avoid a second Job hierarchy and, for InstallV2, the extra
            # path depth that exceeds the Windows PowerShell 5.1 leaf budget.
            Assert-CpaStackProductionBaseline `
                -Guard $productionGuard `
                -ArtifactBaseline $productionArtifactsBefore `
                -ProductionRoot $productionRoots `
                -ProductionStateHome $productionStateHome `
                -ProductionPort $productionPorts `
                -Stage "before test '$test'"
            & (Join-Path $repo $test)
            Assert-CpaStackProductionBaseline `
                -Guard $productionGuard `
                -ArtifactBaseline $productionArtifactsBefore `
                -ProductionRoot $productionRoots `
                -ProductionStateHome $productionStateHome `
                -ProductionPort $productionPorts `
                -Stage "after test '$test'"
            continue
        }
        Invoke-CpaStackGuardedTestCase `
            -TestPath (Join-Path $repo $test) `
            -CaseRoot (Join-Path $suiteRoot ('case-{0:D2}' -f $testIndex)) `
            -CommonPath (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1') `
            -BaselineGuard $productionGuard `
            -ArtifactBaseline $productionArtifactsBefore `
            -ProductionRoot $productionRoots `
            -ProductionStateHome $productionStateHome `
            -ProductionPort $productionPorts
    }

    $pythonTestPath = Join-Path $suiteRoot 'python-regression-tests.ps1'
    $encodedRepo = ConvertTo-CpaStackTestBase64 -Value ([System.IO.Path]::GetFullPath($repo))
    [System.IO.File]::WriteAllText($pythonTestPath, @"
`$ErrorActionPreference = 'Stop'
`$repo = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedRepo'))
`$python = Get-Command python -ErrorAction Stop
`$pythonHexOutput = @(& `$python.Source -c 'import sys; print(sys.hexversion)' 2>&1)
`$pythonExitCode = `$LASTEXITCODE
`$pythonHexVersionText = (@(`$pythonHexOutput | ForEach-Object { [string]`$_ }) -join '').Trim()
`$pythonHexVersion = 0L
if (`$pythonExitCode -ne 0 -or
    -not [long]::TryParse(`$pythonHexVersionText, [ref]`$pythonHexVersion) -or
    `$pythonHexVersion -lt 0x030A00F0) {
    throw "Python 3.10 or newer is required for tests. HexVersion=`$pythonHexVersionText"
}
& `$python.Source -c 'import ast, pathlib, sys; path = pathlib.Path(sys.argv[1]); ast.parse(path.read_bytes(), filename=str(path))' (Join-Path `$repo 'skills\cpa-safe-upgrade\scripts\backup_sqlite.py')
if (`$LASTEXITCODE -ne 0) { throw 'Python syntax validation failed.' }
& `$python.Source -B -m unittest discover -s (Join-Path `$repo 'tests') -p 'test_*.py' -v
if (`$LASTEXITCODE -ne 0) { throw 'Python regression tests failed.' }
"@, [System.Text.UTF8Encoding]::new($false))
    Write-Host 'Running Python regression tests'
    Invoke-CpaStackGuardedTestCase `
        -TestPath $pythonTestPath `
        -CaseRoot (Join-Path $suiteRoot 'case-python') `
        -CommonPath (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1') `
        -BaselineGuard $productionGuard `
        -ArtifactBaseline $productionArtifactsBefore `
        -ProductionRoot $productionRoots `
        -ProductionStateHome $productionStateHome `
        -ProductionPort $productionPorts

    Write-Host 'All tests passed.'
} finally {
    $productionVerificationError = $null
    try {
        Assert-CpaStackProductionBaseline `
            -Guard $productionGuard `
            -ArtifactBaseline $productionArtifactsBefore `
            -ProductionRoot $productionRoots `
            -ProductionStateHome $productionStateHome `
            -ProductionPort $productionPorts `
            -Stage 'while the test suite was running'
    } catch {
        $productionVerificationError = 'Production verification failed: ' + $_.Exception.Message
    }
    try {
        Close-CpaStackProductionGuard -Guard $productionGuard
    } catch {
        if ([string]::IsNullOrWhiteSpace($productionVerificationError)) {
            $productionVerificationError = 'Test process cleanup failed: ' + $_.Exception.Message
        }
    } finally {
        $env:CPA_STACK_TEST_PROTECTED_PORTS = $previousProtectedPorts
    }
    if (Test-Path -LiteralPath $suiteRoot) {
        Remove-Item -LiteralPath $suiteRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not [string]::IsNullOrWhiteSpace($productionVerificationError)) { throw $productionVerificationError }
}
