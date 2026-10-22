# Proposal: align macOS status content to consistent outer gutters

Status: proposal for discussion; no app behavior changes are implemented.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).
The reported app's exact binary revision and OS version were not supplied; source findings apply to this baseline.

## Problem and evidence

In the supplied collapsed screenshot, CPU floats well inside the left side while weather and RAM fill the right. The visual padding appears to depend on the amount of content on the opposite side.

[measureWing and layoutStatus](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/ShellController.swift#L676) confirm the cause: both wings use a width based on the larger cluster, and each cluster is independently placed at `area.midX - size.width / 2`. Thus a short CPU cluster inherits extra space from the fuller right wing. This is a deliberate current formula, with an undesirable visible result in the reported configuration.

## Proposed behavior

Keep symmetric black wings around the hardware housing, but anchor the left content cluster to the left outer gutter and the right cluster to the right outer gutter. Prototype a shared 12-point inset from each clear wing boundary, measured after the flare. Keep a minimum camera-side clearance, even if a segment must overflow or be omitted. The exact inset is a proposal, not an existing token.

Do not make wings independently sized merely to close a content gap: retain the existing notch silhouette. Keep overflow deterministic and ensure interactive targets follow their visible segment after reflow.

## Acceptance criteria for a later implementation

- CPU alone left and weather + RAM right have equal outer gutters, vertically centered in the safe band.
- CPU 4%, 55%, and 100% keep a stable left anchor; right-hand values keep a stable right anchor.
- Compare left-only, right-only, both empty, timer, media, microphone/camera, notifications, agent peeks, maximum-fit and overflow states.
- No text overlaps the hardware housing, flare or another segment, including display scaling and long/localized values.
- Expanded and collapsed states keep status anchors stable; floating pills retain their own intentional layout.
- Capture annotated before/after screenshots at native display scale and assert geometry within 1 point after integral rounding.

## Review classification and validation

Medium polish finding; `rule/alignment-consistent`. Direct visual evidence: user-supplied collapsed screenshot. Source explains the alignment; a fresh native build was unavailable because full Xcode is missing.

Discuss outer-edge anchoring versus camera-facing anchoring. Recommended: matching outer gutters because they make the shape read as one intentional status bar and satisfy the CPU-left expectation. Verify legibility of the existing 9-point stat labels at actual scale; avoid automatically importing web font-size thresholds into AppKit.
