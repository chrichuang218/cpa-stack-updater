# CPA Stack Updater

[![CI](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml/badge.svg)](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)](https://github.com/chrichuang218/cpa-stack-updater)

[中文](README.md)

Transactional Windows migration, recovery, and upgrades for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and [CPA Manager Plus](https://github.com/seakee/CPA-Manager-Plus).

v0.2 uses a thin Skill over a small, stable transaction executor. The Skill selects a public operation; bundled PowerShell owns discovery, ACL validation, SQLite snapshots, candidate verification, switching, and rollback.

> This is a community project. It is not affiliated with or endorsed by either upstream project.

## v0.2 architecture

```text
status (read-only)
  +-- requiredOperation=recover --> recover
  +-- requiredOperation=migrate --> migrate
  +-- canonical healthy ---------> upgrade

shortcut / lan / start / Skill installation are independent operations
```

`upgrade` never migrates, recovers, changes a shortcut, or enables LAN implicitly.

## Safety properties

- Candidate processes use dynamically allocated, unused high loopback ports; candidate ports are not a fixed public interface.
- Formal ports come from the managed stack configuration.
- Release metadata and assets come only from two pinned official upstream repositories over HTTPS, with checksum and SHA256 verification.
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

## Install or update the Skill

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

## Use the v2 CLI

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cpaCli = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
$root = 'E:\CPA-Stack'
```

`E:` is only an example. Local C/D/E volumes, spaces, and non-ASCII paths are supported when they pass the filesystem safety checks.

### 1. Inspect

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli status -Root $root -Json
```

A completed inspection exits 0. An unhealthy stack is represented by `outcome=Blocked`; an inspection protocol failure returns `success=false` and a non-zero exit code. Use `requiredOperation` to select the next explicit command.

### 2. Recover or migrate explicitly

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli recover -Root $root -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli migrate -Root $root -Json
```

Run only the operation required by status and authorized by the user. If automatic discovery is ambiguous, pass a migration request with `-RequestPath`. The request stores source paths, a secrets-file path, and optional formal ports—never secret values. See [migration-request.md](skills/cpa-safe-upgrade/references/migration-request.md).

### 3. Upgrade a healthy canonical stack

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root $root -Json
```

Unknown local versions are blocked by default to avoid replacing a prerelease build with latest stable. Only after a second explicit acknowledgement:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade `
  -Root $root `
  -AllowUnknownVersionReplacement `
  -Json
```

### 4. Start

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start -Root $root -NoBrowser
```

`start` does not recover a pending transaction implicitly.

## Desktop quick launch

The installer creates the stable launcher. A separate managed operation owns the desktop shortcut. Check first; Ensure only when it is missing or drifted:

```powershell
$shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CPA Local Start (New).lnk'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli shortcut `
  -Action Check -Root $root -ShortcutPath $shortcut -Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli shortcut `
  -Action Ensure -Root $root -ShortcutPath $shortcut -Json
```

An identifiable legacy shortcut requires explicit `-AdoptExisting`; unknown conflicts are never overwritten.

## LAN exposure

LAN is a separate high-risk operation. Explain the exposure and obtain explicit authorization before changing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli lan -Action Set -Mode Lan -Root $root -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli lan -Action Set -Mode Loopback -Root $root -Json
```

Candidate validation remains loopback-only.

## Schema v2

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
  "updaterVersion": "1.0.0"
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

v1.0.0 is the first supported release. The 0.x line is development history only; compatibility with old updater installations, journals, or transaction state is not guaranteed. Existing CPA/Manager data can still be moved into a managed root on any local drive through the supported `migrate` flow.

## Security reports

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Do not attach keys, `data.key`, SQLite files, auth data, complete configuration, or raw request logs to issues.

## License

MIT. Upstream projects and downloaded binaries retain their own licenses.
