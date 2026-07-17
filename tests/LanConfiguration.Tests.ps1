$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('cpa-lan-v2-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $temp 'managed root'
$stackConfig = Join-Path $root 'config\stack.psd1'
$cpaConfig = Join-Path $root 'runtime\cli-proxy-api\config.yaml'

try {
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $fixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $repo `
        -DestinationRepository (Join-Path $temp 'repository') `
        -LocalAppDataRoot (Join-Path $temp 'local-app-data')
    $common = Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1'
    $entry = Join-Path $fixture.Repository 'skills\cpa-safe-upgrade\scripts\Set-CpaStackLan.ps1'
    . $common
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Protect-CpaStackPrivateDirectory -Path $root
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $root -AllowCreate
    foreach ($directory in @('config', 'state', 'runtime\cli-proxy-api', 'runtime\manager-plus', 'data\manager-plus')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $directory) | Out-Null
    }
    [ordered]@{
        schemaVersion = 1
        instanceId = [string]$marker.instanceId
        canonicalRoot = $root
        cpa = [ordered]@{ version = 'fixture'; executable = (Join-Path $root 'runtime\cli-proxy-api\cli-proxy-api.exe'); sha256 = ('A' * 64) }
        manager = [ordered]@{ version = 'fixture'; executable = (Join-Path $root 'runtime\manager-plus\cpa-manager-plus.exe'); sha256 = ('B' * 64) }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'state\current.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'runtime\cli-proxy-api\cli-proxy-api.exe') -Value 'fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'runtime\manager-plus\cpa-manager-plus.exe') -Value 'fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'data\manager-plus\data.key') -Value 'fixture' -Encoding ASCII
    @'
host: "127.0.0.1"
port: 23117
api-keys:
  - fixture-key
'@ | Set-Content -LiteralPath $cpaConfig -Encoding UTF8
    @"
@{
    SchemaVersion = 1
    StartupTimeoutSeconds = 10
    HttpTimeoutSeconds = 2
    Cpa = @{
        Executable = 'runtime\cli-proxy-api\cli-proxy-api.exe'
        WorkingDirectory = 'runtime\cli-proxy-api'
        Config = 'runtime\cli-proxy-api\config.yaml'
        Port = 23117
    }
    Manager = @{
        Executable = 'runtime\manager-plus\cpa-manager-plus.exe'
        WorkingDirectory = 'runtime\manager-plus'
        DataDirectory = 'data\manager-plus'
        Port = 28317
        BindAddress = '127.0.0.1'
        RequestMonitoringEnabled = `$true
    }
    Browser = @{
        Url = 'http://127.0.0.1:28317/management.html'
        Executable = ''
    }
}
"@ | Set-Content -LiteralPath $stackConfig -Encoding UTF8
    Protect-CpaStackSecretFile -Path $stackConfig
    Protect-CpaStackSecretFile -Path $cpaConfig

    $stackHash = (Get-FileHash -LiteralPath $stackConfig -Algorithm SHA256).Hash
    $cpaHash = (Get-FileHash -LiteralPath $cpaConfig -Algorithm SHA256).Hash
    $stackTime = (Get-Item -LiteralPath $stackConfig).LastWriteTimeUtc
    $cpaTime = (Get-Item -LiteralPath $cpaConfig).LastWriteTimeUtc

    $output = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -ControlRoot $root -Mode Loopback 2>&1)
    Assert-Equal 1 $LASTEXITCODE ('Matching config without a verified runtime is blocked. Output=' + ($output -join ' | '))
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-False ([bool]$result.success) 'Matching files cannot masquerade as a healthy LAN configuration'
    Assert-False ([bool]$result.changed) 'Matching LAN configuration reports no change'
    Assert-Equal 'Loopback' $result.mode 'LAN result reports the requested mode'
    Assert-Equal $stackHash (Get-FileHash -LiteralPath $stackConfig -Algorithm SHA256).Hash 'NoChange preserves stack config content'
    Assert-Equal $cpaHash (Get-FileHash -LiteralPath $cpaConfig -Algorithm SHA256).Hash 'NoChange preserves CPA config content'
    Assert-Equal $stackTime (Get-Item -LiteralPath $stackConfig).LastWriteTimeUtc 'NoChange preserves stack config timestamp'
    Assert-Equal $cpaTime (Get-Item -LiteralPath $cpaConfig).LastWriteTimeUtc 'NoChange preserves CPA config timestamp'
    Assert-False (Test-Path -LiteralPath (Join-Path $root 'state\lan.pending.json')) 'NoChange creates no journal'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-TestPathWithRetry -Path $temp }
}

'LAN configuration tests passed.'
