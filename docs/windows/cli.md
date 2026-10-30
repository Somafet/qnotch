# Read-only consumer CLI

Windows QNotch exposes cached AI quota and agent activity to local scripts:

```powershell
.\dist\QNotch.exe usage --json
.\dist\QNotch.exe usage --json --provider claude
.\dist\QNotch.exe usage --json --provider claude --account ACCOUNT_ID
.\dist\QNotch.exe agents --json
.\dist\QNotch.exe agents --json --details
```

Start the app normally before querying. Both commands output JSON, including when `--json` is omitted. `--help` describes arguments without connecting. `agents` is a read command; the existing singular `agent` command remains the hook input.

These commands do not start the app, fetch providers, read transcripts, switch accounts, or change settings. Data follows the app's existing refresh cadence. A disabled module stays disabled. macOS does not implement this interface.

## JSON envelope and exit codes

Schema v1 uses UTF-8, one JSON document per invocation, and ISO 8601 UTC timestamps. Consumers should ignore unfamiliar response fields. Nullable data values are explicit `null`; private descriptive fields are omitted unless requested.

Every successful exchange returns:

```json
{
  "schema_version": 1,
  "app_version": "0.4.0",
  "platform": "Windows",
  "generated_at": "2026-10-30T12:00:00Z",
  "module_status": "ready",
  "data": { "accounts": [] }
}
```

`module_status` is `ready`, `initializing`, `disabled`, or `unavailable`. Only `ready` carries a non-null `data` object. Individual accounts/readings may be unavailable even when their module is ready. An empty tracked-session list does not establish that no agents are running outside QNotch's coverage.

- Exit **0**: snapshot delivered, including partial results and disabled/unavailable modules. Inspect the statuses inside it.
- Exit **3**: no consumer service connected for this instance.
- Exit **4**: invalid flags, duplicate flags, unknown provider/account, or an account not belonging to the selected provider.
- Exit **1**: timeout after connecting, incompatible schema, size limit, or other transport/protocol failure.

On failure stdout is empty and stderr contains structured JSON, for example:

```json
{"schema_version":1,"error":{"code":"not_running","message":"No QNotch consumer service is running for this instance."}}
```

When a module is disabled or initializing, account filters cannot be resolved; the command returns that module state rather than loading it to validate an account.

## Usage data

`data.accounts` includes every discovered account for enabled providers, independent of the Claude account selected in the UI. Disabled providers have entries with `status: disabled` and no old numeric readings. `--provider` accepts `claude` or `codex`; `--account` takes the opaque ID from a previous snapshot.

Each account has `provider`, `account_id`, `status`, nullable `plan`, `refreshing`, `checked_at`, `observed_at`, `source`, nullable `error`, `windows`, and `banked_resets`. Account status is `pending`, `ok`, `unavailable`, or `disabled`.

- `checked_at` records the quota check's completion; `observed_at` records the source observation. `generated_at` only dates the export.
- Claude quota source is `provider_api`. Codex quota source is `session_log`: rereading a log does not make its observation newer. QNotch does not verify that a retained Codex log reading belongs to a newly switched login; use it as a local observation, not authoritative account identity.
- Windows include `id`, display `label`, nullable `duration_seconds`, numeric `used_percent` (0–100), and nullable `resets_at`. Claude IDs preserve source keys such as `five_hour`, `seven_day`, `seven_day_opus`; Codex uses `primary` and `secondary`. Model-specific windows need not all be present.
- Expired windows are omitted. If none remain, status is `unavailable` with error `expired_reading`; a passed reset never fabricates a fresh zero.
- Unavailable quota has no windows or observation time. Failure reasons use stable codes such as `not_signed_in`, `subscription_required`, `credentials_unreadable`, `sign_in_expired`, `rate_limited`, `provider_error`, `invalid_response`, `no_reading`, `network_unavailable`, `timeout`, and `internal_error`. No last-good quota fallback is exported.
- Banked resets have `status`, nullable `count`, nullable `next_expires_at`, `source`, and `checked_at`. Status is `available`, `none`, `unknown`, or `unsupported`. A missing field, failed optional lookup, or expired cached credit is unknown, never zero. `none` represents a source-confirmed empty result. Sources are `provider_api` and `codex_app_server`; credit checks are separate from Codex quota checks.

Account IDs are installation-local pseudonyms for provider configuration directories. They survive app restarts while the private `consumer.identity.json` settings file remains. They are not billing identities and change if that file is reset. `--details` adds sanitized account labels, including custom names.

Quota percentages do not imply remaining prompt/token counts, comparable capacity across providers, or a guarantee that a task will succeed. Consumers choose their own age/alert thresholds.

## Agent data

`data` contains `coverage`, `tracking`, `sessions`, and `usage`.

- `tracking.hooks` reports `initializing`, `listening`, or `unavailable`. Listening does not mean hooks are installed in every agent. `tracking.t3` reports `initializing`, `inactive`, `ready`, or `unavailable`, based on the existing integration's observations; it is not an independent audit of database completeness.
- Sessions include opaque `session_id`, `provider` (`claude`, `codex`, or `unknown`), `status` (`ready`, `working`, `needs_you`, `done`), UTC `since`, and `tracking_source` (`hook` or `t3`).
- Usage entries join sessions by `session_id`. Entries may remain after their session row disappears, according to the existing in-memory retention policy. No cross-restart or historical completeness is promised.
- Usage status is `ok`, `pending`, `unavailable`, or `unsupported`. Unread Claude usage is pending; live Codex/other-provider usage is unsupported. Missing/failed reads do not become zero totals.
- Each usage entry includes provider, scope, local Windows timezone ID, read-completion `checked_at`, nullable `total`, and per-local-day `days`. Totals contain `tokens`, nullable `estimated_usd`, and `pricing_complete`. Tokens combine input, output, cache writes and cache reads; this is not unique context size.
- Accounting covers observed Claude transcripts and their subagents. Costs are API-equivalent estimates from QNotch's bundled table, not a bill or current-price guarantee. An unknown model leaves the full estimate null and `pricing_complete: false` rather than presenting a partial sum as complete.

`--details` adds sanitized session titles and project basenames. Default output omits these, full paths, permission/prompt text, process command lines, links, transcript contents and credentials. Consider opted-in titles/labels private when sharing output.

## PowerShell consumers

```powershell
$snapshot = .\dist\QNotch.exe usage --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not query QNotch' }
if ($snapshot.module_status -eq 'ready') {
    $snapshot.data.accounts |
        Where-Object status -eq 'ok' |
        ForEach-Object {
            $provider = $_.provider
            $_.windows | Where-Object used_percent -ge 90 |
                Select-Object @{Name='provider';Expression={$provider}}, id, used_percent, resets_at
        }
}

$agents = .\dist\QNotch.exe agents --json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $agents.module_status -eq 'ready') {
    $agents.data.sessions | Where-Object status -eq 'needs_you'
}
```

## Local transport and testing

The normal app hosts `QNotch.Consumer`, suffixed with `.QNOTCH_INSTANCE` when that environment variable is set. It is a separate read-only pipe with a current-user-only DACL and Windows remote-client rejection. The CLI verifies the server owner. No HTTP listener or debug-control access is needed. Same-user processes share this local interface; it is not a separate user authentication boundary.

Each connection handles one schema-v1 request. Limits: 4 connected workers, 4 KiB request, 1 MiB response, and a two-second exchange deadline. Oversized snapshots return `size_limit` without silent truncation. There is no export timer or disk snapshot cache. Snapshot/demo/measurement modes do not start the production consumer service.

Run contract, synthetic reader, pipe and CLI-process checks through the Windows test suite. The isolated lifecycle script verifies the normal app's endpoint, filters, synthetic hook/transcript, unchanged settings, restart identity and disabled-module behavior:

```powershell
dotnet run --project tests/QNotch.WindowsTests -c Release
./tests/QNotch.WindowsTests/Test-ConsumerCli.ps1 -Executable ./dist/QNotch.exe
# Optional normal-instance latency and idle sample, without account/session details:
./tests/QNotch.WindowsTests/Test-ConsumerCli.ps1 -Executable ./dist/QNotch.exe -Measure -ReportPath ./artifacts/consumer-cli/lifecycle.json
```

The implementation originated in [issue #104](https://github.com/Somafet/qnotch/issues/104) and the [consumer CLI plan](../consumer-cli-plan.md). See [recorded validation and the idle CPU limitation](consumer-cli-validation.md).
