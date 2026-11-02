# Screen inventory

Primary navigation is a floating pill with three destinations, **Overview, Trends, Settings** (⌘1–⌘3). Everything else
opens from a card, a segment or the menu bar.

| Surface | Where | Notes |
| --- | --- | --- |
| Overview | ⌘1, `TodayView` | Week strip; Recovery, Sleep, Strain cards open their detail in place (`TodayDetailViews`); the heart-rate card opens the live-strap sheet |
| Trends | ⌘2, `TrendsHub` | Segments Scores, Sleep, Vitals, Activity, each with a history view and a detail view (Last night, Live, Sessions) |
| Settings | ⌘3, `SettingsHub` | General (strap, battery and charging, alarms, profile), Data (import, comparison, backup), Advanced (diagnostics, data explorer, live strap) |
| Live strap | Sheet from Overview → Heart rate and Settings → Advanced | Live heart rate and battery first; connection controls, link status, sync, packets and log in a collapsed "Connection details" section. Realtime HR runs only while it is open; Done or Esc closes it |
| Workout / sleep detail | Sheets from Trends → Activity and Sleep | Labels, perceived effort, strength sets, sleep corrections |
| Battery badge | Top right of every destination | Opens Settings |
| Menu-bar extra | `MenuBarContent` | Live HR, recovery, battery, connect / live-feed actions |
| Onboarding | Overlay on first launch | Pairing and profile |

## Shared presentation

- Live heart rate everywhere (Overview, Vitals, live sheet, menu bar) is `LiveHeartRate.bpm`: one smoothed value, and
  live zones use the scoring `HRZones` bands with the profile's max HR (below 50 % reads "Below Zone 1").
- Battery everywhere (badge, menu bar, Settings → Strap, live sheet, onboarding) is `BatteryPresentation`: low below the
  low-battery alert threshold (20 %), stale after the alert policy's 10 minutes or on disconnect, charging only from a
  verified fresh reading.
- Charging: Settings → Strap and the live sheet show `StrapBatteryPanel` (the `ChargingIllustration` from StrandDesign).
  When verified charging starts (or the panel appears while charging), light flows from the pack into the strap for
  four short cycles, then rests as a steady glow with the bolt: each animated frame costs a window update, so the ongoing
  indication is still. At 100 % it holds steady; a stale or disconnected reading is drawn dimmed, with the pack lifted
  off. Reduce Motion draws every state still. Charging is what the strap reports: its charging or pack events, or on a
  WHOOP 5.0 the GET_BATTERY_PACK_INFO reply NOOP sends with each battery read (see
  `reverse-engineering/SAFETY_MATRIX.md`). The attached reply hasn't been captured on hardware yet.
- Recovery state words come from `StrandPalette.recoveryState` on every surface.
