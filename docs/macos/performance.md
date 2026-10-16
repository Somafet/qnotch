# Mac milestone measurements

Measured 2026-10-16 on Mac14,2 (Apple silicon, 8 GiB RAM), macOS 26.3 build 25D125. QNotch 0.1.0, release/arm64, source commit `87403d570ab4e0ad6880a18e544dc0f17ec5673e`, clean source when built. Toolchain: Swift 6.2.3, Xcode macOS SDK 26.2. These are Mac observations, not Windows benchmarks.

## Measured sample

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
