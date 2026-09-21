# GitHub API authentication

The secure downloader uses the current user's GitHub CLI credential for HTTPS
requests to `api.github.com` on port 443. Sign in with `gh auth login --hostname
github.com` in an interactive terminal, then verify with `gh auth status
--hostname github.com`. Scheduled runs must use the same Windows user and have
`gh.exe` on PATH. No token needs to be copied into an automation prompt or file.

Credentials are read in memory via `gh auth token`; they are not printed or
passed as command-line arguments. Each redirect creates a new request and checks
the host again. GitHub web pages and release asset hosts receive no Authorization
header. Existing release URL, size, checksum and digest checks remain enforced.
Without an available GitHub CLI credential, requests remain anonymous. An HTTP
authentication failure does not trigger an anonymous retry.

Updater failures retain the existing error code and add numeric fields under
`error.diagnostics` when available: `httpStatus`, `rateLimitRemaining`,
`rateLimitResetEpoch` (Unix seconds), and `retryAfterSeconds`. Response bodies,
credentials and arbitrary headers are excluded. For exhausted quotas, wait until
the reported reset time before retrying; repeated immediate attempts do not help.
