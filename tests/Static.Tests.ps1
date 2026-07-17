$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repo = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Force | Where-Object { $_.FullName -notlike '*\.git\*' })

foreach ($file in $files | Where-Object { $_.Extension -eq '.ps1' }) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-Equal 0 @($errors).Count "PowerShell parser errors in $($file.FullName)"
}

$nonAsciiPowerShell = @($files | Where-Object {
    $_.Extension -eq '.ps1' -and
    @([System.IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0
})
Assert-Equal 0 $nonAsciiPowerShell.Count 'PowerShell sources remain ASCII-safe for Windows PowerShell 5.1'

$textFiles = @($files | Where-Object {
    $_.Extension -in @('.ps1', '.psd1', '.md', '.json', '.yaml', '.yml', '.py') -and
    $_.FullName -ne $PSCommandPath
})
$forbiddenPatterns = @(
    'D:\\Develop',
    'h00019146',
    'HIHONOR',
    'Local\\CPAStackSafeOperation',
    'HTTP_ADDR\s*=\s*"0\.0\.0\.0:\$TempPort"'
)
foreach ($pattern in $forbiddenPatterns) {
    $matches = @($textFiles | Select-String -Pattern $pattern -ErrorAction SilentlyContinue)
    Assert-Equal 0 $matches.Count "Forbidden private or unsafe pattern '$pattern'"
}

$skillRoot = Join-Path $repo 'skills\cpa-safe-upgrade'
$repoVersion = ([System.IO.File]::ReadAllText((Join-Path $repo 'VERSION'), [System.Text.UTF8Encoding]::new($false, $true))).Trim()
$skillVersion = ([System.IO.File]::ReadAllText((Join-Path $skillRoot 'VERSION'), [System.Text.UTF8Encoding]::new($false, $true))).Trim()
Assert-Equal $repoVersion $skillVersion 'Repository and installed-skill VERSION files match'
$forbiddenSkillFiles = @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force | Where-Object {
    $_.Name -match '(?i)(secrets\.local|data\.key|usage\.sqlite|\.env$|\.log$)' -or
    $_.Extension -in @('.exe', '.db', '.sqlite', '.zip')
})
Assert-Equal 0 $forbiddenSkillFiles.Count 'Skill package contains runtime, secret, or binary files'

$skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw -Encoding UTF8
Assert-True ($skill -match '(?s)^---\s*\r?\nname:\s*cpa-safe-upgrade\s*\r?\ndescription:\s*.+?\r?\n---') 'SKILL.md frontmatter is valid'
Assert-True ($skill.Length -lt 20000) 'SKILL.md remains concise'
Assert-False ($skill.Contains('& "$PSScriptRoot\scripts\cpa-stack.ps1"')) 'Interactive examples do not use PSScriptRoot as the skill root'
Assert-True ($skill.Contains('$skillRoot = Split-Path -Parent')) 'SKILL.md derives an explicit skill root from its own path'
Assert-True ($skill.Contains('$cpaCli = Join-Path $skillRoot ''scripts\cpa-stack.ps1''')) 'SKILL.md derives one stable public CLI path'
Assert-True ([regex]::Matches($skill, [regex]::Escape('& $cpaCli')).Count -ge 8) 'Runtime examples use only the stable public CLI'
Assert-False ($skill -match '&\s+\$cpaCli\s+(?:plan|init)\b') 'Primary Skill workflow does not teach deprecated plan or init commands'
Assert-False ($skill -match '-(?:UpdateDesktopShortcut|ExposeToLan)\b') 'Primary Skill workflow does not teach v0.1 combined side-effect switches'
Assert-True ($skill -match "install\.ps1'\s+-Action\s+Check" -and $skill -match "install\.ps1'\s+-Action\s+Update") 'Skill self-update is limited to explicit local installer Check and Update actions'

$initialize = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts\Initialize-CpaStack.ps1') -Raw -Encoding UTF8
Assert-False ($initialize -match 'legacyStartScriptSha256\s*=\s*Get-CpaStackFileHash\s+-Path\s+\$LegacyStartScript') 'Legacy start script hash is not computed unconditionally'
Assert-True ($initialize -match 'legacyStartScriptSha256\s*=\s*if\s*\(\[string\]::IsNullOrWhiteSpace\(\$LegacyStartScript\)\)') 'Legacy start script hash is guarded for an empty path'
Assert-True ([regex]::Matches($initialize, 'Assert-CpaStackLegacyCpaSource').Count -ge 3) 'Initialization gates the legacy source before journaling, copying, and recovery'
Assert-True ([regex]::Matches($initialize, 'Assert-CpaStackLegacyManagerSource').Count -ge 3) 'Initialization gates the legacy Manager runtime and data before copying or recovery'
Assert-True ($initialize -match 'managerRecoveryBlocked') 'Initialization refuses an outer legacy Manager restart after untrusted component recovery'
Assert-True ($initialize -match '\$cpaCandidate\s*=\s*Invoke-InProcessPowerShellJson') 'Initialization captures the completed CPA candidate result'
Assert-True ($initialize -match 'targetCpaRuntimeManifestSha256\s*=\s*\[string\]\$cpaCandidate\.runtimeManifestSha256') 'Initialization journals the post-candidate runtime digest'
Assert-True ($initialize -match 'Set-InitializeJournalPhase[\s\S]+Protect-CpaStackSecretFile\s+-Path\s+\$initializeJournalPath') 'Initialization re-protects the journal after every candidate binding update'
Assert-True ($initialize -match 'ExpectedTargetRuntimeManifestSha256') 'Initialization passes the existing candidate digest into the switch'
Assert-True ($initialize.LastIndexOf('$result | ConvertTo-Json', [System.StringComparison]::Ordinal) -lt $initialize.LastIndexOf('if (-not $result.success)', [System.StringComparison]::Ordinal)) 'Initialization emits its structured result before a non-zero exit'

$start = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Start-CPA-Stack.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-False ($start -match '\[switch\]\$OperationLockHeld') 'Canonical start has no public lock-bypass switch'
Assert-True ($start -match '\[System\.IO\.FileStream\]\$OperationLockHandle') 'Recovery start requires a live file-lock capability'
Assert-True ($start -match '\-RecoveryMode requires a live in-process operation lock handle') 'Recovery mode fails closed without the lock capability'
Assert-True ($start -match 'LocalAddresses\s*=\s*\$addresses') 'Canonical start retains every listener address'
Assert-True ($start.IndexOf('Assert-TrustedListener -Listener $listener', [System.StringComparison]::Ordinal) -lt $start.IndexOf('$lastProbe = Get-CpaHealth', [System.StringComparison]::Ordinal)) 'Canonical start validates the CPA listener before sending its API key'
Assert-True ($start -match 'function Start-ManagedProcess') 'Canonical services start with a controlled environment'
Assert-False ($start -match 'Start-Process\s+-FilePath\s+\$Settings\.(?:Cpa|Manager)\.Executable') 'Canonical services do not inherit the full parent environment'
Assert-True ($start -match 'PROC_THREAD_ATTRIBUTE_HANDLE_LIST|ProcThreadAttributeHandleList') 'Canonical services restrict inherited handles to isolated standard streams'
Assert-True ($start -match '\[CpaStack\.NativeProcessV1\]::Start') 'Canonical services use the native isolated process launcher'

$cli = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\cpa-stack.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
$launcherModule = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'modules\CpaStack.Launcher.psm1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($launcherModule -match "Invoke-CpaStackBundled\s+-HostAdapter\s+\`$HostAdapter\s+-Name\s+'Start-CPA-Stack\.ps1'") 'Public start executes the bundled trusted launcher through its host adapter'
Assert-False ($cli -match 'function\s+(?:Invoke-BundledScript|Get-StatusResult|Get-InitArguments)') 'Public CLI contains no duplicate v0.1 execution implementation'
Assert-False ($cli -match 'schemaVersion\s*=\s*1\s*\r?\n\s*command\s*=') 'Compatibility commands still return the v2 envelope'
Assert-True ($cli -match "Command 'register-root' is a legacy alias outside the v1 supported interface") 'The remaining register-root alias is explicitly outside the supported v1 interface'

$common = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\CpaStack.Common.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
$commonNativeStart = $common.IndexOf('using System;', $common.IndexOf("Add-Type -TypeDefinition @'", [System.StringComparison]::Ordinal), [System.StringComparison]::Ordinal)
$commonNativeEnd = $common.IndexOf("`n'@", $commonNativeStart, [System.StringComparison]::Ordinal)
$startNativeStart = $start.IndexOf('using System;', $start.IndexOf("Add-Type -TypeDefinition @'", [System.StringComparison]::Ordinal), [System.StringComparison]::Ordinal)
$startNativeEnd = $start.IndexOf("`n'@", $startNativeStart, [System.StringComparison]::Ordinal)
Assert-True ($commonNativeStart -ge 0 -and $commonNativeEnd -gt $commonNativeStart -and $startNativeStart -ge 0 -and $startNativeEnd -gt $startNativeStart) 'Both managed-process native launcher sources are present'
Assert-True ($common.Substring($commonNativeStart, $commonNativeEnd - $commonNativeStart) -ceq $start.Substring($startNativeStart, $startNativeEnd - $startNativeStart)) 'Common and standalone native process launchers remain byte-identical'
Assert-True ($common -match '&\s+\$gh\.Source\s+api\s+--hostname\s+github\.com') 'GitHub CLI release queries are pinned to github.com'
Assert-True ($common -match 'maximumReleaseJsonBytes\s*=\s*4194304') 'GitHub release JSON has a 4 MiB safety limit'
Assert-True ($common.Contains('Invoke-CpaStackSecureDownload -Uri "https://api.github.com/repos/$Repository/releases/latest" -Destination $temp -MaximumBytes $maximumReleaseJsonBytes')) 'Direct GitHub release JSON downloads enforce the streaming limit'
Assert-True ($common -match 'AllowAutoRedirect\s*=\s*\$false') 'Downloads disable automatic redirects for per-hop validation'
Assert-True ($common -match 'Copy-CpaStackBoundedStream.+?-MaximumBytes\s+\$MaximumBytes') 'Downloads enforce their byte limit while streaming'
Assert-True ($common -match "\.partial-'\s*\+\s*\[guid\]") 'Downloads use a unique partial file'
Assert-True ($common -match 'Remove-Item\s+-LiteralPath\s+\$partial') 'Failed downloads remove their partial file'
$downloadStart = $common.IndexOf('function Invoke-CpaStackSecureDownload', [System.StringComparison]::Ordinal)
$downloadEnd = $common.IndexOf('function Assert-CpaStackGitHubRepository', [System.StringComparison]::Ordinal)
Assert-True ($downloadStart -ge 0 -and $downloadEnd -gt $downloadStart) 'Secure downloader source boundaries are present'
$downloadSource = $common.Substring($downloadStart, $downloadEnd - $downloadStart)
Assert-False ($downloadSource -match 'Invoke-WebRequest|curl\.exe') 'Secure downloads have no unvalidated fallback transport'
Assert-True ($common -match 'function Read-CpaStackSecretJson') 'Secrets use a dedicated fixed-error JSON reader'
Assert-True ($common -match 'function Wait-CpaStackTrustedListener') 'Credentialed probes have a trusted-listener gate'
Assert-True ($common -match 'function Sync-CpaStackCanonicalLauncher') 'Updater refreshes the canonical desktop launcher target'
Assert-True ($common -match 'function Get-CpaStackCanonicalShortcutContract') 'Canonical shortcut arguments come from one shared contract'
Assert-True ($common -match 'function Set-CpaStackCanonicalShortcut') 'Canonical shortcut writes use the shared contract'
Assert-True ($common -match 'Arguments\s*=\s*''-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File') 'Canonical shortcut starts PowerShell with a hidden non-interactive window'
Assert-True ($common -match '\$link\.WindowStyle\s*=\s*\[int\]\$contract\.WindowStyle') 'Canonical shortcut minimizes its shell bootstrap'
Assert-True ($initialize -match 'Set-CpaStackCanonicalShortcut\s+-ShortcutPath\s+\$DesktopShortcut') 'Migration updates the authorized desktop shortcut through the hidden-window contract'
Assert-True ($initialize -match 'Assert-CpaStackCanonicalShortcutContract\s+-Shortcut\s+\$shortcut') 'Committed migration recovery revalidates the hidden-window shortcut contract'
Assert-True ($common -match '\[switch\]\$MinimalEnvironment') 'Candidate process launcher supports a minimal environment'
Assert-True ($common -match 'PROC_THREAD_ATTRIBUTE_HANDLE_LIST|ProcThreadAttributeHandleList') 'Managed processes inherit only the explicit null-device handle list'
Assert-True ($common -match 'function Test-CpaStackFileReadyForReplacement') 'Port shutdown verifies that the executable can be replaced'
Assert-True ($common -match '\$ownedProcess\.HasExited') 'Port shutdown waits for the exact process after the listener disappears'
Assert-True ($common -match 'function Get-CpaStackWindowsPowerShellModulePath') 'Windows PowerShell child processes use deterministic compatible module paths'
Assert-True ($common -match '\$proxyUri\.UserInfo') 'Managed process proxy URLs reject embedded credentials'
Assert-True ($common -match 'function Protect-CpaStackPrivateTree') 'CPA auth trees receive recursive ACL and reparse protection'
Assert-True ($common -match 'function Assert-CpaStackPrivateTree') 'Executable plugin trees receive recursive owner and ACL validation'
Assert-True ($common -match 'function Copy-CpaStackPluginTree') 'Plugin copies use a fail-closed protected-tree helper'
Assert-True ($common -match 'function Assert-CpaStackLegacyCpaSource') 'Legacy sensitive trees have a read-compatible mutable-access gate'
Assert-True ($common -match 'function Assert-CpaStackLegacyManagerSource') 'Legacy Manager runtime and data have a recursive mutable-access gate'
Assert-True ($common -match 'function Assert-CpaStackManagerRecoverySource') 'Legacy Manager recovery verifies executable, data key, and SQLite state before execution'
Assert-True ($common -match 'function Assert-CpaStackLegacyAncestorAcl') 'Legacy source ancestors are checked for subtree replacement rights'
Assert-True ($common -match 'function Get-CpaStackTreeManifest') 'Candidate runtimes have a recursive content manifest'
Assert-True ($common -match 'function Assert-CpaStackPathBudget') 'Windows PowerShell path limits have a shared preflight gate'
Assert-True ($common -match 'function Assert-CpaStackProjectedTreePathBudget') 'Tree copies validate every projected destination path'
Assert-True ($common.IndexOf('Assert-CpaStackJsonWritePathBudget -Paths @($Path)', [System.StringComparison]::Ordinal) -lt $common.IndexOf('$temp = $Path + ".tmp-"', [System.StringComparison]::Ordinal)) 'Atomic JSON suffixes are budgeted before temp creation'

$state = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Get-CpaStackState.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($state -match 'PowerShellWindowHidden') 'Discovery reports whether a CPA shortcut already hides PowerShell'
Assert-True ($state -match '-WindowStyle\\s\+Hidden') 'Shortcut discovery recognizes the hidden PowerShell argument without exposing raw arguments'

$stateScript = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Get-CpaStackState.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ([regex]::Matches($stateScript, 'LocalAddresses\s*=\s*@\(\$_\.LocalAddresses\)').Count -ge 2) 'Status preserves CPA and Manager listener addresses'
Assert-True ($stateScript -match '\$listenerTrusted\s*=\s*\(\$pathMatches\s+-and\s+\$addressMatches\s+-and\s+\$hashMatches\)') 'Canonical status listener trust includes path, address, and current hash'
Assert-True ($stateScript -match 'SecretsState\.Safe\.Ready\s+-and\s+\$listenerTrusted') 'Canonical status validates listener trust before credentialed probes'
Assert-True ($stateScript -match 'ValidateSet\(''cpa'', ''manager''\)\]\[string\]\$PendingSwitchComponent') 'Transition health checks select exactly one pending component'
Assert-True ($stateScript -match '\[string\]\$journal\.phase\s+-cne\s+''runtime-verified''') 'Transition health checks require a fully verified switched runtime'
Assert-True ($stateScript -match '\[string\]\$journal\.instanceId\s+-cne\s+\[string\]\$current\.instanceId') 'Transition health checks remain bound to the current stack instance'
Assert-True ($stateScript -match '\[string\]\$componentState\.sha256\s+-cne\s+\(\[string\]\$journal\.oldHash\)\.ToUpperInvariant\(\)') 'Transition health checks bind the pending old hash to current state'
foreach ($criticalParent in @('runtime\cli-proxy-api', 'runtime\manager-plus', 'data\manager-plus')) {
    Assert-True ($stateScript.Contains($criticalParent)) "Canonical status checks critical parent path $criticalParent"
}
Assert-True ($stateScript -match 'ManagerDataTree') 'Canonical status reports the recursive Manager data-tree trust state'
Assert-True ($stateScript -match "migrationStatus\s+-in\s+@\('ready', 'migrated'\)") 'Status accepts the latest Manager completed-migration state'
Assert-True ($stateScript -match "runtime\\cli-proxy-api\\plugins") 'Status recursively includes the optional CPA plugins tree in root security'
Assert-True ($stateScript -match 'Assert-CpaStackPrivateTree\s+-Root\s+\$authRoot.+-AllowInheritedDescendants') 'Status permits trusted inherited ACLs on runtime-created CPA auth descendants'
Assert-True ($stateScript -match '\$pluginPaths\s+-icontains\s+\$path') 'Status still rejects inherited ACLs inside the plugins tree'
Assert-True ($start -match "migrationStatus\s+-in\s+@\('ready', 'migrated'\)") 'Canonical start accepts the latest Manager completed-migration state'
Assert-True ($start -match 'Assert-PrivateCpaTree\s+-Root\s+\(Join-Path\s+\$Settings\.Cpa\.WorkingDirectory\s+''auth''\).+-AllowInheritedDescendants') 'Canonical start permits trusted inherited ACLs on runtime-created CPA auth descendants'
Assert-True ($start -match 'Assert-PrivateCpaTree\s+-Root\s+\$pluginsRoot') 'Canonical start validates optional plugins before launching CPA'

$testCpaCandidate = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Test-CpaCandidate.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($testCpaCandidate.IndexOf('Wait-CpaStackTrustedListener', [System.StringComparison]::Ordinal) -lt $testCpaCandidate.IndexOf('Get-CpaStackSecrets', [System.StringComparison]::Ordinal)) 'CPA candidate listener is trusted before secrets are loaded and sent'
Assert-True ($testCpaCandidate -match 'Start-CpaStackProcess.+-MinimalEnvironment') 'CPA candidate receives only the approved environment allowlist'
Assert-True ($testCpaCandidate.IndexOf('WaitForExit(10000)', [System.StringComparison]::Ordinal) -lt $testCpaCandidate.IndexOf('Get-CpaStackTreeManifest -Root $CandidateRuntime', [System.StringComparison]::Ordinal)) 'Candidate manifest is captured only after its process exits'

$testManagerCandidate = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Test-ManagerCandidate.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($testManagerCandidate.IndexOf('    Assert-FormalManagerListener', [System.StringComparison]::Ordinal) -lt $testManagerCandidate.IndexOf('$formalBaseline = Get-CpaStackManagerSetupBaseline', [System.StringComparison]::Ordinal)) 'Formal Manager listener is trusted before its baseline credential is sent'
Assert-True ($testManagerCandidate.IndexOf('Wait-CpaStackTrustedListener -Port $TempPort', [System.StringComparison]::Ordinal) -lt $testManagerCandidate.IndexOf('Set-CpaStackManagerCollector -ManagerPort $TempPort', [System.StringComparison]::Ordinal)) 'Manager candidate listener is trusted before setup secrets are sent'
Assert-True ($testManagerCandidate -match 'Start-CpaStackProcess.+-MinimalEnvironment') 'Manager candidate receives only the approved environment allowlist'

$switchCpa = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Switch-CpaRuntime.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($switchCpa.IndexOf('Wait-CpaStackTrustedListener', [System.StringComparison]::Ordinal) -lt $switchCpa.IndexOf('Get-CpaStackSecrets', [System.StringComparison]::Ordinal)) 'Formal CPA listener is trusted before switch validation sends secrets'
Assert-True ($switchCpa -match 'Start-CpaStackProcess.+-MinimalEnvironment') 'Formal CPA does not inherit unrelated parent secrets'
Assert-True ($switchCpa -match 'Assert-CpaStackPrivateTree\s+-Root\s+\$sourcePlugins') 'CPA switch validates preserved plugins before stopping the source service'
Assert-True ($switchCpa -match 'A non-in-place CPA migration must start the exact candidate runtime that was tested') 'Non-in-place switching requires CandidatePackageRoot to equal TargetRuntime'
Assert-True ([regex]::Matches($switchCpa, 'Get-CpaStackTreeManifest\s+-Root\s+\$TargetRuntime').Count -ge 2) 'Non-in-place switching checks the target manifest before and after stopping legacy CPA'
Assert-False ($switchCpa -match 'Copy-Item\s+-LiteralPath\s+\$SourceConfig\s+-Destination\s+\$targetConfig') 'Non-in-place switching never recopies the untested legacy config'
Assert-False ($switchCpa -match 'Copy-CpaStackAuthTree\s+-Source\s+\(Join-Path\s+\$SourceRuntime') 'Non-in-place switching never recopies live legacy auth'
Assert-False ($switchCpa -match 'Copy-CpaStackPluginTree\s+-Source\s+\$sourcePlugins') 'Non-in-place switching never recopies live legacy plugins'
Assert-True ([regex]::Matches($switchCpa, 'Protect-CpaStackSecretFile\s+-Path\s+\$(?:targetExe|sourceExe)').Count -ge 2) 'CPA switch and rollback restore the executable owner and ACL before restart'
Assert-True ($switchCpa.IndexOf('Assert-CpaStackJsonWritePathBudget', [System.StringComparison]::Ordinal) -lt $switchCpa.IndexOf('Stop-CpaStackPort -Port $Port', [System.StringComparison]::Ordinal)) 'CPA switch path budget fails before stopping the source service'

$switchManager = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Switch-ManagerRuntime.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($switchManager.IndexOf('Wait-CpaStackTrustedListener -Port $ManagerPort', [System.StringComparison]::Ordinal) -lt $switchManager.IndexOf('Invoke-CpaStackHttpJson -Uri "http://127.0.0.1:$ManagerPort/usage-service/info"', [System.StringComparison]::Ordinal)) 'Formal Manager listener is trusted before switch validation sends secrets'
Assert-True ($switchManager -match 'Start-CpaStackProcess.+-MinimalEnvironment') 'Formal Manager does not inherit unrelated parent secrets'
Assert-True ([regex]::Matches($switchManager, 'Protect-CpaStackSecretFile\s+-Path\s+\$(?:targetExe|sourceExe)').Count -ge 2) 'Manager switch and rollback restore the executable owner and ACL before restart'
Assert-True ([regex]::Matches($switchManager, 'Protect-CpaStackPrivateTree\s+-Root\s+\$(?:TargetData|SourceData)').Count -ge 2) 'Manager switch and rollback protect the full data tree including WAL and SHM'
Assert-True ([regex]::Matches($switchManager, 'Assert-CpaStackManagerRecoverySource').Count -ge 2) 'Non-in-place Manager rollback verifies the legacy source before and after ACL hardening'
Assert-True ([regex]::Matches($switchManager, 'Stop-CpaStackStartedProcess\s+-Process\s+\$(?:targetProcess|sourceProcess)').Count -ge 2) 'Manager recovery stops started processes by their fixed process object even when no listener exists'
Assert-False ($switchManager -match 'Protect-CpaStackSecretFile\s+-Path\s+\$(?:targetDb|targetDataKey|sourceDb|sourceDataKey)') 'Manager ACL repair is not limited to database and data-key leaves'
Assert-True ($switchManager.IndexOf('Assert-CpaStackJsonWritePathBudget', [System.StringComparison]::Ordinal) -lt $switchManager.IndexOf('$collectorDisabled = $true', [System.StringComparison]::Ordinal)) 'Manager switch path budget fails before disabling the collector'

$upgrade = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Invoke-CpaStackUpgrade.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($upgrade -match 'DeferFinalCommit') 'Upgrade defers switch journal cleanup until current state is committed'
Assert-True ($upgrade -match 'AllowUnknownVersionReplacement') 'Unknown-version replacement is explicit'
Assert-True ($upgrade -match 'if\s*\(-not\s+\$RecoverOnly\)\s*\{\s*Assert-CpaStackFreeSpace') 'Recovery-only bypasses the normal 1 GiB upgrade capacity gate'
Assert-True ($upgrade.IndexOf('Set-UpgradeJournalPhase -Phase "testing-manager"', [System.StringComparison]::Ordinal) -lt $upgrade.IndexOf('Set-UpgradeJournalPhase -Phase "switching-cpa"', [System.StringComparison]::Ordinal)) 'Both component candidates are tested before the first formal switch'
Assert-True ($upgrade.IndexOf('Assert-SwitchedServicesHealthy -PendingSwitchComponent cpa', [System.StringComparison]::Ordinal) -lt $upgrade.IndexOf('Set-CurrentComponentState -Component cpa', [System.StringComparison]::Ordinal)) 'CPA transition health is verified before current state commits the new hash'
Assert-True ($upgrade.IndexOf('Assert-SwitchedServicesHealthy -PendingSwitchComponent manager', [System.StringComparison]::Ordinal) -lt $upgrade.IndexOf('Set-CurrentComponentState -Component manager', [System.StringComparison]::Ordinal)) 'Manager transition health is verified before current state commits the new hash'
Assert-False (([System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\cpa-stack.ps1'), [System.Text.UTF8Encoding]::new($false, $true))) -match 'PendingSwitchComponent') 'The public CLI does not expose the internal transition health mode'
Assert-True ($upgrade -match 'Immediate switch recovery failed') 'Outer switch failures attempt immediate in-process recovery before returning'
Assert-True ($upgrade -match 'Copy-CpaStackPluginTree\s+-Source\s+\$plugins') 'CPA candidate preparation copies plugins through the protected-tree helper'
Assert-True ($upgrade -match 'Assert-CpaStackPrivateTree\s+-Root\s+\$activePlugins') 'Top-level upgrade fails closed on an unsafe preserved plugins tree'
Assert-False ($upgrade -match 'Protect-CpaStackPrivateTree\s+-Root\s+\$activePlugins') 'Top-level upgrade does not erase evidence of an unsafe plugins ACL'
Assert-True ($upgrade -match 'Repair-CpaStackRecordedExecutableAcl') 'Upgrade repairs only hash-bound active executable ACL drift before trusted preflight'
Assert-True ($upgrade.IndexOf('Repair-CpaStackRecordedExecutableAcl', [System.StringComparison]::Ordinal) -lt $upgrade.IndexOf('$preflight = Invoke-ChildPowerShellJson', [System.StringComparison]::Ordinal)) 'Hash-bound executable ACL repair occurs before canonical preflight'
Assert-True ($upgrade.IndexOf('Assert-UpgradeSwitchPathBudget', $upgrade.IndexOf('try {', [System.StringComparison]::Ordinal), [System.StringComparison]::Ordinal) -lt $upgrade.IndexOf('Set-UpgradeJournalPhase -Phase "switching-cpa"', [System.StringComparison]::Ordinal)) 'Upgrade budgets both components before the first formal switch'
Assert-True ($initialize.IndexOf('Assert-InitializationSwitchPathBudget', $initialize.IndexOf('try {', [System.StringComparison]::Ordinal), [System.StringComparison]::Ordinal) -lt $initialize.IndexOf('Set-InitializeJournalPhase -Phase "switching"', [System.StringComparison]::Ordinal)) 'Initialization budgets both components before the first formal switch'
Assert-True ($upgrade.LastIndexOf('$result | ConvertTo-Json', [System.StringComparison]::Ordinal) -lt $upgrade.LastIndexOf('if (-not $result.success)', [System.StringComparison]::Ordinal)) 'Upgrade emits its structured result before a non-zero exit'
foreach ($journalScript in @('Adopt-CpaStackLegacyCanonical.ps1', 'Initialize-CpaStack.ps1', 'Invoke-CpaStackUpgrade.ps1', 'Switch-CpaRuntime.ps1', 'Switch-ManagerRuntime.ps1')) {
    $journalText = [System.IO.File]::ReadAllText((Join-Path $skillRoot ('scripts\' + $journalScript)), [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($journalText -match 'instanceId') "$journalScript binds state or journals to the instance marker"
}
$adoption = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'scripts\Adopt-CpaStackLegacyCanonical.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($adoption -match 'adopt\.pending\.json') 'Legacy canonical adoption is journaled'
Assert-True ($adoption -match 'Assert-LegacyCanonicalLayout') 'Legacy canonical adoption validates fixed paths and hashes'
Assert-Equal 3 ([regex]::Matches($adoption, '(?<!\d)8317(?!\d)').Count) 'Source adoption keeps the fixed CPA formal-port contract'
Assert-Equal 3 ([regex]::Matches($adoption, '(?<!\d)18317(?!\d)').Count) 'Source adoption keeps the fixed Manager formal-port contract'
Assert-True ($adoption -match 'Protect-CpaStackPrivateTree\s+-Root\s+\$layout\.auth') 'Legacy canonical adoption hardens the full CPA auth tree'
Assert-True ($adoption -match 'Protect-CpaStackPrivateTree\s+-Root\s+\$layout\.plugins') 'Legacy canonical adoption hardens the optional CPA plugins tree'
Assert-True ($adoption -match 'Protect-CpaStackPrivateTree\s+-Root\s+\$layout\.managerData') 'Legacy canonical adoption hardens the entire Manager data tree'
Assert-True ($adoption.LastIndexOf('$result | ConvertTo-Json', [System.StringComparison]::Ordinal) -lt $adoption.LastIndexOf('if (-not $result.success)', [System.StringComparison]::Ordinal)) 'Adoption emits its structured result before a non-zero exit'

$agent = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'agents\openai.yaml'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($agent -match '\$cpa-safe-upgrade') 'openai.yaml default prompt names the skill'

$installer = [System.IO.File]::ReadAllText((Join-Path $repo 'install.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($installer -match 'stableCliPath') 'Installer returns the stable human CLI path'
Assert-True ($installer -match 'stableUninstallPath') 'Installer returns an installed uninstall path'

$workflow = [System.IO.File]::ReadAllText((Join-Path $repo '.github\workflows\ci.yml'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($workflow -match "tags:\s*\['v\*'\]") 'CI runs for release tags'
Assert-True ($workflow -match 'actions/setup-python@') 'CI installs a pinned Python runtime'

$testAll = [System.IO.File]::ReadAllText((Join-Path $repo 'tools\Test-All.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($testAll -match 'Get-Command\s+python\s+-ErrorAction\s+Stop') 'Full tests fail when Python is unavailable'
Assert-True ($testAll.Contains('[Environment]::SetEnvironmentVariable(''CPA_STACK_ROOT'', `$testStackRoot, ''Process'')')) 'Every isolated test process resolves an explicit case-local stack root'
Assert-True ($testAll -match 'Resolve-CpaStackControlRoot') 'The isolated runner verifies root resolution inside the requested test host'
Assert-True ($testAll -match 'PowerShell test host mismatch') 'The isolated runner verifies its requested PowerShell edition and version'
Assert-True ($testAll -match 'Register-CpaStackTestProcess\s+-Guard\s+\$Guard\s+-Process\s+\$process') 'The isolated runner enters the kill-on-close Job before releasing its payload'
Assert-True ($testAll -match 'before test' -and $testAll -match 'while running test') 'Every test case checks the production baseline before and after execution'
Assert-False ($testAll -match "SetEnvironmentVariable\('LOCALAPPDATA'") 'The runner does not claim that an ineffective LOCALAPPDATA environment override isolates Windows known folders'

foreach ($fixtureBoundTest in @(
    'Adoption.Tests.ps1',
    'FixtureStateIsolation.Tests.ps1',
    'InitializeRecoverySafety.Tests.ps1',
    'Install.Tests.ps1',
    'InstallV2.Tests.ps1',
    'LanConfiguration.Tests.ps1',
    'PathSafety.Tests.ps1',
    'TransactionIntegration.Tests.ps1'
)) {
    $fixtureBoundText = [System.IO.File]::ReadAllText((Join-Path $repo ('tests\' + $fixtureBoundTest)), [System.Text.UTF8Encoding]::new($false, $true))
    Assert-True ($fixtureBoundText -match 'New-CpaStackUpdaterTestFixture') "$fixtureBoundTest isolates stateful scripts through a rewritten repository fixture"
}
$adoptionTest = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\Adoption.Tests.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
Assert-True ($adoptionTest -match 'New-CpaStackTestPortPlan') 'Adoption integration uses dynamically allocated high ports'
Assert-True ($adoptionTest -match 'Register-CpaStackTestProcess\s+-Guard\s+\$Guard\s+-Process\s+\$process') 'Adoption integration enters the test Job before releasing its payload'
Assert-True ($adoptionTest -match '\[regex\]::Replace\(\$adoptionHarnessText') 'Adoption integration rewrites only its executable fixture copy away from production ports'
$testHelpers = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\TestHelpers.ps1'), [System.Text.UTF8Encoding]::new($false, $true))
foreach ($statefulRelativePath in @('install.ps1', 'CpaStack.Common.ps1', 'Start-CPA-Stack.ps1')) {
    Assert-True ($testHelpers.Contains($statefulRelativePath)) "Fixture construction structurally verifies $statefulRelativePath state-home rewriting"
}

'Static tests passed.'
