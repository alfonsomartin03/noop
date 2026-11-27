# NOOP architecture

NOOP is a local-only macOS SwiftUI companion for WHOOP 4.0/5.0 straps: no cloud, no account, no mobile app. `project.yml` (XcodeGen) defines the `Strand` app target (product `NOOP.app`) and the hosted `StrandTests`; five local Swift packages hold everything that does not need the app. Source and tests are the reference; this page is a map.

## Data flow

```text
WHOOP strap ↔ BLEManager / Commands
                 ↓ FrameRouter → LiveState → LiveHeartRate / BatteryPresentation → UI
                 ↓ Collector / Backfiller (persist, then acknowledge)
            WhoopProtocol → WhoopStore (SQLite/GRDB, actor)
                                  ↕
                IntelligenceEngine → IncrementalScorer / AnalyticsEngine
                                  ↓
                Repository → SwiftUI screens / menu bar

WHOOP ZIP/folder → StrandImport → WhoopImporter → WhoopStore
Settings → Data ↔ DataBackup ↔ user-selected database backup (restore = replacement + relaunch)
AlarmController → AlarmPlanner / SmartWakeDecider → AlarmDeliveryTransaction → strap + Mac notification
```

`AppModel` (one instance shared by the window and the menu bar) owns the BLE engine, live state, `Repository`, profile, scoring schedule, imports, battery alerts and alarms. At launch `Repository.prewarm()` opens the store and reads the dashboard rows on a detached task while the first window is built; every caller shares that single open. Scoring runs on a utility task, never in views, and is persisted under a separate `<device>-noop` identity.

## Packages

| Package | Responsibility | Depends on |
| --- | --- | --- |
| `WhoopProtocol` | Frame verification/reassembly, 4.0/5.0 device families, packet/stream decoding, 5.0 messages, charging model, ops counters, bundled schema | — |
| `WhoopStore` | Actor over GRDB: migrations (schema v22), source streams, sync receipts, phone outbox, returned score summaries, derived rows, provenance, training logs, alarm history, check-ins | WhoopProtocol, GRDB |
| `StrandAnalytics` | HRV, sleep staging/sessions, recovery, load/strain, workouts, causal baselines/replay, incremental scoring, alarms, health models | WhoopProtocol, WhoopStore |
| `StrandImport` | WHOOP CSV export (ZIP or folder) parsing | ZIPFoundation |
| `StrandDesign` | Palette, typography, motion, cards, charts, charging illustration, zone spectrum | — |
| `StrandSync` | Phone → Mac batch envelope (version, digest), Mac archive ingest and receipts, phone outbox sync pass (#77), encrypted local-network session with code-confirmed pairing and Keychain trust (#79; not wired into the apps yet) | WhoopProtocol, WhoopStore |

Manifests declare macOS 13 / iOS 17 and all build for iOS. App targets: macOS `Strand` and the iOS shell `StrandPhone` (no strap code yet).

## App layers

| Folder | Responsibility |
| --- | --- |
| `Strand/App` | Entry (`AppEntry` test-host gate), `AppModel`, shell (`RootView`, floating nav, live sheet) |
| `Strand/BLE` | CoreBluetooth transport, allowed commands, routing, live state, reconnect |
| `Strand/Collect` | Ordered ingestion, clocks, history ack gate, raw/research archives, ops-counter files, store paths |
| `Strand/Data` | Read model (`Repository`), scoring coordination, WHOOP import mapping, backup, profile, check-in settings |
| `Strand/Device`, `Strand/Alarm` | Battery presentation/alerts, alarm runtime |
| `Strand/Screens`, `MenuBar`, `Onboarding` | Presentation only |

## Screens

Floating pill, ⌘1–⌘5: **Overview** (`TodayView`: week strip, recovery/sleep/strain detail in place, HR day card, check-ins), **Trends** (`TrendsHub`: Scores, Sleep, Vitals, Activity, Highlights), **Health** (`HealthPageView`: functional age, VO₂max estimate, health monitor, activation timeline), **Alarms** (`AlarmsView` + history), **Settings** (`SettingsHub`: General, Data, Advanced). The live strap is a sheet; onboarding overlays the shell on first launch; the menu-bar extra shares `AppModel`.

## Storage

`StorePaths` resolves `OpenWhoop/whoop.sqlite` under Application Support (inside the sandbox container). WAL/SHM accompany it; raw/research/live-rr archives, ops-counter files and UserDefaults are separate. Raw strap rows, imported WHOOP rows and NOOP-derived rows (`<device>-noop`) keep distinct identities; `Repository` merges them for display (imported field wins) and imported values never enter NOOP baselines. User labels, effort, strength sets, sleep corrections, alarm notes and check-ins are source records that rescoring preserves.

Rules: add migrations, never edit applied ones; keep missing, unknown, partial and zero distinct; never drop legacy tables just because a UI entry point went away (`appleDaily` stays in the schema, unused); tools that open a store can migrate it, so use a SQLite-backup copy.

## Analytics rules

- Imported WHOOP results and NOOP estimates are different sources; agreement is a compatibility check, not validation. Nothing is clinically validated.
- Missing observation is not zero, awake or sleep. Stage hypnograms come only from genuine timestamped stages.
- Baselines are causal (prior days, compatible metric identity). Load counts supported awake time only (scoring v5).
- Perceived effort, strength volume and HR load are separate quantities; activity detection does not establish a sport.
- Algorithm versions are part of the scoring key; changing one re-scores affected days.

Evidence and method notes: [MEASUREMENT_VALIDITY](MEASUREMENT_VALIDITY.md), [SLEEP_SESSIONS](SLEEP_SESSIONS.md), [NAP_DETECTION](NAP_DETECTION.md), [HEALTH_MODELS](HEALTH_MODELS.md); protocol evidence in [reverse-engineering](reverse-engineering/README.md).
