#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

function New-TestLoopbackListener {
    $random = [System.Random]::new(([BitConverter]::ToInt32([guid]::NewGuid().ToByteArray(), 0) -band 0x7fffffff))
    for ($attempt = 0; $attempt -lt 512; $attempt++) {
        $port = $random.Next(49152, 65536)
        if ($port -in @(8317, 8318, 18317, 18318, 51001, 51002, 51003, 52001, 52002)) { continue }
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.ExclusiveAddressUse = $true
        try {
            $listener.Start()
            return ,$listener
        } catch [System.Net.Sockets.SocketException] {
            $listener.Stop()
        }
    }
    throw 'Could not create a test-owned loopback listener.'
}

$previousProtectedPorts = $env:CPA_STACK_TEST_PROTECTED_PORTS
$occupiedListener = $null
try {
    $env:CPA_STACK_TEST_PROTECTED_PORTS = '51001, 51002;51003'
    $formalPorts = @(52001, 52002)
    $occupiedListener = New-TestLoopbackListener
    $occupiedPort = ([System.Net.IPEndPoint]$occupiedListener.LocalEndpoint).Port

    $plan = New-CpaStackCandidatePortPlan -FormalPort $formalPorts -Name @('CpaCandidate', 'ManagerCandidate')

    Assert-Equal '127.0.0.1' $plan.BindAddress 'Candidate port plan is loopback-only'
    Assert-Equal 2 @($plan.AllPorts).Count 'Candidate port plan returns every requested role'
    Assert-Equal 2 @($plan.AllPorts | Sort-Object -Unique).Count 'Candidate ports are distinct'
    Assert-Equal $plan.Ports.CpaCandidate $plan.AllPorts[0] 'Candidate role order is preserved'
    Assert-Equal $plan.Ports.ManagerCandidate $plan.AllPorts[1] 'Manager candidate role is addressable by name'

    $protected = @(8317, 8318, 18317, 18318, 51001, 51002, 51003, 52001, 52002, $occupiedPort)
    foreach ($port in @($plan.AllPorts)) {
        Assert-True ($port -ge 49152 -and $port -le 65535) "Candidate port $port is in the high dynamic range"
        Assert-False ($port -in $protected) "Candidate port $port excludes formal, fixed protected, environment-protected, and active listener ports"
        $validation = Assert-CpaStackCandidatePort -Port $port -FormalPort $formalPorts
        Assert-True ([bool]$validation.Safe) "Allocated candidate port $port passes the runtime guard"
    }

    foreach ($port in @(8317, 8318, 18317, 18318, 51001, 52001, $occupiedPort)) {
        Assert-ThrowsMatch {
            Assert-CpaStackCandidatePort -Port $port -FormalPort $formalPorts
        } '(protected|formal|listener)' "Runtime guard rejects unsafe candidate port $port"
    }

    $scriptRoot = Join-Path $repo 'skills\cpa-safe-upgrade\scripts'
    Assert-ThrowsMatch {
        & (Join-Path $scriptRoot 'Test-CpaCandidate.ps1') `
            -ControlRoot 'C:\not-used' `
            -CandidateRuntime 'C:\not-used\cpa' `
            -ActiveConfig 'C:\not-used\config.yaml' `
            -ResultPath 'C:\not-used\result.json' `
            -ExpectedCandidateHash ('0' * 64) `
            -Port 8318 `
            -FormalPort $formalPorts `
            -InProcess
    } 'protected port' 'CPA candidate entry point rejects a protected port before touching the candidate runtime'
    Assert-ThrowsMatch {
        & (Join-Path $scriptRoot 'Test-ManagerCandidate.ps1') `
            -ControlRoot 'C:\not-used' `
            -CandidateRuntime 'C:\not-used\manager' `
            -FormalRuntime 'C:\not-used\formal-manager' `
            -FormalData 'C:\not-used\formal-data' `
            -ResultPath 'C:\not-used\result.json' `
            -ExpectedCandidateHash ('0' * 64) `
            -CpaPort $formalPorts[0] `
            -FormalPort $formalPorts[1] `
            -TempPort 18318 `
            -InProcess
    } 'protected port' 'Manager candidate entry point rejects a protected port before touching the candidate runtime'

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-dynamic-path-' + [guid]::NewGuid().ToString('N'))
    [void](Assert-CpaStackChildPath -Root $root -Path (Join-Path $root ('work\cpa-candidate-' + ('a' * 32))))
    [void](Assert-CpaStackChildPath -Root $root -Path (Join-Path $root ('work\manager-candidate-' + ('b' * 32))))

    $env:CPA_STACK_TEST_PROTECTED_PORTS = 'not-a-port'
    Assert-ThrowsMatch {
        New-CpaStackCandidatePortPlan -FormalPort $formalPorts -Name @('Candidate')
    } 'CPA_STACK_TEST_PROTECTED_PORTS' 'Malformed protected-port configuration fails closed'
} finally {
    if ($null -ne $occupiedListener) { $occupiedListener.Stop() }
    $env:CPA_STACK_TEST_PROTECTED_PORTS = $previousProtectedPorts
}

Write-Host 'Dynamic port tests passed.'
