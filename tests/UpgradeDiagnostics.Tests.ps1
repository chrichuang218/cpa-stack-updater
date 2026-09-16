$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$repo = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $repo 'skills\cpa-safe-upgrade\scripts'
. (Join-Path $scripts 'CpaStack.Common.ps1')

function Import-TestFunctions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count 'Source parses before extracting production functions'
    foreach ($name in $Names) {
        $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        Assert-True ($null -ne $node) "Production function exists: $name"
        # Return definitions; the caller dot-sources them into its isolated test scope.
        $node.Extent.Text
    }
}

$sentinel = 'DO-NOT-LOG-SECRET-74f308'
$state = [pscustomobject]@{
    OverallHealthy = $false; CanonicalEstablished = $true
    Security = @{ Integrity = @{ Ready = $true }; RootAcl = @{ Protected = $true }; ManagerDataTree = @{ Protected = $true } }
    Configuration = @{ Secrets = @{ Ready = $true; token = $sentinel } }
    Cpa = @{ Healthy = $true; Checks = @{ ListenerStable = $true } }
    Manager = @{
        Healthy = $false
        Checks = @{ CollectorRunning = $false; ListenerStable = $true; Unrecognized = $sentinel }
        HttpChecks = @{
            '/usage-service/config' = @{ Attempted = $true; StatusCode = 502; ErrorKind = 'HttpError'; JsonValid = $false; Json = @{ secret = $sentinel } }
            '/status' = @{ Attempted = $true; StatusCode = $null; ErrorKind = $sentinel; JsonValid = $false }
            "/$sentinel" = @{ StatusCode = 200 }
        }
        Port = 59999; Database = @{ ReportedPath = $sentinel }
    }
    PendingOperations = @($sentinel)
}
$failed = New-CpaStackHealthDiagnostic -Stage 'recovery-health' -State $state
Assert-True ('Manager.Checks.CollectorRunning' -in $failed.failedChecks) 'The precise failing readiness check is retained'
Assert-False ('Manager.Checks.ListenerStable' -in $failed.failedChecks) 'Passing checks are not listed as failures'
Assert-Equal 502 $failed.http[0].statusCode 'HTTP 502 is retained without response data'
Assert-Equal '/usage-service/config' $failed.http[0].endpoint 'Endpoint path is retained without authority'
$serialized = $failed | ConvertTo-Json -Depth 12 -Compress
Assert-False ($serialized.Contains($sentinel)) 'Diagnostics exclude secrets, response bodies, unknown fields and paths'
Assert-False ($serialized.Contains('59999')) 'Diagnostics exclude dynamic ports'

$responseException = [System.Exception]::new($sentinel)
$responseException | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 502; Content = $sentinel })
$responseFailure = [System.Management.Automation.ErrorRecord]::new($responseException, 'TestHttp502', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
$http502 = New-CpaStackHttpFailureDiagnostic -Uri "http://127.0.0.1:59999/usage-service/config?secret=$sentinel" -Failure $responseFailure
Assert-Equal 502 $http502.statusCode 'HTTP response status is extracted from the error without reading its body'
Assert-Equal 'HttpError' $http502.failureKind 'An HTTP response is distinguished from a transport timeout'
Assert-False (($http502 | ConvertTo-Json).Contains($sentinel)) 'HTTP diagnostics omit exception messages and response content'

# Exercise the real HTTP wrapper without making a network request.
& {
    function Invoke-RestMethod {
        $exception = [System.Net.WebException]::new('secret response must not escape', [System.Net.WebExceptionStatus]::Timeout)
        throw $exception
    }
    try {
        Invoke-CpaStackHttpJson -Uri "http://user:$sentinel@127.0.0.1:59999/setup?token=$sentinel" -Method POST -Headers @{ Authorization = "Bearer $sentinel" } -Body $sentinel
        throw 'Expected HTTP request to fail'
    } catch {
        $diagnostic = New-CpaStackFailureDiagnostic -Stage 'manager-candidate' -Failure $_
        Assert-Equal '/setup' $diagnostic.http.endpoint 'HTTP wrapper attaches only the allowlisted endpoint'
        Assert-Equal 'POST' $diagnostic.http.method 'HTTP method is retained'
        Assert-Equal 'Timeout' $diagnostic.http.failureKind 'Timeout is distinguished from HTTP error'
        $json = $diagnostic | ConvertTo-Json -Depth 8 -Compress
        Assert-False ($json -match 'secret response|59999|DO-NOT-LOG') 'Exception diagnostics omit messages, headers, body, query and port'
    }
}

& {
    $definitions = Import-TestFunctions -Path (Join-Path $scripts 'Invoke-CpaStackUpgrade.ps1') -Names @('Add-UpgradeDiagnostic', 'ConvertTo-InProcessParameters', 'Invoke-InProcessPowerShellJson')
    . ([scriptblock]::Create($definitions -join "`n"))
    $result = [ordered]@{ diagnostics = @() }
    $diagnosticStage = 'testing-manager'
    function Invoke-TestCandidate {
        param([switch]$InProcess)
        $failure = [System.Exception]::new('Synthetic candidate failure')
        $failure.Data['CpaStackDiagnostics'] = @($failed)
        throw $failure
    }
    Assert-ThrowsMatch { Invoke-InProcessPowerShellJson -Script 'Invoke-TestCandidate' -Arguments @() } 'Synthetic candidate failure' 'Candidate failure remains a failure'
    Assert-Equal 2 $result.diagnostics.Count 'Candidate diagnostics survive the in-process exception wrapper'
    Assert-Equal 'recovery-health' $result.diagnostics[0].stage 'Original child diagnostic is retained'
    Assert-Equal 'testing-manager' $result.diagnostics[1].stage 'Parent context is appended separately'
}

& {
    # Exercise the actual post-switch logging and failure branch, not a copy of its predicate.
    $definitions = Import-TestFunctions -Path (Join-Path $scripts 'Invoke-CpaStackUpgrade.ps1') -Names @('Add-UpgradeDiagnostic', 'Assert-SwitchedServicesHealthy')
    . ([scriptblock]::Create($definitions -join "`n"))
    $result = [ordered]@{ diagnostics = @() }
    function Join-Path { return 'fixture-script.ps1' }
    function Invoke-ChildPowerShellJson { return $state }
    $ControlRoot = 'C:\unused-fixture'
    Assert-ThrowsMatch { Assert-SwitchedServicesHealthy -PendingSwitchComponent manager } 'did not preserve' 'A failed health check still stops the transaction'
    $state.Manager.Healthy = $true
    $state.Manager.Checks.CollectorRunning = $true
    $state.OverallHealthy = $true
    Assert-SwitchedServicesHealthy -PendingSwitchComponent manager
    Assert-Equal 2 $result.diagnostics.Count 'Recovery appends a second event rather than overwriting the first'
    Assert-True ('Manager.Checks.CollectorRunning' -in $result.diagnostics[0].failedChecks) 'First failure survives later state mutation'
    Assert-Equal 0 $result.diagnostics[1].failedChecks.Count 'Later successful checks are recorded separately'
    $state.OverallHealthy = $false
    $pending = New-CpaStackHealthDiagnostic -Stage 'recovery-health' -State $state
    Assert-False $pending.overallHealthy 'Overall state remains visible while a switch is pending'
    Assert-Equal 0 $pending.failedChecks.Count 'A pending transaction alone must not be mislabeled as a failed component check'
}

& {
    # The status gate and its diagnostic booleans share the production check map.
    $definitions = Import-TestFunctions -Path (Join-Path $scripts 'Get-CpaStackState.ps1') -Names @('Get-JsonPropertyValue', 'New-UnattemptedProbe', 'Get-ManagerStatus')
    . ([scriptblock]::Create($definitions -join "`n"))
    function Test-Path { return $true }
    function Get-ListenerProcesses { return [pscustomobject]@{ ProcessId = 42; ExecutablePath = 'fixture.exe'; Name = 'fixture'; LocalAddresses = @('127.0.0.1') } }
    function Test-PathEqual { return $true }
    function Resolve-ExpectedListenerAddresses { return @('127.0.0.1') }
    function Test-ListenerAddresses { return $true }
    function Get-CpaStackFileHash { return ('A' * 64) }
    $script:diagnosticTestCollector = 'stopped'
    function Invoke-JsonProbe {
        return [pscustomobject]@{
            Attempted = $true; Reachable = $true; StatusCode = 200; JsonValid = $true; ErrorKind = $null
            Json = [pscustomobject]@{
                configured = $true; adminReady = $true; projectInitialized = $true; setupRequired = $false
                migrationStatus = 'ready'; dataKeyReady = $true; hasHistoricalData = $false
                config = [pscustomobject]@{ collector = [pscustomobject]@{ enabled = $true } }
                collector = [pscustomobject]@{ collector = $script:diagnosticTestCollector; mode = 'auto'; transport = 'subscribe'; deadLetters = 0 }
                dbPath = 'fixture.sqlite'; secret = $sentinel
            }
        }
    }
    $settings = @{ Manager = @{ Port = 12345; Executable = 'fixture.exe'; WorkingDirectory = 'C:\fixture'; DataDirectory = 'C:\fixture\data'; BindAddress = '127.0.0.1'; RequestMonitoringEnabled = $true }; HttpTimeoutSeconds = 1 }
    $secrets = @{ Safe = @{ Ready = $true }; Values = @{ managerAdminKey = $sentinel } }
    $red = Get-ManagerStatus -Settings $settings -SecretsState $secrets -ExpectedHash ('A' * 64) -TrustStateReady $true
    Assert-False $red.Healthy 'A stopped collector still fails the actual status gate'
    Assert-False $red.Checks.CollectorRunning 'The failed gate has an explicit diagnostic name'
    Assert-False (($red.HttpChecks | ConvertTo-Json -Depth 10).Contains($sentinel)) 'Status HTTP checks omit parsed response content'
    $script:diagnosticTestCollector = 'running'
    $green = Get-ManagerStatus -Settings $settings -SecretsState $secrets -ExpectedHash ('A' * 64) -TrustStateReady $true
    Assert-True $green.Healthy 'The same gate passes once the collector runs'
    Remove-Variable -Name diagnosticTestCollector -Scope Script
}

'Upgrade diagnostics tests passed.'
