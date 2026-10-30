# Native Mac consumer CLI

The development Mac app exposes cached usage and tracked agents through schema v1, following the Windows contract in PR [#105](https://github.com/Somafet/qnotch/pull/105). This does not imply other platform parity or a published Mac release.

```sh
CLI=dist/macos/QNotch.app/Contents/MacOS/QNotch
"$CLI" usage --json
"$CLI" usage --json --provider claude --account ACCOUNT_ID
"$CLI" agents --json --details
"$CLI" agents --json | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["module_status"])'
```

Start the app normally first. Queries never start AppKit, fetch providers, launch Codex, read transcripts, change settings or enable modules. They use the app's cached observations at its existing cadence. `--json` is optional; output is always one UTF-8 JSON document and a newline. `--help` does not connect. Filters and flags reject duplicates and unknown arguments. `--data-dir PATH` or `QNOTCH_MAC_DATA_DIR` select the existing instance root, as for normal Mac launches.

The envelope contains `schema_version: 1`, `app_version`, `platform: macOS`, UTC `generated_at`, `module_status` and `data`. Module status is ready, disabled, initializing or unavailable; only ready carries data. Exit 0 means a snapshot was delivered, including disabled or partially unavailable data. Exit 3 means no service connected, 4 means invalid arguments/selectors, 1 means protocol/transport/timeout failure. Failures leave stdout empty and emit schema-v1 structured JSON on stderr.

Usage accounts include provider, opaque account_id, status, plan, refreshing, checked_at, observed_at, source, error, windows and banked_resets. Every discovered Claude account is included independently of UI selection; disabled providers have no old numbers. Unread quota is pending; failed reads are unavailable. Windows preserve source IDs, durations, percentages and UTC resets. Expired windows are omitted and never become zero. Codex's observation time comes from its session log, not the query time. The account cache does not prove that a retained Codex reading belongs to the current login. Generic native quota failures currently use provider_error, without exporting raw provider error text.

Banked resets carry status, nullable count/next_expires_at, source and their own checked_at. Claude optional lookup failures/missing data are unknown and preserve quota. Source-confirmed empty eligible grants are none. Expired credits are unknown. Native Codex credit lookup is unsupported: queries never spawn an app server. No prompt/token capacity or cross-provider score is inferred.

Agents contains coverage, tracking, sessions and usage. Sessions are tracked hook/T3 observations, with opaque session_id, provider, status, UTC since and tracking_source. Hook health and the T3 watcher's latest database observation are reported separately. Empty sessions do not prove no agents exist. Claude transcript usage includes subagents, replaces duplicate message IDs per file, and reports local-day totals with the native IANA timezone. Tokens combine input/output/cache reads/cache writes. Unread usage is pending, missing reads unavailable, other providers unsupported; these never become zero. API-equivalent cost uses a bundled estimate table, not billing or a current-price guarantee; unknown pricing leaves estimated_usd null and pricing_complete false. Retained usage lives only in memory. Rewritten/truncated transcripts are not reconstructed; retained observed records are not an account ledger or a complete history.

Default output omits titles, projects, paths, prompts, permissions, command lines, links, transcripts and credentials. `--details` adds sanitized account labels, session titles and project basenames; treat these as private. Account/session pseudonyms use an installation-local HMAC secret in mode-0600 consumer.identity.json, loaded at module startup. They survive restart while that file remains. Identity creation never occurs on a query.

The separate mode-0600 Unix socket is `/tmp/qnotch-consumer-<uid>-<device>-<inode>.sock`, derived from the existing instance.lock file. This supports deep data roots and directory aliases. Both client and server verify the peer effective UID. Same-user processes share this interface. The instance lock protects endpoint ownership. The service allows four clients, 4 KiB request lines, 1 MiB response lines and a two-second absolute monotonic exchange deadline. Slow/disconnected clients do not block the UI. Snapshot size errors are explicit, without truncation. No export timer, disk snapshot, HTTP listener or debug-control access is involved. Diagnostic/demo/measurement runs never start this service.

Build and verify:

```sh
bash scripts/macos/build.sh
bash scripts/macos/test.sh
python3 src/QNotch.Mac/Tests/Integration/consumer_cli.py
bash scripts/macos/smoke.sh
```

The integration script owns only its isolated processes and data; it uses synthetic hook/transcript input and disabled quota providers. It verifies an actual Python JSON consumer, settings preservation, disabled modules, bounds, concurrent clients and query subprocess behavior. Results and measured cached-query latency are written under dist/macos/consumer-cli. See [validation evidence](cli-validation.md) for actual checks and limitations.
