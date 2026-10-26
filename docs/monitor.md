# Monitor snapshots

`albedo-monitor` emits one versioned JSON object to stdout, then exits. It uses
`$ALBEDO_HOME` (default `~/.albedo`); `--home PATH` overrides discovery and
`--timeout SECONDS` sets the overall startup/request budget (default 5, maximum 30).
Without `--start-daemon` the helper only observes an existing daemon.

```console
albedo-monitor
albedo-monitor --home /path/to/albedo-home --timeout 3
albedo-monitor --start-daemon
```

The standalone flake package is `packages.<system>.albedo-monitor`; the overlay
also exports `albedo-monitor`. Its runtime includes Python and the suite
`albedo-defaults` CLI, pinned by absolute executable path; no ambient CLI is needed.
Running the source script directly uses `albedo` from PATH.

## Contract version 1

```json
{
  "version": 1,
  "online": true,
  "error": "",
  "sessions": [{
    "id": "session-id",
    "title": "Agent title",
    "workspace": "/workspace",
    "model": "model-id",
    "status": "working",
    "phase": "generating",
    "parent_id": null,
    "clients": null
  }],
  "accounts": [{
    "id": "public-account-id",
    "provider": "openai-codex",
    "account": "Account display label",
    "windows": [{
      "label": "5 hours",
      "remaining_percent": 75.0,
      "resets_at": "2026-05-02T14:00:00Z",
      "resets_at_epoch": 1777730400.0,
      "observed_at": "2026-05-02T12:00:00Z",
      "status": "ok",
      "stale": false
    }],
    "error": ""
  }],
  "accounts_error": ""
}
```

- `online` means `/server` returned a ready protocol-3 daemon whose available
  identity fields match discovery. Later errors can leave `online: true` with
  partial arrays; consumers must check `error` before showing aggregate counts.
- Session status is `working` for preparing, generating, running, compacting or
  interrupting; `waiting` for idle with blocked inputs; `idle` otherwise; unknown
  phases become `unknown`. This is daemon activity, not process CPU usage or
  attached-client presence. All unarchived families and subagents are included;
  closed members are omitted. Client counts are unavailable and always null.
  `model` and `parent_id` may be null.
- Accounts come from the daemon's native multi-account inventory, not historical
  quota rows. Unsupported and never-measured accounts remain visible with
  `quota_unavailable`. Canonical provider names include `anthropic`,
  `openai-codex`, `google-antigravity` and `opencode-go`.
- Windows use cached daemon samples only. `remaining_percent` is `100 - used`
  only for finite percentages in range, otherwise null. Timestamps are RFC3339
  strings or null. The additive optional `resets_at_epoch` field is finite Unix
  seconds parsed from a timezone-aware reset timestamp, otherwise null; clients
  must also accept its absence from older version-1 snapshots. Stale means observation missing/unparseable, older than 30
  minutes, implausibly future-dated, or reset elapsed. Stale values are historical,
  never renewed guesses. Provider status is retained; raw provider error bodies
  are replaced with fixed error codes.
- Errors are fixed codes, not exception text. `error` covers discovery/session
  failures; `accounts_error` covers inventory/identity failures or possible quota
  truncation; account `error` covers missing/failed quotas. Empty string means no
  error observed, not a guarantee of freshness. Process exit is zero for a valid
  snapshot, including offline/error snapshots. Invalid arguments exit nonzero.

## Safety and limitations

By default the helper never starts, attaches to, restarts or upgrades the daemon.
`--start-daemon` explicitly permits the native `albedo daemon` command only when
discovery is missing or its PID no longer exists. A live PID (even an unreachable
or incompatible daemon) and invalid discovery never trigger startup. Concurrent
monitor startups are serialized by a nonblocking `monitor-start.lock` in the home;
a competing invocation reports `daemon_start_in_progress`. Startup failures and
startup timeouts report `daemon_start_failed`, without native command output.
The helper never creates a session or attaches a session client. Existing live
daemons are observed directly, never passed through native CLI startup. Requests
are authenticated GETs to loopback only: `/server`, `/auth` and paginated
`/sessions?scope=all&archived=false`. No provider quota requests are triggered.
Redirects and proxies are not followed. Discovery is capped at 64 KiB, each HTTP
response at 8 MiB, credentials at 1 MiB and session collection at 20 pages of 100.
The daemon's `/server` currently caps quota readings at 200; reaching this limit
is reported as possibly truncated.

`GET /auth` is the ordinary native account-list API. Upstream can initialize
missing stable account IDs and update display metadata in `creds.json`; it does
not change credential secrets, account selection or remotely refresh tokens.
Without the startup flag the helper itself writes no files. Opt-in startup can
create the home, its monitor lock and native daemon files. It reads `creds.json`
locally only to map the
public account ID onto non-secret quota identity fields. Tokens, refresh secrets,
API keys, MCP configuration, prompts, previews and transcripts are never emitted.
Raw exceptions and HTTP error bodies are never included in JSON.

Identity matching follows the pinned upstream store semantics: Claude uses
`accountId` or email, Codex stored email or `accountId`, Antigravity email, and
OpenCode Go email/org/account label. Token-derived fallback identities and JWT
claims are deliberately not computed. Missing/ambiguous mappings remain unknown;
no single-account or label-similarity guess is made. API-key-only provider profiles
outside native account inventory are not listed. Revisit this adapter when
upstream exposes the quota identity directly in its public account API.

The suite builds the quota core with Zig's baseline CPU target rather than the
build host's native instruction set. This prevents cached builds from crashing
with an illegal instruction on machines without the builder's CPU features
(for example AVX-512). A core crash leaves the last successful windows stale;
the monitor cannot refresh them itself.

## Verification

```console
python3 -m unittest discover -s test -p monitor_test.py -v
nix build .#checks.x86_64-linux.monitor .#albedo-monitor
```

Tests use isolated temporary homes and local HTTP fixtures; they never read live
credentials, contact providers or start/restart a real daemon.
