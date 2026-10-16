<p align="center">
  <img src="docs/assets/banner.svg" alt="NOOP — an offline WHOOP companion" width="860">
</p>

<h1 align="center">NOOP</h1>

<p align="center"><b>Your strap. Your data. Your machine. No cloud, no subscription.</b></p>

<p align="center">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20iOS-18C98B?style=flat-square">
  <img alt="Offline by design" src="https://img.shields.io/badge/offline-by%20design-18C98B?style=flat-square">
  <img alt="No subscription" src="https://img.shields.io/badge/subscription-none-2FE6A8?style=flat-square">
  <img alt="WHOOP 4 and 5" src="https://img.shields.io/badge/WHOOP-4.0%20%26%205.0-8B9690?style=flat-square">
</p>

<p align="center">
  <a href="#download">⬇&nbsp;Download</a> ·
  <a href="#features">Features</a> ·
  <a href="docs/PROTOCOL.md">Protocol</a> ·
  <a href="https://github.com/alfonsomartin03/noop/issues">Issues</a>
</p>

---

## Download

Pre-built apps you can run right now:

| Platform | Build | Notes |
|---|---|---|
| **macOS** | `NOOP.app` (see [Releases](../../releases)) | Apple Silicon + Intel. Drag to Applications. |
| **iOS** | — | The shared library is iOS-ready; the app is on the roadmap. |

Prefer to build it yourself? See [`docs/BUILD.md`](docs/BUILD.md).

Everything runs **offline**. The only feature that ever uses the network is the optional **AI Coach**, and only with your own API key.

---

NOOP is a standalone, fully **offline** companion app for WHOOP straps (4.0 and
5.0). It pairs directly with the strap over Bluetooth, stores everything on your
own device in SQLite, imports your existing WHOOP and Apple Health history, and
computes recovery, strain, HRV, and sleep **locally** — with no WHOOP account, no
WHOOP cloud, and no subscription.

It is built on prior open-source reverse-engineering work and exists for one
reason: to let someone who owns a WHOOP strap read **their own biometric data**
from **their own device**, on a machine **they** control.

> **Not affiliated with WHOOP.** NOOP is an independent, unofficial
> interoperability project. It is not affiliated with, endorsed by, or connected
> to WHOOP, Inc. "WHOOP" is used only to identify the hardware NOOP talks to.
> **NOOP is not a medical device** — every derived metric is an approximation, not
> clinical data. See [`DISCLAIMER.md`](DISCLAIMER.md).

This is a standalone repository maintained by Alfonso Martin. It began as a fork
of [`muftiarfan/noop`](https://github.com/muftiarfan/noop), and preserves the
inherited Git history, including earlier project commits recorded under the
[`NoopApp`](https://github.com/NoopApp) author identity. The repository is now
separate from GitHub's fork network. See [`ATTRIBUTION.md`](ATTRIBUTION.md) for
project history and protocol research credits.

---

## Contents

- [Why NOOP](#why-noop)
- [Features](#features)
- [Platform status](#platform-status)
- [Architecture](#architecture)
- [Quickstart (macOS)](#quickstart-macos)
- [How your data flows](#how-your-data-flows)
- [Privacy](#privacy)
- [Attribution](#attribution)
- [Contact](#contact)
- [Disclaimer](#disclaimer)
- [Docs](#docs)

---

## Why NOOP

You bought the strap. The biometric stream it produces is yours. NOOP is built on
that premise:

- **Own your data.** NOOP reads heart rate, R-R intervals, SpO₂, skin temperature,
  respiration, accelerometer/gravity, battery, and event data straight off the
  strap over Bluetooth and writes it to a local SQLite database. Nothing is
  uploaded anywhere.
- **No subscription, no account.** NOOP never logs into a WHOOP account, never
  hits a WHOOP server, and never asks for a paywall. It does not bypass any login,
  paywall, or DRM — it simply talks to a device you own.
- **Bring your history.** Already have years of data in the official app or in
  Apple Health? Import the WHOOP CSV export and/or your Apple Health `export.xml`
  once, and it's permanently on your machine.
- **Transparent math.** Recovery, strain, HRV, and sleep are recomputed on-device
  from documented, citable methods (Task Force 1996 HRV, Karvonen %HRR, Edwards /
  Banister TRIMP, Tanaka HRmax, and so on). The algorithms are approximations of —
  not reproductions of — any proprietary model, and every analyzer file documents
  exactly what it does.

---

## Features

The macOS reference app organizes everything behind a single sidebar
(`Strand/App/RootView.swift`). Each item below is a real screen in
`Strand/Screens/`.

| Screen | What it does |
|---|---|
| **Today** (Control Center) | Home dashboard: recovery ring, a "today's synthesis" insight, a grid of stat tiles (recovery, strain, sleep, HRV, RHR, SpO₂, respiratory, steps, weight, calories) each with a 14-day sparkline, recent workouts, and a data-sources footer. |
| **Live** | Real-time view of the connected strap — heart rate and frame stream as they arrive (~1 Hz). |
| **Breathe** | **HRV haptic breathing biofeedback.** The strap both *measures* HRV (R-R intervals) and *buzzes* its haptic motor, so NOOP paces your breath with felt cues (one buzz inhale, two exhale) and shows live HR + rolling RMSSD responding as the session deepens. Presets: Relax 4-6, Coherence 5.5, Box 4-4. |
| **Intervals** | **Silent haptic HIIT timer.** The strap buzzes every transition (triple-buzz into WORK, single into REST, 3-2-1 tick at phase ends, long buzz on finish) so you train hands-free. Falls back to a glanceable visual timer with no strap. |
| **Explore** (Metric Explorer) | Interrogate any single metric over time, built from the metric catalog (`Strand/Data/MetricCatalog.swift`). |
| **Compare** | Plot two metrics together / against each other over a shared timeline. |
| **Insights** | Behavioral and correlational insights derived from your own series. |
| **Sleep** | Sleep sessions with a hypnogram, stage breakdown, efficiency, resting HR, and HRV — computed by the on-device sleep stager. |
| **Trends** | Long-range trends across recovery, strain, sleep, and biometrics. |
| **Workouts** | Detected exercise sessions with strain and heart-rate detail. |
| **Health** | Biometric overview (HR, HRV, SpO₂, skin temperature, respiratory rate, etc.). |
| **Stress** | Day-level stress / autonomic load visualization. |
| **Apple Health** | Browse and reconcile data imported from your Apple Health export. |
| **Data Sources** | One-tap import of a WHOOP CSV export or an Apple Health export, plus live-strap status. "Bring your history in once, then it's yours." |
| **Notifications** | Configure local notifications and thresholds (`Strand/Data/NotificationSettingsStore.swift`). |
| **Automations** | Turn the strap's physical inputs and live biometrics into Mac actions — all on-device (see below). |
| **Settings** | Profile, preferences, and app configuration. |

There is also a **menu-bar extra** (`Strand/MenuBar/MenuBarContent.swift`) with a
glanceable live HR readout and a compact popover, and a first-run **onboarding
wizard** (`Strand/Onboarding/OnboardingWizard.swift`).

### Automations (on-device)

`Strand/Screens/AutomationsView.swift` + `Strand/System/MacActions.swift`:

- **Double-tap → Mac action.** Double-tap the strap to lock the Mac, buzz back to
  confirm, mark a moment, do nothing, or run any macOS **Shortcut** by name (via
  the `shortcuts://` URL scheme, so it's sandbox-friendly).
- **Wear & presence.** Lock the Mac (or run a Shortcut) the moment the strap
  leaves your wrist; run a Shortcut when it goes back on. *(macOS reserves true
  auto-**unlock** for Apple Watch — NOOP can lock, not unlock.)*
- **Haptic coaching.** HR-zone coaching and an experimental resting-stress nudge —
  the strap buzzes so you don't have to watch a screen.
- **Smart alarm.** Arms the strap's own **firmware** alarm to buzz at your wake
  time (still fires if the Mac is asleep or NOOP is closed), with an optional
  light-sleep wake window when the Mac stays awake and connected.

---

## Platform status

NOOP's logic lives in cross-platform Swift packages, and the same protocol,
storage, analytics, and scoring is shared. The app pairs
with the strap and **score recovery, strain and sleep on your own device** — no
import required.

| Platform | Status |
|---|---|
| **macOS** | ✅ Full app (`Strand/`, SwiftUI, macOS 13+). Pairs over BLE, offloads the strap's history, and scores recovery / strain / sleep on-device. The complete feature set above runs here. |
| **iOS** | 🟡 Libraries ready. Every package declares `.iOS(.v16)` and UI-framework code is guarded with `#if canImport(UIKit)` / `AppKit`; an iOS app target is planned. |

### What to expect when you start

NOOP computes your scores on your own device, so like any recovery wearable it
needs a little data before everything fills in:

- **Live heart rate** shows the moment the strap connects.
- **Strain and sleep** appear after you've worn it and synced — the strap's last
  ~14 days offload automatically over the first few minutes.
- **Recovery** needs a few nights for the app to learn your personal baseline,
  then sharpens each night. WHOOP makes you wait for the same reason.
- **In a hurry?** Import your WHOOP export in Data Sources and your full history
  fills in about a minute.

---

## Architecture

The repository is split into platform-pure Swift packages plus a macOS app target.
All packages declare both `.iOS(.v16)` and `.macOS(.v13)`; framework-specific UI is
guarded with `#if canImport(UIKit)` / `#if canImport(AppKit)`.

```
Strand/                  macOS SwiftUI reference app (this is what you build)
Packages/
  WhoopProtocol/         BLE frame parsing, CRC, command/event/packet decode
  WhoopStore/            GRDB/SQLite persistence (migrations, streams, caches)
  StrandAnalytics/       HRV / recovery / strain / sleep / correlation math
  StrandImport/          WHOOP CSV + Apple Health importers
  StrandDesign/          SwiftUI design system (palette, components, charts)
Tools/reverse_engineer/  Script used to fit the score formulas to a WHOOP export
Fixtures/                sample WHOOP export for tests
```

### `WhoopProtocol` — the reverse-engineering core

Platform-pure (no CoreBluetooth import) so it runs in tests and CLI tools
unchanged. It decodes the on-wire frame format for both strap generations:

```swift
public enum DeviceFamily: String, Sendable, CaseIterable {
    case whoop4   // CRC8 (poly 0x07) header check; service 61080001-…
    case whoop5   // CRC16-Modbus header check, "puffin" packet types; service fd4b0001-…
}
```

Decoding is schema-driven (`Resources/whoop_protocol.json`) and includes CRC8,
CRC16-Modbus, and zlib CRC-32 implementations, frame framing, value
interpretation, and historical-stream reassembly. The app layer (`Strand/BLE/`,
`Strand/Collect/`) wraps these UUID *strings* in `CBUUID` and handles bonding,
offload, and live notifications.

### `WhoopStore` — local SQLite via GRDB

Everything is stored on-device in SQLite (using
[GRDB.swift](https://github.com/groue/GRDB.swift)). The schema is a versioned
migrator (`Database.swift`, currently through `v9`). Examples of decoded-stream
tables created in `v1`–`v3`:

```sql
CREATE TABLE hrSample      (deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId, ts));
CREATE TABLE rrInterval    (deviceId TEXT, ts INTEGER, rrMs INTEGER, PRIMARY KEY(deviceId, ts, rrMs));
CREATE TABLE spo2Sample    (deviceId TEXT, ts INTEGER, red INTEGER, ir INTEGER, PRIMARY KEY(deviceId, ts));
CREATE TABLE skinTempSample(deviceId TEXT, ts INTEGER, raw INTEGER, PRIMARY KEY(deviceId, ts));
CREATE TABLE respSample    (deviceId TEXT, ts INTEGER, raw INTEGER, PRIMARY KEY(deviceId, ts));
```

Later migrations add server-derived metric caches (`sleepSession`, `dailyMetric`),
cursors, a raw frame outbox, and more.

### `StrandAnalytics` — transparent, on-device math

Pure, database-free analyzers. Each is documented and grounded in published
methods (and is explicitly an approximation, not a reproduction of any proprietary
model):

| File | Computes |
|---|---|
| `HRVAnalyzer.swift` | RMSSD + SDNN from R-R intervals (Task Force 1996), with range + Malik ectopic filtering. |
| `RecoveryScorer.swift` | A 0–100 recovery score: HRV-dominant z-score + logistic composite vs personal baselines. |
| `StrainScorer.swift` | A 0–21 logarithmic strain scale from %HRR (Karvonen) and Edwards / Banister TRIMP. |
| `SleepStager.swift` | Sleep/wake detection + approximate 4-class staging from cardiorespiratory + gravity features. |
| `CorrelationEngine.swift` | Pearson r, OLS regression, day-aligned and lagged correlations between two series. |
| `WorkoutDetector.swift`, `Baselines.swift`, `BehaviorInsights.swift`, `AnalyticsEngine.swift` | Workout detection, rolling baselines, behavioral insights, and the per-day orchestrator. |

### `StrandImport` — bring your own history

- **WHOOP CSV export** (`WhoopExportImporter.swift`): header-name-driven, tolerant
  parser for `physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`, and
  `journal_entries.csv`, from a folder or `.zip`. The same schema covers WHOOP 4 /
  5 / MG.
- **Apple Health export** (`AppleHealthImporter.swift`): a **streaming** SAX parser
  (`XMLParser`) for `export.xml` (which can exceed 1 GB), with correlation-dedupe,
  unit normalization (e.g. SpO₂ fraction → %), and sleep-stage mapping.

### `StrandDesign` — the SwiftUI design system

Palette, typography, motion, and reusable components/charts (`RecoveryRing`,
`StrainGauge`, `Hypnogram`, `Sparkline`, `TrendChart`, `YearHeatStrip`,
`StrandCard`, `StatePill`, …) — no external UI dependencies.

---

## Quickstart (macOS)

**Requirements:** macOS 13+, Xcode 15+ (Swift 5.9), and a Mac with Bluetooth. To
pair live, you need your own WHOOP strap; to just explore, you can import a CSV /
Apple Health export instead.

The Xcode project is generated from [`project.yml`](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# 1. Clone
git clone <your-repository-url> NOOP
cd NOOP

# 2. (Re)generate the Xcode project from project.yml
brew install xcodegen   # if you don't have it
xcodegen generate

# 3. Open and run
open Strand.xcodeproj
# Select the "Strand" scheme → Run (⌘R). The built app is named NOOP.
```

Notes:

- Bundle id `com.noopapp.noop`, product name **NOOP**, sandboxed with the
  Bluetooth and user-selected-files entitlements.
- Swift Package Manager resolves the only third-party dependencies automatically:
  **GRDB.swift** (SQLite) and **ZIPFoundation** (export unzip).
- Run the tests from Xcode (the `StrandTests` target + each package's test target),
  or per-package with `swift test` inside `Packages/<Name>/`.

To explore without an Xcode project, the packages build on their own:

```bash
cd Packages/WhoopProtocol && swift build && swift test
```

---

## How your data flows

```
WHOOP strap ──BLE──▶ Strand/BLE + Strand/Collect ──▶ WhoopProtocol (decode)
                                                          │
WHOOP CSV  ─┐                                             ▼
Apple Health├─▶ StrandImport (parse) ───────────▶ WhoopStore (local SQLite)
 export.xml ─┘                                            │
                                                          ▼
                                            StrandAnalytics (recovery/strain/
                                            HRV/sleep, on-device)
                                                          │
                                                          ▼
                                          Strand (SwiftUI) + StrandDesign
```

Every arrow stays on your machine.

---

## Privacy

**Offline by design.** NOOP has no server, no telemetry, and no account. Your
strap data, imports, and computed metrics live in a local SQLite database on your
device and never leave it.

---

## Attribution

This standalone repository began as a fork of [`muftiarfan/noop`](https://github.com/muftiarfan/noop)
and preserves its inherited work and commit history. Earlier project commits in
that history record the [`NoopApp`](https://github.com/NoopApp) author identity.
Alfonso Martin maintains this repository. The code also builds on
open-source reverse-engineering and interoperability work. With thanks:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE protocol; the `WhoopProtocol`
  and `WhoopStore` packages and the collection logic are adapted from this work.
- **`b-nnett/goose`** — the WHOOP 5.0 / MG BLE reverse-engineering (the `fd4b0001-…`
  service family, CRC16-Modbus header, and "puffin" packet types) that NOOP's
  WHOOP 5.0 path is ported from.
- **`groue/GRDB.swift`** — SQLite persistence.
- **`weichsel/ZIPFoundation`** — export unzipping.

Full project and third-party credits are in [`ATTRIBUTION.md`](ATTRIBUTION.md).
The source parent did not include a project license file. This repository does not
add or claim a project-wide license; see upstream and dependency sources for their
own terms. See [`DISCLAIMER.md`](DISCLAIMER.md) for the product notice.

---

## Contact

Questions, feedback, and bug reports → [GitHub Issues](https://github.com/alfonsomartin03/noop/issues).

---

## Disclaimer

NOOP is an independent, unofficial interoperability project. It is
**not affiliated with, endorsed by, or connected to WHOOP, Inc.** All references to
"WHOOP" are nominative — used only to identify the third-party hardware NOOP
interoperates with.

**NOOP is not a medical device.** Heart rate, HRV, recovery, strain, sleep stages,
SpO₂, respiratory rate, and skin temperature are **approximations** computed from
published methods. They are not clinically validated and are not medical advice. Do
not use them to diagnose, treat, or make health decisions — consult a qualified
professional.

Provided **as-is**, with **no warranty**. This repository does not add a project-wide
license. You use it at your own risk. Read the full notice in
[`DISCLAIMER.md`](DISCLAIMER.md).

---

## Docs

- [`DISCLAIMER.md`](DISCLAIMER.md) — product, trademark, and health notice.
- [`ATTRIBUTION.md`](ATTRIBUTION.md) — project history and third-party credits.
- [`project.yml`](project.yml) — XcodeGen project definition (source of `Strand.xcodeproj`).
