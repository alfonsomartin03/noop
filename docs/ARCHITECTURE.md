# NOOP architecture

NOOP is a macOS SwiftUI app with five local Swift packages. `project.yml` defines the `Strand` application and `StrandTests` hosted tests. The product is NOOP.

## Data flow

```text
WHOOP strap ↔ BLEManager / Commands
                  ↓ FrameRouter / Collector / Backfiller
             WhoopProtocol → WhoopStore (SQLite/GRDB)
                                  ↕
                     IncrementalScorer / AnalyticsEngine
                                  ↓
                 Repository → SwiftUI screens / menu bar

WHOOP ZIP/folder → StrandImport → WhoopImporter → WhoopStore
Settings → Data ↔ DataBackup ↔ user-selected database backup
```

`AppModel` owns app coordination, connection/collection services, and the published state used by the UI. `LiveState` carries changing strap readings; `LiveHeartRate` turns them into the one smoothed live number and publishes only when it changes, so per-beat updates don't invalidate views that observe `AppModel`. `Repository` supplies stored/derived screen data. `IntelligenceEngine` coordinates scoring; its scoring pass dispatches `IncrementalScorer` on a utility task. Scoring is persisted under a separate `-noop` device identity, with imported rows kept distinct.

## Boundaries

| Layer | Responsibility |
| --- | --- |
| `Strand/BLE` | CoreBluetooth transport, command dispatch, live state, routing |
| `Strand/Collect` | Ordered historical ingestion, clocks, raw archive and retention |
| `WhoopProtocol` | Frame verification, reassembly, packet interpretation; no BLE connection |
| `WhoopStore` | Actor-backed database access, migrations, source rows, derived caches and provenance |
| `StrandAnalytics` | Signal analysis, sleep/recovery/load calculations, causal replay and incremental scoring |
| `StrandImport` | File parsing; WHOOP app import plus retained Apple Health library support |
| `StrandDesign` | Shared visual tokens, layout primitives, components and charts |
| `Strand/Data` | App read model, profile, import mapping, backups, scoring coordination |
| `Strand/Screens` | Screen presentation and user interactions |

Many numerical routines are pure; the analytics package as a whole is not I/O-free: incremental scoring reads/writes through `WhoopStore`, and calendar handling uses `ZoneTimeline`. Avoid assuming that an actor or async function automatically makes all work nonblocking. Preserve task isolation and measure main-thread work.

Historical packet ordering and acknowledgement/retention behavior are data-integrity constraints. Keep raw ingestion, persistence, and derived scoring separate so UI changes cannot alter the wire protocol or lose samples. See [protocol evidence](reverse-engineering/README.md).

## Presentation

`RootView` has three destinations: Overview (`TodayView`), Trends (`TrendsHub`), and Settings (`SettingsHub`). Hubs embed existing feature screens; the live strap is a sheet. Onboarding overlays the shell, and the menu-bar scene shares the app model. See [SCREEN_INVENTORY.md](SCREEN_INVENTORY.md).

`StrandDesign` owns reusable styling. UI consistency work should consolidate both presentation and metric formatting/state semantics, without moving scoring into views.

## Storage and scope

See [DATA_MODEL.md](DATA_MODEL.md) for storage entry points and [ANALYTICS.md](ANALYTICS.md) for scoring boundaries. The database path is resolved by `StorePaths`, not hard-coded to a developer's home folder.

The repository contains macOS app targets only. Retained Apple Health parsers, package platform declarations, and protocol research do not imply a visible feature or a shipped mobile client. Local sleep-session/alarm work is tracked separately in [FEATURES.md](FEATURES.md).
