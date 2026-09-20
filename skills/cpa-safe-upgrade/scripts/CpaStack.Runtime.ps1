#requires -Version 7.0
# Shared primitives only: importing this file must not start or inspect services.

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
