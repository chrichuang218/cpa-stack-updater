#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CpaStackPermanentProductionPorts = @(8317, 8318, 18317, 18318)

function Initialize-CpaStackProductionGuardNativeType {
    if ($null -ne ('CpaStackUpdater.ProductionGuard.KillOnCloseJob' -as [type])) { return }

    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace CpaStackUpdater.ProductionGuard
{
    public sealed class KillOnCloseJob : IDisposable
    {
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformation = 9;
        private IntPtr handle;

        public KillOnCloseJob()
        {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the test Job Object.");
            }

            JOBOBJECT_EXTENDED_LIMIT_INFORMATION information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, buffer, false);
                if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not enable KILL_ON_JOB_CLOSE.");
                }
            }
            catch
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
                throw;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public void Assign(Process process)
        {
            if (process == null) throw new ArgumentNullException("process");
            if (handle == IntPtr.Zero) throw new ObjectDisposedException("KillOnCloseJob");
            if (process.HasExited) throw new InvalidOperationException("The test process already exited before registration.");
            if (!AssignProcessToJobObject(handle, process.Handle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not assign the test process to the guard Job Object.");
            }
        }

        public static string GetExecutablePath(Process process)
        {
            if (process == null) throw new ArgumentNullException("process");
            StringBuilder path = new StringBuilder(32768);
            int length = path.Capacity;
            if (!QueryFullProcessImageName(process.Handle, 0, path, ref length))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not query the fixed test process image path.");
            }
            if (length <= 0) throw new InvalidOperationException("The fixed test process image path is empty.");
            return path.ToString(0, length);
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero)
            {
                CloseHandle(handle);
                handle = IntPtr.Zero;
            }
            GC.SuppressFinalize(this);
        }

        ~KillOnCloseJob()
        {
            Dispose();
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(
            IntPtr process,
            int flags,
            StringBuilder executablePath,
            ref int executablePathLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

function ConvertTo-CpaStackGuardPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A guarded path cannot be empty.' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $fullPath = [System.IO.Path]::GetFullPath($expanded)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $fullPath.TrimEnd([char]'\', [char]'/')
}

function Assert-CpaStackGuardPathTraversalSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $expandedInputPath = [Environment]::ExpandEnvironmentVariables($Path)
    foreach ($inputSegment in @($expandedInputPath -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        if ([string]$inputSegment -match '~[0-9]') {
            throw "$Role '$Path' uses a potential 8.3 alias component '$inputSegment'."
        }
    }

    $normalizedPath = ConvertTo-CpaStackGuardPath -Path $expandedInputPath
    $pathRoot = [System.IO.Path]::GetPathRoot($normalizedPath)
    $segments = @($normalizedPath.Substring($pathRoot.Length) -split '[\\/]' | Where-Object { $_.Length -gt 0 })
    $currentPath = $pathRoot

    try {
        $rootItem = Get-Item -LiteralPath $pathRoot -Force -ErrorAction Stop
    } catch {
        throw "Could not safely inspect the $Role path root '$pathRoot': $($_.Exception.Message)"
    }
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Role '$normalizedPath' traverses reparse point '$pathRoot'."
    }

    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = [string]$segments[$index]
        $candidatePath = Join-Path $currentPath $segment
        $item = $null
        try {
            $item = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
        } catch {
            $itemFailure = $_.Exception.Message
            try {
                $matchingChildren = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop |
                    Where-Object { [string]::Equals($_.Name, $segment, [System.StringComparison]::OrdinalIgnoreCase) })
            } catch {
                throw "Could not safely inspect the existing $Role path chain at '$candidatePath': $($_.Exception.Message)"
            }
            if ($matchingChildren.Count -eq 0) { break }
            throw "Could not safely inspect existing $Role path component '$candidatePath': $itemFailure"
        }

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Role '$normalizedPath' traverses reparse point '$candidatePath'."
        }
        $canonicalItemPath = ConvertTo-CpaStackGuardPath -Path ([string]$item.FullName)
        $normalizedCandidatePath = ConvertTo-CpaStackGuardPath -Path $candidatePath
        if (-not [string]::Equals($normalizedCandidatePath, $canonicalItemPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$Role '$normalizedPath' uses filesystem alias '$candidatePath'; canonical path is '$canonicalItemPath'."
        }
        if (-not [bool]$item.PSIsContainer) {
            throw "$Role '$normalizedPath' traverses existing non-directory path '$candidatePath'."
        }
        $currentPath = $candidatePath
    }

    return $normalizedPath
}

function Test-CpaStackGuardPathOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    if ([string]::Equals($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $leftPrefix = if ($Left.EndsWith('\') -or $Left.EndsWith('/')) { $Left } else { $Left + [System.IO.Path]::DirectorySeparatorChar }
    $rightPrefix = if ($Right.EndsWith('\') -or $Right.EndsWith('/')) { $Right } else { $Right + [System.IO.Path]::DirectorySeparatorChar }
    return $Left.StartsWith($rightPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Right.StartsWith($leftPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CpaStackActiveListenerPorts {
    $ports = [System.Collections.Generic.HashSet[int]]::new()
    $command = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            if ($null -ne $connection -and [int]$connection.LocalPort -gt 0) {
                [void]$ports.Add([int]$connection.LocalPort)
            }
        }
    }
    foreach ($endpoint in @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners())) {
        if ($null -ne $endpoint -and [int]$endpoint.Port -gt 0) {
            [void]$ports.Add([int]$endpoint.Port)
        }
    }
    return ,$ports
}

function ConvertTo-CpaStackListenerMetadata {
    param([Parameter(Mandatory = $true)]$Listener)

    foreach ($propertyName in @('LocalAddress', 'LocalPort', 'OwningProcess')) {
        if ($null -eq $Listener.PSObject.Properties[$propertyName]) {
            throw "Listener metadata is missing required property '$propertyName'."
        }
    }
    $port = [int]$Listener.LocalPort
    $processId = [int]$Listener.OwningProcess
    if ($port -lt 1 -or $port -gt 65535) { throw "Listener metadata has an invalid TCP port: $port" }
    if ($processId -lt 0) { throw "Listener metadata has an invalid process id: $processId" }
    $executablePath = if ($null -ne $Listener.PSObject.Properties['ExecutablePath']) { [string]$Listener.ExecutablePath } else { $null }
    return [pscustomobject]@{
        LocalAddress = [string]$Listener.LocalAddress
        LocalPort = $port
        OwningProcess = $processId
        ExecutablePath = $executablePath
    }
}

function Get-CpaStackListenerSnapshot {
    [CmdletBinding()]
    param()

    if ($null -eq (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw 'Get-NetTCPConnection is required to capture listener ownership metadata.'
    }

    $snapshot = foreach ($connection in @(Get-NetTCPConnection -State Listen -ErrorAction Stop)) {
        $processId = [int]$connection.OwningProcess
        $executablePath = $null
        if ($processId -gt 0) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                try {
                    try { $executablePath = [string]$process.Path } catch { $executablePath = $null }
                    if ([string]::IsNullOrWhiteSpace($executablePath)) {
                        try { $executablePath = [string]$process.MainModule.FileName } catch { $executablePath = $null }
                    }
                } finally {
                    if ($process -is [System.IDisposable]) { $process.Dispose() }
                }
            }
        }
        [pscustomobject]@{
            LocalAddress = [string]$connection.LocalAddress
            LocalPort = [int]$connection.LocalPort
            OwningProcess = $processId
            ExecutablePath = $executablePath
        }
    }
    return @($snapshot | Sort-Object LocalPort, LocalAddress, OwningProcess, ExecutablePath)
}

function ConvertTo-CpaStackListenerSignature {
    param([Parameter(Mandatory = $true)]$Listener)

    $metadata = ConvertTo-CpaStackListenerMetadata -Listener $Listener
    return @(
        $metadata.LocalAddress.ToLowerInvariant(),
        [string]$metadata.LocalPort,
        [string]$metadata.OwningProcess,
        ([string]$metadata.ExecutablePath).ToLowerInvariant()
    ) -join [char]0x1f
}

function Get-CpaStackGuardProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Role
    )

    try {
        # Force Process to retain a handle for this exact OS process before reading
        # any PID-reusable metadata.
        [void]$Process.Handle
        if ($Process.HasExited) { throw 'The process has already exited.' }
        $processId = [int]$Process.Id
        $startTimeUtcTicks = [long](($Process.StartTime.ToUniversalTime()).Ticks)
        Initialize-CpaStackProductionGuardNativeType
        $executablePath = [CpaStackUpdater.ProductionGuard.KillOnCloseJob]::GetExecutablePath($Process)
        if ([string]::IsNullOrWhiteSpace($executablePath)) {
            throw 'The executable path is unavailable.'
        }
        $executablePath = ConvertTo-CpaStackGuardPath -Path $executablePath
    } catch {
        throw "Could not capture the $Role process identity: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        ProcessId = $processId
        StartTimeUtcTicks = $startTimeUtcTicks
        ExecutablePath = $executablePath
    }
}

function Test-CpaStackGuardProcessIdentityEqual {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    return (
        [int]$Left.ProcessId -eq [int]$Right.ProcessId -and
        [long]$Left.StartTimeUtcTicks -eq [long]$Right.StartTimeUtcTicks -and
        [string]::Equals(
            [string]$Left.ExecutablePath,
            [string]$Right.ExecutablePath,
            [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-CpaStackRequiredProductionPort {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    if (-not $Config.Contains($Section) -or -not ($Config[$Section] -is [System.Collections.IDictionary])) {
        throw "Production stack config '$ConfigPath' is missing the required $Section section."
    }
    $sectionConfig = [System.Collections.IDictionary]$Config[$Section]
    if (-not $sectionConfig.Contains('Port')) {
        throw "Production stack config '$ConfigPath' is missing $Section.Port."
    }
    $port = 0
    if (-not [int]::TryParse([string]$sectionConfig['Port'], [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Production stack config '$ConfigPath' has an invalid $Section.Port value."
    }
    return $port
}

function Get-CpaStackProductionRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProductionStateHome,
        [AllowEmptyString()][string]$EnvironmentRoot = $env:CPA_STACK_ROOT
    )

    $stateHome = Assert-CpaStackGuardPathTraversalSafe -Path $ProductionStateHome -Role 'Production state home'
    $locatorPath = Join-Path $stateHome 'root.json'
    try {
        $locatorExists = Test-Path -LiteralPath $locatorPath -ErrorAction Stop
    } catch {
        throw "Could not determine whether the production root locator exists at '$locatorPath': $($_.Exception.Message)"
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    if ($locatorExists) {
        if (-not (Test-Path -LiteralPath $locatorPath -PathType Leaf -ErrorAction Stop)) {
            throw "Production root locator is not a file: $locatorPath"
        }
        try {
            $locatorText = Get-Content -LiteralPath $locatorPath -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($locatorText)) { throw 'The locator is empty.' }
            $locator = $locatorText | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Production root locator '$locatorPath' could not be parsed: $($_.Exception.Message)"
        }
        if ($null -eq $locator -or
            $null -eq $locator.PSObject.Properties['schemaVersion'] -or
            [string]$locator.schemaVersion -ne '1' -or
            $null -eq $locator.PSObject.Properties['root'] -or
            [string]::IsNullOrWhiteSpace([string]$locator.root)) {
            throw "Production root locator is invalid: $locatorPath"
        }
        if (-not [System.IO.Path]::IsPathRooted([string]$locator.root)) {
            throw "Production root locator must contain an absolute root path: $locatorPath"
        }
        try {
            $roots.Add((Assert-CpaStackGuardPathTraversalSafe -Path ([string]$locator.root) -Role 'Registered production root'))
        } catch {
            throw "Production root locator '$locatorPath' contains an invalid root path: $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentRoot)) {
        if (-not [System.IO.Path]::IsPathRooted($EnvironmentRoot)) {
            throw 'CPA_STACK_ROOT must be an absolute path before production tests can run.'
        }
        try {
            $normalizedEnvironmentRoot = Assert-CpaStackGuardPathTraversalSafe -Path $EnvironmentRoot -Role 'CPA_STACK_ROOT'
        } catch {
            throw "CPA_STACK_ROOT is invalid: $($_.Exception.Message)"
        }
        if ($normalizedEnvironmentRoot -notin @($roots)) { $roots.Add($normalizedEnvironmentRoot) }
    }

    $configuredPorts = [System.Collections.Generic.List[int]]::new()
    $configPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @($roots)) {
        try {
            $rootExists = Test-Path -LiteralPath $root -PathType Container -ErrorAction Stop
        } catch {
            throw "Could not verify registered production root '$root': $($_.Exception.Message)"
        }
        if (-not $rootExists) {
            throw "Registered production root does not exist or is not a directory: $root"
        }

        $configPath = Join-Path $root 'config\stack.psd1'
        try {
            $configExists = Test-Path -LiteralPath $configPath -ErrorAction Stop
        } catch {
            throw "Could not determine whether the production stack config exists at '$configPath': $($_.Exception.Message)"
        }
        if (-not $configExists) { throw "Production stack config is missing: $configPath" }
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf -ErrorAction Stop)) {
            throw "Production stack config is not a file: $configPath"
        }
        try {
            $config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop
        } catch {
            throw "Production stack config '$configPath' could not be parsed: $($_.Exception.Message)"
        }
        if (-not ($config -is [System.Collections.IDictionary])) {
            throw "Production stack config is invalid: $configPath"
        }
        foreach ($port in @(
            (Get-CpaStackRequiredProductionPort -Config $config -Section 'Cpa' -ConfigPath $configPath),
            (Get-CpaStackRequiredProductionPort -Config $config -Section 'Manager' -ConfigPath $configPath)
        )) {
            if ([int]$port -notin @($configuredPorts)) { $configuredPorts.Add([int]$port) }
        }
        $configPaths.Add($configPath)
    }

    return [pscustomobject]@{
        PSTypeName = 'CpaStack.ProductionRegistration'
        Registered = ($roots.Count -gt 0)
        LocatorPath = $locatorPath
        LocatorPresent = [bool]$locatorExists
        EnvironmentRootPresent = (-not [string]::IsNullOrWhiteSpace($EnvironmentRoot))
        Roots = @($roots)
        ConfigPaths = @($configPaths)
        ConfiguredPorts = @($configuredPorts | Sort-Object -Unique)
        ProtectedPorts = @($script:CpaStackPermanentProductionPorts + @($configuredPorts) | Sort-Object -Unique)
    }
}

function New-CpaStackProductionGuard {
    [CmdletBinding()]
    param(
        [string[]]$ProductionRoot = @(),
        [string[]]$ProductionStateHome = @(),
        [int[]]$ProductionPort = @(),
        [int[]]$ProductionProcessId = @(),
        [object[]]$ListenerSnapshot = @()
    )

    if (-not $PSBoundParameters.ContainsKey('ListenerSnapshot')) {
        $ListenerSnapshot = @(Get-CpaStackListenerSnapshot)
    } else {
        $ListenerSnapshot = @($ListenerSnapshot | ForEach-Object { ConvertTo-CpaStackListenerMetadata -Listener $_ })
    }

    $protectedPorts = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($port in @($script:CpaStackPermanentProductionPorts) + @($ProductionPort)) {
        if ($port -lt 1 -or $port -gt 65535) {
            throw "Production port is outside the valid TCP range: $port"
        }
        [void]$protectedPorts.Add([int]$port)
    }

    $protectedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($processId in @($ProductionProcessId)) {
        if ($processId -lt 1) {
            throw "Production process id must be positive: $processId"
        }
        [void]$protectedProcessIds.Add([int]$processId)
    }
    foreach ($listener in @($ListenerSnapshot)) {
        if ($null -eq $listener -or $null -eq $listener.PSObject.Properties['LocalPort']) { continue }
        if (-not $protectedPorts.Contains([int]$listener.LocalPort)) { continue }
        if ($null -ne $listener.PSObject.Properties['OwningProcess'] -and [int]$listener.OwningProcess -gt 0) {
            [void]$protectedProcessIds.Add([int]$listener.OwningProcess)
        }
    }

    $protectedRoots = @($ProductionRoot | ForEach-Object {
            Assert-CpaStackGuardPathTraversalSafe -Path $_ -Role 'Production root'
        } | Sort-Object -Unique)
    $protectedStateHomes = @($ProductionStateHome | ForEach-Object {
            Assert-CpaStackGuardPathTraversalSafe -Path $_ -Role 'Production state home'
        } | Sort-Object -Unique)
    $allocatedPorts = [System.Collections.Generic.HashSet[int]]::new()
    Initialize-CpaStackProductionGuardNativeType
    $jobObject = [CpaStackUpdater.ProductionGuard.KillOnCloseJob]::new()
    $registeredProcesses = [System.Collections.ArrayList]::new()

    return [pscustomobject]@{
        PSTypeName = 'CpaStack.ProductionGuard'
        ProtectedRoots = $protectedRoots
        ProtectedStateHomes = $protectedStateHomes
        ProtectedPorts = @($protectedPorts | Sort-Object)
        ProtectedProcessIds = @($protectedProcessIds | Sort-Object)
        ListenerSnapshot = @($ListenerSnapshot)
        AllocatedPorts = $allocatedPorts
        JobObject = $jobObject
        RegisteredProcesses = $registeredProcesses
        Closed = $false
    }
}

function Assert-CpaStackTestIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][string]$TestRoot,
        [Parameter(Mandatory = $true)][string]$TestStateHome,
        [int[]]$TestPort = @(),
        [int[]]$TestProcessId = @()
    )

    if ([bool]$Guard.Closed) { throw 'The production guard is already closed.' }

    $normalizedTestRoot = Assert-CpaStackGuardPathTraversalSafe -Path $TestRoot -Role 'Test root'
    $normalizedTestStateHome = Assert-CpaStackGuardPathTraversalSafe -Path $TestStateHome -Role 'Test state home'
    foreach ($testPath in @($normalizedTestRoot, $normalizedTestStateHome)) {
        foreach ($protectedPath in @($Guard.ProtectedRoots) + @($Guard.ProtectedStateHomes)) {
            if (Test-CpaStackGuardPathOverlap -Left $testPath -Right $protectedPath) {
                throw "Test path '$testPath' overlaps protected path '$protectedPath'."
            }
        }
    }

    foreach ($port in @($TestPort)) {
        if ([int]$port -in @($Guard.ProtectedPorts)) {
            throw "Test isolation rejected protected port $port."
        }
    }
    foreach ($processId in @($TestProcessId)) {
        if ([int]$processId -in @($Guard.ProtectedProcessIds)) {
            throw "Test isolation rejected protected process id $processId."
        }
    }

    return [pscustomobject]@{
        Safe = $true
        TestRoot = $normalizedTestRoot
        TestStateHome = $normalizedTestStateHome
        TestPorts = @($TestPort)
        TestProcessIds = @($TestProcessId)
    }
}

function New-CpaStackTestPortPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [string[]]$Name = @('CpaFormal', 'CpaCandidate', 'ManagerFormal', 'ManagerCandidate')
    )

    if ([bool]$Guard.Closed) { throw 'The production guard is already closed.' }
    if (@($Name).Count -lt 1) { throw 'At least one test port role is required.' }
    $uniqueNames = @($Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($uniqueNames.Count -ne @($Name).Count) { throw 'Test port role names must be non-empty and unique.' }

    $protectedPorts = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($port in @($Guard.ProtectedPorts)) { [void]$protectedPorts.Add([int]$port) }
    $activePorts = Get-CpaStackActiveListenerPorts
    $random = [System.Random]::new(([BitConverter]::ToInt32([guid]::NewGuid().ToByteArray(), 0) -band 0x7fffffff))
    $reservations = [System.Collections.Generic.List[System.Net.Sockets.TcpListener]]::new()
    $selectedPorts = [System.Collections.Generic.List[int]]::new()
    try {
        foreach ($role in @($Name)) {
            $listener = $null
            for ($attempt = 0; $attempt -lt 512; $attempt++) {
                $candidate = $random.Next(49152, 65536)
                if ($protectedPorts.Contains($candidate) -or
                    $activePorts.Contains($candidate) -or
                    $Guard.AllocatedPorts.Contains($candidate) -or
                    $selectedPorts.Contains($candidate)) {
                    continue
                }

                $candidateListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidate)
                $candidateListener.ExclusiveAddressUse = $true
                try {
                    $candidateListener.Start()
                    $listener = $candidateListener
                    break
                } catch [System.Net.Sockets.SocketException] {
                    $candidateListener.Stop()
                    [void]$activePorts.Add($candidate)
                }
            }
            if ($null -eq $listener) { throw "Could not reserve a safe high loopback port for role '$role'." }
            $reservations.Add($listener)
            $selectedPorts.Add(([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)
        }

        $portMap = [ordered]@{}
        for ($index = 0; $index -lt $Name.Count; $index++) {
            $port = [int]$selectedPorts[$index]
            $portMap[[string]$Name[$index]] = $port
            [void]$Guard.AllocatedPorts.Add($port)
        }
        return [pscustomobject]@{
            PSTypeName = 'CpaStack.TestPortPlan'
            BindAddress = '127.0.0.1'
            Ports = [pscustomobject]$portMap
            AllPorts = @($selectedPorts)
        }
    } finally {
        foreach ($reservation in @($reservations)) { $reservation.Stop() }
    }
}

function Compare-CpaStackProductionListenerSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [object[]]$AfterSnapshot
    )

    if (-not $PSBoundParameters.ContainsKey('AfterSnapshot')) {
        $AfterSnapshot = @(Get-CpaStackListenerSnapshot)
    }
    $protectedPorts = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($port in @($Guard.ProtectedPorts)) { [void]$protectedPorts.Add([int]$port) }

    $before = @($Guard.ListenerSnapshot | ForEach-Object { ConvertTo-CpaStackListenerMetadata -Listener $_ } |
        Where-Object { $protectedPorts.Contains([int]$_.LocalPort) })
    $after = @($AfterSnapshot | ForEach-Object { ConvertTo-CpaStackListenerMetadata -Listener $_ } |
        Where-Object { $protectedPorts.Contains([int]$_.LocalPort) })

    $beforeMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($listener in $before) { $beforeMap[(ConvertTo-CpaStackListenerSignature -Listener $listener)] = $listener }
    $afterMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($listener in $after) { $afterMap[(ConvertTo-CpaStackListenerSignature -Listener $listener)] = $listener }

    $removed = @($beforeMap.Keys | Where-Object { -not $afterMap.ContainsKey($_) } | ForEach-Object { $beforeMap[$_] })
    $added = @($afterMap.Keys | Where-Object { -not $beforeMap.ContainsKey($_) } | ForEach-Object { $afterMap[$_] })
    return [pscustomobject]@{
        PSTypeName = 'CpaStack.ProductionListenerComparison'
        Unchanged = ($removed.Count -eq 0 -and $added.Count -eq 0)
        ProtectedPorts = @($Guard.ProtectedPorts)
        Before = $before
        After = $after
        Removed = $removed
        Added = $added
    }
}

function Register-CpaStackTestProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process
    )

    if ([bool]$Guard.Closed) { throw 'The production guard is already closed.' }
    $candidateIdentity = Get-CpaStackGuardProcessIdentity -Process $Process -Role 'candidate test'
    if ([int]$candidateIdentity.ProcessId -in @($Guard.ProtectedProcessIds)) {
        throw "Test isolation rejected protected process id $($candidateIdentity.ProcessId)."
    }

    for ($index = $Guard.RegisteredProcesses.Count - 1; $index -ge 0; $index--) {
        $registered = $Guard.RegisteredProcesses[$index]
        if ([int]$registered.ProcessId -ne [int]$candidateIdentity.ProcessId) { continue }

        $registeredProcess = $registered.Process
        $registeredProcessActive = $false
        if ($registeredProcess -is [System.Diagnostics.Process]) {
            try {
                [void]$registeredProcess.Handle
                $registeredProcessActive = -not $registeredProcess.HasExited
            } catch {
                $registeredProcessActive = $false
            }
        }

        if (-not $registeredProcessActive) {
            $Guard.RegisteredProcesses.RemoveAt($index)
            if ($registeredProcess -is [System.IDisposable]) { $registeredProcess.Dispose() }
            continue
        }

        $registeredIdentity = Get-CpaStackGuardProcessIdentity -Process $registeredProcess -Role 'registered test'
        $hasCompleteIdentity = (
            $null -ne $registered.PSObject.Properties['StartTimeUtcTicks'] -and
            $null -ne $registered.PSObject.Properties['ExecutablePath'] -and
            -not [string]::IsNullOrWhiteSpace([string]$registered.ExecutablePath)
        )
        if (-not $hasCompleteIdentity) {
            throw "Active test process registration for PID $($candidateIdentity.ProcessId) lacks complete identity metadata."
        }
        $recordedIdentity = [pscustomobject]@{
            ProcessId = [int]$registered.ProcessId
            StartTimeUtcTicks = [long]$registered.StartTimeUtcTicks
            ExecutablePath = ConvertTo-CpaStackGuardPath -Path ([string]$registered.ExecutablePath)
        }
        if (-not (Test-CpaStackGuardProcessIdentityEqual -Left $registeredIdentity -Right $recordedIdentity)) {
            throw "Active test process registration for PID $($candidateIdentity.ProcessId) has conflicting stored identity metadata."
        }
        if (Test-CpaStackGuardProcessIdentityEqual -Left $candidateIdentity -Right $recordedIdentity) {
            return [pscustomobject]@{
                Registered = $true
                ProcessId = [int]$candidateIdentity.ProcessId
                Mode = 'JobObject'
                AlreadyRegistered = $true
            }
        }
        throw "Active test process identity conflict for PID $($candidateIdentity.ProcessId); refusing PID-only registration reuse."
    }

    $trackedProcess = $null
    try {
        # The caller owns its Process object and may dispose it after normal cleanup.
        # Keep an independent fixed handle for guard shutdown and verification.
        $trackedProcess = Get-Process -Id ([int]$candidateIdentity.ProcessId) -ErrorAction Stop
        $trackedIdentity = Get-CpaStackGuardProcessIdentity -Process $trackedProcess -Role 'fixed tracked test'
        if (-not (Test-CpaStackGuardProcessIdentityEqual -Left $candidateIdentity -Right $trackedIdentity)) {
            throw ("The test process identity changed before guard registration. " +
                "Candidate=PID:$($candidateIdentity.ProcessId),Start:$($candidateIdentity.StartTimeUtcTicks),Exe:$($candidateIdentity.ExecutablePath); " +
                "Tracked=PID:$($trackedIdentity.ProcessId),Start:$($trackedIdentity.StartTimeUtcTicks),Exe:$($trackedIdentity.ExecutablePath)")
        }
        $Guard.JobObject.Assign($trackedProcess)
        [void]$Guard.RegisteredProcesses.Add([pscustomobject]@{
            ProcessId = [int]$trackedIdentity.ProcessId
            StartTimeUtcTicks = [long]$trackedIdentity.StartTimeUtcTicks
            ExecutablePath = [string]$trackedIdentity.ExecutablePath
            Process = $trackedProcess
        })
        $trackedProcess = $null
    } finally {
        if ($null -ne $trackedProcess) { $trackedProcess.Dispose() }
    }
    return [pscustomobject]@{
        Registered = $true
        ProcessId = [int]$candidateIdentity.ProcessId
        Mode = 'JobObject'
        AlreadyRegistered = $false
    }
}

function Close-CpaStackProductionGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Guard,
        [ValidateRange(0, 60000)][int]$WaitMilliseconds = 10000
    )

    if ([bool]$Guard.Closed) { return }
    $Guard.Closed = $true
    $Guard.JobObject.Dispose()
    foreach ($registered in @($Guard.RegisteredProcesses)) {
        $process = $registered.Process
        try {
            if ($process.HasExited) { continue }
            if (-not $process.WaitForExit($WaitMilliseconds)) {
                $process.Kill()
                if (-not $process.WaitForExit($WaitMilliseconds)) {
                    throw "Guard-owned test process $($registered.ProcessId) did not exit during cleanup."
                }
            }
        } finally {
            $process.Dispose()
        }
    }
}

Export-ModuleMember -Function @(
    'Get-CpaStackProductionRegistration',
    'New-CpaStackProductionGuard',
    'Assert-CpaStackTestIsolation',
    'New-CpaStackTestPortPlan',
    'Get-CpaStackListenerSnapshot',
    'Compare-CpaStackProductionListenerSnapshot',
    'Register-CpaStackTestProcess',
    'Close-CpaStackProductionGuard'
)
