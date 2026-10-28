# Devices sharing validation

Development environment: Windows 11 Pro 25H2, x64, AMD Ryzen 9 5900X (24 logical CPUs),
32 GiB RAM. The work adds a separate Devices settings page and the version 1
[device protocol](../../../spec/devices.md).

## Executed checks

- Release build with warnings treated as errors: passed.
- Device transport regression executable: 34 checks passed. Includes independent Node.js HMAC
  and AES-GCM vectors, reflection/reordering/tamper rejection, fresh-client replay protection,
  pairing refusal, one-use and expired invitations, bidirectional Unicode text, repeated-name
  multi-chunk files, empty files, receive permissions, truncation cleanup, cancellation,
  restored trust and revoked trust.
- Existing updater checks: 27 passed. Phone-sharing checks: 10 passed. Onboarding checks:
  25 passed. Windows deterministic behavior/rendering checks: passed.
- Repository checks (`npm ci`, `npm test`, Node 24+): all 42 passed.
- Devices settings snapshots: dark and light renders passed the snapshot checker. Final
  published executable's dark Devices render also passed. Local artifacts are under
  `dist/devices-snapshots` and `dist/devices-snapshots-light`.
- Fresh framework-dependent executable published to `dist/QNotch.exe`. The executable that
  existed before this work was preserved as `dist/QNotch-before-devices.exe`.

On macOS CI, commit `5835469` built the native app and passed all four Devices XCTest methods,
including Mac-to-Mac sockets and native Swift to .NET transfers with .NET sending the payloads
back. The full suite failed because Devices was missing from the onboarding groups and a
Terminal PTY resize check timed out. The onboarding entry is fixed in `d2d2d11`; that commit
also adds a separate .NET-client/native-Mac-host pairing test. Latest-head results must be
checked before calling the complete change validated. See [PR 99](https://github.com/Somafet/qnotch/pull/99).

No physical two-computer LAN check has run. Loopback tests establish implementation
compatibility, not firewall permissions or actual Windows/Mac network reachability.

## Idle performance limitation

Diagnostic runs use read-only demo data, no network, a collapsed off-screen panel, 15-second
warmup and 30-second measurement. They do not measure an enabled live device listener.

| Executable | Revision | CPU, percent of one core | Resident memory at end |
| --- | --- | --- | --- |
| Development build, 0.4.0 | `5835469`, dirty | 0.150% | 28.9 MiB |
| Existing published build, 0.8.0 | `796dee7`, clean | 0.119% | 25.1 MiB |
| Development build repeat, 0.4.0 | `5835469`, dirty | 0.137% | 26.0 MiB |

All measurements pass the 80 MiB memory limit and fail the 0.1% CPU limit. The existing
executable is a different revision/version, so this comparison does not isolate a regression
caused by Devices. The first run overlapped snapshot work; the repeat did not. No CPU-budget
pass or live-network performance claim is made. Raw reports are retained locally under
`dist/devices-perf*`.
