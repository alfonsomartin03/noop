# NOOP

NOOP is a local macOS companion for WHOOP straps. It collects data over Bluetooth, imports WHOOP exports, and computes its own sleep, recovery, and cardiovascular strain estimates on your Mac. No account, cloud service, or subscription is required by NOOP.

The app is named **NOOP**. `Strand` remains the internal app target, Xcode scheme, and Swift package prefix.

## What is in the app

- **Overview** — daily recovery, sleep, strain, and heart-rate cards with contextual details, connection/download status, and score-processing progress.
- **Trends** — Scores, Sleep, Vitals, and Activity segments; historical charts, sleep details, and workout sessions. Workout details support activity labels, perceived effort, and strength sets.
- **Settings** — General for device/profile preferences; Data for WHOOP ZIP/folder import, comparisons with imported scores, and database backup/restore; Advanced for recovery diagnostics, the data explorer, and the live-strap sheet.
- **Bluetooth collection** — WHOOP 4.0/5.0 protocol paths, live readings, battery status, and historical downloads. Support varies by hardware, firmware, and verified protocol capability; see the [protocol evidence](docs/reverse-engineering/README.md).
- **Menu-bar companion** and first-run pairing/onboarding.

Primary navigation uses Overview, Trends, and Settings (⌘1–⌘3). See [features](docs/FEATURES.md) and the [screen map](docs/SCREEN_INVENTORY.md).

This repository builds a **macOS app only**. Apple Health parsing remains in `StrandImport`, but there is no Apple Health import screen in the current app. Package platform declarations are not shipped mobile apps. Removed stress, coaching, automation, and standalone insights screens are not current features.

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

NOOP estimates and imported WHOOP scores have separate provenance. Imported scores are not validation of NOOP's algorithms. Missing observations must remain distinguishable from zero; sleep stages and derived scores are estimates, not clinical measurements. See [analytics](docs/ANALYTICS.md), [measurement validity](docs/MEASUREMENT_VALIDITY.md), and [privacy](docs/PRIVACY_SECURITY.md).

## Repository

| Path | Purpose |
| --- | --- |
| `Strand/` | macOS SwiftUI app, BLE transport, collection, read model, and screens |
| `Packages/WhoopProtocol/` | Framing, packet decoding, and protocol resources |
| `Packages/WhoopStore/` | SQLite/GRDB storage, migrations, and caches |
| `Packages/StrandAnalytics/` | Scoring, sleep/activity analysis, and incremental recomputation |
| `Packages/StrandImport/` | WHOOP export and retained Apple Health parsers |
| `Packages/StrandDesign/` | Shared SwiftUI styling, components, and charts |
| `StrandTests/` | Hosted macOS app tests |
| `Tools/` | Protocol probes/decoders, performance probe, and scoring replay/research tools |
| `project.yml` | XcodeGen project definition; the generated Xcode project is ignored |
| `docs/` | Current guides, measurement research, and protocol evidence |

Start with [contributing](docs/CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and the [documentation index](docs/README.md).

NOOP is independent of WHOOP and is not a medical device. See [DISCLAIMER.md](DISCLAIMER.md) and [ATTRIBUTION.md](ATTRIBUTION.md) for limitations and upstream credits.
