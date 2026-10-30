# Consumer CLI plan

Original proposal: 30 October 2026. The scope and acceptance criteria below record the implementation plan.

Implementation tracked in [issue #104](https://github.com/Somafet/qnotch/issues/104). The implemented Windows contract is documented in [the CLI reference](windows/cli.md); this document preserves the original plan.

## Objective and scope

Let local scripts, status bars and desktop tools read QNotch's existing AI quota and agent activity without scraping the UI, handling provider credentials, or duplicating QNotch's readers.

The first release targets Windows and adds two read-only commands:

```powershell
QNotch.exe usage --json
QNotch.exe agents --json
```

Both read cached snapshots from a running instance. Neither starts the GUI, fetches provider data, reads transcripts, changes settings, or enables a disabled module. Preserve the existing `agent` hook command; `agents` is a separate query command.

Defer explicit refresh, watch/event streams, historical storage, remote HTTP, MCP, account switching, agent control, and other modules. Do not imply macOS support. No new visible UI is needed.

## Evidence and limits

- [AI models](../src/QNotch/Modules/Ai/AiModels.cs) already carry windows, percentages, reset times, plan, observation time and banked resets.
- [AiModule](../src/QNotch/Modules/Ai/AiModule.cs) caches results per account, while its UI shows one Claude account at a time. Refresh failures currently replace successful results.
- [ClaudeCodeProvider](../src/QNotch/Modules/Ai/ClaudeCodeProvider.cs) fetches usage remotely. [CodexProvider](../src/QNotch/Modules/Ai/CodexProvider.cs) reads quota from session logs and separately asks the installed CLI for reset credits. Their observation times and failure modes differ.
- [AgentsModule](../src/QNotch/Modules/Agents/AgentsModule.cs) tracks sessions and usage. [AgentUsage](../src/QNotch/Modules/Agents/AgentUsage.cs) reads Claude transcript totals, including subagents, and estimates API-equivalent cost using a bundled price table. This is not billing data or a complete account ledger.
- [Program](../src/QNotch/Program.cs) dispatches CLI verbs before WPF starts. Existing notification and debug clients establish console and pipe conventions, but the debug channel is not a consumer API.

These are source-level findings. Live account accuracy, pricing accuracy, transport performance and consumer compatibility still need validation.

## Public contract

### Common behavior

- Versioned UTF-8 JSON on stdout, one document followed by a newline. `--json` is the stable automation format; the default may be a compact text summary generated from the same snapshot.
- Envelope: `schema_version`, `app_version`, `platform`, `generated_at`, `module_status`, and command-specific data. All instants use ISO 8601 UTC with `Z`.
- `module_status`: `ready`, `initializing`, `disabled`, or `unavailable`. A disabled or uninitialized module must not resemble an empty successful result.
- Exit codes: 0 for a delivered snapshot, including partial/disabled/unavailable data described inside it; 3 for no running service; 4 for invalid arguments; 1 for transport/protocol/internal failure. Errors are structured JSON on stderr when `--json` is used. Consumers inspect record statuses for data availability.
- `--help` exits without connecting. Reject unknown flags and incompatible protocol versions clearly. Use a bounded two-second total exchange deadline and distinguish connection failure from a service that timed out.
- Additive fields are permitted within schema v1; consumers must ignore unknown fields. Breaking meaning or shape requires a new schema version.

### Usage snapshot

Return every discovered account for enabled providers, independent of UI selection. Return disabled provider entries without their old readings. Support optional `--provider claude|codex` and `--account ID` filters; unknown selectors are argument errors. Account IDs are opaque, stable across app restarts, and not derived directly from private paths. A new local ID mapping may be needed; do not expose existing folder-derived IDs verbatim.

Each account contains:

- Provider ID and opaque account ID; an optional account display label only with `--details`.
- `status`: `pending`, `ok`, `unavailable`, or `disabled`; nullable plan; `refreshing`; and a stable error code plus sanitized explanation when unavailable.
- `checked_at` for the latest completed quota check and `observed_at` for the quota source observation. Null means unknown. Preserve an old source timestamp rather than replacing it with the check time.
- Source: `provider_api` or `session_log`. Never imply a request to reread Codex logs refreshed the upstream quota.
- Windows with stable IDs, display labels, nullable duration in seconds, numeric `used_percent`, and nullable `resets_at`. Retain source window keys/durations currently lost during display normalization. Omit expired windows; never assume a reset means usage became zero. No valid windows means unavailable.
- Banked resets as a separate object with `status` (`available`, `none`, `unknown`, `unsupported`), nullable count, nullable next expiry, source and its own check time. Failed credit discovery must not become zero credits. Only report `none` or `unsupported` when the source establishes it.

Do not expose prompt/token capacity estimates from quota percentages. Do not combine providers into a supposedly comparable capacity score. In v1, an unavailable quota result has no numeric readings; retaining last-good readings is deferred. Consumers can judge observation age themselves rather than relying on an unexplained stale threshold.

### Agents snapshot

Return tracked sessions with opaque session ID, provider, status (`ready`, `working`, `needs_you`, `done`), status-change time, and tracking source (`hook`, `t3`, or another implemented source). Include module/tracking health so an empty list is not proof that no agent exists outside QNotch's coverage.

Export optional per-session total and local-day usage from the existing usage cache, including sessions whose live row has disappeared while their usage is retained. Join these records by opaque session ID. Include:

- Token total, nullable estimated USD cost, and `pricing_complete`.
- Scope and provenance: observed Claude transcripts, including subagents; day key plus the local timezone used for daily boundaries; read-completion timestamp.
- Usage availability separately from agent status. Unsupported or unread usage is null/unavailable, never zero. When pricing is incomplete, leave the full cost estimate null rather than presenting a partial sum as complete.

Do not promise historical completeness, cross-restart retention or Codex token accounting. Keep the existing combined token definition explicit: input, output, cache writes and cache reads; it is not unique context size.

By default omit session titles, project labels, full working directories, prompt/permission text, process command lines, transcript paths, deep links and credentials. `--details` may add sanitized account labels, session titles and project basenames; document these as private descriptive data. Full paths and transcript contents remain outside v1.

## Implementation sequence

1. **Freeze the contract and fixtures.** Write the Windows CLI reference with example success, partial, pending, disabled and unavailable documents. Define stable window/error IDs, account identity persistence and session identity mapping. Create synthetic fixtures before wiring the CLI. Do not copy personal logs or credentials into tests.
2. **Build the shared local transport.** Add a small Windows-local read endpoint registry and named-pipe host. Add registration to `ModuleContext`; wire startup/disposal through the app. The shell handles lifecycle and module availability without referencing Ai/Agents implementations. Modules own their commands, DTOs and projections; `ModuleList` registers the verbs. These shared-file changes are shell work, not a module-only patch.
3. **Publish quota snapshots.** Separate public DTOs from WPF view models. Add structured provider errors, source/check timestamps and banked-reset availability. Preserve quota independently when the optional credits query fails. Project immutable snapshots from the existing cache on the dispatcher; serialize outside it. Add account filters and the module-owned `usage` client.
4. **Publish agent snapshots.** Project activity and retained usage with provenance and coverage limits. Track read-completion timestamps and availability explicitly. Add the module-owned `agents` client without altering the hook wire format. Keep private descriptive fields behind `--details`.
5. **Verify, document and publish locally.** Complete contract/transport regressions, isolated integration smoke checks and performance measurements. Document PowerShell examples and limitations. Publish a fresh `dist/QNotch.exe` for the user to try.

Each phase depends on the preceding contract/transport work. Deliver usage first, then agents; do not expand the endpoint registry into a general plugin runtime.

## Transport and lifecycle requirements

- Use a separate current-user-only named pipe, with remote clients rejected. Honor `QNOTCH_INSTANCE` for isolated runs. Do not expose debug actions through it or require `--debug-control`.
- Start the host after normal startup has registered the relevant module endpoints. Classify disabled, initializing and failed modules using shell lifecycle metadata without constructing disabled modules. Stop the host and cancel connections on exit.
- No periodic export timer, disk cache or network listener. Queries read memory and do not change provider cadence. No extra installed dependency.
- Bound request size, response size, connection concurrency and read/write time. Set explicit constants and test their limits. Return a structured size-limit error instead of silently truncating session/account lists; pagination is deferred unless real bounded fixtures demonstrate it is necessary.
- Snapshot capture is short and consistent on the dispatcher; pipe I/O and JSON serialization run off it. Client disconnects must not stall the UI or leave pending work behind.
- CLI DTOs, argument parsing and the pipe client must not load WPF. Keep provider credentials and raw responses out of output and logs.
- Normal snapshot/measurement runs must not publish demo data on the production pipe. Integration tests start the host explicitly with an isolated instance and synthetic fixtures.

## Acceptance and validation

- Contract fixtures cover multiple Claude accounts, UI selection independence, Codex log age, UTC conversion, expired windows, unknown credit availability, missing sign-in, timeout, partial provider failure, disabled providers/modules and empty agent tracking.
- Transcript fixtures cover repeated message blocks, subagent inclusion, unknown model pricing, retained usage after session removal and daily timezone boundaries. Validate known totals by hand against synthetic source events, not only against serializer output.
- Pipe tests cover malformed/oversized requests, oversized responses, incompatible versions, concurrent reads, stalled/disconnected clients, shutdown cancellation and instance isolation. Verify the configured current-user/remote-access restrictions.
- CLI process tests assert stdout/stderr, UTF-8, exit codes, argument rejection, help without an app, and no GUI/WPF startup for query verbs. Validate a consumer example by piping JSON into `ConvertFrom-Json` and checking a known fixture value.
- Querying must not invoke provider fetches, spawn Codex, reread transcripts, change settings, or enable modules. Prove this with instrumented test providers/readers and before/after settings checks.
- Measure collapsed idle CPU/memory before and after, and repeated cached-query latency in an isolated normal instance. Follow the architecture's hard performance limits; record machine, build, sample count and latency distribution. Target completed cached reads below 250 ms at p95 on that recorded machine, with no dispatcher stalls or continuing work after clients exit.
- Run the Windows Release build with warnings as errors and the Update, PhoneShare, Onboarding and Windows regression suites from the Windows development guide, plus the new contract/transport tests and isolated CLI smoke tests. Add tests to the existing CI paths so the required `build` result includes them.
- Because shared module/lifecycle contracts change, run root repository checks with Node.js 24+: `npm ci`, then `npm test`. Check the documentation links too.
- Publish with `dotnet publish src/QNotch/QNotch.csproj -p:PublishProfile=win-x64`. Leave `dist/QNotch.exe` fresh. Interactive launches, if needed, go through Explorer. Do not publish a release or change packaging/update feeds as part of this work.

Completion means both documented commands work against an isolated running instance, contract fixtures and relevant regressions pass, performance evidence is recorded, and the fresh Windows executable is available. External consumer interoperability is only claimed for the consumer examples actually exercised.
