# Devices sharing validation

Development environment: Windows 11 Pro 25H2, x64, AMD Ryzen 9 5900X (24 logical CPUs),
32 GiB RAM. The work adds a separate Devices settings page and the version 1
[device protocol](../../../spec/devices.md).

## Executed checks

- Release build with warnings treated as errors: passed.
- Device transport/model regression executable: 48 checks passed. Includes independent Node.js HMAC
  and AES-GCM vectors, reflection/reordering/tamper rejection, fresh-client replay protection,
  pairing refusal, one-use and expired invitations, bidirectional Unicode text, repeated-name
  multi-chunk files, empty files, receive permissions, truncation cleanup, cancellation,
  restored trust and revoked trust. Sync checks cover concurrent offline edits, cleared-text
  replay, explicit resolution, multi-frame exchange, journal/file recovery, clipboard replay
  after restart and absence of clipboard text in the journal. Tailscale address boundaries pass.
- Windows coordinator integration check passes with isolated sources and storage: incoming
  conflicts preserve the editor, resolution updates it, clipboard echoes are suppressed,
  and restart restores both resolution and replay metadata.
- Existing updater checks: 27 passed. Phone-sharing checks: 10 passed. Onboarding checks:
  25 passed. Windows deterministic behavior/rendering checks: passed.
- Repository checks (`npm ci`, `npm test`, Node 24+): all 42 passed.
- Devices settings snapshots: dark and light renders passed the snapshot checker. Final
  published executable's dark Devices render also passed. Local artifacts are under
  `dist/devices-snapshots` and `dist/devices-snapshots-light`.
- Fresh framework-dependent executable published to `dist/QNotch.exe`. The executable that
  existed before this work was preserved as `dist/QNotch-before-devices.exe`.

On macOS CI, commit `80042bc` built the native app, passed all 156 XCTest regressions and
passed native UI smoke and snapshot checks. Devices tests cover Mac-to-Mac sockets, both
native Swift/.NET pairing directions, text/files in both directions, shared causal sync fixtures,
and a multi-frame native-to-.NET note/clipboard sync exchange. All CI jobs passed at that head.
Subsequent coordinator/restart tests and persistence debounce changes still require latest-head
native validation. See [PR 99](https://github.com/Somafet/qnotch/pull/99).

The user deferred the physical two-computer test to a later manual run. Loopback tests establish
implementation compatibility, not firewall/overlay ACL permissions or actual Windows/Mac
network reachability. No remote Mac settings or software were changed.

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
