# NOOP — agent instructions and current-state reference

## 00 · Read first / maintenance contract

This is the single LLM-maintained quick reference for this repository. Read sections 00–04 at the start of a task, then only the relevant component and file entries. All paths are repository-relative. The detailed inventory is intentionally later in the file; use `rg -n '^##|^###' AGENTS.md` to locate a section without rereading the full inventory. Source code and current tests take precedence over this snapshot; historical reports and source comments can be stale.

**Required on every program modification:** update this file in the same task before handing work back. This includes code, dependencies, resources, schema, configuration, tools, and behavior changes.

1. Check `git status --short` and preserve other work. Read the affected source and tests.
2. Update the affected component summary, invariants, configuration, test mapping, and file inventory. Add/move/remove entries when files change; keep entries concise.
3. Refresh the date, baseline commit when appropriate, and working-tree notes. Distinguish implemented, tested, hardware-confirmed, and unknown; never infer passing tests from existing test files.
4. Record actual verification and remaining limitations in section 08; do not leave previous results presented as verification of changed code.
5. Add a compact dated entry to section 09 (what changed, affected paths, checks, remaining work). Keep the latest 10 entries; consolidate older context into current-state sections. This is a living snapshot, not an append-only transcript.
6. Check inventory paths and documentation links. Do not duplicate source bodies, full test logs, captured health data, credentials, or personal signing values here.

A task is not complete until the reference reflects its changes. These are instructions for future agents, **not a filesystem watcher or CI enforcement**; edits made by tools or people that do not follow these instructions can still make the snapshot stale. Reconcile it with the working tree before relying on it. Do not introduce a second state-summary file.

## 01 · Snapshot and confidence

- Refreshed: **2026-11-02**, user timezone America/New_York.
- Product: **NOOP**, local macOS companion for WHOOP 4.0/5.0 straps. Internal target/scheme/package prefix remains **Strand**.
- Branch at inspection: `main`. Baseline HEAD: `169bfde6cbc88da7c380d1882b69b18bf8de7e59`.
- Scope: current working tree, including uncommitted files; not a release declaration. Existing local changes were preserved.
- Audit: first-party file inventory, text/symbol/resource inspection, key runtime-path and existing-document comparison. Not an exhaustive correctness/security review or a fresh hardware experiment.
- Repository-owned source, docs, tests, fixtures, assets and configuration are indexed below. Generated dependency/build trees and Git internals are classified separately, not treated as application source. Private ignored notes are indexed by role only.
- No app execution, build, package test, database migration, live-store inspection, Bluetooth command, or deployment was performed for this documentation task.

## 02 · Fast architecture / routing

```text
StrandApp / AppEntry -> AppModel
  WHOOP strap <-> BLEManager + Commands
    -> generation-specific reassembly / WhoopProtocol
    -> FrameRouter -> LiveState -> LiveHeartRate / BatteryPresentation -> UI
    -> Collector / historical ingestion + Backfiller -> WhoopStore (GRDB/SQLite)
  WHOOP ZIP/folder -> StrandImport -> WhoopImporter -> WhoopStore
  IntelligenceEngine -> IncrementalScorer -> AnalyticsEngine -> derived rows + provenance
  Repository -> Overview / Trends / Settings / menu bar
  AlarmController -> AlarmPlanner + SmartWakeDecider -> BLE alarm + Mac notification
  DataBackup <-> user-selected database export/restore
```

| Change concern | Start here | Related checks |
| --- | --- | --- |
| App lifecycle, ownership, scheduling | `Strand/App/AppModel.swift`, `StrandApp.swift` | hosted `StrandTests` |
| Navigation and screen exposure | `Strand/App/RootView.swift`, `Strand/Screens/Hubs.swift` | build + inspect affected UI |
| Connection, pairing, sync, wire commands | `Strand/BLE/BLEManager.swift`, `Commands.swift` | protocol tests, smoke tests, evidence docs |
| Frame decoding / checksums | `Packages/WhoopProtocol/Sources/WhoopProtocol/` | Swift protocol fixtures + Python decoder tests |
| Durable collection / safe acknowledgement | `Strand/Collect/`, historical path in `BLEManager.swift` | raw archive, collector and protocol tests |
| Database schema / queries | `Packages/WhoopStore/Sources/WhoopStore/` | migrations, idempotence, derived-write tests |
| Scores, sleep, load, provenance | `Packages/StrandAnalytics/Sources/StrandAnalytics/` | relevant analytics tests and replay regression |
| Imports / backup / UI data merging | `Strand/Data/`, `Packages/StrandImport/` | import/store tests; copied data only |
| Battery and live HR presentation | `Strand/Device/`, `Strand/BLE/LiveHeartRate.swift` | `LivePresentationTests`, `CollectorBatteryTests`, snapshots |
| Alarm planning / execution | `Strand/Alarm/AlarmController.swift`, analytics `AlarmEngine.swift` | `AlarmEngineTests`; hardware evidence is firmware-specific |
| Shared UI primitives | `Packages/StrandDesign/Sources/StrandDesign/` | design tests / optional image snapshots |

### Package dependency graph

- `WhoopProtocol`: no external package dependencies; protocol JSON resource and test fixtures.
- `WhoopStore` -> `WhoopProtocol`, GRDB.swift (manifest >=6.0.0, checked-in resolution **6.29.3**).
- `StrandAnalytics` -> `WhoopProtocol`, `WhoopStore`.
- `StrandImport` -> `WhoopProtocol`, `WhoopStore`, ZIPFoundation (manifest >=0.9.0, checked-in resolution **0.9.20**).
- `StrandDesign`: SwiftUI components; no external package dependencies.
- All five declare Swift tools 5.9, macOS 13 / iOS 16 library platforms. **Only macOS has an app target.** Package platform declarations do not establish a mobile app.
- Swift tools: `ble_probe` -> protocol; `perf_probe` / `strain_replay` -> analytics + store + protocol. Python decoder/tests use standard library.

## 03 · Current component behavior

### App, presentation and navigation

- `AppEntry` checks `NOOP_TEST_HOST` before normal startup; tests get a bare host without BLE or live-store startup. `StrandApp` shares one `AppModel` between window and menu-bar scene.
- Single strap identity: `my-whoop`. `AppModel` owns BLE/live state, `Repository`, profile, scoring, imports, battery notifications and alarms.
- New stored chunks throttle raw-data view invalidation to ~2 s, debounce scoring until ~8 s quiet, and also trigger post-download processing. Launch refreshes cached data, delays ~6 s, applies version rescoring, then analyzes periodically (~15 min). Scoring is dispatched to a detached utility task, not performed in views.
- Three destinations: **Overview** (`TodayView`), **Trends** (`TrendsHub`), **Settings** (`SettingsHub`), shortcuts Cmd-1/2/3. First-launch onboarding overlays the shell.
- Overview: selectable week/day, recovery/sleep/strain detail in place, live-HR sheet, sync/download/processing status.
- Trends: Scores, Sleep, Vitals, Activity; sleep correction and workout detail surfaces. Workout labels, effort and strength sets are user records.
- Settings: General (strap, profile, battery, alarms), Data (WHOOP import, comparison, backups), Advanced (diagnostics, metric explorer, live strap).
- Live strap sheet enables custom realtime streaming while visible; menu-bar actions and alarm wake windows can also control streaming. Do not assume sheet visibility is the only stream owner.
- `LiveHeartRate` is a narrow observable: median over ~10 s / at most 40 readings, plausible range 30–220 bpm; reported HR preferred, latest RR fallback; uses shared HRZones. Publishes only changed display values.
- `BatteryPresentation` centralizes percent, freshness, charging, text, icon and accessibility. Low <20%, intermediate <35%, stale on disconnect or >10 min. Charging requires a verified source; rising percent is insufficient.
- `StrapBatteryPanel` / `ChargingIllustration` render charging states: idle grey pack beside strap; charging = pack docked with bolt, blue→green current/outline/level fill; full = all green with check. Motion: spring dock + connect ring on idle→charging, then 5 flow cycles (particles into the fill's leading edge, fill shimmer, pulsing outline), then one reminder cycle every 30 s and on hover; otherwise still. Reduce Motion, inactive app or dimmed state draws no flow. Actual WHOOP 5.0 charging telemetry remains unverified; synthetic fixture states exercise presentation only.
- No Apple Health import UI, mobile app, cloud/account service, coaching/automation destination, or standalone stress/insights/compare screen. Retained library code is not proof of an exposed feature.

### BLE and collection

- `BLEManager`: scan -> connect -> discover -> bond -> subscribe -> per-characteristic reassembly -> decode/routing/store/sync. WHOOP generations differ in GATT and header framing; `DeviceFamily` selects them.
- Bluetooth access is remembered in `noop.bluetoothChoice` (`BluetoothChoice`): the system's Allow/Don't Allow answer is recorded on each central state update, and Settings ▸ Strap has a Use Bluetooth toggle. While declined, no `CBCentralManager` is created at launch (no scan, no repeated system prompt) unless macOS now reports allowedAlways. macOS keeps its own answer per signature; ad-hoc rebuilds still re-prompt when the choice is allowed/undecided — only stable signing (`Local.xcconfig`) fixes that.
- Reconnect: besides the 3 s rescan after an unintended disconnect, a 15-min watchdog (`reconnectTimer`, life of the central) cancels a stalled pending connect and rescans while the app is open and the link is lost; skipped after a user Disconnect. `LiveState.nextReconnectAt` drives the Settings caption. Not hardware-tested.
- `Commands` is a restricted app command set. Protocol research does not grant permission to add destructive/firmware operations to normal flows.
- `FrameRouter` mutates `LiveState`; standard HR characteristic parsing is separate. Standard broadcast listening is opt-in (`listenToHRBroadcast`), default off.
- `Collector` buffers frames; default flush 64 frames / 30 s, pre-clock cap 4096. Decode/persist precedes optional raw outbox write. Raw capture defaults off; bounded capture window is at most five minutes.
- `Backfiller` persists decoded history, optional raw, and cursor before chunk acknowledgement. Keep-data-on-strap mode suppresses acknowledgements/cursor advancement. Repeated ENDs belong to one offload sequence; never close ingestion after the first END.
- WHOOP 5 historical ingestion in `BLEManager` includes durable archival for undecodable history. `RawHistoryArchive` writes UTC-day JSONL to `OpenWhoop/undecoded-history`, synchronizes before returning and is never auto-pruned. Archive failure must prevent unsafe acknowledgement.
- Clock mapping is explicit (`DeviceClock`, `ClockCorrelation`, `ClockPolicy`). Historical type-47 records carry Unix time; realtime data can require device/host correlation. Do not apply one timestamp rule indiscriminately.
- `BackfillPolicy` rate-limits sync triggers; `StuckStrapDetector` compares strap data availability with persisted HR frontier, not merely trim cursor movement.
- Device evidence is scoped to hardware/firmware. Read `docs/reverse-engineering/SAFETY_MATRIX.md`, `COMMAND_REGISTRY.md`, and relevant capture evidence before hardware work.

### Storage, imports and scoring

- `StorePaths` resolves Application Support `OpenWhoop/whoop.sqlite`; sandboxed app uses its container. Never hard-code a user's home path. WAL/SHM can accompany SQLite; raw archive and UserDefaults are separate.
- `WhoopStore` is an actor-backed GRDB access layer. `Repository` and BLE use separate handles; WAL/busy handling supports this arrangement.
- Current schema **v15**; migration definitions are authoritative in `Database.swift`. Add migrations; do not rewrite applied migrations.
- Tables: `device`, `hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`, `rawBatch`, `cursors`, `dailyMetric`, `sleepSession`, `journal`, `workout`, `appleDaily`, `metricSeries`, `metricProvenance`, `loadRecord`, `sessionEffort`, `strengthSet`, `workoutLabel`, `dayScoreState`, `sleepCorrection`.
- v10 preserves within-second RR sequence; v11 provenance; v12 load; v13 training logs; v14 workout labels/incremental state; v15 classified sleep-session fields/corrections.
- Raw/import identity and `<device>-noop` computed identity stay distinct. `Repository` merges display data with imported-field precedence; imported values must not enter NOOP-only causal baselines.
- `WhoopImporter` maps parsed WHOOP cycles, sleeps, workouts, journal and metric series into idempotent upserts. `StrandImport` retains Apple Health XML parsing/aggregation as a library capability.
- `DataBackup` exports database contents and restores by replacement, requiring relaunch. It is not a merge or a full preference/raw-archive backup.
- `IntelligenceEngine.scoringVersion = 5`; `IncrementalScorer` reuses unchanged days, tracks algorithm/config/source changes and scores in causal order. Upgrades archive older derived rows and replace each day's results/state atomically; explicit rescoring has its own invalidation path.
- `HRQuality` and `SupportedHR` gate supported elapsed time. `HRCalibration` supplies shared HR references; `CardioLoad` computes load; `StrainScorer` maps load to a versioned 0–21 display index. Confident sleep/naps are excluded in v5.
- Sleep flow: minute/epoch evidence -> detected episodes -> grouped/classified sessions -> user corrections -> sleep accounting/vitals/recovery. Preserve primary/interrupted-primary/nap/uncertain distinctions and user corrections on rescoring.
- HRV uses cleaned RR with sequence retained. Causal baselines only use compatible persisted metric identities from prior days. `RecoveryAssessment` separates dimensions; legacy composite remains an estimate.
- Missing/unknown/unstaged is not zero, awake, or confirmed sleep. Imported stage totals cannot establish an actual hypnogram. Cardiovascular load, calories, activity labels, strength volume and perceived effort are different quantities.
- Evaluation harnesses (`StagingEvaluation`, `DetectionEvaluation`) do not establish clinical accuracy; repository fixtures/tests are not an independent reference cohort.

### Alarms

- `AlarmEngine` provides pure planning, timezone/DST/weekday logic, exact/smart-wake/sleep-goal decisions and state types; `AlarmController` owns timer, persistence, notifications and BLE actions.
- Current source confirms immediate vibration, readback and autonomous on-device deadline alarm **only for firmware 50.43.1.0**; `onDeviceAlarmVerified = true`, with H04 evidence documented on 2026-11-02. These are pre-existing recorded experiments, not re-tested in this task.
- Next absolute deadline is translated to strap time, stored in alarm id 1, and read back before claiming confirmed-on-device. Slot is consumed; recurrence requires NOOP to re-arm. Clearing is gated by NOOP ownership state.
- Smart/goal early decisions require running/connected host, use available HR evidence (not validated live sleep stages), and post a Mac notification. Idle-sleep assertion cannot prevent lid-closed sleep. Do not promise unconditional delivery.

## 04 · Constraints, discrepancies and unfinished verification

- Preserve all unrelated uncommitted work. Initial changes concentrate on shared live/battery presentation, reduced observation/redraw scope, fixture launch support, design cleanup and synthetic XML fixture inclusion.
- `docs/DATA_MODEL.md`, `FEATURES.md`, `ANALYTICS.md` and some sleep notes still describe sleep/alarm/v15 as local/uncommitted work. Relevant implementation files are tracked and unchanged relative to inspected HEAD. Git status and source supersede those historical status labels; deployment remains unknown.
- `AlarmController` leading comment says strap vibration is not yet confirmed, but `verified(firmware:)` and later evidence confirm it. Some earlier capability/proposal rows in `ALARM_CAPABILITIES.md` also predate later H02b/H04/H07 results.
- Potential alarm issue observed by source inspection, **not reproduced or fixed**: `AlarmController.ring` assigns `.triggered` before comparing the same state to `.confirmedOnDevice`, making `strapRingsItself` false in that sequence. Investigate before relying on duplicate-ring prevention.
- Legacy comments mention server/phone/Kotlin or removed screens (`MetricsCache`, `Cursors`, analytics/design umbrella comments, some view comments). They do not describe a currently shipped backend/mobile app.
- `StrainGauge.swift` is deleted in the initial working tree; shared design umbrella comments can still mention it. Do not restore removed UI merely because a comment names it.
- Current hardware coverage is not universal WHOOP compatibility. Charging source on WHOOP 5 remains unknown; alarm confirmation is firmware-specific; unknown history needs archival, not invented decoding.
- No release/build/test-health conclusion is established by this snapshot. Existing local tests and documentation reports must be rerun for the relevant code change.

## 05 · Build, configuration and verification recipe

- Canonical project: `project.yml` (XcodeGen); generated `Strand.xcodeproj` ignored. Regenerate after adding app files or changing configuration; do not hand-maintain the generated project.
- macOS 13+, Swift tools 5.9-compatible Xcode, XcodeGen. App build settings: Swift language 5.0, minimal strict concurrency, version 0.1.0 / build 1, bundle `com.noopapp.noop`, product `NOOP.app`.
- Sandbox entitlements: app sandbox, Bluetooth, user-selected read/write files. Bluetooth permission and compatible hardware required for collection.
- `Signing.xcconfig` includes optional ignored `Local.xcconfig`; template is `Local.xcconfig.example`. Keep personal signing settings out of commits.
- Initial dependency fetch needs network; normal app processing is local. No CI workflow is present in the inspected first-party inventory.

```sh
xcodegen generate
swift test --package-path Packages/WhoopProtocol
swift test --package-path Packages/WhoopStore
swift test --package-path Packages/StrandAnalytics
swift test --package-path Packages/StrandImport
swift test --package-path Packages/StrandDesign
python3 -m unittest discover -s Tools/whoop_re -p 'test_*.py'
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived test
# Optional visual snapshots; otherwise snapshot tests skip:
STRAND_SNAPSHOT_DIR=/tmp/noop-snapshots swift test --package-path Packages/StrandDesign
```

Hosted tests use `NOOP_TEST_HOST=1` from the scheme to suppress production startup. Configure local signing as needed; documented ad-hoc test flags are `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`. Run affected checks, not all hardware probes, for every edit. Documentation-only changes need source/path consistency checks.

| Runtime switch / persisted setting | Meaning / caution |
| --- | --- |
| `NOOP_TEST_HOST` environment | Presence selects isolated test host |
| `NOOP_FIXTURE_STORE` environment | Database **copy** path; disables CoreBluetooth setup; copy can still migrate/rescore |
| `-noop.fixture.tab trends\|settings` | Fixture launch destination |
| `-noop.fixture.battery cycle\|charging` | Fixture-only synthetic battery sequence (8 s/state) / fixed charging |
| `noop.onboarded` | First-run overlay completion |
| `scoringVersionApplied` | Applied scoring migration marker, current target 5 |
| `enableRawCapture` | Research raw capture, default off |
| `noop.bluetoothChoice` | `undecided`/`allowed`/`declined`; declined keeps Bluetooth off across launches |
| `listenToHRBroadcast` | Standard HR subscription opt-in |
| `noop.keepDataOnStrap` | Persist history without trim acknowledgement (`BLEManager.keepDataOnStrapKey`) |
| `alarm.specs`, `alarm.capabilities`, `alarm.fired`, `alarm.ownsStrapAlarm` | Alarm definitions / cached capabilities / dedupe / ownership in UserDefaults |
| Profile, battery alerts, timezone timeline, hub selections | UserDefaults; see ProfileStore, BatteryMonitor, ZoneTimeline and Hubs |

Performance/replay tools must use a database copy: opening `WhoopStore` can migrate it even if a tool describes its own work as read-only. Use SQLite backup or the app's export; do not copy an active main file while ignoring WAL. Fixture mode emits launch/repository timing logs; unsigned preference storage differs from sandboxed preferences.

## 06 · Folder boundaries and ignored/generated material

| Path | Ownership / treatment |
| --- | --- |
| `Strand/` | App integration, screens, BLE, collection, resources; indexed below |
| `Packages/` | Five local packages, each with manifest, Sources and Tests; resolved files where present |
| `StrandTests/` | Hosted app isolation, smoke, collector/battery, raw archive and live presentation checks |
| `Tools/` | BLE investigation, offline Python decoding/export analysis, performance and scoring replay |
| `docs/` | Guides, dated research, evidence registry and redacted captures; current source wins on conflict |
| `docs/assets/` | README/document SVG logo/banner |
| `Strand/Resources/Assets.xcassets/` | Asset catalog and app-icon PNG variants; resource metadata, not code |
| `.git/` | Version-control metadata; no program logic; do not edit manually |
| `Strand.xcodeproj/` | Generated local project, workspace/scheme settings; regenerate from project.yml |
| `Packages/*/.build/`, `Tools/*/.build/` | Local compiler output, dependency checkouts, caches; multi-GB generated material, not a source inventory |
| `.swiftpm/`, build/DerivedData/app bundles if present | Generated/ignored local state; not authoritative source |
| `.local/ai-prompts/` | Three ignored historical project-audit, sleep/recovery, workout/strain prompt notes; not current requirements or public documentation |
| `.DS_Store`, `__pycache__/` if present | OS/interpreter artifacts; irrelevant to behavior |
| Private exports, SQLite files, `Local.xcconfig`, secrets | Ignored by policy; do not embed personal contents in this reference |

## 07 · Complete first-party file index

Each entry names an existing file at inspection. Paths are grouped by directory; combine a directory heading with a filename to locate it. Symbols are navigation hints, not a guarantee of public API or live UI reachability. Test names describe coverage intent, not a passing result. JSON/CSV/XML/JSONL and image files are fixtures/resources/evidence, not executable components. Deleted tracked files appear only in the initial Git snapshot.

### `.`

- `.gitignore` — Generated output, personal data/signing, local notes exclusions; synthetic export.xml exception.
- `ATTRIBUTION.md` — Project history and attribution; Project history; Protocol research and software
- `DISCLAIMER.md` — Disclaimer and trademark notice; Independent project; Project contents
- `Local.xcconfig.example` — Template for ignored personal signing configuration.
- `README.md` — NOOP; What is in the app; Build and run
- `Signing.xcconfig` — Shared signing configuration; optional private Local.xcconfig include.
- `project.yml` — Canonical XcodeGen app/test targets, packages, build settings and isolated test scheme.

### `Packages/StrandAnalytics`

- `Package.resolved` — Locked dependencies: grdb.swift 6.29.3
- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Packages/StrandAnalytics/Sources/StrandAnalytics`

- `AlarmEngine.swift` — Symbols: AlarmSpec, Mode, AlarmCapabilities, Status, AlarmState, AlarmOccurrence, AlarmPlanner (additional helpers in source)
- `AnalyticsEngine.swift` — Symbols: AnalyticsEngine, ProfileBaselines, DayResult, FollowingData
- `Baselines.swift` — Symbols: MetricCfg, BaselineStatus, BaselineState, Deviation, Baselines
- `BehaviorInsights.swift` — Symbols: BehaviorEffect, BehaviorInsights
- `CardioLoad.swift` — Symbols: LoadMethod, Descriptor, BanisterCoefficients, LoadSummary, CardioLoad, WorkoutReconciliation, DayLoadStatus (additional helpers in source)
- `CausalReference.swift` — Symbols: CalendarDay, ReferenceTransform, ReferenceConfig, ReferenceState, ReferenceSnapshot, ScoreOutcome, ScoredObservation (additional helpers in source)
- `CausalReplay.swift` — Symbols: CausalReplay, Output
- `ComparisonEngine.swift` — Symbols: SeriesStat, PeriodComparison, ComparisonEngine
- `CorrelationEngine.swift` — Symbols: Correlation, CorrelationEngine
- `DetectionEvaluation.swift` — Symbols: DetectionEvaluation, Annotated, Recording, Report
- `EstimateAccuracy.swift` — Symbols: EstimateAccuracy, Result
- `HRCalibration.swift` — Symbols: HRCalibration, MaxSource, RestingSource
- `HRQuality.swift` — Symbols: HRQuality, Report
- `HRVAnalyzer.swift` — Symbols: HRVAnalyzer, HRVResult
- `HRZones.swift` — Symbols: HRZone, HRZoneSet, TimeInZone, HRZones
- `IncrementalScorer.swift` — Symbols: ScoringRequest, RecomputeReason, ScoringOutcome, IncrementalScorer
- `MetricProvenance.swift` — Symbols: MetricDefinition, MetricSource, MeasurementContext, MetricAggregation, MetricIdentity, MetricObservation, ProvenanceKey
- `RecoveryAssessment.swift` — Symbols: VitalsQuality, Completeness, RecoveryAssessment, Legacy, SleepSufficiency, Autonomic, Flag (additional helpers in source)
- `RecoveryScorer.swift` — Symbols: RecoveryScorer, DriverBaseline, Term, Breakdown
- `RespiratoryRate.swift` — Symbols: RespiratoryRate, Result
- `SleepAccounting.swift` — Symbols: TimeSpan, SleepAccounting, EpisodeSummary, SRIResult, CircularClock, Shortfall, WindowShortfall
- `SleepNeed.swift` — Symbols: SleepNeed, Summary
- `SleepSessions.swift` — Symbols: SleepSessionKind, SleepHabit, SleepCorrection, Action, ClassifiedSleepSession, SleepSessionPolicy, SleepSessionClassifier (additional helpers in source)
- `SleepStager.swift` — Symbols: StageSegment, SleepKind, SleepSession, SleepStager, Period, MinuteGrid, Evidence (additional helpers in source)
- `SleepState.swift` — Symbols: SleepState, SleepStateReason
- `SleepVitals.swift` — Symbols: VitalWindow, SleepVitals, SleepVitalsCalculator
- `StagingEvaluation.swift` — Symbols: StagingEvaluation, Night, ClassMetrics, Agreement, Report, Tally, SplitMix64
- `StrainScorer.swift` — Symbols: StrainScorer
- `StrandAnalytics.swift` — Symbols: StrandAnalytics
- `SupportedHR.swift` — Symbols: HRSupport, HRInterval, SupportedHR
- `TrainingLog.swift` — Symbols: SessionRPE, StrengthSet, StrengthVolume, ExerciseSummary
- `WorkoutDetector.swift` — Symbols: UserProfile, ActivityEvidence, ExerciseSession, WorkoutDetector, ActivityPoint, Episode, Calories (additional helpers in source)
- `WorkoutLabels.swift` — Symbols: ActivityType, LabelProvenance, ActivityLabel, WorkoutLabels
- `ZoneTimeline.swift` — Symbols: ZoneEntry, ZoneTimeline

### `Packages/StrandAnalytics/Tests/StrandAnalyticsTests`

- `AlarmEngineTests.swift` — Test suite: AlarmEngineTests; 17 test methods
- `AnalyticsEngineTests.swift` — Test suite: AnalyticsEngineTests; 7 test methods
- `BaselinesTests.swift` — Test suite: BaselinesTests; 11 test methods
- `BehaviorInsightsTests.swift` — Test suite: BehaviorInsightsTests; 11 test methods
- `CardioLoadTests.swift` — Test suite: SupportedHRTests, LoadMethodTests, HRCalibrationTests; 79 test methods
- `ComparisonEngineTests.swift` — Test suite: ComparisonEngineTests; 14 test methods
- `CorrelationEngineTests.swift` — Test suite: CorrelationEngineTests; 11 test methods
- `EstimateAccuracyTests.swift` — Test suite: EstimateAccuracyTests; 3 test methods
- `HRVAnalyzerTests.swift` — Test suite: HRVAnalyzerTests; 9 test methods
- `HRZonesTests.swift` — Test suite: HRZonesTests; 8 test methods
- `IncrementalScorerTests.swift` — Test suite: IncrementalScorerTests, Snapshot, WorkoutLabelTests; 23 test methods
- `MeasurementValidityTests.swift` — Test suite: MeasurementValidityTests; 35 test methods
- `RecoveryScorerTests.swift` — Test suite: RecoveryScorerTests; 8 test methods
- `ReplayRegressionTests.swift` — Test suite: ReplayRegressionTests, Res; 11 test methods
- `RespiratoryRateTests.swift` — Test suite: RespiratoryRateTests, LCG; 6 test methods
- `SleepNeedTests.swift` — Test suite: SleepNeedTests; 4 test methods
- `SleepSessionClassifierTests.swift` — Test suite: SleepSessionClassifierTests; 25 test methods
- `SleepStagerTests.swift` — Test suite: SleepStagerTests; 16 test methods
- `SleepStrainScenarioTests.swift` — Test suite: SleepStrainScenarioTests, Seg, Built; 21 test methods
- `SleepVitalsTests.swift` — Test suite: SleepVitalsTests, HRStreams; 18 test methods
- `StrainScorerTests.swift` — Test suite: StrainScorerTests; 8 test methods
- `WorkoutDetectorTests.swift` — Test suite: WorkoutDetectorTests, WorkoutDetectorHROnlyTests; 18 test methods
- `ZoneTimelineTests.swift` — Test suite: ZoneTimelineTests; 4 test methods

### `Packages/StrandDesign`

- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Packages/StrandDesign/Sources/StrandDesign`

- `ChargingIllustration.swift` — Symbols: ChargingIllustration, Phase, Geometry
- `ChartHover.swift` — Symbols: ChartTooltip, ChartTooltipPlacement, ChartHoverMath, CrosshairRule, HighlightDot, PositionedTooltip
- `Components.swift` — Symbols: NoopMetrics, NoopCard, SectionHeader, StatTile, ChartCard, ChartFooter, InsightCard (additional helpers in source)
- `Hypnogram.swift` — Symbols: SleepInterval, Hypnogram
- `Motion.swift` — Symbols: StrandMotion, MotionDemo
- `Palette.swift` — Symbols: StrandPalette, SleepStage
- `RecoveryRing.swift` — Symbols: RecoveryRing, RecoveryArc, RecoveryRingLive
- `Sparkline.swift` — Symbols: Sparkline
- `StatePill.swift` — Symbols: StrandTone, StatePill, ConnectionDot
- `StrandCard.swift` — Symbols: StrandCard, StrandCardHover
- `StrandDesign.swift` — Symbols: StrandDesign
- `TrendChart.swift` — Symbols: TrendPoint, TrendChart
- `Typography.swift` — Symbols: StrandFont
- `Widgets.swift` — Symbols: WidgetSize, WidgetSpanKey, WidgetGridLayout, WidgetGrid, StrandWidget, WidgetPressStyle, WidgetValue (additional helpers in source)
- `YearHeatStrip.swift` — Symbols: RecoveryDay, YearHeatStrip, Week, DateFormatterCache

### `Packages/StrandDesign/Tests/StrandDesignTests`

- `PlaceholderTests.swift` — Test suite: StrandDesignTests; 25 test methods
- `WidgetSnapshotTests.swift` — Test suite: WidgetSnapshotTests; 2 test methods

### `Packages/StrandImport`

- `Package.resolved` — Locked dependencies: grdb.swift 6.29.3, zipfoundation 0.9.20
- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Packages/StrandImport/Sources/StrandImport`

- `AppleHealthAggregator.swift` — Symbols: AppleDailyAggregate, AppleHealthAggregator, Acc, Night
- `AppleHealthImporter.swift` — Symbols: AppleHealthImporter, HealthXMLDelegate, HealthDateParser
- `CSVParsing.swift` — Symbols: BOM, HeaderNorm, CSVTable, WhoopTime
- `ImportCoordinator.swift` — Symbols: ImportCoordinator, DetectedImport, ZipPeek
- `ImportModels.swift` — Symbols: DataSourceKind, HealthSample, HealthWorkout, SleepStage, SleepStageInterval, WhoopCycleRow, WhoopSleepRow (additional helpers in source)
- `StrandImport.swift` — Symbols: StrandImport
- `WhoopExportImporter.swift` — Symbols: WhoopExportImporter

### `Packages/StrandImport/Tests/StrandImportTests`

- `AppleHealthAggregatorTests.swift` — Test suite: AppleHealthAggregatorTests; 28 test methods
- `AppleHealthImporterTests.swift` — Test suite: AppleHealthImporterTests; 12 test methods
- `Helpers.swift` — Test suite: Fixtures
- `ImportCoordinatorTests.swift` — Test suite: ImportCoordinatorTests; 8 test methods
- `PlaceholderTests.swift` — Test suite: PlaceholderTests; 1 test methods
- `WhoopExportImporterTests.swift` — Test suite: WhoopExportImporterTests; 12 test methods

### `Packages/StrandImport/Tests/StrandImportTests/Resources`

- `export.xml` — Import test fixture; synthetic input, not user export.
- `journal_entries.csv` — Import test fixture; synthetic input, not user export.
- `physiological_cycles.csv` — Import test fixture; synthetic input, not user export.
- `sleeps.csv` — Import test fixture; synthetic input, not user export.
- `workouts.csv` — Import test fixture; synthetic input, not user export.

### `Packages/WhoopProtocol`

- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Packages/WhoopProtocol/Sources/WhoopProtocol`

- `BatteryPolicy.swift` — Symbols: BatteryReading, Source, BatteryAlertState, BatteryAlertPolicy, Alert
- `DeviceClock.swift` — Symbols: ClockSample, ClockEstimate, DeviceClockEstimator, Rejection, Outcome
- `DeviceFamily.swift` — Symbols: DeviceFamily, HeaderCRCKind, PuffinPacketType
- `Framing.swift` — Symbols: FrameCheck, Reassembler
- `HistoricalMeta.swift` — Symbols: HistoricalMeta
- `HistoricalStreams.swift` — Functions: extractHistoricalStreams, wall
- `Interpreter.swift` — Symbols: DecodedField, ParsedFrame, FieldBuilder
- `PostHooks.swift` — Functions: formatMean, registerPostHooks, le32
- `Redaction.swift` — Symbols: Redactor
- `Schema.swift` — Symbols: FieldSpec, AxisSpec, VariantSpec, VersionSpec, PacketSpec, Schema, RawAxis (additional helpers in source)
- `Streams.swift` — Symbols: HRSample, RRInterval, WhoopEvent, BatterySample, SpO2Sample, SkinTempSample, RespSample (additional helpers in source)
- `SyncCoverage.swift` — Symbols: SyncSpan, IntervalSet, SyncSession, Phase
- `Values.swift` — Symbols: ParsedValue
- `Whoop5Messages.swift` — Symbols: Whoop5DecodeError, Whoop5Result, Whoop5CommandResponse, Whoop5Clock, Whoop5DataRange, Whoop5HistoryMeta, Whoop5EventKind (additional helpers in source)
- `WhoopProtocol.swift` — Symbols: WhoopProtocolInfo

### `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources`

- `whoop_protocol.json` — Protocol schema resource.

### `Packages/WhoopProtocol/Tests/WhoopProtocolTests`

- `BiometricStreamsParityTests.swift` — Test suite: BiometricStreamsParityTests, FrameEntry, HRGold; 1 test methods
- `DeviceFamilyFramingTests.swift` — Test suite: DeviceFamilyFramingTests; 14 test methods
- `DeviceLogicTests.swift` — Test suite: DeviceClockTests, RedactionTests, SyncSessionTests; 27 test methods
- `FramingTests.swift` — Test suite: FramingTests; 10 test methods
- `HistoricalMetaTests.swift` — Test suite: HistoricalMetaTests; 9 test methods
- `HistoricalStreamsParityTests.swift` — Test suite: HistoricalStreamsParityTests, FrameEntry, HRGold; 1 test methods
- `HistoricalV24Tests.swift` — Test suite: HistoricalV24Tests; 5 test methods
- `InterpreterEnvelopeTests.swift` — Test suite: InterpreterEnvelopeTests; 4 test methods
- `ParityTests.swift` — Test suite: GoldenEntry, FrameEntry, ParityTests; 2 test methods
- `PostHooksTests.swift` — Test suite: PostHooksTests; 8 test methods
- `ReassemblerTests.swift` — Test suite: ReassemblerTests, ReassemblerWhoop5Tests, Whoop5CommandFramingTests; 15 test methods
- `SchemaTests.swift` — Test suite: SchemaTests; 5 test methods
- `SmokeTests.swift` — Test suite: SmokeTests; 1 test methods
- `StreamsParityTests.swift` — Test suite: StreamsParityTests, FrameEntry, HRGold; 1 test methods
- `StreamsTests.swift` — Test suite: StreamsTests; 5 test methods
- `ValuesTests.swift` — Test suite: ValuesTests; 4 test methods
- `Whoop5MessagesTests.swift` — Test suite: Whoop5MessagesTests; 18 test methods

### `Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources`

- `biometric_streams_golden.json` — Protocol golden data / captured frame fixture.
- `frames.json` — Protocol golden data / captured frame fixture.
- `golden.json` — Protocol golden data / captured frame fixture.
- `historical_frames.json` — Protocol golden data / captured frame fixture.
- `historical_golden.json` — Protocol golden data / captured frame fixture.
- `streams_golden.json` — Protocol golden data / captured frame fixture.
- `whoop5_frames.json` — Protocol golden data / captured frame fixture.

### `Packages/WhoopStore`

- `Package.resolved` — Locked dependencies: grdb.swift 6.29.3
- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Packages/WhoopStore/Sources/WhoopStore`

- `Cursors.swift` — Functions: setCursor, cursor, setHighwater, highwater, setReadHighwater, readHighwater
- `Database.swift` — Package entry point / extensions; inspect source.
- `DerivedStore.swift` — Symbols: ProvenanceRecord, LoadRecordRow, DayScoreRow, DerivedBatch, DerivedWriteScope
- `JournalWorkoutAppleCache.swift` — Symbols: JournalEntry, WorkoutRow, AppleDaily
- `MetricSeriesStore.swift` — Symbols: MetricPoint
- `MetricsCache.swift` — Symbols: CachedSleepSession, DailyMetric, SleepCorrectionRow
- `RawOutbox.swift` — Symbols: ClockRef, RawBatchMeta
- `Reads.swift` — Functions: hrSamples, rrIntervals, events, batterySamples, spo2Samples, skinTempSamples
- `StreamStore.swift` — Functions: upsertDevice, insert, storageStats_rowCountsForTest, deviceRowForTest
- `TrainingLogStore.swift` — Symbols: TrainingLogProvenance, SessionEffortRow, StrengthSetRow, TrainingLogEntry, WorkoutLabelRow
- `WhoopStore.swift` — Symbols: WhoopStoreInfo, WhoopStore

### `Packages/WhoopStore/Tests/WhoopStoreTests`

- `BiometricStreamTests.swift` — Test suite: BiometricStreamTests; 8 test methods
- `CursorTests.swift` — Test suite: CursorTests; 5 test methods
- `DerivedWriteTests.swift` — Test suite: DerivedWriteTests; 7 test methods
- `InsertTests.swift` — Test suite: InsertTests; 4 test methods
- `JournalWorkoutAppleCacheTests.swift` — Test suite: JournalWorkoutAppleCacheTests; 13 test methods
- `LatestSampleTests.swift` — Test suite: LatestSampleTests; 1 test methods
- `MetricSeriesStoreTests.swift` — Test suite: MetricSeriesStoreTests; 11 test methods
- `MetricsCacheTests.swift` — Test suite: MetricsCacheTests; 10 test methods
- `MigrationTests.swift` — Test suite: MigrationTests; 5 test methods
- `PruneTests.swift` — Test suite: PruneTests; 5 test methods
- `RRSequenceTests.swift` — Test suite: RRSequenceTests, DerivedIsolationTests; 10 test methods
- `RawOutboxTests.swift` — Test suite: RawOutboxTests; 6 test methods
- `ReadTests.swift` — Test suite: ReadTests; 5 test methods
- `ScaffoldTests.swift` — Test suite: ScaffoldTests; 2 test methods
- `SleepCorrectionTests.swift` — Test suite: SleepCorrectionTests; 3 test methods
- `TrainingLogStoreTests.swift` — Test suite: TrainingLogStoreTests; 13 test methods

### `Strand/Alarm`

- `AlarmController.swift` — Symbols: AlarmController

### `Strand/App`

- `AppModel.swift` — Symbols: AppModel
- `ContentView.swift` — Symbols: ContentView
- `RootView.swift` — Symbols: NavItem, NavTarget, NavigateKey, RootView, LiveSheet, FloatingNav, BatteryBadge
- `StrandApp.swift` — Symbols: AppEntry, StrandApp

### `Strand/BLE`

- `BLEManager.swift` — Symbols: BLEManager
- `BackfillPolicy.swift` — Symbols: BackfillTrigger, BackfillPolicy
- `BluetoothChoice.swift` — Symbols: BluetoothChoice (remembered access choice, launch gate, 15-min reconnect interval)
- `Commands.swift` — Symbols: WhoopCommand
- `FrameRouter.swift` — Symbols: FrameRouter
- `LiveHeartRate.swift` — Symbols: LiveHeartRate
- `LiveState.swift` — Symbols: LiveState, BatteryStatus, DeviceInfo
- `StandardHeartRate.swift` — Symbols: StandardHeartRate
- `StuckStrapDetector.swift` — Symbols: StuckStrapDetector

### `Strand/Collect`

- `Backfiller.swift` — Symbols: BackfillStoreWriting, Backfiller
- `ClockCorrelation.swift` — Symbols: ClockCorrelation
- `ClockPolicy.swift` — Symbols: ClockPolicy
- `Collector.swift` — Symbols: StoreWriting, CollectorPolicy, Collector
- `PrunePolicy.swift` — Symbols: PrunePolicy
- `RawCaptureWindow.swift` — Symbols: RawCaptureWindow
- `RawHistoryArchive.swift` — Symbols: RawHistoryArchive
- `StorePaths.swift` — Symbols: StorePaths, LaunchMode

### `Strand/Data`

- `DataBackup.swift` — Symbols: DataBackup, BackupResult
- `IntelligenceEngine.swift` — Symbols: IntelligenceEngine, Computed
- `MetricCatalog.swift` — Symbols: MetricDescriptor, MetricCatalog
- `Profile.swift` — Symbols: ProfileStore, K
- `Repository.swift` — Symbols: Repository
- `WhoopImporter.swift` — Symbols: WhoopImporter

### `Strand/Device`

- `BatteryMonitor.swift` — Symbols: BatteryMonitor
- `BatteryPresentation.swift` — Symbols: BatteryPresentation, Charge, Level
- `StrapBatteryPanel.swift` — Symbols: StrapBatteryPanel, StrapBatteryContent

### `Strand/MenuBar`

- `MenuBarContent.swift` — Symbols: MenuBarLabel, MenuBarContent

### `Strand/Onboarding`

- `OnboardingWizard.swift` — Symbols: OnboardingWizard, Step, BondWatcher, WelcomeStep, WhatItDoesStep, Slide, SlideRow (additional helpers in source)

### `Strand/Resources`

- `Info.plist` — App/probe bundle metadata and permissions descriptions.
- `Strand.entitlements` — App sandbox, Bluetooth and user-selected file entitlements.

### `Strand/Resources/Assets.xcassets`

- `Contents.json` — Asset catalog metadata.

### `Strand/Resources/Assets.xcassets/AppIcon.appiconset`

- `Contents.json` — Asset catalog metadata.
- `icon_128x128.png` — App icon image.
- `icon_128x128@2x.png` — App icon image.
- `icon_16x16.png` — App icon image.
- `icon_16x16@2x.png` — App icon image.
- `icon_256x256.png` — App icon image.
- `icon_256x256@2x.png` — App icon image.
- `icon_32x32.png` — App icon image.
- `icon_32x32@2x.png` — App icon image.
- `icon_512x512.png` — App icon image.
- `icon_512x512@2x.png` — App icon image.

### `Strand/Screens`

- `AlarmCard.swift` — Symbols: AlarmCard, AlarmEditor, AlarmSection
- `DataSourcesView.swift` — Symbols: DataSourcesView
- `HealthView.swift` — Symbols: HealthView, HeartRateSection, VitalsSection, Vital
- `Hubs.swift` — Symbols: SegmentedHub, TrendsHub, Seg, SettingsHub, AdvancedSettings, Tool
- `LiveStatusView.swift` — Symbols: LivePhase, LiveStatusCard, StepState, StrapHistoryCard
- `LiveView.swift` — Symbols: LiveView
- `MetricExplorerView.swift` — Symbols: ExploreRange, MetricExplorerView, MetricRow, MetricDetailView, CorrRow
- `PairingResetNotice.swift` — Symbols: PairingResetNotice
- `RecentCyclesCard.swift` — Symbols: RecentCyclesCard, Row
- `RecoveryDiagnosticsView.swift` — Symbols: RecoveryDiagnosticsView, Report
- `ScreenScaffold.swift` — Symbols: ScreenEmbeddedKey, ScreenScaffold, ComingSoon
- `SettingsView.swift` — Symbols: SettingsView, SettingsSection, FormRow
- `SleepNeedCard.swift` — Symbols: SleepNeedCard
- `SleepSessionsCard.swift` — Symbols: SleepSessionsCard, SessionRow, AdjustSleepSheet
- `SleepView.swift` — Symbols: SleepView, SleepInputKey, SleepModel, Stages, Night
- `TodayDetailViews.swift` — Symbols: TodayDetail, DayMath, DayHRStats, Inputs, DetailHeader, DetailTile, DetailGrid (additional helpers in source)
- `TodayView.swift` — Symbols: TodayView, WeekStrip, ConnectionStrip, SyncProgressStrip, SyncFormat, HeartRateDayCard, LiveHeadline (additional helpers in source)
- `TrendSections.swift` — Symbols: TrendRange, TrendSeries, TrendWindow, TrendRangeBar, TrendStat, TrendSummaryRow, TrendCard (additional helpers in source)
- `TrendsView.swift` — Symbols: TrendsView
- `WorkoutDetailView.swift` — Symbols: SleepTimeline, Segment, WorkoutSelection, WorkoutDetailView
- `WorkoutsView.swift` — Symbols: WorkoutsView, SportGroup, Range, RowMetrics, ColWidth

### `StrandTests`

- `BluetoothChoiceTests.swift` — Test suite: BluetoothChoiceTests; 4 test methods
- `CollectorBatteryTests.swift` — Test suite: CollectorBatteryTests, SpyStore; 2 test methods
- `LivePresentationTests.swift` — Test suite: LiveHeartRateTests, BatteryPresentationTests; 11 test methods
- `RawHistoryArchiveTests.swift` — Test suite: RawHistoryArchiveTests; 2 test methods
- `StrandSmokeTests.swift` — Test suite: StrandSmokeTests; 1 test methods

### `Tools/ble_probe`

- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.
- `make_app.sh` — Build/wrap the BLE research probe as a macOS app for Bluetooth permissions.

### `Tools/ble_probe/Sources/ble_probe`

- `main.swift` — Symbols: ScriptStep, Options, Probe

### `Tools/ble_probe/bundle`

- `Info.plist` — App/probe bundle metadata and permissions descriptions.

### `Tools/perf_probe`

- `Package.resolved` — Locked dependencies: grdb.swift 6.29.3
- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Tools/perf_probe/Sources/perf_probe`

- `main.swift` — Functions: ms, timed

### `Tools/reverse_engineer`

- `analyze_export.py` — Offline WHOOP export research/analysis.

### `Tools/strain_replay`

- `Package.resolved` — Locked dependencies: grdb.swift 6.29.3
- `Package.swift` — SwiftPM manifest; dependency/platform/target definition.

### `Tools/strain_replay/Sources/strain_replay`

- `main.swift` — Symbols: Scored

### `Tools/whoop_re`

- `test_whoop5_decode.py` — Python fixture regression tests for WHOOP 5 decoder.
- `whoop5_decode.py` — Standalone WHOOP 5 capture/frame decoder.

### `docs`

- `ANALYTICS.md` — NOOP analytics; Current processing path; Measurement rules
- `ARCHITECTURE.md` — NOOP architecture; Data flow; Boundaries
- `BLE_REVERSE_ENGINEERING.md` — BLE Reverse Engineering; Credits; Where the code lives
- `BUILD.md` — Build and test NOOP; Local development; Verification commands
- `CONTRIBUTING.md` — Contributing to NOOP; Before changing code; Where changes belong
- `DATA_MODEL.md` — NOOP local data model; Location and ownership; Tables and APIs
- `FEATURES.md` — Current NOOP features; Work in progress in the current checkout
- `HR_BROADCAST_RESEARCH.md` — Heart-rate broadcast: what is known (researched 2026-10-15); WHOOP 4.0 — documented, implemented; WHOOP 5.0 — VERIFIED (2026-10-21, live on owner's strap)
- `LIBRARY.md` — NOOP packages; Integration notes
- `MEASUREMENT_VALIDITY.md` — Measurement validity: specification and change report (October 2026); 1. Defects found and fixed; 2. Metric specifications
- `PRIVACY_SECURITY.md` — Privacy and data handling; Data paths; Local storage
- `PROTOCOL.md` — WHOOP BLE Protocol; 1. GATT topology; 2. Frame envelope
- `README.md` — NOOP documentation; Current guides; Measurement and implementation evidence
- `SCREEN_INVENTORY.md` — Screen inventory; Shared presentation
- `SLEEP_RECOVERY_RESEARCH_2026-10-27.md` — NOOP sleep and recovery: evidence and engineering direction; 1. The decisions that matter most; 2. What the current NOOP tree shows
- `SLEEP_SESSIONS.md` — Sleep sessions, naps and interrupted sleep; Audit (before this change); Architecture (now)
- `SLEEP_STRAIN_AUDIT.md` — Sleep / strain / recovery: lineage, algorithms, limits; Data lineage; Day boundary
- `WHOOP_REVERSE_ENGINEERING.md` — What a WHOOP export reveals about its scoring; Sleep: arithmetic that is exact; Sleep performance (MAE 3.0)
- `WORKOUT_STRAIN_REPORT.md` — Workout detection and strain: change report (October 2026); 1. Defects: what was actually reproduced; 2. How input reaches the display now
- `WORKOUT_STRAIN_RESEARCH_2026-10-30.md` — NOOP: workout detection, training load, and strain; Main recommendation; 1. Findings that should change the product

### `docs/assets`

- `banner.svg` — Documentation artwork.
- `logo.svg` — Documentation artwork.

### `docs/reverse-engineering`

- `ALARM_CAPABILITIES.md` — WHOOP 5.0 haptics and alarms — investigation and capability matrix; Evidence so far; H02–H06 results (approved, 2026-11-02 13:07–13:12)
- `AUDIT.md` — Audit of NOOP's existing BLE integration (2026-11-02); Architecture map; Status (2026-11-02)
- `COMMAND_REGISTRY.md` — Command registry (WHOOP 5.0)
- `EXPERIMENT_LOG.md` — Experiment log; P0 — Existing evidence (passive, 2026-10-13 → 2026-11-02); E01 — Passive GATT enumeration (2026-11-02 11:13)
- `GATT_MAP.md` — GATT map (WHOOP 5.0, fw 50.43.1.0, hw WG50_r52); Differences from published research
- `PACKET_TYPES.md` — Packet types and decoded structures (WHOOP 5.0); Type inventory on this strap; 36 COMMAND_RESPONSE
- `PROTOCOL_SPEC.md` — WHOOP 5.0 transport and frame specification; 1. Transport; 2. Frame envelope
- `README.md` — WHOOP 5.0 reverse engineering; Tools; Redaction
- `SAFETY_MATRIX.md` — Safety matrix; History acknowledgement policy (implemented 2026-11-02); Battery alerts (implemented 2026-11-02)
- `SENSOR_STREAMS.md` — Sensor streams (WHOOP 5.0, fw 50.43.1.0)
- `STATE_MACHINE.md` — Connection and sync state machine (WHOOP 5.0); NOOP's 5.0 sequence (as implemented 2026-11-02); Not yet tested
- `TEST_RESULTS.md` — Test results; Offline (no device); Live (owner's strap)
- `UNKNOWN_CAPABILITIES.md` — Unknowns and hypotheses
- `whoop5_commands.json` — Machine-readable command registry.

### `docs/reverse-engineering/captures`

- `E01-passive-gatt.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `E02-readonly-matrix.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `E04-realtime-hr.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `H01-get-alarm.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `H02-H03-H06-slot0.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `H02b.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `H05-disable.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.
- `H07.jsonl` — Recorded protocol experiment evidence; see experiment log for claims/redaction.

## 08 · Verification record

Bluetooth choice + periodic reconnect, 2026-11-02:

- PASS: `xcodegen generate`; hosted `xcodebuild ... CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test` (21 tests incl. new `BluetoothChoiceTests`).
- Not run: live strap disconnect/reconnect, system prompt behaviour, the Settings toggle in the running app. Local builds found ad-hoc signed and no codesigning identity installed, so macOS will still re-prompt after rebuilds until signing is configured.

Charging illustration rework, 2026-11-02:

- PASS: `swift test --package-path Packages/StrandDesign` (27 tests) with `STRAND_SNAPSHOT_DIR`; light/dark static snapshots inspected visually. PASS: app `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`.
- Not run: hosted app tests, live animation timing/CPU measurement, hardware charging. Animated flow layer was not observed running (ImageRenderer snapshots are static).

Documentation audit, 2026-11-02:

- Enumerated existing tracked and nonignored untracked files; read first-party text for inventory/symbols and inspected core execution paths and guides.
- PASS: all 302 indexed files exist; indexed set exactly matches existing tracked/nonignored first-party files (excluding this file). Explicit source/document paths in the overview resolve. Compared schema v1–v15, scoring version, manifests/resolutions, root Git status and baseline commit.
- Confirmed the index includes every existing first-party tracked/nonignored file at creation (except this self-referential file); deleted and ignored/generated material are separately accounted for.
- Application/package/Python tests, app build, snapshots and hardware checks: **not run** for this documentation-only change. No functional code changed.
- This record applies only to the documented snapshot. Refresh it when behavior changes.

## 09 · Recent reference-maintenance log

| Date | Change | Checks / remaining work |
| --- | --- | --- |
| 2026-11-02 | Remembered Bluetooth choice (`BluetoothChoice`, Settings toggle, launch gate) and 15-min reconnect watchdog in `BLEManager`; `LiveState`, `AppModel`, `SettingsView`. | Hosted tests pass; no hardware/UI run. |
| 2026-11-02 | Reworked `ChargingIllustration` (colour-coded phases, bolt/check pack, docking ring, current flow, shimmer, periodic reminder pulse). API unchanged. | StrandDesign tests + snapshots, app build. Live motion/CPU not measured. |
| 2026-11-02 | Created root `AGENTS.md` as the single agent entry point, architecture/state reference, file index and mandatory update contract. Preserved existing code changes. | Inventory/source consistency checks; no runtime checks. Existing documentation drift and potential alarm sequencing issue recorded in section 04. |

## 10 · Initial working-tree evidence (historical baseline)

This is the **pre-documentation** status observed during the initial audit, not a claim about future Git status. Replace/consolidate when reconciling later changes. `M` modified, `D` deleted, `??` untracked. No pre-existing files were changed by the reference-creation task.

```text
M .gitignore
 M Packages/StrandDesign/Sources/StrandDesign/Components.swift
 D Packages/StrandDesign/Sources/StrandDesign/StrainGauge.swift
 M Packages/StrandDesign/Tests/StrandDesignTests/WidgetSnapshotTests.swift
 M Strand/App/AppModel.swift
 M Strand/App/RootView.swift
 M Strand/App/StrandApp.swift
 M Strand/BLE/BLEManager.swift
 M Strand/Collect/StorePaths.swift
 M Strand/Data/Repository.swift
 M Strand/MenuBar/MenuBarContent.swift
 M Strand/Onboarding/OnboardingWizard.swift
 M Strand/Screens/HealthView.swift
 M Strand/Screens/LiveView.swift
 M Strand/Screens/SettingsView.swift
 M Strand/Screens/SleepView.swift
 M Strand/Screens/TodayView.swift
 M docs/ARCHITECTURE.md
 M docs/BUILD.md
 M docs/CONTRIBUTING.md
 M docs/SCREEN_INVENTORY.md
 D docs/reverse-engineering/captures/E01-passive-gatt.jsonl.sb-3aa3c045-H2IfTW
?? Packages/StrandDesign/Sources/StrandDesign/ChargingIllustration.swift
?? Packages/StrandImport/Tests/StrandImportTests/Resources/export.xml
?? Strand/BLE/LiveHeartRate.swift
?? Strand/Device/BatteryPresentation.swift
?? Strand/Device/StrapBatteryPanel.swift
?? StrandTests/LivePresentationTests.swift
```
