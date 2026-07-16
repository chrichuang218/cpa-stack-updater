# CPA Stack Updater

[![CI](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml/badge.svg)](https://github.com/chrichuang218/cpa-stack-updater/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)](https://github.com/chrichuang218/cpa-stack-updater)

[简体中文](README.md)

Safe, transactional Windows upgrades for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and [CPA Manager Plus](https://github.com/seakee/CPA-Manager-Plus).

New binaries are downloaded from official GitHub releases, verified, and tested on loopback-only temporary ports before production is touched. Failed formal switches restore the last healthy runtime automatically.

> Community project. It is not affiliated with or endorsed by either upstream project.

## Why this exists

Manual CPA upgrades tend to accumulate copied runtimes, stale ZIP files, test databases, launch scripts, and unclear rollback folders. CPA Stack Updater turns that into one managed root with a repeatable transaction:

```text
discover -> plan -> download and verify -> candidate tests -> snapshot
        -> atomic switch -> formal verification -> commit
                           \-> automatic restore on failure
```

The existing installation can live on C:, D:, E:, a path with spaces, or a non-English path. The updater discovers the running executables and migrates only the active runtime and active Manager data.

## Safety properties

- Candidate CPA and Manager services bind only to `127.0.0.1`.
- Official archives and checksums are verified with SHA256.
- ZIP entries are checked for traversal and size limits before extraction.
- Manager SQLite is copied through the SQLite online-backup API.
- A per-Windows-account, cross-session lock prevents concurrent upgrades, installs, and uninstalls.
- Secret-free journals bind to an instance ID and recover interrupted transactions.
- Candidate hashes are checked again immediately before switching.
- Long-lived services start without a console window and inherit only explicit `NUL` standard handles, so they cannot keep an upgrade command's output pipe open.
- The updater fixes the verified listener's `Process` before stopping it. Even if the listener disappears first, it waits for that same process and executable lock; candidates started by the updater are also cleaned up by their fixed process when they never bind.
- The managed root is restricted to the current user, SYSTEM, and Administrators.
- Direct runtime parents and the full Manager data tree, including WAL/SHM, are checked for trusted owners, ACLs, and reparse points.
- Before executing an old Manager during a non-in-place rollback, the updater revalidates the executable, `data.key`, required business tables, and the `usage_events` count/max-id/max-timestamp watermarks. Pre-existing settings and model-price data must not decrease.
- SQLite validation protects business-data semantics; it does not require identical database SHA256, file size, page layout, WAL/SHM, checkpoint, or rollup bytes.
- All switch paths are preflighted against the Windows PowerShell 5.1 budgets of 247 characters for directories and 259 for files, before any production stop.
- Unknown port owners are never killed.
- Legacy directories are never deleted without a separate explicit request.

See [docs/safety-model.md](docs/safety-model.md) for the complete trust and transaction model.

## Requirements

- Windows 10 or Windows 11, x64
- Windows PowerShell 5.1 or PowerShell 7
- Python 3.10 or newer for SQLite online backups that can be generated, reopened, and checked
- Local NTFS or ReFS destination
- Existing CLIProxyAPI and CPA Manager Plus when performing a migration

Git is not required for a normal installation. It is only needed if you choose to clone the repository for development.

The repository contains no third-party executables, user configuration, keys, databases, or telemetry.

## Quick start

Download and extract the latest `Source code (zip)` from [Releases](https://github.com/chrichuang218/cpa-stack-updater/releases/latest). Open PowerShell in the extracted directory, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -StackRoot 'E:\CPA-Stack'
```

`Bypass` applies only to this installer process. It does not change the machine or user execution policy. Developers can clone the repository with Git and run the same command.

The extracted directory can be deleted after installation. Always use the installed stable CLI afterward; define it whenever you open a new PowerShell session:

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cpaCli = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\cpa-stack.ps1'
```

`E:` is only an example. Use a local NTFS/ReFS directory on a drive that actually exists. The installer writes an ownership marker, and uninstall refuses to remove an unowned look-alike directory.

Preview without changing anything:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli plan -Root 'E:\CPA-Stack' -Json
```

Migrate an existing healthy installation when necessary, then upgrade both services. Desktop shortcuts are not changed silently. If the old shortcut still targets the legacy launcher, using it after migration or reboot can start the old runtime and data again. Before the first migration, explicitly choose one startup path:

- If you authorize the updater to repoint the discovered CPA desktop shortcut to the canonical launcher, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root 'E:\CPA-Stack' -UpdateDesktopShortcut -Json
```

  The refreshed `.lnk` starts the canonical launcher through `powershell.exe -NonInteractive -WindowStyle Hidden`, so double-clicking it does not show a PowerShell window. Direct CLI commands remain visible, and bundled PowerShell scripts reuse the caller's console instead of opening another window.

- If you do not authorize a shortcut change, run the upgrade without that switch. Do not use the old shortcut afterward; always start the managed stack through the canonical CLI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root 'E:\CPA-Stack' -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start -Root 'E:\CPA-Stack'
```

If the existing binary version cannot be identified reliably, replacement is blocked to avoid downgrading a nightly or prerelease build to latest stable. After reviewing and explicitly accepting that risk:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Root 'E:\CPA-Stack' -AllowUnknownVersionReplacement -Json
```

After the first successful initialization, the selected root is registered under the current Windows profile. Future commands can omit `-Root`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli status -Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade -Json
```

If the target was created by an earlier version of this tool and already has canonical runtime/data but no `instanceId` marker, `upgrade` first verifies fixed paths, running processes, and recorded hashes. It then adopts the root in place through a secret-free journal and hardens its ACLs without recopying or clearing Manager data.

## Codex skill

`install.ps1` installs `cpa-safe-upgrade` into `$CODEX_HOME\skills`, or `$HOME\.codex\skills` when `CODEX_HOME` is unset.

Example prompt:

> Use $cpa-safe-upgrade to discover my existing CPA installation, migrate it to E:\CPA-Stack, and safely upgrade both services.

The Skill calls the same `cpa-stack.ps1` interface as human users. It does not improvise stop/copy/start commands.

To update the updater, download a newer Release and run `install.ps1` again; the installer atomically replaces the same stable path. If it reports that the Skill directory is in use, close editors viewing the installed `SKILL.md` or terminals whose working directory is inside that Skill, then retry. The installer never terminates those processes and preserves the current Skill and rollback slot on failure. A result with `success=true` and `complete=false` means the new Skill was committed but launcher, root-locator, or old-slot cleanup returned explicit `postCommitWarnings`; resolve that lock or ACL issue and run the installer again. The original ZIP is not needed for uninstall:

```powershell
$uninstaller = Join-Path $codexHome 'skills\cpa-safe-upgrade\scripts\Uninstall-CpaSafeUpgrade.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -Yes
```

Uninstall removes only the owned Skill and its previous-version copy. CPA runtimes and Manager data are never touched.

## Any drive or directory

Managed-root precedence is:

1. `-Root`
2. `CPA_STACK_ROOT`
3. the protected root locator from the last successful initialization
4. `%LOCALAPPDATA%\CPAStack`

Examples:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli plan -Root 'C:\Tools\CPA Stack'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli plan -Root 'D:\服务\CPA-Stack'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli plan -Root 'E:\CPA-Stack'
```

UNC paths, drive roots, exFAT, Git worktrees, the Windows/Program Files trees, and the user-profile root itself are rejected. A dedicated directory under LocalAppData remains supported.

## Commands

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli status        [-Root <path>] [-Json]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli plan          [-Root <path>] [-Json]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli init          [-Root <path>] [source options] [-Json]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli upgrade       [-Root <path>] [source options] [-AllowUnknownVersionReplacement] [-Json]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli start         [-Root <path>] [-NoBrowser]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cpaCli register-root -Root <path> [-Json]
```

See [docs/cli.md](docs/cli.md) for explicit-source and protected-secret examples.

## Managed layout

```text
CPA-Stack/
├── .cpa-stack-instance.json
├── config/
├── runtime/
│   ├── cli-proxy-api/
│   └── manager-plus/
├── data/manager-plus/
├── ops/Start-CPA-Stack.ps1
├── state/
├── releases/current/
├── rollback/last-known-good/
├── work/
└── logs/
```

The retention model is `current + last-known-good`. Candidate and work directories are temporary.

## Current release stage

`v0.1.x` is the public hardening series. Rollout should progress through 5, then 20, then 100 distinct Windows environments. Do not describe a new version as production-proven until its recovery and path matrix has passed on real machines.

## Contributing and security

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing transaction code.
- Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).
- Never attach keys, `data.key`, SQLite databases, auth files, full configuration, or raw request logs to an issue.

## License

MIT. Upstream projects and downloaded binaries retain their own licenses.
