[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [Parameter(Mandatory = $true)][string]$CandidateRuntime,
    [Parameter(Mandatory = $true)][string]$FormalRuntime,
    [Parameter(Mandatory = $true)][string]$FormalData,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedCandidateHash,
    [switch]$RequireV111Schema,
    [int]$CpaPort = 8317,
    [int]$FormalPort = 18317,
    [int]$TempPort = 18318,
    [switch]$InProcess
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")

$candidateExe = Join-Path $CandidateRuntime "cpa-manager-plus.exe"
$formalExe = Join-Path $FormalRuntime "cpa-manager-plus.exe"
$testRoot = Join-Path $ControlRoot ("work\manager-18318-" + [guid]::NewGuid().ToString("N"))
$emptyData = Join-Path $testRoot "empty-data"
$snapshotData = Join-Path $testRoot "snapshot-data"
$baselinePath = Join-Path $testRoot "sqlite-baseline.json"
$result = [ordered]@{
    component = "Manager Plus"
    port = $TempPort
    success = $false
    candidatePath = $candidateExe
    candidateHash = Get-CpaStackFileHash -Path $candidateExe
    emptyDataSmoke = $false
    snapshotCompatibility = $false
    schemaValidated = [bool]$RequireV111Schema
    hasHistoricalData = $false
    collectorEnabled = $null
    dataKeyPreserved = $false
    error = $null
}

$secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
$headers = @{ Authorization = "Bearer $($secrets.managerAdminKey)" }
$formalBaseline = $null
$formalBaselineRestoreRequired = $false
$formalProcessId = 0
$formalExpectedHash = $null
$candidateProcess = $null

function Stop-ManagerCandidateProcess {
    if ($null -eq $script:candidateProcess) {
        Stop-CpaStackPort -Port $TempPort -ExpectedPath $candidateExe -RequireExecutableWriteAccess
        return
    }

    Stop-CpaStackPort -Port $TempPort -ExpectedPath $candidateExe -ExpectedProcess $script:candidateProcess -RequireExecutableWriteAccess
    if ($script:candidateProcess -is [System.IDisposable]) { $script:candidateProcess.Dispose() }
    $script:candidateProcess = $null
}

function Start-ManagerCandidate {
    param([string]$Data)
    $environment = @{
        HTTP_ADDR             = "127.0.0.1:$TempPort"
        USAGE_DATA_DIR        = $Data
        USAGE_DB_PATH         = (Join-Path $Data "usage.sqlite")
        CPA_MANAGER_ADMIN_KEY = [string]$secrets.managerAdminKey
    }
    return Start-CpaStackProcess -FilePath $candidateExe -WorkingDirectory $CandidateRuntime -Environment $environment -RemoveEnvironment @("PANEL_PATH") -MinimalEnvironment
}

function Assert-FormalManagerListener {
    [void](Wait-CpaStackTrustedListener -Port $FormalPort -ExpectedPath $formalExe -ExpectedProcessId $formalProcessId -ExpectedHash $formalExpectedHash -Seconds 2)
}

function Test-ManagerCandidateHttp {
    param([bool]$ExpectHistorical, [int]$ExpectedProcessId)

    [void](Wait-CpaStackTrustedListener -Port $TempPort -ExpectedPath $candidateExe -ExpectedProcessId $ExpectedProcessId -ExpectedHash $ExpectedCandidateHash -AllowedAddresses @('127.0.0.1') -Seconds 40)
    [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$TempPort/health" -Seconds 40)
    $info = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$TempPort/usage-service/info" -Headers $headers
    $config = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$TempPort/usage-service/config" -Headers $headers
    if ($null -eq $config.config -or $null -eq $config.config.collector -or $null -eq $config.config.collector.enabled) {
        throw "Manager candidate config.collector.enabled is missing."
    }
    if ([bool]$config.config.collector.enabled) {
        throw "Manager candidate collector must remain disabled."
    }
    if ($ExpectHistorical -and -not [bool]$info.hasHistoricalData) {
        throw "Manager candidate did not detect historical data."
    }
    $page = Invoke-WebRequest -Uri "http://127.0.0.1:$TempPort/management.html" -UseBasicParsing -TimeoutSec 10
    if ($page.StatusCode -ne 200 -or $page.Content -notmatch "CPA Manager Plus") {
        throw "Manager candidate embedded page validation failed."
    }
    [void](Wait-CpaStackTrustedListener -Port $TempPort -ExpectedPath $candidateExe -ExpectedProcessId $ExpectedProcessId -ExpectedHash $ExpectedCandidateHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
    return [pscustomobject]@{ info = $info; config = $config }
}

try {
    Assert-CpaStackChildPath -Root $ControlRoot -Path $CandidateRuntime
    Assert-CpaStackPath -Path $candidateExe -PathType Leaf
    if ((Get-CpaStackFileHash -Path $candidateExe) -ne $ExpectedCandidateHash.ToUpperInvariant()) {
        throw 'Manager candidate executable hash changed before validation.'
    }
    Assert-CpaStackPath -Path $FormalData
    Assert-CpaStackPath -Path (Join-Path $FormalData "usage.sqlite") -PathType Leaf
    Assert-CpaStackPath -Path $formalExe -PathType Leaf
    if (Get-CpaStackListener -Port $TempPort) {
        throw "Manager candidate port $TempPort is already in use."
    }
    $formalListener = Get-CpaStackListener -Port $FormalPort
    if (-not $formalListener -or $formalListener.ExecutablePath -ine $formalExe) {
        throw "Formal Manager port $FormalPort is not owned by the expected executable."
    }
    $formalProcessId = [int]$formalListener.ProcessId
    $formalExpectedHash = Get-CpaStackFileHash -Path $formalExe
    Assert-FormalManagerListener
    $formalBaseline = Get-CpaStackManagerSetupBaseline -ManagerPort $FormalPort -ManagerAdminKey $secrets.managerAdminKey
    Assert-FormalManagerListener
    New-Item -ItemType Directory -Force -Path $emptyData | Out-Null

    try {
        $candidateProcess = Start-ManagerCandidate -Data $emptyData
        [void](Wait-CpaStackTrustedListener -Port $TempPort -ExpectedPath $candidateExe -ExpectedProcessId $candidateProcess.Id -ExpectedHash $ExpectedCandidateHash -AllowedAddresses @('127.0.0.1') -Seconds 40)
        [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$TempPort/health" -Seconds 40)
        $formalBaselineRestoreRequired = $true
        [void](Set-CpaStackManagerCollector -ManagerPort $TempPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled $false -Baseline $formalBaseline)
        [void](Test-ManagerCandidateHttp -ExpectHistorical $false -ExpectedProcessId $candidateProcess.Id)
        Assert-FormalManagerListener
        [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $FormalPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
        Assert-FormalManagerListener
        $result.emptyDataSmoke = $true
    } finally {
        Stop-ManagerCandidateProcess
        if ($formalBaselineRestoreRequired) {
            Assert-FormalManagerListener
            [void](Set-CpaStackManagerCollector -ManagerPort $FormalPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$formalBaseline.collectorEnabled) -Baseline $formalBaseline)
            [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $FormalPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
            Assert-FormalManagerListener
            $formalBaselineRestoreRequired = $false
        }
    }

    $formalBaselineRestoreRequired = $true
    Assert-FormalManagerListener
    [void](Set-CpaStackManagerCollector -ManagerPort $FormalPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled $false -Baseline $formalBaseline)
    try {
        New-Item -ItemType Directory -Force -Path $snapshotData | Out-Null
        $dataKey = Join-Path $FormalData "data.key"
        Assert-CpaStackPath -Path $dataKey -PathType Leaf
        $sourceDataKeyHash = Get-CpaStackFileHash -Path $dataKey
        Copy-Item -LiteralPath $dataKey -Destination (Join-Path $snapshotData "data.key") -Force
        if ((Get-CpaStackFileHash -Path (Join-Path $snapshotData "data.key")) -ne $sourceDataKeyHash) {
            throw "Manager snapshot data.key hash mismatch."
        }
        $baseline = Invoke-CpaStackSqliteBackup -Source (Join-Path $FormalData "usage.sqlite") -Destination (Join-Path $snapshotData "usage.sqlite") -ResultPath $baselinePath
    } finally {
        Assert-FormalManagerListener
        [void](Set-CpaStackManagerCollector -ManagerPort $FormalPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$formalBaseline.collectorEnabled) -Baseline $formalBaseline)
        [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $FormalPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
        Assert-FormalManagerListener
        $formalBaselineRestoreRequired = $false
    }

    try {
        $candidateProcess = Start-ManagerCandidate -Data $snapshotData
        [void](Wait-CpaStackTrustedListener -Port $TempPort -ExpectedPath $candidateExe -ExpectedProcessId $candidateProcess.Id -ExpectedHash $ExpectedCandidateHash -AllowedAddresses @('127.0.0.1') -Seconds 40)
        $expectHistorical = ([Int64]$baseline.snapshot.usage_events.count -gt 0)
        $snapshotState = Test-ManagerCandidateHttp -ExpectHistorical $expectHistorical -ExpectedProcessId $candidateProcess.Id
        if ($RequireV111Schema) {
            $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
            & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Test-ManagerData.ps1") -DatabasePath (Join-Path $snapshotData "usage.sqlite") -BaselineJsonPath $baselinePath | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Manager candidate v1.11 schema/history assertions failed."
            }
        } else {
            $verifyDir = Join-Path $testRoot "snapshot-verify"
            New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
            $after = Invoke-CpaStackSqliteBackup -Source (Join-Path $snapshotData "usage.sqlite") -Destination (Join-Path $verifyDir "usage.sqlite") -ResultPath (Join-Path $verifyDir "result.json")
            foreach ($field in @("count", "max_id", "max_timestamp_ms")) {
                $beforeValue = $baseline.snapshot.usage_events.$field
                $afterValue = $after.snapshot.usage_events.$field
                if ($null -ne $beforeValue -and ($null -eq $afterValue -or [Int64]$afterValue -lt [Int64]$beforeValue)) {
                    throw "Manager candidate regressed the historical watermark: $field"
                }
            }
            foreach ($table in @('settings', 'model_prices')) {
                $beforeValue = $baseline.snapshot.critical_table_counts.$table
                if ($null -eq $beforeValue) { continue }
                $afterValue = $after.snapshot.critical_table_counts.$table
                if ($null -eq $afterValue -or [Int64]$afterValue -lt [Int64]$beforeValue) {
                    throw "Manager candidate regressed a required business table: $table"
                }
            }
        }
        $result.snapshotCompatibility = $true
        $result.hasHistoricalData = [bool]$snapshotState.info.hasHistoricalData
        $result.collectorEnabled = [bool]$snapshotState.config.config.collector.enabled
        $result.dataKeyPreserved = ((Get-CpaStackFileHash -Path (Join-Path $snapshotData "data.key")) -eq $sourceDataKeyHash)
    } finally {
        Stop-ManagerCandidateProcess
    }

    $result.success = ($result.emptyDataSmoke -and $result.snapshotCompatibility -and $result.dataKeyPreserved -and ($result.collectorEnabled -eq $false))
} catch {
    $result.error = $_.Exception.Message
} finally {
    try {
        Stop-ManagerCandidateProcess
    } catch {
        $result.success = $false
        $result.error = (($result.error, "Candidate cleanup failed: $($_.Exception.Message)") | Where-Object { $_ }) -join ' '
    } finally {
        if ($null -ne $candidateProcess -and $candidateProcess -is [System.IDisposable]) {
            $candidateProcess.Dispose()
        }
    }
    if ($formalBaselineRestoreRequired -and $null -ne $formalBaseline) {
        try {
            Assert-FormalManagerListener
            [void](Set-CpaStackManagerCollector -ManagerPort $FormalPort -CpaPort $CpaPort -ManagerAdminKey $secrets.managerAdminKey -CpaManagementKey $secrets.cpaManagementKey -Enabled ([bool]$formalBaseline.collectorEnabled) -Baseline $formalBaseline)
            [void](Assert-CpaStackManagerSetupBaseline -ManagerPort $FormalPort -ManagerAdminKey $secrets.managerAdminKey -Expected $formalBaseline)
            Assert-FormalManagerListener
            $formalBaselineRestoreRequired = $false
        } catch {
            $result.error = $result.error + " Formal collector restore failed: " + $_.Exception.Message
        }
    }
    Write-CpaStackJson -Value $result -Path $ResultPath
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $result.success) {
    if ($InProcess) { throw $result.error }
    Write-Error $result.error
    exit 1
}
$result | ConvertTo-Json -Depth 10 -Compress
