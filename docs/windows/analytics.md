# Windows analytics implementation

[Shared analytics contract and coverage inventory](../../spec/analytics.md).

`Core/Analytics.cs` owns explicit native HTTP delivery. `Core/AnalyticsCatalog.cs` rejects noncatalog actions and targets. `analytics-config.json` is embedded by the existing project and both publish profiles, preserving the single-executable package. It contains the supplied QNotch public project token and EU Cloud host. Environment overrides are documented in the shared contract.

General settings stores `ShareUsageData` locally with a default of true. Environment opt-out overrides the control, and setup codes exclude the preference. Identity is read lazily only after a valid configured, enabled action. Diagnostics return before analytics initialization.

Run `dotnet run --project tests/QNotch.WindowsTests -c Release` for synthetic transport/privacy/identity/consent/queue/retry and shared-fixture checks. No real PostHog request is made. Other required Windows regressions and snapshot/smoke checks remain in [development.md](development.md). The emitted source-site inventory is an audit aid and must be updated when action sites change.

Performance measurement uses isolated diagnostics, with telemetry intentionally absent. It measures the app's diagnostic idle workload, not a configured user's full integration workload. Report failures as failures and compare equivalent builds before attributing a regression.

After the project token was supplied, one synthetic batch (`app_version=validation`, random hashed synthetic identity) was accepted by EU ingestion with HTTP 200 and `{"status":"Ok"}` on 2026-10-30. The receipt is in local `artifacts/analytics-ingestion-validation.json`. No personal account identity or content was used. Dashboard appearance was not queried; write-only ingestion credentials cannot verify it.

## Verification from this implementation

Warning-free Release build; updater 27/27, phone sharing 10/10, onboarding 25/25; Windows analytics/layout checks and real ConPTY lifecycle/I/O checks passed. General enabled and environment-disabled snapshots were visually inspected and passed the snapshot checker. Full smoke finished with `done`, including accessible names, onboarding, notifications CLI/transport, agents hook and terminal fixture. Smoke reported its documented skips for Windows refusing synthetic hotkey foreground activation (toggle/search) and for module changes applying on restart; other reported checks passed. `git diff --check` passed. A fresh framework-dependent `dist/QNotch.exe` was published; no release or interactive app was launched.

Performance on Windows 11 Pro 25H2, Ryzen 9 5900X (24 logical processors), QNotch 0.4.0, all 17 diagnostic modules, collapsed/off-screen, 15-second warmup and 30-second interval: the first current build measured 0.109% of one core and 29.8 MB ending resident memory. One settled published repeat measured 0.133% and 29.3 MB. A comparable framework-dependent published HEAD source archive measured 0.107% and 28.1 MB on the same machine. **All three exceed the 0.1% CPU limit; memory passes the 80 MiB limit.** These limited samples do not establish the cause of the difference. The baseline was extracted with `git archive`, not a worktree; its diagnostic source revision reads unknown because the archive has no git metadata.

A separate configured analytics-service-only process, with a synthetic account/install identity and mocked HTTP, measured 0.05208% sampled CPU over 30 seconds after a 15-second warmup, 36.2 MB ending process resident memory, one mocked send and an empty queue. This is a process-level sampled CPU reading for the service test, not full WPF app/provider performance and not a real ingestion test. Reproduce with `dotnet run --project tests/QNotch.WindowsTests -c Release -- --analytics-idle-measure`. Reports and logs from this run are under local `artifacts/analytics-*`; they are verification outputs, not release assets.
