#requires -Version 7.0
# Execute the real coordinator with fake IO: no services, network or production writes.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\cpa-safe-upgrade\scripts\Invoke-CpaStackUpgrade.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Equal 0 $errors.Count 'Upgrade parses'
$main=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
$flow=[scriptblock]::Create($main.Extent.Text)
Assert-False ($main.Extent.Text -match 'Test-(Cpa|Manager)Candidate|New-CpaStackCandidatePortPlan') 'No candidate execution in ordinary upgrades'

foreach ($case in @('success','cpa-only','unchanged','download-fails','switch-fails')) { & {
    $ControlRoot='C:\fixture'; $stateDir='C:\fixture\state'; $workRoot='C:\fixture\work'; $packageRoot='C:\fixture\packages'
    $currentStatePath=Join-Path $stateDir 'current.json'; $upgradeJournalPath=Join-Path $stateDir 'upgrade.pending.json'
    $resultPath=Join-Path $stateDir 'last-upgrade.json'; $releaseCurrent='C:\fixture\releases'
    $RecoverOnly=$false; $AllowUnknownVersionReplacement=$true; $suppressResultPersistence=$false; $diagnosticStage='preflight'
    $result=[ordered]@{success=$false;cpa=$null;manager=$null;error=$null;diagnostics=@()}
    $events=[Collections.Generic.List[string]]::new(); $scenario=@{Journal=$false;FailedSwitch=$false;Trace=''}
    $fixtureCurrent=[pscustomobject]@{instanceId=('1'*32);cpa=[pscustomobject]@{version='v1.13.0'};manager=[pscustomobject]@{version='v1.13.0'}}
    $fixtureStack=@{Cpa=@{WorkingDirectory='runtime\cpa';Config='runtime\cpa\config.yaml';Port=8317};Manager=@{WorkingDirectory='runtime\manager';DataDirectory='data';Port=18317;BindAddress='127.0.0.1'}}
    foreach($name in @('Assert-CpaStackPath','Assert-CpaStackChildPath','Protect-CpaStackPrivateDirectory',
        'Repair-CpaStackRecordedExecutableAcl','Add-UpgradeDiagnostic','Write-UpgradeCheckpoint','Exit-CpaStackOperationLock',
        'Remove-UpgradeTemporaryWork','Remove-OrphanedRollbackStaging','Clear-SensitiveUpgradeWork','Assert-UpgradeSwitchPathBudget',
        'Remove-UpgradeJournal','New-Item','Remove-Item','Move-Item','Wait-CpaStackTrustedListener')) {
        . ([scriptblock]::Create("function $name { }"))
    }
    function Get-ChildItem { @() }
    function Join-Path { param($Path,$ChildPath) [IO.Path]::Combine([string]$Path,[string]$ChildPath) }
    function Enter-CpaStackOperationLock { [object]::new() }
    function Ensure-CpaStackInstanceMarker { [pscustomobject]@{instanceId=('1'*32)} }
    function Test-Path { param($LiteralPath)
        if($LiteralPath -eq $upgradeJournalPath){return $scenario.Journal}
        if($LiteralPath -like '*switch-cpa.pending.json'){return $scenario.FailedSwitch}
        return $LiteralPath -notmatch 'pending|previous|plugins'
    }
    function Read-CpaStackJson { param($Path) if($Path -eq $currentStatePath){return $fixtureCurrent}; [pscustomobject]@{success=$true;skipped=$false} }
    function Write-CpaStackJson { param($Value,$Path) if($Path -eq $upgradeJournalPath){$scenario.Journal=$true;Assert-Equal 4 $Value.schemaVersion 'New runtime-only journal'} }
    function Get-CpaStackConfig { $fixtureStack }
    function Get-CpaStackSecrets { @{managerAdminKey='fixture'} }
    function Invoke-ChildPowerShellJson { [pscustomobject]@{OverallHealthy=$true;CanonicalEstablished=$true;InterruptedState=$false} }
    function New-CpaStackHealthDiagnostic { @{} }
    function New-CpaStackFailureDiagnostic { param($Stage,$Failure) $scenario.Trace=$Failure.InvocationInfo.PositionMessage; @{} }
    function Sync-CpaStackCanonicalLauncher { @{changed=$false} }
    function Get-CpaStackLatestRelease { @{} }
    function Save-CpaStackRelease { param($Release,$Destination)
        if($case -eq 'download-fails'){throw 'fixture checksum failure'}
        $unchanged=$case -eq 'unchanged' -or ($case -eq 'cpa-only' -and $Destination.EndsWith('manager-plus'))
        @{tag=$(if($unchanged){'v1.13.0'}else{'v1.13.1'});packageRoot=$Destination;executableSha256=$(if($unchanged){'A'*64}else{'B'*64})}
    }
    function Convert-TagVersion { param($Tag) [version]$Tag.TrimStart('v') }
    function Get-CpaStackFileHash { 'A'*64 }
    function Get-CpaStackListener { [pscustomobject]@{ExecutablePath='C:\fixture\runtime\manager\cpa-manager-plus.exe';ProcessId=123} }
    function Get-CpaStackManagerSetupBaseline { @{cpaBaseUrl='http://127.0.0.1:8317';collectorEnabled=$false;pollIntervalMs=500;usageStatisticsEnabled=$true} }
    function Set-UpgradeJournalPhase { param($Phase) $events.Add($Phase) }
    function Invoke-SwitchScript { param($Script,$Arguments) $events.Add('switch'); $events.Add([IO.Path]::GetFileName($Script)); if($case -eq 'switch-fails'){$scenario.FailedSwitch=$true;throw 'fixture switch failure'} }
    function Set-CurrentComponentState { param($Component) $events.Add('record-'+$Component) }
    function Restore-CanonicalInterruptedState { param($CpaRuntime,$ManagerRuntime,$ManagerData,$Preflight,[switch]$CommitOnly) $events.Add($(if($CommitOnly){'archive'}else{'recover'})) }
    function Recover-UpgradePreparationState { $events.Add('preparation-recovery') }
    function Set-CpaStackRegisteredRoot { $events.Add('registered') }
    & $flow
    switch($case){
        success {
            Assert-True $result.success "Successful switch commits: $($result.error) $($scenario.Trace)"
            Assert-Equal 2 @($events|Where-Object {$_ -eq 'switch'}).Count 'One switch per component'
            Assert-Equal 2 @($events|Where-Object {$_ -eq 'archive'}).Count 'Only archive on success'
            Assert-False ($events.Contains('recover')) 'No runtime recovery on success'
        }
        unchanged { Assert-True $result.success "Already-current succeeds: $($result.error)"; Assert-False ($events.Contains('switch')) 'No restart when unchanged' }
        cpa-only { Assert-True $result.success 'CPA-only upgrade succeeds'; Assert-True $result.manager.skipped 'Unchanged Manager is skipped'; Assert-False ($events.Contains('Switch-ManagerRuntime.ps1')) 'CPA-only never enters Manager backup or stop workflow' }
        download-fails { Assert-False $result.success 'Bad download fails'; Assert-False ($events.Contains('switch')) 'Bad download cannot stop runtime' }
        switch-fails { Assert-False $result.success 'Failed switch fails'; Assert-True ($events.Contains('recover')) 'Failure invokes recovery'; Assert-False ($events.Contains('record-cpa')) 'No commit of failed runtime' }
    }
} }
& {
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-ValidatedUpgradeJournal'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $ControlRoot='C:\fixture'; $upgradeJournalPath='C:\fixture\upgrade.pending.json'
    $instanceMarker=[pscustomobject]@{instanceId=('1'*32)}
    $journal=[pscustomobject]@{schemaVersion=4;operation='upgrade-runtime';operationId=('2'*32);instanceId=('1'*32);canonicalRoot=$ControlRoot;phase='switching-cpa';cpaCandidateExe=$null;managerCandidateExe=$null;managerBaseline=[pscustomobject]@{cpaBaseUrl='http://127.0.0.1:8317';collectorEnabled=$false;pollIntervalMs=500;usageStatisticsEnabled=$true};createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z'}
    $previous=$journal | ConvertTo-Json | ConvertFrom-Json; $previous.phase='prepared'
    $previous.createdAt=$journal.createdAt; $previous.updatedAt=$journal.updatedAt
    function Test-Path { $true }
    function Read-StableUpgradeJournalFile { param($Path) @{Value=$(if($Path.EndsWith('.previous')){$previous}else{$journal});Descriptor=@{Path=$Path;Exists=$true;Sha256=('A'*64)}} }
    [void](Read-ValidatedUpgradeJournal)
    $journal.phase='switching-manager'; [void](Read-ValidatedUpgradeJournal)
    $journal.phase='testing-cpa'
    Assert-Throws { Read-ValidatedUpgradeJournal } 'New format rejects candidate phases'
    $journal.phase='switching-cpa'; $previous.operationId='3'*32
    Assert-Throws { Read-ValidatedUpgradeJournal } 'Mixed transaction IDs remain rejected'
    # The previous candidate format remains recoverable, never newly emitted.
    $previous.operationId='2'*32
    foreach($doc in @($journal,$previous)){
        $doc.schemaVersion=3; $doc.operation='upgrade-candidates'
        $doc | Add-Member cpaCandidatePort 60000
        $doc | Add-Member managerCandidatePort 60001
    }
    $journal.phase='testing-cpa'
    function Get-CpaStackConfig { @{Cpa=@{Port=8317};Manager=@{Port=18317}} }
    function Get-CpaStackCandidateProtectedPorts { @(8317,18317) }
    [void](Read-ValidatedUpgradeJournal)
}
& {
    $guard=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '^\(?\$CommitOnly\)?$'},$true)
    Assert-True ($null -ne $guard) 'Commit-only guard exists'
    $body=$guard.Clauses[0].Item2.Extent.Text
    $check=[scriptblock]::Create($body.Substring(1,$body.Length-2))
    $managerRecovery=$null
    $cpaRecovery=[pscustomobject]@{Disposition='commit-new';Journal=@{phase='runtime-verified'}}
    & $check
    $cpaRecovery.Disposition='restore-old'
    Assert-Throws { & $check } 'Old runtime cannot be silently committed'
    $cpaRecovery=$null
    Assert-Throws { & $check } 'Missing switch cannot be silently committed'
}
'Upgrade flow checks passed.'
