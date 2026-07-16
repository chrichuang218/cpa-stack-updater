$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
. $commonPath

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-adoption-tests-' + [guid]::NewGuid().ToString('N'))
$harness = Join-Path $temp 'harness'
$root = Join-Path $temp 'legacy canonical root'
$locatorPath = Get-CpaStackRootLocatorPath
$locatorExisted = Test-Path -LiteralPath $locatorPath -PathType Leaf
$locatorBytes = if ($locatorExisted) { [System.IO.File]::ReadAllBytes($locatorPath) } else { $null }
$locatorSddl = if ($locatorExisted) { (Get-Acl -LiteralPath $locatorPath).Sddl } else { $null }
$previousFixtureRoot = [Environment]::GetEnvironmentVariable('CPA_STACK_ADOPTION_TEST_ROOT', 'Process')
$pluginRootJunction = $null
$authRootJunction = $null
try {
    New-Item -ItemType Directory -Force -Path $harness | Out-Null
    foreach ($name in @('CpaStack.Common.ps1', 'Adopt-CpaStackLegacyCanonical.ps1', 'Start-CPA-Stack.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo ('skills\cpa-safe-upgrade\scripts\' + $name)) -Destination $harness
    }
    @'
function Get-CpaStackListener {
    param([int]$Port)
    $relative = if ($Port -eq 8317) { 'runtime\cli-proxy-api\cli-proxy-api.exe' } else { 'runtime\manager-plus\cpa-manager-plus.exe' }
    return [pscustomobject]@{
        Port = $Port
        LocalAddress = '127.0.0.1'
        LocalAddresses = @('127.0.0.1')
        ListenerCount = 1
        ProcessId = $PID
        ExecutablePath = Join-Path $env:CPA_STACK_ADOPTION_TEST_ROOT $relative
    }
}
function Wait-CpaStackTrustedListener {
    param([int]$Port, [string]$ExpectedPath, [int]$ExpectedProcessId, [string]$ExpectedHash, [string[]]$AllowedAddresses, [int]$Seconds)
    return Get-CpaStackListener -Port $Port
}
'@ | Add-Content -LiteralPath (Join-Path $harness 'CpaStack.Common.ps1') -Encoding ASCII
    @'
param([string]$ControlRoot)
[pscustomobject]@{
    SchemaVersion = 1
    OverallHealthy = $false
    CanonicalEstablished = $false
    MigrationRequired = $true
    LegacyCanonicalAdoptionRequired = $true
    Cpa = [pscustomobject]@{ Healthy = $true }
    Manager = [pscustomobject]@{ Healthy = $true }
    Security = [pscustomobject]@{
        RootAcl = [pscustomobject]@{ Protected = $true }
        Integrity = [pscustomobject]@{ Ready = $true }
    }
} | ConvertTo-Json -Depth 10
exit 1
'@ | Set-Content -LiteralPath (Join-Path $harness 'Get-CpaStackState.ps1') -Encoding ASCII

    $fixtureStateOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'Get-CpaStackState.ps1') -ControlRoot $root 2>&1)
    Assert-Equal 1 $LASTEXITCODE 'Adoption status fixture preserves the unhealthy pre-adoption exit code'
    Assert-True ($fixtureStateOutput.Count -gt 1) 'Adoption status fixture emits realistic multi-line JSON'
    Assert-Equal '{' ([string]$fixtureStateOutput[0]).Trim() 'Adoption status fixture starts a JSON document on its own line'
    Assert-Equal '}' ([string]$fixtureStateOutput[$fixtureStateOutput.Count - 1]).Trim() 'Adoption status fixture ends a JSON document on its own line'

    foreach ($directory in @('config', 'ops', 'state', 'runtime\cli-proxy-api\auth', 'runtime\cli-proxy-api\plugins\nested', 'runtime\manager-plus', 'data\manager-plus', 'rollback')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
    }
    [Environment]::SetEnvironmentVariable('CPA_STACK_ADOPTION_TEST_ROOT', $root, 'Process')
    $cpaExe = Join-Path $root 'runtime\cli-proxy-api\cli-proxy-api.exe'
    $managerExe = Join-Path $root 'runtime\manager-plus\cpa-manager-plus.exe'
    Set-Content -LiteralPath $cpaExe -Value 'synthetic old cpa executable' -Encoding ASCII
    Set-Content -LiteralPath $managerExe -Value 'synthetic old manager executable' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\config.yaml') -Value "host: `"127.0.0.1`"`r`nport: 8317" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\plugins\plugin.ps1') -Value '# plugin fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\plugins\nested\helper.ps1') -Value '# nested plugin fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'data\manager-plus\usage.sqlite') -Value 'synthetic sqlite fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'data\manager-plus\data.key') -Value 'synthetic data key' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'config\secrets.local.json') -Value '{"cpaClientApiKey":"test","cpaManagementKey":"test","managerAdminKey":"test"}' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'ops\Start-CPA-Stack.ps1') -Value '# stale launcher' -Encoding ASCII
    @'
@{
    SchemaVersion = 1
    StartupTimeoutSeconds = 30
    HttpTimeoutSeconds = 5
    Cpa = @{
        Executable = 'runtime\cli-proxy-api\cli-proxy-api.exe'
        WorkingDirectory = 'runtime\cli-proxy-api'
        Config = 'runtime\cli-proxy-api\config.yaml'
        Port = 8317
    }
    Manager = @{
        Executable = 'runtime\manager-plus\cpa-manager-plus.exe'
        WorkingDirectory = 'runtime\manager-plus'
        DataDirectory = 'data\manager-plus'
        Port = 18317
        BindAddress = '127.0.0.1'
        RequestMonitoringEnabled = $true
    }
    Browser = @{ Url = 'http://127.0.0.1:18317/management.html'; Executable = '' }
}
'@ | Set-Content -LiteralPath (Join-Path $root 'config\stack.psd1') -Encoding ASCII
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        canonicalRoot = $root
        cpa = [ordered]@{
            version = 'legacy'
            executable = $cpaExe
            sha256 = Get-CpaStackFileHash -Path $cpaExe
            config = Join-Path $root 'runtime\cli-proxy-api\config.yaml'
        }
        manager = [ordered]@{
            version = 'legacy'
            executable = $managerExe
            sha256 = Get-CpaStackFileHash -Path $managerExe
            data = Join-Path $root 'data\manager-plus'
        }
    }) -Path (Join-Path $root 'state\current.json')

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1') -ControlRoot $root 2>&1)
    Assert-Equal 0 $LASTEXITCODE ('Legacy canonical adoption succeeds. Output=' + ($output -join ' | '))
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
    Assert-Equal 1 $jsonLine.Count 'Adoption returns one structured result'
    $result = $jsonLine[0] | ConvertFrom-Json
    Assert-True ([bool]$result.success) 'Adoption reports success'
    Assert-True ([bool]$result.adopted) 'Adoption reports the legacy canonical transition'
    Assert-True ([bool]$result.changed) 'Adoption reports its state and ACL changes'
    $marker = Read-CpaStackJson -Path (Join-Path $root '.cpa-stack-instance.json')
    $current = Read-CpaStackJson -Path (Join-Path $root 'state\current.json')
    Assert-True ([string]$marker.instanceId -match '^[0-9a-fA-F]{32}$') 'Adoption creates a valid instance id'
    Assert-Equal ([string]$marker.instanceId) ([string]$current.instanceId) 'Marker and current state share the adopted instance id'
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'state\adopt.pending.json')) 'Adoption removes its pending journal after commit'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $harness 'Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path (Join-Path $root 'ops\Start-CPA-Stack.ps1')) 'Adoption refreshes the canonical launcher'
    Assert-CpaStackPrivateTree -Root (Join-Path $root 'runtime\cli-proxy-api\plugins') -Description 'Adopted CPA plugins'

    Remove-Item -LiteralPath (Join-Path $root '.cpa-stack-instance.json') -Force
    Set-Content -LiteralPath (Join-Path $root 'ops\Start-CPA-Stack.ps1') -Value '# interrupted stale launcher' -Encoding ASCII
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        operation = 'adopt-legacy-canonical-stack'
        instanceId = [string]$current.instanceId
        canonicalRoot = $root
        cpaSha256 = Get-CpaStackFileHash -Path $cpaExe
        managerSha256 = Get-CpaStackFileHash -Path $managerExe
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }) -Path (Join-Path $root 'state\adopt.pending.json')

    $replayOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1') -ControlRoot $root 2>&1)
    Assert-Equal 0 $LASTEXITCODE ('Interrupted adoption replay succeeds. Output=' + ($replayOutput -join ' | '))
    $replayedMarker = Read-CpaStackJson -Path (Join-Path $root '.cpa-stack-instance.json')
    Assert-Equal ([string]$current.instanceId) ([string]$replayedMarker.instanceId) 'Adoption replay uses the journal-bound instance id'
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'state\adopt.pending.json')) 'Adoption replay removes its pending journal'
    Assert-Equal (Get-CpaStackFileHash -Path (Join-Path $harness 'Start-CPA-Stack.ps1')) (Get-CpaStackFileHash -Path (Join-Path $root 'ops\Start-CPA-Stack.ps1')) 'Adoption replay finishes launcher synchronization'

    $stackConfigPath = Join-Path $root 'config\stack.psd1'
    $validStackConfig = [System.IO.File]::ReadAllText($stackConfigPath)
    [System.IO.File]::WriteAllText($stackConfigPath, $validStackConfig.Replace('Port = 18317', 'Port = 19317'), [System.Text.UTF8Encoding]::new($false))
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $wrongPortOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1') -ControlRoot $root 2>&1)
        $wrongPortExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $wrongPortExitCode 'Adoption rejects a non-canonical formal Manager port'
    Assert-True (($wrongPortOutput -join ' ') -match 'canonical formal ports') 'Wrong-port adoption failure is explicit'
    [System.IO.File]::WriteAllText($stackConfigPath, $validStackConfig, [System.Text.UTF8Encoding]::new($false))
    Protect-CpaStackSecretFile -Path $stackConfigPath

    $pluginsRoot = Join-Path $root 'runtime\cli-proxy-api\plugins'
    Remove-Item -LiteralPath $pluginsRoot -Recurse -Force
    $externalPlugins = Join-Path $temp 'external-plugins'
    New-Item -ItemType Directory -Force -Path $externalPlugins | Out-Null
    $pluginRootJunction = New-Item -ItemType Junction -Path $pluginsRoot -Target $externalPlugins
    $ErrorActionPreference = 'Continue'
    try {
        $pluginReparseOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1') -ControlRoot $root 2>&1)
        $pluginReparseExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $pluginReparseExitCode 'Adoption rejects a CPA plugins root junction'
    Assert-True (($pluginReparseOutput -join ' ') -match 'reparse point') 'Plugins-junction adoption failure is explicit'
    [System.IO.Directory]::Delete($pluginsRoot)
    $pluginRootJunction = $null
    New-Item -ItemType Directory -Force -Path $pluginsRoot | Out-Null
    Protect-CpaStackPrivateTree -Root $pluginsRoot

    $authRoot = Join-Path $root 'runtime\cli-proxy-api\auth'
    Remove-Item -LiteralPath $authRoot -Recurse -Force
    $externalAuth = Join-Path $temp 'external-auth'
    New-Item -ItemType Directory -Force -Path $externalAuth | Out-Null
    $authRootJunction = New-Item -ItemType Junction -Path $authRoot -Target $externalAuth
    $ErrorActionPreference = 'Continue'
    try {
        $reparseOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'Adopt-CpaStackLegacyCanonical.ps1') -ControlRoot $root 2>&1)
        $reparseExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorAction
    }
    Assert-Equal 1 $reparseExitCode 'Adoption rejects a CPA auth junction'
    Assert-True (($reparseOutput -join ' ') -match 'reparse point') 'Auth-junction adoption failure is explicit'
} finally {
    [Environment]::SetEnvironmentVariable('CPA_STACK_ADOPTION_TEST_ROOT', $previousFixtureRoot, 'Process')
    foreach ($junction in @($authRootJunction, $pluginRootJunction)) {
        if ($junction -and (Test-Path -LiteralPath $junction.FullName)) {
            [System.IO.Directory]::Delete($junction.FullName)
        }
    }
    if ($locatorExisted) {
        [System.IO.File]::WriteAllBytes($locatorPath, $locatorBytes)
        $restoredAcl = Get-Acl -LiteralPath $locatorPath
        $restoredAcl.SetSecurityDescriptorSddlForm($locatorSddl)
        Set-Acl -LiteralPath $locatorPath -AclObject $restoredAcl
    } elseif (Test-Path -LiteralPath $locatorPath -PathType Leaf) {
        Remove-Item -LiteralPath $locatorPath -Force
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

'Adoption tests passed.'
