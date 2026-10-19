# First-run onboarding

A short, skippable welcome that shows what QNotch does, lets a new user pick features and connects accounts on the spot. Both platforms implement it natively (WPF on Windows, AppKit on the Mac) from this contract. Step ids, settings keys and the GitHub device flow are shared. Layout, controls and wording details can follow each platform's conventions.

## When it shows

- **Automatically, once, on a fresh install**: the app starts and finds no general settings file (`general.json` on Windows, the Mac's equivalent). It runs before any module is constructed, so the feature choices apply with no restart.
- **Existing users never see it automatically.** If the general settings exist but have no `OnboardingDone` value, the app sets `OnboardingDone = true` silently.
- **On demand**: Settings has a **Show welcome tour** button (General on Windows, About on the Mac). A tour opened this way runs while the app is running. Its Features step is read-only: a feature list with a **Change in Settings** link instead of switches.
  - Platform difference: the Mac turns features on and off without a restart, so its on-demand Features step keeps the switches and applies them at once, exactly as Settings, Features does.
- Never in diagnostic runs: Windows `--snapshot` renders the steps (see Verification) instead, and Mac `--smoke-test`/`--measure` skip the tour.

`OnboardingDone` (bool) lives in the general settings and is set when the tour finishes, is skipped or its window is closed. It is a local preference, so it is never shared in setup codes. The Mac stores it as `onboardingDone` in `general.json`, its usual key style; it writes `false` when a first-run tour starts, so a tour that never ended (the app quit midway) shows again at the next launch.

## Window

- A standalone, centered window that has focus. It is not the notch panel. About 760 × 520, dark like the notch (near-black surface, bordered cards, accent chips), with no standard title bar. It has a close control and can be dragged.
- Top: a hero area of about 55% of the height with an illustration of the step. It is built from the platform's own glyphs and cards (a miniature pill, Home cards, the feature tiles). Bitmaps are optional, never required. Bottom: title, a one-line subtitle and the step's content.
- Footer: progress dots (one per step shown), **Back** (hidden on the first step), **Skip** (ends the tour with what has been chosen so far plus defaults) and the primary button (**Continue**, or the step's own label).
- Keyboard: Return activates the primary button, Esc skips, Tab moves through controls. Every control has an accessible name. Motion follows [Motion](#motion), including reduced motion.
- Closing the window counts as Skip. Skipping never discards a choice that was already made, such as a saved GitHub token or a toggled feature.

## Motion

Both platforms follow this contract with their own animation system (Core Animation on the Mac, WPF storyboards on Windows).

**Principles.** Motion is purposeful and quick, mostly 180–320 ms. Entrances ease out, exits ease in. A gentle spring or overshoot is reserved for success moments. Only opacity and transforms animate, never layout in a loop. A looping animation runs only while its step is shown and the window is visible and not covered; otherwise it is removed, not just hidden. With reduced motion (the system setting, or QNotch's own **Reduce motion**) there are no slides, scales, loops or staggers: changes are 120 ms crossfades or cuts.

1. **Window.** It enters with a fade from 0, a scale from 0.96 and a 12 pt rise, about 300 ms, ease-out. Skip and close leave with a fade and a scale to 0.98 in 160 ms.
2. **Step transitions** are directional. Forward, the outgoing content slides about 24 pt left and fades while the incoming slides in from the right; Back mirrors it. The hero moves about half the distance of the content (parallax), and the content follows it by about 40 ms: title, subtitle, then the step's controls, about 30 ms apart. About 260 ms in all.
3. **Progress dots.** The active dot's pill width and color animate from step to step.
4. **Buttons and controls** give hover and press feedback (color in 120 ms, a press scale of 0.97). The primary button's label crossfades when it changes (Get started, Continue, Open QNotch).
5. **Hero moments** play once when a step is entered; loops only where stated.
   - `welcome`: the notch drops in from the bezel and its segments fade in one by one (about 50 ms apart); the panel then unfolds downward (scale from its top edge with a fade) and its cards stagger in (about 60 ms apart). Optional: a very slow ambient drift of the glow behind the hero (a cheap loop).
   - `open`: the cursor glides to the notch, which takes its hover glow; then the key caps press down in order (⌃, ⌥, N) and release, repeating about every 3 s while the step is shown. When the user presses the real gesture, the caps go down together, the "That's it" check pops (spring 0.6 → 1.08 → 1) and the caps' loop stops.
   - `features`: tiles stagger in row by row (about 20 ms per tile, at most about 300 ms in all). A switch animates its tile's icon tint and the tile's opacity (about 55% when off) in 150 ms. **Turn all off/on** ripples down the group (about 30 ms per tile).
   - `connect`: the cards stagger in. The GitHub contribution grid fills cell by cell in a diagonal wave (about 400 ms) when it appears and again when sign-in succeeds. Row status text crossfades. The device-code panel expands once when the code arrives, and "Waiting for you…" has a subtle pulsing dot that loops only while polling. A successful connection turns the status green with the check spring.
   - `finish`: the "QNotch is ready" check draws its stroke (about 350 ms) as its chip pops in. **Open QNotch** hands off to the product: the tour shrinks and flies to the notch at the top center of the notch's display (scale about 0.3, moving up, fading, about 350 ms, ease-in) and the real panel springs open as it arrives. The panel takes the keyboard before the tour window goes away.
6. **Determinism.** Snapshots and smoke tests see the settled final state: they skip or complete every animation. No timer or display link outlives the tour.

## Steps

The tour shows each step below in order and leaves out a step that has nothing to show. The ids are stable (used for snapshots, logs and tests).

### 1. `welcome`

- Title: **Welcome to QNotch**. Subtitle: *Everything you glance at, in the notch at the top of your screen.*
- Hero: the pill with a few live-looking segments (time, weather, now playing), then the panel opening below it.
- Primary: **Get started**. The footer Skip label here is **Skip setup**.

### 2. `open`

- Title: **Open it from anywhere**. Subtitle: *Hover the notch, or press your shortcut.*
- Shows the current toggle shortcut as key caps (read from the shortcut service, never hardcoded). **Change** records a new gesture with the same rules and conflict reporting as Settings, Hotkeys, and saves it the same way.
- *Try it now*: pressing the gesture while the tour window has focus shows a check mark (**That's it**). It is detected locally in the window, so no global hook is added.

### 3. `features`

- Title: **Pick your features**. Subtitle: *You can change these any time in Settings, Features.*
- One tile per `ModuleList` entry (its icon, title and description) with a switch, grouped in this order. A platform without one of the modules leaves it out.
  - **At a glance**: stats, media, weather, capture, timer, volume
  - **Get things done**: clipboard, search, note, filetray, colorpicker, scheduled
  - **For developers**: agents, ai, github, notifications
- Every switch starts on (today's default). **Turn all off** / **Turn all on** per group. The result is written to `DisabledModules`.
- When the tour was opened on demand, this step is read-only (see When it shows).

### 4. `connect`

- Title: **Connect your accounts**. Subtitle: *Optional. Everything else works without them.*
- One row per enabled feature that has a one-step setup. Each row shows its status (*Not connected* / *Connected as @login* / *Berlin, Germany*) and its action. Without such a feature (for example, GitHub, Weather and Agents are all off), the step is left out.
  - **GitHub**: **Sign in with GitHub** (device flow, below). A secondary **Use a token instead** opens the existing paste box inline.
  - **Weather**: a place search box (the same provider and search as Settings, Weather) that saves the chosen place.
  - **Agents**: **Connect Claude Code** / **Connect Codex** for each installed agent, using the module's existing Connect action (same file changes, backup and messages as Settings).
- Rows come from the modules, not the shell. Each module that wants a row provides a static setup factory next to its `ModuleList` entry (Windows: an optional `ModuleInfo` member; Mac: the same idea in `ModuleInfo`). The factory must work before the module is constructed: it uses only static helpers, the settings store and the credential store, and never starts providers. The running module picks up what the row saved when it starts (and on demand, through the same path Settings already uses).

### 5. `finish`

- Title: **Final touches**.
- **Check for updates automatically** (on by default). Windows: sets `CheckForUpdates` and `UpdateChecksChoiceMade`, so the first-start Settings, Updates prompt no longer opens after a completed or skipped tour. Mac: sets Sparkle's `automaticallyChecksForUpdates` and records that the choice was made, so Sparkle does not ask on the second launch.
- **Start with Windows** / **Open at login** (on by default), using the platform's existing setting.
- Tips with real gestures: the Search shortcut, *Right-click the tray icon* or *Use the menu-bar item* for Settings, and *Drag files onto the notch* (only if File tray is on).
- Primary: **Open QNotch**: finishes the tour, closes the window and opens the panel on Home with keyboard focus.

A skipped tour applies these defaults: features as toggled so far (all on if untouched), updates on and start at login unchanged. On Windows, skipping also sets `UpdateChecksChoiceMade`, because the default was shown in the tour.

## GitHub device flow

Both platforms sign in with the [OAuth device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow). It needs no backend, no client secret and no redirect handling. The public client ID of QNotch's GitHub OAuth App (with Device Flow enabled) is a constant in each platform's GitHub module (`GithubOAuth.ClientId`). While it is empty, the app hides every **Sign in with GitHub** button and shows the token paste box.

1. `POST https://github.com/login/device/code` with `client_id` and `scope=read:user` and `Accept: application/json`. The response gives `device_code`, `user_code`, `verification_uri`, `expires_in` and `interval`.
2. Show `user_code` large, in a monospaced font, with **Copy code and open GitHub**: this copies the code and opens `verification_uri` in the default browser. Below: *Waiting for you to approve QNotch on GitHub…* with **Cancel**.
3. Poll `POST https://github.com/login/oauth/access_token` with `client_id`, `device_code` and `grant_type=urn:ietf:params:oauth:grant-type:device_code`, every `interval` seconds:
   - `authorization_pending`: keep waiting.
   - `slow_down`: add 5 seconds to the interval (or use the `interval` in the response).
   - `expired_token`: *The code expired.* plus **Try again**.
   - `access_denied`: *Sign-in was cancelled on GitHub.* plus **Try again**.
   - A network error: show it and allow **Try again**. Never retry in a tight loop.
4. On `access_token`: save it in the platform credential store under the same entry as a pasted token (Windows Credential Manager `QNotch/GitHub`, Mac Keychain). Check it with the existing request, then show **Connected as @login**.

Polling runs only while the sign-in UI is visible. Cancel, closing the window, the tour ending or `expires_in` passing stops it. The token, device code and user code are never logged. **Sign in with GitHub** also appears in Settings, GitHub on both platforms, above the token box.

Only `read:user` is requested. People who want private activity counted can still paste a classic token with `repo`, as today.

## Privacy and docs

- New network requests: `github.com/login/device/code` and `github.com/login/oauth/access_token`, only when the user clicks **Sign in with GitHub**. List them with each platform's network requests.
- The tour itself makes no requests. The Weather place search makes the same requests as Settings, Weather.

## Verification

- Windows: `--snapshot` also writes `onboarding-<step>.png` and its `.txt` twin for every step (with demo values: a connected GitHub row, a chosen place). Unit-style checks: the fresh-install, existing-user and on-demand decisions, `DisabledModules` from the feature choices, and device-flow response handling (pending, slow_down, expired, denied, success) against canned JSON with no network.
- Mac: XCTest for the same decision table and the device-flow parser in `QNotchMacCore`. The smoke test opens the tour in an isolated data directory, steps through every step and closes it.
