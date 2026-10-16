# Shared product principles

QNotch puts a small status surface at the top of a display and opens a panel on demand. This document applies to both platform designs. [ARCHITECTURE.md](../ARCHITECTURE.md) contains the current Windows implementation contract; [SPEC.md](../SPEC.md) retains the original Windows design.

## Modules and behavior

- The shell owns window behavior, focus, layout, and navigation. Modules own their state, providers, views, and settings.
- The common extension concepts are cards, tabs, status segments, search sources, and settings sections. Keep identifiers stable when interoperability requires it; controls and OS APIs can differ.
- Disabled modules do not start providers or background work. A feature's presence on one platform does not imply availability on the other.
- Missing data has an explicit unavailable state. Do not render unavailable values as zero or imply access the OS does not provide.
- Preserve user focus unless they explicitly summon input. Honor reduced motion and support keyboard navigation and accessible control names.

## Resource use and data

- Prefer OS events, coalesce bursts, and avoid publishing unchanged state. Sampling exceptions must be justified by the platform API.
- Hidden content does not keep unnecessary animations, layout, or provider work alive. Background work must not block input.
- Bound caches and histories, decode images at useful sizes, and stream large transfers.
- Keep data local by default. Explain outbound requests, make optional network features switchable, and store secrets in the platform credential store.
- Document per-platform targets and measured results separately. Include the version, hardware, configuration, interval, and measurement method. Do not copy Windows renderer, JIT, or working-set techniques into the Mac contract.

## Compatibility fixtures

[release-tags.json](../tests/fixtures/release-tags.json) defines the reserved publishing channels. Repository tests consume every case; Windows updater tests consume valid Mac cases to prove those tags do not become Windows updates. Publishing accepts a narrower stable Windows tag format than the existing updater's historical parser, which remains unchanged.

[The notification reference](../docs/notifications.md) documents the released Windows protocol. A Mac implementation can reuse portable payload semantics, but must document its own CLI and local transport before claiming compatibility. Setup-code portability and cross-platform feature parity are not established by this preparation.
