# NOOP — agent reference

Single LLM-maintained entry point: rules, current state, routing and file index. Read §0–§4 first, then only the component and index entries you need (`rg -n '^##|^###' AGENTS.md` to jump). Source and tests win over this file; other docs and source comments can be stale (§4). Paths are repository-relative.

## 0 · Maintenance contract (every program change)

1. `git status --short` first; preserve unrelated work. Read affected source and tests.
2. In the same task, update the affected §3 bullets, §5 settings, §7 index lines (add/move/remove files), §8 verification and a §9 log row. Keep entries terse; no source bodies, logs, health data, credentials or signing values.
3. Mark what is implemented vs tested vs hardware-confirmed vs unknown. Never imply tests pass because test files exist.
4. §9 keeps the latest 8 rows; fold older context into §3/§4. Do not create a second state-summary file.
5. Before handing back, re-run the index check in §8 so §7 matches the tree.

This is a convention, not CI: reconcile with the working tree before trusting it.

## 1 · Snapshot

- Refreshed **2026-11-05** (America/New_York). Branch `main`, HEAD `d058a70` (`d058a701d9d8…`). Working tree (uncommitted): Trends visual restyle; Alarms tab; 2026-11-05 smart-wake/delivery/alarm-history/coverage/charging rework (see §9).
- **NOOP**: local-only macOS companion for WHOOP 4.0/5.0 straps. Internal target/scheme/package prefix **Strand**; bundle `com.noopapp.noop`, product `NOOP.app`, v0.1.0 (1).
- 318 first-party files indexed in §7 (tracked + non-ignored untracked, excluding this file). Source size hotspots: `BLEManager.swift` ~2.0k lines, `SleepStager.swift` ~1.3k, `OnboardingWizard.swift` ~1.1k, `TrendSections.swift` ~0.9k — search, don't read whole.
- Test inventory (methods in files, not pass results): StrandAnalytics 388, WhoopProtocol 139, WhoopStore 111, StrandImport 61, StrandDesign 27 (2 snapshot tests skip without env), hosted StrandTests 31, Python 22.

## 2 · Architecture and routing

```text
AppEntry (NOOP_TEST_HOST? bare host) -> StrandApp -> AppModel (one instance; window + menu bar)
  strap <-> BLEManager (+ Commands, DeviceFamily framing, Reassembler, WhoopProtocol decode)
    realtime -> FrameRouter -> LiveState -> LiveHeartRate / BatteryPresentation -> UI
    frames   -> Collector -> WhoopStore            history -> Backfiller / RawHistoryArchive -> WhoopStore
  WHOOP ZIP/folder -> StrandImport -> WhoopImporter -> WhoopStore
  IntelligenceEngine -> IncrementalScorer -> AnalyticsEngine -> derived rows + provenance
  Repository -> Overview / Trends / Settings / menu bar
  AlarmController -> AlarmPlanner + SmartWakeDecider (evidence windows) -> AlarmDeliveryTransaction -> strap (AlarmStrapLink)
                  + Mac notification (AlarmNotifying) + append-only history (WhoopStore alarmEvent)
  DataBackup <-> user-selected export / restore-by-replacement
```

| Concern | Start in | Checks |
| --- | --- | --- |
| Lifecycle, scheduling, ownership | `Strand/App/AppModel.swift`, `StrandApp.swift` | hosted `StrandTests` |
| Navigation / screens | `Strand/App/RootView.swift`, `Strand/Screens/Hubs.swift` | app build + visual check |
| Connect, pair, sync, wire commands | `Strand/BLE/BLEManager.swift`, `Commands.swift` | WhoopProtocol tests, reverse-engineering docs |
| Frame decode / checksums / 5.0 messages | `Packages/WhoopProtocol/Sources/WhoopProtocol/` | Swift fixtures + Python decoder tests |
| Durable collection / safe acknowledgement | `Strand/Collect/`, history path in `BLEManager.swift` | collector, raw archive, protocol tests |
| Schema / queries | `Packages/WhoopStore/Sources/WhoopStore/Database.swift` + extensions | migration, idempotence, derived-write tests |
| Scores, sleep, load, provenance | `Packages/StrandAnalytics/Sources/StrandAnalytics/` | analytics tests incl. replay regression |
| Imports / backup / display merge | `Strand/Data/`, `Packages/StrandImport/` | import + store tests (copied data only) |
| Battery, charging, live HR | `Strand/Device/`, `Strand/BLE/LiveHeartRate.swift`, `LiveState.swift`, `Whoop5Messages.swift` | `LivePresentationTests`, `CollectorBatteryTests`, `Whoop5ChargingTests` |
| Alarms | `Strand/Alarm/AlarmController.swift`, `Strand/Screens/AlarmsView.swift`, `AlarmHistoryView.swift`, analytics `AlarmEngine.swift`, `SmartWake.swift`, `AlarmDelivery.swift`, `AlarmHistory.swift` | `AlarmEngineTests`, `SmartWakeTests`, `AlarmDeliveryTests`, `AlarmHistoryTests`, hosted `AlarmControllerTests`; hardware evidence is firmware-specific |
| Shared UI primitives | `Packages/StrandDesign/Sources/StrandDesign/` | StrandDesign tests / snapshots |

Packages (all Swift tools 5.9, platforms macOS 13 / iOS 16; **only a macOS app target exists**):
`WhoopProtocol` (no deps; schema JSON resource) · `WhoopStore` → WhoopProtocol, GRDB (≥6.0.0, resolved 6.29.3) · `StrandAnalytics` → WhoopProtocol, WhoopStore · `StrandImport` → WhoopProtocol, WhoopStore, ZIPFoundation (≥0.9.0, resolved 0.9.20) · `StrandDesign` (SwiftUI, no deps). Tools: `ble_probe` → WhoopProtocol; `perf_probe`, `strain_replay` → analytics + store + protocol; Python uses stdlib only.

## 3 · Current behavior (verified against source 2026-11-03)

### App and UI

- `AppEntry` checks `NOOP_TEST_HOST` before startup (tests get no BLE/store). Single strap identity `my-whoop`. `AppModel` owns BLE/live state, `Repository`, profile, scoring, imports, battery notifications, alarms.
- New stored chunks: raw-data refresh throttled ~2 s; scoring debounced until ~8 s quiet; post-download processing triggered. Launch: refresh cache, wait ~6 s, apply version rescoring, then analyze every ~15 min. Scoring runs in a detached utility task, never in views.
- Destinations (floating pill, Cmd-1…4): **Overview** (`TodayView`), **Trends** (`TrendsHub`: Scores, Sleep, Vitals, Activity), **Alarms** (`AlarmsView`), **Settings** (`SettingsHub`: General = strap/Bluetooth/profile/battery; Data = WHOOP import, comparison, backups; Advanced = diagnostics, metric explorer, live strap). First-launch onboarding overlays the shell.
- Alarms tab: next-alarm hero (time, countdown, smart window, delivery pill, "I'm awake" while an early wake's deadline fallback is pending), warnings (incl. history-save failures), alarm rows, `AlarmEditor`, **History** (`AlarmHistorySection`: one row per occurrence with evidence-based status; detail sheet = facts, genuine NOOP stage timeline ±90/30 min with separate decision/vibration markers, event trail, user notes). `NextAlarmLink` (Overview; Sleep) navigates there.
- Overview HR card coverage: `DayCoverage` (StrandAnalytics) — supported intervals clipped/unioned to the day's real length (DST) up to now; captions "X recorded so far" / "X recorded of 24 h"; details line "Data through …", gap stretches, unsynced time; warning only for ≥1 h and ≥10 % gaps or >2 h unsynced. Never claims the strap was off. Caption only; scoring unchanged.
- Hypnograms only from genuine timestamped stage segments (`SleepTimeline.intervals(session:)`); imported stage totals draw a proportional bar (Sleep hero, Today card) with a note. No synthetic stage order anywhere.
- Overview: week/day selection, recovery/sleep/strain detail in place, live-HR sheet, sync/download/processing status. Trends adds sleep correction and workout detail; workout labels, effort and strength sets are user records.
- Trends styling: summary `TrendStat` bubbles (26 pt continuous radius, SF Symbol badge, SF Rounded, accent wash/border/shadow, springy hover lift off under Reduce Motion; `accent` tints bubble, `tint` tints value). Chart cards use `TrendChart(style: .soft)` (monotone 3.5 pt line, one haloed latest-point bubble, dashed grid, rounded labels), `TrendCard(accent:)`, `TrendFooter` pills and `SoftAxis` + rounded gradient bars. Other screens keep `TrendChart` `.standard` and `ChartFooter`.
- Realtime stream ownership: `BLEManager.realtimeOwners` (`live-sheet`, `menu`, `alarm`, default `ui`); the stream stops and the live value clears only when the last owner releases. The alarm releases on decision, edit/delete, completion and errors.
- `LiveHeartRate`: median over ~10 s (≤40 readings), plausible 30–220 bpm, reported HR preferred, RR fallback, shared `HRZones`; publishes only changed values.
- `BatteryPresentation`: low <20% (from `BatteryAlertPolicy.lowPercent`), medium <35%; percentage stale when disconnected or >10 min old. Charge (`charging`/`likely`/`notCharging`/`unknown`) and attachment come from `LiveState.charging` (`ChargingModel`) with their own freshness; disconnected → unknown. `illustration` maps to detached/attached/charging/full/unknown. All surfaces (badge, menu bar, Settings, live sheet, onboarding) use it; `BatteryMonitor` alerts see only the confirmed flag stamped on readings.
- `ChargingIllustration` phases: `idle` (detached, pack beside), `attached` (seated, unlit), `charging` (flow), `full`, `unknown` (faint pack). Spring dock + ring on detached→charging, 5 flow cycles, reminder every 30 s and on hover; none under Reduce Motion, inactive app or dimmed.
- Not present: Apple Health import UI, mobile app, cloud/account service, coaching, standalone stress/insights/compare screens. Library code (e.g. Apple Health parsing, `ComparisonEngine`, `BehaviorInsights`) is not proof of exposed UI.

### BLE, charging and collection

- `BLEManager`: scan → connect → discover → bond → subscribe → per-characteristic reassembly → decode/route/store/sync; `DeviceFamily` selects 4.0 vs 5.0 GATT and header framing.
- `BluetoothChoice` (`noop.bluetoothChoice`): records the system answer; Settings ▸ Strap toggle. While declined, no `CBCentralManager` at launch unless macOS reports allowedAlways. Ad-hoc rebuilds still re-prompt; only stable signing (`Local.xcconfig`) fixes that.
- Reconnect: 3 s rescan after unintended disconnect, plus a 15-min watchdog (`BluetoothChoice.reconnectIntervalSeconds`) that cancels a stalled connect and rescans while open and disconnected; skipped after user Disconnect. `LiveState.nextReconnectAt` drives the Settings caption. Not hardware-tested.
- Charging (`ChargingModel`, WhoopProtocol): attachment and activity are separate facts with source, event time, receipt time and connection UUID (`LiveState.beginConnection` per connect; reset on disconnect). Events 7/8 → activity; 21 → attached (and clears a "not charging" that was only inferred from detachment); 22 → detached + not charging. `Whoop5Charging.packInfo` (151): only the E02 shape (FAILURE, 31-byte body `01`+zeros) = detached; SUCCESS = `answeredUndecoded` (attachment stays unknown); anything else unrecognized. Replies are bound to request seq/time/connection; older evidence never overrides newer (late reply vs newer removal). Facts expire after 3 h; percentages never refresh them. "Charging likely" = ≥3 readings, ≥3 pt non-decreasing rise over ≥10 min, expires 20 min; never confirmed, never alerts. 4.0 BATTERY_LEVEL flag → activity. Battery/pack poll ~60 s, paused during downloads, caught up immediately after (`pollBatteryIfOverdue`). Live charging on hardware not yet observed.
- `Commands` is a restricted app command set; research never licenses destructive/firmware ops in normal flows. `FrameRouter` mutates `LiveState`; standard HR broadcast listening is opt-in (`listenToHRBroadcast`, default off).
- `Collector`: flush at 64 frames / 30 s, pre-clock cap 4096; decode/persist before optional raw outbox. Raw capture off by default; capture window ≤5 min.
- `Backfiller` persists decoded history, optional raw and cursor **before** chunk ack. Keep-data-on-strap suppresses ack/cursor advance. Repeated ENDs belong to one offload; never close after the first END.
- 5.0 undecodable history → `RawHistoryArchive` (UTC-day JSONL in `OpenWhoop/undecoded-history`, fsync before return, never pruned). Archive failure must block acknowledgement.
- Clocks are explicit (`DeviceClock`, `ClockCorrelation`, `ClockPolicy`): type-47 history carries Unix time; realtime may need device/host correlation.
- `BackfillPolicy` rate-limits sync triggers; `StuckStrapDetector` compares strap availability to persisted HR frontier.
- Before hardware work read `docs/reverse-engineering/SAFETY_MATRIX.md`, `COMMAND_REGISTRY.md` and relevant captures. Evidence is scoped to WHOOP 5.0 fw 50.43.1.0 / hw WG50_r52.

### Storage, imports and scoring

- `StorePaths`: Application Support `OpenWhoop/whoop.sqlite` (sandbox container in the app); never hard-code a home path. WAL/SHM accompany it; raw archive and UserDefaults are separate.
- `WhoopStore` is an actor over GRDB; `Repository` and BLE hold separate handles (WAL + busy handling).
- Schema **v16** (`Database.swift`, migrations v1–v16; v16 alarm history). Add migrations; never edit applied ones. v10 RR sequence, v11 provenance, v12 load, v13 training logs, v14 workout labels + incremental state, v15 classified sleep sessions + corrections.
- Tables: `device`, `hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`, `rawBatch`, `cursors`, `dailyMetric`, `sleepSession`, `journal`, `workout`, `appleDaily`, `metricSeries`, `metricProvenance`, `loadRecord`, `sessionEffort`, `strengthSet`, `workoutLabel`, `dayScoreState`, `sleepCorrection`, `alarmEvent`, `alarmAnnotation`.
- Raw/import identity and `<device>-noop` computed identity stay distinct. `Repository` merges for display with imported-field precedence; imported values never enter NOOP causal baselines.
- `WhoopImporter` → idempotent upserts of cycles, sleeps, workouts, journal, metric series. `DataBackup` exports the DB and restores by replacement (relaunch); not a merge, not preferences or raw archive.
- `IntelligenceEngine.scoringVersion = 5`; `IncrementalScorer` reuses unchanged days, tracks algorithm/config/source changes, scores in causal order; upgrades archive old derived rows and replace per-day results atomically.
- `HRQuality`/`SupportedHR` gate supported time; `HRCalibration` gives HR references; `CardioLoad` → `StrainScorer` (versioned 0–21). Confident sleep/naps excluded from load in v5.
- Sleep: minute/epoch evidence → episodes → classified sessions (primary / interrupted-primary / nap / uncertain) → user corrections → accounting, vitals, recovery. Corrections survive rescoring.
- HRV uses cleaned RR with sequence. Baselines use compatible metric identities from prior days only. `RecoveryAssessment` separates dimensions; legacy composite is an estimate.
- Missing ≠ zero/awake/sleep. Imported stage totals are not a hypnogram. Load, calories, labels, strength volume and RPE are different quantities. `StagingEvaluation`/`DetectionEvaluation` do not establish clinical accuracy.

### Alarms

- `AlarmEngine`: pure planning (timezone/DST/weekday), `AlarmStateMachine`. `SmartWake.swift`: `WakeEvidenceBuffer` (timestamped HR; rejects implausible/duplicate-second/out-of-order/stale >15 s/future), fixed median windows, `SmartWakeDecider` counts elapsed sustained time (each window consumed once; gaps break runs), `SmartWakePolicy` versions, `WakeDecisionRecord` (policy, threshold, score, baseline source/age, evidence quality, reason). Default `smart-wake-v2-hr`: 20-s windows ≥10 samples, 60 s sustained, threshold 0.45→0.35 across the window (~+11 %→+9 % HR over baseline), baseline ≤4 days, run must end ≤45 s ago; sleep goal needs main-session progress ≤45 min old. Experimental: compared only on synthetic traces vs `legacyV1` (SmartWakeTests prints the table); not validated for wake effectiveness.
- Delivery (`AlarmDeliveryTransaction`): SET(now+60) → wait final SUCCESS → RUN → wait SUCCESS → HAPTICS_FIRED/APP_DRIVEN_ALARM_EXECUTED within 40 s of RUN = "strap reported"; answers matched by command + app seq (`BLEManager.send` returns seq); 10 s response / 30 s haptics timeouts; disconnect fails. Failed/unconfirmed/expired-undismissed → deadline re-armed on the slot (RUN consumes it) and the Mac rings again at the deadline; only a strap dismissal (100 reason 2 / matched), in-app "I'm awake" or the deadline completes an occurrence. `completed` (`alarm.fired`) vs `earlyAttempted` (`alarm.earlyAttempted`) are separate and survive restart.
- Deadline arm is SET → (answer) → GET read-back, bound to one occurrence; never while a delivery is unsettled or within 2 min after a stored deadline should ring (`slotHoldUntil`), so the next arm can't overwrite a ringing alarm. STRAP_DRIVEN_ALARM_EXECUTED is attributed only to an exactly stored strap time (±2 s, `alarm.armedTargets`). Capabilities follow `live.deviceInfo.firmware` changes.
- On-device alarm, vibration and read-back confirmed **only for fw 50.43.1.0** (H04 2026-11-02). Events carry a live flag (within 120 s of strap time): only live events touch delivery; history replays are recorded at their original time, unmatched ones stay unmatched. Notifications check authorization, use critical sound only if the system enables it, and record the submission outcome.
- History: `alarmEvent` (append-only; dedupe key `strap:<n>:<unix>:<subsec>` for strap events) + `alarmAnnotation` (user notes). Rows show immediately, persist in the background, failures surface as a warning and retry on tick; delivery never waits on persistence. Stage lookup (`AlarmStageLookup`) uses raw NOOP episodes only (`Repository.noopSleepEpisodes`), never imported totals, recombined gap labels, `unknown`/`asleep`.
- Smart/goal early wake needs the Mac awake, NOOP running and connected. Lid-closed sleep is not prevented. Never promise unconditional delivery or describe an HR rise as confirmed light sleep.

## 4 · Known issues and documentation drift

- Alarm delivery is tested against a fake link only; the real SET→RUN→haptics sequence, delayed answers, slot hold timing and dismissal attribution are not hardware-confirmed. `BLEManager` stream ownership has no direct test (CoreBluetooth). Smart-wake v2 thresholds are untested on real nights.
- Stage source label shows the current `IntelligenceEngine.scoringVersion`; rows don't store their own version (rescoring replaces them).
- Overview coverage caption is unit-tested but not visually inspected (card is below the fold in fixture screenshots).
- Older rows in `ALARM_CAPABILITIES.md` predate H02b/H04/H07.
- `docs/FEATURES.md`, `DATA_MODEL.md`, `ANALYTICS.md`, `docs/README.md` and `SLEEP_RECOVERY_RESEARCH_2026-10-27.md` still label sleep/alarm/v15 work as uncommitted/in progress; it is committed.
- Legacy comments mention server/phone/Kotlin or removed screens (`MetricsCache`, `Cursors`, design umbrella, some views). No backend or mobile app ships.
- Not universal WHOOP compatibility: alarm confirmation is firmware-specific; attached battery-pack reply layout and live charging events are unobserved; unknown history must be archived, not guessed.
- No CI workflow exists. No release/test-health conclusion is implied by this file.

## 5 · Build, configuration, runtime switches

- `project.yml` (XcodeGen) is canonical; `Strand.xcodeproj` is generated and ignored — regenerate after adding app files or changing settings. macOS 13+, Swift 5.0 language mode, minimal strict concurrency.
- Entitlements: sandbox, Bluetooth, user-selected read/write. `Signing.xcconfig` optionally includes ignored `Local.xcconfig` (template `Local.xcconfig.example`).
- BLEManager emits existing main-actor/nonisolated delegate warnings at build; not errors.

```sh
xcodegen generate
swift test --package-path Packages/<WhoopProtocol|WhoopStore|StrandAnalytics|StrandImport|StrandDesign>
python3 -m unittest discover -s Tools/whoop_re -p 'test_*.py'
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
STRAND_SNAPSHOT_DIR=/tmp/noop-snapshots swift test --package-path Packages/StrandDesign   # optional image snapshots
```

Run the affected checks per change; docs-only changes need path/claim consistency checks. Tools that open `WhoopStore` can migrate the DB: use a copy made via SQLite backup or the app export, never a bare main file without WAL.

| Switch / key | Meaning |
| --- | --- |
| env `NOOP_TEST_HOST` | Isolated test host (set by scheme) |
| env `NOOP_FIXTURE_STORE` | DB **copy** path; disables CoreBluetooth; copy may still migrate/rescore; logs launch timing |
| `-noop.fixture.tab trends\|alarms\|settings`, `-noop.fixture.live YES`, `-noop.fixture.battery cycle\|charging` | Fixture-only launch tab, open live sheet, synthetic battery states via the charging model (cycle: detached, attached, charging, full, disconnected; 8 s/state) |
| `-noop.fixture.alarmHistory YES`, `-noop.fixture.alarmDetail YES` | Fixture-only: seed synthetic alarm history (one occurrence per status) into the COPY; open the newest detail sheet |
| `noop.onboarded`, `scoringVersionApplied` (target 5) | First-run done; applied scoring migration |
| `noop.bluetoothChoice` | `undecided`/`allowed`/`declined` |
| `noop.keepDataOnStrap`, `enableRawCapture`, `listenToHRBroadcast` | No trim ack; research raw capture (off); standard HR subscription (off) |
| `noop.deviceInfo`, `lastSyncedAt`, `backfillLastAt`, `hrBroadcastLastSet` | Cached DIS info; sync/backfill timestamps; last broadcast set |
| `alarm.specs`, `alarm.capabilities`, `alarm.fired`, `alarm.earlyAttempted`, `alarm.armedTargets`, `alarm.ownsStrapAlarm` | Alarm definitions, capabilities, completed occurrences, early wakes attempted, stored strap times, strap ownership |
| `profile.age/sex/heightCm/weightKg/hrMaxOverride` | `ProfileStore` |
| `notify.batteryLow/batteryFull/batteryAlertState` | `BatteryMonitor` alerts |
| `noop.trends.segment`, `noop.settings.segment`, `noop.live.detailsOpen` | Hub selection / UI state |

## 6 · Folder boundaries

| Path | Treatment |
| --- | --- |
| `Strand/`, `Packages/*/{Sources,Tests}`, `StrandTests/`, `Tools/`, `docs/` | First-party; indexed in §7 |
| `Strand.xcodeproj/`, `Packages/*/.build/`, `Tools/*/.build/`, `.swiftpm/`, DerivedData | Generated; never authoritative, don't edit |
| `.local/ai-prompts/` | Ignored historical prompt notes; not requirements |
| `Local.xcconfig`, SQLite files, private exports, secrets | Ignored; never copy contents here |
| `.git/`, `.DS_Store`, `__pycache__/` | Not behavior |

## 7 · File index

Format: `file` — purpose. Tests list `Suite(methods)`. Fixtures/resources are data, not code.

### Root
- `README.md` — product overview, build/run. `ATTRIBUTION.md` — history and protocol credits. `DISCLAIMER.md` — independence/trademark notice.
- `project.yml` — XcodeGen targets, packages, settings, test scheme. `Signing.xcconfig` / `Local.xcconfig.example` — shared signing + private override template. `.gitignore` — generated/personal exclusions (synthetic `export.xml` allowed).

### `Strand/App`
- `StrandApp.swift` — `AppEntry` test-host gate; `StrandApp` window + menu-bar scenes sharing `AppModel`.
- `AppModel.swift` — owns BLE, repository, scoring schedule, imports, battery monitor, alarms.
- `RootView.swift` — shell: `NavItem` (4 tabs)/`FloatingNav`, `NavTarget`, `LiveSheet`, `BatteryBadge`.
- `ContentView.swift` — thin wrapper view.

### `Strand/BLE`
- `BLEManager.swift` — CoreBluetooth central: scan/connect/bond/subscribe, reassembly, 4.0/5.0 decode, history offload + ack, charging/battery/alarm command handling, reconnect watchdog.
- `Commands.swift` — `WhoopCommand` allowed command set + payloads. `FrameRouter.swift` — realtime frames → `LiveState`.
- `LiveState.swift` — published live status, `BatteryStatus`, `ChargingReport`, `DeviceInfo` cache. `LiveHeartRate.swift` — smoothed display HR.
- `StandardHeartRate.swift` — 0x2A37 parser. `BackfillPolicy.swift` — sync trigger rate limit. `StuckStrapDetector.swift` — data-vs-frontier stall check. `BluetoothChoice.swift` — remembered access choice, launch gate, reconnect interval.

### `Strand/Collect`
- `Collector.swift` — frame buffer/flush policy, `StoreWriting`. `Backfiller.swift` — history persist-then-ack. `RawHistoryArchive.swift` — undecodable-history JSONL.
- `ClockCorrelation.swift`, `ClockPolicy.swift` — device↔host time. `RawCaptureWindow.swift` — bounded raw capture. `PrunePolicy.swift` — retention constants. `StorePaths.swift` — DB path, `LaunchMode`, fixture switches.

### `Strand/Data`
- `Repository.swift` — UI data source; loads/merges days, sleep, workouts, imports. `IntelligenceEngine.swift` — scoring orchestration, `scoringVersion`.
- `WhoopImporter.swift` — parsed export → store upserts. `DataBackup.swift` — export/restore. `MetricCatalog.swift` — explorer metric descriptors. `Profile.swift` — `ProfileStore` defaults.

### `Strand/Device`, `Strand/Alarm`, `Strand/MenuBar`, `Strand/Onboarding`
- `Device/BatteryPresentation.swift` — battery text/icon/tint/freshness model. `Device/BatteryMonitor.swift` — low/full notifications. `Device/StrapBatteryPanel.swift` — battery panel with `ChargingIllustration`.
- `Alarm/AlarmController.swift` — alarm runtime + `AlarmStrapLink`/`AlarmNotifying`/`AlarmHistorySink` interfaces: scheduling, evidence ingest, decisions, delivery transactions, slot arm/read-back/reconcile, history persistence.
- `MenuBar/MenuBarContent.swift` — menu-bar label and menu (status, sync, streaming).
- `Onboarding/OnboardingWizard.swift` — first-run steps: welcome, Bluetooth, wear, scan, bond, profile, import, done.

### `Strand/Screens`
- `TodayView.swift` — Overview: week strip, connection/sync strips, HR day card. `TodayDetailViews.swift` — recovery/sleep/strain detail, `DayMath` formatting.
- `TrendsView.swift` — Trends ▸ Scores (summary, recovery hero, daily signals, year strip). `TrendSections.swift` — shared trend range/series, `TrendStat`/`TrendCard`/`TrendFooter`/`TrendLineCard`, Sleep/Vitals/Activity trends, `SoftAxis`, `EqualRowLayout`, `TrendTabSwitcher`.
- `Hubs.swift` — `TrendsHub`, `SettingsHub`, `AdvancedSettings`. `ScreenScaffold.swift` — page scaffold + `ComingSoon` empty state.
- `SleepView.swift` — sleep detail tiles/hypnogram. `SleepSessionsCard.swift` — sessions + `AdjustSleepSheet` corrections. `SleepNeedCard.swift` — sleep need.
- `HealthView.swift` — HR and vitals detail. `WorkoutsView.swift` — workout list/summary. `WorkoutDetailView.swift` — workout detail, labels, effort, sets.
- `SettingsView.swift` — General settings (strap, Bluetooth toggle, profile, battery). `AlarmsView.swift` — Alarms tab, `AlarmEditor`, `NextAlarmLink`. `AlarmHistoryView.swift` — History section, occurrence detail (stage timeline, trail, notes). `DataSourcesView.swift` — imports, comparison, backups.
- `LiveView.swift` — live strap sheet. `LiveStatusView.swift` — connection steps, strap history card. `PairingResetNotice.swift` — stale-pairing instructions.
- `MetricExplorerView.swift` — metric browser + correlations. `RecoveryDiagnosticsView.swift` — recovery inputs report. `RecentCyclesCard.swift` — recent cycles list.

### `Strand/Resources`
- `Info.plist`, `Strand.entitlements`; `Assets.xcassets/` (`Contents.json`, `AppIcon.appiconset/Contents.json` + 10 `icon_*.png`).

### `StrandTests` (hosted)
- `AlarmControllerTests`(9), `BluetoothChoiceTests`(4), `CollectorBatteryTests`(2), `LivePresentationTests` = LiveHeartRateTests + BatteryPresentationTests (13), `RawHistoryArchiveTests`(2), `StrandSmokeTests`(1).

### `Packages/WhoopProtocol/Sources/WhoopProtocol`
- `DeviceFamily.swift` — 4.0/5.0 GATT, header CRC kind, packet types. `Framing.swift` — CRC8/16/32, `Reassembler`, frame verification.
- `Interpreter.swift` — schema-driven `parseFrame`/`parseFrameWhoop5`. `Schema.swift` — schema model/loader (`Resources/whoop_protocol.json`). `Values.swift` — `ParsedValue`. `PostHooks.swift` — per-packet decode hooks.
- `Streams.swift` — HR/RR/event/battery/SpO2/temp/resp/gravity extraction, 5.0 realtime + historical records. `HistoricalStreams.swift` — history → streams. `HistoricalMeta.swift` — history metadata classification.
- `Whoop5Messages.swift` — 5.0 command responses, clock, data range, events, `Whoop5Charging` (`packInfo`), `Whoop5Alarm`. `ChargingModel.swift` — attachment/charging facts, freshness, ordering, "likely" inference. `BatteryPolicy.swift` — readings + alert policy. `DeviceClock.swift` — clock estimator. `SyncCoverage.swift` — sync spans/sessions. `Redaction.swift` — capture redaction. `WhoopProtocol.swift` — module info.

### `Packages/WhoopProtocol/Tests/WhoopProtocolTests`
- BiometricStreamsParityTests(1), DeviceFamilyFramingTests(14), DeviceLogicTests = clock/redaction/sync/battery-alert (27), FramingTests(10), HistoricalMetaTests(9), HistoricalStreamsParityTests(1), HistoricalV24Tests(5), InterpreterEnvelopeTests(4), ParityTests(2), PostHooksTests(8), ReassemblerTests incl. 5.0 command/realtime/historical (15), SchemaTests(5), SmokeTests(1), StreamsParityTests(1), StreamsTests(5), ValuesTests(4), Whoop5ChargingTests(3) + ChargingModelTests(6), Whoop5MessagesTests(18).
- `Resources/`: `frames.json`, `golden.json`, `historical_frames.json`, `historical_golden.json`, `streams_golden.json`, `biometric_streams_golden.json`, `whoop5_frames.json` — captured/golden fixtures.

### `Packages/WhoopStore/Sources/WhoopStore`
- `WhoopStore.swift` — actor + open/config. `Database.swift` — migrations v1–v16. `StreamStore.swift` — device upsert + stream inserts. `Reads.swift` — stream reads. `Cursors.swift` — cursor/highwater keys.
- `RawOutbox.swift` — raw batch outbox. `MetricsCache.swift` — `DailyMetric`, cached sleep sessions, corrections. `MetricSeriesStore.swift` — imported metric series. `DerivedStore.swift` — provenance, load, day score state, atomic derived batches.
- `JournalWorkoutAppleCache.swift` — journal, workouts, Apple daily. `TrainingLogStore.swift` — effort, strength sets, workout labels. `AlarmHistoryStore.swift` — append-only alarm events (dedupe) + annotations.
- Tests: AlarmHistoryStoreTests(3), BiometricStreamTests(8), CursorTests(5), DerivedWriteTests(7), InsertTests(4), JournalWorkoutAppleCacheTests(13), LatestSampleTests(1), MetricSeriesStoreTests(11), MetricsCacheTests(10), MigrationTests(5), PruneTests(5), RRSequenceTests + DerivedIsolation(10), RawOutboxTests(6), ReadTests(5), ScaffoldTests(2), SleepCorrectionTests(3), TrainingLogStoreTests(13). `Package.swift`, `Package.resolved`.

### `Packages/StrandAnalytics/Sources/StrandAnalytics`
- Orchestration: `AnalyticsEngine` (per-day results), `IncrementalScorer` (reuse/invalidation), `CausalReplay`, `CausalReference` (causal baselines), `Baselines`, `MetricProvenance` (metric identities/sources).
- HR & load: `HRQuality`, `SupportedHR`, `HRCalibration`, `HRZones`, `ZoneTimeline`, `CardioLoad` (load methods, day/session records), `StrainScorer`, `WorkoutDetector` (episodes, calories), `WorkoutLabels`, `TrainingLog` (RPE, strength volume).
- Sleep & recovery: `SleepStager` (minute grid → stages/episodes), `SleepSessions` (classifier, corrections), `SleepAccounting` (totals, SRI, shortfall), `SleepNeed`, `SleepState`, `SleepVitals`, `HRVAnalyzer`, `RespiratoryRate`, `RecoveryAssessment`, `RecoveryScorer`.
- Alarms: `AlarmEngine` (planning, states), `SmartWake` (evidence buffer, policy, decider, decision record), `AlarmDelivery` (SET→RUN transaction), `AlarmHistory` (summaries, `AlarmStageLookup`). `DayCoverage` (Overview coverage captions).
- Other: `ComparisonEngine`, `CorrelationEngine`, `BehaviorInsights`, `EstimateAccuracy`, `StagingEvaluation`, `DetectionEvaluation`, `StrandAnalytics` (module info).
- Tests: AlarmDeliveryTests(6), AlarmEngineTests(9), AlarmHistoryTests(5), DayCoverageTests(7), SmartWakeTests(11), AnalyticsEngineTests(7), BaselinesTests(11), BehaviorInsightsTests(11), CardioLoadTests = supported HR, load, calibration, day load, episodes, reconciliation, detection eval, awake load (79), ComparisonEngineTests(14), CorrelationEngineTests(11), EstimateAccuracyTests(3), HRVAnalyzerTests(9), HRZonesTests(8), IncrementalScorerTests + WorkoutLabel(23), MeasurementValidityTests(35), RecoveryScorerTests(8), ReplayRegressionTests(11), RespiratoryRateTests(6), SleepNeedTests(4), SleepSessionClassifierTests(25), SleepStagerTests(16), SleepStrainScenarioTests(21), SleepVitalsTests(18), StrainScorerTests(8), WorkoutDetectorTests + HROnly(18), ZoneTimelineTests(4). `Package.swift`, `Package.resolved`.

### `Packages/StrandImport`
- Sources: `ImportCoordinator` (detect ZIP/folder kind), `WhoopExportImporter` (CSV → rows), `CSVParsing` (BOM, headers, WHOOP time), `ImportModels`, `AppleHealthImporter` (XML SAX), `AppleHealthAggregator` (daily aggregates), `StrandImport` (module info).
- Tests: AppleHealthAggregatorTests(28), AppleHealthImporterTests(12), ImportCoordinatorTests(8), WhoopExportImporterTests(12), PlaceholderTests(1), `Helpers.swift`; `Resources/` synthetic `export.xml`, `journal_entries.csv`, `physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`. `Package.swift`, `Package.resolved`.

### `Packages/StrandDesign`
- Sources: `Palette` (tokens, score/zone/stage colors, `ink`/`scoreInk`), `Typography` (`StrandFont`), `Motion` (`StrandMotion`, Reduce Motion), `Components` (`NoopMetrics`, `NoopCard`/`strandSurface`, `StatTile`, `ChartCard`, `ChartFooter`, `SegmentedPillControl`, buttons), `StrandCard`, `StatePill`, `Widgets` (widget grid, progress ring, stage bar), `TrendChart` (`.standard`/`.soft`), `ChartHover` (tooltip/crosshair), `Sparkline`, `Hypnogram`, `RecoveryRing`, `YearHeatStrip`, `ChargingIllustration`, `StrandDesign` (module info).
- Tests: `PlaceholderTests` = StrandDesignTests(25), `WidgetSnapshotTests`(2, need `STRAND_SNAPSHOT_DIR`). `Package.swift`.

### `Tools`
- `ble_probe/` — `Sources/ble_probe/main.swift` scripted BLE research probe; `make_app.sh` wraps it as an app; `bundle/Info.plist`; `Package.swift`.
- `perf_probe/` — `main.swift` repository/scoring timing on a DB copy; `Package.swift`, `Package.resolved`.
- `strain_replay/` — `main.swift` replays strain scoring on a DB copy; `Package.swift`, `Package.resolved`.
- `whoop_re/` — `whoop5_decode.py` standalone 5.0 frame decoder; `test_whoop5_decode.py` (22). `reverse_engineer/analyze_export.py` — export score analysis.

### `docs`
- Guides: `README.md` (index), `ARCHITECTURE.md`, `BUILD.md`, `CONTRIBUTING.md`, `DATA_MODEL.md`, `FEATURES.md`, `LIBRARY.md`, `PRIVACY_SECURITY.md`, `SCREEN_INVENTORY.md`, `ANALYTICS.md`.
- Protocol: `PROTOCOL.md`, `BLE_REVERSE_ENGINEERING.md`, `HR_BROADCAST_RESEARCH.md`, `WHOOP_REVERSE_ENGINEERING.md` (export scoring analysis).
- Measurement reports: `MEASUREMENT_VALIDITY.md`, `SLEEP_SESSIONS.md`, `SLEEP_STRAIN_AUDIT.md`, `SLEEP_RECOVERY_RESEARCH_2026-10-27.md`, `WORKOUT_STRAIN_REPORT.md`, `WORKOUT_STRAIN_RESEARCH_2026-10-30.md`.
- `assets/` — `banner.svg`, `logo.svg`.
- `reverse-engineering/` — `README.md`, `AUDIT.md`, `SAFETY_MATRIX.md`, `COMMAND_REGISTRY.md` + `whoop5_commands.json`, `GATT_MAP.md`, `PROTOCOL_SPEC.md`, `PACKET_TYPES.md`, `SENSOR_STREAMS.md`, `STATE_MACHINE.md`, `ALARM_CAPABILITIES.md`, `EXPERIMENT_LOG.md`, `TEST_RESULTS.md`, `UNKNOWN_CAPABILITIES.md`.
- `reverse-engineering/captures/` — redacted JSONL evidence: `E01-passive-gatt`, `E02-readonly-matrix`, `E04-realtime-hr`, `H01-get-alarm`, `H02-H03-H06-slot0`, `H02b`, `H05-disable`, `H07`.

## 8 · Verification record

Index check (run after file changes; expects no output):

```sh
git ls-files --cached --others --exclude-standard | grep -v -e '^AGENTS.md$' -e 'AppIcon.appiconset/icon_' | while read f; do b=$(basename "$f"); b=${b%.*}; grep -qF "$b" AGENTS.md || echo "unindexed: $f"; done
```

- 2026-11-05 smart wake / delivery / history / coverage / charging: PASS WhoopProtocol 139, WhoopStore 111, StrandAnalytics 388, StrandImport 61, StrandDesign 27 (2 skips), hosted 31, app build. Visually checked (fixture copy, screenshots): Alarms History list (4 statuses), occurrence detail with genuine stage timeline + markers, Settings battery cycle (detached/attached/charging/full/disconnected). Not visually checked: Overview coverage caption, Sleep hero bar note. Not hardware-tested: any alarm delivery path, charging events, pack reply while attached, wake effectiveness.
- 2026-11-03 alarm fixes + Alarms tab: PASS app build; PASS hosted tests (23 incl. new `AlarmControllerTests`). Not run: strap ring/buzz on hardware, visual check of the Alarms tab.
- 2026-11-03 reference rewrite: scanned all 305 first-party files (types, functions, test counts, sizes); verified §3–§5 claims in source (migrations v1–v15, scoring v5, collector/live-HR/battery constants, reconnect interval, charging decode, alarm verification and ring bug, settings keys). Index check: no unindexed files. Docs-only; no builds/tests run.
- 2026-11-03 Trends chart soft restyle: PASS StrandDesign tests (27, 2 skips) and app build. Not visually inspected.
- 2026-11-02 Trends stat bubbles: PASS app build. Not visually inspected.
- 2026-11-02 Bluetooth choice + reconnect: PASS hosted tests (21). No hardware/UI run.
- 2026-11-02 Charging illustration: PASS StrandDesign tests + snapshots, app build. Animation/CPU and hardware charging not observed.

## 9 · Change log (latest 8)

| Date | Change | Checks / remaining |
| --- | --- | --- |
| 2026-11-05 | Smart wake v2 (timestamped windows, duration-based, versioned records); serialized SET→RUN delivery transaction with deadline fallback + slot reconciliation; stream ownership; v16 alarm history + History UI/detail; removed fabricated hypnograms; `DayCoverage` captions; `ChargingModel` (attachment vs charging, freshness, ordering, strict 151 parsing, "likely"). | Tests + build + fixture screenshots; no hardware. |
| 2026-11-03 | Fixed strap double-buzz, same-deadline re-arm after early wake, repeating one-offs; new Alarms tab (`AlarmsView`, renamed from `AlarmCard.swift`) + `NextAlarmLink` on Overview/Sleep. | Build + hosted tests; no hardware/visual check. |
| 2026-11-03 | Rewrote `AGENTS.md`: compact index by purpose, verified state, added charging pipeline, settings keys, known bug, index-check command; dropped stale baseline section. | Path/claim checks only. |
| 2026-11-03 | Soft Trends chart contents (`TrendChart.Style.soft`, `TrendCard` accent, `TrendFooter`, `SoftAxis`, rounded bars). | Tests + build; no visual check. |
| 2026-11-02 | Bubbly `TrendStat` (`symbol`, `accent`, rounded type, hover lift). | Build; no visual check. |
| 2026-11-02 | `BluetoothChoice`, Settings toggle, launch gate, 15-min reconnect watchdog. | Hosted tests; no hardware. |
| 2026-11-02 | `ChargingIllustration` rework; 5.0 charging events + pack-info decode (`Whoop5Charging`, `ChargingReport`). | Design tests; live charging unobserved. |
| 2026-11-02 | Alarm + smart wake (`AlarmEngine`, `AlarmController`), H02–H07 evidence. | `AlarmEngineTests`; fw 50.43.1.0 only. |
