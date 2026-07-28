# AutoMix Native design QA

## Comparison target

- Source visual truth: `docs/ui-ux-audit/second-pass/04-console-final.png`
- Rendered implementation: `docs/ui-ux-audit/native-redesign/06-native-live-final.png`
- Source viewport and pixels: 1280 × 720 CSS px, 1280 × 720 image px, 1× capture
- Implementation viewport and pixels: 1180 × 720 SwiftUI content points plus a 32-point macOS title bar, 1180 × 752 image px, 1× capture
- Intended native default content size: 1280 × 720; tested native minimum content size: 1180 × 720
- Production display: 5120 × 1410 logical screen, maximized native content approximately 5120 × 1378 points; Computer Use evidence was normalized to 2048 × 528 pixels
- Theme: dark broadcast-console theme on both surfaces
- State: the source is a synthetic running mix with SAFE active; the native capture is the real saved device/profile state with the engine gated and SAFE inactive. Dynamic values, configured role names, and engine availability were therefore excluded from pixel-level fidelity claims.
- Density normalization: the full views were judged structurally. Focused header and channel crops were compared at equal pixel dimensions after excluding the native title bar and centering the 1280-pixel source header to the 1180-pixel tested native width.

## Full-view comparison evidence

The source and implementation were opened together in one comparison input after the final build. Both establish the same operator hierarchy:

1. persistent engine, loudness, health, workspace, SAFE, FREEZE, and start/stop controls;
2. a dedicated service-scene row;
3. a horizontally scrollable channel rack;
4. a fixed right-side stream/master/detail rail;
5. a compact bottom automation, rehearsal, recording, remote, and runtime bar.

The native app intentionally uses actual `AppModel` data and controls. It does not reproduce the browser proof's synthetic EQ curves, DCA groups, or matrix-output blocks because those browser-only representations do not have equivalent native model data or actions.

## Focused comparison evidence

- Header source crop: `docs/ui-ux-audit/native-redesign/qa-source-header.png`
- Header implementation crop: `docs/ui-ux-audit/native-redesign/qa-native-header.png`
- Channel source crop: `docs/ui-ux-audit/native-redesign/qa-source-channel.png`
- Channel implementation crop: `docs/ui-ux-audit/native-redesign/qa-native-channel.png`
- Production-display pre-fix capture: `docs/ui-ux-audit/native-redesign/09-native-production-display.png`
- Production-display post-fix capture: `docs/ui-ux-audit/native-redesign/10-native-production-display-adaptive.png`

The focused crops confirm that the native app carries over the compact two-row header, cyan selection treatment, dark card hierarchy, meter emphasis, compact override controls, and quiet automation-reason copy without introducing placeholder art.

## Required fidelity surfaces

- Fonts and typography: both surfaces use a compact system sans with monospaced numeric readouts and tracked uppercase metadata. The native implementation uses 8-point minimum metadata after the QA fix; primary channel names and loudness values retain stronger optical weight.
- Spacing and layout rhythm: the main five-region composition, channel-card cadence, right rail, borders, radii, and compact bottom bar match the target. The macOS title bar is an expected platform frame, not app-content drift.
- Colors and visual tokens: canvas, raised panels, subtle borders, cyan selection, green health, amber warning, and red safety states map to the source hierarchy. Secondary and tertiary native text were raised to 62% and 42% white for legibility.
- Image quality and asset fidelity: the target contains no photographic or branded raster assets. The native app uses platform SF Symbols for functional icons and does not substitute visible target imagery with CSS, inline SVG, emoji, or placeholder art.
- Copy and content: app-specific labels are concise and operator-oriented. `SAFE` / `SAFE ACTIVE`, `FREEZE`, `LIVE`, `SETUP`, and `VALIDATE` are consistent. Native dynamic values and `Unknown` roles correctly reflect the unconfigured real profile rather than synthetic proof data.
- Icons: functional icons use one platform family and remain aligned with labels. No decorative icon treatment competes with telemetry.
- States and interactions: Live, channel selection, Setup, Validate, SAFE engagement, SAFE-release confirmation, and cancel/keep-safe behavior were exercised in the running app.
- Responsiveness: the native console remains coherent at its 1180 × 720 minimum content size. On the 5120 × 1410 production display, the operator shell now scales to preserve readable physical type and practical channel density. Wide channel content scrolls within the rack rather than hiding the master rail or persistent safety controls.
- Accessibility: the accessibility tree exposes named workspace, scene, SAFE, FREEZE, mute, role, slider, recording, and recovery controls. SAFE includes help text and a destructive release confirmation.

## Findings

No actionable P0, P1, or P2 differences remain.

- [P3] Browser-only DSP detail is not present in the native strip
  - Location: channel-card visualization.
  - Evidence: the source shows a small EQ response curve and classifier confidence; the native strip shows actual input level, trim, fader, noise floor, state, and override controls.
  - Impact: the native view is slightly less visually rich, but it avoids inventing telemetry the native model does not expose.
  - Follow-up: add a real response curve only after the engine publishes the corresponding per-channel DSP data.

- [P3] Unconfigured native content is quieter than the synthetic reference
  - Location: roles, levels, and start state.
  - Evidence: the source uses realistic synthetic channels and a running engine; the native capture accurately shows `Unknown`, silence, and a 96 kHz route warning from the saved profile.
  - Impact: this changes screenshot energy, not layout or interaction quality.
  - Follow-up: capture a second venue-proof set after loading the real service profile and HD96/Dante route.

## Comparison history

### Iteration 1 — blocked

- [P2] Dense metadata was too small and too low-contrast in `docs/ui-ux-audit/native-redesign/01-native-live.png`.
- Source labels remained subdued but readable; native 7-point labels at 30% white disappeared in channel stats, scene metadata, header units, and the bottom console.

Fixes:

- Increased all 7-point operator metadata to an 8-point minimum.
- Raised secondary text from 54% to 62% white and tertiary text from 30% to 42% white.
- Declared a 1280 × 720 default content size while retaining the tested 1180 × 720 minimum.

### Iteration 2 — passed

- Post-fix evidence: `docs/ui-ux-audit/native-redesign/06-native-live-final.png`
- The final full-view and focused comparisons show readable metadata, preserved hierarchy, no clipped persistent controls, and no remaining P0/P1/P2 drift.

### Iteration 3 — blocked at production-display scale

- [P2] Maximizing the fixed-point console across the 5120 × 1410 production display exposed roughly 27 channel strips at once, making labels and controls physically too small for live operation.
- Evidence: `docs/ui-ux-audit/native-redesign/09-native-production-display.png`

Fix:

- Added adaptive whole-console scaling based on available width and height, capped at 2×.
- The native view now preserves its minimum layout at ordinary window sizes and magnifies the operator surface on very large displays.

### Iteration 4 — passed at production-display scale

- Post-fix evidence: `docs/ui-ux-audit/native-redesign/10-native-production-display-adaptive.png`
- The maximized app now presents roughly 14 readable channel strips while preserving the complete header, scene row, master rail, and bottom safety/runtime controls.

## Primary interactions tested

- Selected channel 1 and verified the master rail exposed mute, manual fader, pan, and override-clear controls.
- Opened Setup and verified Core Audio, recovery, HD96 preflight, Dante checks, and the channel map remained available.
- Opened Validate and verified the stability monitor and channel map remained available.
- Engaged SAFE with one action.
- Requested SAFE release and verified the destructive `Release SAFE` and safe-default `Keep SAFE Engaged` actions.
- Kept SAFE engaged and dismissed the confirmation.

## Verification

- Native Debug build with signing disabled: passed.
- Native Release build with local ad-hoc review signature: passed.
- Simulated 64-channel/96 kHz audio, scene/role/manual override, telemetry, FREEZE, SAFE, recording, and soundcheck smoke: passed.
- Remote monitor static/auth/pairing/cookie/command/SSE smoke: passed.
- Packaged ZIP extraction, code-signature verification, monitor smoke, and simulated-audio smoke: passed.
- Diff whitespace validation: passed.
- Runtime crash/error check: no crash or app error was observed in the tested states. Browser console checks are not applicable to this native SwiftUI surface.

## Implementation checklist

- [x] Match the browser console's operator hierarchy in native SwiftUI.
- [x] Preserve real native audio/model actions instead of synthetic UI-only controls.
- [x] Keep Setup and Validate engineering workflows intact.
- [x] Verify channel selection and safety confirmation.
- [x] Fix dense-label contrast and minimum type size.
- [x] Build, run, capture, and compare final evidence.

final result: passed
