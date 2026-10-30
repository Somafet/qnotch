# Mac product analytics

QNotch records explicit commands as `qnotch_action` under the [shared contract](../../spec/analytics.md). Share usage data defaults on and appears at the bottom of General settings. `QNOTCH_TELEMETRY_ENABLED=false` overrides that switch. Disabling cancels in-flight transport and discards staged/buffered events immediately; it sends no opt-out event. Requests already received by the server cannot be recalled.

Shipping configuration is `Sources/QNotchMac/Resources/analytics-config.json`, copied as an SPM resource bundle into the app. It contains the supplied QNotch public ingestion token and EU host `https://eu.i.posthog.com`. `QNOTCH_POSTHOG_KEY` and `QNOTCH_POSTHOG_HOST` override it. Missing/invalid configuration sends nothing and does not resolve identity. No T3 key or endpoint is reused.

Identity resolves on a utility queue after the first eligible command. A persistent local UUID in `analytics-install-id` is SHA256-hashed for `install_id`. `distinct_id` hashes Codex `tokens.account_id`, then Claude `userID`, then that installation UUID; `identity_source` reports only codex/claude/anonymous. Raw identifiers and authentication material never enter the event or logs. Consent and identity stay local and are excluded from setup codes.

Events carry only fixed module/action/surface identifiers, schema/app version, hashed identity, `outcome=requested`, and optional allowlisted `target` plus boolean `enabled`. Requested means invocation, including commands that later cancel or fail. It does not mean success. No paths, names, clipboard/notes/search/media text, application/window titles, raw IDs, credentials, control labels, replay, autocapture, error payloads, or person profiles are sent. Native URLSession uses ephemeral storage, no cookies/cache, HTTPS and no redirects.

## Command coverage

| Area | Explicit commands |
| --- | --- |
| Shell | Open panel, select tab (canonical target), settings, close by Escape/shortcut/module dismissal, pin, edit mode, game override, move notch, card resize/reorder, tab reorder, restart, quit, check updates |
| Onboarding | Next, back, skip, finish, feature target and enabled choice, login/update choice; integration commands use the same catalog |
| General/appearance/features | Display, menu icon, hover/close delays, segment hover, pin, accent, motion, profile name/photo, module enable/disable with target, card/tab/notch visibility, setup export/check/apply |
| Other settings | Login, shortcut assignment/reset, sound choice/preview, update checks/install/beta, game behavior/rules, each module's settings; setting identifiers and boolean choices are fixed |
| Timer | Start, pause, reset, duration selection; no tick/completion events |
| Media | Play/pause, next/previous, source selection, seek; no now-playing updates |
| Clipboard | Copy again, pin/unpin, remove, clear, history preference; no clipboard observation events |
| Notes | Debounced save following editing, including flush on close; no text/keystroke payload |
| Files | Add/drop/chooser, remove, clear, open, reveal, copy path command, export, native share picker, Quick Look; no file metadata |
| Search | Return submits, keyboard/click executes result; no per-keystroke events |
| GitHub | Connect, cancel, authorization browser, token save/test, disconnect, explicit refresh/retry |
| AI | Launch app, slot assignment, custom app add/remove, account select/rename, explicit refresh/scan, settings |
| Agents | Show/open session, dismiss, stop process group, connect/disconnect hooks, settings; no hook/session/provider update events |
| Notifications | Invoke, dismiss, clear, mute, test, token renewal, settings; no incoming notification/expiry/unread events |
| Scheduled | Pause/resume, delete request, reveal, explicit reload; no scans |
| Weather | Place search/selection, forecast link, explicit retry/refresh, units/notch preferences; no forecast updates |
| Volume | User volume/mute commands; no CoreAudio observation events |
| Color picker | Sample request, copy color command; no color payload |
| Terminal | Copy, paste, Return submit; no input/output text or resize events |
| Stats/Capture | Stats preference choices; Capture is passive and has no independent commands |

Native diagnostic runs (`--snapshot`, `--smoke-test`, `--measure`) and debug-control launches never configure analytics. Automatic timer/notification panel opening, startup pinned opening, periodic refreshes, provider observations, incoming CLI notification/hook traffic and geometry/layout refreshes are not user commands. Pointer-leave/focus-loss automatic closing is deliberately not recorded. Clipboard and terminal copy/paste commands mean invocation only. Mac lacks Windows phone-sharing commands; native share and Quick Look are platform-specific. Shared catalog fixture tests permit the native supported subset and reject any native entry absent from the shared contract.

The queue is memory-only (lost on exit), bounded to 1000 staged/buffered entries with up to 20 in flight, batches of 20, a 10-second partial-batch timer, and a 10-second request timeout. Successful full backlogs drain immediately. Transient failures retry with the same event UUID, a two-second exponentially increasing cap up to five minutes, and random delay between half and full cap. Retention is 30 minutes; 400/401/413 responses drop their batch. No idle repeating timer is installed.

## Verification

`Tests/QNotchMacTests/AnalyticsTests.swift` consumes `tests/fixtures/analytics/catalog-v1.json` and `identity-v1.json`. It covers catalog/target allowlists, shared hash vectors, persistent identity precedence, default consent, setup-code isolation, disabled/missing configuration, diagnostic suppression, bounded asynchronous identity staging, opt-out invalidation stable event UUID retry after a mocked 408 response, and a mocked URLProtocol batch payload (including person-profile suppression).

From the repository root on Apple silicon with Xcode 15+:

```sh
bash scripts/macos/build.sh
bash scripts/macos/test.sh
bash scripts/macos/smoke.sh
node scripts/check-snapshots.mjs dist/macos/smoke
python3 src/QNotch.Mac/Tests/Integration/analytics_contract.py
```

Inspect General settings PNGs for the bottom consent row and disabled environment override. A configured local test should separately exercise offline retry, server 408/429/500, redirect rejection, and cancellation during a request. The initial native validation below preceded project-token configuration. After configuration, the parent sent one synthetic batch from Windows to the same EU project; ingestion accepted it with HTTP 200. No personal identity or content was used, and dashboard visibility was not queried.

Native validation ran on the linked Apple-silicon Mac using implementation archive `b80cd480cc83b2cf32287add55ccb74e129985e47d9a4e6c92e7dee9be891cb3`. The Mac checkout was clean at `22564f53`; the Windows source base `0bfff7f` was absent there, and the supplied patch applied cleanly. This verifies the supplied changes on that Mac base, rather than claiming identical repository revisions across machines. No follow-on code fixes were required.

The release build passed with warnings treated as errors. XCTest passed 159 tests, including 9 analytics tests. Native smoke passed 41 checks, produced 116 PNGs, and passed the snapshot validator. General settings PNGs in dark/light appearance and environment-override mode were inspected: the consent row is last and accessible, and the override disables it and shows it off. The app's bundled configuration matched source (empty project token and EU host). All six hard performance checks passed; startup at 1.029 seconds exceeded the non-gating 0.5-second target. The normal app was untouched; no production telemetry or personal identity was used. Native evidence is under `dist/macos/analytics-validation/` on that Mac, including `report.txt`, `tests.log`, and the General PNGs.

After the public token was supplied, the native app was rebuilt and all 159 XCTest cases (including 9 analytics tests) passed again. The portable contract also passed. The configured bundle matched its source byte for byte (SHA-256 `273998ab7cb65fe726a2f7d1245d893bedccbb3bf2e1645606e21803dd91c51f`). A supplemental diagnostic check confirmed no analytics client or identity directory was created with the configured bundle. The resulting artifact is `dist/macos/QNotch.app` on the Mac. No ordinary app launch, personal authentication access, or additional ingestion event was used for this rebuild.
