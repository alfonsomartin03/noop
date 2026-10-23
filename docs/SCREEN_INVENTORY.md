# Screen inventory and consolidation

Primary navigation went from a 9-item sidebar to a floating pill with 3 destinations: **Overview, Trends, Settings** (⌘1–⌘3).

| Before | Verdict | Now |
|---|---|---|
| Today | KEEP | **Overview** (detail views for Recovery / Sleep / Strain / HR still open in place from its cards) |
| Live | RELOCATE | Sheet opened from the Overview heart-rate card and Settings → Advanced; "Done" closes it. Realtime-HR start/stop lifecycle unchanged. |
| Sleep | MERGE | Trends → Sleep |
| Workouts | MERGE | Trends → Activity (no 4th tab: list + detail sheet does not justify one) |
| Vitals | MERGE | Trends → Vitals |
| Trends | KEEP | Trends → Scores |
| Data Explorer | RELOCATE | Settings → Advanced |
| Import & Export | RELOCATE | Settings → Data |
| Settings | KEEP | Settings → General |

Removed: `DataPendingNote` (unreferenced), the sidebar + sidebar status row (its connection/battery info is the top-right battery chip, which now opens Settings). Not removed: every other type is referenced; BLE, collection and store code untouched.
Kept on purpose: the menu-bar extra, the onboarding wizard, and the per-metric detail views inside Overview. The screens themselves are reused unchanged inside the segments, so their internal duplication (e.g. sleep shown on Overview, Sleep and Trends) is not yet collapsed.
