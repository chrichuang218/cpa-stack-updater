# CPA Stack Updater

[![CI](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml/badge.svg)](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)](https://github.com/chrichuang218/cpa-stack-updater)

[中文](README.md)

Transactional Windows migration, recovery, and upgrades for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and [CPA Manager Plus](https://github.com/seakee/CPA-Manager-Plus). Tell Codex the outcome you want; bundled PowerShell owns discovery, ACL validation, SQLite snapshots, candidate verification, switching, and rollback.

> This is a community project. It is not affiliated with or endorsed by either upstream project.

## Use Codex directly

For the first install, send Codex:

```text
https://github.com/chrichuang218/cpa-stack-updater

Install this CPA upgrade Skill. My CPA root is E:\CPA-Stack.
```

Then say:

```text
Use $cpa-safe-upgrade to upgrade CPA.
```

Future requests can simply say “upgrade CPA,” “check CPA,” or “create the CPA desktop launcher.” The root is needed only for first install, switching instances, or isolated tests. Upgrade validates and updates the Skill first, then handles recovery, first migration, stable replacement, and shortcut maintenance without repeated confirmation. LAN remains separately authorized.

## Automatic upgrade

```text
upgrade
  +-- newer updater ------------> verify, atomically install, re-exec
  +-- pending transaction -------> recover (at most once)
  +-- canonical not established -> migrate (at most once)
  +-- ready ---------------------> upgrade
  +-- after success -------------> shortcut Ensure

lan / start / manual Skill installation are independent operations
```

One `upgrade` invocation authorizes verified updater self-update, recovery, migration, stable replacement, and default desktop shortcut maintenance. A failed updater check or install stops before runtime work. LAN remains separate.

## Safety properties

- Candidate processes use dynamically allocated, unused high loopback ports; candidate ports are not a fixed public interface.
- Formal ports come from the managed stack configuration.
- Release metadata and assets come only from two pinned official upstream repositories over HTTPS, with checksum and SHA256 verification.
- Skill self-update accepts only a newer stable Release from this repository and verifies the versioned ZIP, `checksums.txt`, both GitHub digests, and bundled VERSION files.
- ZIP traversal, entry count, and expanded size are checked before extraction.
- Manager data uses SQLite online backup plus `quick_check`, required-table, and historical-watermark checks.
- Secret-free journals bind every transaction to an instance ID and support hard-interruption recovery.
- Shutdown pins a verified listener `Process`; an unknown PID/path is never terminated.
- Long-lived services have no console and inherit only explicit `NUL` standard handles.
- The managed root, runtime, auth/plugins, Manager data, and critical parent directories are checked for owner, DACL, and reparse safety.
- Windows PowerShell 5.1 path budgets are checked before a formal service is stopped.
- A failed formal switch restores the previous healthy runtime.
- The updater installer changes only the Skill, stable launcher, and root registration. It does not upgrade CPA/Manager or alter LAN.

See [docs/safety-model.md](docs/safety-model.md) for the full model.

## Requirements

- Windows 10/11 x64
- Windows PowerShell 5.1 or PowerShell 7
- Python 3.10+
- A local NTFS or ReFS volume
- An existing CLIProxyAPI and CPA Manager Plus installation for migration

The repository contains no third-party executables, real configuration, keys, databases, or telemetry.

## Manual Skill install or update (optional)

Download and extract a trusted package from [Releases](https://github.com/chrichuang218/cpa-stack-updater/releases/latest). Start with a strictly read-only check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Action Check `
  -StackRoot 'E:\CPA-Stack' `
  -Json
```

After confirmation, install or update atomically:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -Action Update `
  -StackRoot 'E:\CPA-Stack' `
  -Json
```

Use `-CodexHome` for a non-default Codex home. The installer uses two slots and a protected write-ahead journal. Concurrent updates commit once, and a later Update recovers a hard-interrupted install. When an explicit `StackRoot` is new and empty, the installer creates a protected instance marker and stable launcher so a later explicit `migrate` can use the same root; it does not install or start the CPA runtime. The launcher is written to `<StackRoot>\ops\Start-CPA-Stack.ps1`, and no desktop shortcut is created.

`Bypass` applies only to this process and does not change persistent execution policy.

## Run the CLI manually (optional)

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cpaCli = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
$root = 'E:\CPA-Stack'
```

`E:` is only an example. Local C/D/E volumes, spaces, and non-ASCII paths are supported when they pass the filesystem safety checks.

### 1. One-command upgrade

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root $root -Json
```

The command runs `updater → recover → migrate → runtime upgrade → shortcut Ensure` without secondary authorization. A newer updater is verified, installed atomically, and re-executed before runtime work; failure stops. Unknown or unverifiable old binaries are replaced by the verified latest stable release, and a successful runtime upgrade maintains the default desktop quick launcher.

When discovery is ambiguous, provide the migration request to the same command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root $root -RequestPath '<request.json>' -Json
```

The request stores source paths, a secrets-file path, and optional formal ports—never secret values. See [migration-request.md](skills/cpa-safe-upgrade/references/migration-request.md).

Real safety failures still stop immediately, including ambiguous journals, unknown port owners, untrusted ACL/reparse state, checksum or candidate-health failures, disk/path budgets, SQLite watermark regressions, and rollback failures.

#### Windows Task Scheduler

Use `powershell.exe` with:

```text
-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<CodexHome>\skills\cpa-safe-upgrade\scripts\cpa-stack.ps1" upgrade -Root "<managed root>" -Json
```

Exit code `0` means the updater/runtime upgraded or was already current; non-zero means a real failure. The command reads no stdin, opens no browser, emits no confirmation prompt, and the next scheduled run automatically handles one recoverable pending transaction.

### 2. Start

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start -Root $root -NoBrowser
```

`start` does not recover a pending transaction implicitly.

## Desktop quick launch

After a successful `upgrade`, the updater automatically creates or updates the current user's `CPA 本地启动.lnk`. The same idempotent operation can also be invoked directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli shortcut `
  -Action Ensure -Root $root -Json
```

The shortcut uses the bundled icon and keeps one visible PowerShell window, preferring PowerShell 7 (`pwsh.exe`) and falling back to Windows PowerShell 5.1. The desktop entry runs the Fast starter directly: no ACL, hash, state, port-health, or Manager-readiness preflight is performed. Configured processes are reused immediately; missing processes are launched directly before the management page opens. Full checks remain in CLI `start` and update transactions. Recognizable legacy CPA shortcuts are backed up and adopted automatically; unknown unrelated conflicts are never overwritten.

## LAN exposure

LAN is a separate high-risk operation. Explain the exposure and obtain explicit authorization before changing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli lan -Action Set -Mode Lan -Root $root -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli lan -Action Set -Mode Loopback -Root $root -Json
```

Candidate validation remains loopback-only.

## Structured result (developer reference)

Every public command returns a v2 envelope:

```json
{
  "schemaVersion": 2,
  "operation": "upgrade",
  "success": true,
  "outcome": "Changed",
  "changed": true,
  "rolledBack": false,
  "recovered": false,
  "root": "E:\\CPA-Stack",
  "before": null,
  "after": null,
  "warnings": [],
  "error": null,
  "updaterVersion": "1.1.0"
}
```

A non-null error always contains stable `code` and `message` fields. Operation-specific diagnostic details must not be confused with internal journal or dynamic candidate-port contracts.

See [docs/cli.md](docs/cli.md) for complete syntax.

## Uninstall

```powershell
$uninstaller = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\Uninstall-CpaSafeUpgrade.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -Yes
```

Uninstall removes only owned Skill slots with valid markers. It does not touch CPA runtime, Manager data, or a legacy installation.

## Root resolution

Order:

1. `-Root`
2. `CPA_STACK_ROOT`
3. the protected root locator
4. `%LOCALAPPDATA%\CPAStack`

Drive roots, UNC paths, Git worktrees, Windows/Program Files trees, the user-profile root, and unsupported filesystems are rejected.

## Tests and release status

Tests use isolated root/state/lock directories, dynamically allocated high loopback ports, and a `KILL_ON_JOB_CLOSE` Job Object. Formal ports, PIDs, roots, control files, executable hashes, and critical ACLs are release-blocking invariants. CI runs the complete suite under both Windows PowerShell 5.1 and PowerShell 7.

## Security reports

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Do not attach keys, `data.key`, SQLite files, auth data, complete configuration, or raw request logs to issues.

## License

MIT. Upstream projects and downloaded binaries retain their own licenses.
