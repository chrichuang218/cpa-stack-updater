#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('All', 'Core', 'CpaSuccess', 'CpaRollback', 'CpaHangCleanup', 'ManagerRollback', 'ManagerMigrationRollback', 'ManagerMigrationTamper', 'ManagerRecoveryGate', 'TransitionHealth', 'PendingGate', 'RecoveryJournalGuard', 'InterruptedCpaRollback', 'CpaAvailability', 'Maintenance', 'MaintenanceIdentity', 'MaintenanceResultWarning', 'MaintenanceLifecycle', 'MaintenanceRecovery', 'MaintenanceRollbackFailure', 'MaintenancePendingGuard', 'MaintenanceCommitRecovery')]
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
$stateScript = Join-Path $scriptRoot 'Get-CpaStackState.ps1'
$productionGuardModule = Join-Path $repo 'tools\CpaStack.ProductionGuard.psm1'
$isolatedStartStackScript = $null
$isolatedStackEntry = $null
$isolatedLocalAppData = $null
$productionGuard = $null
$startedProcessRegistration = $null

. $commonScript
Import-Module $productionGuardModule -Force

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
    private static IPAddress listenAddress;
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

            if (managerMode && args.Length > 0 &&
                string.Equals(args[0], "cleanup-derived", StringComparison.OrdinalIgnoreCase))
            {
                return RunCleanupDerived(args);
            }

            string failNextStart = Path.Combine(workingDirectory, "fail-next-start.once");
            if (managerMode && File.Exists(failNextStart))
            {
                File.Delete(failNextStart);
                throw new InvalidOperationException("Synthetic one-shot Manager restart failure.");
            }

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
            TcpListener listener = new TcpListener(listenAddress, port);
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
        string config = File.ReadAllText(configPath);
        Match match = Regex.Match(config, @"(?m)^port:\s*(\d+)\s*$");
        if (!match.Success)
        {
            throw new InvalidOperationException("Config has no numeric port.");
        }
        Match hostMatch = Regex.Match(config, @"(?m)^host:\s*[""']?([^""'#\s]+)[""']?\s*(?:#.*)?$");
        if (!hostMatch.Success)
        {
            throw new InvalidOperationException("Config has no host.");
        }
        listenAddress = ResolveListenAddress(hostMatch.Groups[1].Value);
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
        int separator = address.LastIndexOf(':');
        if (separator <= 0 || separator >= address.Length - 1)
        {
            throw new InvalidOperationException("HTTP_ADDR has no port.");
        }
        listenAddress = ResolveListenAddress(address.Substring(0, separator).Trim('[', ']'));

        dataDirectory = Environment.GetEnvironmentVariable("USAGE_DATA_DIR");
        databasePath = Environment.GetEnvironmentVariable("USAGE_DB_PATH");
        string cpaPortPath = Path.Combine(workingDirectory, "cpa-port.txt");
        if (!File.Exists(cpaPortPath))
        {
            throw new InvalidOperationException("Manager fixture requires an explicit CPA port plan.");
        }
        cpaPort = Int32.Parse(File.ReadAllText(cpaPortPath).Trim());
        string collectorFallback = behavior.IndexOf("default-collector-false", StringComparison.OrdinalIgnoreCase) >= 0
            ? "false"
            : "true";
        collectorEnabled = Boolean.Parse(
            ReadOptional(Path.Combine(dataDirectory, "collector-state.txt"), collectorFallback).Trim()
        );
        return Int32.Parse(address.Substring(separator + 1));
    }

    private static int RunCleanupDerived(string[] args)
    {
        string requestedDatabase = null;
        for (int index = 1; index < args.Length - 1; index++)
        {
            if (string.Equals(args[index], "--db-path", StringComparison.OrdinalIgnoreCase))
            {
                requestedDatabase = args[index + 1].Trim('"');
                break;
            }
        }
        if (string.IsNullOrWhiteSpace(requestedDatabase) || !File.Exists(requestedDatabase))
        {
            throw new InvalidOperationException("cleanup-derived requires an existing --db-path.");
        }

        string countPath = Path.Combine(workingDirectory, "cleanup-count.txt");
        int count = Int32.Parse(ReadOptional(countPath, "0").Trim()) + 1;
        File.WriteAllText(countPath, count.ToString());
        if (behavior.IndexOf("cleanup-fail", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            File.AppendAllText(requestedDatabase, "maintenance-fixture-tamper");
            return 23;
        }
        if (behavior.IndexOf("cleanup-restart-once", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            File.WriteAllText(Path.Combine(workingDirectory, "fail-next-start.once"), "fail");
        }
        return 0;
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
                "{\"configured\":true,\"adminReady\":true,\"projectInitialized\":true,\"dataKeyReady\":true," +
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

    private static IPAddress ResolveListenAddress(string value)
    {
        if (String.Equals(value, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return IPAddress.Loopback;
        }
        return IPAddress.Parse(value);
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
    if ($null -eq $productionGuard) { throw 'The production guard must be active before allocating test ports.' }
    $plan = New-CpaStackTestPortPlan -Guard $productionGuard -Name @('TransactionPort')
    $port = [int]$plan.Ports.TransactionPort
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

    $compilerInvocation = $null
    $compilerExitCode = -1
    $compilerOutput = ''
    $compilerError = ''
    try {
        # The wrapper reaches a ready gate before invoking Add-Type. The parent
        # registers that exact wrapper in the KILL_ON_JOB_CLOSE Job Object, then
        # releases the go gate so compiler descendants inherit the job.
        $compilerInvocation = Start-IsolatedInterruptedScript `
            -TargetScript $compilerPath `
            -Parameters ([ordered]@{
                SourcePath = $sourcePath
                OutputPath = $OutputPath
            })
        if (-not $compilerInvocation.Process.WaitForExit(120000)) {
            throw "Transaction fixture compiler exceeded its timeout: $BuildId"
        }
        $compilerExitCode = [int]$compilerInvocation.Process.ExitCode
        if (Test-Path -LiteralPath $compilerInvocation.StdoutPath -PathType Leaf) {
            $compilerOutput = [System.IO.File]::ReadAllText($compilerInvocation.StdoutPath)
        }
        if (Test-Path -LiteralPath $compilerInvocation.StderrPath -PathType Leaf) {
            $compilerError = [System.IO.File]::ReadAllText($compilerInvocation.StderrPath)
        }
    } finally {
        if ($null -ne $compilerInvocation) {
            Remove-IsolatedInterruptedScript -Invocation $compilerInvocation
            $compilerInvocation.Process.Dispose()
        }
    }
    if ($compilerExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Failed to compile transaction fixture executable: $BuildId. Exit=$compilerExitCode Output=[$compilerOutput] Error=[$compilerError]"
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

    $process = Start-CpaStackProcess -FilePath $Executable -Arguments "-config `"$Config`"" -WorkingDirectory $Runtime -StartedProcessRegistration $startedProcessRegistration
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
    $process = Start-CpaStackProcess -FilePath $Executable -WorkingDirectory $Runtime -Environment $environment -RemoveEnvironment @('PANEL_PATH') -StartedProcessRegistration $startedProcessRegistration
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
    $fixedProcess = Get-CpaStackFixedListenerProcess -Listener $listener -ExpectedPath $executable
    try {
        Stop-CpaStackPort -Port $Port -ExpectedPath $executable -ExpectedProcess $fixedProcess -RequireExecutableWriteAccess
    } finally {
        if ($fixedProcess -is [System.IDisposable]) { $fixedProcess.Dispose() }
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

function New-MaintenanceSqliteFixture {
    param([string]$Path)

    $python = Get-CpaStackPythonCommand
    $code = @'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute('CREATE TABLE usage_events (id INTEGER PRIMARY KEY, timestamp_ms INTEGER NOT NULL, request_service_tier TEXT, response_service_tier TEXT, cache_input_mode TEXT, normalized_uncached_input_tokens INTEGER, normalized_total_input_tokens INTEGER, normalized_cache_read_tokens INTEGER, normalized_cache_creation_tokens INTEGER)')
c.execute('CREATE TABLE settings (name TEXT PRIMARY KEY, value TEXT)')
c.execute('CREATE TABLE model_prices (name TEXT PRIMARY KEY, prompt_configured INTEGER, completion_configured INTEGER, cache_read_configured INTEGER, cache_creation_configured INTEGER)')
c.execute('CREATE TABLE usage_account_model_rollups (id INTEGER)')
c.execute('CREATE TABLE usage_rollup_checkpoints (id INTEGER)')
c.execute('CREATE TABLE usage_dashboard_hourly_rollups (id INTEGER)')
c.execute('INSERT INTO usage_events (id, timestamp_ms) VALUES (1, 1000)')
c.execute('INSERT INTO settings (name, value) VALUES (?, ?)', ('fixture', 'ready'))
c.commit()
c.close()
'@
    $arguments = @($python.Prefix) + @('-c', $code, $Path)
    & $python.Path @arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Failed to create the Manager SQLite fixture.'
    }
}

function Invoke-IsolatedRecoveryCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [ValidateSet('recover')][string]$Command = 'recover'
    )


    $runId = [guid]::NewGuid().ToString('N')
    $wrapperPath = Join-Path $testRunRoot 'invoke-recovery-command.ps1'
    $readyPath = Join-Path $testRunRoot ($runId + '.ready')
    $goPath = Join-Path $testRunRoot ($runId + '.go')
    $stdoutPath = Join-Path $testRunRoot ($runId + '.stdout')
    $stderrPath = Join-Path $testRunRoot ($runId + '.stderr')
    if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        Write-Utf8Text -Path $wrapperPath -Value @'
param(
    [string]$Entry,
    [string]$ControlRoot,
    [string]$Command,
    [string]$ReadyPath,
    [string]$GoPath
)
$ErrorActionPreference = 'Stop'
[System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) {
    if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for test Job Object registration.' }
    Start-Sleep -Milliseconds 25
}
& $Entry recover -Root $ControlRoot -Json
$commandSucceeded = $?
$commandExitCode = $LASTEXITCODE
if ($null -eq $commandExitCode) { $commandExitCode = if ($commandSucceeded) { 0 } else { 1 } }
exit ([int]$commandExitCode)
'@
    }

    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Entry "{1}" -ControlRoot "{2}" -Command {3} -ReadyPath "{4}" -GoPath "{5}"' -f `
        $wrapperPath, $isolatedStackEntry, $ControlRoot, $Command, $readyPath, $goPath
    $process = Start-Process `
        -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Source `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    $registered = $false
    try {
        $readyDeadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and -not $process.HasExited -and (Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 25
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            $errorText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
            throw "Recovery command wrapper did not reach the registration gate. Error=[$errorText]"
        }
        [void](Register-CpaStackTestProcess -Guard $productionGuard -Process $process)
        $registered = $true
        Write-Utf8Text -Path $goPath -Value 'go'
        if (-not $process.WaitForExit(120000)) {
            throw 'Recovery command exceeded the integration-test timeout.'
        }

        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        $json = $null
        foreach ($line in @($stdout -split '\r?\n')) {
            $candidate = $line.Trim()
            if (-not ($candidate.StartsWith('{') -and $candidate.EndsWith('}'))) { continue }
            try { $json = $candidate | ConvertFrom-Json } catch {}
        }
        if ($null -eq $json) {
            throw "Recovery command returned no JSON result. ExitCode=$($process.ExitCode) Output=[$stdout] Error=[$stderr]"
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Result = $json
            Output = $stdout
            ErrorOutput = $stderr
        }
    } finally {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(10000)
        }
        if (-not $registered) { $process.Dispose() }
        foreach ($path in @($readyPath, $goPath, $stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

function Start-IsolatedInterruptedScript {
    param(
        [Parameter(Mandatory = $true)][string]$TargetScript,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Parameters
    )

    $runId = [guid]::NewGuid().ToString('N')
    $wrapperPath = Join-Path $testRunRoot 'invoke-interrupted-script.ps1'
    $invocationPath = Join-Path $testRunRoot ($runId + '.invocation.json')
    $readyPath = Join-Path $testRunRoot ($runId + '.ready')
    $goPath = Join-Path $testRunRoot ($runId + '.go')
    $stdoutPath = Join-Path $testRunRoot ($runId + '.stdout')
    $stderrPath = Join-Path $testRunRoot ($runId + '.stderr')
    if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        Write-Utf8Text -Path $wrapperPath -Value @'
param(
    [string]$TargetScript,
    [string]$InvocationPath,
    [string]$ReadyPath,
    [string]$GoPath
)
$ErrorActionPreference = 'Stop'
$invocation = [System.IO.File]::ReadAllText($InvocationPath) | ConvertFrom-Json
$parameters = @{}
foreach ($property in @($invocation.PSObject.Properties)) {
    $parameters[[string]$property.Name] = $property.Value
}
[System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) {
    if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for test Job Object registration.' }
    Start-Sleep -Milliseconds 25
}
& $TargetScript @parameters
$commandSucceeded = $?
$commandExitCode = $LASTEXITCODE
if ($null -eq $commandExitCode) { $commandExitCode = if ($commandSucceeded) { 0 } else { 1 } }
exit ([int]$commandExitCode)
'@
    }
    Write-Utf8Text -Path $invocationPath -Value ($Parameters | ConvertTo-Json -Depth 8)

    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -TargetScript "{1}" -InvocationPath "{2}" -ReadyPath "{3}" -GoPath "{4}"' -f `
        $wrapperPath, $TargetScript, $invocationPath, $readyPath, $goPath
    $process = Start-Process `
        -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Source `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    $registered = $false
    try {
        $readyDeadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and -not $process.HasExited -and (Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 25
        }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
            $errorText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
            throw "Interrupted-command wrapper did not reach the registration gate. Error=[$errorText]"
        }
        [void](Register-CpaStackTestProcess -Guard $productionGuard -Process $process)
        $registered = $true
        Write-Utf8Text -Path $goPath -Value 'go'
        return [pscustomobject]@{
            Process = $process
            InvocationPath = $invocationPath
            ReadyPath = $readyPath
            GoPath = $goPath
            StdoutPath = $stdoutPath
            StderrPath = $stderrPath
        }
    } catch {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(10000)
        }
        if (-not $registered) { $process.Dispose() }
        foreach ($path in @($invocationPath, $readyPath, $goPath, $stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        throw
    }
}

function Remove-IsolatedInterruptedScript {
    param($Invocation)

    if ($null -eq $Invocation) { return }
    if (-not $Invocation.Process.HasExited) {
        $Invocation.Process.Kill()
        [void]$Invocation.Process.WaitForExit(10000)
    }
    foreach ($path in @(
        $Invocation.InvocationPath,
        $Invocation.ReadyPath,
        $Invocation.GoPath,
        $Invocation.StdoutPath,
        $Invocation.StderrPath
    )) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
    }
}

function Complete-IsolatedInvocation {
    param(
        [Parameter(Mandatory = $true)]$Invocation,
        [int]$TimeoutSeconds = 180
    )

    try {
        if (-not $Invocation.Process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "Isolated command exceeded its $TimeoutSeconds second timeout."
        }
        $stdout = if (Test-Path -LiteralPath $Invocation.StdoutPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($Invocation.StdoutPath)
        } else { '' }
        $stderr = if (Test-Path -LiteralPath $Invocation.StderrPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($Invocation.StderrPath)
        } else { '' }
        $documents = @()
        foreach ($line in @($stdout -split '\r?\n')) {
            $candidate = $line.Trim()
            if (-not ($candidate.StartsWith('{') -and $candidate.EndsWith('}'))) { continue }
            $document = $null
            try { $document = $candidate | ConvertFrom-Json } catch { $document = $null }
            if ($null -ne $document) { $documents += $document }
        }
        if ($documents.Count -ne 1) {
            throw "Isolated command returned $($documents.Count) JSON documents. Output=[$stdout] Error=[$stderr]"
        }
        return [pscustomobject]@{
            ExitCode = [int]$Invocation.Process.ExitCode
            Result = $documents[0]
            Output = $stdout
            ErrorOutput = $stderr
        }
    } finally {
        Remove-IsolatedInterruptedScript -Invocation $Invocation
        $Invocation.Process.Dispose()
    }
}

function Start-IsolatedMaintenanceCommand {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    return Start-IsolatedInterruptedScript -TargetScript $isolatedStackEntry -Parameters ([ordered]@{
        Command = 'maintenance'
        Root = $ControlRoot
        Action = 'CleanupDerived'
        Json = $true
    })
}

function Invoke-IsolatedMaintenanceCommand {
    param([Parameter(Mandatory = $true)][string]$ControlRoot)

    $invocation = Start-IsolatedMaintenanceCommand -ControlRoot $ControlRoot
    return Complete-IsolatedInvocation -Invocation $invocation
}

function New-ManagedStackFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Binary,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$CpaBehavior = 'good',
        [switch]$MaintenanceSchema
    )

    $fixture = New-ManagedRoot -Name $Name
    $root = $fixture.Root
    $cpaPort = Get-UnusedLoopbackPort
    $managerPort = Get-UnusedLoopbackPort
    [void](Assert-CpaStackTestIsolation `
        -Guard $productionGuard `
        -TestRoot $root `
        -TestStateHome $isolatedLocalAppData `
        -TestPort @($cpaPort, $managerPort))

    $cpaRuntime = Join-Path $root 'runtime\cli-proxy-api'
    $managerRuntime = Join-Path $root 'runtime\manager-plus'
    $managerData = Join-Path $root 'data\manager-plus'
    $cpaConfig = Join-Path $cpaRuntime 'config.yaml'
    $stackConfig = Join-Path $root 'config\stack.psd1'
    $cpaExe = Join-Path $cpaRuntime 'cli-proxy-api.exe'
    $managerExe = Join-Path $managerRuntime 'cpa-manager-plus.exe'
    New-Item -ItemType Directory -Force -Path $cpaRuntime, (Join-Path $cpaRuntime 'auth'), $managerRuntime, $managerData, (Join-Path $root 'ops') | Out-Null
    Copy-Item -LiteralPath $Binary -Destination $cpaExe
    Copy-Item -LiteralPath $Binary -Destination $managerExe
    Write-Utf8Text -Path (Join-Path $cpaRuntime 'behavior.txt') -Value $CpaBehavior
    Write-Utf8Text -Path (Join-Path $managerRuntime 'behavior.txt') -Value 'good'
    Write-Utf8Text -Path (Join-Path $managerRuntime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $managerData 'data.key') -Value 'fixture-data-key'
    Write-Utf8Text -Path (Join-Path $managerData 'collector-state.txt') -Value 'true'
    if ($MaintenanceSchema) {
        New-MaintenanceSqliteFixture -Path (Join-Path $managerData 'usage.sqlite')
    } else {
        New-SqliteFixture -Path (Join-Path $managerData 'usage.sqlite')
    }
    Write-CpaConfig -Path $cpaConfig -Port $cpaPort
    Write-StackConfig -Path $stackConfig -CpaPort $cpaPort -ManagerPort $managerPort
    Copy-Item -LiteralPath $isolatedStartStackScript -Destination (Join-Path $root 'ops\Start-CPA-Stack.ps1')
    [void](Write-TestSecrets -ControlRoot $root -Protect)
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        instanceId = [string]$fixture.Marker.instanceId
        canonicalRoot = $root
        cpa = [ordered]@{
            version = 'fixture-stack'
            executable = $cpaExe
            sha256 = Get-CpaStackFileHash -Path $cpaExe
        }
        manager = [ordered]@{
            version = 'fixture-stack'
            executable = $managerExe
            sha256 = Get-CpaStackFileHash -Path $managerExe
        }
    }) -Path (Join-Path $root 'state\current.json')

    foreach ($directory in @((Join-Path $root 'config'), (Join-Path $root 'ops'), (Join-Path $root 'state'))) {
        Protect-CpaStackPrivateDirectory -Path $directory
    }
    foreach ($path in @(
        (Join-Path $root '.cpa-stack-instance.json'),
        (Join-Path $root 'state\current.json'),
        $stackConfig,
        (Join-Path $root 'ops\Start-CPA-Stack.ps1'),
        $cpaConfig,
        $cpaExe,
        $managerExe
    )) {
        Protect-CpaStackSecretFile -Path $path
    }
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'runtime')
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'data')

    try {
        [void](Start-CpaFixture -Executable $cpaExe -Runtime $cpaRuntime -Config $cpaConfig -Port $cpaPort)
        [void](Start-ManagerFixture -Executable $managerExe -Runtime $managerRuntime -Data $managerData -Port $managerPort)
    } catch {
        Stop-OwnedFixturePort -Port $cpaPort -ManagedRoot $root
        Stop-OwnedFixturePort -Port $managerPort -ManagedRoot $root
        throw
    }

    return [pscustomobject]@{
        Root = $root
        CpaPort = $cpaPort
        ManagerPort = $managerPort
        CpaConfig = $cpaConfig
        StackConfig = $stackConfig
    }
}





function Invoke-MaintenanceIdentityGateTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-identity' -MaintenanceSchema
    $maintenanceScript = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Invoke-CpaStackMaintenance.ps1'
    $originalScript = [System.IO.File]::ReadAllText($maintenanceScript, [System.Text.UTF8Encoding]::new($false, $true))
    $needle = '        $result.managerStopped = Stop-MaintenanceManager -Context $context'
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($needle)).Count) 'Maintenance identity fixture has one pre-stop seam'
    $holdCode = @'
        [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_MAINTENANCE_HOLD_READY_PATH, 'ready', [System.Text.UTF8Encoding]::new($false))
        while (-not (Test-Path -LiteralPath $env:CPA_STACK_TEST_MAINTENANCE_HOLD_RELEASE_PATH -PathType Leaf)) {
            Start-Sleep -Milliseconds 50
        }
'@
    Write-Utf8Text -Path $maintenanceScript -Value ($originalScript.Replace($needle, $holdCode.TrimEnd() + [Environment]::NewLine + $needle))

    $readyPath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-ready')
    $releasePath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-release')
    $previousReady = $env:CPA_STACK_TEST_MAINTENANCE_HOLD_READY_PATH
    $previousRelease = $env:CPA_STACK_TEST_MAINTENANCE_HOLD_RELEASE_PATH
    $invocation = $null
    $replacement = $null
    try {
        $env:CPA_STACK_TEST_MAINTENANCE_HOLD_READY_PATH = $readyPath
        $env:CPA_STACK_TEST_MAINTENANCE_HOLD_RELEASE_PATH = $releasePath
        $invocation = Start-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $invocation.Process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $readyPath -PathType Leaf) 'Maintenance reaches the pre-stop identity seam'

        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        $managerRuntime = Join-Path $fixture.Root 'runtime\manager-plus'
        $replacement = Start-ManagerFixture `
            -Executable (Join-Path $managerRuntime 'cpa-manager-plus.exe') `
            -Runtime $managerRuntime `
            -Data (Join-Path $fixture.Root 'data\manager-plus') `
            -Port $fixture.ManagerPort
        Write-Utf8Text -Path $releasePath -Value 'release'

        $run = Complete-IsolatedInvocation -Invocation $invocation
        $invocation = $null
        Assert-True ($run.ExitCode -ne 0) 'Manager PID replacement blocks maintenance'
        Assert-False ([bool]$run.Result.success) 'Manager PID replacement reports failure'
        Assert-Equal 'MaintenanceProcessChanged' ([string]$run.Result.error.code) 'Manager PID replacement has a stable error code'
        $replacement.Refresh()
        Assert-False ([bool]$replacement.HasExited) 'Maintenance does not stop the replacement Manager process'
        Assert-Equal ([int]$replacement.Id) ([int](Get-CpaStackListener -Port $fixture.ManagerPort).ProcessId) 'Replacement Manager remains the formal listener'
    } finally {
        $env:CPA_STACK_TEST_MAINTENANCE_HOLD_READY_PATH = $previousReady
        $env:CPA_STACK_TEST_MAINTENANCE_HOLD_RELEASE_PATH = $previousRelease
        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        if ($null -ne $invocation) {
            Remove-IsolatedInterruptedScript -Invocation $invocation
            $invocation.Process.Dispose()
        }
        if ($null -ne $replacement) { $replacement.Dispose() }
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        foreach ($path in @($readyPath, $releasePath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

function Invoke-MaintenanceResultPersistenceWarningTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-result-warning' -MaintenanceSchema
    $resultPath = Join-Path $fixture.Root 'state\maintenance-result.json'
    Write-Utf8Text -Path $resultPath -Value '{}'
    Protect-CpaStackSecretFile -Path $resultPath
    $resultHandle = [System.IO.File]::Open(
        $resultPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    try {
        $run = Invoke-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        Assert-Equal 0 $run.ExitCode "Maintenance remains successful when only result persistence fails. Output=[$($run.Output)] Error=[$($run.ErrorOutput)]"
        Assert-True ([bool]$run.Result.success) 'Committed maintenance remains successful after result persistence failure'
        Assert-True (@($run.Result.warnings | Where-Object { [string]$_ -match 'result file.*persist' }).Count -eq 1) 'Result persistence failure is exposed as one warning'
        Assert-True ([bool]$run.Result.maintenance.databaseVerified) 'Result persistence warning preserves database verification evidence'
        Assert-True ([bool]$run.Result.maintenance.managerRestarted) 'Result persistence warning preserves restart evidence'
        Assert-True ($null -ne (Get-CpaStackListener -Port $fixture.CpaPort)) 'Result persistence warning leaves CPA healthy'
        Assert-True ($null -ne (Get-CpaStackListener -Port $fixture.ManagerPort)) 'Result persistence warning leaves Manager healthy'
    } finally {
        $resultHandle.Dispose()
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
    }
}

function Assert-MaintenanceFixtureDatabase {
    param([Parameter(Mandatory = $true)][string]$Root)

    $validator = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Test-ManagerData.ps1'
    $database = Join-Path $Root 'data\manager-plus\usage.sqlite'
    $output = @(& pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $validator -DatabasePath $database 2>&1)
    $exitCode = $LASTEXITCODE
    $document = (@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-Equal 0 $exitCode 'Maintenance fixture database passes the bundled validator'
    Assert-True ([bool]$document.success) 'Maintenance fixture database remains valid'
    Assert-Equal 1 ([Int64]$document.database.usage_events.count) 'Maintenance preserves the authoritative request count'
    return $document
}

function Assert-MaintenanceFixtureHealthy {
    param([Parameter(Mandatory = $true)]$Fixture)

    Assert-True ($null -ne (Get-CpaStackListener -Port $Fixture.CpaPort)) 'Maintenance leaves CPA healthy'
    Assert-True ($null -ne (Get-CpaStackListener -Port $Fixture.ManagerPort)) 'Maintenance leaves Manager healthy'
    Assert-False (Test-Path -LiteralPath (Join-Path $Fixture.Root 'state\maintenance.pending.json')) 'Maintenance leaves no pending journal'
    Assert-False (Test-Path -LiteralPath (Join-Path $Fixture.Root 'state\maintenance.pending.json.previous')) 'Maintenance leaves no previous journal'
    [void](Assert-MaintenanceFixtureDatabase -Root $Fixture.Root)
}

function Invoke-MaintenanceLifecycleTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $successFixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-success' -MaintenanceSchema
    try {
        $beforeCpa = Get-CpaStackListener -Port $successFixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $successFixture.ManagerPort
        $success = Invoke-IsolatedMaintenanceCommand -ControlRoot $successFixture.Root
        Assert-Equal 0 $success.ExitCode "Maintenance succeeds. Output=[$($success.Output)] Error=[$($success.ErrorOutput)]"
        Assert-True ([bool]$success.Result.success) 'Successful maintenance reports success'
        Assert-Equal 'Changed' ([string]$success.Result.outcome) 'Successful maintenance reports Changed'
        Assert-True ([bool]$success.Result.maintenance.databaseVerified) 'Successful maintenance verifies the database'
        Assert-True ([bool]$success.Result.maintenance.backupRetained) 'Successful maintenance retains a validated backup'
        Assert-Equal 1 ([int](Get-Content -Raw (Join-Path $successFixture.Root 'runtime\manager-plus\cleanup-count.txt')).Trim()) 'Successful maintenance runs cleanup-derived once'
        Assert-Equal ([int]$beforeCpa.ProcessId) ([int](Get-CpaStackListener -Port $successFixture.CpaPort).ProcessId) 'Successful maintenance does not restart CPA'
        Assert-True ([int]$beforeManager.ProcessId -ne [int](Get-CpaStackListener -Port $successFixture.ManagerPort).ProcessId) 'Successful maintenance restarts Manager'
        Assert-MaintenanceFixtureHealthy -Fixture $successFixture
    } finally {
        Stop-OwnedFixturePort -Port $successFixture.CpaPort -ManagedRoot $successFixture.Root
        Stop-OwnedFixturePort -Port $successFixture.ManagerPort -ManagedRoot $successFixture.Root
    }

    $cleanupFailureFixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-cleanup-rollback' -MaintenanceSchema
    try {
        Write-Utf8Text -Path (Join-Path $cleanupFailureFixture.Root 'runtime\manager-plus\behavior.txt') -Value 'cleanup-fail'
        $failure = Invoke-IsolatedMaintenanceCommand -ControlRoot $cleanupFailureFixture.Root
        Assert-Equal 1 $failure.ExitCode 'Synthetic cleanup failure returns nonzero'
        Assert-False ([bool]$failure.Result.success) 'Synthetic cleanup failure reports failure'
        Assert-Equal 'RolledBack' ([string]$failure.Result.outcome) 'Synthetic cleanup failure reports RolledBack'
        Assert-True ([bool]$failure.Result.rolledBack) 'Synthetic cleanup failure restores the backup'
        Assert-Equal 'CleanupDerivedFailed' ([string]$failure.Result.error.code) 'Synthetic cleanup failure preserves the stable code'
        $databaseText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes((Join-Path $cleanupFailureFixture.Root 'data\manager-plus\usage.sqlite')))
        Assert-False ($databaseText.Contains('maintenance-fixture-tamper')) 'Rollback removes the failed cleanup mutation'
        Assert-MaintenanceFixtureHealthy -Fixture $cleanupFailureFixture
    } finally {
        Stop-OwnedFixturePort -Port $cleanupFailureFixture.CpaPort -ManagedRoot $cleanupFailureFixture.Root
        Stop-OwnedFixturePort -Port $cleanupFailureFixture.ManagerPort -ManagedRoot $cleanupFailureFixture.Root
    }

    $restartFailureFixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-restart-rollback' -MaintenanceSchema
    try {
        Write-Utf8Text -Path (Join-Path $restartFailureFixture.Root 'runtime\manager-plus\behavior.txt') -Value 'cleanup-restart-once'
        $failure = Invoke-IsolatedMaintenanceCommand -ControlRoot $restartFailureFixture.Root
        Assert-Equal 1 $failure.ExitCode 'Synthetic first restart failure returns nonzero'
        Assert-Equal 'RolledBack' ([string]$failure.Result.outcome) 'Synthetic first restart failure reports RolledBack'
        Assert-Equal 'MaintenanceRestartFailed' ([string]$failure.Result.error.code) 'Synthetic first restart failure has a stable stage-specific code'
        Assert-Equal 'restart' ([string]$failure.Result.error.phase) 'Synthetic first restart failure reports the restart phase'
        Assert-True ([bool]$failure.Result.maintenance.managerRestarted) 'Rollback restarts Manager after the one-shot failure'
        Assert-False (Test-Path -LiteralPath (Join-Path $restartFailureFixture.Root 'runtime\manager-plus\fail-next-start.once')) 'One-shot restart failure is consumed'
        Assert-MaintenanceFixtureHealthy -Fixture $restartFailureFixture
    } finally {
        Stop-OwnedFixturePort -Port $restartFailureFixture.CpaPort -ManagedRoot $restartFailureFixture.Root
        Stop-OwnedFixturePort -Port $restartFailureFixture.ManagerPort -ManagedRoot $restartFailureFixture.Root
    }
}

function New-MaintenanceHardInterruptedFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Binary,
        [Parameter(Mandatory = $true)][ValidateSet('source-stopped', 'cleaned')][string]$Phase,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $fixture = New-ManagedStackFixture -Binary $Binary -Name $Name -MaintenanceSchema
    $maintenanceScript = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Invoke-CpaStackMaintenance.ps1'
    $originalScript = [System.IO.File]::ReadAllText($maintenanceScript, [System.Text.UTF8Encoding]::new($false, $true))
    $needle = if ($Phase -eq 'cleaned') {
        '        Write-MaintenanceJournal -Journal $journal -Phase cleaned'
    } else {
        "        Write-MaintenanceJournal -Journal `$journal -Phase '$Phase'"
    }
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($needle)).Count) "Maintenance hard-interruption fixture has one $Phase seam"
    $holdCode = @'
        [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_MAINTENANCE_HARD_READY_PATH, 'ready', [System.Text.UTF8Encoding]::new($false))
        while ($true) { Start-Sleep -Milliseconds 100 }
'@
    Write-Utf8Text -Path $maintenanceScript -Value ($originalScript.Replace($needle, $needle + [Environment]::NewLine + $holdCode.TrimEnd()))

    $readyPath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-hard-ready')
    $previousReady = $env:CPA_STACK_TEST_MAINTENANCE_HARD_READY_PATH
    $invocation = $null
    $job = $null
    try {
        $env:CPA_STACK_TEST_MAINTENANCE_HARD_READY_PATH = $readyPath
        $invocation = Start-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        $job = [CpaStackUpdater.ProductionGuard.KillOnCloseJob]::new()
        $job.Assign($invocation.Process)
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $invocation.Process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $readyPath -PathType Leaf) "Maintenance reaches persisted $Phase before hard interruption"
        $job.Dispose()
        $job = $null
        Assert-True ($invocation.Process.WaitForExit(10000)) 'Hard interruption stops the maintenance process tree'
    } finally {
        $env:CPA_STACK_TEST_MAINTENANCE_HARD_READY_PATH = $previousReady
        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        if ($null -ne $job) { $job.Dispose() }
        if ($null -ne $invocation) {
            Remove-IsolatedInterruptedScript -Invocation $invocation
            $invocation.Process.Dispose()
        }
    }

    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Root 'state\maintenance.pending.json') -PathType Leaf) "Hard interruption retains the $Phase maintenance journal"
    Assert-True ($null -eq (Get-CpaStackListener -Port $fixture.ManagerPort)) "Hard interruption at $Phase leaves Manager stopped for recovery"
    return [pscustomobject]@{ Fixture = $fixture; ReadyPath = $readyPath }
}

function Invoke-MaintenanceHardInterruptionCase {
    param(
        [Parameter(Mandatory = $true)][string]$Binary,
        [Parameter(Mandatory = $true)][ValidateSet('source-stopped', 'cleaned')][string]$Phase
    )

    $interrupted = New-MaintenanceHardInterruptedFixture -Binary $Binary -Phase $Phase -Name ('maintenance-hard-' + $Phase)
    $fixture = $interrupted.Fixture

    try {
        $recovery = Invoke-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        Assert-Equal 0 $recovery.ExitCode "Rerun recovers and completes $Phase maintenance. Output=[$($recovery.Output)] Error=[$($recovery.ErrorOutput)]"
        Assert-True ([bool]$recovery.Result.success) 'Maintenance rerun succeeds after hard interruption'
        Assert-True ([bool]$recovery.Result.recovered) 'Maintenance rerun reports recovered=true'
        $expectedCleanupCount = if ($Phase -eq 'cleaned') { 2 } else { 1 }
        Assert-Equal $expectedCleanupCount ([int](Get-Content -Raw (Join-Path $fixture.Root 'runtime\manager-plus\cleanup-count.txt')).Trim()) "Maintenance rerun executes the expected cleanup count after $Phase"
        Assert-MaintenanceFixtureHealthy -Fixture $fixture
    } finally {
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        if (Test-Path -LiteralPath $interrupted.ReadyPath) { Remove-Item -LiteralPath $interrupted.ReadyPath -Force }
    }
}

function Invoke-MaintenanceRecoveryTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    Invoke-MaintenanceHardInterruptionCase -Binary $Binary -Phase 'source-stopped'
    Invoke-MaintenanceHardInterruptionCase -Binary $Binary -Phase cleaned
}

function Invoke-MaintenanceRollbackFailureTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-rollback-failure' -MaintenanceSchema
    $maintenanceScript = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Invoke-CpaStackMaintenance.ps1'
    $originalScript = [System.IO.File]::ReadAllText($maintenanceScript, [System.Text.UTF8Encoding]::new($false, $true))
    $needle = '        $result.managerStopped = Stop-MaintenanceManager -Context $context -ExpectedProcessId $context.ProcessId'
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($needle)).Count) 'Maintenance rollback-failure fixture has one pre-stop seam'
    $holdCode = @'
        [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_READY_PATH, 'ready', [System.Text.UTF8Encoding]::new($false))
        while (-not (Test-Path -LiteralPath $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_RELEASE_PATH -PathType Leaf)) {
            Start-Sleep -Milliseconds 50
        }
'@
    Write-Utf8Text -Path $maintenanceScript -Value ($originalScript.Replace($needle, $holdCode.TrimEnd() + [Environment]::NewLine + $needle))
    Write-Utf8Text -Path (Join-Path $fixture.Root 'runtime\manager-plus\behavior.txt') -Value 'cleanup-fail'

    $readyPath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-rollback-ready')
    $releasePath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-rollback-release')
    $previousReady = $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_READY_PATH
    $previousRelease = $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_RELEASE_PATH
    $invocation = $null
    try {
        $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_READY_PATH = $readyPath
        $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_RELEASE_PATH = $releasePath
        $invocation = Start-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        $deadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $invocation.Process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $readyPath -PathType Leaf) 'Maintenance reaches the rollback-failure seam'
        $pending = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'rollback') -Directory -Filter 'pending-maintenance-*')
        Assert-Equal 1 $pending.Count 'Maintenance has one bound pending backup before stop'
        Add-Content -LiteralPath (Join-Path $pending[0].FullName 'data.key') -Value 'tampered' -Encoding ASCII
        Write-Utf8Text -Path $releasePath -Value 'release'
        $run = Complete-IsolatedInvocation -Invocation $invocation
        $invocation = $null
        Assert-Equal 1 $run.ExitCode 'Tampered rollback backup returns nonzero'
        Assert-Equal 'MaintenanceRollbackFailed' ([string]$run.Result.error.code) 'Tampered rollback backup reports the stable failure code'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Root 'state\maintenance.pending.json') -PathType Leaf) 'Rollback failure retains the maintenance journal'
        Assert-True (Test-Path -LiteralPath $pending[0].FullName -PathType Container) 'Rollback failure retains the tampered backup'
        Assert-True ($null -eq (Get-CpaStackListener -Port $fixture.ManagerPort)) 'Rollback failure does not invent a healthy Manager state'
        Assert-True ($null -ne (Get-CpaStackListener -Port $fixture.CpaPort)) 'Rollback failure leaves CPA unchanged'
    } finally {
        $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_READY_PATH = $previousReady
        $env:CPA_STACK_TEST_MAINTENANCE_ROLLBACK_RELEASE_PATH = $previousRelease
        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        if ($null -ne $invocation) {
            Remove-IsolatedInterruptedScript -Invocation $invocation
            $invocation.Process.Dispose()
        }
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        foreach ($path in @($readyPath, $releasePath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

function Invoke-MaintenancePendingRecoveryGuardTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $damaged = New-MaintenanceHardInterruptedFixture -Binary $Binary -Phase 'source-stopped' -Name 'maintenance-pending-damaged'
    try {
        $pending = @(Get-ChildItem -LiteralPath (Join-Path $damaged.Fixture.Root 'rollback') -Directory -Filter 'pending-maintenance-*')
        Assert-Equal 1 $pending.Count 'Interrupted maintenance retains one pending backup'
        Add-Content -LiteralPath (Join-Path $pending[0].FullName 'data.key') -Value 'tampered' -Encoding ASCII
        $recovery = Invoke-IsolatedMaintenanceCommand -ControlRoot $damaged.Fixture.Root
        Assert-Equal 1 $recovery.ExitCode 'Damaged pending backup recovery returns nonzero'
        Assert-Equal 'MaintenanceRollbackFailed' ([string]$recovery.Result.error.code) 'Damaged pending backup reports rollback failure'
        Assert-True (Test-Path -LiteralPath (Join-Path $damaged.Fixture.Root 'state\maintenance.pending.json') -PathType Leaf) 'Damaged pending recovery retains the journal'
        Assert-True (Test-Path -LiteralPath $pending[0].FullName -PathType Container) 'Damaged pending recovery retains backup evidence'
        Assert-True ($null -eq (Get-CpaStackListener -Port $damaged.Fixture.ManagerPort)) 'Damaged pending recovery leaves Manager stopped rather than inventing success'
    } finally {
        Stop-OwnedFixturePort -Port $damaged.Fixture.CpaPort -ManagedRoot $damaged.Fixture.Root
        Stop-OwnedFixturePort -Port $damaged.Fixture.ManagerPort -ManagedRoot $damaged.Fixture.Root
        if (Test-Path -LiteralPath $damaged.ReadyPath) { Remove-Item -LiteralPath $damaged.ReadyPath -Force }
    }

    $foreign = New-MaintenanceHardInterruptedFixture -Binary $Binary -Phase 'source-stopped' -Name 'maintenance-pending-foreign'
    try {
        $newInstanceId = [guid]::NewGuid().ToString('N')
        $markerPath = Join-Path $foreign.Fixture.Root '.cpa-stack-instance.json'
        $currentPath = Join-Path $foreign.Fixture.Root 'state\current.json'
        $marker = Read-CpaStackJson -Path $markerPath
        $current = Read-CpaStackJson -Path $currentPath
        $marker.instanceId = $newInstanceId
        $current.instanceId = $newInstanceId
        Write-CpaStackJson -Value $marker -Path $markerPath
        Write-CpaStackJson -Value $current -Path $currentPath
        $recovery = Invoke-IsolatedMaintenanceCommand -ControlRoot $foreign.Fixture.Root
        Assert-Equal 1 $recovery.ExitCode 'Foreign maintenance journal recovery returns nonzero'
        Assert-Equal 'MaintenanceRollbackFailed' ([string]$recovery.Result.error.code) 'Foreign maintenance journal reports rollback failure'
        Assert-True (Test-Path -LiteralPath (Join-Path $foreign.Fixture.Root 'state\maintenance.pending.json') -PathType Leaf) 'Foreign journal remains for diagnosis'
        Assert-True ($null -eq (Get-CpaStackListener -Port $foreign.Fixture.ManagerPort)) 'Foreign journal does not start or stop a new Manager instance'
    } finally {
        Stop-OwnedFixturePort -Port $foreign.Fixture.CpaPort -ManagedRoot $foreign.Fixture.Root
        Stop-OwnedFixturePort -Port $foreign.Fixture.ManagerPort -ManagedRoot $foreign.Fixture.Root
        if (Test-Path -LiteralPath $foreign.ReadyPath) { Remove-Item -LiteralPath $foreign.ReadyPath -Force }
    }

    $poisoned = New-MaintenanceHardInterruptedFixture -Binary $Binary -Phase 'source-stopped' -Name 'maintenance-pending-path-poisoned'
    try {
        $pending = @(Get-ChildItem -LiteralPath (Join-Path $poisoned.Fixture.Root 'rollback') -Directory -Filter 'pending-maintenance-*')
        Assert-Equal 1 $pending.Count 'Path-poisoned maintenance retains one pending backup'
        $manifestPath = Join-Path $pending[0].FullName 'manifest.json'
        $manifest = Read-CpaStackJson -Path $manifestPath
        $decoyDirectory = Join-Path $poisoned.Fixture.Root 'data\maintenance-decoy'
        New-Item -ItemType Directory -Force -Path $decoyDirectory | Out-Null
        Protect-CpaStackPrivateDirectory -Path $decoyDirectory
        $decoyDatabase = Join-Path $decoyDirectory 'usage.sqlite'
        Copy-Item -LiteralPath (Join-Path $pending[0].FullName 'usage.sqlite') -Destination $decoyDatabase
        Protect-CpaStackSecretFile -Path $decoyDatabase
        $cpaListenerBefore = Get-CpaStackListener -Port $poisoned.Fixture.CpaPort
        Assert-True ($null -ne $cpaListenerBefore) 'Path-poisoning fixture begins with a healthy CPA listener'
        $manifest.executable = Join-Path $poisoned.Fixture.Root 'runtime\cli-proxy-api\cli-proxy-api.exe'
        $manifest.database = $decoyDatabase
        $manifest.managerPort = $poisoned.Fixture.CpaPort
        Write-CpaStackJson -Value $manifest -Path $manifestPath

        $recovery = Invoke-IsolatedMaintenanceCommand -ControlRoot $poisoned.Fixture.Root
        Assert-Equal 1 $recovery.ExitCode 'Path-poisoned backup recovery returns nonzero'
        Assert-Equal 'MaintenanceRollbackFailed' ([string]$recovery.Result.error.code) 'Path-poisoned backup reports rollback failure'
        Assert-True (Test-Path -LiteralPath (Join-Path $poisoned.Fixture.Root 'state\maintenance.pending.json') -PathType Leaf) 'Path-poisoned recovery retains the journal'
        Assert-True (Test-Path -LiteralPath $pending[0].FullName -PathType Container) 'Path-poisoned recovery retains backup evidence'
        $cpaListenerAfter = Get-CpaStackListener -Port $poisoned.Fixture.CpaPort
        Assert-True ($null -ne $cpaListenerAfter) 'Path-poisoned recovery does not stop the CPA listener'
        Assert-Equal ([int]$cpaListenerBefore.ProcessId) ([int]$cpaListenerAfter.ProcessId) 'Path-poisoned recovery leaves the original CPA process untouched'
        Assert-True ($null -eq (Get-CpaStackListener -Port $poisoned.Fixture.ManagerPort)) 'Path-poisoned recovery leaves Manager stopped for explicit diagnosis'
    } finally {
        Stop-OwnedFixturePort -Port $poisoned.Fixture.CpaPort -ManagedRoot $poisoned.Fixture.Root
        Stop-OwnedFixturePort -Port $poisoned.Fixture.ManagerPort -ManagedRoot $poisoned.Fixture.Root
        if (Test-Path -LiteralPath $poisoned.ReadyPath) { Remove-Item -LiteralPath $poisoned.ReadyPath -Force }
    }
}

function Invoke-MaintenanceCommitRecoveryTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-commit-recovery' -MaintenanceSchema
    $maintenanceScript = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Invoke-CpaStackMaintenance.ps1'
    $originalScript = [System.IO.File]::ReadAllText($maintenanceScript, [System.Text.UTF8Encoding]::new($false, $true))
    $needle = '    $Journal.backupPath = Retain-MaintenanceBackup -Backup $Backup -OperationId $OperationId'
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($needle)).Count) 'Maintenance commit fixture has one post-retain seam'
    $holdCode = @'
        [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_MAINTENANCE_COMMIT_READY_PATH, 'ready', [System.Text.UTF8Encoding]::new($false))
        while (-not (Test-Path -LiteralPath $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_RELEASE_PATH -PathType Leaf)) {
            Start-Sleep -Milliseconds 50
        }
'@
    Write-Utf8Text -Path $maintenanceScript -Value ($originalScript.Replace($needle, $needle + [Environment]::NewLine + $holdCode.TrimEnd()))

    $readyPath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-commit-ready')
    $releasePath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-commit-release')
    $previousReady = $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_READY_PATH
    $previousRelease = $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_RELEASE_PATH
    $invocation = $null
    $journalHandle = $null
    try {
        $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_READY_PATH = $readyPath
        $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_RELEASE_PATH = $releasePath
        $invocation = Start-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $invocation.Process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $readyPath -PathType Leaf) 'Maintenance reaches post-retain commit seam'
        $journalPath = Join-Path $fixture.Root 'state\maintenance.pending.json'
        $journalHandle = [System.IO.File]::Open($journalPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        Write-Utf8Text -Path $releasePath -Value 'release'
        $first = Complete-IsolatedInvocation -Invocation $invocation
        $invocation = $null
        Assert-Equal 1 $first.ExitCode 'Locked commit journal returns nonzero without rolling back committed maintenance'
        Assert-Equal 'MaintenanceCommitIncomplete' ([string]$first.Result.error.code) 'Locked commit journal reports an incomplete commit'
        Assert-False ([bool]$first.Result.rolledBack) 'Commit cleanup failure does not undo validated maintenance'
        Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) 'Incomplete commit retains its journal'
        Assert-True ($null -ne (Get-CpaStackListener -Port $fixture.ManagerPort)) 'Incomplete commit leaves Manager healthy'
        $journalHandle.Dispose()
        $journalHandle = $null

        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        $recovery = Invoke-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        Assert-Equal 0 $recovery.ExitCode "Commit recovery rerun succeeds. Output=[$($recovery.Output)] Error=[$($recovery.ErrorOutput)]"
        Assert-True ([bool]$recovery.Result.recovered) 'Commit recovery rerun reports recovered=true'
        Assert-MaintenanceFixtureHealthy -Fixture $fixture
    } finally {
        $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_READY_PATH = $previousReady
        $env:CPA_STACK_TEST_MAINTENANCE_COMMIT_RELEASE_PATH = $previousRelease
        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        if ($null -ne $journalHandle) { $journalHandle.Dispose() }
        if ($null -ne $invocation) {
            Remove-IsolatedInterruptedScript -Invocation $invocation
            $invocation.Process.Dispose()
        }
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        foreach ($path in @($readyPath, $releasePath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

function Invoke-MaintenanceCommittedJournalCleanupTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-ManagedStackFixture -Binary $Binary -Name 'maintenance-committed-cleanup' -MaintenanceSchema
    $maintenanceScript = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Invoke-CpaStackMaintenance.ps1'
    $originalScript = [System.IO.File]::ReadAllText($maintenanceScript, [System.Text.UTF8Encoding]::new($false, $true))
    $needle = '    Write-MaintenanceJournal -Journal $Journal -Phase committed'
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($needle)).Count) 'Committed cleanup fixture has one persisted committed seam'
    $holdCode = @'
    [System.IO.File]::WriteAllText($env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_READY_PATH, 'ready', [System.Text.UTF8Encoding]::new($false))
    while (-not (Test-Path -LiteralPath $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_RELEASE_PATH -PathType Leaf)) {
        Start-Sleep -Milliseconds 50
    }
'@
    Write-Utf8Text -Path $maintenanceScript -Value ($originalScript.Replace($needle, $needle + [Environment]::NewLine + $holdCode.TrimEnd()))

    $readyPath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-committed-ready')
    $releasePath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.maintenance-committed-release')
    $previousReady = $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_READY_PATH
    $previousRelease = $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_RELEASE_PATH
    $invocation = $null
    $previousJournalHandle = $null
    try {
        $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_READY_PATH = $readyPath
        $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_RELEASE_PATH = $releasePath
        $invocation = Start-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and
            -not $invocation.Process.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $readyPath -PathType Leaf) 'Maintenance persists committed before journal cleanup'
        $journalPath = Join-Path $fixture.Root 'state\maintenance.pending.json'
        $previousJournalPath = $journalPath + '.previous'
        Assert-True (Test-Path -LiteralPath $previousJournalPath -PathType Leaf) 'Committed journal has a previous generation to clean'
        $previousJournalHandle = [System.IO.File]::Open($previousJournalPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        Write-Utf8Text -Path $releasePath -Value 'release'
        $first = Complete-IsolatedInvocation -Invocation $invocation
        $invocation = $null
        Assert-Equal 1 $first.ExitCode 'Locked previous journal returns nonzero after committed is durable'
        Assert-Equal 'MaintenanceCommitIncomplete' ([string]$first.Result.error.code) 'Committed journal cleanup failure reports incomplete commit'
        Assert-False ([bool]$first.Result.rolledBack) 'Committed journal cleanup failure does not roll back validated maintenance'
        Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) 'Failed previous-journal cleanup preserves the committed current journal'
        Assert-Equal 'committed' ([string](Read-CpaStackJson -Path $journalPath).phase) 'Preserved current journal records the committed phase'
        Assert-True ($null -ne (Get-CpaStackListener -Port $fixture.ManagerPort)) 'Committed cleanup failure leaves Manager healthy'
        $previousJournalHandle.Dispose()
        $previousJournalHandle = $null

        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        $recovery = Invoke-IsolatedMaintenanceCommand -ControlRoot $fixture.Root
        Assert-Equal 0 $recovery.ExitCode "Committed cleanup recovery rerun succeeds. Output=[$($recovery.Output)] Error=[$($recovery.ErrorOutput)]"
        Assert-True ([bool]$recovery.Result.recovered) 'Committed cleanup recovery reports recovered=true'
        Assert-MaintenanceFixtureHealthy -Fixture $fixture
    } finally {
        $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_READY_PATH = $previousReady
        $env:CPA_STACK_TEST_MAINTENANCE_COMMITTED_RELEASE_PATH = $previousRelease
        Write-Utf8Text -Path $maintenanceScript -Value $originalScript
        if ($null -ne $previousJournalHandle) { $previousJournalHandle.Dispose() }
        if ($null -ne $invocation) {
            Remove-IsolatedInterruptedScript -Invocation $invocation
            $invocation.Process.Dispose()
        }
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        foreach ($path in @($readyPath, $releasePath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
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
        $json = & $switchCpaScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $candidate -SourceConfig $config -ResultPath $resultPath -ExpectedCandidateHash $newHash -Port $port -StartedProcessRegistration $startedProcessRegistration -InProcess
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
            & $switchCpaScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $candidate -SourceConfig $config -ResultPath $resultPath -ExpectedCandidateHash $newHash -Port $port -StartedProcessRegistration $startedProcessRegistration -InProcess | Out-Null
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
        & $shortCandidateScript -ControlRoot $candidateRoot -CandidateRuntime $candidateRuntime -ActiveConfig $candidateConfig -ResultPath $candidateResultPath -ExpectedCandidateHash $candidateHash -Port $candidatePort -StartedProcessRegistration $startedProcessRegistration -InProcess | Out-Null
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
            & $shortSwitchScript -ControlRoot $formalRoot -SourceRuntime $runtime -TargetRuntime $runtime -CandidatePackageRoot $formalCandidate -SourceConfig $config -ResultPath $formalResultPath -ExpectedCandidateHash $formalCandidateHash -Port $formalPort -StartedProcessRegistration $startedProcessRegistration -InProcess | Out-Null
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
            & $switchManagerScript -ControlRoot $root -SourceRuntime $runtime -SourceData $data -TargetRuntime $runtime -TargetData $data -CandidatePackageRoot $candidate -ResultPath $resultPath -ExpectedCandidateHash $newHash -ManagerPort $managerPort -CpaPort $cpaPort -StartedProcessRegistration $startedProcessRegistration -InProcess | Out-Null
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
                -StartedProcessRegistration $startedProcessRegistration `
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
            & $switchManagerScript -ControlRoot $root -SourceRuntime $sourceRuntime -SourceData $sourceData -TargetRuntime $targetRuntime -TargetData $targetData -CandidatePackageRoot $targetRuntime -ResultPath $resultPath -ExpectedCandidateHash $newHash -ManagerPort $managerPort -CpaPort $cpaPort -StartedProcessRegistration $startedProcessRegistration -InProcess | Out-Null
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

function Invoke-TransitionHealthTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedRoot -Name 'transition-health'
    $root = $fixture.Root
    $cpaPort = Get-UnusedLoopbackPort
    $managerPort = Get-UnusedLoopbackPort
    $cpaRuntime = Join-Path $root 'runtime\cli-proxy-api'
    $managerRuntime = Join-Path $root 'runtime\manager-plus'
    $managerData = Join-Path $root 'data\manager-plus'
    $cpaExe = Join-Path $cpaRuntime 'cli-proxy-api.exe'
    $managerExe = Join-Path $managerRuntime 'cpa-manager-plus.exe'
    $currentPath = Join-Path $root 'state\current.json'
    $cpaJournalPath = Join-Path $root 'state\switch-cpa.pending.json'
    $managerJournalPath = Join-Path $root 'state\switch-manager.pending.json'
    New-Item -ItemType Directory -Force -Path $cpaRuntime, (Join-Path $cpaRuntime 'auth'), $managerRuntime, $managerData, (Join-Path $root 'ops') | Out-Null
    Copy-Item -LiteralPath $OldBinary -Destination $cpaExe
    Copy-Item -LiteralPath $OldBinary -Destination $managerExe
    Write-Utf8Text -Path (Join-Path $cpaRuntime 'behavior.txt') -Value 'good'
    Write-Utf8Text -Path (Join-Path $managerRuntime 'behavior.txt') -Value 'good'
    Write-Utf8Text -Path (Join-Path $managerRuntime 'cpa-port.txt') -Value ([string]$cpaPort)
    Write-Utf8Text -Path (Join-Path $managerData 'data.key') -Value 'fixture-data-key'
    Write-Utf8Text -Path (Join-Path $managerData 'collector-state.txt') -Value 'true'
    New-SqliteFixture -Path (Join-Path $managerData 'usage.sqlite')
    Write-CpaConfig -Path (Join-Path $cpaRuntime 'config.yaml') -Port $cpaPort
    Write-StackConfig -Path (Join-Path $root 'config\stack.psd1') -CpaPort $cpaPort -ManagerPort $managerPort
    Copy-Item -LiteralPath $isolatedStartStackScript -Destination (Join-Path $root 'ops\Start-CPA-Stack.ps1')
    [void](Write-TestSecrets -ControlRoot $root -Protect)

    $oldCpaHash = Get-CpaStackFileHash -Path $cpaExe
    $oldManagerHash = Get-CpaStackFileHash -Path $managerExe
    $current = [ordered]@{
        schemaVersion = 1
        instanceId = [string]$fixture.Marker.instanceId
        canonicalRoot = $root
        cpa = [ordered]@{ version = 'fixture-old'; executable = $cpaExe; sha256 = $oldCpaHash }
        manager = [ordered]@{ version = 'fixture-old'; executable = $managerExe; sha256 = $oldManagerHash }
    }
    Write-CpaStackJson -Value $current -Path $currentPath
    foreach ($criticalDirectory in @(
        (Join-Path $root 'config'),
        (Join-Path $root 'ops'),
        (Join-Path $root 'state')
    )) {
        Protect-CpaStackPrivateDirectory -Path $criticalDirectory
    }
    foreach ($criticalPath in @(
        (Join-Path $root '.cpa-stack-instance.json'),
        $currentPath,
        (Join-Path $root 'config\stack.psd1'),
        (Join-Path $root 'ops\Start-CPA-Stack.ps1'),
        (Join-Path $cpaRuntime 'config.yaml'),
        $cpaExe,
        $managerExe
    )) {
        Protect-CpaStackSecretFile -Path $criticalPath
    }
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'runtime')
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'data')

    $invokeState = {
        param([string]$ProbeRoot, [string]$TransitionComponent)
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $stateScript, '-ControlRoot', $ProbeRoot)
        if (-not [string]::IsNullOrWhiteSpace($TransitionComponent)) {
            $arguments += @('-PendingSwitchComponent', $TransitionComponent)
        }
        $output = @(& pwsh.exe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $json = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json
        return [pscustomobject]@{ ExitCode = $exitCode; State = $json }
    }

    try {
        [void](Start-CpaFixture -Executable $cpaExe -Runtime $cpaRuntime -Config (Join-Path $cpaRuntime 'config.yaml') -Port $cpaPort)
        [void](Start-ManagerFixture -Executable $managerExe -Runtime $managerRuntime -Data $managerData -Port $managerPort)
        $steady = & $invokeState $root $null
        $steadyDetails = $steady.State | ConvertTo-Json -Depth 10 -Compress
        Assert-Equal -Expected 0 -Actual $steady.ExitCode -Message "fixture stack should begin healthy. State=[$steadyDetails]"

        Stop-OwnedFixturePort -Port $cpaPort -ManagedRoot $root
        Copy-Item -LiteralPath $NewBinary -Destination $cpaExe -Force
        Protect-CpaStackSecretFile -Path $cpaExe
        $newCpaHash = Get-CpaStackFileHash -Path $cpaExe
        [void](Start-CpaFixture -Executable $cpaExe -Runtime $cpaRuntime -Config (Join-Path $cpaRuntime 'config.yaml') -Port $cpaPort)
        Write-CpaStackJson -Value ([ordered]@{
            operation = 'switch-cpa'
            operationId = [guid]::NewGuid().ToString('N')
            instanceId = [string]$fixture.Marker.instanceId
            phase = 'runtime-verified'
            targetRuntime = $cpaRuntime
            oldHash = $oldCpaHash
            newHash = $newCpaHash
        }) -Path $cpaJournalPath
        Protect-CpaStackSecretFile -Path $cpaJournalPath

        $steadyDuringCpa = & $invokeState $root $null
        Assert-False -Condition ([bool]$steadyDuringCpa.State.Security.Integrity.Ready) -Message 'steady status should reject a pre-commit CPA hash'
        $cpaTransition = & $invokeState $root 'cpa'
        Assert-True -Condition ([bool]$cpaTransition.State.Security.Integrity.Ready) -Message 'CPA transition should accept the journal-bound new hash'
        Assert-True -Condition ([bool]$cpaTransition.State.Cpa.Healthy -and [bool]$cpaTransition.State.Manager.Healthy) -Message 'CPA transition should probe both formal services before current commits'

        $current.cpa.sha256 = $newCpaHash
        $current.cpa.version = 'fixture-new'
        Write-CpaStackJson -Value $current -Path $currentPath
        Protect-CpaStackSecretFile -Path $currentPath
        Remove-Item -LiteralPath $cpaJournalPath -Force

        Stop-OwnedFixturePort -Port $managerPort -ManagedRoot $root
        Copy-Item -LiteralPath $NewBinary -Destination $managerExe -Force
        Protect-CpaStackSecretFile -Path $managerExe
        $newManagerHash = Get-CpaStackFileHash -Path $managerExe
        [void](Start-ManagerFixture -Executable $managerExe -Runtime $managerRuntime -Data $managerData -Port $managerPort)
        Write-CpaStackJson -Value ([ordered]@{
            operation = 'switch-manager'
            operationId = [guid]::NewGuid().ToString('N')
            instanceId = [string]$fixture.Marker.instanceId
            phase = 'runtime-verified'
            targetRuntime = $managerRuntime
            targetData = $managerData
            oldHash = $oldManagerHash
            newHash = $newManagerHash
        }) -Path $managerJournalPath
        Protect-CpaStackSecretFile -Path $managerJournalPath

        $steadyDuringManager = & $invokeState $root $null
        Assert-False -Condition ([bool]$steadyDuringManager.State.Security.Integrity.Ready) -Message 'steady status should reject a pre-commit Manager hash'
        $managerTransition = & $invokeState $root 'manager'
        Assert-True -Condition ([bool]$managerTransition.State.Security.Integrity.Ready) -Message 'Manager transition should accept the journal-bound new hash'
        Assert-True -Condition ([bool]$managerTransition.State.Cpa.Healthy -and [bool]$managerTransition.State.Manager.Healthy) -Message 'Manager transition should probe both formal services before current commits'
    } finally {
        Stop-OwnedFixturePort -Port $cpaPort -ManagedRoot $root
        Stop-OwnedFixturePort -Port $managerPort -ManagedRoot $root
    }
}

function Invoke-RecoveryJournalValidationGuardTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedStackFixture -Binary $OldBinary -Name 'recovery-journal-guard'
    $root = $fixture.Root
    $cpaRuntime = Join-Path $root 'runtime\cli-proxy-api'
    $managerRuntime = Join-Path $root 'runtime\manager-plus'
    $managerData = Join-Path $root 'data\manager-plus'
    $cpaExe = Join-Path $cpaRuntime 'cli-proxy-api.exe'
    $managerExe = Join-Path $managerRuntime 'cpa-manager-plus.exe'
    $currentPath = Join-Path $root 'state\current.json'
    $upgradeResultPath = Join-Path $root 'state\last-upgrade.json'
    $current = Read-CpaStackJson -Path $currentPath
    $poisonRoot = Join-Path $testRunRoot ('recovery-poison-' + [guid]::NewGuid().ToString('N'))
    $poisonRuntime = Join-Path $poisonRoot 'runtime'
    $poisonData = Join-Path $poisonRoot 'data'
    $poisonConfig = Join-Path $poisonRoot 'config.yaml'
    New-Item -ItemType Directory -Force -Path $poisonRuntime, $poisonData | Out-Null
    Write-Utf8Text -Path $poisonConfig -Value 'poison-canary'
    Write-Utf8Text -Path (Join-Path $poisonRuntime 'canary.txt') -Value 'runtime-canary'
    Write-Utf8Text -Path (Join-Path $poisonData 'canary.txt') -Value 'data-canary'
    $aclSections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
        [System.Security.AccessControl.AccessControlSections]::Group -bor
        [System.Security.AccessControl.AccessControlSections]::Access

    $protectedFiles = @(
        (Join-Path $root '.cpa-stack-instance.json'),
        $currentPath,
        $fixture.StackConfig,
        $fixture.CpaConfig,
        $cpaExe,
        $managerExe,
        (Join-Path $managerData 'data.key'),
        $poisonConfig,
        (Join-Path $poisonRuntime 'canary.txt'),
        (Join-Path $poisonData 'canary.txt')
    )
    $captureFiles = {
        $snapshot = [ordered]@{}
        foreach ($path in $protectedFiles) {
            $acl = Get-CpaStackFileSystemAcl -Path $path
            $snapshot[$path] = [pscustomobject]@{
                Hash = Get-CpaStackFileHash -Path $path
                Owner = Get-CpaStackAclOwnerSid -Acl $acl
                Sddl = $acl.GetSecurityDescriptorSddlForm($aclSections)
            }
        }
        return $snapshot
    }
    $assertFilesUnchanged = {
        param($Before, [string]$Scenario)
        foreach ($path in $protectedFiles) {
            $afterAcl = Get-CpaStackFileSystemAcl -Path $path
            Assert-Equal ([string]$Before[$path].Hash) (Get-CpaStackFileHash -Path $path) "$Scenario preserves bytes for $path"
            Assert-Equal ([string]$Before[$path].Owner) (Get-CpaStackAclOwnerSid -Acl $afterAcl) "$Scenario preserves owner for $path"
            Assert-Equal ([string]$Before[$path].Sddl) ($afterAcl.GetSecurityDescriptorSddlForm($aclSections)) "$Scenario preserves DACL for $path"
        }
    }
    $assertProcessesUnchanged = {
        param($BeforeCpa, $BeforeManager, [string]$Scenario)
        $afterCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $afterManager = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-True ($null -ne $afterCpa) "$Scenario leaves the isolated CPA listening"
        Assert-True ($null -ne $afterManager) "$Scenario leaves the isolated Manager listening"
        Assert-Equal ([int]$BeforeCpa.ProcessId) ([int]$afterCpa.ProcessId) "$Scenario does not restart or stop the isolated CPA"
        Assert-Equal ([int]$BeforeManager.ProcessId) ([int]$afterManager.ProcessId) "$Scenario does not restart or stop the isolated Manager"
        Assert-Equal ([string]$BeforeCpa.ExecutablePath) ([string]$afterCpa.ExecutablePath) "$Scenario preserves the isolated CPA listener owner"
        Assert-Equal ([string]$BeforeManager.ExecutablePath) ([string]$afterManager.ExecutablePath) "$Scenario preserves the isolated Manager listener owner"
    }

    try {
        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $cpaJournalPath = Join-Path $root 'state\switch-cpa.pending.json'
        Write-CpaStackJson -Value ([ordered]@{
            operation = 'switch-cpa'
            operationId = [guid]::NewGuid().ToString('N')
            instanceId = [string]$current.instanceId
            phase = 'source-stopped'
            sourceRuntime = $cpaRuntime
            targetRuntime = $cpaRuntime
            sourceConfig = $poisonConfig
            port = $fixture.CpaPort
            pendingPath = $null
            oldHash = [string]$current.cpa.sha256
            newHash = 'B' * 64
            targetProcessId = $null
        }) -Path $cpaJournalPath
        $cpaJournalHash = Get-CpaStackFileHash -Path $cpaJournalPath

        $cpaRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-True ($cpaRecovery.ExitCode -ne 0) 'Path-poisoned CPA recovery returns a nonzero exit code'
        Assert-False ([bool]$cpaRecovery.Result.success) 'Path-poisoned CPA recovery reports failure'
        Assert-Equal 'ManualRecoveryRequired' ([string]$cpaRecovery.Result.outcome) "Path-poisoned CPA recovery requires manual recovery. Output=[$($cpaRecovery.Output)] Error=[$($cpaRecovery.ErrorOutput)]"
        Assert-True (Test-Path -LiteralPath $cpaJournalPath -PathType Leaf) 'Path-poisoned CPA journal is retained for diagnosis'
        Assert-Equal $cpaJournalHash (Get-CpaStackFileHash -Path $cpaJournalPath) 'Path-poisoned CPA journal is not rewritten'
        Assert-False (Test-Path -LiteralPath $upgradeResultPath) 'Path-poisoned CPA recovery does not persist a canonical result file before validation'
        & $assertProcessesUnchanged $beforeCpa $beforeManager 'Path-poisoned CPA journal'
        & $assertFilesUnchanged $beforeFiles 'Path-poisoned CPA journal'
        Remove-Item -LiteralPath $cpaJournalPath -Force

        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $previousPath = $cpaJournalPath + '.previous'
        if (Test-Path -LiteralPath $previousPath) { Remove-Item -LiteralPath $previousPath -Force }
        $previousOperationId = [guid]::NewGuid().ToString('N')
        $previousPending = Join-Path $root ('rollback\pending-cpa-' + $previousOperationId)
        $validPreparedJournal = [ordered]@{
            schemaVersion = 1
            operation = 'switch-cpa'
            operationId = $previousOperationId
            parentOperationId = $null
            instanceId = [string]$current.instanceId
            phase = 'prepared'
            createdAt = [DateTimeOffset]::Now.ToString('o')
            sourceRuntime = $cpaRuntime
            targetRuntime = $cpaRuntime
            sourceConfig = $fixture.CpaConfig
            port = $fixture.CpaPort
            pendingPath = $previousPending
            oldHash = [string]$current.cpa.sha256
            newHash = 'B' * 64
            targetRuntimeManifestSha256 = $null
            targetConfigSha256 = $null
            targetHost = $null
            targetProcessId = $null
        }
        Write-CpaStackJson -Value $validPreparedJournal -Path $cpaJournalPath
        $foreignPrevious = $validPreparedJournal | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $foreignPrevious.operationId = [guid]::NewGuid().ToString('N')
        Write-Utf8Text -Path $previousPath -Value ($foreignPrevious | ConvertTo-Json -Depth 8)
        Protect-CpaStackSecretFile -Path $previousPath
        $preparedJournalHash = Get-CpaStackFileHash -Path $cpaJournalPath
        $foreignPreviousHash = Get-CpaStackFileHash -Path $previousPath

        $foreignPreviousRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-True ($foreignPreviousRecovery.ExitCode -ne 0) 'Foreign switch previous journal returns a nonzero exit code'
        Assert-Equal 'ManualRecoveryRequired' ([string]$foreignPreviousRecovery.Result.outcome) "Foreign switch previous journal requires manual recovery. Output=[$($foreignPreviousRecovery.Output)] Error=[$($foreignPreviousRecovery.ErrorOutput)]"
        Assert-Equal $preparedJournalHash (Get-CpaStackFileHash -Path $cpaJournalPath) 'Foreign previous validation preserves the current switch journal'
        Assert-Equal $foreignPreviousHash (Get-CpaStackFileHash -Path $previousPath) 'Foreign previous validation preserves the previous evidence'
        Assert-False (Test-Path -LiteralPath $upgradeResultPath) 'Foreign previous validation does not persist a canonical result'
        & $assertProcessesUnchanged $beforeCpa $beforeManager 'Foreign switch previous journal'
        & $assertFilesUnchanged $beforeFiles 'Foreign switch previous journal'
        Remove-Item -LiteralPath $cpaJournalPath, $previousPath -Force

        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $phaseOperationId = [guid]::NewGuid().ToString('N')
        $invalidPhaseJournal = [ordered]@{}
        foreach ($key in $validPreparedJournal.Keys) { $invalidPhaseJournal[$key] = $validPreparedJournal[$key] }
        $invalidPhaseJournal.operationId = $phaseOperationId
        $invalidPhaseJournal.phase = 'target-started'
        $invalidPhaseJournal.pendingPath = Join-Path $root ('rollback\pending-cpa-' + $phaseOperationId)
        $invalidPhaseJournal.targetProcessId = [int]$beforeCpa.ProcessId
        Write-CpaStackJson -Value $invalidPhaseJournal -Path $cpaJournalPath
        if (Test-Path -LiteralPath $previousPath) { Remove-Item -LiteralPath $previousPath -Force }
        $invalidPhaseHash = Get-CpaStackFileHash -Path $cpaJournalPath

        $invalidPhaseRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-True ($invalidPhaseRecovery.ExitCode -ne 0) 'Target-started journal with active old runtime returns a nonzero exit code'
        Assert-Equal 'ManualRecoveryRequired' ([string]$invalidPhaseRecovery.Result.outcome) "Phase-inconsistent switch journal requires manual recovery. Output=[$($invalidPhaseRecovery.Output)] Error=[$($invalidPhaseRecovery.ErrorOutput)]"
        Assert-Equal $invalidPhaseHash (Get-CpaStackFileHash -Path $cpaJournalPath) 'Phase-inconsistent recovery preserves the journal'
        Assert-False (Test-Path -LiteralPath $upgradeResultPath) 'Phase-inconsistent recovery does not persist a canonical result'
        & $assertProcessesUnchanged $beforeCpa $beforeManager 'Phase-inconsistent switch journal'
        & $assertFilesUnchanged $beforeFiles 'Phase-inconsistent switch journal'
        Remove-Item -LiteralPath $cpaJournalPath -Force

        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $managerJournalPath = Join-Path $root 'state\switch-manager.pending.json'
        Write-CpaStackJson -Value ([ordered]@{
            operation = 'switch-manager'
            operationId = [guid]::NewGuid().ToString('N')
            instanceId = [guid]::NewGuid().ToString('N')
            phase = 'source-stopped'
            sourceRuntime = $poisonRuntime
            sourceData = $poisonData
            targetRuntime = $poisonRuntime
            targetData = $poisonData
            managerPort = $fixture.ManagerPort
            cpaPort = $fixture.CpaPort
            pendingPath = $null
            oldHash = [string]$current.manager.sha256
            newHash = 'C' * 64
            managerBaseline = [ordered]@{
                cpaBaseUrl = "http://127.0.0.1:$($fixture.CpaPort)"
                collectorEnabled = $true
                pollIntervalMs = 1000
                usageStatisticsEnabled = $true
            }
            targetProcessId = $null
        }) -Path $managerJournalPath
        $managerJournalHash = Get-CpaStackFileHash -Path $managerJournalPath

        $managerRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-True ($managerRecovery.ExitCode -ne 0) 'Foreign Manager recovery returns a nonzero exit code'
        Assert-False ([bool]$managerRecovery.Result.success) 'Foreign Manager recovery reports failure'
        Assert-Equal 'ManualRecoveryRequired' ([string]$managerRecovery.Result.outcome) "Foreign Manager recovery requires manual recovery. Output=[$($managerRecovery.Output)] Error=[$($managerRecovery.ErrorOutput)]"
        Assert-True (Test-Path -LiteralPath $managerJournalPath -PathType Leaf) 'Foreign Manager journal is retained for diagnosis'
        Assert-Equal $managerJournalHash (Get-CpaStackFileHash -Path $managerJournalPath) 'Foreign Manager journal is not rewritten'
        Assert-False (Test-Path -LiteralPath $upgradeResultPath) 'Foreign Manager recovery does not persist a canonical result file before validation'
        & $assertProcessesUnchanged $beforeCpa $beforeManager 'Foreign Manager journal'
        & $assertFilesUnchanged $beforeFiles 'Foreign Manager journal'
        Remove-Item -LiteralPath $managerJournalPath -Force

        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $orphanPath = Join-Path $root ('rollback\pending-cpa-' + [guid]::NewGuid().ToString('N'))
        $orphanCanary = Join-Path $orphanPath 'canary.txt'
        New-Item -ItemType Directory -Force -Path $orphanPath | Out-Null
        Write-Utf8Text -Path $orphanCanary -Value 'orphan-evidence'
        $orphanHash = Get-CpaStackFileHash -Path $orphanCanary
        $orphanAcl = Get-CpaStackFileSystemAcl -Path $orphanCanary
        $orphanSddl = $orphanAcl.GetSecurityDescriptorSddlForm($aclSections)

        $orphanRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-True ($orphanRecovery.ExitCode -ne 0) 'Unreferenced rollback artifact returns a nonzero exit code'
        Assert-False ([bool]$orphanRecovery.Result.success) 'Unreferenced rollback artifact reports failure'
        Assert-Equal 'ManualRecoveryRequired' ([string]$orphanRecovery.Result.outcome) "Unreferenced rollback artifact requires manual recovery. Output=[$($orphanRecovery.Output)] Error=[$($orphanRecovery.ErrorOutput)]"
        Assert-True (Test-Path -LiteralPath $orphanPath -PathType Container) 'Unreferenced rollback artifact remains in its original slot'
        Assert-Equal $orphanHash (Get-CpaStackFileHash -Path $orphanCanary) 'Unreferenced rollback evidence bytes are unchanged'
        Assert-False (Test-Path -LiteralPath $upgradeResultPath) 'Unreferenced rollback recovery does not persist a canonical result file before validation'
        $afterOrphanAcl = Get-CpaStackFileSystemAcl -Path $orphanCanary
        Assert-Equal (Get-CpaStackAclOwnerSid -Acl $orphanAcl) (Get-CpaStackAclOwnerSid -Acl $afterOrphanAcl) 'Unreferenced rollback evidence owner is unchanged'
        Assert-Equal $orphanSddl ($afterOrphanAcl.GetSecurityDescriptorSddlForm($aclSections)) 'Unreferenced rollback evidence DACL is unchanged'
        & $assertProcessesUnchanged $beforeCpa $beforeManager 'Unreferenced rollback artifact'
        & $assertFilesUnchanged $beforeFiles 'Unreferenced rollback artifact'
        Remove-TestPathWithRetry -Path $orphanPath

        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $preparedOperationId = [guid]::NewGuid().ToString('N')
        $preparedPendingPath = Join-Path $root ('rollback\pending-cpa-' + $preparedOperationId)
        $preparedJournalPath = Join-Path $root 'state\switch-cpa.pending.json'
        Write-CpaStackJson -Value ([ordered]@{
            operation = 'switch-cpa'
            operationId = $preparedOperationId
            instanceId = [string]$current.instanceId
            phase = 'prepared'
            sourceRuntime = $cpaRuntime
            targetRuntime = $cpaRuntime
            sourceConfig = $fixture.CpaConfig
            port = $fixture.CpaPort
            pendingPath = $preparedPendingPath
            oldHash = [string]$current.cpa.sha256
            newHash = 'D' * 64
            targetProcessId = $null
        }) -Path $preparedJournalPath
        Assert-False (Test-Path -LiteralPath $preparedPendingPath) 'Prepared-journal fixture models interruption before the snapshot move'

        $preparedRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-Equal 0 $preparedRecovery.ExitCode "Canonical prepared recovery succeeds before pending snapshot move. Output=[$($preparedRecovery.Output)] Error=[$($preparedRecovery.ErrorOutput)]"
        Assert-True ([bool]$preparedRecovery.Result.success) 'Canonical prepared recovery reports success'
        Assert-Equal 'Changed' ([string]$preparedRecovery.Result.outcome) 'Canonical prepared recovery reports a recovered change'
        Assert-Equal 'upgrade' ([string]$preparedRecovery.Result.recoveryKind) 'Canonical prepared recovery remains owned by upgrade recovery'
        Assert-True (Test-Path -LiteralPath $upgradeResultPath -PathType Leaf) 'Validated canonical recovery may persist its result'
        Assert-False (Test-Path -LiteralPath $preparedJournalPath) 'Canonical prepared recovery clears its validated journal'
        Assert-False (Test-Path -LiteralPath $preparedPendingPath) 'Canonical prepared recovery does not invent a missing snapshot'
        $afterPreparedCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $afterPreparedManager = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-True ($null -ne $afterPreparedCpa) 'Canonical prepared recovery restarts the isolated CPA'
        Assert-True ($null -ne $afterPreparedManager) 'Canonical prepared recovery leaves the isolated Manager healthy'
        Assert-Equal ([int]$beforeCpa.ProcessId) ([int]$afterPreparedCpa.ProcessId) 'Prepared recovery does not restart a healthy unchanged CPA'
        Assert-Equal ([int]$beforeManager.ProcessId) ([int]$afterPreparedManager.ProcessId) 'Canonical prepared recovery preserves the healthy Manager process'
        & $assertFilesUnchanged $beforeFiles 'Canonical prepared recovery without a moved snapshot'

        $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
        $beforeFiles = & $captureFiles
        $deferredCandidate = Join-Path $root ('work\deferred-recovery-candidate-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $deferredCandidate | Out-Null
        Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $deferredCandidate 'cli-proxy-api.exe')
        Write-Utf8Text -Path (Join-Path $deferredCandidate 'behavior.txt') -Value 'good-new'
        $newHash = Get-CpaStackFileHash -Path (Join-Path $deferredCandidate 'cli-proxy-api.exe')
        $deferredResultPath = Join-Path $root 'state\deferred-cpa-switch.json'
        $deferredJson = & $switchCpaScript `
            -ControlRoot $root `
            -SourceRuntime $cpaRuntime `
            -TargetRuntime $cpaRuntime `
            -CandidatePackageRoot $deferredCandidate `
            -SourceConfig $fixture.CpaConfig `
            -ResultPath $deferredResultPath `
            -ExpectedCandidateHash $newHash `
            -Port $fixture.CpaPort `
            -DeferFinalCommit `
            -StartedProcessRegistration $startedProcessRegistration `
            -InProcess
        $deferredResult = ($deferredJson | Select-Object -Last 1) | ConvertFrom-Json
        Assert-True ([bool]$deferredResult.success -and [bool]$deferredResult.commitDeferred) 'Deferred CPA switch leaves a recoverable verified transaction'
        $deferredJournal = Read-CpaStackJson -Path $preparedJournalPath
        $deferredPrevious = Read-CpaStackJson -Path ($preparedJournalPath + '.previous')
        Assert-Equal 'runtime-verified' ([string]$deferredJournal.phase) 'Deferred current journal reaches runtime-verified'
        Assert-Equal 'target-started' ([string]$deferredPrevious.phase) 'Deferred previous journal is the legal adjacent target-started phase'
        Assert-True (Test-Path -LiteralPath ([string]$deferredJournal.pendingPath) -PathType Container) 'Deferred switch retains its rollback backup before recovery'
        Assert-Equal $newHash (Get-CpaStackFileHash -Path $cpaExe) 'Deferred switch activates the new runtime before current state commits'

        $deferredRecovery = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-Equal 0 $deferredRecovery.ExitCode "Deferred switch recovery succeeds. Output=[$($deferredRecovery.Output)] Error=[$($deferredRecovery.ErrorOutput)]"
        Assert-True ([bool]$deferredRecovery.Result.success) 'Deferred switch recovery reports success'
        Assert-Equal ([string]$current.cpa.sha256) (Get-CpaStackFileHash -Path $cpaExe) 'Deferred switch recovery restores the recorded old runtime'
        Assert-False (Test-Path -LiteralPath $preparedJournalPath) 'Deferred recovery removes its validated current journal'
        Assert-False (Test-Path -LiteralPath ($preparedJournalPath + '.previous')) 'Deferred recovery removes only its validated previous journal'
        Assert-Equal ([string]$current.cpa.sha256) (Get-CpaStackFileHash -Path (Join-Path $root 'rollback\last-known-good\cpa\runtime\cli-proxy-api.exe')) 'Deferred recovery commits the validated old backup to last-known-good'
        $afterDeferredCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $afterDeferredManager = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-True ($null -ne $afterDeferredCpa -and $null -ne $afterDeferredManager) 'Deferred recovery leaves both isolated services healthy'
        Assert-Equal ([int]$beforeManager.ProcessId) ([int]$afterDeferredManager.ProcessId) 'Deferred CPA recovery preserves the healthy Manager process'
        & $assertFilesUnchanged $beforeFiles 'Deferred verified CPA recovery'
        Remove-TestPathWithRetry -Path $deferredCandidate
    } finally {
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $root
        if (Test-Path -LiteralPath $poisonRoot) { Remove-TestPathWithRetry -Path $poisonRoot }
    }
}

function Invoke-InterruptedCpaRollbackTest {
    param([string]$OldBinary, [string]$NewBinary)

    $fixture = New-ManagedStackFixture -Binary $OldBinary -Name 'interrupted-cpa-rollback'
    $root = $fixture.Root
    $runtime = Join-Path $root 'runtime\cli-proxy-api'
    $exe = Join-Path $runtime 'cli-proxy-api.exe'
    $journalPath = Join-Path $root 'state\switch-cpa.pending.json'
    $candidate = Join-Path $root 'work\rollback-test-candidate'
    $oldHash = Get-CpaStackFileHash -Path $exe
    $managerBefore = Get-CpaStackListener -Port $fixture.ManagerPort
    try {
        New-Item -ItemType Directory -Path $candidate | Out-Null
        Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidate 'cli-proxy-api.exe')
        Write-Utf8Text -Path (Join-Path $candidate 'behavior.txt') -Value 'good-new'
        $output = & $switchCpaScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime `
            -CandidatePackageRoot $candidate -SourceConfig $fixture.CpaConfig `
            -ResultPath (Join-Path $root 'state\rollback-test-switch.json') `
            -ExpectedCandidateHash (Get-CpaStackFileHash -Path (Join-Path $candidate 'cli-proxy-api.exe')) `
            -Port $fixture.CpaPort -DeferFinalCommit -StartedProcessRegistration $startedProcessRegistration -InProcess
        $switched = ($output | Select-Object -Last 1) | ConvertFrom-Json
        Assert-True $switched.success 'Fixture reaches a real deferred switch'
        $journal = Read-CpaStackJson -Path $journalPath
        $backupExe = Join-Path $journal.pendingPath 'runtime\cli-proxy-api.exe'
        $journalHash = Get-CpaStackFileHash -Path $journalPath

        # Model a crash halfway through restoring runtime files: old exe, new companion file.
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $root
        Copy-Item -LiteralPath $backupExe -Destination $exe -Force
        Protect-CpaStackSecretFile -Path $exe
        [void](Start-CpaFixture -Executable $exe -Runtime $runtime -Config $fixture.CpaConfig -Port $fixture.CpaPort)
        Assert-Equal $oldHash (Get-CpaStackFileHash -Path $exe) 'Old executable is already restored'
        Assert-Equal 'good-new' ([System.IO.File]::ReadAllText((Join-Path $runtime 'behavior.txt'))) 'Other runtime files are not restored yet'
        $beforeFailure = Get-CpaStackListener -Port $fixture.CpaPort

        [System.IO.File]::AppendAllText($backupExe, 'corrupt-backup')
        $rejected = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-False ([bool]$rejected.Result.success) 'Old active executable does not bypass backup validation'
        Assert-Equal 'ManualRecoveryRequired' $rejected.Result.outcome 'Invalid backup remains a manual recovery failure'
        Assert-Equal $journalHash (Get-CpaStackFileHash -Path $journalPath) 'Rejected recovery preserves the journal'
        Assert-Equal $beforeFailure.ProcessId (Get-CpaStackListener -Port $fixture.CpaPort).ProcessId 'Rejected recovery does not stop the service'
        Copy-Item -LiteralPath $OldBinary -Destination $backupExe -Force
        Protect-CpaStackSecretFile -Path $backupExe

        $recovered = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-Equal 0 $recovered.ExitCode "Interrupted CPA rollback resumes. Output=[$($recovered.Output)] Error=[$($recovered.ErrorOutput)]"
        Assert-True ([bool]$recovered.Result.success -and [bool]$recovered.Result.recovered) 'Recovery is verified before reporting success'
        Assert-Equal $oldHash (Get-CpaStackFileHash -Path $exe) 'Recorded old CPA is retained'
        Assert-Equal 'good' ([System.IO.File]::ReadAllText((Join-Path $runtime 'behavior.txt'))) 'Recovery recopies all validated runtime files'
        Assert-False (Test-Path -LiteralPath $journalPath) 'Completed recovery removes the validated transaction'
        Assert-False (Test-Path -LiteralPath ($journalPath + '.previous')) 'Completed recovery removes its prior generation'
        Assert-Equal $managerBefore.ProcessId (Get-CpaStackListener -Port $fixture.ManagerPort).ProcessId 'Manager remains running throughout CPA recovery'
        Assert-Equal $oldHash (Get-CpaStackFileHash -Path (Join-Path $root 'rollback\last-known-good\cpa\runtime\cli-proxy-api.exe')) 'Verified backup is retained'
        $again = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
        Assert-Equal 'NoChange' $again.Result.outcome 'A second recover is idempotent'
    } finally {
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $root
    }
}

function Invoke-CpaAvailabilityTest {
    param([string]$OldBinary, [string]$NewBinary)

    foreach ($mode in @('commit-new', 'restored-old', 'missing-exe')) {
        $fixture = New-ManagedStackFixture -Binary $OldBinary -Name ("availability-$mode")
        $root = $fixture.Root
        $runtime = Join-Path $root 'runtime\cli-proxy-api'
        $exe = Join-Path $runtime 'cli-proxy-api.exe'
        $commonPath = Join-Path (Split-Path -Parent $isolatedStackEntry) 'CpaStack.Common.ps1'
        $originalCommon = [System.IO.File]::ReadAllText($commonPath)
        try {
            if ($mode -ne 'missing-exe') {
                # Deterministic outage guard: a whole auth walk must never run after
                # stopping a previously healthy CPA, regardless of machine speed/tree size.
                $guard = @'
if ([System.IO.Path]::GetFullPath($Root).TrimEnd('\') -ieq '__AUTH__' -and -not (Get-CpaStackListener -Port __PORT__)) {
    throw 'Bulk auth traversal entered the CPA outage window.'
}
'@
                $guard = $guard.Replace('__AUTH__', (Join-Path $runtime 'auth').Replace("'", "''")).Replace('__PORT__', [string]$fixture.CpaPort)
                $needle = '$items = @(Get-CpaStackTreeItemsNoReparse -Root $Root)'
                Assert-True ($originalCommon.Contains($needle)) 'Availability fixture intercepts full-tree protection'
                $guardedCommon = $originalCommon.Replace($needle, ($guard + "`n" + $needle))
                $needle = '$items = if ($RootOnly)'
                Assert-True ($originalCommon.Contains($needle)) 'Availability fixture intercepts full-tree validation'
                $guardedCommon = $guardedCommon.Replace($needle, ('if (-not $RootOnly) { ' + $guard + "`n}`n" + $needle))
                [System.IO.File]::WriteAllText($commonPath, $guardedCommon, [System.Text.UTF8Encoding]::new($false))
            }
            $candidate = Join-Path $root 'work\availability-candidate'
            New-Item -ItemType Directory -Path $candidate | Out-Null
            Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $candidate 'cli-proxy-api.exe')
            Write-Utf8Text -Path (Join-Path $candidate 'behavior.txt') -Value 'good-new'
            $currentPath = Join-Path $root 'state\current.json'
            $current = Read-CpaStackJson -Path $currentPath
            $oldHash = [string]$current.cpa.sha256
            $newHash = Get-CpaStackFileHash -Path (Join-Path $candidate 'cli-proxy-api.exe')
            $switchScript = Join-Path (Split-Path -Parent $isolatedStackEntry) 'Switch-CpaRuntime.ps1'
            $output = & $switchScript -ControlRoot $root -SourceRuntime $runtime -TargetRuntime $runtime `
                -CandidatePackageRoot $candidate -SourceConfig $fixture.CpaConfig -ResultPath (Join-Path $root 'state\availability-switch.json') `
                -ExpectedCandidateHash $newHash -Port $fixture.CpaPort -DeferFinalCommit `
                -StartedProcessRegistration $startedProcessRegistration -InProcess
            Assert-True (($output | Select-Object -Last 1 | ConvertFrom-Json).success) 'A real switch succeeds without offline whole-auth work'
            $journalPath = Join-Path $root 'state\switch-cpa.pending.json'
            $journal = Read-CpaStackJson -Path $journalPath
            if ($mode -eq 'commit-new') {
                $current.cpa.sha256 = $newHash
                Write-CpaStackJson -Value $current -Path $currentPath
            } else {
                Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $root
                if ($mode -eq 'restored-old') {
                    Copy-CpaStackTree -Source (Join-Path $journal.pendingPath 'runtime') -Destination $runtime
                    [void](Start-CpaFixture -Executable $exe -Runtime $runtime -Config $fixture.CpaConfig -Port $fixture.CpaPort)
                } else {
                    $journal.phase = 'rolling-back'
                    Write-CpaStackJson -Value $journal -Path $journalPath
                    Remove-Item -LiteralPath $exe -Force
                }
            }
            $beforeCpa = Get-CpaStackListener -Port $fixture.CpaPort
            $beforeManager = Get-CpaStackListener -Port $fixture.ManagerPort
            $recovered = Invoke-IsolatedRecoveryCommand -ControlRoot $root -Command recover
            Assert-Equal 0 $recovered.ExitCode "$mode recovery succeeds. Output=[$($recovered.Output)] Error=[$($recovered.ErrorOutput)]"
            $afterCpa = Get-CpaStackListener -Port $fixture.CpaPort
            Assert-True ($null -ne $afterCpa) "$mode leaves CPA listening"
            if ($mode -ne 'missing-exe') { Assert-Equal $beforeCpa.ProcessId $afterCpa.ProcessId "$mode must not restart a healthy CPA" }
            Assert-Equal $beforeManager.ProcessId (Get-CpaStackListener -Port $fixture.ManagerPort).ProcessId "$mode must not restart Manager"
            Assert-Equal $(if ($mode -eq 'commit-new') { $newHash } else { $oldHash }) (Get-CpaStackFileHash -Path $exe) "$mode selects the bound executable"
            Assert-False (Test-Path -LiteralPath $journalPath) "$mode completes the validated transaction"
            Assert-True (Test-Path -LiteralPath (Join-Path $root 'state\last-upgrade.json')) 'Recovery leaves structured progress/results'
        } finally {
            [System.IO.File]::WriteAllText($commonPath, $originalCommon, [System.Text.UTF8Encoding]::new($false))
            Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $root
            Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $root
        }
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
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'runtime')
    Protect-CpaStackPrivateTree -Root (Join-Path $root 'data')

    $failure = $null
    try {
        & $isolatedStartStackScript -ConfigPath (Join-Path $root 'config\stack.psd1') -SecretsPath (Join-Path $root 'config\secrets.local.json') -NoBrowser -StartedProcessRegistration $startedProcessRegistration -InProcess | Out-Null
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True -Condition ($failure -match 'interrupted CPA stack transaction') -Message "standalone startup should refuse a pending transaction journal. Failure=[$failure]"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $isolatedLocalAppData 'CPAStack\locks\CPAStackSafeOperation.lock') -PathType Leaf) -Message 'pending journal startup gate should use the isolated operation lock'
    Assert-True -Condition ($null -eq (Get-CpaStackListener -Port $cpaPort)) -Message 'pending journal gate should not start CPA'
    Assert-True -Condition ($null -eq (Get-CpaStackListener -Port $managerPort)) -Message 'pending journal gate should not start Manager'
}

try {
    $listenerSnapshot = @(Get-CpaStackListenerSnapshot)
    $productionStateHome = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack'
    $productionRegistration = Get-CpaStackProductionRegistration -ProductionStateHome $productionStateHome
    $productionRoots = @($productionRegistration.Roots)
    $productionGuard = New-CpaStackProductionGuard `
        -ProductionRoot $productionRoots `
        -ProductionStateHome @($productionStateHome) `
        -ProductionPort @($productionRegistration.ProtectedPorts) `
        -ListenerSnapshot $listenerSnapshot
    [void](Assert-CpaStackTestIsolation `
        -Guard $productionGuard `
        -TestRoot $testRunRoot `
        -TestStateHome (Join-Path $testRunRoot 'local-app-data'))
    $startedProcessRegistration = {
        param([System.Diagnostics.Process]$Process)
        [void](Register-CpaStackTestProcess -Guard $productionGuard -Process $Process)
    }.GetNewClosure()

    New-Item -ItemType Directory -Force -Path $testRunRoot | Out-Null
    $transactionFixture = New-CpaStackUpdaterTestFixture `
        -SourceRepository $repo `
        -DestinationRepository (Join-Path $testRunRoot 'repository') `
        -LocalAppDataRoot (Join-Path $testRunRoot 'local-app-data')
    $isolatedStartStackScript = Join-Path $transactionFixture.Repository 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'
    $isolatedStackEntry = Join-Path $transactionFixture.Repository 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
    $isolatedLocalAppData = $transactionFixture.LocalAppData
    New-Item -ItemType Directory -Force -Path $compileRoot | Out-Null
    $oldBinary = Join-Path $compileRoot 'fixture-old.exe'
    $newBinary = Join-Path $compileRoot 'fixture-new.exe'
    Compile-StubExecutable -BuildId 'fixture-old' -OutputPath $oldBinary
    Compile-StubExecutable -BuildId 'fixture-new' -OutputPath $newBinary
    Assert-False -Condition ((Get-CpaStackFileHash -Path $oldBinary) -eq (Get-CpaStackFileHash -Path $newBinary)) -Message 'fixture builds must have distinct executable hashes'

    if ($Case -in @('All', 'Core', 'CpaSuccess')) {
        Invoke-CpaSwitchSuccessTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'CpaRollback')) {
        Invoke-CpaSwitchRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'CpaHangCleanup')) {
        Invoke-CpaHangBeforeListenCleanupTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'ManagerRollback')) {
        Invoke-ManagerSwitchRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'ManagerMigrationRollback')) {
        Invoke-ManagerMigrationRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'ManagerMigrationTamper')) {
        Invoke-ManagerMigrationTamperGateTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'ManagerRecoveryGate')) {
        Invoke-ManagerRecoverySourceGateTest -OldBinary $oldBinary
    }
    if ($Case -in @('All', 'Core', 'TransitionHealth')) {
        Invoke-TransitionHealthTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'PendingGate')) {
        Invoke-PendingJournalStartupGateTest -OldBinary $oldBinary
    }
    if ($Case -in @('All', 'Core', 'RecoveryJournalGuard')) {
        Invoke-RecoveryJournalValidationGuardTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'InterruptedCpaRollback')) {
        Invoke-InterruptedCpaRollbackTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Core', 'CpaAvailability')) {
        Invoke-CpaAvailabilityTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenanceIdentity')) {
        Invoke-MaintenanceIdentityGateTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenanceResultWarning')) {
        Invoke-MaintenanceResultPersistenceWarningTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenanceLifecycle')) {
        Invoke-MaintenanceLifecycleTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenanceRecovery')) {
        Invoke-MaintenanceRecoveryTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenanceRollbackFailure')) {
        Invoke-MaintenanceRollbackFailureTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenancePendingGuard')) {
        Invoke-MaintenancePendingRecoveryGuardTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'Maintenance', 'MaintenanceCommitRecovery')) {
        Invoke-MaintenanceCommitRecoveryTest -Binary $oldBinary
        Invoke-MaintenanceCommittedJournalCleanupTest -Binary $oldBinary
    }

    Write-Host 'Transaction integration tests passed.'
} finally {
    $guardFailure = $null
    if ($null -ne $productionGuard) {
        try {
            Close-CpaStackProductionGuard -Guard $productionGuard
        } catch {
            $guardFailure = $_.Exception.Message
        }
        try {
            $productionComparison = Compare-CpaStackProductionListenerSnapshot -Guard $productionGuard
            if (-not [bool]$productionComparison.Unchanged) {
                $guardFailure = 'Production listener ownership changed while transaction integration tests were running.'
            }
        } catch {
            $guardFailure = 'Could not verify the production listener snapshot: ' + $_.Exception.Message
        }
    }
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
    if (-not [string]::IsNullOrWhiteSpace($guardFailure)) { throw $guardFailure }
}
