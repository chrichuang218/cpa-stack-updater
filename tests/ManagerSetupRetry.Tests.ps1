$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')

$sentinel = 'SETUP-RETRY-SECRET-38e9'
foreach ($case in @(
    @{ Name='busy-then-ready'; Failures=2; Status=502; Code='request_failed'; Message='database is locked (5) (SQLITE_BUSY)'; Attempts=3; Succeeds=$true },
    @{ Name='busy-exhausted'; Failures=20; Status=502; Code='request_failed'; Message='database is locked (5) (SQLITE_BUSY)'; Attempts=4; Succeeds=$false },
    @{ Name='ordinary-502'; Failures=20; Status=502; Code='management_api_validation_failed'; Message='management API validation failed: 401 Unauthorized'; Attempts=1; Succeeds=$false },
    @{ Name='auth-error'; Failures=20; Status=401; Code='invalid_admin_key'; Message='invalid admin key'; Attempts=1; Succeeds=$false },
    @{ Name='unknown-code'; Failures=20; Status=502; Code=$sentinel; Message='database is locked (5) (SQLITE_BUSY)'; Attempts=1; Succeeds=$false },
    @{ Name='missing-busy-code'; Failures=20; Status=502; Code='request_failed'; Message='database is locked'; Attempts=1; Succeeds=$false },
    @{ Name='invalid-json'; Failures=20; Status=502; Code='request_failed'; Message='SQLITE_BUSY'; Raw='not JSON SQLITE_BUSY'; Attempts=1; Succeeds=$false },
    @{ Name='transport-timeout'; Failures=20; Status=0; Code='request_failed'; Message='SQLITE_BUSY'; Attempts=1; Succeeds=$false },
    @{ Name='owner-changed'; Failures=2; Status=502; Code='request_failed'; Message='database is locked (5) (SQLITE_BUSY)'; Attempts=1; Succeeds=$false }
)) {
    & {
        $script:setupCalls=0; $script:configCalls=0; $script:retrySleeps=0; $script:trustChecks=0
        function Get-CpaStackListener { return [pscustomobject]@{ProcessId=123;ExecutablePath='C:\fixture\manager.exe';LocalAddresses=@('127.0.0.1')} }
        function Get-CpaStackFileHash { return ('A' * 64) }
        function Wait-CpaStackTrustedListener {
            param($ExpectedPath,$ExpectedProcessId,$ExpectedHash,$AllowedAddresses)
            $script:trustChecks++
            Assert-Equal 123 $ExpectedProcessId 'Retry stays bound to the original process'
            Assert-Equal ('A' * 64) $ExpectedHash 'Retry revalidates the original executable'
            Assert-Equal '127.0.0.1' ($AllowedAddresses -join ',') 'Retry preserves listener binding'
            if ($case.Name -eq 'owner-changed') { throw 'Fixture owner changed' }
        }
        function Start-Sleep { $script:retrySleeps++ }
        function Invoke-RestMethod {
            param($Uri,$Method,$Headers,$Body)
            if ($Method -eq 'GET') {
                $script:configCalls++
                return [pscustomobject]@{config=[pscustomobject]@{collector=[pscustomobject]@{enabled=$false}}}
            }
            $script:setupCalls++
            $payload=$Body | ConvertFrom-Json
            Assert-False $payload.requestMonitoringEnabled 'Every attempt preserves the requested disabled collector'
            Assert-Equal $sentinel $payload.managementKey 'Every attempt uses the same payload'
            if ($script:setupCalls -le $case.Failures) {
                $exception=if($case.Status -eq 0){[System.Net.WebException]::new('Sensitive response: '+$sentinel, [System.Net.WebExceptionStatus]::Timeout)}else{[System.Exception]::new('Sensitive response: '+$sentinel)}
                if ($case.Status -ne 0) { $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=$case.Status}) }
                $errorRecord=[System.Management.Automation.ErrorRecord]::new($exception,'FixtureHttpFailure',[System.Management.Automation.ErrorCategory]::InvalidResult,$null)
                $json = if ($case.ContainsKey('Raw')) {$case.Raw} else {@{code=$case.Code;error=$case.Message;secret=$sentinel} | ConvertTo-Json -Compress}
                $errorRecord.ErrorDetails=[System.Management.Automation.ErrorDetails]::new($json)
                throw $errorRecord
            }
            return [pscustomobject]@{ok=$true}
        }
        $events=[System.Collections.Generic.List[object]]::new()
        $failed=$false; $caughtMessage=''
        try {
            $actual=Set-CpaStackManagerCollector -ManagerPort 12345 -CpaPort 12346 -ManagerAdminKey $sentinel -CpaManagementKey $sentinel -Enabled $false -RetryDiagnostics $events
        } catch {
            $failed=$true
            $caughtMessage=$_.Exception.Message
            if ($case.Name -eq 'busy-exhausted') {
                Assert-Equal 'SQLITE_BUSY' $_.Exception.Data['CpaStackHttpDiagnostic'].databaseError 'The original database error survives exhaustion'
            }
        }
        Assert-Equal (-not $case.Succeeds) $failed "$($case.Name): success or failure stays truthful ($caughtMessage)"
        Assert-Equal $case.Attempts $script:setupCalls "$($case.Name): exact bounded attempt count"
        Assert-Equal $(if($case.Succeeds){1}else{0}) $script:configCalls "$($case.Name): config is checked only after setup succeeds"
        if ($case.Succeeds) {
            Assert-False $actual.config.collector.enabled 'Successful retry still checks the collector result'
            Assert-Equal 2 $events.Count 'Recovered lock contention is retained in diagnostics'
            Assert-Equal 2 $script:trustChecks 'Each repeated request revalidates its listener'
        }
        if ($case.Name -eq 'busy-exhausted') {
            Assert-Equal 4 $events.Count 'Every busy failure remains observable'
            Assert-False $events[3].willRetry 'The final failure is explicitly not retried'
            Assert-Equal 3 $script:retrySleeps 'The exhausted attempt does not sleep again'
        }
        Assert-False (($events.ToArray() | ConvertTo-Json -Depth 10).Contains($sentinel)) 'Retry diagnostics never persist credentials, unknown codes or raw bodies'
    }
}
'Manager setup retry tests passed.'
