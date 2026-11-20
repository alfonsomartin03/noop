# Issue: Refine Settings and strap charging motion

## Goal

Make General Settings easier to scan on wide windows and compact on narrow windows, and make the strap charging animation feel purposeful without distracting from battery status.

## Design basis

- Apple Human Interface Guidelines: group related controls, use motion purposefully, and make custom motion optional. <https://developer.apple.com/design/human-interface-guidelines/motion>
- Microsoft Fluent 2: use quick, natural motion with clear hierarchy and transitions that explain a state change. <https://fluent2.microsoft.design/motion>
- GitHub Primer: keep motion subtle, respect reduced-motion preferences, and provide text for information conveyed by animation. <https://primer.style/accessibility/design-guidance/motion-and-animation/>

## Work completed

- Put strap status and its controls first in General Settings, followed by Profile.
- Put keep-data, research capture, check-ins, and About in an adaptive card grid that collapses to one column at narrow widths.
- Tightened section hierarchy by pairing each section title and description beside a compact icon badge.
- Changed the charging cue to a brief two-cycle flow on confirmed charging, then a still state; hovering replays the cue. Reduce Motion, app activity, and telemetry dimming continue to gate motion.
- Kept battery facts and the visible text status as the authoritative state; animation does not carry information by itself.

## Steps

1. [x] Reorder General Settings around the strap and profile tasks.
2. [x] Make supporting settings cards responsive to available width.
3. [x] Shorten the confirmed-charging motion and remove timed repeat playback.
4. [ ] Review the Settings page at 1180, 760, and 420 points in light and dark appearances; check that controls and copy remain legible and unclipped.
5. [ ] Check keyboard focus, VoiceOver section order, and Reduce Motion behavior.
6. [ ] Observe idle, attached, charging, full, unknown, and stale battery states in the running app; confirm the flow only occurs for confirmed charging and the text stays correct.

## Acceptance criteria

- Supporting cards use two columns when space permits and one column when they do not; no card content is clipped.
- Strap identity, connection state, battery percentage, pack attachment, and charging remain distinct facts.
- The charging illustration settles after its brief cue, does not repeat on a timer, and remains understandable with motion disabled.
- No new user-default keys or telemetry claims are added.

## State

Implementation is present in `Strand/Screens/SettingsView.swift` and `Packages/StrandDesign/Sources/StrandDesign/ChargingIllustration.swift`. Automated tests, app build, visual review, and hardware confirmation have not been run for this issue.
