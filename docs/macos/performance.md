# Mac milestone measurements

## Parity modules: Timer, Volume, Note, Color picker, Mic and camera, System stats

Measured 2026-10-16 on the same Mac14,2, 8 GiB, macOS 26.3 configuration (release/arm64, built from the working tree that this commit records). `measure.sh` now records two 30-second collapsed intervals with every module enabled:

- **Enabled but quiet** (no stats in the wings, timer stopped, no capture in use): **0 app draw callbacks**, **0.00019% of one core**, **7 interrupt wakeups**, resident **73.3 MiB**, physical footprint **9.7 MiB**. Volume, Mic and camera, and battery use event listeners only. Note and Color picker do nothing until used.
- **Default System stats wings** (CPU and memory, sampled every 5 seconds while collapsed): **0 app draw callbacks**, **0.0011% of one core**, **18 interrupt wakeups**, resident **74.3 MiB**, footprint **10.0 MiB**. This is the one repeating collapsed wake so far. It runs only while a sampled stat is shown in the wings; with none shown, nothing is sampled.

Resident size counts clean pages of shared system frameworks. It rises with every framework a module loads (CoreMediaIO and IOKit added about 2 MiB), while the app's own physical footprint (what Activity Monitor shows as Memory) stays near 10 MiB. Both are recorded from now on. The 80 MiB resident target still holds, but it has less headroom than the footprint suggests.

[Raw sample](performance-2026-10-16-modules.json).

### Clipboard history

macOS has no pasteboard change notification. With Clipboard history on (the default), a 1-second timer with 0.5-second tolerance compares `NSPasteboard.changeCount` and reads contents only after a change. This is the agreed exception to "no repeating idle timers". Measured with every module enabled and nothing active: **0 app draw callbacks**, **0.0006% of one core** (up from about 0.0002%), **31 interrupt wakeups** in 30 seconds (up from about 7), footprint **9.8 MiB**, resident **62.4 MiB**. Turning Clipboard history off removes the timer. [Raw sample](performance-2026-10-16-clipboard.json).

## Integrated-notch correction

Measured 2026-10-16 on the same Mac14,2, 8 GiB, macOS 26.3 configuration, release/arm64 source `f1726270f109988e099535c7933c5dfa808c7e09`, clean when built. The surface now wraps the camera housing at the bezel. Native smoke checked actual window/view bounds: screen and surface top at 956 points, panel controls ending below the camera boundary at 924 points, and status views entirely in the side wings.

One isolated **31.495-second** collapsed-idle interval after the same three-second warmup recorded **0 app draw callbacks**, **0 surface rebuilds**, **6 interrupt wakeups**, **0.000218% of one core** (practically below 0.001%), and **70.1 MiB start / 65.3 MiB end resident memory**. Process start to panel ordering was **442.5 ms** in this run. This is another single sample, not evidence of a general memory improvement or a consistently met cold-launch target. The method and measurement limitations below still apply.

[Raw integrated-notch sample](performance-2026-10-16-notch.json). Local validation also passed 14 regressions and the native placement/focus/timer smoke test.

## Initial milestone baseline

Measured 2026-10-16 on Mac14,2 (Apple silicon, 8 GiB RAM), macOS 26.3 build 25D125. QNotch 0.1.0, release/arm64, source commit `87403d570ab4e0ad6880a18e544dc0f17ec5673e`, clean source when built. Toolchain: Swift 6.2.3, Xcode macOS SDK 26.2. These are Mac observations, not Windows benchmarks.

### Measured sample

`bash scripts/macos/measure.sh` launched a separate process with fresh temporary settings. After a three-second warmup, it measured one requested 30-second collapsed-idle interval. The actual interval was **31.471 seconds**, reflecting timer scheduling/coalescing. No timer was running, the pointer stayed away, and no UI smoke test ran concurrently.

- CPU: **0.000244% of one core** in this sample, using the process's user + system CPU time delta. Treat this as below 0.001% for practical interpretation, rather than a precision guarantee.
- Resident memory: **70.8 MiB at start, 70.6 MiB at end**. This is resident size, not private memory, peak footprint, or a long-duration leak test.
- Interrupt wakeups: **8** over the interval. This counter is not total thread wakeups.
- App view draw callbacks: **0**; surface rebuilds: **0**; panel remained collapsed. This does not measure WindowServer/compositor/GPU redraws.
- Process start to panel ordered front: **99.7 ms**, using the kernel process-start timestamp and the Mach clock. A preceding UI smoke launch of the same source recorded **398.8 ms**. Neither value includes first compositor presentation or Launch Services waiting.

[Raw machine-readable sample](performance-2026-10-16.json). The build's embedded source revision and dirty flag identify the measured source independently of subsequent documentation commits.

## Targets and limits

The development targets are CPU at or below 0.1% of one core while collapsed with a stopped timer, no repeating idle work, zero settled app draw callbacks, resident memory below 80 MiB, and process-start-to-panel-ordering below 500 ms. The sample meets these targets under the measured conditions. Earlier uncontrolled launches during rebuild/validation exceeded one second, so a consistent cold-launch target has **not** been established. This is one machine and one quiet interval, not a distribution or a guarantee across displays, OS versions, or workloads.

The native smoke test separately verifies that a hidden running timer finishes with one scheduled completion wake and that disabling it cancels scheduled work. An expanded running timer intentionally refreshes at most once per second. Those checks are behavior tests, not active-timer CPU benchmarks.

AppKit can redraw on desktop, display, focus, or appearance events; zero idle draw callbacks does not forbid event-driven repainting. Instruments/Energy Log, a longer idle run, cold-start sampling, physical multi-display reconnect, and macOS 13 installation checks remain useful follow-up validation before public distribution. See the [measurement procedure and platform limits](README.md#performance-targets-and-evidence).
