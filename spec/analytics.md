# Action analytics, schema 1

QNotch Windows and Mac use explicit `qnotch_action` events. The versioned [catalog](../tests/fixtures/analytics/catalog-v1.json) defines fixed module/action pairs, targets, surfaces and outcomes. Native module ids `timer`, `note`, `filetray`, `colorpicker` map to `pomodoro`, `notes`, `files`, `color_picker` in analytics. The catalog is a union, not a claim of platform feature parity.

Every event has a generated UUID, capture timestamp and top-level `distinct_id`. Properties are `schema_version`, `platform` (`windows`/`macos`), `app_version`, `module`, `action`, `surface` (`ui`, `hotkey`, `cli`, `tray`, `onboarding`), `outcome` (`requested`), `install_id`, `identity_source` (`codex`, `claude`, `anonymous`) and `$process_person_profile: false`. Optional `target` must be in the fixed catalog; optional `enabled` is boolean. There is no arbitrary property bag or text/value field.

`requested` means an action was invoked. Dialog cancellation, remote rejection or OS failure may follow; this event never claims completion. A debounced note save records the save attempt, without text. Periodic refresh, provider observations, property bindings, rendered views and timer ticks are not user actions. Passive modules can have feature/presentation settings without their own action events.

Continuous controls record one action per gesture, not per step: volume changes, timer duration changes (a wheel spin through the minutes) and Mac media seeking. Calls less than 1.5 seconds apart belong to the same gesture. Windows `agents/cli_hook` records the first hook of each agent session since the app started, not every hook call. `agents/connect`, `agents/disconnect` and `agents/cli_hook` carry the agent as `target`: `agents_claude` or `agents_codex`. The welcome tour's Connect uses the `onboarding` surface on both platforms. A Mac GitHub sign-in records `cancel_connect` only when a sign-in in progress is cancelled, not when its view closes.

## Lifecycle event

`qnotch_active` says that QNotch is running, whether or not anyone touches it. It is sent once per launch, after the modules start (after the first-run tour, if one runs), and once per new UTC day while the app keeps running. Its fixed values are in the catalog's `lifecycle` section. Properties are the shared `schema_version`, `platform`, `app_version`, `install_id`, `identity_source` and `$process_person_profile: false`, plus:

| Property | Values |
| --- | --- |
| `reason` | `launch`, or `day` for a new UTC day while running |
| `channel` | Windows: `store` (MSIX), `winget`, `scoop`, `chocolatey`, `zip` (self-contained download), `exe` (framework-dependent download), `source` (not a tagged release build). Mac: `direct` (release build), `source` |
| `modules` | Enabled modules as sorted catalog targets. Windows reports the modules this start runs; Mac reads them at each event, because Mac module changes apply live |
| `previous_exit` | `launch` only: `clean` (the last run quit normally), `unclean` (it ended without its normal exit: a crash, a forced stop or power loss), `none` (no record) |

Package-manager channels are recognized locally from the executable's install folder; the path itself is never sent. Release builds are marked at build time: Windows tag builds on GitHub Actions, Mac builds given `QNOTCH_VERSION`. `previous_exit` comes from a one-word local file, `analytics-run-state` in the data directory, written `running` at launch and `exited` at a normal exit. Signing out, restarting or shutting down Windows or the Mac is a normal exit: Windows writes `exited` when the session ends, because the process can be stopped before its exit cleanup runs. It is written only while analytics is enabled. Windows checks for the new day on its existing 10-second delivery timer; Mac arms one one-shot timer for just after the next UTC midnight.

## Quit question (Windows)

A new Windows install is asked once, when the user quits, for the main reason. The question appears only when the install's first run was less than 7 days ago, it was never asked before, analytics is enabled (the local preference and the environment override, with delivery configured), the run is a normal one (not `--snapshot`, `--smoke-test`, `--measure`, `--debug-control` or read-only) and the shell is not in game mode. It never follows another exit: sign-out or shutdown, Restart now, an update install, the debug channel's `quit`, a second instance leaving or a crash. Only the two quit commands a user chooses ask: the tray menu and Settings, About. An install from before the question has no recorded first-run date and is never asked.

Choosing an answer, Skip, Esc or closing the dialog records `shell`/`quit_reason` with the same surface as the `quit` that triggered it (`tray` for the tray menu, `ui` for Settings), then quits. `quit` is unchanged. The `target` is one of seven fixed ids and nothing else: `quit_in_the_way` (It gets in my way), `quit_not_useful` (Nothing in it I'd use), `quit_missing_feature` (It's missing something I need), `quit_not_working` (Something didn't work), `quit_just_trying` (Just having a look), `quit_back_later` (Closing it for now, I'll be back) and `quit_skipped`. There is no text field and nothing else is sent. Every way out of the dialog quits; it cannot cancel the quit. The first-run date and the asked flag are local `GeneralSettings` values, excluded from setup codes. The Mac has no such question.

## Privacy and identity

No paths, names, titles, clipboard, notes, searches, terminal input/output, file metadata, account names, raw account ids, credentials, JWTs, notification text, token material or arbitrary errors enter payloads. Token reveal/copy events contain only the fixed action. No identify/person updates, autocapture, pageviews, exception capture, session recording or replay are enabled.

Identity adapts T3 Code commit `32ecd71726fee16f335484c1f95cbce126d461f6`: SHA-256 of Codex `tokens.account_id`, otherwise Claude `userID`, otherwise the persistent random install UUID. `install_id` is always SHA-256 of that UUID. Codex Team accounts can share a distinct id; the install hash distinguishes installations. Missing, malformed or API-key-only provider files fall through. Only the selected identifiers are read locally and hashed; tokens are never sent. [Synthetic hash vectors](../tests/fixtures/analytics/identity-v1.json) are consumed by platform tests. These are pseudonymous identifiers, not a claim of anonymous people.

Analytics is enabled by default through a local preference. `QNOTCH_TELEMETRY_ENABLED=false` overrides that preference; UI cannot override the environment. The **Share usage data** control is last in General. Disabling clears queued events and cancels active delivery; previously delivered events cannot be withdrawn. Re-enabling starts a fresh queue. The preference is excluded from setup codes.

Identity is read when the first event of a run is recorded, which is now the launch event. Diagnostics, snapshot, smoke, measurement and debug-control runs never initialize analytics transport, read provider identity, create the install id or write the run-state file. CLI invocations are recorded by the running app's receiving boundary, so diagnostic CLI children cannot independently initialize telemetry.

## Configuration and delivery

Each platform embeds `analytics-config.json` with public project-token `key` and `host`. The supplied QNotch public ingestion token is configured on both platforms with EU host `https://eu.i.posthog.com`. Normal users need no environment variables. Releases must embed the config inside the existing executable/app bundle; do not add ZIP entries or change Windows release names.

`QNOTCH_POSTHOG_KEY` and `QNOTCH_POSTHOG_HOST` override bundled values. Configure only public project tokens (`phc_`), never a personal API key. Windows enforces the token prefix; Mac requires a nonempty token and leaves authentication validation to ingestion. Both require HTTPS destinations without credentials, query or fragment. Missing configuration or a rejected destination disables delivery and identity work. Never borrow T3's destination/key or invent a project. Do not test real ingestion without an authorized QNotch project destination.

Native HTTP POST to `/batch/`, at most 20 events per request, 10-second partial-batch delivery interval, 10-second request timeout, bounded in-memory queue of 1000 (Mac may also have up to 20 in flight), UUIDs/timestamps retained across retries. Windows checks periodically; Mac schedules only while work is pending and immediately drains full successful backlogs. No queue is persisted to disk. Retry delay is half-to-full jitter over exponential 2 seconds to 5 minutes. A failed batch is retained at most 30 minutes. HTTP 400/401/413 drop that batch; other failures retry. Sends are serialized, redirects are disabled and exit attempts a best-effort flush. This follows T3's explicit transport approach without a new runtime SDK.

## Windows action inventory

The [source-site inventory](../tests/fixtures/analytics/windows-sites.json) records literal capture locations; the runtime allowlist is independently tested against the shared catalog. Capture is at explicit action callbacks or module command boundaries, not a generic click listener.

| Area | Action boundaries |
| --- | --- |
| Shell | User summon/hover, tab choice, settings navigation, pin/edit controls, card visibility/size/order, tab order, notch positioning, tray actions, game-mode overrides, manual update checks/install/release notes, quit, and the first-week quit reason (`quit_reason`, see [Quit question](#quit-question-windows)) |
| Onboarding | Next/back/skip/finish, feature choices, account setup callbacks |
| General/settings | Display, timing, pin/login/telemetry preferences, setup copy/check/apply, theme/accent/profile, sound choice/preview/reset, shortcut change/reset, feature enablement/presentation |
| Media | Play/pause, next/previous, session choice, seek; no playback or timeline observations |
| Clipboard | Copy, pin, remove, clear, persistence setting; no captured clipboard observation |
| AI | Launch/slots, custom apps, provider choices, account selection/rename, explicit usage refresh/scan; background usage polling silent |
| Agents | Show, dismiss, stop process, hook connect/disconnect and first received CLI hook per agent session, each with the agent (`agents_claude`, `agents_codex`) as target; no transcript/tool contents |
| Notes | Debounced save attempt; single note on Windows, no fabricated multi-note actions |
| Files/phone share | Add/drop/open/reveal/remove/clear/export, copy path action, share open/back/start/stop/extend/link copy/select all/none/reveal received; no paths or names |
| Notifications | Invoke/dismiss/clear/mute, test/token renewal/copy, settings, external command receipt; no automatic alerts/read tracking |
| Timer | Start/pause, user duration/reset through duration command, one per wheel gesture; no ticks/completion events |
| Color picker | Pick and copy result/recent color; no color value |
| Weather | Explicit search/place selection/forecast opening/refresh, units/pill settings; no periodic forecast traffic |
| Scheduled | Enable/pause and remove; no periodic Task Scheduler enumeration |
| Volume | Volume change, one per drag/wheel/key gesture, and mute invocation; OS volume observation silent |
| Terminal | New session, submit/copy/paste invocation; no keystrokes/commands/output |
| Stats/capture | Passive OS observations only; module and presentation choices are captured by shell settings |

Mac-only actions in the union include Quick Look, multiple-note management where available, login-items UI and native updater choices. Windows does not fabricate them. File tile selection and token reveal are cataloged for Mac; Windows phone sharing uses its explicit all/none selection controls and has no reveal-token control.

Coverage inventory is source-level evidence, not proof every OS integration succeeded. Platform tests validate delivery/identity/consent/privacy. A single synthetic batch using app version `validation` was accepted by the configured EU endpoint with HTTP 200 and `{"status":"Ok"}` on 2026-10-30. This verifies endpoint acceptance, not downstream dashboard visibility; no analytics query credential was provided. See [Windows verification notes](../docs/windows/analytics.md).
