[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControlRoot,
    [switch]$RecoverOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CpaStack.Common.ps1')

$ControlRoot = Assert-CpaStackSecureLocalRoot -Path $ControlRoot
$stateDir = Join-Path $ControlRoot 'state'
$currentPath = Join-Path $stateDir 'current.json'
$journalPath = Join-Path $stateDir 'adopt.pending.json'
$markerPath = Join-Path $ControlRoot '.cpa-stack-instance.json'
$result = [ordered]@{
    operation = 'adopt-legacy-canonical-stack'
    success = $false
    changed = $false
    adopted = $false
    root = $ControlRoot
    instanceId = $null
    launcherUpdated = $false
    journalCleanupWarning = $null
    error = $null
}
$operationLock = $null

function Get-LegacyCanonicalState {
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Get-CpaStackState.ps1') -ControlRoot $ControlRoot 2>&1)
    $json = (@($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'Legacy canonical status returned no structured result.' }
    try {
        return ConvertFrom-Json -InputObject $json -ErrorAction Stop
    } catch {
        throw 'Legacy canonical status returned an invalid structured result.'
    }
}

function Assert-LegacyCanonicalLayout {
    param($Current, $Journal)

    if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$Current.canonicalRoot).TrimEnd('\'), $ControlRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Legacy current state points to another canonical root.'
    }
    $expected = [ordered]@{
        cpaRuntime = Join-Path $ControlRoot 'runtime\cli-proxy-api'
        cpaExe = Join-Path $ControlRoot 'runtime\cli-proxy-api\cli-proxy-api.exe'
        cpaConfig = Join-Path $ControlRoot 'runtime\cli-proxy-api\config.yaml'
        auth = Join-Path $ControlRoot 'runtime\cli-proxy-api\auth'
        plugins = Join-Path $ControlRoot 'runtime\cli-proxy-api\plugins'
        managerRuntime = Join-Path $ControlRoot 'runtime\manager-plus'
        managerExe = Join-Path $ControlRoot 'runtime\manager-plus\cpa-manager-plus.exe'
        managerData = Join-Path $ControlRoot 'data\manager-plus'
        managerDb = Join-Path $ControlRoot 'data\manager-plus\usage.sqlite'
        managerKey = Join-Path $ControlRoot 'data\manager-plus\data.key'
        stackConfig = Join-Path $ControlRoot 'config\stack.psd1'
        secrets = Join-Path $ControlRoot 'config\secrets.local.json'
        launcher = Join-Path $ControlRoot 'ops\Start-CPA-Stack.ps1'
    }
    foreach ($path in $expected.Values) {
        Assert-CpaStackChildPath -Root $ControlRoot -Path $path
    }
    foreach ($path in @($expected.cpaExe, $expected.cpaConfig, $expected.managerExe, $expected.managerDb, $expected.managerKey, $expected.stackConfig, $expected.secrets, $expected.launcher)) {
        Assert-CpaStackPath -Path $path -PathType Leaf
    }
    Assert-CpaStackPath -Path $expected.managerData
    Assert-CpaStackPath -Path $expected.auth
    Assert-CpaStackLegacyCpaSource -Runtime $expected.cpaRuntime -ConfigPath $expected.cpaConfig
    Assert-CpaStackLegacyManagerSource -Runtime $expected.managerRuntime -Data $expected.managerData
    [void](Get-CpaStackTreeItemsNoReparse -Root $expected.auth)
    if (Test-Path -LiteralPath $expected.plugins) {
        Assert-CpaStackPath -Path $expected.plugins
        [void](Get-CpaStackTreeItemsNoReparse -Root $expected.plugins)
    }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$Current.cpa.executable), $expected.cpaExe, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Current.cpa.config), $expected.cpaConfig, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Current.manager.executable), $expected.managerExe, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$Current.manager.data), $expected.managerData, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Legacy current state does not use the fixed canonical runtime and data slots.'
    }
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'CPA'; Path = $expected.cpaExe; Recorded = [string]$Current.cpa.sha256; Journal = if ($Journal) { [string]$Journal.cpaSha256 } else { $null } },
        [pscustomobject]@{ Name = 'Manager'; Path = $expected.managerExe; Recorded = [string]$Current.manager.sha256; Journal = if ($Journal) { [string]$Journal.managerSha256 } else { $null } }
    )) {
        if ($entry.Recorded -notmatch '^[0-9A-Fa-f]{64}$') { throw "$($entry.Name) legacy current hash is invalid." }
        $actual = Get-CpaStackFileHash -Path $entry.Path
        if ($actual -ne $entry.Recorded.ToUpperInvariant()) { throw "$($entry.Name) legacy current hash does not match its executable." }
        if ($Journal -and $actual -ne $entry.Journal.ToUpperInvariant()) { throw "$($entry.Name) changed after the adoption journal was written." }
    }
    $stack = Get-CpaStackConfig -ControlRoot $ControlRoot
    if (-not [string]::Equals([System.IO.Path]::GetFullPath((Join-Path $ControlRoot ([string]$stack.Cpa.Executable))), $expected.cpaExe, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath((Join-Path $ControlRoot ([string]$stack.Cpa.WorkingDirectory))), $expected.cpaRuntime, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath((Join-Path $ControlRoot ([string]$stack.Cpa.Config))), $expected.cpaConfig, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath((Join-Path $ControlRoot ([string]$stack.Manager.Executable))), $expected.managerExe, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath((Join-Path $ControlRoot ([string]$stack.Manager.WorkingDirectory))), $expected.managerRuntime, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath((Join-Path $ControlRoot ([string]$stack.Manager.DataDirectory))), $expected.managerData, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Legacy stack configuration does not use the fixed canonical slots.'
    }
    if ([int]$stack.Cpa.Port -ne 8317 -or [int]$stack.Manager.Port -ne 18317) {
        throw 'Legacy stack configuration does not use the canonical formal ports.'
    }
    $managerBindAddress = [string]$stack.Manager.BindAddress
    if ([string]::IsNullOrWhiteSpace($managerBindAddress) -or $managerBindAddress -notmatch '^[A-Za-z0-9.:%\[\]-]+$') {
        throw 'Legacy Manager bind address is invalid.'
    }
    $cpaConfigContent = [System.IO.File]::ReadAllText($expected.cpaConfig, [System.Text.UTF8Encoding]::new($false, $true))
    $hostMatches = @([regex]::Matches($cpaConfigContent, '(?m)^host:\s*["'']?(?<host>[^"''#\s]+)'))
    if ($hostMatches.Count -ne 1) { throw 'Legacy CPA config must contain exactly one explicit host.' }
    $expected['cpaBindAddress'] = [string]$hostMatches[0].Groups['host'].Value
    $expected['managerBindAddress'] = $managerBindAddress
    return [pscustomobject]$expected
}

try {
    $operationLock = Enter-CpaStackOperationLock
    Assert-CpaStackPath -Path $ControlRoot
    Assert-CpaStackPath -Path $currentPath -PathType Leaf
    Assert-CpaStackChildPath -Root $ControlRoot -Path $journalPath

    $journal = $null
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        $journal = Read-CpaStackJson -Path $journalPath
        if ([int]$journal.schemaVersion -ne 1 -or
            [string]$journal.operation -ne 'adopt-legacy-canonical-stack' -or
            [string]$journal.instanceId -notmatch '^[0-9a-fA-F]{32}$' -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$journal.canonicalRoot).TrimEnd('\'), $ControlRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Legacy canonical adoption journal is invalid or belongs to another root.'
        }
    } elseif ($RecoverOnly) {
        $result.success = $true
        $result.changed = $false
        $result | ConvertTo-Json -Depth 8 -Compress
        exit 0
    } else {
        $otherPending = @(Get-ChildItem -LiteralPath $stateDir -File -Filter '*.pending.json' -ErrorAction SilentlyContinue)
        $rollbackPending = @(Get-ChildItem -LiteralPath (Join-Path $ControlRoot 'rollback') -Directory -Filter 'pending-*' -ErrorAction SilentlyContinue)
        if ($otherPending.Count -gt 0 -or $rollbackPending.Count -gt 0) {
            throw 'Legacy canonical adoption requires a root with no other pending transaction.'
        }
    }

    $current = Read-CpaStackJson -Path $currentPath
    if ([int]$current.schemaVersion -ne 1) {
        throw 'Legacy current state schema is unsupported.'
    }
    $currentIdProperty = $current.PSObject.Properties['instanceId']
    $currentInstanceId = if ($null -ne $currentIdProperty) { [string]$currentIdProperty.Value } else { $null }
    if ($null -ne $currentIdProperty -and $currentInstanceId -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'Legacy current state instance id is invalid.'
    }

    $existingMarker = $null
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $existingMarker = Read-CpaStackJson -Path $markerPath
        if ([int]$existingMarker.schemaVersion -ne 1 -or
            [string]$existingMarker.instanceId -notmatch '^[0-9a-fA-F]{32}$' -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$existingMarker.root).TrimEnd('\'), $ControlRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Existing instance marker is invalid or belongs to another root.'
        }
    }

    $boundInstanceIds = @(@(
            [string]$currentInstanceId,
            $(if ($journal) { [string]$journal.instanceId } else { $null }),
            $(if ($existingMarker) { [string]$existingMarker.instanceId } else { $null })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($boundInstanceIds.Count -gt 1) {
        throw 'Legacy current state, adoption journal, and instance marker do not identify the same stack.'
    }
    $instanceId = if ($journal) {
        [string]$journal.instanceId
    } elseif (-not [string]::IsNullOrWhiteSpace($currentInstanceId)) {
        $currentInstanceId
    } elseif ($existingMarker) {
        [string]$existingMarker.instanceId
    } else {
        [guid]::NewGuid().ToString('N')
    }

    $layout = Assert-LegacyCanonicalLayout -Current $current -Journal $journal
    $cpaListener = Get-CpaStackListener -Port 8317
    $managerListener = Get-CpaStackListener -Port 18317
    if (-not $cpaListener -or $cpaListener.ExecutablePath -ine $layout.cpaExe -or
        -not $managerListener -or $managerListener.ExecutablePath -ine $layout.managerExe) {
        throw 'Legacy canonical formal ports are not owned by the recorded executables.'
    }
    [void](Wait-CpaStackTrustedListener -Port 8317 -ExpectedPath $layout.cpaExe -ExpectedProcessId $cpaListener.ProcessId -ExpectedHash ([string]$current.cpa.sha256) -AllowedAddresses @($layout.cpaBindAddress) -Seconds 2)
    [void](Wait-CpaStackTrustedListener -Port 18317 -ExpectedPath $layout.managerExe -ExpectedProcessId $managerListener.ProcessId -ExpectedHash ([string]$current.manager.sha256) -AllowedAddresses @($layout.managerBindAddress) -Seconds 2)

    foreach ($directory in @($ControlRoot, (Join-Path $ControlRoot 'config'), (Join-Path $ControlRoot 'ops'), $stateDir, (Join-Path $ControlRoot 'runtime'), (Join-Path $ControlRoot 'runtime\cli-proxy-api'), (Join-Path $ControlRoot 'runtime\manager-plus'), (Join-Path $ControlRoot 'data'))) {
        Protect-CpaStackPrivateDirectory -Path $directory
    }
    foreach ($file in @($layout.cpaExe, $layout.cpaConfig, $layout.managerExe, $layout.stackConfig, $layout.secrets, $layout.launcher, $currentPath)) {
        Protect-CpaStackSecretFile -Path $file
    }
    Protect-CpaStackPrivateTree -Root $layout.auth
    if (Test-Path -LiteralPath $layout.plugins) {
        Protect-CpaStackPrivateTree -Root $layout.plugins
    }
    Protect-CpaStackPrivateTree -Root $layout.managerData
    $result.changed = $true
    $layout = Assert-LegacyCanonicalLayout -Current $current -Journal $journal

    if (-not $journal) {
        $journal = [ordered]@{
            schemaVersion = 1
            operation = 'adopt-legacy-canonical-stack'
            instanceId = $instanceId
            canonicalRoot = $ControlRoot
            cpaSha256 = Get-CpaStackFileHash -Path $layout.cpaExe
            managerSha256 = Get-CpaStackFileHash -Path $layout.managerExe
            createdAt = [DateTimeOffset]::Now.ToString('o')
        }
        Write-CpaStackJson -Value $journal -Path $journalPath
        Protect-CpaStackSecretFile -Path $journalPath
    }

    if ($null -eq $currentIdProperty) {
        $current | Add-Member -NotePropertyName instanceId -NotePropertyValue $instanceId
    } elseif ([string]$currentIdProperty.Value -ne $instanceId) {
        throw 'Legacy current state instance id conflicts with the adoption journal.'
    }
    Write-CpaStackJson -Value $current -Path $currentPath
    Protect-CpaStackSecretFile -Path $currentPath

    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-CpaStackJson -Value ([ordered]@{
            schemaVersion = 1
            instanceId = $instanceId
            root = $ControlRoot
            createdAt = [DateTimeOffset]::Now.ToString('o')
            adoptedLegacyCanonical = $true
        }) -Path $markerPath
        Protect-CpaStackSecretFile -Path $markerPath
    }
    $marker = Ensure-CpaStackInstanceMarker -ControlRoot $ControlRoot
    if ([string]$marker.instanceId -ne $instanceId) { throw 'Adopted instance marker validation failed.' }

    $status = Get-LegacyCanonicalState
    if (-not [bool]$status.Cpa.Healthy -or -not [bool]$status.Manager.Healthy -or
        -not [bool]$status.Security.RootAcl.Protected -or
        -not [bool]$status.Security.ManagerDataTree.Protected -or
        -not [bool]$status.Security.Integrity.Ready) {
        throw 'Adopted canonical services, ACL, or integrity did not pass the trusted health contract.'
    }

    $launcher = Sync-CpaStackCanonicalLauncher -ControlRoot $ControlRoot
    $result.launcherUpdated = [bool]$launcher.changed
    Set-CpaStackRegisteredRoot -ControlRoot $ControlRoot
    $result.instanceId = $instanceId
    $result.adopted = $true
    try {
        Remove-Item -LiteralPath $journalPath -Force -ErrorAction Stop
    } catch {
        $result.journalCleanupWarning = $_.Exception.Message
        throw 'Legacy canonical adoption committed, but its journal could not be removed. Retry to finish cleanup.'
    }
    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    Exit-CpaStackOperationLock -Mutex $operationLock
}

$result | ConvertTo-Json -Depth 8 -Compress
if (-not $result.success) {
    Write-Error $result.error
    exit 1
}
