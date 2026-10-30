# Consumer CLI validation

30 October 2026, Windows x64, QNotch 0.4.0 development Release build, .NET 10. Hardware: AMD Ryzen 9 5900X, 24 logical processors, Windows 11 build 26200. No live provider account values or pricing accuracy were validated.

## Functional checks

- Release build with warnings as errors.
- Windows behavior suite, including synthetic consumer contracts, Claude/Codex quota parsing, transcript deduplication/subagents, unknown pricing, opaque IDs, protected pipe DACL, bounded request/response sizes, concurrent clients, stalled-client eviction and shutdown cancellation.
- Real CLI subprocess checks: UTF-8, stdout/stderr, exit codes, help without an app, and absence of PresentationFramework/PresentationCore images while a query waits on a fixture server.
- Existing ConPTY checks, updater checks (27), phone-sharing checks (10), onboarding checks (25), and repository checks (42).
- Isolated normal-app lifecycle: cached snapshots, filters, unchanged settings after repeated reads, stable account IDs after restart, disabled modules not constructed, a synthetic hook/transcript producing exactly 120 tokens, and a later `needs_you` state. Default output omitted the fixture's private title, project, source session ID and transcript path.

Reproduce through [the CLI guide](cli.md) and [the lifecycle script](../../tests/QNotch.WindowsTests/Test-ConsumerCli.ps1). The fixture tests do not assert that the bundled price table matches current upstream pricing, or that every external agent is tracked. Pipe ACLs were inspected locally; no second-machine network probe was performed. Remote rejection is explicitly configured with Windows' `PIPE_REJECT_REMOTE_CLIENTS` flag.

## Performance result and limitation

The isolated normal-app test enabled Ai and Agents, disabled provider fetching and other modules, and used a synthetic agent/transcript. The consumer service was active with the panel collapsed. Thirty reads timed CLI process startup, pipe exchange and PowerShell `ConvertFrom-Json`: p50 130.01 ms, p95 141.38 ms, maximum 154.86 ms. This meets the plan's 250 ms p95 target on this machine; it is not a portable latency guarantee.

The quiet 30.014-second normal-app idle sample measured 0.2422% of one core and about 28 MiB resident memory at the end. CPU used exact process cycle counts divided by a calibrated cycle rate. Memory was sampled from `Process.WorkingSet64`. The resident-memory limit passed; the architecture's 0.1% idle CPU limit **did not pass**.

The all-module diagnostic baseline before implementation also failed the CPU limit at 0.112%; its later diagnostic sample measured 0.148%. Those diagnostic runs use demo data and do not start the production consumer service, so they cannot establish the active service's overhead. Their resident-memory samples passed. The normal-instance and diagnostic configurations differ and must not be treated as a controlled before/after comparison.

An additional matched normal-instance check built the original source from commit `6d675eb758ee03fb0652710165e8ff77cb55c7ad` and used the same Release configuration and isolated settings for each build: Ai/Agents enabled, providers disabled, a synthetic 120-token transcript and needs-you hook, ten seconds to settle after the last hook, then thirty seconds idle with no consumer queries. The original-source sample measured 0.3111% of one core. The new-build sample measured **0.0512%** over 30.010 seconds, with 35,127,296 resident bytes at the end; that sample passed both hard limits. Both reported the panel collapsed.

The spread across samples is substantial, so these single runs do not establish a causal performance improvement or zero idle overhead. The implementation introduces no export polling timer. The matched new-build check passes, but the all-module diagnostic CPU failure remains recorded and needs profiling independently; functional success must not be reported as every performance sample passing.

The published single-file executable also passed the full isolated lifecycle script. Its thirty cached reads measured p50 112.98 ms, p95 131.74 ms and maximum 143.73 ms, including process startup and PowerShell JSON parsing.

Local raw reports are under `artifacts/consumer-cli/`: `baseline/performance.json`, `after/performance.json`, `lifecycle-final.json`, `matched-baseline.json`, `matched-after.json` and `published-lifecycle.json`. They contain aggregate measurements, not exported account/session data.
