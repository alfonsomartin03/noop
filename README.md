# NOOP

NOOP is a local macOS companion for WHOOP straps. It collects data over Bluetooth, imports WHOOP exports, and computes its own sleep, recovery, and cardiovascular strain estimates on your Mac. No account, cloud service, or subscription is required by NOOP.

The app is named **NOOP**. `Strand` remains the internal app target, Xcode scheme, and Swift package prefix.

## What is in the app

- **Overview** — week strip; recovery, sleep and strain detail; heart-rate day card with activation timeline and coverage; optional morning/evening check-ins; sync and processing status.
- **Trends** — Scores, Sleep, Vitals, Activity and Highlights (records and streaks), with completed-period comparisons. Workout details support activity labels, perceived effort and strength sets.
- **Health** — experimental functional age and pace, VO₂max estimate, personal-range health monitor, heart-rate activation timeline (not a stress score).
- **Alarms** — strap alarms with an optional experimental smart-wake window and per-occurrence history.
- **Settings** — General (strap, Bluetooth, battery alerts, profile, research capture, check-ins); Data (WHOOP ZIP/folder import, comparison with imported scores, backup/restore); Advanced (recovery diagnostics, data explorer, live strap).
- **Bluetooth collection** — WHOOP 4.0/5.0 protocol paths, live readings, battery status, and historical downloads. Support varies by hardware, firmware, and verified protocol capability; see the [protocol evidence](docs/reverse-engineering/README.md).
- **Menu-bar companion** and first-run pairing/onboarding.

Primary navigation is a floating pill with Overview, Trends, Health, Alarms and Settings (⌘1–⌘5). See [architecture](docs/ARCHITECTURE.md).

For a plain-language overview of completed work, hardware evidence, and open research, see [project progress](docs/PROJECT_PROGRESS.md).

This repository builds a **macOS app only**. There is no Apple Health import, mobile app, cloud service or coaching. Package platform declarations are not shipped mobile apps.

## Build and run

Requires macOS 13+, Xcode with Swift 5.9 or newer, and XcodeGen. Swift package dependencies need to be resolved for the initial build.

```sh
git clone https://github.com/alfonsomartin03/noop.git
cd noop
xcodegen generate
open Strand.xcodeproj
```

Select the **Strand** scheme and run on **My Mac**; the product is `NOOP.app`. For a stable development signature, copy `Local.xcconfig.example` to `Local.xcconfig` and enter your development team. Allow Bluetooth access when pairing your strap.

See [build and test instructions](docs/BUILD.md) for command-line checks and signing details.

## Data and measurement

Data is stored in SQLite at `OpenWhoop/whoop.sqlite` beneath the app's Application Support directory (inside its container for sandboxed builds). Settings → Data exports/restores database backups; restoring replaces local database contents and requires relaunch. Preferences stored in UserDefaults are separate from that database.

NOOP estimates and imported WHOOP scores have separate provenance. Imported scores are not validation of NOOP's algorithms. Missing observations must remain distinguishable from zero; sleep stages and derived scores are estimates, not clinical measurements. See [architecture](docs/ARCHITECTURE.md#analytics-rules), [measurement validity](docs/MEASUREMENT_VALIDITY.md), and [privacy](docs/PRIVACY_SECURITY.md).

## Repository

| Path | Purpose |
| --- | --- |
| `Strand/` | macOS SwiftUI app, BLE transport, collection, read model, and screens |
| `Packages/WhoopProtocol/` | Framing, packet decoding, and protocol resources |
| `Packages/WhoopStore/` | SQLite/GRDB storage, migrations, and caches |
| `Packages/StrandAnalytics/` | Scoring, sleep/activity analysis, and incremental recomputation |
| `Packages/StrandImport/` | WHOOP export parser |
| `Packages/StrandDesign/` | Shared SwiftUI styling, components, and charts |
| `StrandTests/` | Hosted macOS app tests |
| `Tools/` | Protocol probes/decoders, performance probe, and scoring replay/research tools |
| `project.yml` | XcodeGen project definition; the generated Xcode project is ignored |
| `docs/` | Current guides, measurement research, protocol evidence; `docs/archive/` holds dated historical reports |

Start with [contributing](docs/CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and the [documentation index](docs/README.md).

NOOP is independent of WHOOP and is not a medical device. See [DISCLAIMER.md](DISCLAIMER.md) and [ATTRIBUTION.md](ATTRIBUTION.md) for limitations and upstream credits.
