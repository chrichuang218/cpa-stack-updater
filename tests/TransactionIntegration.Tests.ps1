#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('All', 'CpaSuccess', 'CpaRollback', 'CpaPluginGate', 'CpaMigrationBinding', 'ManagerRollback', 'PendingGate')]
    [string]$Case = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$scriptRoot = Join-Path $repo 'skills\cpa-safe-upgrade\scripts'
$commonScript = Join-Path $scriptRoot 'CpaStack.Common.ps1'
$switchCpaScript = Join-Path $scriptRoot 'Switch-CpaRuntime.ps1'
$testCpaScript = Join-Path $scriptRoot 'Test-CpaCandidate.ps1'
$switchManagerScript = Join-Path $scriptRoot 'Switch-ManagerRuntime.ps1'
$isolatedStartStackScript = $null
$isolatedLocalAppData = $null

. $commonScript

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'Transaction integration tests skipped: Windows is required.'
    return
}

$stubSource = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

public static class Program
{
    public const string BuildId = "__BUILD_ID__";

    private static string workingDirectory;
    private static string behavior;
    private static string dataDirectory;
    private static string databasePath;
    private static int cpaPort;
    private static bool collectorEnabled;
    private static bool managerMode;

    public static int Main(string[] args)
    {
        try
        {
            workingDirectory = Directory.GetCurrentDirectory();
            behavior = ReadOptional(Path.Combine(workingDirectory, "behavior.txt"), "good").Trim();
            managerMode = Path.GetFileNameWithoutExtension(
                System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName
            ).IndexOf("manager", StringComparison.OrdinalIgnoreCase) >= 0;

            int port = managerMode ? ConfigureManager() : ConfigureCpa(args);
            TcpListener listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            while (true)
            {
                using (TcpClient client = listener.AcceptTcpClient())
                {
                    try
                    {
                        Handle(client);
                    }
                    catch (IOException)
                    {
                        // A probe may close immediately after reading the body.
                    }
                    catch (SocketException)
                    {
                        // Keep the fixture alive for the next independent probe.
                    }
                    catch (Exception)
                    {
                        // Malformed or abandoned test probes must not end the server.
                    }
                }
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.ToString());
            return 1;
        }
    }

    private static int ConfigureCpa(string[] args)
    {
        string configPath = null;
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "-config", StringComparison.OrdinalIgnoreCase))
            {
                configPath = args[index + 1].Trim('"');
                break;
            }
        }
        if (string.IsNullOrWhiteSpace(configPath))
        {
            throw new InvalidOperationException("Missing -config argument.");
        }

        Match match = Regex.Match(File.ReadAllText(configPath), @"(?m)^port:\s*(\d+)\s*$");
        if (!match.Success)
        {
            throw new InvalidOperationException("Config has no numeric port.");
        }
        return Int32.Parse(match.Groups[1].Value);
    }

    private static int ConfigureManager()
    {
        string address = Environment.GetEnvironmentVariable("HTTP_ADDR");
        if (string.IsNullOrWhiteSpace(address))
        {
            throw new InvalidOperationException("HTTP_ADDR is missing.");
        }
        Match match = Regex.Match(address, @":(\d+)$");
        if (!match.Success)
        {
            throw new InvalidOperationException("HTTP_ADDR has no port.");
        }

        dataDirectory = Environment.GetEnvironmentVariable("USAGE_DATA_DIR");
        databasePath = Environment.GetEnvironmentVariable("USAGE_DB_PATH");
        cpaPort = Int32.Parse(ReadOptional(Path.Combine(workingDirectory, "cpa-port.txt"), "8317").Trim());
        collectorEnabled = Boolean.Parse(
            ReadOptional(Path.Combine(dataDirectory, "collector-state.txt"), "true").Trim()
        );
        return Int32.Parse(match.Groups[1].Value);
    }

    private static void Handle(TcpClient client)
    {
        NetworkStream stream = client.GetStream();
        StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 4096, true);
        string requestLine = reader.ReadLine();
        if (string.IsNullOrWhiteSpace(requestLine))
        {
            return;
        }

        int contentLength = 0;
        string header;
        while (!string.IsNullOrEmpty(header = reader.ReadLine()))
        {
            if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
            {
                contentLength = Int32.Parse(header.Substring(header.IndexOf(':') + 1).Trim());
            }
        }

        string body = String.Empty;
        if (contentLength > 0)
        {
            char[] buffer = new char[contentLength];
            int offset = 0;
            while (offset < buffer.Length)
            {
                int read = reader.Read(buffer, offset, buffer.Length - offset);
                if (read <= 0) break;
                offset += read;
            }
            body = new String(buffer, 0, offset);
        }

        string[] requestParts = requestLine.Split(' ');
        string method = requestParts.Length > 0 ? requestParts[0] : "GET";
        string path = requestParts.Length > 1 ? requestParts[1] : "/";
        if (managerMode)
        {
            HandleManager(stream, method, path, body);
        }
        else
        {
            HandleCpa(stream, path);
        }
    }

    private static void HandleCpa(Stream stream, string path)
    {
        if (path.StartsWith("/v1/models", StringComparison.OrdinalIgnoreCase))
        {
            string models = behavior.IndexOf("bad-models", StringComparison.OrdinalIgnoreCase) >= 0
                ? "{\"data\":[]}"
                : "{\"data\":[{\"id\":\"fixture-model\"}]}";
            WriteResponse(stream, "200 OK", "application/json", models);
            return;
        }
        if (path.StartsWith("/v0/management/config", StringComparison.OrdinalIgnoreCase))
        {
            WriteResponse(stream, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }
        WriteResponse(stream, "404 Not Found", "application/json", "{\"error\":\"not-found\"}");
    }

    private static void HandleManager(Stream stream, string method, string path, string body)
    {
        if (string.Equals(method, "POST", StringComparison.OrdinalIgnoreCase) &&
            path.StartsWith("/setup", StringComparison.OrdinalIgnoreCase))
        {
            Match requested = Regex.Match(
                body,
                "\\\"requestMonitoringEnabled\\\"\\s*:\\s*(true|false)",
                RegexOptions.IgnoreCase
            );
            if (requested.Success)
            {
                collectorEnabled = Boolean.Parse(requested.Groups[1].Value);
                File.WriteAllText(
                    Path.Combine(dataDirectory, "collector-state.txt"),
                    collectorEnabled ? "true" : "false"
                );
            }
            WriteResponse(stream, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }
        if (path.StartsWith("/health", StringComparison.OrdinalIgnoreCase))
        {
            WriteResponse(stream, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }
        if (path.StartsWith("/usage-service/info", StringComparison.OrdinalIgnoreCase))
        {
            WriteResponse(
                stream,
                "200 OK",
                "application/json",
                "{\"configured\":true,\"adminReady\":true,\"dataKeyReady\":true," +
                "\"setupRequired\":false,\"migrationStatus\":\"ready\",\"hasHistoricalData\":false}"
            );
            return;
        }
        if (path.StartsWith("/usage-service/config", StringComparison.OrdinalIgnoreCase))
        {
            string config = "{\"config\":{\"cpaConnection\":{\"cpaBaseUrl\":\"http://127.0.0.1:" +
                cpaPort + "\"},\"collector\":{\"enabled\":" +
                (collectorEnabled ? "true" : "false") +
                ",\"pollIntervalMs\":500}},\"cpaUsage\":{\"usageStatisticsEnabled\":true}}";
            WriteResponse(stream, "200 OK", "application/json", config);
            return;
        }
        if (path.StartsWith("/status", StringComparison.OrdinalIgnoreCase))
        {
            string status = "{\"collector\":{\"collector\":\"" +
                (collectorEnabled ? "running" : "stopped") +
                "\"},\"dbPath\":\"" + JsonEscape(databasePath) + "\"}";
            WriteResponse(stream, "200 OK", "application/json", status);
            return;
        }
        if (path.StartsWith("/management.html", StringComparison.OrdinalIgnoreCase))
        {
            string page = behavior.IndexOf("bad-page", StringComparison.OrdinalIgnoreCase) >= 0
                ? "<html>broken fixture</html>"
                : "<html>CPA Manager Plus fixture</html>";
            WriteResponse(stream, "200 OK", "text/html; charset=utf-8", page);
            return;
        }
        WriteResponse(stream, "404 Not Found", "application/json", "{\"error\":\"not-found\"}");
    }

    private static void WriteResponse(Stream stream, string status, string contentType, string content)
    {
        byte[] payload = Encoding.UTF8.GetBytes(content);
        string headers = "HTTP/1.1 " + status + "\r\n" +
            "Content-Type: " + contentType + "\r\n" +
            "Content-Length: " + payload.Length + "\r\n" +
            "Connection: close\r\n\r\n";
        byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
        stream.Write(headerBytes, 0, headerBytes.Length);
        stream.Write(payload, 0, payload.Length);
        stream.Flush();
    }

    private static string JsonEscape(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static string ReadOptional(string path, string fallback)
    {
        return File.Exists(path) ? File.ReadAllText(path) : fallback;
    }
}
'@

$testRunRoot = Join-Path $env:TEMP ('cpa-stack-transaction-tests-' + [guid]::NewGuid().ToString('N'))
$compileRoot = Join-Path $testRunRoot 'compiled'
$managedRoots = New-Object System.Collections.Generic.List[string]
$legacySourceRoots = New-Object System.Collections.Generic.List[string]
$usedPorts = @{}

function Write-Utf8Text {
    param([string]$Path, [string]$Value)

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Get-UnusedLoopbackPort {
    do {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        } finally {
            $listener.Stop()
        }
    } while ($usedPorts.ContainsKey($port) -or $port -in @(8317, 8318, 18317, 18318))

    $usedPorts[$port] = $true
    return $port
}

function Compile-StubExecutable {
    param([string]$BuildId, [string]$OutputPath)

    $sourcePath = Join-Path $compileRoot ($BuildId + '.cs')
    $compilerPath = Join-Path $compileRoot 'compile-stub.ps1'
    Write-Utf8Text -Path $sourcePath -Value $stubSource.Replace('__BUILD_ID__', $BuildId)
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        Write-Utf8Text -Path $compilerPath -Value @'
param([string]$SourcePath, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$code = [System.IO.File]::ReadAllText($SourcePath)
Add-Type -TypeDefinition $code -Language CSharp -OutputAssembly $OutputPath -OutputType ConsoleApplication -ErrorAction Stop
'@
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compilerPath -SourcePath $sourcePath -OutputPath $OutputPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Failed to compile transaction fixture executable: $BuildId"
    }
}

function New-ManagedRoot {
    param([string]$Name)

    $root = Join-Path $testRunRoot ($Name + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Protect-CpaStackPrivateDirectory -Path $root
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $root -AllowCreate
    $managedRoots.Add($root)
    return [pscustomobject]@{ Root = $root; Marker = $marker }
}

function Write-CpaConfig {
    param([string]$Path, [int]$Port)

    Write-Utf8Text -Path $Path -Value @"
host: 127.0.0.1
port: $Port
api-keys:
  - fixture-client-key
"@
}

function Write-StackConfig {
    param([string]$Path, [int]$CpaPort, [int]$ManagerPort)

    Write-Utf8Text -Path $Path -Value @"
@{
    SchemaVersion = 1
    StartupTimeoutSeconds = 5
    HttpTimeoutSeconds = 2
    Cpa = @{
        Executable = 'runtime\cli-proxy-api\cli-proxy-api.exe'
        WorkingDirectory = 'runtime\cli-proxy-api'
        Config = 'runtime\cli-proxy-api\config.yaml'
        Port = $CpaPort
    }
    Manager = @{
        Executable = 'runtime\manager-plus\cpa-manager-plus.exe'
        WorkingDirectory = 'runtime\manager-plus'
        DataDirectory = 'data\manager-plus'
        Port = $ManagerPort
        BindAddress = '127.0.0.1'
        RequestMonitoringEnabled = `$true
    }
    Browser = @{
        Url = 'http://127.0.0.1:$ManagerPort/management.html'
        Executable = ''
    }
}
"@
}

function Write-TestSecrets {
    param([string]$ControlRoot, [switch]$Protect)

    $path = Join-Path $ControlRoot 'config\secrets.local.json'
    Write-CpaStackJson -Value ([ordered]@{
        cpaClientApiKey = 'fixture-client-key'
        cpaManagementKey = 'fixture-management-key'
        managerAdminKey = 'fixture-admin-key'
    }) -Path $path
    if ($Protect) { Protect-CpaStackSecretFile -Path $path }
    return $path
}

function Start-CpaFixture {
    param([string]$Executable, [string]$Runtime, [string]$Config, [int]$Port)

    $process = Start-CpaStackProcess -FilePath $Executable -Arguments "-config `"$Config`"" -WorkingDirectory $Runtime
    $hash = Get-CpaStackFileHash -Path $Executable
    [void](Wait-CpaStackTrustedListener -Port $Port -ExpectedPath $Executable -ExpectedProcessId $process.Id -ExpectedHash $hash -AllowedAddresses @('127.0.0.1') -Seconds 10)
    return $process
}

function Start-ManagerFixture {
    param([string]$Executable, [string]$Runtime, [string]$Data, [int]$Port)

    $environment = @{
        HTTP_ADDR = "127.0.0.1:$Port"
        USAGE_DATA_DIR = $Data
        USAGE_DB_PATH = Join-Path $Data 'usage.sqlite'
        CPA_MANAGER_ADMIN_KEY = 'fixture-admin-key'
    }
    $process = Start-CpaStackProcess -FilePath $Executable -WorkingDirectory $Runtime -Environment $environment -RemoveEnvironment @('PANEL_PATH')
    $hash = Get-CpaStackFileHash -Path $Executable
    [void](Wait-CpaStackTrustedListener -Port $Port -ExpectedPath $Executable -ExpectedProcessId $process.Id -ExpectedHash $hash -AllowedAddresses @('127.0.0.1') -Seconds 10)
    return $process
}

function Stop-OwnedFixturePort {
    param([int]$Port, [string]$ManagedRoot)

    $listener = Get-CpaStackListener -Port $Port
    if (-not $listener) { return }
    $root = [System.IO.Path]::GetFullPath($ManagedRoot).TrimEnd('\') + '\'
    $executable = [System.IO.Path]::GetFullPath([string]$listener.ExecutablePath)
    if (-not $executable.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture cleanup refused an unexpected listener on port $Port."
    }
    Stop-Process -Id $listener.ProcessId -Force -ErrorAction Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $listener.ProcessId -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 100
    }
}

function New-SqliteFixture {
    param([string]$Path)

    $python = Get-CpaStackPythonCommand
    $code = "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE usage_events (id INTEGER PRIMARY KEY, timestamp_ms INTEGER NOT NULL)'); c.execute('CREATE TABLE settings (name TEXT PRIMARY KEY, value TEXT)'); c.commit(); c.close()"
    $arguments = @($python.Prefix) + @('-c', $code, $Path)
    & $python.Path @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Failed to create the Manager SQLite fixture.'
    }
}

function Invoke-CpaSwitchSuccessTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'cpa-success'
    $root = $fixture.Root
    $port = Get-UnusedLoopbackPort
    $runtime = Join-Path $root 'runtime\cli-proxy-api'
    $candidate = Join-Path $root 'work\current\cpa-candidate'
    $config = Join-Path $runtime 'config.yaml'
    $resultPath = Join-Path $root 'state\cpa-switch-result.json'
    $auth = Join-Path $runtime 'auth'
    $plugins = Join-Path $runtime 'plugins'
    New-Item -ItemType Directory -Force -Path $runtime, $candidate, $auth, $plugins | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $runtime 'cli-proxy-api.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidate 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $runtime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $candidate 'behavior.txt') -Value 'good-new'
    Write-Utf8Text -Path (Join-Path $auth 'account.json') -Value '{}'
    Write-Utf8Text -Path (Join-Path $plugins 'plugin.ps1') -Value '# preserved plugin'
    Write-CpaConfig -Path $config -Port $port
    [void](Write-TestSecrets -ControlRoot $root)
    Protect-CpaStackPrivateTree -Root $auth
    Protect-CpaStackPrivateTree -Root $plugins

    $sourceExe = Join-Path $runtime 'cli-proxy-api.exe'
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $newHash = Get-CpaStackFileHash -Path (Join-Path $candidate 'cli-proxy-api.exe')
    try {
        [void](Start-CpaFixture -Executable $sourceExe -Runtime $runtime -Config $config -Port $port)
        $json = & $switchCpaScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $candidate -SourceConfig $config -ResultPath $resultPath -ExpectedCandidateHash $newHash -Port $port -InProcess
        $result = ($json | Select-Object -Last 1) | ConvertFrom-Json

        Assert-True -Condition ([bool]$result.success) -Message 'real CPA in-place switch should succeed'
        Assert-False -Condition ([bool]$result.rolledBack) -Message 'successful CPA switch should not report rollback'
        Assert-Equal -Expected $newHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'successful CPA switch should activate the candidate binary'
        Assert-Equal -Expected 'good-new' -Actual ([System.IO.File]::ReadAllText((Join-Path $runtime 'behavior.txt')).Trim()) -Message 'candidate runtime payload should be active'
        Assert-Equal -Expected '# preserved plugin' -Actual ([System.IO.File]::ReadAllText((Join-Path $plugins 'plugin.ps1')).Trim()) -Message 'successful switch preserves the protected plugins tree'
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path (Join-Path $root 'rollback\last-known-good\cpa\runtime\cli-proxy-api.exe')) -Message 'successful switch should retain the old executable as last-known-good'
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $root 'state\switch-cpa.pending.json')) -Message 'successful switch should clear its pending journal'
        [void](Wait-CpaStackTrustedListener -Port $port -ExpectedPath $sourceExe -ExpectedProcessId (Get-CpaStackListener -Port $port).ProcessId -ExpectedHash $newHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
    } finally {
        Stop-OwnedFixturePort -Port $port -ManagedRoot $root
    }
}

function Invoke-CpaSwitchRollbackTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'cpa-rollback'
    $root = $fixture.Root
    $port = Get-UnusedLoopbackPort
    $runtime = Join-Path $root 'runtime\cli-proxy-api'
    $candidate = Join-Path $root 'work\current\cpa-candidate'
    $config = Join-Path $runtime 'config.yaml'
    $resultPath = Join-Path $root 'state\cpa-switch-result.json'
    $auth = Join-Path $runtime 'auth'
    $plugins = Join-Path $runtime 'plugins'
    New-Item -ItemType Directory -Force -Path $runtime, $candidate, $auth, $plugins | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $runtime 'cli-proxy-api.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidate 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $runtime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $candidate 'behavior.txt') -Value 'bad-models'
    Write-Utf8Text -Path (Join-Path $auth 'account.json') -Value '{}'
    Write-Utf8Text -Path (Join-Path $plugins 'plugin.ps1') -Value '# rollback plugin'
    Write-CpaConfig -Path $config -Port $port
    [void](Write-TestSecrets -ControlRoot $root)
    Protect-CpaStackPrivateTree -Root $auth
    Protect-CpaStackPrivateTree -Root $plugins

    $sourceExe = Join-Path $runtime 'cli-proxy-api.exe'
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $newHash = Get-CpaStackFileHash -Path (Join-Path $candidate 'cli-proxy-api.exe')
    try {
        [void](Start-CpaFixture -Executable $sourceExe -Runtime $runtime -Config $config -Port $port)
        $failure = $null
        try {
            & $switchCpaScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $candidate -SourceConfig $config -ResultPath $resultPath -ExpectedCandidateHash $newHash -Port $port -InProcess | Out-Null
        } catch {
            $failure = $_.Exception.Message
        }
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($failure)) -Message 'bad CPA formal health should fail the switch'

        $result = Read-CpaStackJson -Path $resultPath
        Assert-False -Condition ([bool]$result.success) -Message 'failed CPA switch result should be unsuccessful'
        Assert-True -Condition ([bool]$result.rolledBack) -Message "failed CPA formal validation should automatically roll back. Failure=[$failure] ResultError=[$($result.error)]"
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'CPA rollback should restore the old executable bytes'
        Assert-Equal -Expected 'good-old' -Actual ([System.IO.File]::ReadAllText((Join-Path $runtime 'behavior.txt')).Trim()) -Message 'CPA rollback should restore the old runtime payload'
        Assert-Equal -Expected '# rollback plugin' -Actual ([System.IO.File]::ReadAllText((Join-Path $plugins 'plugin.ps1')).Trim()) -Message 'CPA rollback preserves the protected plugins tree'
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $root 'state\switch-cpa.pending.json')) -Message 'completed CPA rollback should clear its pending journal'
        $listener = Get-CpaStackListener -Port $port
        [void](Wait-CpaStackTrustedListener -Port $port -ExpectedPath $sourceExe -ExpectedProcessId $listener.ProcessId -ExpectedHash $oldHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
        $models = Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$port/v1/models" -Headers @{ Authorization = 'Bearer fixture-client-key' }
        Assert-Equal -Expected 1 -Actual @($models.data).Count -Message 'CPA rollback should return the old service healthy'
    } finally {
        Stop-OwnedFixturePort -Port $port -ManagedRoot $root
    }
}

function Invoke-CpaPluginSecurityGateTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'cpa-plugin-gate'
    $root = $fixture.Root
    $port = Get-UnusedLoopbackPort
    $runtime = Join-Path $root 'runtime\cli-proxy-api'
    $candidate = Join-Path $root 'work\current\cpa-candidate'
    $config = Join-Path $runtime 'config.yaml'
    $resultPath = Join-Path $root 'state\cpa-switch-result.json'
    $plugins = Join-Path $runtime 'plugins'
    $auth = Join-Path $runtime 'auth'
    $nestedPlugins = Join-Path $plugins 'nested'
    New-Item -ItemType Directory -Force -Path $runtime, $candidate, $nestedPlugins, $auth | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $runtime 'cli-proxy-api.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidate 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $runtime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $candidate 'behavior.txt') -Value 'good-new'
    Write-Utf8Text -Path (Join-Path $auth 'account.json') -Value '{}'
    Write-Utf8Text -Path (Join-Path $nestedPlugins 'plugin.ps1') -Value '# plugin fixture'
    Write-CpaConfig -Path $config -Port $port
    [void](Write-TestSecrets -ControlRoot $root)
    Protect-CpaStackPrivateTree -Root $auth
    Protect-CpaStackPrivateTree -Root $plugins

    $untrustedSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $pluginAcl = Get-Acl -LiteralPath $nestedPlugins
    [void]$pluginAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $untrustedSid,
        [System.Security.AccessControl.FileSystemRights]::Write,
        [System.Security.AccessControl.AccessControlType]::Allow
    ))
    Set-Acl -LiteralPath $nestedPlugins -AclObject $pluginAcl

    $sourceExe = Join-Path $runtime 'cli-proxy-api.exe'
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $newHash = Get-CpaStackFileHash -Path (Join-Path $candidate 'cli-proxy-api.exe')
    try {
        $oldProcess = Start-CpaFixture -Executable $sourceExe -Runtime $runtime -Config $config -Port $port
        $failure = $null
        try {
            & $switchCpaScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $candidate -SourceConfig $config -ResultPath $resultPath -ExpectedCandidateHash $newHash -Port $port -InProcess | Out-Null
        } catch {
            $failure = $_.Exception.Message
        }
        Assert-True -Condition ($failure -match 'unexpected identity') -Message "CPA switch should reject an untrusted plugins write ACE. Failure=[$failure]"
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'plugin security gate leaves the old executable untouched'
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $root 'state\switch-cpa.pending.json')) -Message 'plugin security gate fails before writing a switch journal'
        [void](Wait-CpaStackTrustedListener -Port $port -ExpectedPath $sourceExe -ExpectedProcessId $oldProcess.Id -ExpectedHash $oldHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
    } finally {
        Stop-OwnedFixturePort -Port $port -ManagedRoot $root
    }
}

function Invoke-CpaMigrationSnapshotBindingTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'cpa-migration-binding'
    $root = $fixture.Root
    $port = Get-UnusedLoopbackPort
    $candidatePort = Get-UnusedLoopbackPort
    $legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('cpa-legacy-source-' + [guid]::NewGuid().ToString('N'))
    [void]$legacySourceRoots.Add($legacyRoot)
    New-Item -ItemType Directory -Force -Path $legacyRoot | Out-Null
    Protect-CpaStackPrivateDirectory -Path $legacyRoot

    $sourceRuntime = Join-Path $legacyRoot 'runtime'
    $sourceAuth = Join-Path $sourceRuntime 'auth'
    $sourcePlugins = Join-Path $sourceRuntime 'plugins'
    $sourceConfig = Join-Path $sourceRuntime 'config.yaml'
    New-Item -ItemType Directory -Force -Path $sourceAuth, $sourcePlugins | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $sourceRuntime 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $sourceRuntime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $sourceAuth 'account.json') -Value 'source-auth-before-candidate'
    Write-Utf8Text -Path (Join-Path $sourcePlugins 'plugin.ps1') -Value 'source-plugin-before-candidate'
    Write-CpaConfig -Path $sourceConfig -Port $port
    Protect-CpaStackPrivateTree -Root $sourceRuntime

    $targetRuntime = Join-Path $root 'runtime\cli-proxy-api'
    $targetAuth = Join-Path $targetRuntime 'auth'
    $targetPlugins = Join-Path $targetRuntime 'plugins'
    $targetConfig = Join-Path $targetRuntime 'config.yaml'
    New-Item -ItemType Directory -Force -Path $targetAuth, $targetPlugins | Out-Null
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $targetRuntime 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $targetRuntime 'behavior.txt') -Value 'good-new'
    Write-Utf8Text -Path (Join-Path $targetAuth 'account.json') -Value 'candidate-auth-snapshot'
    Write-Utf8Text -Path (Join-Path $targetPlugins 'plugin.ps1') -Value 'candidate-plugin-snapshot'
    Write-CpaConfig -Path $targetConfig -Port $port
    Protect-CpaStackPrivateTree -Root $targetRuntime
    [void](Write-TestSecrets -ControlRoot $root)

    $candidateHash = Get-CpaStackFileHash -Path (Join-Path $targetRuntime 'cli-proxy-api.exe')
    $candidateResultPath = Join-Path $root 'state\cpa-migration-candidate.json'
    $candidateJson = & $testCpaScript -ControlRoot $root -CandidateRuntime $targetRuntime -ActiveConfig $targetConfig -ActiveRuntime $sourceRuntime -ResultPath $candidateResultPath -ExpectedCandidateHash $candidateHash -Port $candidatePort -InProcess
    $candidateResult = ($candidateJson | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True -Condition ([bool]$candidateResult.success) -Message 'migration candidate should validate before snapshot binding'
    Assert-True -Condition ([string]$candidateResult.runtimeManifestSha256 -match '^[0-9A-F]{64}$') -Message 'candidate returns a post-exit runtime manifest digest'
    Assert-Equal -Expected '127.0.0.1' -Actual ([string]$candidateResult.activeConfigHost) -Message 'candidate binds the canonical target host'

    $sourceExe = Join-Path $sourceRuntime 'cli-proxy-api.exe'
    $targetExe = Join-Path $targetRuntime 'cli-proxy-api.exe'
    $resultPath = Join-Path $root 'state\cpa-migration-switch.json'
    try {
        $sourceProcess = Start-CpaFixture -Executable $sourceExe -Runtime $sourceRuntime -Config $sourceConfig -Port $port

        $untrustedSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
        $unsafePlugin = Join-Path $sourcePlugins 'plugin.ps1'
        $unsafeAcl = Get-Acl -LiteralPath $unsafePlugin
        [void]$unsafeAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $untrustedSid,
            [System.Security.AccessControl.FileSystemRights]::Write,
            [System.Security.AccessControl.AccessControlType]::Allow
        ))
        Set-Acl -LiteralPath $unsafePlugin -AclObject $unsafeAcl
        $gateFailure = $null
        try {
            & $switchCpaScript -ControlRoot $root -SourceRuntime $sourceRuntime -TargetRuntime $targetRuntime -CandidatePackageRoot $targetRuntime -SourceConfig $sourceConfig -ResultPath $resultPath -ExpectedCandidateHash $candidateHash -ExpectedTargetRuntimeManifestSha256 ([string]$candidateResult.runtimeManifestSha256) -ExpectedTargetConfigHash ([string]$candidateResult.activeConfigSha256) -ExpectedTargetHost ([string]$candidateResult.activeConfigHost) -Port $port -InProcess | Out-Null
        } catch {
            $gateFailure = $_.Exception.Message
        }
        Assert-True -Condition ($gateFailure -match 'mutable access') -Message "Unsafe legacy source must fail before migration switch. Failure=[$gateFailure]"
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $root 'state\switch-cpa.pending.json')) -Message 'unsafe legacy source fails before the switch journal'
        [void](Wait-CpaStackTrustedListener -Port $port -ExpectedPath $sourceExe -ExpectedProcessId $sourceProcess.Id -ExpectedHash (Get-CpaStackFileHash -Path $sourceExe) -AllowedAddresses @('127.0.0.1') -Seconds 2)

        Protect-CpaStackSecretFile -Path $unsafePlugin
        Write-Utf8Text -Path (Join-Path $sourceAuth 'account.json') -Value 'source-auth-after-candidate'
        Write-Utf8Text -Path $unsafePlugin -Value 'source-plugin-after-candidate'
        Write-Utf8Text -Path $sourceConfig -Value "host: 0.0.0.0`r`nport: $port`r`napi-keys:`r`n  - fixture-client-key"

        $switchJson = & $switchCpaScript -ControlRoot $root -SourceRuntime $sourceRuntime -TargetRuntime $targetRuntime -CandidatePackageRoot $targetRuntime -SourceConfig $sourceConfig -ResultPath $resultPath -ExpectedCandidateHash $candidateHash -ExpectedTargetRuntimeManifestSha256 ([string]$candidateResult.runtimeManifestSha256) -ExpectedTargetConfigHash ([string]$candidateResult.activeConfigSha256) -ExpectedTargetHost ([string]$candidateResult.activeConfigHost) -Port $port -InProcess
        $switchResult = ($switchJson | Select-Object -Last 1) | ConvertFrom-Json
        Assert-True -Condition ([bool]$switchResult.success) -Message 'bound non-in-place migration should succeed'
        Assert-Equal -Expected 'candidate-auth-snapshot' -Actual ([System.IO.File]::ReadAllText((Join-Path $targetAuth 'account.json')).Trim()) -Message 'formal migration uses the candidate-tested auth snapshot'
        Assert-Equal -Expected 'candidate-plugin-snapshot' -Actual ([System.IO.File]::ReadAllText((Join-Path $targetPlugins 'plugin.ps1')).Trim()) -Message 'formal migration uses the candidate-tested plugins snapshot'
        Assert-Equal -Expected '127.0.0.1' -Actual (Get-CpaStackConfigHost -ConfigPath $targetConfig) -Message 'formal migration preserves the candidate-bound loopback config'
        [void](Wait-CpaStackTrustedListener -Port $port -ExpectedPath $targetExe -ExpectedProcessId (Get-CpaStackListener -Port $port).ProcessId -ExpectedHash $candidateHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
    } finally {
        $listener = Get-CpaStackListener -Port $port
        if ($listener -and $listener.ExecutablePath -in @($sourceExe, $targetExe)) {
            Stop-CpaStackPort -Port $port -ExpectedPath $listener.ExecutablePath
        }
    }
}

function Invoke-ManagerSwitchRollbackTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'manager-rollback'
    $root = $fixture.Root
    $managerPort = Get-UnusedLoopbackPort
    $cpaPort = Get-UnusedLoopbackPort
    $runtime = Join-Path $root 'runtime\manager-plus'
    $data = Join-Path $root 'data\manager-plus'
    $candidate = Join-Path $root 'work\current\manager-candidate'
    $resultPath = Join-Path $root 'state\manager-switch-result.json'
    New-Item -ItemType Directory -Force -Path $runtime, $data, $candidate | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $runtime 'cpa-manager-plus.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidate 'cpa-manager-plus.exe')
    Write-Utf8Text -Path (Join-Path $runtime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $runtime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $candidate 'behavior.txt') -Value 'bad-page'
    Write-Utf8Text -Path (Join-Path $candidate 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $data 'data.key') -Value 'fixture-data-key'
    New-SqliteFixture -Path (Join-Path $data 'usage.sqlite')
    Write-StackConfig -Path (Join-Path $root 'config\stack.psd1') -CpaPort $cpaPort -ManagerPort $managerPort
    [void](Write-TestSecrets -ControlRoot $root)

    $sourceExe = Join-Path $runtime 'cpa-manager-plus.exe'
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $oldDataKeyHash = Get-CpaStackFileHash -Path (Join-Path $data 'data.key')
    $newHash = Get-CpaStackFileHash -Path (Join-Path $candidate 'cpa-manager-plus.exe')
    try {
        [void](Start-ManagerFixture -Executable $sourceExe -Runtime $runtime -Data $data -Port $managerPort)
        $failure = $null
        try {
            & $switchManagerScript -ControlRoot $root -SourceRuntime $runtime -SourceData $data -TargetRuntime $runtime -TargetData $data -CandidatePackageRoot $candidate -ResultPath $resultPath -ExpectedCandidateHash $newHash -ManagerPort $managerPort -CpaPort $cpaPort -InProcess | Out-Null
        } catch {
            $failure = $_.Exception.Message
        }
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($failure)) -Message 'bad Manager formal page should fail the switch'

        $result = Read-CpaStackJson -Path $resultPath
        Assert-False -Condition ([bool]$result.success) -Message 'failed Manager switch result should be unsuccessful'
        Assert-True -Condition ([bool]$result.rolledBack) -Message 'failed Manager formal validation should automatically roll back'
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'Manager rollback should restore the old executable bytes'
        Assert-Equal -Expected $oldDataKeyHash -Actual (Get-CpaStackFileHash -Path (Join-Path $data 'data.key')) -Message 'Manager rollback should preserve data.key'
        Assert-Equal -Expected 'good-old' -Actual ([System.IO.File]::ReadAllText((Join-Path $runtime 'behavior.txt')).Trim()) -Message 'Manager rollback should restore the old runtime payload'
        Assert-Equal -Expected 'true' -Actual ([System.IO.File]::ReadAllText((Join-Path $data 'collector-state.txt')).Trim()) -Message 'Manager rollback should restore the collector baseline'
        Assert-False -Condition (Test-Path -LiteralPath (Join-Path $root 'state\switch-manager.pending.json')) -Message 'completed Manager rollback should clear its pending journal'
        $listener = Get-CpaStackListener -Port $managerPort
        [void](Wait-CpaStackTrustedListener -Port $managerPort -ExpectedPath $sourceExe -ExpectedProcessId $listener.ProcessId -ExpectedHash $oldHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
        $page = Invoke-WebRequest -Uri "http://127.0.0.1:$managerPort/management.html" -UseBasicParsing -TimeoutSec 3
        Assert-True -Condition ($page.Content -match 'CPA Manager Plus') -Message 'Manager rollback should return the old service healthy'
    } finally {
        Stop-OwnedFixturePort -Port $managerPort -ManagedRoot $root
    }
}

function Invoke-PendingJournalStartupGateTest {
    param([string]$OldBinary)

    $fixture = New-ManagedRoot -Name 'pending-startup-gate'
    $root = $fixture.Root
    $cpaPort = Get-UnusedLoopbackPort
    $managerPort = Get-UnusedLoopbackPort
    $cpaRuntime = Join-Path $root 'runtime\cli-proxy-api'
    $managerRuntime = Join-Path $root 'runtime\manager-plus'
    $managerData = Join-Path $root 'data\manager-plus'
    New-Item -ItemType Directory -Force -Path $cpaRuntime, $managerRuntime, $managerData, (Join-Path $root 'ops') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $cpaRuntime 'auth') | Out-Null
    $cpaExe = Join-Path $cpaRuntime 'cli-proxy-api.exe'
    $managerExe = Join-Path $managerRuntime 'cpa-manager-plus.exe'
    Copy-Item -LiteralPath $OldBinary -Destination $cpaExe
    Copy-Item -LiteralPath $OldBinary -Destination $managerExe
    Write-CpaConfig -Path (Join-Path $cpaRuntime 'config.yaml') -Port $cpaPort
    Write-StackConfig -Path (Join-Path $root 'config\stack.psd1') -CpaPort $cpaPort -ManagerPort $managerPort
    Copy-Item -LiteralPath $isolatedStartStackScript -Destination (Join-Path $root 'ops\Start-CPA-Stack.ps1')
    [void](Write-TestSecrets -ControlRoot $root -Protect)
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        instanceId = [string]$fixture.Marker.instanceId
        canonicalRoot = $root
        cpa = [ordered]@{
            version = 'fixture-old'
            executable = $cpaExe
            sha256 = Get-CpaStackFileHash -Path $cpaExe
        }
        manager = [ordered]@{
            version = 'fixture-old'
            executable = $managerExe
            sha256 = Get-CpaStackFileHash -Path $managerExe
        }
    }) -Path (Join-Path $root 'state\current.json')
    Write-CpaStackJson -Value ([ordered]@{
        operation = 'switch-cpa'
        operationId = [guid]::NewGuid().ToString('N')
        instanceId = [string]$fixture.Marker.instanceId
        phase = 'source-stopped'
    }) -Path (Join-Path $root 'state\switch-cpa.pending.json')

    foreach ($criticalPath in @(
        (Join-Path $root '.cpa-stack-instance.json'),
        (Join-Path $root 'state\current.json'),
        (Join-Path $root 'config\stack.psd1'),
        (Join-Path $root 'ops\Start-CPA-Stack.ps1'),
        $cpaExe,
        $managerExe
    )) {
        Protect-CpaStackSecretFile -Path $criticalPath
    }
    Protect-CpaStackPrivateTree -Root (Join-Path $cpaRuntime 'auth')

    $failure = $null
    try {
        & $isolatedStartStackScript -ConfigPath (Join-Path $root 'config\stack.psd1') -SecretsPath (Join-Path $root 'config\secrets.local.json') -NoBrowser -InProcess | Out-Null
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True -Condition ($failure -match 'interrupted CPA stack transaction') -Message "standalone startup should refuse a pending transaction journal. Failure=[$failure]"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $isolatedLocalAppData 'CPAStack\locks\CPAStackSafeOperation.lock') -PathType Leaf) -Message 'pending journal startup gate should use the isolated operation lock'
    Assert-True -Condition ($null -eq (Get-CpaStackListener -Port $cpaPort)) -Message 'pending journal gate should not start CPA'
    Assert-True -Condition ($null -eq (Get-CpaStackListener -Port $managerPort)) -Message 'pending journal gate should not start Manager'
}

try {
    New-Item -ItemType Directory -Force -Path $testRunRoot | Out-Null
    $transactionFixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $repo `
        -DestinationRepository (Join-Path $testRunRoot 'repository') `
        -LocalAppDataRoot (Join-Path $testRunRoot 'local-app-data')
    $isolatedStartStackScript = Join-Path $transactionFixture.Repository 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
    $isolatedLocalAppData = $transactionFixture.LocalAppData
    New-Item -ItemType Directory -Force -Path $compileRoot | Out-Null
    $oldBinary = Join-Path $compileRoot 'fixture-old.exe'
    $newBinary = Join-Path $compileRoot 'fixture-new.exe'
    Compile-StubExecutable -BuildId 'fixture-old' -OutputPath $oldBinary
    Compile-StubExecutable -BuildId 'fixture-new' -OutputPath $newBinary
    Assert-False -Condition ((Get-CpaStackFileHash -Path $oldBinary) -eq (Get-CpaStackFileHash -Path $newBinary)) -Message 'fixture builds must have distinct executable hashes'

    if ($Case -in @('All', 'CpaSuccess')) {
        Invoke-CpaSwitchSuccessTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'CpaRollback')) {
        Invoke-CpaSwitchRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'CpaPluginGate')) {
        Invoke-CpaPluginSecurityGateTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'CpaMigrationBinding')) {
        Invoke-CpaMigrationSnapshotBindingTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'ManagerRollback')) {
        Invoke-ManagerSwitchRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'PendingGate')) {
        Invoke-PendingJournalStartupGateTest -OldBinary $oldBinary
    }

    Write-Host 'Transaction integration tests passed.'
} finally {
    foreach ($root in $managedRoots) {
        foreach ($listener in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction SilentlyContinue
            if ($process -and $process.ExecutablePath) {
                $rootPrefix = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
                $executable = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath)
                if ($executable.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    if (Test-Path -LiteralPath $testRunRoot) {
        Remove-Item -LiteralPath $testRunRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($legacyRoot in $legacySourceRoots) {
        if (Test-Path -LiteralPath $legacyRoot) {
            Remove-Item -LiteralPath $legacyRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
