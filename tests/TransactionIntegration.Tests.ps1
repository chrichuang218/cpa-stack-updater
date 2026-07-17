#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('All', 'CpaSuccess', 'CpaRollback', 'CpaHangCleanup', 'ManagerRollback', 'ManagerMigrationRollback', 'ManagerMigrationTamper', 'ManagerRecoveryGate', 'TransitionHealth', 'PendingGate', 'RecoveryJournalGuard', 'LanSuccess', 'LanRollback', 'LanRecovery', 'UpgradeCandidateRecovery')]
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
$isolatedLanEntry = $null
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
            if (behavior.IndexOf("fail-on-lan", StringComparison.OrdinalIgnoreCase) >= 0 &&
                (IPAddress.Any.Equals(listenAddress) || IPAddress.IPv6Any.Equals(listenAddress)))
            {
                throw new InvalidOperationException("Synthetic LAN bind failure.");
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

function Invoke-IsolatedLanCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ControlRoot,
        [ValidateSet('Loopback', 'Lan')][string]$Mode,
        [ValidateSet('lan', 'recover')][string]$Command = 'lan'
    )

    if ($Command -eq 'lan' -and [string]::IsNullOrWhiteSpace($Mode)) {
        throw 'LAN test command requires a mode.'
    }

    $runId = [guid]::NewGuid().ToString('N')
    $wrapperPath = Join-Path $testRunRoot 'invoke-lan-command.ps1'
    $readyPath = Join-Path $testRunRoot ($runId + '.ready')
    $goPath = Join-Path $testRunRoot ($runId + '.go')
    $stdoutPath = Join-Path $testRunRoot ($runId + '.stdout')
    $stderrPath = Join-Path $testRunRoot ($runId + '.stderr')
    if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
        Write-Utf8Text -Path $wrapperPath -Value @'
param(
    [string]$Entry,
    [string]$ControlRoot,
    [string]$Mode,
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
if ($Command -eq 'recover') {
    & $Entry recover -Root $ControlRoot -Json
} else {
    & $Entry lan -Root $ControlRoot -Action Set -Mode $Mode -Json
}
$commandSucceeded = $?
$commandExitCode = $LASTEXITCODE
if ($null -eq $commandExitCode) { $commandExitCode = if ($commandSucceeded) { 0 } else { 1 } }
exit ([int]$commandExitCode)
'@
    }

    $modeArgument = if ([string]::IsNullOrWhiteSpace($Mode)) { '' } else { $Mode }
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Entry "{1}" -ControlRoot "{2}" -Mode "{3}" -Command {4} -ReadyPath "{5}" -GoPath "{6}"' -f `
        $wrapperPath, $isolatedLanEntry, $ControlRoot, $modeArgument, $Command, $readyPath, $goPath
    $process = Start-Process `
        -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
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
            throw "LAN command wrapper did not reach the registration gate. Error=[$errorText]"
        }
        [void](Register-CpaStackTestProcess -Guard $productionGuard -Process $process)
        $registered = $true
        Write-Utf8Text -Path $goPath -Value 'go'
        if (-not $process.WaitForExit(120000)) {
            throw 'LAN command exceeded the integration-test timeout.'
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
            throw "LAN command returned no JSON result. ExitCode=$($process.ExitCode) Output=[$stdout] Error=[$stderr]"
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
        -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
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

function New-LanTransactionFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Binary,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$CpaBehavior = 'good'
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
    New-SqliteFixture -Path (Join-Path $managerData 'usage.sqlite')
    Write-CpaConfig -Path $cpaConfig -Port $cpaPort
    Write-StackConfig -Path $stackConfig -CpaPort $cpaPort -ManagerPort $managerPort
    Copy-Item -LiteralPath $isolatedStartStackScript -Destination (Join-Path $root 'ops\Start-CPA-Stack.ps1')
    [void](Write-TestSecrets -ControlRoot $root -Protect)
    Write-CpaStackJson -Value ([ordered]@{
        schemaVersion = 1
        instanceId = [string]$fixture.Marker.instanceId
        canonicalRoot = $root
        cpa = [ordered]@{
            version = 'fixture-lan'
            executable = $cpaExe
            sha256 = Get-CpaStackFileHash -Path $cpaExe
        }
        manager = [ordered]@{
            version = 'fixture-lan'
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

function Assert-LanFixtureState {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet('127.0.0.1', '0.0.0.0')][string]$Address
    )

    Assert-Equal $Address (Get-CpaStackConfigHost -ConfigPath $Fixture.CpaConfig) 'CPA config contains the requested bind address'
    $stack = Import-PowerShellDataFile -LiteralPath $Fixture.StackConfig
    Assert-Equal $Address ([string]$stack.Manager.BindAddress) 'Manager config contains the requested bind address'
    foreach ($port in @($Fixture.CpaPort, $Fixture.ManagerPort)) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        Assert-True ($listeners.Count -gt 0) "LAN fixture owns a listener on test port $port"
        foreach ($listener in $listeners) {
            Assert-Equal $Address ([string]$listener.LocalAddress) "Test listener $port uses only the requested address"
        }
    }
    Assert-False (Test-Path -LiteralPath (Join-Path $Fixture.Root 'state\lan.pending.json')) 'LAN transaction leaves no pending journal'
    Assert-False (Test-Path -LiteralPath (Join-Path $Fixture.Root 'state\lan.pending.json.previous')) 'LAN transaction leaves no previous journal artifact'
}

function Invoke-LanConfigurationSuccessTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-LanTransactionFixture -Binary $Binary -Name 'lan-success'
    try {
        $lan = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Mode Lan
        Assert-Equal 0 $lan.ExitCode "LAN command succeeds. Output=[$($lan.Output)] Error=[$($lan.ErrorOutput)]"
        Assert-True ([bool]$lan.Result.success) 'LAN command reports success'
        Assert-Equal 'lan' $lan.Result.operation 'LAN command returns the v2 operation envelope'
        Assert-Equal 'Changed' $lan.Result.outcome 'LAN command reports a committed change'
        Assert-True ([bool]$lan.Result.changed) 'LAN command reports changed=true'
        Assert-False ([bool]$lan.Result.rolledBack) 'Successful LAN command does not report rollback'
        Assert-LanFixtureState -Fixture $fixture -Address '0.0.0.0'

        $loopback = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Mode Loopback
        Assert-Equal 0 $loopback.ExitCode "Loopback command succeeds. Output=[$($loopback.Output)] Error=[$($loopback.ErrorOutput)]"
        Assert-True ([bool]$loopback.Result.success) 'Loopback command reports success'
        Assert-Equal 'Changed' $loopback.Result.outcome 'Loopback command reports a committed change'
        Assert-LanFixtureState -Fixture $fixture -Address '127.0.0.1'
    } finally {
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
    }
}

function Invoke-LanConfigurationRollbackTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-LanTransactionFixture -Binary $Binary -Name 'lan-rollback' -CpaBehavior 'fail-on-lan'
    try {
        $lan = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Mode Lan
        Assert-Equal 1 $lan.ExitCode "Synthetic LAN bind failure returns a failing command. Output=[$($lan.Output)] Error=[$($lan.ErrorOutput)]"
        Assert-False ([bool]$lan.Result.success) 'Failed LAN command reports success=false'
        Assert-Equal 'RolledBack' $lan.Result.outcome 'Failed LAN command reports automatic rollback'
        Assert-False ([bool]$lan.Result.changed) 'Rolled-back LAN command reports changed=false'
        Assert-True ([bool]$lan.Result.rolledBack) 'Failed LAN command reports rolledBack=true'
        Assert-Equal 'LanApplyFailedRolledBack' $lan.Result.error.code 'Rollback result preserves the specific failure code'
        Assert-LanFixtureState -Fixture $fixture -Address '127.0.0.1'

        $noChange = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Mode Loopback
        Assert-Equal 0 $noChange.ExitCode 'Rollback leaves the stack usable by the next public command'
        Assert-Equal 'NoChange' $noChange.Result.outcome 'Post-rollback loopback command is idempotent'
    } finally {
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
    }
}

function Invoke-LanHardInterruptionRecoveryTest {
    param([Parameter(Mandatory = $true)][string]$Binary)

    $fixture = New-LanTransactionFixture -Binary $Binary -Name 'lan-hard-recovery'
    $setLanScript = Join-Path (Split-Path -Parent $isolatedLanEntry) 'Set-CpaStackLan.ps1'
    $originalScript = [System.IO.File]::ReadAllText($setLanScript, [System.Text.UTF8Encoding]::new($false, $true))
    $holdNeedle = "            Set-LanJournalPhase -Journal `$pendingTransaction -Phase 'configs-written'"
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($holdNeedle)).Count) 'LAN hard-kill fixture has one persisted config-write seam'
    $holdProbe = @'
            [System.IO.File]::WriteAllText(
                $env:CPA_STACK_TEST_LAN_HOLD_READY_PATH,
                'ready',
                [System.Text.UTF8Encoding]::new($false)
            )
            while ($true) { Start-Sleep -Milliseconds 100 }
'@
    $patchedScript = $originalScript.Replace($holdNeedle, $holdNeedle + [Environment]::NewLine + $holdProbe.TrimEnd())
    Write-Utf8Text -Path $setLanScript -Value $patchedScript

    $runId = [guid]::NewGuid().ToString('N')
    $wrapperPath = Join-Path $testRunRoot 'invoke-lan-hard-kill.ps1'
    $wrapperReady = Join-Path $testRunRoot ($runId + '.wrapper-ready')
    $wrapperGo = Join-Path $testRunRoot ($runId + '.wrapper-go')
    $holdReady = Join-Path $testRunRoot ($runId + '.transaction-ready')
    $stdoutPath = Join-Path $testRunRoot ($runId + '.stdout')
    $stderrPath = Join-Path $testRunRoot ($runId + '.stderr')
    Write-Utf8Text -Path $wrapperPath -Value @'
param(
    [string]$Entry,
    [string]$ControlRoot,
    [string]$ReadyPath,
    [string]$GoPath
)
$ErrorActionPreference = 'Stop'
[System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path -LiteralPath $GoPath -PathType Leaf)) {
    if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for the hard-kill Job Object.' }
    Start-Sleep -Milliseconds 25
}
& $Entry lan -Root $ControlRoot -Action Set -Mode Lan -Json
exit ([int]$LASTEXITCODE)
'@

    $commandJob = $null
    $process = $null
    $hardPhaseCompleted = $false
    $previousHoldReady = $env:CPA_STACK_TEST_LAN_HOLD_READY_PATH
    try {
        $env:CPA_STACK_TEST_LAN_HOLD_READY_PATH = $holdReady
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Entry "{1}" -ControlRoot "{2}" -ReadyPath "{3}" -GoPath "{4}"' -f `
            $wrapperPath, $isolatedLanEntry, $fixture.Root, $wrapperReady, $wrapperGo
        $process = Start-Process `
            -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        $commandJob = [CpaStackUpdater.ProductionGuard.KillOnCloseJob]::new()
        $commandJob.Assign($process)
        $readyDeadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $wrapperReady -PathType Leaf) -and -not $process.HasExited -and (Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True (Test-Path -LiteralPath $wrapperReady -PathType Leaf) 'Hard-kill wrapper reaches the Job Object gate'
        Write-Utf8Text -Path $wrapperGo -Value 'go'

        $holdDeadline = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $holdReady -PathType Leaf) -and -not $process.HasExited -and (Get-Date) -lt $holdDeadline) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $holdReady -PathType Leaf) 'LAN transaction reaches the persisted configs-written phase before hard termination'
        Assert-False $process.HasExited 'LAN transaction is still active at the hard-interruption point'
        $commandJob.Dispose()
        $commandJob = $null
        Assert-True ($process.WaitForExit(10000)) 'Closing the dedicated Job Object kills the LAN command tree'
        $hardPhaseCompleted = $true
    } finally {
        $env:CPA_STACK_TEST_LAN_HOLD_READY_PATH = $previousHoldReady
        Write-Utf8Text -Path $setLanScript -Value $originalScript
        if ($null -ne $commandJob) { $commandJob.Dispose() }
        if ($null -ne $process) {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(10000)
            }
            $process.Dispose()
        }
        if (-not $hardPhaseCompleted) {
            Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
            Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        }
    }

    try {
        $journalPath = Join-Path $fixture.Root 'state\lan.pending.json'
        Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) 'Hard interruption leaves the persistent LAN journal'
        Assert-Equal '0.0.0.0' (Get-CpaStackConfigHost -ConfigPath $fixture.CpaConfig) 'Hard interruption occurs after the CPA config write'
        Assert-Equal '0.0.0.0' ([string](Import-PowerShellDataFile -LiteralPath $fixture.StackConfig).Manager.BindAddress) 'Hard interruption occurs after the Manager config write'

        $previousJournalPath = $journalPath + '.previous'
        Assert-True (Test-Path -LiteralPath $previousJournalPath -PathType Leaf) 'Hard interruption retains the adjacent LAN journal predecessor'
        $validCurrentBytes = [System.IO.File]::ReadAllBytes($journalPath)
        $validPreviousBytes = [System.IO.File]::ReadAllBytes($previousJournalPath)
        $validJournal = Read-CpaStackJson -Path $journalPath
        $validPreviousJournal = Read-CpaStackJson -Path $previousJournalPath
        Assert-Equal 'configs-written' ([string]$validJournal.phase) 'Hard interruption current journal records configs-written'
        Assert-Equal 'prepared' ([string]$validPreviousJournal.phase) 'Hard interruption previous journal records the adjacent prepared phase'
        $validCurrentHash = Get-CpaStackFileHash -Path $journalPath
        $validPreviousHash = Get-CpaStackFileHash -Path $previousJournalPath

        $invalidPreviousJournal = $validPreviousJournal | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $invalidPreviousJournal.instanceId = [guid]::NewGuid().ToString('N')
        Write-Utf8Text -Path $previousJournalPath -Value ($invalidPreviousJournal | ConvertTo-Json -Depth 12)
        $currentHashBeforeInvalidPrevious = Get-CpaStackFileHash -Path $journalPath
        $invalidPreviousHash = Get-CpaStackFileHash -Path $previousJournalPath
        $cpaConfigHash = Get-CpaStackFileHash -Path $fixture.CpaConfig
        $stackConfigHash = Get-CpaStackFileHash -Path $fixture.StackConfig
        $aclSections = [System.Security.AccessControl.AccessControlSections]::Owner -bor
            [System.Security.AccessControl.AccessControlSections]::Group -bor
            [System.Security.AccessControl.AccessControlSections]::Access
        $journalSddl = (Get-CpaStackFileSystemAcl -Path $journalPath).GetSecurityDescriptorSddlForm($aclSections)
        $previousJournalSddl = (Get-CpaStackFileSystemAcl -Path $previousJournalPath).GetSecurityDescriptorSddlForm($aclSections)
        $cpaConfigSddl = (Get-CpaStackFileSystemAcl -Path $fixture.CpaConfig).GetSecurityDescriptorSddlForm($aclSections)
        $stackConfigSddl = (Get-CpaStackFileSystemAcl -Path $fixture.StackConfig).GetSecurityDescriptorSddlForm($aclSections)
        $cpaListenerBeforeInvalidPrevious = Get-CpaStackListener -Port $fixture.CpaPort
        $managerListenerBeforeInvalidPrevious = Get-CpaStackListener -Port $fixture.ManagerPort

        $invalidPreviousRecovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-True ($invalidPreviousRecovery.ExitCode -ne 0) 'Invalid LAN previous-journal recovery returns a nonzero exit code'
        Assert-False ([bool]$invalidPreviousRecovery.Result.success) 'Invalid LAN previous-journal recovery reports failure'
        Assert-Equal 'ManualRecoveryRequired' ([string]$invalidPreviousRecovery.Result.outcome) "Invalid LAN previous journal requires manual recovery. Output=[$($invalidPreviousRecovery.Output)] Error=[$($invalidPreviousRecovery.ErrorOutput)]"
        Assert-Equal $currentHashBeforeInvalidPrevious (Get-CpaStackFileHash -Path $journalPath) 'Invalid previous recovery does not rewrite the current journal'
        Assert-Equal $invalidPreviousHash (Get-CpaStackFileHash -Path $previousJournalPath) 'Invalid previous recovery preserves the invalid previous evidence'
        Assert-Equal $cpaConfigHash (Get-CpaStackFileHash -Path $fixture.CpaConfig) 'Invalid previous recovery preserves CPA config bytes'
        Assert-Equal $stackConfigHash (Get-CpaStackFileHash -Path $fixture.StackConfig) 'Invalid previous recovery preserves stack config bytes'
        Assert-Equal $journalSddl ((Get-CpaStackFileSystemAcl -Path $journalPath).GetSecurityDescriptorSddlForm($aclSections)) 'Invalid previous recovery preserves current journal ACL'
        Assert-Equal $previousJournalSddl ((Get-CpaStackFileSystemAcl -Path $previousJournalPath).GetSecurityDescriptorSddlForm($aclSections)) 'Invalid previous recovery preserves previous journal ACL'
        Assert-Equal $cpaConfigSddl ((Get-CpaStackFileSystemAcl -Path $fixture.CpaConfig).GetSecurityDescriptorSddlForm($aclSections)) 'Invalid previous recovery preserves CPA config ACL'
        Assert-Equal $stackConfigSddl ((Get-CpaStackFileSystemAcl -Path $fixture.StackConfig).GetSecurityDescriptorSddlForm($aclSections)) 'Invalid previous recovery preserves stack config ACL'
        $cpaListenerAfterInvalidPrevious = Get-CpaStackListener -Port $fixture.CpaPort
        $managerListenerAfterInvalidPrevious = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-Equal ([int]$cpaListenerBeforeInvalidPrevious.ProcessId) ([int]$cpaListenerAfterInvalidPrevious.ProcessId) 'Invalid previous recovery does not restart CPA'
        Assert-Equal ([int]$managerListenerBeforeInvalidPrevious.ProcessId) ([int]$managerListenerAfterInvalidPrevious.ProcessId) 'Invalid previous recovery does not restart Manager'

        [System.IO.File]::WriteAllBytes($journalPath, $validCurrentBytes)
        [System.IO.File]::WriteAllBytes($previousJournalPath, $validPreviousBytes)
        Assert-Equal $validCurrentHash (Get-CpaStackFileHash -Path $journalPath) 'Raw fixture restore reinstates the valid current journal bytes'
        Assert-Equal $validPreviousHash (Get-CpaStackFileHash -Path $previousJournalPath) 'Raw fixture restore reinstates the valid previous journal bytes'

        $foreignJournal = $validJournal | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $foreignJournal.instanceId = [guid]::NewGuid().ToString('N')
        Write-Utf8Text -Path $journalPath -Value ($foreignJournal | ConvertTo-Json -Depth 12)
        $foreignJournalHash = Get-CpaStackFileHash -Path $journalPath
        $previousJournalHash = Get-CpaStackFileHash -Path $previousJournalPath
        $journalSddl = (Get-CpaStackFileSystemAcl -Path $journalPath).GetSecurityDescriptorSddlForm($aclSections)
        $previousJournalSddl = (Get-CpaStackFileSystemAcl -Path $previousJournalPath).GetSecurityDescriptorSddlForm($aclSections)
        $cpaConfigSddl = (Get-CpaStackFileSystemAcl -Path $fixture.CpaConfig).GetSecurityDescriptorSddlForm($aclSections)
        $stackConfigSddl = (Get-CpaStackFileSystemAcl -Path $fixture.StackConfig).GetSecurityDescriptorSddlForm($aclSections)
        $cpaListenerBeforeForeign = Get-CpaStackListener -Port $fixture.CpaPort
        $managerListenerBeforeForeign = Get-CpaStackListener -Port $fixture.ManagerPort

        $foreignRecovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-True ($foreignRecovery.ExitCode -ne 0) 'Foreign LAN journal recovery returns a nonzero exit code'
        Assert-False ([bool]$foreignRecovery.Result.success) 'Foreign LAN journal recovery reports failure'
        Assert-Equal 'ManualRecoveryRequired' ([string]$foreignRecovery.Result.outcome) "Foreign LAN journal requires manual recovery. Output=[$($foreignRecovery.Output)] Error=[$($foreignRecovery.ErrorOutput)]"
        Assert-Equal $foreignJournalHash (Get-CpaStackFileHash -Path $journalPath) 'Foreign LAN journal is not rewritten'
        Assert-Equal $previousJournalHash (Get-CpaStackFileHash -Path $previousJournalPath) 'Foreign LAN recovery preserves the previous journal evidence'
        Assert-Equal $cpaConfigHash (Get-CpaStackFileHash -Path $fixture.CpaConfig) 'Foreign LAN recovery preserves CPA config bytes'
        Assert-Equal $stackConfigHash (Get-CpaStackFileHash -Path $fixture.StackConfig) 'Foreign LAN recovery preserves stack config bytes'
        Assert-Equal $journalSddl ((Get-CpaStackFileSystemAcl -Path $journalPath).GetSecurityDescriptorSddlForm($aclSections)) 'Foreign LAN recovery preserves journal ACL'
        Assert-Equal $previousJournalSddl ((Get-CpaStackFileSystemAcl -Path $previousJournalPath).GetSecurityDescriptorSddlForm($aclSections)) 'Foreign LAN recovery preserves previous journal ACL'
        Assert-Equal $cpaConfigSddl ((Get-CpaStackFileSystemAcl -Path $fixture.CpaConfig).GetSecurityDescriptorSddlForm($aclSections)) 'Foreign LAN recovery preserves CPA config ACL'
        Assert-Equal $stackConfigSddl ((Get-CpaStackFileSystemAcl -Path $fixture.StackConfig).GetSecurityDescriptorSddlForm($aclSections)) 'Foreign LAN recovery preserves stack config ACL'
        $cpaListenerAfterForeign = Get-CpaStackListener -Port $fixture.CpaPort
        $managerListenerAfterForeign = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-Equal ([int]$cpaListenerBeforeForeign.ProcessId) ([int]$cpaListenerAfterForeign.ProcessId) 'Foreign LAN recovery does not restart CPA'
        Assert-Equal ([int]$managerListenerBeforeForeign.ProcessId) ([int]$managerListenerAfterForeign.ProcessId) 'Foreign LAN recovery does not restart Manager'

        [System.IO.File]::WriteAllBytes($journalPath, $validCurrentBytes)
        [System.IO.File]::WriteAllBytes($previousJournalPath, $validPreviousBytes)
        Assert-Equal $validCurrentHash (Get-CpaStackFileHash -Path $journalPath) 'Foreign rejection is followed by a raw valid-current restore'
        Assert-Equal $validPreviousHash (Get-CpaStackFileHash -Path $previousJournalPath) 'Foreign rejection is followed by a raw valid-previous restore'
        Assert-Equal 'configs-written' ([string](Read-CpaStackJson -Path $journalPath).phase) 'Restored current journal retains configs-written'
        Assert-Equal 'prepared' ([string](Read-CpaStackJson -Path $previousJournalPath).phase) 'Restored previous journal retains prepared'

        $recovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-Equal 0 $recovery.ExitCode "Public recover succeeds after LAN hard interruption. Output=[$($recovery.Output)] Error=[$($recovery.ErrorOutput)]"
        Assert-True ([bool]$recovery.Result.success) 'LAN recovery reports success'
        Assert-Equal 'Changed' $recovery.Result.outcome 'LAN recovery reports a recovered change'
        Assert-True ([bool]$recovery.Result.recovered) 'LAN recovery sets recovered=true'
        Assert-True ([bool]$recovery.Result.rolledBack) 'LAN recovery reports that it restored the pre-transaction state'
        Assert-Equal 'lan' $recovery.Result.recoveryKind 'Recovery routes the LAN journal to its dedicated transaction recovery'
        Assert-LanFixtureState -Fixture $fixture -Address '127.0.0.1'

        $secondRecovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-Equal 0 $secondRecovery.ExitCode 'A second recover is idempotent'
        Assert-Equal 'NoChange' $secondRecovery.Result.outcome 'A second recover reports NoChange'
        Assert-False ([bool]$secondRecovery.Result.recovered) 'A second recover does not invent recovery work'
    } finally {
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        foreach ($path in @($wrapperReady, $wrapperGo, $holdReady, $stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

function Invoke-UpgradeCandidateHardInterruptionRecoveryTest {
    param(
        [Parameter(Mandatory = $true)][string]$OldBinary,
        [Parameter(Mandatory = $true)][string]$NewBinary
    )

    $fixture = New-LanTransactionFixture -Binary $OldBinary -Name 'upgrade-candidate-hard-recovery'
    $scriptsRoot = Split-Path -Parent $isolatedLanEntry
    $upgradeScript = Join-Path $scriptsRoot 'Invoke-CpaStackUpgrade.ps1'
    $originalScript = [System.IO.File]::ReadAllText($upgradeScript, [System.Text.UTF8Encoding]::new($false, $true))
    $overrideNeedle = '. (Join-Path $PSScriptRoot "CpaStack.Common.ps1")'
    Assert-Equal 1 ([regex]::Matches($originalScript, [regex]::Escape($overrideNeedle)).Count) 'Upgrade hard-kill fixture has one release override seam'
    $releaseOverride = @'
function Get-CpaStackLatestRelease {
    param([string]$Repository, [string]$AssetPattern)
    return [pscustomobject]@{ Repository = $Repository; AssetPattern = $AssetPattern }
}

function Save-CpaStackRelease {
    param($Release, [string]$Destination)
    $isCpa = [string]$Release.Repository -eq 'router-for-me/CLIProxyAPI'
    $packageRoot = if ($isCpa) {
        $env:CPA_STACK_TEST_UPGRADE_CPA_PACKAGE
    } else {
        $env:CPA_STACK_TEST_UPGRADE_MANAGER_PACKAGE
    }
    $executable = Join-Path $packageRoot $(if ($isCpa) { 'cli-proxy-api.exe' } else { 'cpa-manager-plus.exe' })
    return [pscustomobject]@{
        tag = if ($isCpa) { 'v9.9.9' } else { 'v1.11.1' }
        packageRoot = $packageRoot
        executableSha256 = Get-CpaStackFileHash -Path $executable
        archiveSha256 = ('A' * 64)
    }
}
'@
    $patchedScript = $originalScript.Replace(
        $overrideNeedle,
        $overrideNeedle + [Environment]::NewLine + $releaseOverride.TrimEnd()
    )

    $packageRoot = Join-Path $testRunRoot ('upgrade-packages-' + [guid]::NewGuid().ToString('N'))
    $cpaPackage = Join-Path $packageRoot 'cpa'
    $managerPackage = Join-Path $packageRoot 'manager'
    $candidateRecordPath = Join-Path $testRunRoot ([guid]::NewGuid().ToString('N') + '.candidate-started')
    New-Item -ItemType Directory -Force -Path $cpaPackage, $managerPackage | Out-Null
    Copy-Item -LiteralPath $NewBinary -Destination (Join-Path $cpaPackage 'cli-proxy-api.exe')
    Copy-Item -LiteralPath $OldBinary -Destination (Join-Path $managerPackage 'cpa-manager-plus.exe')
    Write-Utf8Text -Path (Join-Path $cpaPackage 'behavior.txt') -Value 'hang-before-listen'
    Write-Utf8Text -Path (Join-Path $cpaPackage 'start-record-path.txt') -Value $candidateRecordPath

    $previousCpaPackage = $env:CPA_STACK_TEST_UPGRADE_CPA_PACKAGE
    $previousManagerPackage = $env:CPA_STACK_TEST_UPGRADE_MANAGER_PACKAGE
    $invocation = $null
    $candidateProcessId = 0
    $candidateExecutable = $null
    $scriptRestored = $false
    try {
        $env:CPA_STACK_TEST_UPGRADE_CPA_PACKAGE = $cpaPackage
        $env:CPA_STACK_TEST_UPGRADE_MANAGER_PACKAGE = $managerPackage
        Write-Utf8Text -Path $upgradeScript -Value $patchedScript

        $formalCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $formalManager = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-True ($null -ne $formalCpa) 'Canonical CPA is listening before the interrupted upgrade'
        Assert-True ($null -ne $formalManager) 'Canonical Manager is listening before the interrupted upgrade'
        $formalCpaProcessId = [int]$formalCpa.ProcessId
        $formalManagerProcessId = [int]$formalManager.ProcessId

        $invocation = Start-IsolatedInterruptedScript `
            -TargetScript $upgradeScript `
            -Parameters ([ordered]@{
                ControlRoot = $fixture.Root
                AllowUnknownVersionReplacement = $true
            })

        $startDeadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $candidateRecordPath -PathType Leaf) -and
            -not $invocation.Process.HasExited -and (Get-Date) -lt $startDeadline) {
            Start-Sleep -Milliseconds 50
        }
        $updaterError = ''
        if (-not (Test-Path -LiteralPath $candidateRecordPath -PathType Leaf) -and $invocation.Process.HasExited) {
            [void]$invocation.Process.WaitForExit()
            if (Test-Path -LiteralPath $invocation.StderrPath -PathType Leaf) {
                $updaterError = [System.IO.File]::ReadAllText($invocation.StderrPath)
            }
        }
        Assert-True (Test-Path -LiteralPath $candidateRecordPath -PathType Leaf) "Upgrade starts the bind-delayed candidate before timeout. Error=[$updaterError]"
        Assert-False $invocation.Process.HasExited 'Upgrade updater is still active while its candidate is waiting before bind'

        $startRecord = [System.IO.File]::ReadAllText($candidateRecordPath).Trim()
        Assert-True ($startRecord -match '^fixture-new\|(?<pid>\d+)$') 'Bind-delayed upgrade candidate records its process id'
        $candidateProcessId = [int]$matches['pid']
        $journalPath = Join-Path $fixture.Root 'state\upgrade.pending.json'
        $journalPreviousPath = $journalPath + '.previous'
        Assert-True (Test-Path -LiteralPath $journalPath -PathType Leaf) 'Upgrade writes its journal before starting the candidate'
        Assert-True (Test-Path -LiteralPath $journalPreviousPath -PathType Leaf) 'Upgrade retains the adjacent prepared journal generation'
        $journal = Read-CpaStackJson -Path $journalPath
        $journalPrevious = Read-CpaStackJson -Path $journalPreviousPath
        Assert-Equal 'testing-cpa' ([string]$journal.phase) 'Upgrade journal identifies the interrupted candidate phase'
        Assert-Equal 'prepared' ([string]$journalPrevious.phase) 'Upgrade previous journal records the legal prepared predecessor'
        Assert-Equal ([string]$journal.operationId) ([string]$journalPrevious.operationId) 'Upgrade current and previous journals bind the same operationId'
        $validJournalBytes = [System.IO.File]::ReadAllBytes($journalPath)
        $validPreviousBytes = [System.IO.File]::ReadAllBytes($journalPreviousPath)
        $validJournalHash = Get-CpaStackFileHash -Path $journalPath
        $validPreviousHash = Get-CpaStackFileHash -Path $journalPreviousPath
        $candidateExecutable = [System.IO.Path]::GetFullPath([string]$journal.cpaCandidateExe)
        Assert-True (Test-Path -LiteralPath $candidateExecutable -PathType Leaf) 'Upgrade journal binds the exact candidate executable'
        [void](Assert-CpaStackTestIsolation `
            -Guard $productionGuard `
            -TestRoot $fixture.Root `
            -TestStateHome $isolatedLocalAppData `
            -TestPort @([int]$journal.cpaCandidatePort, [int]$journal.managerCandidatePort) `
            -TestProcessId @($candidateProcessId))
        $candidateProcess = Get-Process -Id $candidateProcessId -ErrorAction Stop
        try {
            Assert-Equal $candidateExecutable ([System.IO.Path]::GetFullPath([string]$candidateProcess.MainModule.FileName)) 'Recorded orphan PID executes the journal-bound candidate path'
        } finally {
            $candidateProcess.Dispose()
        }
        Assert-True ($null -eq (Get-CpaStackListener -Port ([int]$journal.cpaCandidatePort))) 'Candidate has not bound its temporary port at the interruption point'

        $invocation.Process.Kill()
        Assert-True ($invocation.Process.WaitForExit(10000)) 'Hard termination stops the updater process'
        Start-Sleep -Milliseconds 250
        Assert-True ($null -ne (Get-Process -Id $candidateProcessId -ErrorAction SilentlyContinue)) 'Hard termination leaves the bind-delayed candidate orphan alive'
        Assert-True ($null -eq (Get-CpaStackListener -Port ([int]$journal.cpaCandidatePort))) 'The orphan remains invisible to listener-only cleanup'

        Write-Utf8Text -Path $upgradeScript -Value $originalScript
        $scriptRestored = $true
        $env:CPA_STACK_TEST_UPGRADE_CPA_PACKAGE = $previousCpaPackage
        $env:CPA_STACK_TEST_UPGRADE_MANAGER_PACKAGE = $previousManagerPackage

        Remove-Item -LiteralPath $journalPath -Force
        $orphanPreviousRecovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-True ($orphanPreviousRecovery.ExitCode -ne 0) 'Orphan upgrade previous generation returns a nonzero exit code'
        Assert-Equal 'ManualRecoveryRequired' ([string]$orphanPreviousRecovery.Result.outcome) "Orphan upgrade previous requires manual recovery. Output=[$($orphanPreviousRecovery.Output)] Error=[$($orphanPreviousRecovery.ErrorOutput)]"
        Assert-Equal $validPreviousHash (Get-CpaStackFileHash -Path $journalPreviousPath) 'Orphan previous evidence remains unchanged'
        Assert-True ($null -ne (Get-Process -Id $candidateProcessId -ErrorAction SilentlyContinue)) 'Orphan previous rejection does not stop the candidate process'
        [System.IO.File]::WriteAllBytes($journalPath, $validJournalBytes)
        Protect-CpaStackSecretFile -Path $journalPath
        Assert-Equal $validJournalHash (Get-CpaStackFileHash -Path $journalPath) 'Raw current journal restore reinstates the valid bytes'

        $foreignPrevious = Read-CpaStackJson -Path $journalPreviousPath
        $foreignPrevious.operationId = [guid]::NewGuid().ToString('N')
        Write-Utf8Text -Path $journalPreviousPath -Value ($foreignPrevious | ConvertTo-Json -Depth 12)
        Protect-CpaStackSecretFile -Path $journalPreviousPath
        $foreignPreviousHash = Get-CpaStackFileHash -Path $journalPreviousPath
        $foreignPreviousRecovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-True ($foreignPreviousRecovery.ExitCode -ne 0) 'Foreign upgrade previous generation returns a nonzero exit code'
        Assert-Equal 'ManualRecoveryRequired' ([string]$foreignPreviousRecovery.Result.outcome) "Foreign upgrade previous requires manual recovery. Output=[$($foreignPreviousRecovery.Output)] Error=[$($foreignPreviousRecovery.ErrorOutput)]"
        Assert-Equal $validJournalHash (Get-CpaStackFileHash -Path $journalPath) 'Foreign previous rejection preserves the current upgrade journal'
        Assert-Equal $foreignPreviousHash (Get-CpaStackFileHash -Path $journalPreviousPath) 'Foreign previous rejection preserves the previous evidence'
        Assert-True ($null -ne (Get-Process -Id $candidateProcessId -ErrorAction SilentlyContinue)) 'Foreign previous rejection does not stop the candidate process'
        [System.IO.File]::WriteAllBytes($journalPreviousPath, $validPreviousBytes)
        Protect-CpaStackSecretFile -Path $journalPreviousPath
        Assert-Equal $validPreviousHash (Get-CpaStackFileHash -Path $journalPreviousPath) 'Raw previous restore reinstates the valid adjacent generation'

        $recovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-Equal 0 $recovery.ExitCode "Public recover succeeds after upgrade candidate hard interruption. Output=[$($recovery.Output)] Error=[$($recovery.ErrorOutput)]"
        Assert-True ([bool]$recovery.Result.success) 'Upgrade candidate recovery reports success'
        Assert-Equal 'Changed' $recovery.Result.outcome 'Upgrade candidate recovery reports a recovered change'
        Assert-True ([bool]$recovery.Result.recovered) 'Upgrade candidate recovery sets recovered=true'
        Assert-Equal 'upgrade' $recovery.Result.recoveryKind 'Public recovery routes the upgrade journal to its transaction recovery'
        Assert-True ($null -eq (Get-Process -Id $candidateProcessId -ErrorAction SilentlyContinue)) 'Public recovery kills the exact bind-delayed candidate process'
        Assert-False (Test-Path -LiteralPath $journalPath) 'Public recovery removes the upgrade journal after verified cleanup'
        Assert-False (Test-Path -LiteralPath $journalPreviousPath) 'Public recovery removes the validated previous generation before the current journal'
        Assert-False (Test-Path -LiteralPath $candidateExecutable) 'Public recovery can remove the candidate work tree after stopping the orphan'

        $recoveredCpa = Get-CpaStackListener -Port $fixture.CpaPort
        $recoveredManager = Get-CpaStackListener -Port $fixture.ManagerPort
        Assert-Equal $formalCpaProcessId ([int]$recoveredCpa.ProcessId) 'Candidate recovery does not restart or replace the formal CPA'
        Assert-Equal $formalManagerProcessId ([int]$recoveredManager.ProcessId) 'Candidate recovery does not restart or replace the formal Manager'
        Assert-Equal $fixture.StackConfig ([string]$recovery.Result.state.Configuration.StackConfigPath) 'Recovery verification remains bound to the isolated canonical config'

        $secondRecovery = Invoke-IsolatedLanCommand -ControlRoot $fixture.Root -Command recover
        Assert-Equal 0 $secondRecovery.ExitCode 'A second upgrade recover is idempotent'
        Assert-Equal 'NoChange' $secondRecovery.Result.outcome 'A second upgrade recover reports NoChange'
        Assert-False ([bool]$secondRecovery.Result.recovered) 'A second upgrade recover does not invent recovery work'
    } finally {
        $env:CPA_STACK_TEST_UPGRADE_CPA_PACKAGE = $previousCpaPackage
        $env:CPA_STACK_TEST_UPGRADE_MANAGER_PACKAGE = $previousManagerPackage
        if (-not $scriptRestored) { Write-Utf8Text -Path $upgradeScript -Value $originalScript }
        Remove-IsolatedInterruptedScript -Invocation $invocation
        if ($candidateProcessId -gt 0 -and $candidateExecutable) {
            [void](Stop-CpaStackProcessesByExecutablePath -ExpectedPath $candidateExecutable)
        }
        Stop-OwnedFixturePort -Port $fixture.CpaPort -ManagedRoot $fixture.Root
        Stop-OwnedFixturePort -Port $fixture.ManagerPort -ManagedRoot $fixture.Root
        foreach ($path in @($candidateRecordPath, $packageRoot)) {
            if (Test-Path -LiteralPath $path) { Remove-TestPathWithRetry -Path $path }
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
        $output = @(& powershell.exe @arguments 2>&1)
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

    $fixture = New-LanTransactionFixture -Binary $OldBinary -Name 'recovery-journal-guard'
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

        $cpaRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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

        $foreignPreviousRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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

        $invalidPhaseRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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

        $managerRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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

        $orphanRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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

        $preparedRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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
        Assert-True ([int]$afterPreparedCpa.ProcessId -ne [int]$beforeCpa.ProcessId) 'Canonical prepared recovery replaces only the interrupted CPA process'
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

        $deferredRecovery = Invoke-IsolatedLanCommand -ControlRoot $root -Command recover
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
    $isolatedLanEntry = Join-Path $transactionFixture.Repository 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
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
    if ($Case -in @('All', 'TransitionHealth')) {
        Invoke-TransitionHealthTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'PendingGate')) {
        Invoke-PendingJournalStartupGateTest -OldBinary $oldBinary
    }
    if ($Case -in @('All', 'RecoveryJournalGuard')) {
        Invoke-RecoveryJournalValidationGuardTest -OldBinary $oldBinary -NewBinary $newBinary
    }
    if ($Case -in @('All', 'LanSuccess')) {
        Invoke-LanConfigurationSuccessTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'LanRollback')) {
        Invoke-LanConfigurationRollbackTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'LanRecovery')) {
        Invoke-LanHardInterruptionRecoveryTest -Binary $oldBinary
    }
    if ($Case -in @('All', 'UpgradeCandidateRecovery')) {
        Invoke-UpgradeCandidateHardInterruptionRecoveryTest -OldBinary $oldBinary -NewBinary $newBinary
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
