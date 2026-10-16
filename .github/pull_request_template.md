## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checks

Affected areas: Windows / macOS development / website / repository / shared

<!-- Check relevant items and mark unrelated checks N/A with a short explanation. Do not require both operating systems for a platform-specific contribution. -->

- [ ] Ran the affected area's build/tests from CONTRIBUTING.md (list commands and results)
- [ ] Windows UI: ran `QNotch.exe --snapshot <dir>`, checked `snapshot.txt`, and inspected changed PNGs (attach them)
- [ ] Background work: supplied before/after CPU and memory results with platform, version, and measurement conditions
- [ ] Repository/release changes: ran root `npm test` and preserved the required `build` gate and Windows release compatibility
- [ ] Packaging changes: verified both Windows publish variants and the single-exe ZIP with `--verify-publish`, where affected
- [ ] Mac UI/providers: described real validation and known platform limitations; no feature-parity claims without evidence
