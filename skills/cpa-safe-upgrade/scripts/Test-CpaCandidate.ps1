[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [Parameter(Mandatory = $true)][string]$CandidateRuntime,
    [Parameter(Mandatory = $true)][string]$ActiveConfig,
    [string]$ActiveRuntime,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedCandidateHash,
    [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
    [int[]]$FormalPort = @(),
    [scriptblock]$StartedProcessRegistration,
    [switch]$InProcess
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")
if ($null -ne $StartedProcessRegistration -and -not $InProcess) {
    throw '-StartedProcessRegistration is reserved for in-process callers.'
}

[void](Assert-CpaStackCandidatePort -Port $Port -FormalPort $FormalPort)

$candidateExe = Join-Path $CandidateRuntime "cli-proxy-api.exe"
$testRoot = Join-Path $ControlRoot ("work\cpa-candidate-" + [guid]::NewGuid().ToString("N"))
$testConfig = Join-Path $testRoot "config.yaml"
$result = [ordered]@{
    component = "CPA"
    port = $Port
    success = $false
    candidatePath = $candidateExe
    candidateHash = Get-CpaStackFileHash -Path $candidateExe
    modelCount = 0
    managementReady = $false
    activeConfigSha256 = $null
    activeConfigHost = $null
    runtimeManifestSha256 = $null
    runtimeManifestEntryCount = 0
    error = $null
}
$process = $null

try {
    Assert-CpaStackChildPath -Root $ControlRoot -Path $CandidateRuntime
    Assert-CpaStackPath -Path $candidateExe -PathType Leaf
    if ((Get-CpaStackFileHash -Path $candidateExe) -ne $ExpectedCandidateHash.ToUpperInvariant()) {
        throw 'CPA candidate executable hash changed before validation.'
    }
    Assert-CpaStackPath -Path $ActiveConfig -PathType Leaf
    $candidatePlugins = Join-Path $CandidateRuntime 'plugins'
    if (Test-Path -LiteralPath $candidatePlugins) {
        Assert-CpaStackPrivateTree -Root $candidatePlugins -Description 'CPA candidate plugins'
    }
    if (Get-CpaStackListener -Port $Port) {
        throw "CPA candidate port $Port is already in use."
    }

    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $content = [System.IO.File]::ReadAllText($ActiveConfig, [System.Text.UTF8Encoding]::new($false, $true))
    $updated = [regex]::Replace($content, "(?m)^port:\s*\d+\s*$", "port: $Port", 1)
    if ($updated -eq $content) {
        throw "CPA config does not contain a replaceable top-level port."
    }
    if ($updated -match '(?m)^host:\s*.*$') {
        $updated = [regex]::Replace($updated, '(?m)^host:\s*.*$', 'host: "127.0.0.1"', 1)
    } else {
        $updated = "host: `"127.0.0.1`"`r`n" + $updated
    }
    $updated = [regex]::Replace($updated, '(?m)^auth-dir:\s*.+$', 'auth-dir: "auth"', 1)
    if (-not $ActiveRuntime) { $ActiveRuntime = Split-Path -Parent $ActiveConfig }
    $updated = $updated.Replace($ActiveRuntime, $CandidateRuntime).Replace($ActiveRuntime.Replace('\', '/'), $CandidateRuntime.Replace('\', '/'))
    [System.IO.File]::WriteAllText($testConfig, $updated, [System.Text.UTF8Encoding]::new($false))

    $process = Start-CpaStackProcess -FilePath $candidateExe -Arguments "-config `"$testConfig`"" -WorkingDirectory $CandidateRuntime -MinimalEnvironment -StartedProcessRegistration $StartedProcessRegistration
    [void](Wait-CpaStackTrustedListener -Port $Port -ExpectedPath $candidateExe -ExpectedProcessId $process.Id -ExpectedHash $ExpectedCandidateHash -AllowedAddresses @('127.0.0.1') -Seconds 35)
    $secrets = Get-CpaStackSecrets -ControlRoot $ControlRoot
    $managementHeaders = @{ Authorization = "Bearer $($secrets.cpaManagementKey)" }
    $clientHeaders = @{ Authorization = "Bearer $($secrets.cpaClientApiKey)" }
    [void](Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$Port/v0/management/config" -Headers $managementHeaders -Seconds 35)
    $result.managementReady = $true
    $models = Wait-CpaStackHttpJson -Uri "http://127.0.0.1:$Port/v1/models" -Headers $clientHeaders -Seconds 20
    $result.modelCount = if ($models.data) { @($models.data).Count } else { 0 }
    if ($result.modelCount -lt 1) {
        throw "CPA candidate returned no models."
    }
    [void](Wait-CpaStackTrustedListener -Port $Port -ExpectedPath $candidateExe -ExpectedProcessId $process.Id -ExpectedHash $ExpectedCandidateHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    $cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
    try {
        Stop-CpaStackPort -Port $Port -ExpectedPath $candidateExe -ExpectedProcess $process -RequireExecutableWriteAccess
    } catch {
        [void]$cleanupErrors.Add($_.Exception.Message)
    }
    if ($process) {
        try {
            Stop-CpaStackStartedProcess -Process $process -ExpectedPath $candidateExe
        } catch {
            [void]$cleanupErrors.Add($_.Exception.Message)
        } finally {
            if ($process -is [System.IDisposable]) { $process.Dispose() }
        }
    }
    if ($cleanupErrors.Count -gt 0) {
        $result.success = $false
        $result.error = (($result.error, ("Candidate cleanup failed: " + ($cleanupErrors -join ' '))) | Where-Object { $_ }) -join ' '
    }
    if ($result.success) {
        try {
            Protect-CpaStackPrivateTree -Root $CandidateRuntime
            if ((Get-CpaStackFileHash -Path $candidateExe) -ne $ExpectedCandidateHash.ToUpperInvariant()) {
                throw 'CPA candidate executable changed during validation.'
            }
            $manifest = Get-CpaStackTreeManifest -Root $CandidateRuntime
            $result.activeConfigSha256 = Get-CpaStackFileHash -Path $ActiveConfig
            $result.activeConfigHost = Get-CpaStackConfigHost -ConfigPath $ActiveConfig
            $result.runtimeManifestSha256 = [string]$manifest.sha256
            $result.runtimeManifestEntryCount = [int]$manifest.entryCount
        } catch {
            $result.success = $false
            $result.error = (($result.error, "Candidate snapshot binding failed: $($_.Exception.Message)") | Where-Object { $_ }) -join ' '
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
$result | ConvertTo-Json -Depth 8 -Compress
