# Current NOOP features

The current product is the macOS app described in [README](../README.md). Navigation is defined in `Strand/App/RootView.swift` and `Strand/Screens/Hubs.swift`.

| Area | Available behavior |
| --- | --- |
| Overview | Recovery, sleep, strain, and HR summaries; contextual details; download/scoring status |
| Trends → Scores | Historical score and daily-signal charts |
| Trends → Sleep | Sleep trends and last-night detail |
| Trends → Vitals | Historical vitals and live health detail |
| Trends → Activity | Activity trends, sessions, workout detail, activity labels, effort and strength logging |
| Settings → General | Device/connection controls, profile/HR calibration, battery notifications, retention preference |
| Settings → Data | WHOOP ZIP/folder import, stored-data summary, NOOP/imported-score comparison, database backup/restore |
| Settings → Advanced | Recovery diagnostics, data explorer, live-strap sheet |
| App shell | First-run onboarding, top-right battery badge, ⌘1–⌘3 navigation, menu-bar companion |

BLE supports generation-specific WHOOP 4.0/5.0 paths; verified behavior and uncertainties are recorded in [reverse-engineering](reverse-engineering/README.md). Imported WHOOP scores and local estimates remain distinct sources. Derived metrics may be unavailable when coverage or baseline requirements are not met.

Apple Health parsers and related storage types remain in the packages, but there is no Apple Health import control in the current app. There are no separate Stress, Insights, Compare, Notifications, Automations, or Support destinations, and no iOS/Android app target.

## Work in progress in the current checkout

Sleep-session corrections and strap-alarm work are present as local changes at this documentation refresh, rather than part of the verified remote main commit. See [sleep sessions](SLEEP_SESSIONS.md) and [alarm capabilities](reverse-engineering/ALARM_CAPABILITIES.md). Do not treat those notes as a released or universally supported hardware feature; check the branch and device evidence before testing.
