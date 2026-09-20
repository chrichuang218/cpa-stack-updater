# Real-runtime isolated upgrade test

Run only with explicit permission to copy local credentials and history:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\Test-RealUpgrade.ps1 -SourceRoot 'E:\CPA-Stack' -TestRoot 'E:\CPA-stack-test' -CpaPort 28317 -ManagerPort 28318
```

The destination must not exist. The runner copies runtime/auth, takes an online
SQLite snapshot, creates a new instance identity, and omits production journals,
rollback state and runtime overrides. Only the offline test snapshot is rebound
to the test CPA. Its collector and account automation are disabled; history and
encrypted credentials are retained. No production database settings are changed.

The existing fixture isolates the root locator; the runner additionally redirects
the desktop shortcut into the test directory. It installs the current local source
into a separate Codex directory and calls public `start`, then one public `upgrade`.
Updater release checks remain enabled, but installing a newer updater is refused:
it would overwrite the local fix and fixture isolation. Such a refusal is a failed
test, not a successful runtime upgrade.

Production listener identity and key-file hashes are compared before/after.
This is a same-account integration fixture, **not an OS/network sandbox**. Copied
credentials retain their upstream access; do not send inference requests through
the test instance. This is also not an exact point-in-time snapshot of all auth
files; SQLite history uses the consistent online backup API.

Results stay under the test root (`test-result.json`, `test-start.json`,
`test-upgrade.json`). Any failure stops subsequent runtime operations and retains
evidence. Test services, if started, remain available for inspection. There is no
automatic production installation, recovery, commit, push or release.
