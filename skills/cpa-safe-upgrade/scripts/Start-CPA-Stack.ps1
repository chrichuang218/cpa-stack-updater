#requires -Version 5.1

<#
.SYNOPSIS
Starts the canonical CPA stack without restarting already healthy services.

.DESCRIPTION
The default configuration contract is:

  config\stack.psd1
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
    Browser = @{
      Url = 'http://127.0.0.1:18317/management.html'
      Executable = '' # Optional; empty uses the default browser.
    }

  config\secrets.local.json
    {
      "cpaClientApiKey": "...",
      "cpaManagementKey": "...",
      "managerAdminKey": "..."
    }

Relative paths are resolved from the stack root, which is the parent of the
config directory. The secrets file must have protected inheritance and may be
read only by the current user, LocalSystem, and local Administrators.

The script deliberately does not stop an existing process. A listener owned by
the expected executable must also pass its health contract; otherwise startup
fails explicitly so a credential or configuration problem is not hidden by a
restart.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$SecretsPath,
    [switch]$NoBrowser,
    [System.IO.FileStream]$OperationLockHandle,
    [switch]$RecoveryMode,
    [scriptblock]$StartedProcessRegistration,
    [switch]$InProcess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$operationMutex = $null
$exitCode = 1
$failureMessage = $null

function Enter-StartupLock {
    $lockDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\locks'
    New-Item -ItemType Directory -Force -Path $lockDirectory | Out-Null
    $lockPath = Join-Path $lockDirectory 'CPAStackSafeOperation.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $metadata = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID`nstarted=$([DateTimeOffset]::Now.ToString('o'))`n")
            $stream.SetLength(0)
            $stream.Write($metadata, 0, $metadata.Length)
            $stream.Flush()
            return $stream
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'A CPA stack migration or upgrade is already running.'
            }
            Start-Sleep -Milliseconds 200
        }
    } while ($true)
}

function Get-RequiredMapValue {
    param(
        [System.Collections.IDictionary]$Map,
        [string]$Name,
        [string]$Context
    )

    if ($null -eq $Map -or -not $Map.Contains($Name)) {
        throw "Missing required setting '$Context.$Name'."
    }

    $value = $Map[$Name]
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "Setting '$Context.$Name' must not be empty."
    }

    return $value
}

function Get-OptionalMapValue {
    param(
        [System.Collections.IDictionary]$Map,
        [string]$Name,
        $DefaultValue
    )

    if ($null -eq $Map -or -not $Map.Contains($Name)) {
        return $DefaultValue
    }

    return $Map[$Name]
}

function Get-JsonPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-ConfiguredPath {
    param(
        [string]$StackRoot,
        [string]$Value
    )

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $StackRoot $Value))
}

function ConvertTo-Port {
    param(
        $Value,
        [string]$Context
    )

    try {
        $port = [int]$Value
    }
    catch {
        throw "Setting '$Context' must be an integer port."
    }

    if ($port -lt 1 -or $port -gt 65535) {
        throw "Setting '$Context' must be between 1 and 65535."
    }

    return $port
}

function Import-StackSettings {
    param([string]$Path)

    $absoluteConfigPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $absoluteConfigPath -PathType Leaf)) {
        throw "Stack configuration file does not exist: $absoluteConfigPath"
    }

    $config = Import-PowerShellDataFile -LiteralPath $absoluteConfigPath
    $schemaVersion = [int](Get-RequiredMapValue -Map $config -Name 'SchemaVersion' -Context 'Stack')
    if ($schemaVersion -ne 1) {
        throw "Unsupported stack configuration schema version: $schemaVersion"
    }

    $configDirectory = Split-Path -Parent $absoluteConfigPath
    if ((Split-Path -Leaf $configDirectory) -ieq 'config') {
        $stackRoot = Split-Path -Parent $configDirectory
    }
    else {
        $stackRoot = $configDirectory
    }

    $cpa = Get-RequiredMapValue -Map $config -Name 'Cpa' -Context 'Stack'
    $manager = Get-RequiredMapValue -Map $config -Name 'Manager' -Context 'Stack'
    $browser = Get-RequiredMapValue -Map $config -Name 'Browser' -Context 'Stack'

    $requestMonitoringEnabled = Get-RequiredMapValue -Map $manager -Name 'RequestMonitoringEnabled' -Context 'Manager'
    if ($requestMonitoringEnabled -isnot [bool]) {
        throw "Setting 'Manager.RequestMonitoringEnabled' must be a Boolean."
    }

    $browserExecutableValue = [string](Get-OptionalMapValue -Map $browser -Name 'Executable' -DefaultValue '')
    $browserExecutable = $null
    if (-not [string]::IsNullOrWhiteSpace($browserExecutableValue)) {
        $browserExecutable = Resolve-ConfiguredPath -StackRoot $stackRoot -Value $browserExecutableValue
    }

    return [pscustomobject]@{
        ConfigPath = $absoluteConfigPath
        StackRoot = $stackRoot
        StartupTimeoutSeconds = [int](Get-RequiredMapValue -Map $config -Name 'StartupTimeoutSeconds' -Context 'Stack')
        HttpTimeoutSeconds = [int](Get-RequiredMapValue -Map $config -Name 'HttpTimeoutSeconds' -Context 'Stack')
        Cpa = [pscustomobject]@{
            Executable = Resolve-ConfiguredPath -StackRoot $stackRoot -Value ([string](Get-RequiredMapValue -Map $cpa -Name 'Executable' -Context 'Cpa'))
            WorkingDirectory = Resolve-ConfiguredPath -StackRoot $stackRoot -Value ([string](Get-RequiredMapValue -Map $cpa -Name 'WorkingDirectory' -Context 'Cpa'))
            Config = Resolve-ConfiguredPath -StackRoot $stackRoot -Value ([string](Get-RequiredMapValue -Map $cpa -Name 'Config' -Context 'Cpa'))
            Port = ConvertTo-Port -Value (Get-RequiredMapValue -Map $cpa -Name 'Port' -Context 'Cpa') -Context 'Cpa.Port'
        }
        Manager = [pscustomobject]@{
            Executable = Resolve-ConfiguredPath -StackRoot $stackRoot -Value ([string](Get-RequiredMapValue -Map $manager -Name 'Executable' -Context 'Manager'))
            WorkingDirectory = Resolve-ConfiguredPath -StackRoot $stackRoot -Value ([string](Get-RequiredMapValue -Map $manager -Name 'WorkingDirectory' -Context 'Manager'))
            DataDirectory = Resolve-ConfiguredPath -StackRoot $stackRoot -Value ([string](Get-RequiredMapValue -Map $manager -Name 'DataDirectory' -Context 'Manager'))
            Port = ConvertTo-Port -Value (Get-RequiredMapValue -Map $manager -Name 'Port' -Context 'Manager') -Context 'Manager.Port'
            BindAddress = [string](Get-RequiredMapValue -Map $manager -Name 'BindAddress' -Context 'Manager')
            RequestMonitoringEnabled = [bool]$requestMonitoringEnabled
        }
        Browser = [pscustomobject]@{
            Url = [string](Get-RequiredMapValue -Map $browser -Name 'Url' -Context 'Browser')
            Executable = $browserExecutable
        }
    }
}

function Assert-CanonicalInstanceState {
    param($Settings)

    $root = [System.IO.Path]::GetFullPath([string]$Settings.StackRoot).TrimEnd('\')
    $expectedScript = Join-Path $root 'ops\Start-CPA-Stack.ps1'
    $actualScript = [System.IO.Path]::GetFullPath($PSCommandPath)
    $bundledScriptRoot = Split-Path -Parent $actualScript
    $bundledSkillRoot = Split-Path -Parent $bundledScriptRoot
    $isCanonicalScript = [string]::Equals($actualScript, [System.IO.Path]::GetFullPath($expectedScript), [System.StringComparison]::OrdinalIgnoreCase)
    $isBundledScript = ((Split-Path -Leaf $bundledScriptRoot) -ieq 'scripts' -and
        (Test-Path -LiteralPath (Join-Path $bundledScriptRoot 'CpaStack.Common.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $bundledSkillRoot 'SKILL.md') -PathType Leaf))
    if (-not $isCanonicalScript -and -not $isBundledScript) {
        throw 'This start script is not running from the canonical ops slot.'
    }
    $rootItem = Get-Item -Force -LiteralPath $root
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The canonical stack root must not be a reparse point.'
    }
    $acl = Get-Acl -LiteralPath $root
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $ownerText = [string]$acl.Owner
        $ownerSid = if ($ownerText -match '^S-1-') {
            [System.Security.Principal.SecurityIdentifier]::new($ownerText).Value
        } else {
            [System.Security.Principal.NTAccount]::new($ownerText).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
    } catch {
        throw "The canonical stack root owner could not be verified: $($_.Exception.Message)"
    }
    if (-not $acl.AreAccessRulesProtected -or $ownerSid -ne $currentSid) {
        throw 'The canonical stack root ACL or owner is not protected for the current user.'
    }
    $allowedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($rule in $acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' }) {
        try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch { $sid = [string]$rule.IdentityReference }
        if ($allowedSids -notcontains $sid) {
            throw "The canonical stack root grants access to an unexpected identity: $sid"
        }
    }
    $markerPath = Join-Path $root '.cpa-stack-instance.json'
    $currentPath = Join-Path $root 'state\current.json'
    foreach ($path in @($markerPath, $currentPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Canonical instance state is missing: $path"
        }
    }
    foreach ($path in @(
        $markerPath,
        $currentPath,
        $Settings.ConfigPath,
        $expectedScript,
        (Join-Path $root 'runtime'),
        (Join-Path $root 'data'),
        $Settings.Cpa.WorkingDirectory,
        $Settings.Manager.WorkingDirectory,
        $Settings.Manager.DataDirectory,
        $Settings.Cpa.Executable,
        $Settings.Manager.Executable
    )) {
        $item = Get-Item -Force -LiteralPath $path
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A critical canonical path is a reparse point: $path"
        }
        $pathAcl = Get-Acl -LiteralPath $path
        $pathOwnerText = [string]$pathAcl.Owner
        try {
            $pathOwnerSid = if ($pathOwnerText -match '^S-1-') {
                [System.Security.Principal.SecurityIdentifier]::new($pathOwnerText).Value
            } else {
                [System.Security.Principal.NTAccount]::new($pathOwnerText).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
        } catch {
            throw "A critical canonical path owner could not be verified: $path"
        }
        if ($pathOwnerSid -ne $currentSid) {
            throw "A critical canonical path has an unexpected owner: $path"
        }
        foreach ($rule in $pathAcl.Access | Where-Object { $_.AccessControlType -eq 'Allow' }) {
            try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = [string]$rule.IdentityReference }
            if ($allowedSids -notcontains $sid) {
                throw "A critical canonical path grants access to an unexpected identity: $path ($sid)"
            }
        }
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $marker = [System.IO.File]::ReadAllText($markerPath, $utf8) | ConvertFrom-Json
    $current = [System.IO.File]::ReadAllText($currentPath, $utf8) | ConvertFrom-Json
    if ([string]$marker.instanceId -notmatch '^[0-9a-fA-F]{32}$' -or [string]$current.instanceId -ne [string]$marker.instanceId) {
        throw 'Canonical marker and current state instance ids do not match.'
    }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$marker.root).TrimEnd('\'), $root, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\'), $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Canonical marker or current state points to another root.'
    }
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'CPA'; SettingsPath = $Settings.Cpa.Executable; CurrentPath = [string]$current.cpa.executable; Hash = [string]$current.cpa.sha256 },
        [pscustomobject]@{ Name = 'Manager'; SettingsPath = $Settings.Manager.Executable; CurrentPath = [string]$current.manager.executable; Hash = [string]$current.manager.sha256 }
    )) {
        $settingsPath = [System.IO.Path]::GetFullPath([string]$entry.SettingsPath)
        if (-not $settingsPath.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$($entry.Name) executable is outside the canonical stack root."
        }
        if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$entry.SettingsPath), [System.IO.Path]::GetFullPath($entry.CurrentPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$($entry.Name) config path does not match current state."
        }
        if ($entry.Hash -notmatch '^[0-9A-Fa-f]{64}$' -or (Get-FileHash -Algorithm SHA256 -LiteralPath $entry.SettingsPath).Hash -ne $entry.Hash.ToUpperInvariant()) {
            throw "$($entry.Name) executable does not match current state."
        }
    }
    Assert-PrivateCpaTree -Root (Join-Path $Settings.Cpa.WorkingDirectory 'auth') -Description 'Canonical CPA auth'
    $pluginsRoot = Join-Path $Settings.Cpa.WorkingDirectory 'plugins'
    if (Test-Path -LiteralPath $pluginsRoot) {
        Assert-PrivateCpaTree -Root $pluginsRoot -Description 'Canonical CPA plugins'
    }
    Assert-PrivateCpaTree -Root $Settings.Manager.DataDirectory -Description 'Canonical Manager data' -AllowInheritedDescendants
}

function Assert-PrivateCpaTree {
    param(
        [string]$Root,
        [string]$Description,
        [switch]$AllowInheritedDescendants
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "$Description directory is missing."
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @($currentSid, 'S-1-5-18', 'S-1-5-32-544')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($rootFull)
    while ($queue.Count -gt 0) {
        $path = $queue.Dequeue()
        $item = Get-Item -Force -LiteralPath $path
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description tree contains a reparse point: $path"
        }
        $acl = Get-Acl -LiteralPath $path
        $isRoot = [string]::Equals([System.IO.Path]::GetFullPath($path).TrimEnd('\'), $rootFull, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $acl.AreAccessRulesProtected -and ($isRoot -or -not $AllowInheritedDescendants)) {
            throw "$Description ACL inheritance is enabled: $path"
        }
        try {
            $ownerSid = $acl.Owner
            if ($ownerSid -notmatch '^S-1-') {
                $ownerSid = ([System.Security.Principal.NTAccount]::new([string]$ownerSid)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
        } catch {
            throw "$Description owner could not be verified: $path"
        }
        $allowedOwnerSids = if ($AllowInheritedDescendants -and -not $isRoot) { $allowedSids } else { @($currentSid) }
        if ($allowedOwnerSids -notcontains [string]$ownerSid) {
            throw "$Description path has an unexpected owner: $path"
        }
        foreach ($rule in $acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' }) {
            try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
            catch { $sid = [string]$rule.IdentityReference }
            if ($allowedSids -notcontains $sid) {
                throw "$Description path grants access to an unexpected identity: $path"
            }
        }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -Force -LiteralPath $item.FullName) {
                $queue.Enqueue($child.FullName)
            }
        }
    }
}

function Assert-PositiveTimeouts {
    param($Settings)

    if ($Settings.StartupTimeoutSeconds -lt 1) {
        throw "Setting 'StartupTimeoutSeconds' must be positive."
    }
    if ($Settings.HttpTimeoutSeconds -lt 1) {
        throw "Setting 'HttpTimeoutSeconds' must be positive."
    }
}

function Assert-RequiredPaths {
    param($Settings)

    foreach ($file in @($Settings.Cpa.Executable, $Settings.Cpa.Config, $Settings.Manager.Executable)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Required file does not exist: $file"
        }
    }

    foreach ($directory in @($Settings.Cpa.WorkingDirectory, $Settings.Manager.WorkingDirectory, $Settings.Manager.DataDirectory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Required directory does not exist: $directory"
        }
    }
}

function Assert-CpaConfigPort {
    param(
        [string]$Path,
        [int]$ExpectedPort
    )

    $matches = @([System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false, $true)) | Where-Object { $_ -match '^port:\s*(\d+)\s*(?:#.*)?$' })
    if ($matches.Count -ne 1) {
        throw "CPA configuration must contain exactly one top-level numeric 'port' entry."
    }

    $null = $matches[0] -match '^port:\s*(\d+)'
    $actualPort = [int]$Matches[1]
    if ($actualPort -ne $ExpectedPort) {
        throw "CPA port mismatch: stack.psd1 expects $ExpectedPort but the CPA config uses $actualPort."
    }
}

function Get-SecretsAclAssessment {
    param([string]$Path)

    $issues = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $issues.Add('FileMissing')
        return [pscustomobject]@{ Protected = $false; Issues = @($issues) }
    }

    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        $issues.Add('InheritanceEnabled')
    }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    try {
        $ownerText = [string]$acl.Owner
        $ownerSid = if ($ownerText -match '^S-1-') {
            [System.Security.Principal.SecurityIdentifier]::new($ownerText).Value
        } else {
            [System.Security.Principal.NTAccount]::new($ownerText).Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        if ($ownerSid -ne $currentSid) { $issues.Add('UnexpectedOwner') }
    } catch {
        $issues.Add('UnresolvableOwner')
    }

    $allowedSids = @{}
    $allowedSids[$currentSid] = $true
    $allowedSids['S-1-5-18'] = $true
    $allowedSids['S-1-5-32-544'] = $true

    $readMask = [int64](
        [System.Security.AccessControl.FileSystemRights]::ReadData -bor
        [System.Security.AccessControl.FileSystemRights]::ReadAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::ReadExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::ReadPermissions
    )

    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            continue
        }

        try {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $issues.Add('UnresolvableAllowPrincipal')
            continue
        }

        $grantsRead = (([int64]$rule.FileSystemRights -band $readMask) -ne 0)
        if ($grantsRead -and -not $allowedSids.ContainsKey($sid)) {
            $issues.Add('UnexpectedReadPrincipal')
        }
    }

    return [pscustomobject]@{
        Protected = ($issues.Count -eq 0)
        Issues = @($issues | Select-Object -Unique)
    }
}

function Import-ProtectedSecrets {
    param([string]$Path)

    $assessment = Get-SecretsAclAssessment -Path $Path
    if (-not $assessment.Protected) {
        throw "Secrets ACL validation failed: $($assessment.Issues -join ', ')."
    }

    try {
        $secrets = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    }
    catch {
        throw "Secrets file is not valid JSON."
    }

    $values = @{}
    foreach ($name in @('cpaClientApiKey', 'cpaManagementKey', 'managerAdminKey')) {
        $value = Get-JsonPropertyValue -Object $secrets -Name $name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Secrets file is missing required non-empty string property '$name'."
        }
        $values[$name] = [string]$value
    }

    return $values
}

function Test-PathEqual {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd('\'),
        [System.IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Initialize-CpaStackNativeProcessType {
    if ($null -ne ('CpaStack.NativeProcessV1' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CpaStack
{
    public static class NativeProcessV1
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint ExtendedStartupInfoPresent = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint WaitObject0 = 0x00000000;
        private static readonly IntPtr ProcThreadAttributeHandleList = new IntPtr(0x00020002);

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public int Size;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public int Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx
        {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process;
            public IntPtr Thread;
            public uint ProcessId;
            public uint ThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            ref SecurityAttributes securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            int flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        private static SafeFileHandle OpenNull(uint access)
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.InheritHandle = true;
            SafeFileHandle handle = CreateFile(
                "NUL",
                access,
                FileShareRead | FileShareWrite | FileShareDelete,
                ref attributes,
                OpenExisting,
                FileAttributeNormal,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Could not open the Windows null device for managed-process isolation.");
            }
            return handle;
        }

        private static IntPtr BuildEnvironmentBlock(IDictionary environment, out int characterCount)
        {
            List<string> entries = new List<string>();
            foreach (DictionaryEntry entry in environment)
            {
                string name = Convert.ToString(entry.Key);
                string value = Convert.ToString(entry.Value);
                if (String.IsNullOrEmpty(name) || name.IndexOf('=') >= 0 || name.IndexOf('\0') >= 0 || value.IndexOf('\0') >= 0)
                {
                    throw new InvalidOperationException("Managed-process environment contains an invalid name or value.");
                }
                entries.Add(name + "=" + value);
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            StringBuilder block = new StringBuilder();
            foreach (string entry in entries)
            {
                block.Append(entry);
                block.Append('\0');
            }
            block.Append('\0');
            string text = block.ToString();
            characterCount = text.Length;
            return Marshal.StringToHGlobalUni(text);
        }

        private static void ZeroAndFreeEnvironment(IntPtr environment, int characterCount)
        {
            if (environment == IntPtr.Zero) { return; }
            for (int offset = 0; offset < characterCount * 2; offset += 2)
            {
                Marshal.WriteInt16(environment, offset, 0);
            }
            Marshal.FreeHGlobal(environment);
        }

        public static Process Start(string filePath, string arguments, string workingDirectory, IDictionary environment)
        {
            return Start(filePath, arguments, workingDirectory, environment, null);
        }

        public static Process Start(
            string filePath,
            string arguments,
            string workingDirectory,
            IDictionary environment,
            Action<Process> registerBeforeResume)
        {
            if (String.IsNullOrWhiteSpace(filePath) || filePath.IndexOf('"') >= 0)
            {
                throw new ArgumentException("Managed-process executable path is invalid.", "filePath");
            }
            if (String.IsNullOrWhiteSpace(workingDirectory))
            {
                throw new ArgumentException("Managed-process working directory is required.", "workingDirectory");
            }
            if (environment == null)
            {
                throw new ArgumentNullException("environment");
            }

            SafeFileHandle standardInput = null;
            SafeFileHandle standardOutput = null;
            SafeFileHandle standardError = null;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            int environmentCharacters = 0;
            ProcessInformation processInformation = new ProcessInformation();
            Process process = null;
            bool processCreated = false;
            bool processResumed = false;
            bool registrationAttempted = false;
            bool registrationCompleted = false;
            bool attributeListInitialized = false;

            try
            {
                standardInput = OpenNull(GenericRead);
                standardOutput = OpenNull(GenericWrite);
                standardError = OpenNull(GenericWrite);

                IntPtr attributeListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
                if (attributeListSize == IntPtr.Zero)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not size the managed-process handle list.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not initialize the managed-process handle list.");
                }
                attributeListInitialized = true;

                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, standardInput.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size, standardOutput.DangerousGetHandle());
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, standardError.DangerousGetHandle());
                if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributeHandleList,
                    handleList,
                    new IntPtr(IntPtr.Size * 3),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restrict managed-process inherited handles.");
                }

                environmentBlock = BuildEnvironmentBlock(environment, out environmentCharacters);
                StartupInfoEx startupInfo = new StartupInfoEx();
                startupInfo.StartupInfo.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                startupInfo.StartupInfo.Flags = (int)StartfUseStdHandles;
                startupInfo.StartupInfo.StandardInput = standardInput.DangerousGetHandle();
                startupInfo.StartupInfo.StandardOutput = standardOutput.DangerousGetHandle();
                startupInfo.StartupInfo.StandardError = standardError.DangerousGetHandle();
                startupInfo.AttributeList = attributeList;

                string command = "\"" + filePath + "\"";
                if (!String.IsNullOrWhiteSpace(arguments)) { command += " " + arguments; }
                StringBuilder commandLine = new StringBuilder(command);
                uint flags = CreateSuspended | CreateUnicodeEnvironment | ExtendedStartupInfoPresent | CreateNoWindow;
                if (!CreateProcess(
                    filePath,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    flags,
                    environmentBlock,
                    workingDirectory,
                    ref startupInfo,
                    out processInformation))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Managed process could not be started.");
                }
                processCreated = true;
                process = Process.GetProcessById((int)processInformation.ProcessId);
                IntPtr processHandle = process.Handle;
                if (registerBeforeResume != null)
                {
                    registrationAttempted = true;
                    registerBeforeResume(process);
                    registrationCompleted = true;
                }
                if (ResumeThread(processInformation.Thread) == UInt32.MaxValue)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Managed process could not be resumed.");
                }
                processResumed = true;
                return process;
            }
            catch (Exception startupError)
            {
                Exception cleanupError = null;
                if (processCreated && !processResumed && processInformation.Process != IntPtr.Zero)
                {
                    if (!TerminateProcess(processInformation.Process, 1))
                    {
                        cleanupError = new Win32Exception(Marshal.GetLastWin32Error(), "A suspended managed process could not be terminated after startup failed.");
                    }
                    else if (WaitForSingleObject(processInformation.Process, 5000) != WaitObject0)
                    {
                        cleanupError = new InvalidOperationException("A suspended managed process did not exit after startup failed.");
                    }
                }
                if (process != null) { process.Dispose(); }
                if (cleanupError != null)
                {
                    throw new AggregateException(
                        "Managed-process startup failed and suspended-process cleanup also failed.",
                        startupError,
                        cleanupError);
                }
                if (registrationAttempted && !registrationCompleted)
                {
                    throw new InvalidOperationException(
                        "Started-process registration failed; the exact suspended process was terminated before it could execute.",
                        startupError);
                }
                throw;
            }
            finally
            {
                ZeroAndFreeEnvironment(environmentBlock, environmentCharacters);
                if (processInformation.Thread != IntPtr.Zero) { CloseHandle(processInformation.Thread); }
                if (processInformation.Process != IntPtr.Zero) { CloseHandle(processInformation.Process); }
                if (attributeListInitialized) { DeleteProcThreadAttributeList(attributeList); }
                if (handleList != IntPtr.Zero) { Marshal.FreeHGlobal(handleList); }
                if (attributeList != IntPtr.Zero) { Marshal.FreeHGlobal(attributeList); }
                if (standardError != null) { standardError.Dispose(); }
                if (standardOutput != null) { standardOutput.Dispose(); }
                if (standardInput != null) { standardInput.Dispose(); }
            }
        }
    }
}
'@
}


function Start-ManagedProcess {
    param(
        [string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [scriptblock]$ProcessRegistration
    )

    $processEnvironment = @{}
    $allowedNames = @(
        'SystemRoot', 'WINDIR', 'COMSPEC', 'TEMP', 'TMP', 'PATH', 'PATHEXT',
        'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA',
        'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
        'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER',
        'NO_PROXY', 'no_proxy', 'SSL_CERT_FILE', 'SSL_CERT_DIR'
    )
    $allowedValues = @{}
    foreach ($name in $allowedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $allowedValues[$name] = $value }
    }
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $proxyUri = $null
        if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$proxyUri) -and
            $proxyUri.Scheme -in @('http', 'https', 'socks5') -and
            [string]::IsNullOrEmpty($proxyUri.UserInfo) -and
            [string]::IsNullOrEmpty($proxyUri.Query) -and
            [string]::IsNullOrEmpty($proxyUri.Fragment) -and
            -not [string]::IsNullOrWhiteSpace($proxyUri.Host)) {
            $allowedValues[$name] = $value
        }
    }
    foreach ($name in $allowedValues.Keys) {
        $processEnvironment[$name] = [string]$allowedValues[$name]
    }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) {
            [void]$processEnvironment.Remove($name)
        } else {
            $processEnvironment[$name] = [string]$Environment[$name]
        }
    }
    Initialize-CpaStackNativeProcessType
    if ($null -eq $ProcessRegistration) {
        return [CpaStack.NativeProcessV1]::Start($FilePath, $Arguments, $WorkingDirectory, $processEnvironment)
    }
    $registrationCallback = $ProcessRegistration
    $registrationScript = {
        param([System.Diagnostics.Process]$Process)
        & $registrationCallback $Process | Out-Null
    }.GetNewClosure()
    $registrationAction = [System.Action[System.Diagnostics.Process]]$registrationScript
    return [CpaStack.NativeProcessV1]::Start(
        $FilePath,
        $Arguments,
        $WorkingDirectory,
        $processEnvironment,
        $registrationAction)
}

function Get-ListenerProcess {
    param([int]$Port)

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    $processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($processIds.Count -eq 0) {
        return $null
    }
    if ($processIds.Count -ne 1) {
        throw "Port $Port has multiple listening process owners."
    }

    $processId = [int]$processIds[0]
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId"
    if ($null -eq $process -or [string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
        throw "Cannot resolve the executable path for the process listening on port $Port."
    }

    $addresses = @($connections | Select-Object -ExpandProperty LocalAddress -Unique)
    return [pscustomobject]@{
        ProcessId = $processId
        Name = $process.Name
        ExecutablePath = [System.IO.Path]::GetFullPath($process.ExecutablePath)
        LocalAddresses = $addresses
    }
}

function ConvertTo-NormalizedListenerAddress {
    param([string]$Value)

    $text = $Value.Trim().TrimStart('[').TrimEnd(']')
    $address = $null
    if ([System.Net.IPAddress]::TryParse($text, [ref]$address)) {
        return $address.ToString()
    }
    return $text.ToLowerInvariant()
}

function Resolve-AllowedListenerAddresses {
    param([string]$BindAddress)

    $value = $BindAddress.Trim().TrimStart('[').TrimEnd(']')
    if ($value -ieq 'localhost') {
        return @('127.0.0.1', '::1')
    }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed)) {
        if ($parsed.Equals([System.Net.IPAddress]::Any) -or $parsed.Equals([System.Net.IPAddress]::IPv6Any)) {
            return @('0.0.0.0', '::')
        }
        return @($parsed.ToString())
    }
    try {
        $resolved = @([System.Net.Dns]::GetHostAddresses($value) | ForEach-Object { $_.ToString() } | Select-Object -Unique)
    } catch {
        throw 'The configured bind hostname could not be resolved safely.'
    }
    if ($resolved.Count -eq 0) {
        throw 'The configured bind hostname resolved to no addresses.'
    }
    return $resolved
}

function Assert-TrustedListener {
    param(
        $Listener,
        [string]$ExpectedPath,
        [int]$ExpectedProcessId,
        [string[]]$AllowedAddresses
    )

    if ($null -eq $Listener) {
        throw 'The expected service has not opened its configured port.'
    }
    if (-not (Test-PathEqual -Left $Listener.ExecutablePath -Right $ExpectedPath) -or
        ($ExpectedProcessId -gt 0 -and $Listener.ProcessId -ne $ExpectedProcessId)) {
        throw 'The configured port is owned by an unexpected process.'
    }
    $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExpectedPath).Hash
    $listenerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Listener.ExecutablePath).Hash
    if ($listenerHash -ne $expectedHash) {
        throw 'The listener executable changed before credentialed validation.'
    }
    $allowed = @($AllowedAddresses | ForEach-Object { ConvertTo-NormalizedListenerAddress -Value ([string]$_) } | Where-Object { $_ })
    $actual = @($Listener.LocalAddresses | ForEach-Object { ConvertTo-NormalizedListenerAddress -Value ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
    if ($actual.Count -eq 0 -or @($actual | Where-Object { $allowed -notcontains $_ }).Count -gt 0) {
        throw 'The configured port is listening on an unauthorized address.'
    }
}

function Get-CpaAllowedAddresses {
    param([string]$ConfigPath)

    $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.UTF8Encoding]::new($false, $true))
    $match = [regex]::Match($content, '(?m)^host:\s*["'']?(?<host>[^"''#\s]+)')
    if (-not $match.Success) {
        throw 'CPA config must declare an explicit host.'
    }
    $hostValue = $match.Groups['host'].Value.Trim().TrimStart('[').TrimEnd(']')
    return @(Resolve-AllowedListenerAddresses -BindAddress $hostValue)
}

function Assert-NoDetachedExpectedProcess {
    param([string]$ExpectedPath)

    $name = [System.IO.Path]::GetFileName($ExpectedPath).Replace("'", "''")
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue)
    $matching = @($processes | Where-Object { Test-PathEqual -Left $_.ExecutablePath -Right $ExpectedPath })
    if ($matching.Count -gt 0) {
        throw "The expected executable is already running but is not listening on its configured port: $ExpectedPath"
    }
}

function Invoke-JsonProbe {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSeconds,
        [string]$Method = 'GET',
        $Body = $null
    )

    $parameters = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        TimeoutSec = $TimeoutSeconds
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $parameters['ContentType'] = 'application/json'
        $parameters['Body'] = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }

    try {
        $response = Invoke-WebRequest @parameters
        $json = $null
        $jsonValid = $false
        if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
            try {
                $json = $response.Content | ConvertFrom-Json
                $jsonValid = $true
            }
            catch {
                $jsonValid = $false
            }
        }

        return [pscustomobject]@{
            Reachable = $true
            StatusCode = [int]$response.StatusCode
            Json = $json
            JsonValid = $jsonValid
            ErrorKind = $null
        }
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            return [pscustomobject]@{
                Reachable = $true
                StatusCode = [int]$response.StatusCode
                Json = $null
                JsonValid = $false
                ErrorKind = 'HttpError'
            }
        }

        return [pscustomobject]@{
            Reachable = $false
            StatusCode = $null
            Json = $null
            JsonValid = $false
            ErrorKind = $_.Exception.GetType().Name
        }
    }
}

function Get-CpaHealth {
    param(
        $Settings,
        [string]$ApiKey
    )

    $uri = "http://127.0.0.1:$($Settings.Cpa.Port)/v1/models"
    $probe = Invoke-JsonProbe -Uri $uri -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSeconds $Settings.HttpTimeoutSeconds
    $models = Get-JsonPropertyValue -Object $probe.Json -Name 'data'
    $modelCount = if ($null -eq $models) { 0 } else { @($models).Count }

    return [pscustomobject]@{
        Uri = $uri
        Reachable = $probe.Reachable
        StatusCode = $probe.StatusCode
        ModelCount = $modelCount
        Healthy = ($probe.StatusCode -eq 200 -and $modelCount -gt 0)
        ErrorKind = $probe.ErrorKind
    }
}

function Wait-ForCpaHealth {
    param(
        $Settings,
        [string]$ApiKey,
        [int]$StartedProcessId
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Settings.StartupTimeoutSeconds)
    $lastProbe = $null
    $allowedAddresses = Get-CpaAllowedAddresses -ConfigPath $Settings.Cpa.Config
    do {
        if ($null -eq (Get-Process -Id $StartedProcessId -ErrorAction SilentlyContinue)) {
            throw "CPA process exited before becoming healthy."
        }

        $listener = Get-ListenerProcess -Port $Settings.Cpa.Port
        if ($null -eq $listener) {
            Start-Sleep -Milliseconds 500
            continue
        }
        Assert-TrustedListener -Listener $listener -ExpectedPath $Settings.Cpa.Executable -ExpectedProcessId $StartedProcessId -AllowedAddresses $allowedAddresses

        $lastProbe = Get-CpaHealth -Settings $Settings -ApiKey $ApiKey
        if ($lastProbe.Healthy) {
            Assert-TrustedListener -Listener (Get-ListenerProcess -Port $Settings.Cpa.Port) -ExpectedPath $Settings.Cpa.Executable -ExpectedProcessId $StartedProcessId -AllowedAddresses $allowedAddresses
            return [pscustomobject]@{ Listener = $listener; Health = $lastProbe }
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    $status = if ($null -eq $lastProbe.StatusCode) { 'no HTTP response' } else { "HTTP $($lastProbe.StatusCode)" }
    throw "CPA did not become healthy within $($Settings.StartupTimeoutSeconds) seconds ($status)."
}

function Ensure-CpaService {
    param(
        $Settings,
        [string]$ApiKey
    )

    $listener = Get-ListenerProcess -Port $Settings.Cpa.Port
    $allowedAddresses = Get-CpaAllowedAddresses -ConfigPath $Settings.Cpa.Config
    if ($null -ne $listener) {
        Assert-TrustedListener -Listener $listener -ExpectedPath $Settings.Cpa.Executable -ExpectedProcessId $listener.ProcessId -AllowedAddresses $allowedAddresses

        $health = Get-CpaHealth -Settings $Settings -ApiKey $ApiKey
        Assert-TrustedListener -Listener (Get-ListenerProcess -Port $Settings.Cpa.Port) -ExpectedPath $Settings.Cpa.Executable -ExpectedProcessId $listener.ProcessId -AllowedAddresses $allowedAddresses
        if (-not $health.Healthy) {
            $status = if ($null -eq $health.StatusCode) { 'unreachable' } else { "HTTP $($health.StatusCode)" }
            throw "The expected CPA process is listening but failed its health contract ($status). It was not restarted."
        }

        return [pscustomobject]@{ Action = 'Reused'; ProcessId = $listener.ProcessId; Health = $health }
    }

    Assert-NoDetachedExpectedProcess -ExpectedPath $Settings.Cpa.Executable
    $arguments = '-config "{0}"' -f $Settings.Cpa.Config
    $process = Start-ManagedProcess -FilePath $Settings.Cpa.Executable -Arguments $arguments -WorkingDirectory $Settings.Cpa.WorkingDirectory -ProcessRegistration $StartedProcessRegistration

    try {
        $ready = Wait-ForCpaHealth -Settings $Settings -ApiKey $ApiKey -StartedProcessId $process.Id
        return [pscustomobject]@{ Action = 'Started'; ProcessId = $ready.Listener.ProcessId; Health = $ready.Health }
    }
    catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-ManagerInfo {
    param(
        $Settings,
        [string]$AdminKey
    )

    $baseUri = "http://127.0.0.1:$($Settings.Manager.Port)"
    $headers = @{ Authorization = "Bearer $AdminKey" }
    return Invoke-JsonProbe -Uri "$baseUri/usage-service/info" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds
}

function Invoke-ManagerSetup {
    param(
        $Settings,
        [hashtable]$Secrets
    )

    $uri = "http://127.0.0.1:$($Settings.Manager.Port)/setup"
    $headers = @{ Authorization = "Bearer $($Secrets.managerAdminKey)" }
    $body = [ordered]@{
        cpaBaseUrl = "http://127.0.0.1:$($Settings.Cpa.Port)"
        managementKey = $Secrets.cpaManagementKey
        requestMonitoringEnabled = $Settings.Manager.RequestMonitoringEnabled
        ensureUsageStatisticsEnabled = $true
        pollIntervalMs = 500
    }

    $probe = Invoke-JsonProbe -Uri $uri -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds -Method 'POST' -Body $body
    if ($probe.StatusCode -lt 200 -or $probe.StatusCode -ge 300) {
        $status = if ($null -eq $probe.StatusCode) { 'unreachable' } else { "HTTP $($probe.StatusCode)" }
        throw "Manager setup failed ($status)."
    }
}

function Get-ManagerReadiness {
    param(
        $Settings,
        [string]$AdminKey
    )

    $baseUri = "http://127.0.0.1:$($Settings.Manager.Port)"
    $headers = @{ Authorization = "Bearer $AdminKey" }
    $health = Invoke-JsonProbe -Uri "$baseUri/health" -Headers @{} -TimeoutSeconds $Settings.HttpTimeoutSeconds
    $info = Invoke-JsonProbe -Uri "$baseUri/usage-service/info" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds
    $usageConfig = Invoke-JsonProbe -Uri "$baseUri/usage-service/config" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds
    $status = Invoke-JsonProbe -Uri "$baseUri/status" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds

    $configured = [bool](Get-JsonPropertyValue -Object $info.Json -Name 'configured')
    $adminReady = [bool](Get-JsonPropertyValue -Object $info.Json -Name 'adminReady')
    $dataKeyReady = [bool](Get-JsonPropertyValue -Object $info.Json -Name 'dataKeyReady')
    $setupRequired = [bool](Get-JsonPropertyValue -Object $info.Json -Name 'setupRequired')
    $migrationStatus = [string](Get-JsonPropertyValue -Object $info.Json -Name 'migrationStatus')

    $configObject = Get-JsonPropertyValue -Object $usageConfig.Json -Name 'config'
    $cpaConnection = Get-JsonPropertyValue -Object $configObject -Name 'cpaConnection'
    $cpaBaseUrl = [string](Get-JsonPropertyValue -Object $cpaConnection -Name 'cpaBaseUrl')
    $expectedCpaBaseUrl = "http://127.0.0.1:$($Settings.Cpa.Port)"
    $cpaBaseUrlMatches = ($cpaBaseUrl -eq $expectedCpaBaseUrl)
    $collectorConfig = Get-JsonPropertyValue -Object $configObject -Name 'collector'
    $collectorEnabledValue = Get-JsonPropertyValue -Object $collectorConfig -Name 'enabled'
    $collectorMatches = ($collectorEnabledValue -is [bool] -and [bool]$collectorEnabledValue -eq $Settings.Manager.RequestMonitoringEnabled)

    $statusCollector = Get-JsonPropertyValue -Object $status.Json -Name 'collector'
    $collectorState = [string](Get-JsonPropertyValue -Object $statusCollector -Name 'collector')
    $dbPath = [string](Get-JsonPropertyValue -Object $status.Json -Name 'dbPath')
    $expectedDbPath = Join-Path $Settings.Manager.DataDirectory 'usage.sqlite'
    $dbPathMatches = Test-PathEqual -Left $dbPath -Right $expectedDbPath
    $collectorStateMatches = (-not $Settings.Manager.RequestMonitoringEnabled -or $collectorState -eq 'running')

    $ready = (
        $health.StatusCode -eq 200 -and
        $info.StatusCode -eq 200 -and
        $usageConfig.StatusCode -eq 200 -and
        $status.StatusCode -eq 200 -and
        $configured -and
        $adminReady -and
        $dataKeyReady -and
        -not $setupRequired -and
        $migrationStatus -in @('ready', 'migrated') -and
        $cpaBaseUrlMatches -and
        $collectorMatches -and
        $collectorStateMatches -and
        $dbPathMatches
    )

    return [pscustomobject]@{
        Ready = $ready
        HealthStatusCode = $health.StatusCode
        InfoStatusCode = $info.StatusCode
        ConfigStatusCode = $usageConfig.StatusCode
        StatusStatusCode = $status.StatusCode
        SetupRequired = $setupRequired
        Configured = $configured
        AdminReady = $adminReady
        DataKeyReady = $dataKeyReady
        MigrationStatus = $migrationStatus
        CpaBaseUrl = $cpaBaseUrl
        CpaBaseUrlMatches = $cpaBaseUrlMatches
        CollectorEnabled = $collectorEnabledValue
        CollectorState = $collectorState
        DbPathMatches = $dbPathMatches
    }
}

function Ensure-ManagerConfigured {
    param(
        $Settings,
        [hashtable]$Secrets
    )

    $info = Get-ManagerInfo -Settings $Settings -AdminKey $Secrets.managerAdminKey
    if ($info.StatusCode -ne 200) {
        $status = if ($null -eq $info.StatusCode) { 'unreachable' } else { "HTTP $($info.StatusCode)" }
        throw "Manager usage service is not accessible with the configured admin key ($status)."
    }

    $initialReadiness = Get-ManagerReadiness -Settings $Settings -AdminKey $Secrets.managerAdminKey
    $collectorNeedsUpdate = ($initialReadiness.CollectorEnabled -isnot [bool] -or [bool]$initialReadiness.CollectorEnabled -ne $Settings.Manager.RequestMonitoringEnabled)
    $needsSetup = ($initialReadiness.SetupRequired -or -not $initialReadiness.Configured -or -not $initialReadiness.CpaBaseUrlMatches -or $collectorNeedsUpdate)
    if ($needsSetup) {
        Invoke-ManagerSetup -Settings $Settings -Secrets $Secrets
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($Settings.StartupTimeoutSeconds)
    $last = $null
    do {
        $last = Get-ManagerReadiness -Settings $Settings -AdminKey $Secrets.managerAdminKey
        if ($last.Ready) {
            return $last
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Manager did not satisfy its readiness contract within $($Settings.StartupTimeoutSeconds) seconds."
}

function Start-ManagerProcess {
    param(
        $Settings,
        [string]$AdminKey
    )

    $environment = [ordered]@{
        HTTP_ADDR = "$($Settings.Manager.BindAddress):$($Settings.Manager.Port)"
        USAGE_DATA_DIR = $Settings.Manager.DataDirectory
        USAGE_DB_PATH = (Join-Path $Settings.Manager.DataDirectory 'usage.sqlite')
        CPA_MANAGER_ADMIN_KEY = $AdminKey
        PANEL_PATH = $null
    }
    return Start-ManagedProcess -FilePath $Settings.Manager.Executable -WorkingDirectory $Settings.Manager.WorkingDirectory -Environment $environment -ProcessRegistration $StartedProcessRegistration
}

function Wait-ForManagerListener {
    param(
        $Settings,
        [int]$StartedProcessId
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Settings.StartupTimeoutSeconds)
    $allowedAddresses = @(Resolve-AllowedListenerAddresses -BindAddress ([string]$Settings.Manager.BindAddress))
    do {
        if ($null -eq (Get-Process -Id $StartedProcessId -ErrorAction SilentlyContinue)) {
            throw "Manager process exited before opening its configured port."
        }

        $listener = Get-ListenerProcess -Port $Settings.Manager.Port
        if ($null -ne $listener) {
            Assert-TrustedListener -Listener $listener -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $StartedProcessId -AllowedAddresses $allowedAddresses

            $health = Invoke-JsonProbe -Uri "http://127.0.0.1:$($Settings.Manager.Port)/health" -Headers @{} -TimeoutSeconds $Settings.HttpTimeoutSeconds
            if ($health.StatusCode -eq 200) {
                Assert-TrustedListener -Listener (Get-ListenerProcess -Port $Settings.Manager.Port) -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $StartedProcessId -AllowedAddresses $allowedAddresses
                return $listener
            }
        }

        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Manager did not open a healthy endpoint within $($Settings.StartupTimeoutSeconds) seconds."
}

function Ensure-ManagerService {
    param(
        $Settings,
        [hashtable]$Secrets
    )

    $listener = Get-ListenerProcess -Port $Settings.Manager.Port
    $allowedAddresses = @(Resolve-AllowedListenerAddresses -BindAddress ([string]$Settings.Manager.BindAddress))
    if ($null -ne $listener) {
        Assert-TrustedListener -Listener $listener -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $listener.ProcessId -AllowedAddresses $allowedAddresses

        $health = Invoke-JsonProbe -Uri "http://127.0.0.1:$($Settings.Manager.Port)/health" -Headers @{} -TimeoutSeconds $Settings.HttpTimeoutSeconds
        if ($health.StatusCode -ne 200) {
            $status = if ($null -eq $health.StatusCode) { 'unreachable' } else { "HTTP $($health.StatusCode)" }
            throw "The expected Manager process is listening but failed its health endpoint ($status). It was not restarted."
        }

        Assert-TrustedListener -Listener (Get-ListenerProcess -Port $Settings.Manager.Port) -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $listener.ProcessId -AllowedAddresses $allowedAddresses
        $readiness = Ensure-ManagerConfigured -Settings $Settings -Secrets $Secrets
        Assert-TrustedListener -Listener (Get-ListenerProcess -Port $Settings.Manager.Port) -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $listener.ProcessId -AllowedAddresses $allowedAddresses
        return [pscustomobject]@{ Action = 'Reused'; ProcessId = $listener.ProcessId; Readiness = $readiness }
    }

    Assert-NoDetachedExpectedProcess -ExpectedPath $Settings.Manager.Executable
    $process = Start-ManagerProcess -Settings $Settings -AdminKey $Secrets.managerAdminKey
    try {
        $listener = Wait-ForManagerListener -Settings $Settings -StartedProcessId $process.Id
        Assert-TrustedListener -Listener $listener -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $process.Id -AllowedAddresses $allowedAddresses
        $readiness = Ensure-ManagerConfigured -Settings $Settings -Secrets $Secrets
        Assert-TrustedListener -Listener (Get-ListenerProcess -Port $Settings.Manager.Port) -ExpectedPath $Settings.Manager.Executable -ExpectedProcessId $process.Id -AllowedAddresses $allowedAddresses
        return [pscustomobject]@{ Action = 'Started'; ProcessId = $listener.ProcessId; Readiness = $readiness }
    }
    catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Open-ManagerBrowser {
    param($Settings)

    $uri = $null
    if (-not [Uri]::TryCreate($Settings.Browser.Url, [UriKind]::Absolute, [ref]$uri)) {
        throw "Browser.Url is not a valid absolute URI."
    }
    if ($uri.Scheme -notin @('http', 'https') -or -not $uri.IsLoopback) {
        throw 'Browser.Url must use HTTP(S) on a loopback address.'
    }

    if ($null -ne $Settings.Browser.Executable) {
        if (-not (Test-Path -LiteralPath $Settings.Browser.Executable -PathType Leaf)) {
            throw "Configured browser executable does not exist: $($Settings.Browser.Executable)"
        }
        Start-Process -FilePath $Settings.Browser.Executable -ArgumentList @($Settings.Browser.Url) | Out-Null
    }
    else {
        Start-Process -FilePath $Settings.Browser.Url | Out-Null
    }
}

try {
    $recoveryAuthorized = $false
    if ($null -ne $StartedProcessRegistration -and -not $InProcess) {
        throw '-StartedProcessRegistration is reserved for in-process callers.'
    }
    if ($null -ne $OperationLockHandle) {
        if (-not $InProcess -or -not $RecoveryMode) {
            throw '-OperationLockHandle is reserved for in-process recovery transactions.'
        }
        $expectedLockPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CPAStack\locks\CPAStackSafeOperation.lock'
        if ($OperationLockHandle.SafeFileHandle.IsClosed -or -not $OperationLockHandle.CanRead -or -not $OperationLockHandle.CanWrite -or
            -not [string]::Equals([System.IO.Path]::GetFullPath($OperationLockHandle.Name), [System.IO.Path]::GetFullPath($expectedLockPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The supplied CPA stack operation lock handle is invalid.'
        }
        $recoveryAuthorized = $true
    } elseif ($RecoveryMode) {
        throw '-RecoveryMode requires a live in-process operation lock handle.'
    } else {
        $operationMutex = Enter-StartupLock
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\stack.psd1'
    }

    $settings = Import-StackSettings -Path $ConfigPath
    Assert-CanonicalInstanceState -Settings $settings
    if (-not $recoveryAuthorized) {
        $pending = @(Get-ChildItem -LiteralPath (Join-Path $settings.StackRoot 'state') -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
        if ($pending.Count -gt 0) {
            throw "An interrupted CPA stack transaction must be recovered before startup: $($pending.Name -join ', ')"
        }
    }
    Assert-PositiveTimeouts -Settings $settings
    Assert-RequiredPaths -Settings $settings
    Assert-CpaConfigPort -Path $settings.Cpa.Config -ExpectedPort $settings.Cpa.Port

    if ([string]::IsNullOrWhiteSpace($SecretsPath)) {
        $SecretsPath = Join-Path (Split-Path -Parent $settings.ConfigPath) 'secrets.local.json'
    }
    $SecretsPath = [System.IO.Path]::GetFullPath($SecretsPath)
    $secrets = Import-ProtectedSecrets -Path $SecretsPath

    $cpaResult = Ensure-CpaService -Settings $settings -ApiKey $secrets.cpaClientApiKey
    $managerResult = Ensure-ManagerService -Settings $settings -Secrets $secrets

    $browserAction = 'Skipped'
    if (-not $NoBrowser) {
        Open-ManagerBrowser -Settings $settings
        $browserAction = 'Opened'
    }

    [pscustomobject]@{
        Success = $true
        Cpa = [pscustomobject]@{
            Action = $cpaResult.Action
            ProcessId = $cpaResult.ProcessId
            Port = $settings.Cpa.Port
            Executable = $settings.Cpa.Executable
            ModelCount = $cpaResult.Health.ModelCount
        }
        Manager = [pscustomobject]@{
            Action = $managerResult.Action
            ProcessId = $managerResult.ProcessId
            Port = $settings.Manager.Port
            Executable = $settings.Manager.Executable
            DataDirectory = $settings.Manager.DataDirectory
            CollectorEnabled = $managerResult.Readiness.CollectorEnabled
            CollectorState = $managerResult.Readiness.CollectorState
        }
        Browser = $browserAction
    } | ConvertTo-Json -Depth 6
    $exitCode = 0
}
catch {
    $failureMessage = $_.Exception.Message
    [pscustomobject]@{
        Success = $false
        Error = [pscustomobject]@{
            Type = $_.Exception.GetType().FullName
            Message = $_.Exception.Message
        }
    } | ConvertTo-Json -Depth 4
    $exitCode = 1
}
finally {
    if ($operationMutex) {
        $operationMutex.Dispose()
    }
}

if ($InProcess) {
    if ($exitCode -ne 0) { throw $failureMessage }
    return
}
exit $exitCode
