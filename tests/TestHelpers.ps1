Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -cne [string]$Actual) {
        throw "Assertion failed: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "Assertion failed: $Message" }
}

function Assert-ThrowsMatch {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    try {
        & $Action
    } catch {
        if ([string]$_.Exception.Message -notmatch $Pattern) {
            throw "Assertion failed: $Message. Expected error matching=[$Pattern] Actual=[$($_.Exception.Message)]"
        }
        return
    }
    throw "Assertion failed: $Message. Expected an exception."
}

function Remove-TestPathWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 10,
        [int]$DelayMilliseconds = 250
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq $Attempts) { throw }
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
}

function New-CpaStackUpdaterTestFixture {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRepository,
        [Parameter(Mandatory = $true)][string]$DestinationRepository,
        [Parameter(Mandatory = $true)][string]$LocalAppDataRoot
    )

    $sourceFull = [System.IO.Path]::GetFullPath($SourceRepository).TrimEnd('\')
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationRepository).TrimEnd('\')
    $localAppDataFull = [System.IO.Path]::GetFullPath($LocalAppDataRoot).TrimEnd('\')
    if (Test-Path -LiteralPath $destinationFull) {
        throw "Test fixture repository already exists: $destinationFull"
    }

    New-Item -ItemType Directory -Path $destinationFull | Out-Null
    New-Item -ItemType Directory -Force -Path $localAppDataFull | Out-Null
    foreach ($name in @('install.ps1', 'uninstall.ps1', 'VERSION')) {
        Copy-Item -LiteralPath (Join-Path $sourceFull $name) -Destination (Join-Path $destinationFull $name)
    }
    Copy-Item -LiteralPath (Join-Path $sourceFull 'skills') -Destination (Join-Path $destinationFull 'skills') -Recurse

    $folderLookup = "[Environment]::GetFolderPath('LocalApplicationData')"
    $escapedRoot = $localAppDataFull.Replace("'", "''")
    $replacement = "'$escapedRoot'"
    $changedFiles = 0
    $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    foreach ($script in Get-ChildItem -LiteralPath $destinationFull -Recurse -File -Filter '*.ps1') {
        $content = [System.IO.File]::ReadAllText($script.FullName, $strictUtf8)
        if ($content.IndexOf($folderLookup, [System.StringComparison]::Ordinal) -lt 0) {
            continue
        }
        $content = $content.Replace($folderLookup, $replacement)
        [System.IO.File]::WriteAllText($script.FullName, $content, $utf8NoBom)
        $changedFiles++
    }
    if ($changedFiles -eq 0) {
        throw 'The test fixture did not isolate any LocalApplicationData lookup.'
    }

    return [pscustomobject]@{
        Repository = $destinationFull
        LocalAppData = $localAppDataFull
    }
}

function Open-TestDirectoryWithoutDeleteShare {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($null -eq ('CpaStackUpdater.Tests.NativeDirectoryHandle' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CpaStackUpdater.Tests
{
    public static class NativeDirectoryHandle
    {
        private const uint GenericRead = 0x80000000;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        public static SafeFileHandle Open(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                GenericRead,
                FileShare.Read | FileShare.Write,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            return handle;
        }
    }
}
'@
    }

    return [CpaStackUpdater.Tests.NativeDirectoryHandle]::Open([System.IO.Path]::GetFullPath($Path))
}
