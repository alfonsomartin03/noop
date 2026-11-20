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

## Rework (2026-11-20)

- Settings is one reading column (≤ 780 pt): a strap hero card (name, status, battery, Reconnect/Disconnect), then inset-grouped sections with short rows and long explanations moved to section footers. The adaptive two-column grid was dropped: uneven card heights made it harder to scan.
- Recalculate scores moved from the strap card to Data; check-ins render as flat rows inside their card.
- The illustration is one filleted strap silhouette (band fading at both ends, pod, level bar). The charging pack is drawn only while charging or full; pack attachment otherwise appears in the text facts only. Charging = bolt pack, lit seam, blue→green level; full = check, all green. The cue is a pack drop-in and two light sweeps, then still.

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

Implementation is present in `Strand/Screens/SettingsView.swift` and `Packages/StrandDesign/Sources/StrandDesign/ChargingIllustration.swift`. After the rework: StrandDesign 40 and app build + hosted 115 pass; illustration snapshots (light/dark) and the fixture app at 1180 pt light were looked at. Dark mode in the app, narrow widths, keyboard/VoiceOver and a real strap remain (steps 4–6).
