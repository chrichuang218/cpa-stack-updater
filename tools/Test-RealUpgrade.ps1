#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$TestRoot,
    [ValidateRange(1024, 65535)][int]$CpaPort = 28317,
    [ValidateRange(1024, 65535)][int]$ManagerPort = 28318
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tests\TestHelpers.ps1')
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
Import-Module (Join-Path $PSScriptRoot 'CpaStack.ProductionGuard.psm1') -Force
$SourceRoot = Assert-CpaStackSecureLocalRoot -Path $SourceRoot
$TestRoot = Assert-CpaStackSecureLocalRoot -Path $TestRoot
if (Test-Path -LiteralPath $TestRoot) { throw 'Test root must not already exist; existing evidence is never overwritten.' }
if ($CpaPort -eq $ManagerPort) { throw 'Test ports must differ.' }
$sourceSettings = Import-PowerShellDataFile (Join-Path $SourceRoot 'config\stack.psd1')
$stateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack'
$desktop = [Environment]::GetFolderPath('Desktop')
$guard = New-CpaStackProductionGuard -ProductionRoot @($SourceRoot) -ProductionStateHome @($stateHome) `
    -ProductionPort @($sourceSettings.Cpa.Port, $sourceSettings.Manager.Port)
$protectedFiles = @(
    (Join-Path $SourceRoot '.cpa-stack-instance.json'), (Join-Path $SourceRoot 'state\current.json'),
    (Join-Path $SourceRoot 'config\stack.psd1'), (Join-Path $SourceRoot 'config\secrets.local.json'),
    (Join-Path $SourceRoot 'runtime\cli-proxy-api\cli-proxy-api.exe'),
    (Join-Path $SourceRoot 'runtime\manager-plus\cpa-manager-plus.exe'),
    (Join-Path $SourceRoot 'runtime\cli-proxy-api\config.yaml'), (Join-Path $stateHome 'root.json')
) + @(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' -File | ForEach-Object { $_.FullName })
$baseline = @{}
foreach ($path in $protectedFiles) { $baseline[$path] = Get-CpaStackFileHash -Path $path }
$oldProtectedPorts = $env:CPA_STACK_TEST_PROTECTED_PORTS
$phase = 'preflight'
$report = [ordered]@{ success = $false; phase = $phase; productionUnchanged = $false; error = $null }

function Invoke-TestCli {
    param([string[]]$Arguments)
    $output = @(& pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:cli @Arguments)
    $code = $LASTEXITCODE
    $document = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    if ($null -eq $document -or $document.schemaVersion -ne 2) { throw 'Missing final schema v2 result.' }
    Write-CpaStackJson -Value $document -Path (Join-Path $TestRoot ('test-' + $Arguments[0] + '.json'))
    if ($code -ne 0 -or -not $document.success) { throw ('Test CLI failed: ' + [string]$document.error.code) }
    return $document
}

try {
    [void](Assert-CpaStackTestIsolation -Guard $guard -TestRoot $TestRoot -TestStateHome (Join-Path $TestRoot 'lab\local') -TestPort @($CpaPort, $ManagerPort))
    foreach ($port in @($CpaPort, $ManagerPort)) {
        if (Get-CpaStackListener -Port $port) { throw 'A requested test port is already occupied.' }
    }
    $env:CPA_STACK_TEST_PROTECTED_PORTS = (@($guard.ProtectedPorts) -join ',')
    $sourceCurrent = Read-CpaStackJson -Path (Join-Path $SourceRoot 'state\current.json')
    foreach ($component in @('cpa', 'manager')) {
        Assert-CpaStackChildPath -Path $sourceCurrent.$component.executable -Root $SourceRoot | Out-Null
        if ((Get-CpaStackFileHash -Path $sourceCurrent.$component.executable) -ine $sourceCurrent.$component.sha256) { throw 'Source executable does not match its current record.' }
    }
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $TestRoot
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $TestRoot -AllowCreate
    Write-CpaStackJson -Value @{ root=$TestRoot; source=$SourceRoot; cpaPort=$CpaPort; managerPort=$ManagerPort } -Path (Join-Path $TestRoot '.cpa-stack-test.json')
    $phase = 'copy-runtime'
    Write-Host 'Copying runtime and auth into protected test directories.'
    foreach ($relative in @('runtime\cli-proxy-api', 'runtime\manager-plus')) {
        $sourcePath = Join-Path $SourceRoot $relative
        [void](Get-CpaStackTreeItemsNoReparse -Root $sourcePath -ExcludeDirectoryNames @('auth', 'logs'))
        Copy-CpaStackTree -Source $sourcePath -Destination (Join-Path $TestRoot $relative) `
            -ExcludeDirectoryNames @('auth', 'logs') -ExcludeFileNames @('server.log', 'config.json')
    }
    Copy-CpaStackAuthTree -Source (Join-Path $SourceRoot 'runtime\cli-proxy-api\auth') -Destination (Join-Path $TestRoot 'runtime\cli-proxy-api\auth')
    foreach ($relative in @('config', 'state', 'ops', 'data\manager-plus', 'lab')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $TestRoot $relative) | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'config\secrets.local.json') -Destination (Join-Path $TestRoot 'config\secrets.local.json')
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'data\manager-plus\data.key') -Destination (Join-Path $TestRoot 'data\manager-plus\data.key')
    $phase = 'snapshot'
    Write-Host 'Creating consistent online database snapshot; production stays running.'
    [void](Invoke-CpaStackSqliteBackup -Source (Join-Path $SourceRoot 'data\manager-plus\usage.sqlite') `
        -Destination (Join-Path $TestRoot 'data\manager-plus\usage.sqlite') -ResultPath (Join-Path $TestRoot 'lab\snapshot.json'))
    & python (Join-Path $PSScriptRoot 'prepare_test_database.py') $TestRoot $CpaPort
    if ($LASTEXITCODE -ne 0) { throw 'Offline test snapshot preparation failed.' }
    $configPath = Join-Path $TestRoot 'runtime\cli-proxy-api\config.yaml'
    $config = [IO.File]::ReadAllText($configPath)
    if ([regex]::Matches($config, '(?m)^port:\s*\d+\s*$').Count -ne 1) { throw 'Unsupported CPA port setting.' }
    $config = [regex]::Replace($config, '(?m)^port:\s*\d+\s*$', "port: $CpaPort")
    $config = [regex]::Replace($config, '(?m)^host:.*$', 'host: "127.0.0.1"')
    $config = [regex]::Replace($config, '(?m)^auth-dir:.*$', 'auth-dir: "auth"')
    if ([regex]::Matches($config, '(?m)^host:').Count -ne 1 -or [regex]::Matches($config, '(?m)^auth-dir:').Count -ne 1) { throw 'Explicit host and auth directory required.' }
    if ($config -match '(?m)^[^#\r\n]*(?<![A-Za-z])[A-Za-z]:[\\/]') { throw 'CPA config contains an external absolute path; inspect before running.' }
    $config = [regex]::Replace($config, '(?ms)(^pprof:\s*\r?\n\s+enabled:)\s*true', '$1 false')
    if ($config.Contains($SourceRoot) -or $config.Contains($SourceRoot.Replace('\','/'))) { throw 'CPA config still references production.' }
    [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
    $stackConfig = @"
@{
 SchemaVersion = 1
 StartupTimeoutSeconds = 60
 HttpTimeoutSeconds = 10
 Cpa = @{ Executable='runtime\cli-proxy-api\cli-proxy-api.exe'; WorkingDirectory='runtime\cli-proxy-api'; Config='runtime\cli-proxy-api\config.yaml'; Port=$CpaPort }
 Manager = @{ Executable='runtime\manager-plus\cpa-manager-plus.exe'; WorkingDirectory='runtime\manager-plus'; DataDirectory='data\manager-plus'; Port=$ManagerPort; BindAddress='127.0.0.1'; RequestMonitoringEnabled=`$false }
 Browser = @{ Url='http://127.0.0.1:$ManagerPort/management.html'; Executable='' }
}
"@
    [IO.File]::WriteAllText((Join-Path $TestRoot 'config\stack.psd1'), $stackConfig, [Text.UTF8Encoding]::new($false))
    $current = [ordered]@{ schemaVersion=1; instanceId=$marker.instanceId; canonicalRoot=$TestRoot; initializedAt=[DateTimeOffset]::Now.ToString('o') }
    foreach ($component in @('cpa','manager')) {
        $entry = $sourceCurrent.$component
        $relative = if ($component -eq 'cpa') { 'runtime\cli-proxy-api\cli-proxy-api.exe' } else { 'runtime\manager-plus\cpa-manager-plus.exe' }
        $exe = Join-Path $TestRoot $relative
        if ((Get-CpaStackFileHash -Path $exe) -ine $entry.sha256) { throw 'Copied executable hash mismatch.' }
        $current[$component] = @{ version=$entry.version; executable=$exe; sha256=$entry.sha256 }
    }
    $current.cpa.config = $configPath
    $current.manager.data = Join-Path $TestRoot 'data\manager-plus'
    Write-CpaStackJson -Value $current -Path (Join-Path $TestRoot 'state\current.json')
    $phase = 'isolate-updater'
    $fixture = New-CpaStackUpdaterTestFixture -SourceRepository $repo -DestinationRepository (Join-Path $TestRoot 'lab\repo') -LocalAppDataRoot (Join-Path $TestRoot 'lab\local')
    $testDesktop = Join-Path $TestRoot 'lab\desktop'
    New-Item -ItemType Directory -Path $testDesktop | Out-Null
    $fixtureCli = Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
    $text = [IO.File]::ReadAllText($fixtureCli)
    $needle = "[Environment]::GetFolderPath('Desktop')"
    if (-not $text.Contains($needle)) { throw 'Desktop isolation seam changed.' }
    [IO.File]::WriteAllText($fixtureCli, $text.Replace($needle, "'" + $testDesktop.Replace("'","''") + "'"), [Text.UTF8Encoding]::new($false))
    $shortcutModule = Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\modules\CpaStack.ManagedShortcut.psm1'
    $text = [IO.File]::ReadAllText($shortcutModule)
    if (-not $text.Contains($needle)) { throw 'Shortcut module desktop isolation seam changed.' }
    [IO.File]::WriteAllText($shortcutModule, $text.Replace($needle, "'" + $testDesktop.Replace("'","''") + "'"), [Text.UTF8Encoding]::new($false))
    # A downloaded installer would discard fixture path isolation. Refuse, never skip its check.
    $selfUpdate = Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\modules\CpaStack.SelfUpdate.psm1'
    $text = [IO.File]::ReadAllText($selfUpdate)
    $pattern = 'Invoke-CpaStackUpdaterInstaller -ReleaseRoot \$ReleaseRoot -CodexHome \$CodexHome `\r?\n\s+-StackRoot \$StackRoot -ExpectedVersion \$ExpectedVersion'
    if ([regex]::Matches($text, $pattern).Count -ne 1) { throw 'Self-update isolation seam changed.' }
    $text = [regex]::Replace($text, $pattern, "throw 'Isolated test requires a new local fixture before updating updater.'")
    [IO.File]::WriteAllText($selfUpdate, $text, [Text.UTF8Encoding]::new($false))
    Write-Host 'Applying private ACLs to the test copy before starting any process.'
    Protect-CpaStackPrivateTree -Root $TestRoot
    $testCodex = Join-Path $TestRoot 'lab\codex'
    foreach ($action in @('Check','Update')) {
        $installText = @(& pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture.Repository 'install.ps1') -Action $action -CodexHome $testCodex -StackRoot $TestRoot -Json)
        $installExit = $LASTEXITCODE
        $installed = ($installText -join [Environment]::NewLine) | ConvertFrom-Json
        if ($installExit -ne 0 -or -not $installed.success) { throw 'Isolated installer failed.' }
    }
    $script:cli = Join-Path $testCodex 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
    $phase = 'start'
    Write-Host 'Starting test services on separate loopback ports.'
    $start = Invoke-TestCli -Arguments @('start','-Root',$TestRoot,'-NoBrowser','-Json')
    $phase = 'upgrade'
    Write-Host 'Running one public upgrade against the isolated test root.'
    $upgrade = Invoke-TestCli -Arguments @('upgrade','-Root',$TestRoot,'-Json')
    $report['upgrade'] = @{ outcome=$upgrade.outcome; changed=$upgrade.changed; rolledBack=$upgrade.rolledBack; recovered=$upgrade.recovered; warnings=$upgrade.warnings }
    $phase = 'completed'
    $report.success = $true
} catch {
    $report.error = $_.Exception.Message
} finally {
    $report.phase = $phase
    $unchanged = (Compare-CpaStackProductionListenerSnapshot -Guard $guard).Unchanged
    foreach ($path in $protectedFiles) { if ((Get-CpaStackFileHash -Path $path) -cne $baseline[$path]) { $unchanged = $false } }
    $report.productionUnchanged = $unchanged
    if (-not $unchanged) { $report.success = $false; $report.error = 'Production baseline changed; stop and inspect.' }
    $env:CPA_STACK_TEST_PROTECTED_PORTS = $oldProtectedPorts
    Close-CpaStackProductionGuard -Guard $guard
    if (Test-Path -LiteralPath $TestRoot) { Write-CpaStackJson -Value $report -Path (Join-Path $TestRoot 'test-result.json') }
    $report | ConvertTo-Json -Depth 6 -Compress
}
if (-not $report.success) { exit 1 }
