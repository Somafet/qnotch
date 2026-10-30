# Mac consumer validation

Measured 2026-10-30, release/arm64 development build on Mac14,2, 8 GiB RAM, macOS 26.3 (25D125). The CLI sources are recorded by this commit, based on 22564f53e7a005abb279f07084b8b8a4f407d16a. Contract reference: Windows PR [#105](https://github.com/Somafet/qnotch/pull/105) at 9c33ebcb0b497ac487b718e810977f3ae82b826d. The Mac implementation builds independently of that PR. No Windows sources, packaging, releases or update feeds change; no shared protocol/CI edits require parent Windows regressions.

## Checks actually run

- `bash scripts/macos/build.sh`: passed, leaving a fresh dist/macos/QNotch.app.
- `bash scripts/macos/test.sh`: 165 XCTest cases passed, warnings treated as errors. This includes pre-existing analytics tests in the dirty checkout.
- Independent staged-source export (no Git worktree created): release/arm64 `swift test` with warnings as errors, 156 cases passed without the unrelated analytics changes. Its executable also passed isolated consumer integration before the final defensive reader refinements; the final refinements passed the independent native tests.
- `python3 src/QNotch.Mac/Tests/Integration/consumer_cli.py`: passed against the final real bundle, with isolated roots and synthetic hook/transcript input. It checks UTF-8/details privacy, opaque IDs, unknown selectors, disabled providers/modules, unchanged settings across queries, malformed/version/oversized requests, four concurrent clients, stalled-client cleanup, connected CLI timeout/exit 1, no-instance exit 3, bad-argument exit 4, help without startup, separate-directory isolation and a Python JSON consumer. It terminates only its own PIDs.
- Native tests additionally exercise expired/pending data, stable restart identity, multi-account filters independent of the selected row, source window IDs/durations, duplicate messages/subagents/unknown pricing, failed transcript reads, socket mode/peer checks, disconnect/shutdown and oversized responses over the real transport.
- `bash scripts/macos/smoke.sh` and `node scripts/check-snapshots.mjs dist/macos/smoke`: passed, ending in done. Smoke notes the screen was locked, so WindowServer key status was not checked. No visible UI layout change was intended; native placement/module/header checks passed.
- Node 25.8.1: `npm ci` succeeded. `npm test` in the original dirty checkout failed one relative-link check because unrelated spec/analytics.md points to a missing Windows analytics document. A complete staged-file export passed all 42 repository tests after `npm ci`. Unrelated work remains outside this commit.

## Measured cached queries and idle

[Raw measurements and configuration](cli-validation.json). Forty separate cached `agents --json` processes: median **7.89 ms**, p95 **12.13 ms**, maximum **31.87 ms**. These include process startup and JSON validation, using Python perf_counter; they are warm local queries, not cold-launch guarantees.

An isolated normal instance had Agents and AI enabled, both quota providers disabled, and every other module disabled. Synthetic observed transcript usage was cached before measurement. With the panel collapsed, a **10.010-second** two-endpoint proc_pid_rusage v2 interval measured **0.00119% of one core**, RSS **63.3 MiB** initially and **63.2 MiB** finally. There was no sampling loop. T3 could observe the active development conversation; other system load was uncontrolled. This is RSS, not private footprint or a leak test. The 10-second interval is shorter than the guide's 30-second measurement mode.

There is no matched before/after baseline. [Historical Mac measurements](performance.md) used different module/configuration states and cannot establish this change's CPU/memory delta. No regression or long-duration idle guarantee is inferred. Measurement/demo mode deliberately does not host the consumer endpoint.

## Limits

The local development build includes preserved pre-existing uncommitted analytics work; the independent staged-source checks demonstrate the PR has no dependency on it. No live provider accuracy, billing accuracy, foreign-user login, macOS 13 hardware or complete historical coverage was exercised. Native Codex credits are explicitly unsupported; quota failures use sanitized generic provider_error. Transcript records are observed in-memory retained data, including subagents, with a 64 MiB per-file read cap; truncations/rewrites are not reconstructed. A missing/failed/incomplete read is unavailable, not a zero total. Unknown pricing leaves the full estimate null. Hook listening and T3 readiness are observations, not installation/completeness audits. No signing, notarization or release publishing was performed.
