$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $repo 'skills\cpa-safe-upgrade\scripts\CpaStack.Common.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'skills\cpa-safe-upgrade\scripts\Start-CPA-Stack.ps1'), [ref]$tokens, [ref]$errors)
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-PrivateCpaTree' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cpa-auth-logs-' + [guid]::NewGuid().ToString('N'))
$auth = Join-Path $temp 'auth'
$logs = Join-Path $auth 'logs'
$credential = Join-Path $auth 'fixture.json'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
[IO.File]::WriteAllText($credential, '{}')
[IO.File]::WriteAllText((Join-Path $logs 'history.tmp'), 'fixture')
Protect-CpaStackPrivateTree -Root $temp
try {
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Force)
        if ($LiteralPath -ieq $logs) { throw 'Historical logs were enumerated.' }
        Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
    }
    $items = @(Get-CpaStackTreeItemsNoReparse -Root $auth -ShallowDirectoryNames @('logs'))
    Assert-Equal 3 $items.Count 'Only auth root, credential and logs boundary are visited'
    Assert-CpaStackPrivateTree -Root $auth -ShallowDirectoryNames @('logs')
    Assert-PrivateCpaTree -Root $auth -ShallowDirectoryNames @('logs')
    Copy-CpaStackAuthTree -Source $auth -Destination (Join-Path $temp 'copy')
    Assert-False (Test-Path (Join-Path $temp 'copy\logs')) 'Auth copies omit historical logs'
    Assert-True (Test-Path (Join-Path $temp 'copy\fixture.json')) 'Auth copies keep credentials'
    Assert-Throws { Assert-CpaStackPrivateTree -Root $auth } 'Generic tree audits remain recursive'

    foreach ($unsafePath in @($logs, $credential)) {
        $changed = Get-CpaStackFileSystemAcl -Path $unsafePath
        $changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Read', 'Allow'))
        Set-CpaStackFileSystemAcl -Path $unsafePath -Acl $changed
        try {
            Assert-Throws { Assert-CpaStackPrivateTree -Root $auth -ShallowDirectoryNames @('logs') } 'Credential and logs boundary ACL checks remain enforced'
            Assert-Throws { Assert-PrivateCpaTree -Root $auth -ShallowDirectoryNames @('logs') } 'Starter retains boundary ACL checks'
        } finally {
            if ($unsafePath -eq $logs) { Protect-CpaStackPrivateDirectory -Path $unsafePath }
            else { Protect-CpaStackSecretFile -Path $unsafePath }
        }
    }
    function Get-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Force)
        if ($LiteralPath -ieq $logs) { return [pscustomobject]@{ Attributes=[IO.FileAttributes]::ReparsePoint } }
        Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
    }
    Assert-Throws { Assert-CpaStackPrivateTree -Root $auth -ShallowDirectoryNames @('logs') } 'A log directory link is rejected before traversal is pruned'
    Assert-Throws { Assert-PrivateCpaTree -Root $auth -ShallowDirectoryNames @('logs') } 'Starter rejects a log directory link'
    Remove-Item Function:\Get-Item
    Remove-Item Function:\Get-ChildItem
    # A nested credentials directory called logs is not the top-level log boundary.
    New-Item -ItemType Directory -Path (Join-Path $auth 'nested\logs') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $auth 'nested\logs\credential.json'), '{}')
    $items = @(Get-CpaStackTreeItemsNoReparse -Root $auth -ShallowDirectoryNames @('logs'))
    Assert-True (@($items | Where-Object { $_.Name -eq 'credential.json' }).Count -eq 1) 'Nested credentials remain traversed'
} finally {
    Remove-Item Function:\Get-ChildItem -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-Item -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
'Auth log boundary tests passed.'
