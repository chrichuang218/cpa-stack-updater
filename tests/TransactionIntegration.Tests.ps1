#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('All', 'CpaSuccess', 'CpaRollback', 'CpaHangCleanup', 'ManagerRollback', 'ManagerMigrationRollback', 'ManagerMigrationTamper', 'ManagerRecoveryGate', 'PendingGate')]
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
    private static string cpaConfigPath;
    private static int cpaPort;
    private static bool collectorEnabled;
    private static bool managerMode;
    private static bool sourceTampered;

    public static int Main(string[] args)
    {
        try
        {
            workingDirectory = Directory.GetCurrentDirectory();
            behavior = ReadOptional(Path.Combine(workingDirectory, "behavior.txt"), "good").Trim();
            managerMode = Path.GetFileNameWithoutExtension(
                System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName
            ).IndexOf("manager", StringComparison.OrdinalIgnoreCase) >= 0;

            string startRecordDirective = Path.Combine(workingDirectory, "start-record-path.txt");
            if (File.Exists(startRecordDirective))
            {
                string startRecordPath = File.ReadAllText(startRecordDirective).Trim();
                File.AppendAllText(
                    startRecordPath,
                    BuildId + "|" + System.Diagnostics.Process.GetCurrentProcess().Id + Environment.NewLine
                );
            }

            int port = managerMode ? ConfigureManager() : ConfigureCpa(args);
            if (behavior.IndexOf("hang-before-listen", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                System.Threading.Thread.Sleep(System.Threading.Timeout.Infinite);
            }
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

        cpaConfigPath = configPath;
        Match match = Regex.Match(File.ReadAllText(configPath), @"(?m)^port:\s*(\d+)\s*$");
        if (!match.Success)
        {
            throw new InvalidOperationException("Config has no numeric port.");
        }
        cpaPort = Int32.Parse(match.Groups[1].Value);
        return cpaPort;
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
        string collectorFallback = behavior.IndexOf("default-collector-false", StringComparison.OrdinalIgnoreCase) >= 0
            ? "false"
            : "true";
        collectorEnabled = Boolean.Parse(
            ReadOptional(Path.Combine(dataDirectory, "collector-state.txt"), collectorFallback).Trim()
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
            if (behavior.IndexOf("tamper-cpa-config", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                File.WriteAllText(
                    cpaConfigPath,
                    "host: 0.0.0.0\r\nport: " + cpaPort + "\r\napi-keys:\r\n  - fixture-client-key\r\n"
                );
            }
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
            if (!sourceTampered && behavior.IndexOf("tamper-source", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                string directive = Path.Combine(workingDirectory, "tamper-source.txt");
                if (File.Exists(directive))
                {
                    string sourcePath = File.ReadAllText(directive).Trim();
                    File.AppendAllText(sourcePath, "tampered-by-transaction-fixture");
                    sourceTampered = true;
                }
            }
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

$testRunRoot = Join-Path $env:TEMP ('cst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

    $compilerArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SourcePath "{1}" -OutputPath "{2}"' -f $compilerPath, $sourcePath, $OutputPath
    $compiler = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList $compilerArguments -WindowStyle Hidden -Wait -PassThru
    $compilerExitCode = $compiler.ExitCode
    $compiler.Dispose()
    if ($compilerExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Failed to compile transaction fixture executable: $BuildId"
    }
}

function New-ManagedRoot {
    param([string]$Name)

    $root = Join-Path $testRunRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

function New-ShortTimeoutTransactionScript {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [Parameter(Mandatory = $true)][string]$SourceScript,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $scriptDirectory = Join-Path $ControlRoot 'work\short-timeout-scripts'
    New-Item -ItemType Directory -Force -Path $scriptDirectory | Out-Null
    $commonDestination = Join-Path $scriptDirectory 'CpaStack.Common.ps1'
    if (-not (Test-Path -LiteralPath $commonDestination -PathType Leaf)) {
        Copy-Item -LiteralPath $commonScript -Destination $commonDestination
    }
    $destination = Join-Path $scriptDirectory $Name
    $content = [System.IO.File]::ReadAllText($SourceScript, [System.Text.UTF8Encoding]::new($false, $true))
    $content = $content.Replace('-Seconds 35', '-Seconds 3')
    Write-Utf8Text -Path $destination -Value $content
    return $destination
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

function Invoke-CpaHangBeforeListenCleanupTest {
    param([string]$OldBinary, [string]$NewBinary)

    $candidateFixture = New-ManagedRoot -Name 'cpa-candidate-hang-cleanup'
    $candidateRoot = $candidateFixture.Root
    $candidateRuntime = Join-Path $candidateRoot 'work\current\cpa-candidate'
    $candidateConfig = Join-Path $candidateRoot 'config\active.yaml'
    $candidateResultPath = Join-Path $candidateRoot 'state\cpa-candidate-result.json'
    $candidateStartRecord = Join-Path $candidateRoot 'candidate-start.txt'
    $candidatePort = Get-UnusedLoopbackPort
    New-Item -ItemType Directory -Force -Path $candidateRuntime | Out-Null
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidateRuntime 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $candidateRuntime 'behavior.txt') -Value 'hang-before-listen'
    Write-Utf8Text -Path (Join-Path $candidateRuntime 'start-record-path.txt') -Value $candidateStartRecord
    Write-CpaConfig -Path $candidateConfig -Port (Get-UnusedLoopbackPort)
    [void](Write-TestSecrets -ControlRoot $candidateRoot)
    $candidateHash = Get-CpaStackFileHash -Path (Join-Path $candidateRuntime 'cli-proxy-api.exe')
    $shortCandidateScript = New-ShortTimeoutTransactionScript -ControlRoot $candidateRoot -SourceScript $testCpaScript -Name 'Test-CpaCandidate.ps1'

    $candidateFailure = $null
    try {
        & $shortCandidateScript -ControlRoot $candidateRoot -CandidateRuntime $candidateRuntime -ActiveConfig $candidateConfig -ResultPath $candidateResultPath -ExpectedCandidateHash $candidateHash -Port $candidatePort -InProcess | Out-Null
    } catch {
        $candidateFailure = $_.Exception.Message
    }
    Assert-True -Condition ($candidateFailure -match 'did not claim port') -Message "A candidate that hangs before listen must time out. Failure=[$candidateFailure]"
    $candidateRecord = [System.IO.File]::ReadAllText($candidateStartRecord).Trim()
    Assert-True -Condition ($candidateRecord -match '^fixture-new\|(?<pid>\d+)$') -Message 'The hanging candidate records its fixed process id'
    $candidateProcessId = [int]([regex]::Match($candidateRecord, '\|(?<pid>\d+)$').Groups['pid'].Value)
    Assert-True -Condition ($null -eq (Get-Process -Id $candidateProcessId -ErrorAction SilentlyContinue)) -Message 'Candidate cleanup terminates the fixed process even though it never listened'
    Assert-True -Condition ($null -eq (Get-CpaStackListener -Port $candidatePort)) -Message 'Candidate cleanup leaves its temporary port free'

    $formalFixture = New-ManagedRoot -Name 'cpa-formal-hang-cleanup'
    $formalRoot = $formalFixture.Root
    $formalPort = Get-UnusedLoopbackPort
    $runtime = Join-Path $formalRoot 'runtime\cli-proxy-api'
    $formalCandidate = Join-Path $formalRoot 'work\current\cpa-candidate'
    $config = Join-Path $runtime 'config.yaml'
    $formalResultPath = Join-Path $formalRoot 'state\cpa-switch-result.json'
    $formalStartRecord = Join-Path $formalRoot 'formal-target-start.txt'
    $auth = Join-Path $runtime 'auth'
    $plugins = Join-Path $runtime 'plugins'
    New-Item -ItemType Directory -Force -Path $runtime, $formalCandidate, $auth, $plugins | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $runtime 'cli-proxy-api.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $formalCandidate 'cli-proxy-api.exe')
    Write-Utf8Text -Path (Join-Path $runtime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $formalCandidate 'behavior.txt') -Value 'hang-before-listen'
    Write-Utf8Text -Path (Join-Path $formalCandidate 'start-record-path.txt') -Value $formalStartRecord
    Write-Utf8Text -Path (Join-Path $auth 'account.json') -Value '{}'
    Write-Utf8Text -Path (Join-Path $plugins 'plugin.ps1') -Value '# rollback plugin'
    Write-CpaConfig -Path $config -Port $formalPort
    [void](Write-TestSecrets -ControlRoot $formalRoot)
    Protect-CpaStackPrivateTree -Root $auth
    Protect-CpaStackPrivateTree -Root $plugins
    $sourceExe = Join-Path $runtime 'cli-proxy-api.exe'
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $formalCandidateHash = Get-CpaStackFileHash -Path (Join-Path $formalCandidate 'cli-proxy-api.exe')
    $shortSwitchScript = New-ShortTimeoutTransactionScript -ControlRoot $formalRoot -SourceScript $switchCpaScript -Name 'Switch-CpaRuntime.ps1'
    try {
        [void](Start-CpaFixture -Executable $sourceExe -Runtime $runtime -Config $config -Port $formalPort)
        $formalFailure = $null
        try {
            & $shortSwitchScript -ControlRoot $formalRoot -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $formalCandidate -SourceConfig $config -ResultPath $formalResultPath -ExpectedCandidateHash $formalCandidateHash -Port $formalPort -InProcess | Out-Null
        } catch {
            $formalFailure = $_.Exception.Message
        }
        $formalResult = Read-CpaStackJson -Path $formalResultPath
        Assert-True -Condition ($formalFailure -match 'old service was restored') -Message "A formal target that hangs before listen must roll back. Failure=[$formalFailure]"
        Assert-True -Condition ([bool]$formalResult.rolledBack) -Message 'Healthy old CPA is restored after formal target hang'
        $formalRecord = [System.IO.File]::ReadAllText($formalStartRecord).Trim()
        Assert-True -Condition ($formalRecord -match '^fixture-new\|(?<pid>\d+)$') -Message 'The hanging formal target records its fixed process id'
        $formalTargetProcessId = [int]([regex]::Match($formalRecord, '\|(?<pid>\d+)$').Groups['pid'].Value)
        Assert-True -Condition ($null -eq (Get-Process -Id $formalTargetProcessId -ErrorAction SilentlyContinue)) -Message 'Formal rollback terminates the fixed target process even though it never listened'
        $restoredListener = Get-CpaStackListener -Port $formalPort
        Assert-True -Condition ($null -ne $restoredListener -and [int]$restoredListener.ProcessId -ne $formalTargetProcessId) -Message 'Only the restored old CPA owns the formal port'
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'Formal hang rollback restores the old executable'
    } finally {
        Stop-OwnedFixturePort -Port $formalPort -ManagedRoot $formalRoot
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
        Assert-True -Condition ([bool]$result.rolledBack) -Message "failed Manager formal validation should automatically roll back. Failure=$failure ResultError=$($result.error)"
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

function Invoke-ManagerMigrationTamperGateTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'manager-migration-tamper'
    $root = $fixture.Root
    $managerPort = Get-UnusedLoopbackPort
    $cpaPort = Get-UnusedLoopbackPort
    $legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('cpa-manager-legacy-source-' + [guid]::NewGuid().ToString('N'))
    [void]$legacySourceRoots.Add($legacyRoot)
    Protect-CpaStackPrivateDirectory -Path $legacyRoot

    $sourceRuntime = Join-Path $legacyRoot 'runtime'
    $sourceData = Join-Path $legacyRoot 'data'
    $targetRuntime = Join-Path $root 'runtime\manager-plus'
    $targetData = Join-Path $root 'data\manager-plus'
    $resultPath = Join-Path $root 'state\manager-migration-result.json'
    New-Item -ItemType Directory -Force -Path $sourceRuntime, $sourceData, $targetRuntime | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $sourceRuntime 'cpa-manager-plus.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $targetRuntime 'cpa-manager-plus.exe')
    Write-Utf8Text -Path (Join-Path $sourceRuntime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $sourceRuntime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $targetRuntime 'behavior.txt') -Value 'bad-page-tamper-source-default-collector-false'
    Write-Utf8Text -Path (Join-Path $targetRuntime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $sourceData 'data.key') -Value 'fixture-data-key'
    New-SqliteFixture -Path (Join-Path $sourceData 'usage.sqlite')
    Protect-CpaStackPrivateTree -Root $sourceRuntime
    Protect-CpaStackPrivateTree -Root $sourceData
    Write-StackConfig -Path (Join-Path $root 'config\stack.psd1') -CpaPort $cpaPort -ManagerPort $managerPort
    [void](Write-TestSecrets -ControlRoot $root)

    $sourceExe = Join-Path $sourceRuntime 'cpa-manager-plus.exe'
    $targetExe = Join-Path $targetRuntime 'cpa-manager-plus.exe'
    $sourceDataKey = Join-Path $sourceData 'data.key'
    Write-Utf8Text -Path (Join-Path $targetRuntime 'tamper-source.txt') -Value $sourceDataKey
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $oldDataKeyHash = Get-CpaStackFileHash -Path $sourceDataKey
    $newHash = Get-CpaStackFileHash -Path $targetExe
    try {
        [void](Start-ManagerFixture -Executable $sourceExe -Runtime $sourceRuntime -Data $sourceData -Port $managerPort)
        $failure = $null
        try {
            & $switchManagerScript `
                -ControlRoot $root `
                -SourceRuntime $sourceRuntime `
                -SourceData $sourceData `
                -TargetRuntime $targetRuntime `
                -TargetData $targetData `
                -CandidatePackageRoot $targetRuntime `
                -ResultPath $resultPath `
                -ExpectedCandidateHash $newHash `
                -ManagerPort $managerPort `
                -CpaPort $cpaPort `
                -InProcess | Out-Null
        } catch {
            $failure = $_.Exception.Message
        }

        Assert-True -Condition ($failure -match 'automatic recovery also failed') -Message "Tampered legacy Manager must make recovery fail closed. Failure=[$failure]"
        $result = Read-CpaStackJson -Path $resultPath
        Assert-False -Condition ([bool]$result.success) -Message 'Tampered non-in-place Manager migration should fail'
        Assert-False -Condition ([bool]$result.rolledBack) -Message 'Tampered legacy Manager must not be reported as safely restored'
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'Fixture leaves the legacy executable unchanged'
        Assert-False -Condition ((Get-CpaStackFileHash -Path $sourceDataKey) -eq $oldDataKeyHash) -Message "Fixture should have changed the stopped legacy data key. Failure=[$failure] Result=[$($result.error)]"
        Assert-True -Condition ($null -eq (Get-CpaStackListener -Port $managerPort)) -Message 'Recovery trust failure must not execute either Manager binary'
    } finally {
        $listener = Get-CpaStackListener -Port $managerPort
        if ($listener -and $listener.ExecutablePath -in @($sourceExe, $targetExe)) {
            Stop-CpaStackPort -Port $managerPort -ExpectedPath $listener.ExecutablePath
        }
    }
}

function Invoke-ManagerMigrationRollbackTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'manager-migration-rollback'
    $root = $fixture.Root
    $managerPort = Get-UnusedLoopbackPort
    $cpaPort = Get-UnusedLoopbackPort
    $legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('cpa-manager-legacy-rollback-' + [guid]::NewGuid().ToString('N'))
    [void]$legacySourceRoots.Add($legacyRoot)
    Protect-CpaStackPrivateDirectory -Path $legacyRoot
    $sourceRuntime = Join-Path $legacyRoot 'runtime'
    $sourceData = Join-Path $legacyRoot 'data'
    $targetRuntime = Join-Path $root 'runtime\manager-plus'
    $targetData = Join-Path $root 'data\manager-plus'
    $resultPath = Join-Path $root 'state\manager-migration-result.json'
    New-Item -ItemType Directory -Force -Path $sourceRuntime, $sourceData, $targetRuntime | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $sourceRuntime 'cpa-manager-plus.exe')
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $targetRuntime 'cpa-manager-plus.exe')
    Write-Utf8Text -Path (Join-Path $sourceRuntime 'behavior.txt') -Value 'good-old'
    Write-Utf8Text -Path (Join-Path $sourceRuntime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $targetRuntime 'behavior.txt') -Value 'bad-page-default-collector-false'
    Write-Utf8Text -Path (Join-Path $targetRuntime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $sourceData 'data.key') -Value 'fixture-data-key'
    New-SqliteFixture -Path (Join-Path $sourceData 'usage.sqlite')
    Protect-CpaStackPrivateTree -Root $sourceRuntime
    Protect-CpaStackPrivateTree -Root $sourceData
    Write-StackConfig -Path (Join-Path $root 'config\stack.psd1') -CpaPort $cpaPort -ManagerPort $managerPort
    [void](Write-TestSecrets -ControlRoot $root)

    $sourceExe = Join-Path $sourceRuntime 'cpa-manager-plus.exe'
    $targetExe = Join-Path $targetRuntime 'cpa-manager-plus.exe'
    $oldHash = Get-CpaStackFileHash -Path $sourceExe
    $oldDataKeyHash = Get-CpaStackFileHash -Path (Join-Path $sourceData 'data.key')
    $newHash = Get-CpaStackFileHash -Path $targetExe
    try {
        [void](Start-ManagerFixture -Executable $sourceExe -Runtime $sourceRuntime -Data $sourceData -Port $managerPort)
        $failure = $null
        try {
            & $switchManagerScript -ControlRoot $root -SourceRuntime $sourceRuntime -SourceData $sourceData -TargetRuntime $targetRuntime -TargetData $targetData -CandidatePackageRoot $targetRuntime -ResultPath $resultPath -ExpectedCandidateHash $newHash -ManagerPort $managerPort -CpaPort $cpaPort -InProcess | Out-Null
        } catch {
            $failure = $_.Exception.Message
        }
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($failure)) -Message 'Bad non-in-place Manager candidate should fail'
        $result = Read-CpaStackJson -Path $resultPath
        Assert-True -Condition ([bool]$result.rolledBack) -Message "Trusted legacy Manager should be restored. Failure=[$failure] Result=[$($result.error)]"
        Assert-Equal -Expected $oldHash -Actual (Get-CpaStackFileHash -Path $sourceExe) -Message 'Non-in-place rollback preserves the legacy executable'
        Assert-Equal -Expected $oldDataKeyHash -Actual (Get-CpaStackFileHash -Path (Join-Path $sourceData 'data.key')) -Message 'Non-in-place rollback preserves the legacy data key'
        $listener = Get-CpaStackListener -Port $managerPort
        [void](Wait-CpaStackTrustedListener -Port $managerPort -ExpectedPath $sourceExe -ExpectedProcessId $listener.ProcessId -ExpectedHash $oldHash -AllowedAddresses @('127.0.0.1') -Seconds 2)
    } finally {
        $listener = Get-CpaStackListener -Port $managerPort
        if ($listener -and $listener.ExecutablePath -in @($sourceExe, $targetExe)) {
            Stop-CpaStackPort -Port $managerPort -ExpectedPath $listener.ExecutablePath
        }
    }
}

function Invoke-ManagerRecoverySourceGateTest {
    param([string]$OldBinary)

    $legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('cpa-manager-recovery-gate-' + [guid]::NewGuid().ToString('N'))
    [void]$legacySourceRoots.Add($legacyRoot)
    Protect-CpaStackPrivateDirectory -Path $legacyRoot
    $runtime = Join-Path $legacyRoot 'runtime'
    $data = Join-Path $legacyRoot 'data'
    New-Item -ItemType Directory -Force -Path $runtime, $data | Out-Null
    $executable = Join-Path $runtime 'cpa-manager-plus.exe'
    $database = Join-Path $data 'usage.sqlite'
    $dataKey = Join-Path $data 'data.key'
    Copy-Item -LiteralPath $OldBinary -Destination $executable
    Write-Utf8Text -Path $dataKey -Value 'fixture-data-key'
    New-SqliteFixture -Path $database
    Protect-CpaStackPrivateTree -Root $runtime
    Protect-CpaStackPrivateTree -Root $data

    $python = Get-CpaStackPythonCommand
    $seedCode = "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('INSERT INTO usage_events(timestamp_ms) VALUES (1000),(2000)'); c.execute('INSERT INTO settings(name,value) VALUES (?,?)',('fixture','stable')); c.commit(); c.close()"
    $seedArguments = @($python.Prefix) + @('-c', $seedCode, $database)
    & $python.Path @seedArguments
    if ($LASTEXITCODE -ne 0) { throw 'Failed to seed the Manager recovery SQLite fixture.' }

    $baselineRoot = Join-Path $legacyRoot 'baseline'
    New-Item -ItemType Directory -Path $baselineRoot | Out-Null
    $baselineDatabase = Join-Path $baselineRoot 'usage.sqlite'
    $baseline = Invoke-CpaStackSqliteBackup -Source $database -Destination $baselineDatabase -ResultPath (Join-Path $baselineRoot 'sqlite.json')
    $executableHash = Get-CpaStackFileHash -Path $executable
    $dataKeyHash = Get-CpaStackFileHash -Path $dataKey
    [void](Assert-CpaStackManagerRecoverySource `
        -Runtime $runtime `
        -Data $data `
        -ExpectedExecutableSha256 $executableHash `
        -ExpectedDataKeySha256 $dataKeyHash `
        -ExpectedSnapshot $baseline `
        -VerificationRoot (Join-Path $legacyRoot 'verify-good'))

    Write-Utf8Text -Path $dataKey -Value 'changed-data-key'
    Assert-ThrowsMatch {
        Assert-CpaStackManagerRecoverySource -Runtime $runtime -Data $data -ExpectedExecutableSha256 $executableHash -ExpectedDataKeySha256 $dataKeyHash -ExpectedSnapshot $baseline -VerificationRoot (Join-Path $legacyRoot 'verify-key')
    } 'data.key changed' 'Manager recovery rejects a changed data key before execution'
    Write-Utf8Text -Path $dataKey -Value 'fixture-data-key'

    $baselineDatabaseHash = Get-CpaStackFileHash -Path $database
    $physicalRewriteArguments = @($python.Prefix) + @('-c', "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA user_version=7'); c.commit(); c.close()", $database)
    & $python.Path @physicalRewriteArguments
    if ($LASTEXITCODE -ne 0) { throw 'Failed to rewrite the Manager recovery SQLite fixture.' }
    Assert-False -Condition ((Get-CpaStackFileHash -Path $database) -eq $baselineDatabaseHash) -Message 'Physical SQLite bytes change for the semantic recovery test'
    [void](Assert-CpaStackManagerRecoverySource -Runtime $runtime -Data $data -ExpectedExecutableSha256 $executableHash -ExpectedDataKeySha256 $dataKeyHash -ExpectedSnapshot $baseline -VerificationRoot (Join-Path $legacyRoot 'verify-physical-rewrite'))

    $regressionArguments = @($python.Prefix) + @('-c', "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('DELETE FROM usage_events WHERE id=(SELECT max(id) FROM usage_events)'); c.commit(); c.close()", $database)
    & $python.Path @regressionArguments
    if ($LASTEXITCODE -ne 0) { throw 'Failed to regress the Manager recovery SQLite fixture.' }
    Assert-ThrowsMatch {
        Assert-CpaStackManagerRecoverySource -Runtime $runtime -Data $data -ExpectedExecutableSha256 $executableHash -ExpectedDataKeySha256 $dataKeyHash -ExpectedSnapshot $baseline -VerificationRoot (Join-Path $legacyRoot 'verify-database')
    } 'count regressed' 'Manager recovery rejects a usage_events count below the rollback baseline'
    Copy-Item -LiteralPath $baselineDatabase -Destination $database -Force

    [System.IO.File]::AppendAllText($executable, 'changed-executable')
    Assert-ThrowsMatch {
        Assert-CpaStackManagerRecoverySource -Runtime $runtime -Data $data -ExpectedExecutableSha256 $executableHash -ExpectedDataKeySha256 $dataKeyHash -ExpectedSnapshot $baseline -VerificationRoot (Join-Path $legacyRoot 'verify-executable')
    } 'executable changed' 'Manager recovery rejects a changed executable before execution'
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
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'runtime')
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'data')

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
    if ($Case -in @('All', 'CpaHangCleanup')) {
        Invoke-CpaHangBeforeListenCleanupTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'ManagerRollback')) {
        Invoke-ManagerSwitchRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'ManagerMigrationRollback')) {
        Invoke-ManagerMigrationRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'ManagerMigrationTamper')) {
        Invoke-ManagerMigrationTamperGateTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'ManagerRecoveryGate')) {
        Invoke-ManagerRecoverySourceGateTest -OldBinary $oldBinary
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
        Remove-TestPathWithRetry -Path $testRunRoot
    }
    foreach ($legacyRoot in $legacySourceRoots) {
        Remove-TestPathWithRetry -Path $legacyRoot
    }
}
