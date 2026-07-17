#requires -Version 5.1

<#
.SYNOPSIS
Returns a read-only, secret-free JSON snapshot of the canonical CPA stack.

.DESCRIPTION
Reads config\stack.psd1 and the ACL-protected config\secrets.local.json using
the same contract as Start-CPA-Stack.ps1. Secret values are used only as HTTP
authorization headers and are never included in the output.

Exit code is 0 only when both services, their paths, the secrets ACL, and the
Manager data/collector contract are healthy. All other states still emit one
JSON document and exit 1.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$SecretsPath,
    [string]$ControlRoot,
    [ValidateSet('cpa', 'manager')][string]$PendingSwitchComponent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CpaStack.Common.ps1')
$ControlRoot = Resolve-CpaStackControlRoot -RequestedRoot $ControlRoot

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

    $allowedSids = @{}
    $allowedSids[[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value] = $true
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

function Get-SecretsState {
    param([string]$Path)

    $acl = Get-SecretsAclAssessment -Path $Path
    $requiredFields = [ordered]@{
        cpaClientApiKey = $false
        cpaManagementKey = $false
        managerAdminKey = $false
    }
    $values = $null
    $parseOk = $false

    if ($acl.Protected) {
        try {
            $jsonText = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
            $json = $jsonText | ConvertFrom-Json
            $values = @{}
            foreach ($name in @($requiredFields.Keys)) {
                $value = Get-JsonPropertyValue -Object $json -Name $name
                $present = ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value))
                $requiredFields[$name] = $present
                if ($present) {
                    $values[$name] = [string]$value
                }
            }
            $parseOk = $true
        }
        catch {
            $parseOk = $false
            $values = $null
        }
    }

    $allFieldsPresent = -not (@($requiredFields.Values | Where-Object { -not $_ }).Count -gt 0)
    return [pscustomobject]@{
        Safe = [pscustomobject]@{
            Path = $Path
            Exists = (Test-Path -LiteralPath $Path -PathType Leaf)
            AclProtected = $acl.Protected
            AclIssues = @($acl.Issues)
            JsonValid = $parseOk
            RequiredFieldsPresent = [pscustomobject]$requiredFields
            Ready = ($acl.Protected -and $parseOk -and $allFieldsPresent)
        }
        Values = $values
    }
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

function Get-ListenerProcesses {
    param([int]$Port)

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    $processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
    $records = @()
    foreach ($processId in $processIds) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue
        $records += [pscustomobject]@{
            ProcessId = [int]$processId
            Name = if ($null -eq $process) { $null } else { $process.Name }
            ExecutablePath = if ($null -eq $process) { $null } else { $process.ExecutablePath }
            LocalAddresses = @($connections | Where-Object { $_.OwningProcess -eq $processId } | Select-Object -ExpandProperty LocalAddress -Unique)
        }
    }

    return @($records)
}

function Resolve-ExpectedListenerAddresses {
    param([string]$BindAddress)

    if ([string]::IsNullOrWhiteSpace($BindAddress)) { return @() }
    $value = $BindAddress.Trim().TrimStart('[').TrimEnd(']')
    if ($value -ieq 'localhost') { return @('127.0.0.1', '::1') }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed)) {
        if ($parsed.Equals([System.Net.IPAddress]::Any) -or $parsed.Equals([System.Net.IPAddress]::IPv6Any)) {
            return @('0.0.0.0', '::')
        }
        return @($parsed.ToString())
    }
    try {
        return @([System.Net.Dns]::GetHostAddresses($value) | ForEach-Object { $_.ToString() } | Select-Object -Unique)
    } catch {
        return @()
    }
}

function Test-ListenerAddresses {
    param($Listener, [string[]]$ExpectedAddresses)

    if ($null -eq $Listener -or $ExpectedAddresses.Count -eq 0) { return $false }
    $expected = @($ExpectedAddresses | ForEach-Object {
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse(([string]$_), [ref]$parsed)) { $parsed.ToString() } else { ([string]$_).ToLowerInvariant() }
    } | Select-Object -Unique)
    $actual = @($Listener.LocalAddresses | ForEach-Object {
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse(([string]$_), [ref]$parsed)) { $parsed.ToString() } else { ([string]$_).ToLowerInvariant() }
    } | Where-Object { $_ } | Select-Object -Unique)
    return ($actual.Count -gt 0 -and @($actual | Where-Object { $expected -notcontains $_ }).Count -eq 0)
}

function Get-TreeItemsNoReparse {
    param(
        [string]$Root,
        [string]$Description = 'Protected CPA stack'
    )

    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $items = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $queue.Enqueue([System.IO.Path]::GetFullPath($Root))
    while ($queue.Count -gt 0) {
        $path = $queue.Dequeue()
        $item = Get-Item -Force -LiteralPath $path
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description tree contains a reparse point: $path"
        }
        [void]$items.Add($item)
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -Force -LiteralPath $item.FullName) {
                $queue.Enqueue($child.FullName)
            }
        }
    }
    return @($items)
}

function Get-RootSecurityState {
    param([string]$StackRoot)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowedSids = @(
        $currentSid,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    $issues = @()
    $paths = @(
        $StackRoot,
        (Join-Path $StackRoot 'config'),
        (Join-Path $StackRoot 'ops'),
        (Join-Path $StackRoot 'state'),
        (Join-Path $StackRoot 'runtime'),
        (Join-Path $StackRoot 'data'),
        (Join-Path $StackRoot 'runtime\cli-proxy-api'),
        (Join-Path $StackRoot 'runtime\manager-plus'),
        (Join-Path $StackRoot 'data\manager-plus'),
        (Join-Path $StackRoot '.cpa-stack-instance.json'),
        (Join-Path $StackRoot 'config\secrets.local.json'),
        (Join-Path $StackRoot 'ops\Start-CPA-Stack.ps1'),
        (Join-Path $StackRoot 'state\current.json'),
        (Join-Path $StackRoot 'runtime\cli-proxy-api\cli-proxy-api.exe'),
        (Join-Path $StackRoot 'runtime\manager-plus\cpa-manager-plus.exe'),
        (Join-Path $StackRoot 'data\manager-plus\usage.sqlite'),
        (Join-Path $StackRoot 'data\manager-plus\data.key')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $authRoot = Join-Path $StackRoot 'runtime\cli-proxy-api\auth'
    if (Test-Path -LiteralPath $authRoot -PathType Container) {
        try {
            Assert-CpaStackPrivateTree -Root $authRoot -Description 'Protected CPA auth' -AllowInheritedDescendants
        } catch {
            $issues += $_.Exception.Message
        }
    } else {
        $issues += 'CPA auth directory is missing.'
    }
    $pluginPaths = @()
    $pluginsRoot = Join-Path $StackRoot 'runtime\cli-proxy-api\plugins'
    if (Test-Path -LiteralPath $pluginsRoot) {
        if (-not (Test-Path -LiteralPath $pluginsRoot -PathType Container)) {
            $issues += 'CPA plugins path is not a directory.'
        } else {
            try {
                $pluginPaths = @(Get-TreeItemsNoReparse -Root $pluginsRoot -Description 'Protected CPA plugins' | Select-Object -ExpandProperty FullName)
                $paths += $pluginPaths
            } catch {
                $issues += $_.Exception.Message
            }
        }
    }
    foreach ($path in $paths) {
        try {
            $item = Get-Item -Force -LiteralPath $path
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $issues += "Critical path is a reparse point: $path"
                continue
            }
            $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
            if ($path -ieq $StackRoot -and -not $acl.AreAccessRulesProtected) {
                $issues += 'Root ACL inheritance is enabled.'
            }
            if ($pluginPaths -icontains $path -and -not $acl.AreAccessRulesProtected) {
                $issues += "Private CPA tree ACL inheritance is enabled: $path"
            }
            $ownerText = [string]$acl.Owner
            try {
                $ownerSid = if ($ownerText -match '^S-1-') {
                    [System.Security.Principal.SecurityIdentifier]::new($ownerText).Value
                } else {
                    [System.Security.Principal.NTAccount]::new($ownerText).Translate([System.Security.Principal.SecurityIdentifier]).Value
                }
            } catch {
                $ownerSid = $ownerText
            }
            if ($ownerSid -ne $currentSid) {
                $issues += "Unexpected owner on critical path: $path ($ownerText)"
            }
            foreach ($rule in $acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' }) {
                try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
                catch { $sid = [string]$rule.IdentityReference }
                if ($allowedSids -notcontains $sid) {
                    $issues += "Unexpected allow rule on ${path}: $sid"
                }
            }
        } catch {
            $issues += "ACL inspection failed for ${path}: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        Protected = ($issues.Count -eq 0)
        Issues = @($issues)
    }
}

function Get-ManagerDataSecurityState {
    param([string]$DataRoot)

    $issues = @()
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
        $issues += 'Manager data directory is missing.'
    } else {
        try {
            Assert-CpaStackPrivateTree -Root $DataRoot -Description 'Manager data tree' -AllowInheritedDescendants
        } catch {
            $issues += $_.Exception.Message
        }
    }
    return [pscustomobject]@{
        Protected = ($issues.Count -eq 0)
        Issues = @($issues)
    }
}

function Get-CurrentIntegrityState {
    param(
        [string]$StackRoot,
        [System.Collections.IDictionary]$ExpectedExecutableHashes = @{}
    )

    $issues = @()
    $markerPath = Join-Path $StackRoot '.cpa-stack-instance.json'
    $currentPath = Join-Path $StackRoot 'state\current.json'
    $markerPresent = Test-Path -LiteralPath $markerPath -PathType Leaf
    $currentPresent = Test-Path -LiteralPath $currentPath -PathType Leaf
    $marker = $null
    $current = $null
    if (-not $markerPresent) { $issues += 'Instance marker is missing.' }
    if (-not $currentPresent) { $issues += 'Current state is missing.' }
    if ($markerPresent) {
        try {
            $marker = Read-CpaStackJson -Path $markerPath
            if ([System.IO.Path]::GetFullPath([string]$marker.root).TrimEnd('\') -ine [System.IO.Path]::GetFullPath($StackRoot).TrimEnd('\')) {
                $issues += 'Instance marker root mismatch.'
            }
        } catch { $issues += "Instance marker is unreadable: $($_.Exception.Message)" }
    }
    if ($currentPresent) {
        try {
            $current = Read-CpaStackJson -Path $currentPath
            if ([System.IO.Path]::GetFullPath([string]$current.canonicalRoot).TrimEnd('\') -ine [System.IO.Path]::GetFullPath($StackRoot).TrimEnd('\')) {
                $issues += 'Current state root mismatch.'
            }
            foreach ($component in @('cpa', 'manager')) {
                $entry = $current.$component
                if ($entry -and [string]$entry.executable -and [string]$entry.sha256) {
                    $expectedHash = [string]$entry.sha256
                    if ($ExpectedExecutableHashes.Contains($component)) {
                        $expectedHash = [string]$ExpectedExecutableHashes[$component]
                    }
                    $actual = Get-CpaStackFileHash -Path ([string]$entry.executable)
                    if ($actual -ne $expectedHash.ToUpperInvariant()) {
                        $issues += "$component executable hash mismatch."
                    }
                }
            }
        } catch { $issues += "Current state is unreadable: $($_.Exception.Message)" }
    }
    if ($marker -and $current) {
        $markerIdProperty = $marker.PSObject.Properties['instanceId']
        $currentIdProperty = $current.PSObject.Properties['instanceId']
        if ($null -eq $markerIdProperty -or [string]$markerIdProperty.Value -notmatch '^[0-9a-fA-F]{32}$') {
            $issues += 'Instance marker id is invalid.'
        } elseif ($null -eq $currentIdProperty) {
            $issues += 'Current state instance id is missing.'
        } elseif ([string]$currentIdProperty.Value -ne [string]$markerIdProperty.Value) {
            $issues += 'Current state instance mismatch.'
        }
    }
    return [pscustomobject]@{
        Ready = ($issues.Count -eq 0)
        MarkerPresent = $markerPresent
        CurrentPresent = $currentPresent
        Issues = @($issues)
    }
}

function Get-PendingSwitchProbeContext {
    param(
        [string]$StackRoot,
        [string]$Component,
        $Settings
    )

    $expectedHashes = @{}
    if ([string]::IsNullOrWhiteSpace($Component)) {
        return [pscustomobject]@{ ExpectedHashes = $expectedHashes }
    }

    $journalPath = Join-Path $StackRoot ("state\switch-$Component.pending.json")
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw "Pending $Component switch health validation requires its journal."
    }

    $otherComponent = if ($Component -eq 'cpa') { 'manager' } else { 'cpa' }
    $otherJournalPath = Join-Path $StackRoot ("state\switch-$otherComponent.pending.json")
    if (Test-Path -LiteralPath $otherJournalPath -PathType Leaf) {
        throw 'Pending switch health validation requires exactly one component journal.'
    }

    $journal = Read-CpaStackJson -Path $journalPath
    $current = Read-CpaStackJson -Path (Join-Path $StackRoot 'state\current.json')
    $marker = Read-CpaStackJson -Path (Join-Path $StackRoot '.cpa-stack-instance.json')
    $expectedOperation = "switch-$Component"
    if ([string]$journal.operation -cne $expectedOperation -or
        [string]$journal.phase -cne 'runtime-verified' -or
        [string]$journal.operationId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "Pending $Component switch journal is not ready for transition health validation."
    }
    if ([string]$journal.instanceId -notmatch '^[0-9a-fA-F]{32}$' -or
        [string]$journal.instanceId -cne [string]$current.instanceId -or
        [string]$journal.instanceId -cne [string]$marker.instanceId) {
        throw "Pending $Component switch journal belongs to a different stack instance."
    }

    $componentState = $current.$Component
    if ([string]$journal.oldHash -notmatch '^[0-9A-Fa-f]{64}$' -or
        [string]$journal.newHash -notmatch '^[0-9A-Fa-f]{64}$' -or
        [string]$componentState.sha256 -cne ([string]$journal.oldHash).ToUpperInvariant()) {
        throw "Pending $Component switch hashes do not match the recorded transition."
    }

    $expectedRuntime = if ($Component -eq 'cpa') { [string]$Settings.Cpa.WorkingDirectory } else { [string]$Settings.Manager.WorkingDirectory }
    if (-not (Test-PathEqual -Left ([string]$journal.targetRuntime) -Right $expectedRuntime)) {
        throw "Pending $Component switch targets an unexpected runtime."
    }
    if ($Component -eq 'manager' -and -not (Test-PathEqual -Left ([string]$journal.targetData) -Right ([string]$Settings.Manager.DataDirectory))) {
        throw 'Pending manager switch targets an unexpected data directory.'
    }

    $expectedHashes[$Component] = ([string]$journal.newHash).ToUpperInvariant()
    return [pscustomobject]@{ ExpectedHashes = $expectedHashes }
}

function Invoke-JsonProbe {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSeconds
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -Headers $Headers -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
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
            Attempted = $true
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
                Attempted = $true
                Reachable = $true
                StatusCode = [int]$response.StatusCode
                Json = $null
                JsonValid = $false
                ErrorKind = 'HttpError'
            }
        }

        return [pscustomobject]@{
            Attempted = $true
            Reachable = $false
            StatusCode = $null
            Json = $null
            JsonValid = $false
            ErrorKind = $_.Exception.GetType().Name
        }
    }
}

function New-UnattemptedProbe {
    return [pscustomobject]@{
        Attempted = $false
        Reachable = $false
        StatusCode = $null
        Json = $null
        JsonValid = $false
        ErrorKind = 'CredentialsUnavailable'
    }
}

function Get-CpaStatus {
    param(
        $Settings,
        $SecretsState,
        [string]$ExpectedHash,
        [bool]$TrustStateReady
    )

    $listeners = @(Get-ListenerProcesses -Port $Settings.Cpa.Port)
    $singleListener = if ($listeners.Count -eq 1) { $listeners[0] } else { $null }
    $pathMatches = ($null -ne $singleListener -and (Test-PathEqual -Left $singleListener.ExecutablePath -Right $Settings.Cpa.Executable))

    $configPort = $null
    $configHost = $null
    if (Test-Path -LiteralPath $Settings.Cpa.Config -PathType Leaf) {
        $configLines = [System.IO.File]::ReadAllLines($Settings.Cpa.Config, [System.Text.UTF8Encoding]::new($false, $true))
        $portLines = @($configLines | Where-Object { $_ -match '^port:\s*(\d+)\s*(?:#.*)?$' })
        if ($portLines.Count -eq 1) {
            $null = $portLines[0] -match '^port:\s*(\d+)'
            $configPort = [int]$Matches[1]
        }
        $hostLines = @($configLines | Where-Object { $_ -match '^host:\s*["'']?(?<host>[^"''#\s]+)' })
        if ($hostLines.Count -eq 1) {
            $null = $hostLines[0] -match '^host:\s*["'']?(?<host>[^"''#\s]+)'
            $configHost = [string]$Matches['host']
        }
    }
    $expectedAddresses = @(Resolve-ExpectedListenerAddresses -BindAddress $configHost)
    $addressMatches = Test-ListenerAddresses -Listener $singleListener -ExpectedAddresses $expectedAddresses
    $hashMatches = ($ExpectedHash -match '^[0-9A-Fa-f]{64}$' -and (Get-CpaStackFileHash -Path $Settings.Cpa.Executable) -eq $ExpectedHash.ToUpperInvariant())
    $listenerTrusted = ($pathMatches -and $addressMatches -and $hashMatches)

    $probe = New-UnattemptedProbe
    if ($TrustStateReady -and $SecretsState.Safe.Ready -and $listenerTrusted) {
        $probe = Invoke-JsonProbe -Uri "http://127.0.0.1:$($Settings.Cpa.Port)/v1/models" -Headers @{ Authorization = "Bearer $($SecretsState.Values.cpaClientApiKey)" } -TimeoutSeconds $Settings.HttpTimeoutSeconds
    }
    $postListeners = @(Get-ListenerProcesses -Port $Settings.Cpa.Port)
    $postListener = if ($postListeners.Count -eq 1) { $postListeners[0] } else { $null }
    $postListenerTrusted = ($listenerTrusted -and $null -ne $postListener -and $postListener.ProcessId -eq $singleListener.ProcessId -and
        (Test-PathEqual -Left $postListener.ExecutablePath -Right $Settings.Cpa.Executable) -and
        (Test-ListenerAddresses -Listener $postListener -ExpectedAddresses $expectedAddresses) -and
        (Get-CpaStackFileHash -Path $Settings.Cpa.Executable) -eq $ExpectedHash.ToUpperInvariant())
    $models = Get-JsonPropertyValue -Object $probe.Json -Name 'data'
    $modelCount = if ($null -eq $models) { 0 } else { @($models).Count }

    $healthy = (
        (Test-Path -LiteralPath $Settings.Cpa.Executable -PathType Leaf) -and
        (Test-Path -LiteralPath $Settings.Cpa.WorkingDirectory -PathType Container) -and
        (Test-Path -LiteralPath $Settings.Cpa.Config -PathType Leaf) -and
        $configPort -eq $Settings.Cpa.Port -and
        $listeners.Count -eq 1 -and
        $pathMatches -and
        $addressMatches -and
        $hashMatches -and
        $postListenerTrusted -and
        $TrustStateReady -and
        $probe.StatusCode -eq 200 -and
        $modelCount -gt 0
    )

    return [pscustomobject]@{
        Healthy = $healthy
        Port = $Settings.Cpa.Port
        Expected = [pscustomobject]@{
            Executable = $Settings.Cpa.Executable
            ExecutableExists = (Test-Path -LiteralPath $Settings.Cpa.Executable -PathType Leaf)
            WorkingDirectory = $Settings.Cpa.WorkingDirectory
            WorkingDirectoryExists = (Test-Path -LiteralPath $Settings.Cpa.WorkingDirectory -PathType Container)
            Config = $Settings.Cpa.Config
            ConfigExists = (Test-Path -LiteralPath $Settings.Cpa.Config -PathType Leaf)
            ConfigPort = $configPort
            ConfigHost = $configHost
            ListenerAddresses = $expectedAddresses
            ExecutableHashMatchesCurrent = $hashMatches
        }
        ListenerCount = $listeners.Count
        Listeners = @($listeners | ForEach-Object {
            [pscustomobject]@{
                ProcessId = $_.ProcessId
                Name = $_.Name
                ExecutablePath = $_.ExecutablePath
                LocalAddresses = @($_.LocalAddresses)
                PathMatches = (Test-PathEqual -Left $_.ExecutablePath -Right $Settings.Cpa.Executable)
            }
        })
        Health = [pscustomobject]@{
            Attempted = $probe.Attempted
            Reachable = $probe.Reachable
            StatusCode = $probe.StatusCode
            ModelCount = $modelCount
            ErrorKind = $probe.ErrorKind
        }
    }
}

function Get-ManagerStatus {
    param(
        $Settings,
        $SecretsState,
        [string]$ExpectedHash,
        [bool]$TrustStateReady
    )

    $listeners = @(Get-ListenerProcesses -Port $Settings.Manager.Port)
    $singleListener = if ($listeners.Count -eq 1) { $listeners[0] } else { $null }
    $pathMatches = ($null -ne $singleListener -and (Test-PathEqual -Left $singleListener.ExecutablePath -Right $Settings.Manager.Executable))
    $expectedAddresses = @(Resolve-ExpectedListenerAddresses -BindAddress ([string]$Settings.Manager.BindAddress))
    $addressMatches = Test-ListenerAddresses -Listener $singleListener -ExpectedAddresses $expectedAddresses
    $hashMatches = ($ExpectedHash -match '^[0-9A-Fa-f]{64}$' -and (Get-CpaStackFileHash -Path $Settings.Manager.Executable) -eq $ExpectedHash.ToUpperInvariant())
    $listenerTrusted = ($pathMatches -and $addressMatches -and $hashMatches)
    $baseUri = "http://127.0.0.1:$($Settings.Manager.Port)"

    $healthProbe = New-UnattemptedProbe
    $infoProbe = New-UnattemptedProbe
    $configProbe = New-UnattemptedProbe
    $statusProbe = New-UnattemptedProbe
    if ($TrustStateReady -and $listenerTrusted) {
        $healthProbe = Invoke-JsonProbe -Uri "$baseUri/health" -Headers @{} -TimeoutSeconds $Settings.HttpTimeoutSeconds
    }
    if ($TrustStateReady -and $SecretsState.Safe.Ready -and $listenerTrusted) {
        $headers = @{ Authorization = "Bearer $($SecretsState.Values.managerAdminKey)" }
        $infoProbe = Invoke-JsonProbe -Uri "$baseUri/usage-service/info" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds
        $configProbe = Invoke-JsonProbe -Uri "$baseUri/usage-service/config" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds
        $statusProbe = Invoke-JsonProbe -Uri "$baseUri/status" -Headers $headers -TimeoutSeconds $Settings.HttpTimeoutSeconds
    }
    $postListeners = @(Get-ListenerProcesses -Port $Settings.Manager.Port)
    $postListener = if ($postListeners.Count -eq 1) { $postListeners[0] } else { $null }
    $postListenerTrusted = ($listenerTrusted -and $null -ne $postListener -and $postListener.ProcessId -eq $singleListener.ProcessId -and
        (Test-PathEqual -Left $postListener.ExecutablePath -Right $Settings.Manager.Executable) -and
        (Test-ListenerAddresses -Listener $postListener -ExpectedAddresses $expectedAddresses) -and
        (Get-CpaStackFileHash -Path $Settings.Manager.Executable) -eq $ExpectedHash.ToUpperInvariant())

    $configured = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'configured')
    $adminReady = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'adminReady')
    $projectInitialized = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'projectInitialized')
    $setupRequired = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'setupRequired')
    $migrationStatus = [string](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'migrationStatus')
    $dataKeyReady = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'dataKeyReady')
    $hasHistoricalData = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'hasHistoricalData')

    $configObject = Get-JsonPropertyValue -Object $configProbe.Json -Name 'config'
    $collectorConfig = Get-JsonPropertyValue -Object $configObject -Name 'collector'
    $collectorEnabled = Get-JsonPropertyValue -Object $collectorConfig -Name 'enabled'
    $collectorMatches = ($collectorEnabled -is [bool] -and [bool]$collectorEnabled -eq $Settings.Manager.RequestMonitoringEnabled)

    $statusCollector = Get-JsonPropertyValue -Object $statusProbe.Json -Name 'collector'
    $collectorState = [string](Get-JsonPropertyValue -Object $statusCollector -Name 'collector')
    $collectorMode = [string](Get-JsonPropertyValue -Object $statusCollector -Name 'mode')
    $collectorTransport = [string](Get-JsonPropertyValue -Object $statusCollector -Name 'transport')
    $deadLetters = Get-JsonPropertyValue -Object $statusCollector -Name 'deadLetters'
    $dbPath = [string](Get-JsonPropertyValue -Object $statusProbe.Json -Name 'dbPath')
    $expectedDbPath = Join-Path $Settings.Manager.DataDirectory 'usage.sqlite'
    $dbPathMatches = Test-PathEqual -Left $dbPath -Right $expectedDbPath
    $collectorStateMatches = (-not $Settings.Manager.RequestMonitoringEnabled -or $collectorState -eq 'running')

    $healthy = (
        (Test-Path -LiteralPath $Settings.Manager.Executable -PathType Leaf) -and
        (Test-Path -LiteralPath $Settings.Manager.WorkingDirectory -PathType Container) -and
        (Test-Path -LiteralPath $Settings.Manager.DataDirectory -PathType Container) -and
        (Test-Path -LiteralPath $expectedDbPath -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Settings.Manager.DataDirectory 'data.key') -PathType Leaf) -and
        $listeners.Count -eq 1 -and
        $pathMatches -and
        $addressMatches -and
        $hashMatches -and
        $postListenerTrusted -and
        $TrustStateReady -and
        $healthProbe.StatusCode -eq 200 -and
        $infoProbe.StatusCode -eq 200 -and
        $configProbe.StatusCode -eq 200 -and
        $statusProbe.StatusCode -eq 200 -and
        $configured -and
        $adminReady -and
        $projectInitialized -and
        -not $setupRequired -and
        $migrationStatus -in @('ready', 'migrated') -and
        $dataKeyReady -and
        $collectorMatches -and
        $collectorStateMatches -and
        $dbPathMatches
    )

    return [pscustomobject]@{
        Healthy = $healthy
        Port = $Settings.Manager.Port
        Expected = [pscustomobject]@{
            Executable = $Settings.Manager.Executable
            ExecutableExists = (Test-Path -LiteralPath $Settings.Manager.Executable -PathType Leaf)
            WorkingDirectory = $Settings.Manager.WorkingDirectory
            WorkingDirectoryExists = (Test-Path -LiteralPath $Settings.Manager.WorkingDirectory -PathType Container)
            DataDirectory = $Settings.Manager.DataDirectory
            DataDirectoryExists = (Test-Path -LiteralPath $Settings.Manager.DataDirectory -PathType Container)
            Database = $expectedDbPath
            DatabaseExists = (Test-Path -LiteralPath $expectedDbPath -PathType Leaf)
            DataKeyExists = (Test-Path -LiteralPath (Join-Path $Settings.Manager.DataDirectory 'data.key') -PathType Leaf)
            BindAddress = [string]$Settings.Manager.BindAddress
            ListenerAddresses = $expectedAddresses
            ExecutableHashMatchesCurrent = $hashMatches
        }
        ListenerCount = $listeners.Count
        Listeners = @($listeners | ForEach-Object {
            [pscustomobject]@{
                ProcessId = $_.ProcessId
                Name = $_.Name
                ExecutablePath = $_.ExecutablePath
                LocalAddresses = @($_.LocalAddresses)
                PathMatches = (Test-PathEqual -Left $_.ExecutablePath -Right $Settings.Manager.Executable)
            }
        })
        Health = [pscustomobject]@{
            Reachable = $healthProbe.Reachable
            StatusCode = $healthProbe.StatusCode
            ErrorKind = $healthProbe.ErrorKind
        }
        UsageService = [pscustomobject]@{
            Attempted = $infoProbe.Attempted
            StatusCode = $infoProbe.StatusCode
            Configured = $configured
            AdminReady = $adminReady
            ProjectInitialized = $projectInitialized
            SetupRequired = $setupRequired
            MigrationStatus = $migrationStatus
            DataKeyReady = $dataKeyReady
            HasHistoricalData = $hasHistoricalData
        }
        Collector = [pscustomobject]@{
            ConfigStatusCode = $configProbe.StatusCode
            ExpectedEnabled = $Settings.Manager.RequestMonitoringEnabled
            Enabled = $collectorEnabled
            State = $collectorState
            Mode = $collectorMode
            Transport = $collectorTransport
            DeadLetters = $deadLetters
        }
        Database = [pscustomobject]@{
            StatusCode = $statusProbe.StatusCode
            ReportedPath = $dbPath
            PathMatches = $dbPathMatches
        }
    }
}

function Get-LegacyScriptValue {
    param(
        [string]$Content,
        [string]$VariableName
    )

    $pattern = '(?m)^\s*\$' + [regex]::Escape($VariableName) + '\s*=\s*["''](?<value>.*?)["'']\s*$'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        return $match.Groups['value'].Value
    }
    return $null
}

function Get-LegacyClientApiKey {
    param([string]$ConfigFile)

    $inside = $false
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigFile)) {
        if ($line -match '^api-keys\s*:\s*$') {
            $inside = $true
            continue
        }
        if ($inside -and $line -match '^[A-Za-z0-9_-]+\s*:') {
            break
        }
        if ($inside -and $line -match '^\s*-\s*(["'']?)(?<value>.+?)\1\s*$') {
            return $matches['value'].Trim()
        }
    }
    return $null
}

function Get-PendingOperationState {
    param([string]$StackRoot)

    $paths = @()
    $details = @()
    $rollbackRoot = Join-Path $StackRoot 'rollback'
    if (Test-Path -LiteralPath $rollbackRoot -PathType Container) {
        $paths += @(Get-ChildItem -Force -LiteralPath $rollbackRoot -Directory -Filter 'pending-*' | Select-Object -ExpandProperty FullName)
    }
    $stateRoot = Join-Path $StackRoot 'state'
    if (Test-Path -LiteralPath $stateRoot -PathType Container) {
        foreach ($file in Get-ChildItem -Force -LiteralPath $stateRoot -File -Filter '*.pending.json') {
            $paths += $file.FullName
            try {
                $journal = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
                $details += [pscustomobject]@{
                    Path = $file.FullName
                    Operation = $journal.operation
                    Phase = $journal.phase
                    SourceRuntime = $journal.sourceRuntime
                    SourceData = $journal.sourceData
                    TargetRuntime = $journal.targetRuntime
                    TargetData = $journal.targetData
                    PendingPath = $journal.pendingPath
                }
            } catch {
                $details += [pscustomobject]@{ Path = $file.FullName; Operation = $null; Phase = 'unreadable' }
            }
        }
    }
    return [pscustomobject]@{ Paths = @($paths | Select-Object -Unique); Details = @($details) }
}

function Get-LegacyState {
    param([string]$ExpectedControlRoot)

    $cpaListeners = @(Get-ListenerProcesses -Port 8317)
    $managerListeners = @(Get-ListenerProcesses -Port 18317)
    $cpaListener = if ($cpaListeners.Count -eq 1) { $cpaListeners[0] } else { $null }
    $managerListener = if ($managerListeners.Count -eq 1) { $managerListeners[0] } else { $null }
    $wsh = New-Object -ComObject WScript.Shell
    $shortcutPath = Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Desktop')) -Filter '*CPA*.lnk' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    $shortcut = $null
    $startScript = $null
    if ($shortcutPath -and (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        $link = $wsh.CreateShortcut($shortcutPath)
        $shortcut = [pscustomobject]@{
            Path = $shortcutPath
            TargetPath = $link.TargetPath
            ScriptPath = $null
            WorkingDirectory = $link.WorkingDirectory
            IconLocation = $link.IconLocation
            PowerShellWindowHidden = (
                [System.IO.Path]::GetFileName([string]$link.TargetPath) -ieq 'powershell.exe' -and
                [string]$link.Arguments -match '(?i)(?:^|\s)-WindowStyle\s+Hidden(?:\s|$)'
            )
        }
        if ($link.Arguments -match '(?i)-File\s+["''](?<path>.*?)["'']') {
            $startScript = $matches['path']
            $shortcut.ScriptPath = $startScript
        }
    }

    $scriptContent = if ($startScript -and (Test-Path -LiteralPath $startScript)) { [System.IO.File]::ReadAllText($startScript) } else { '' }
    $scriptCpaRuntime = Get-LegacyScriptValue -Content $scriptContent -VariableName 'cpaDir'
    $scriptManagerRuntime = Get-LegacyScriptValue -Content $scriptContent -VariableName 'managerDir'
    $cpaRuntime = if ($cpaListener) { Split-Path -Parent $cpaListener.ExecutablePath } else { $scriptCpaRuntime }
    $cpaConfig = Get-LegacyScriptValue -Content $scriptContent -VariableName 'cpaConfig'
    if (-not $cpaConfig -and $cpaRuntime) { $cpaConfig = Join-Path $cpaRuntime 'config.yaml' }
    $managerRuntime = if ($managerListener) { Split-Path -Parent $managerListener.ExecutablePath } else { $scriptManagerRuntime }

    $clientKey = if ($cpaConfig -and (Test-Path -LiteralPath $cpaConfig)) { Get-LegacyClientApiKey -ConfigFile $cpaConfig } else { $null }
    $managerKey = Get-LegacyScriptValue -Content $scriptContent -VariableName 'managerAdminKey'
    $cpaCredentialTargetTrusted = ($cpaListener -and $clientKey -and (
        ($scriptCpaRuntime -and (Test-PathEqual -Left $cpaListener.ExecutablePath -Right (Join-Path $scriptCpaRuntime 'cli-proxy-api.exe'))) -or
        (-not $scriptCpaRuntime -and $cpaConfig -and [System.IO.Path]::GetFullPath($cpaConfig).StartsWith([System.IO.Path]::GetFullPath($cpaRuntime).TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase))
    ))
    $managerCredentialTargetTrusted = ($managerListener -and $managerKey -and $scriptManagerRuntime -and
        (Test-PathEqual -Left $managerListener.ExecutablePath -Right (Join-Path $scriptManagerRuntime 'cpa-manager-plus.exe')))
    $managerData = $null
    $reportedDbPath = $null
    if ($managerCredentialTargetTrusted) {
        $statusProbe = Invoke-JsonProbe -Uri 'http://127.0.0.1:18317/status' -Headers @{ Authorization = "Bearer $managerKey" } -TimeoutSeconds 5
        $reportedDbPath = [string](Get-JsonPropertyValue -Object $statusProbe.Json -Name 'dbPath')
        if ($statusProbe.StatusCode -eq 200 -and $reportedDbPath -and (Test-Path -LiteralPath $reportedDbPath -PathType Leaf)) {
            $managerData = Split-Path -Parent ([System.IO.Path]::GetFullPath($reportedDbPath))
        }
    }
    if (-not $managerData) {
        $managerData = Get-LegacyScriptValue -Content $scriptContent -VariableName 'managerDataDir'
        if (-not $managerData -and $managerRuntime) { $managerData = Join-Path $managerRuntime 'data' }
    }
    $cpaHealth = $null
    $managerHealth = $null
    if ($cpaCredentialTargetTrusted) {
        $probe = Invoke-JsonProbe -Uri 'http://127.0.0.1:8317/v1/models' -Headers @{ Authorization = "Bearer $clientKey" } -TimeoutSeconds 5
        $models = Get-JsonPropertyValue -Object $probe.Json -Name 'data'
        $cpaHealth = [pscustomobject]@{ StatusCode = $probe.StatusCode; ModelCount = if ($models) { @($models).Count } else { 0 } }
    }
    if ($managerCredentialTargetTrusted) {
        $headers = @{ Authorization = "Bearer $managerKey" }
        $healthProbe = Invoke-JsonProbe -Uri 'http://127.0.0.1:18317/health' -Headers @{} -TimeoutSeconds 5
        $infoProbe = Invoke-JsonProbe -Uri 'http://127.0.0.1:18317/usage-service/info' -Headers $headers -TimeoutSeconds 5
        $configProbe = Invoke-JsonProbe -Uri 'http://127.0.0.1:18317/usage-service/config' -Headers $headers -TimeoutSeconds 5
        $collector = Get-JsonPropertyValue -Object (Get-JsonPropertyValue -Object $configProbe.Json -Name 'config') -Name 'collector'
        $managerHealth = [pscustomobject]@{
            HealthStatusCode = $healthProbe.StatusCode
            InfoStatusCode = $infoProbe.StatusCode
            HasHistoricalData = [bool](Get-JsonPropertyValue -Object $infoProbe.Json -Name 'hasHistoricalData')
            CollectorEnabled = Get-JsonPropertyValue -Object $collector -Name 'enabled'
            ReportedDbPath = $reportedDbPath
            DataKeyPresent = [bool]($managerData -and (Test-Path -LiteralPath (Join-Path $managerData 'data.key') -PathType Leaf))
        }
    }

    $cpaReady = ($null -ne $cpaHealth -and $cpaHealth.StatusCode -eq 200 -and $cpaHealth.ModelCount -gt 0)
    $managerReady = ($null -ne $managerHealth -and $managerHealth.HealthStatusCode -eq 200 -and $managerHealth.InfoStatusCode -eq 200 -and $managerHealth.DataKeyPresent)
    $healthy = ($cpaListener -and $managerListener -and $cpaReady -and $managerReady)
    $pendingState = Get-PendingOperationState -StackRoot $ExpectedControlRoot
    $pendingOperations = @($pendingState.Paths)
    $healthy = ($healthy -and $pendingOperations.Count -eq 0)
    return [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAt = [DateTimeOffset]::Now.ToString('o')
        OverallHealthy = [bool]$healthy
        CanonicalEstablished = $false
        MigrationRequired = $true
        InterruptedState = (-not $cpaListener -or -not $managerListener -or $pendingOperations.Count -gt 0)
        PendingOperations = $pendingOperations
        PendingOperationDetails = $pendingState.Details
        CanonicalRoot = $ExpectedControlRoot
        Cpa = [pscustomobject]@{
            Port = 8317
            Process = $cpaListener
            RuntimeDirectory = $cpaRuntime
            ConfigPath = $cpaConfig
            ExecutableHash = if ($cpaListener) { (Get-FileHash -Algorithm SHA256 -LiteralPath $cpaListener.ExecutablePath).Hash } else { $null }
            Health = $cpaHealth
        }
        Manager = [pscustomobject]@{
            Port = 18317
            Process = $managerListener
            RuntimeDirectory = $managerRuntime
            DataDirectory = $managerData
            ExecutableHash = if ($managerListener) { (Get-FileHash -Algorithm SHA256 -LiteralPath $managerListener.ExecutablePath).Hash } else { $null }
            Health = $managerHealth
        }
        Startup = [pscustomobject]@{
            ScriptPath = $startScript
            Shortcut = $shortcut
        }
        Secrets = [pscustomobject]@{
            CpaClientApiKeyPresent = [bool]$clientKey
            CpaManagementKeyPresent = [bool](Get-LegacyScriptValue -Content $scriptContent -VariableName 'cpaManagementKey')
            ManagerAdminKeyPresent = [bool]$managerKey
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $ControlRoot 'config\stack.psd1'
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $legacy = Get-LegacyState -ExpectedControlRoot $ControlRoot
        $legacy | ConvertTo-Json -Depth 10
        if ($legacy.OverallHealthy) { exit 0 }
        exit 1
    }

    $settings = Import-StackSettings -Path $ConfigPath
    if ([string]::IsNullOrWhiteSpace($SecretsPath)) {
        $SecretsPath = Join-Path (Split-Path -Parent $settings.ConfigPath) 'secrets.local.json'
    }
    $SecretsPath = [System.IO.Path]::GetFullPath($SecretsPath)

    $pendingState = Get-PendingOperationState -StackRoot $settings.StackRoot
    $pendingOperations = @($pendingState.Paths)
    $rootSecurity = Get-RootSecurityState -StackRoot $settings.StackRoot
    $managerDataSecurity = Get-ManagerDataSecurityState -DataRoot $settings.Manager.DataDirectory
    $pendingSwitchProbe = Get-PendingSwitchProbeContext -StackRoot $settings.StackRoot -Component $PendingSwitchComponent -Settings $settings
    $integrity = Get-CurrentIntegrityState -StackRoot $settings.StackRoot -ExpectedExecutableHashes $pendingSwitchProbe.ExpectedHashes
    $trustStateReady = [bool]($rootSecurity.Protected -and $managerDataSecurity.Protected -and $integrity.Ready)
    $secretsState = Get-SecretsState -Path $SecretsPath
    $currentForProbe = $null
    try { $currentForProbe = Read-CpaStackJson -Path (Join-Path $settings.StackRoot 'state\current.json') } catch {}
    $currentCpa = Get-JsonPropertyValue -Object $currentForProbe -Name 'cpa'
    $currentManager = Get-JsonPropertyValue -Object $currentForProbe -Name 'manager'
    $expectedCpaHash = [string](Get-JsonPropertyValue -Object $currentCpa -Name 'sha256')
    $expectedManagerHash = [string](Get-JsonPropertyValue -Object $currentManager -Name 'sha256')
    if ($pendingSwitchProbe.ExpectedHashes.Contains('cpa')) { $expectedCpaHash = [string]$pendingSwitchProbe.ExpectedHashes['cpa'] }
    if ($pendingSwitchProbe.ExpectedHashes.Contains('manager')) { $expectedManagerHash = [string]$pendingSwitchProbe.ExpectedHashes['manager'] }
    $cpa = Get-CpaStatus -Settings $settings -SecretsState $secretsState -ExpectedHash $expectedCpaHash -TrustStateReady $trustStateReady
    $manager = Get-ManagerStatus -Settings $settings -SecretsState $secretsState -ExpectedHash $expectedManagerHash -TrustStateReady $trustStateReady
    $overallHealthy = ($secretsState.Safe.Ready -and $rootSecurity.Protected -and $managerDataSecurity.Protected -and $integrity.Ready -and $cpa.Healthy -and $manager.Healthy -and $pendingOperations.Count -eq 0)
    $adoptionPending = @($pendingOperations | Where-Object { (Split-Path -Leaf ([string]$_)) -ieq 'adopt.pending.json' }).Count -gt 0
    $legacyCanonicalAdoptionRequired = ($adoptionPending -or (-not $integrity.MarkerPresent -and $integrity.CurrentPresent))
    $cpaListenerAddresses = @($cpa.Listeners | ForEach-Object { @($_.LocalAddresses) } | Where-Object { $_ } | Select-Object -Unique)
    $managerListenerAddresses = @($manager.Listeners | ForEach-Object { @($_.LocalAddresses) } | Where-Object { $_ } | Select-Object -Unique)

    [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAt = [DateTimeOffset]::Now.ToString('o')
        OverallHealthy = $overallHealthy
        CanonicalEstablished = [bool]$integrity.Ready
        MigrationRequired = $legacyCanonicalAdoptionRequired
        LegacyCanonicalAdoptionRequired = $legacyCanonicalAdoptionRequired
        InterruptedState = ($cpa.ListenerCount -ne 1 -or $manager.ListenerCount -ne 1 -or $pendingOperations.Count -gt 0)
        PendingOperations = $pendingOperations
        PendingOperationDetails = $pendingState.Details
        Configuration = [pscustomobject]@{
            StackRoot = $settings.StackRoot
            StackConfigPath = $settings.ConfigPath
            Secrets = $secretsState.Safe
        }
        Security = [pscustomobject]@{
            RootAcl = $rootSecurity
            ManagerDataTree = $managerDataSecurity
            Integrity = $integrity
            CpaLoopbackOnly = ($cpaListenerAddresses.Count -gt 0 -and -not @($cpaListenerAddresses | Where-Object { $_ -notin @('127.0.0.1', '::1') }))
            ManagerLoopbackOnly = ($managerListenerAddresses.Count -gt 0 -and -not @($managerListenerAddresses | Where-Object { $_ -notin @('127.0.0.1', '::1') }))
        }
        Cpa = $cpa
        Manager = $manager
    } | ConvertTo-Json -Depth 10

    if ($overallHealthy) {
        exit 0
    }
    exit 1
}
catch {
    [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAt = [DateTimeOffset]::Now.ToString('o')
        OverallHealthy = $false
        Error = [pscustomobject]@{
            Code = 'StatusFailed'
            Message = $_.Exception.Message
        }
    } | ConvertTo-Json -Depth 5
    exit 1
}
