# NOOP — agent reference

Single LLM-maintained entry point: rules, current state, routing and file index. Read §0–§4, then only what you need (`rg -n '^##|^###' AGENTS.md`). Source and tests win over this file and every doc. Paths are repository-relative.

## 0 · Maintenance contract (every program change)

1. `git status --short` first; preserve unrelated work. Read affected source and tests.
2. In the same task update §3 (behavior), §5 (settings), §7 (index: add/move/remove files), §8 (verification) and §9 (log, latest 8 rows). Terse; no source bodies, logs, health data, credentials or signing values.
3. Say what is implemented vs tested vs hardware-confirmed vs unknown. Test files existing ≠ tests passing.
4. Re-run the §8 index check before handing back. One state file only (this one).
5. After a branch is confirmed merged, remove its clean worktree and local branch; remove the remote branch only after the host confirms the PR merged.

## 1 · Snapshot

- Refreshed **2026-11-20** (America/New_York), after the #25 close-out cleanup; v0.2.0 release 2026-11-27. Planning links updated 2026-11-21; R18 + event-120 hold-outs recorded 2026-11-26.
- **NOOP**: local-only macOS companion for WHOOP 4.0/5.0 straps. Internal target/scheme/package prefix **Strand**; bundle `com.noopapp.noop`, product `NOOP.app`, v0.2.0 (2) — first tagged pre-release (`v0.2.0`, GitHub release with zipped app); 1.0 is reserved for the phone + Mac release.
- 397 first-party files (tracked + non-ignored untracked, excluding this file). Size hotspots: `BLEManager.swift` ~2.0k lines, `SleepStager.swift` ~1.3k, `OnboardingWizard.swift` ~1.1k, `TrendSections.swift` ~0.9k — search, don't read whole.
- Test methods (counts in files; pass results are in §8): WhoopProtocol 196, WhoopStore 105, StrandAnalytics 515, StrandImport 14, StrandDesign 40 (2 snapshot tests need `STRAND_SNAPSHOT_DIR`), hosted StrandTests 118 (8 env-gated renders: `NOOP_RENDER_TRENDS/OVERVIEW/HEALTH/SETTINGS/ACTIVITY=1`), Python whoop_re + reverse_engineer.
- Strap research (#25 and #38–#48) is **closed**; outcomes + passive backlog in `docs/reverse-engineering/EVIDENCE_MATRIX.md` §8. Open: #49 functional-age follow-ups.

## 2 · Architecture and routing

```text
AppEntry (NOOP_TEST_HOST? bare host) -> StrandApp -> AppModel (one instance; window + menu bar)
  strap <-> BLEManager (+ Commands, DeviceFamily framing, Reassembler, WhoopProtocol decode)
    realtime -> FrameRouter -> LiveState -> LiveHeartRate / BatteryPresentation -> UI
    frames   -> Collector -> WhoopStore            history -> Backfiller (+ HistoryAckGate, RawHistoryArchive) -> WhoopStore
  WHOOP ZIP/folder -> StrandImport -> WhoopImporter -> WhoopStore
  IntelligenceEngine -> IncrementalScorer -> AnalyticsEngine -> derived rows + provenance
  Repository (prewarmed at launch) -> Overview / Trends / Health / Alarms / Settings / menu bar
  AlarmController -> AlarmPlanner + SmartWakeDecider -> AlarmDeliveryTransaction -> strap (AlarmStrapLink) + Mac notification + alarmEvent
  DataBackup <-> user-selected export / restore-by-replacement
```

| Concern | Start in | Checks |
| --- | --- | --- |
| Lifecycle, scheduling, launch | `Strand/App/AppModel.swift`, `Strand/Data/Repository.swift` | hosted `StrandTests`; fixture launch `[perf]` lines |
| Navigation / screens | `Strand/App/RootView.swift`, `Strand/Screens/Hubs.swift` | app build + visual check |
| Health page | `Strand/Screens/HealthPageView.swift`, analytics `FunctionalAge*.swift`, `HealthMonitor.swift`, `docs/HEALTH_MODELS.md` | `FunctionalAge*Tests`, `HealthMonitorTests` |
| Highlights / check-ins | `HighlightsView.swift`, `CheckInViews.swift`; analytics `DataHighlights.swift`, `CheckIns.swift` | `DataHighlightsTests`, `CheckInInsightsTests`, `CheckInStoreTests` |
| Connect, pair, sync, commands | `Strand/BLE/BLEManager.swift`, `Commands.swift` | WhoopProtocol tests, `docs/reverse-engineering/` |
| Decode / checksums / 5.0 messages | `Packages/WhoopProtocol/Sources/WhoopProtocol/` | Swift fixtures + Python decoder tests |
| Collection / acknowledgement | `Strand/Collect/`, history path in `BLEManager.swift` | `HistoryAckGateTests`, `RawHistoryArchiveTests` |
| Schema / queries | `Packages/WhoopStore/Sources/WhoopStore/Database.swift` + extensions | migration, idempotence, derived-write tests |
| Scores, sleep, load, provenance | `Packages/StrandAnalytics/Sources/StrandAnalytics/` | analytics tests incl. replay regression |
| Imports / backup | `Strand/Data/`, `Packages/StrandImport/` | import + store tests (copied data only) |
| Battery, charging, live HR | `Strand/Device/`, `LiveHeartRate.swift`, `LiveState.swift`, `ChargingModel.swift`, `Whoop5Messages.swift` | `LivePresentationTests`, `CollectorBatteryTests`, `Whoop5ChargingTests`, `PackInfoModelTests` |
| Alarms | `Strand/Alarm/AlarmController.swift`, `AlarmsView.swift`, `AlarmHistoryView.swift`; analytics `AlarmEngine/SmartWake/AlarmDelivery/AlarmHistory.swift` | `AlarmControllerTests` (fake link) + analytics alarm suites |
| Shared UI | `Packages/StrandDesign/Sources/StrandDesign/` | StrandDesign tests / snapshots |

Packages (Swift tools 5.9; declare macOS 13 / iOS 16; **only a macOS app target exists**): `WhoopProtocol` (no deps; schema JSON) · `WhoopStore` → WhoopProtocol, GRDB (≥6.0.0, resolved 6.29.3) · `StrandAnalytics` → WhoopProtocol, WhoopStore · `StrandImport` → WhoopProtocol, WhoopStore, ZIPFoundation (≥0.9.0, resolved 0.9.20) · `StrandDesign` (SwiftUI). Tools: `ble_probe` → WhoopProtocol; `perf_probe`, `strain_replay` → analytics + store + protocol; Python is stdlib only.

## 3 · Current behavior (verified against source 2026-11-20)

### App and UI

- Sprint 2 plans coverage-aware activity detail. Sprint 3 assigns collection/display to iPhone and storage/scoring to Mac, superseding phone scoring for the initial release.
- Planned only: `docs/sprints/PHONE_MAC_ARCHIVE.md` outlines an iPhone collector, local Mac archive, compact phone history and safe pruning, with future read-only API gateway boundaries; milestones 7/8 and issues #76–#81 track delivery, #82 is future backlog. None is implemented.

- `AppEntry` checks `NOOP_TEST_HOST` (tests get no BLE/store). **Release builds** compile out testing/diagnostic paths via `LaunchMode.diagnostics` (Debug or `NOOP_DIAGNOSTICS` only): test host, fixture launch + `[perf]`, connection log + unified-log lines, ops-counter files, live R–R archive, raw and research capture (Settings row hidden). Undecoded-history archive stays. Single strap identity `my-whoop`; derived rows `my-whoop-noop`.
- **Launch:** `AppModel.init` calls `Repository.prewarm()`, which opens the store once and reads the dashboard rows on a detached task while the first window is built; all `ensureStore()` callers share that open (before: 4 concurrent opens, each running the migrator, and the first read waited ~250 ms for the main actor). Then: refresh, wait ~6 s, apply version rescoring, analyze every 15 min. New chunks: UI refresh throttled ~2 s; scoring after ~8 s quiet; scoring always on a detached utility task.
- **Navigation** (floating pill, ⌘1–5): Overview (`TodayView`), Trends (`TrendsHub`: Scores, Sleep, Vitals, Activity, Highlights), Health (`HealthPageView`), Alarms (`AlarmsView`), Settings (`SettingsHub`: General, Data, Advanced). Onboarding overlays the shell on first launch; live strap is a sheet (Done, Esc, or a click outside closes it — `DismissOnOutsideClick`).
- **Overview:** week strip; recovery/sleep/strain detail in place; `HeartRateDayCard` (HR runs broken at gaps > 5 min and activation strip on one `DayTimeAxis`, DST-aware; hatched no-data, dashed upcoming; summary + insights; `DayCoverage` caption — warns only for ≥ 1 h and ≥ 10 % unexplained gaps or > 2 h unsynced, strap-reported off-wrist time explained, never inferred); check-in card; compact `SyncProgressStrip`. Strain detail has a **Steps** tile from the 5.0 strap counter (accepted as accurate by owner decision 2026-11-27, #84; no further validation) (`Repository.strapSteps` → `StepCounterSample.window`: increases only, post-reset value counted, activity time only over synced seconds, "≥ N" unless complete, no tile without rows, never 0). **Walking & running** tile beside it (#83, `ActivityCoverage`): activity-code 1/2 time over synced seconds only, shown with synced time of the elapsed day (23/25 h on DST days), gaps listed, "≥" for any gap or a sync lag past the 30-min grace (`DayCoverage.syncGraceSeconds`); walking/running moved out of the steps tile. Both tiles give VoiceOver spoken text (`DetailTile.spoken`: "at least", full unit words, no "·").
- **Trends:** daily series are UTC-midnight keyed and drawn/labelled in UTC; lines break at missing days (`maxGap` 1.5 d); `TrendCardGrid` equal-height rows; `YearHeatStrip` walks every local day and scrolls when narrow; quiet `SegmentedPillControl` range bar; completed-period comparisons only (missing ≠ zero). Activity = day strain, Z1–Z5 zone totals, workouts per week. Sleep adds `SleepPerformance` (`noop-sleep-perf-v1`). Vitals split imported wrist °C from NOOP skin-temperature change.
- **Highlights:** 1M/3M/All Time over completed local days, one source at a time (WHOOP import or NOOP), records, streaks (gaps end streaks), ties → most recent + count, "View day" sheet.
- **Check-ins:** optional morning/evening sessions from `CheckInLibrary` (17 prompts), Yes/No/Not sure/Skip, one entry per local date + session; insights need ≥ 5 per group, |d| < 0.2 SD = no clear difference, association wording; optional one-off reminders (7 days, snooze 30 min). Never read by scoring.
- **Health:** functional-age hero (#49, experimental, `noop-functional-age-v1-groups`: one contributor per group — measured VO₂max ≤ 2 y old else steps (still excluded: needs complete days, not just counter accuracy), resting HR, sleep duration; birth date required; pace = mean of 8 weekly 30-day impacts, display-only because the 6-month projection lost to "no change" in replay; < 18 shows "<18"). Lab biological age stays unavailable. VO₂max card (`vo2-hr-ratio-v1`, unvalidated). Health Monitor (RR, SpO₂, RHR, HRV, skin-temp change vs causal personal ranges: 30-day lookback, ≥ 14 prior nights, never all-clear with missing/stale). HRV position (`PersonalRangePosition`: within 1 robust SD of median = typical). Stress Monitor = HR activation timeline, "not a stress score".
- **Recovery detail:** HRV and skin temperature resolved **per field** (`Repository.fieldReading`), value/baseline/sparkline from that field's own source; Nightly maximum HRV (max quality-gated 5-min RMSSD over the NOOP main sleep, ≥ 6 windows; never scored).
- **Alarms tab:** next-alarm hero (countdown, smart window, delivery pill, "I'm awake — skip" within 12 h before the deadline), editor, per-occurrence History with genuine NOOP stage timeline.
- **Settings General:** strap hero (status pill, `StrapBatteryPanel`, Reconnect/Disconnect), grouped rows: Connection, Battery alerts, Profile (`ProfileCard`: age derived from optional birth date, measured VO₂max), Data (research capture, recalculate), Check-ins, About. Data = WHOOP import, comparison, backup/restore. Advanced = recovery diagnostics, metric explorer (only metrics with stored WHOOP-import data), live strap.
- **Battery** (`BatteryPresentation`): low < 20 %, medium < 35 %, stale when disconnected or > 20 min; three facts (strap battery / charging pack / charging), each with source; "Charge" capsule only for a fresh low reading off the charger. `ChargingIllustration` draws the pack only while charging/full; brief sweep then still; no motion under Reduce Motion.
- Not present: Apple Health import (removed from the code 2026-11-20; the empty `appleDaily` table stays in the schema), mobile app, cloud, coaching, numerical stress or biological-age scores.

### BLE, charging and collection

- `BLEManager`: scan → connect → discover → bond → subscribe → per-characteristic reassembly → decode/route/store/sync; `DeviceFamily` picks 4.0 vs 5.0 GATT/framing. Strap alarm commands go only through `AlarmStrapLink` (the old direct arm/disable/test-buzz helpers were removed).
- `BluetoothChoice` (`noop.bluetoothChoice`): no `CBCentralManager` at launch while declined unless macOS reports allowedAlways. Ad-hoc rebuilds re-prompt; stable signing needs `Local.xcconfig`.
- Liveness: keep-alive 30 s; bounce only after 120 s silence while realtime is wanted, > 20 min when idle. Reconnect: 3 s rescan after an unintended disconnect + 15-min watchdog (not hardware-tested).
- Realtime stream owners (`live-sheet`, `menu`, `alarm`, `ui`); stops when the last owner releases. `LiveHeartRate`: ~10 s median, 30–220 bpm.
- **Charging** (`ChargingModel`): attachment and activity are separate facts with source/time/connection. 5.0 event 3 byte 9 bit 0 = charging (fw 50.43.1.0, every ~30 s while charging); event 29 u16 @6 = soc × 10; 21 = attached, 22 = detached; event 117 byte 1 = 4 → full. Pack info 151 sent with `[01]`: presence 1 → attached, revision + zeros → absent (layout CONFIRMED C06b); a reply never overrides a newer event or one < 60 s before its request. Facts carry over a reconnect as "last reported", expire after 3 h; "Charging likely" (≥ 3 pt rise over ≥ 10 min) never alerts. Battery poll on connect then ≤ every 15 min, skipped when a live soc arrived.
- `Collector` flushes at 64 frames / 30 s (pre-clock cap 4096). `Backfiller` persists decoded history (+ optional raw/research) and cursor **before** ack; every saved chunk is acked. `HistoryAckGate`: a repeat END while saving is never acked; nothing after a refused chunk. Undecodable 5.0 history → `RawHistoryArchive` (`OpenWhoop/undecoded-history`, fsync, never pruned; failure blocks ack). Raw outbox `rawBatch` is append-only (the server-sync pruning/cursors were dead code, removed 2026-11-20).
- Research capture (`ResearchCapture`, user-started, ≤ 7 days / 400 MB): full decoded type-47 frames → `OpenWhoop/research-history`, byte-identical repeats dropped, write failure blocks ack. Live acceptance A01 passed.
- Clocks: `DeviceClock`/`ClockCorrelation`/`ClockPolicy`. 5.0 strap clock drifts ~+1.4 s/day; `ClockResyncPolicy` re-sets it after a pull when ≥ 1 s off (≤ 1/24 h; 1 h when ≥ 30 s off) via a token-gated SET_CLOCK + read-back (observed live). Stored 5.0 timestamps stay strap time (data before 2026-11-18 14:05 keeps a ~40 s offset).
- Ops counters (`OpsCounterBook` + `OpsCounterStore`): per-day command/link/pull counts in `OpenWhoop/ops-counters/yyyy-MM-dd.json`, running since 2026-11-19. A poweredOff is classified at the next poweredOn (`PowerOffClassifier`): `systemSleep` if the Mac slept in between, else `bluetoothOff` (R86; older files count sleeps as `bluetoothOff`).
- `Whoop5RealtimeTally` + `OpenWhoop/live-rr` archive keep live packet-40 evidence; live R–R = ms (CONFIRMED). The app does not use live R–R.
- Hardware work: read `docs/reverse-engineering/SAFETY_MATRIX.md` and `COMMAND_REGISTRY.md` first. Evidence is scoped to WHOOP 5.0 fw 50.43.1.0 / hw WG50_r52. Firmware: **no-go** (#47).

### Storage, imports and scoring

- `StorePaths`: Application Support `OpenWhoop/whoop.sqlite` (sandbox container). `WhoopStore` is an actor over GRDB (`DatabaseQueue`, WAL, 5 s busy timeout); Repository and BLE hold separate handles.
- Schema **v19** (`WhoopStoreInfo.schemaVersion` = 19, fixed 2026-11-20; was a stale 15). Add migrations, never edit applied ones. Key: v10 RR sequence, v11 provenance, v12 load, v13 training logs, v14 labels + incremental state, v15 sleep sessions + corrections, v16 alarm history, v17 check-ins, v18 `skinTempSample.unit`, v19 `stepCounterSample`.
- 5.0 history record v0x12: HR, RR, gravity, skin temperature (payload 65 u16 ÷ 100 °C, unit `centi_celsius`), step counter (49 u16) + activity code (55 u8: 2 = run CONFIRMED, 1 walk / 0 still SUPPORTED), stored in one transaction. Step counter resets 1 s after alarm rings (2 mornings) and once during a removal; never at midnight.
- `WhoopImporter` → idempotent upserts of cycles (with declared sleep), sleeps, workouts, journal, metric series. `DataBackup` = DB export + restore by replacement (relaunch).
- Scoring: `IntelligenceEngine.scoringVersion = 5`; `IncrementalScorer` reuses unchanged days and re-scores on algorithm/config/source change. Versions in `algorithmKey`: `nap-evidence-v2`, `sessions-v2`, `sleep-core-fragments-v2`, `wrist-events-v1`, `skin-temp-night-v2`. Confident sleep/naps excluded from load.
- Sleep detection (`sleep-core-fragments-v2`): quiet runs are admitted as fragments on lenient bars (quiet ≥ 0.80, HR dip ≥ 0.05); joined spans are judged on the strict main/nap bars; the final-wake extension runs from the span end and from the last strict fragment's end (later wins).
- Sleep: minute evidence → episodes → classified sessions (primary / interrupted-primary / nap / uncertain) → corrections (survive rescoring) → accounting, vitals, recovery. Low-evidence nap candidates are "uncertain" until confirmed. Hypnograms only from genuine stage segments.
- Skin-temperature change: night median over asleep stages minus off-wrist time (≥ 1,800 samples, ≥ 50 % coverage) vs median of earlier nights (≥ 5 prior). Wrist wear from events 10/9 (off/on) affects temperature and coverage only.
- Missing ≠ zero/awake/sleep. `StagingEvaluation`/`DetectionEvaluation` do not establish clinical accuracy.

### Alarms

- `AlarmEngine` (planning, DST), `SmartWake` (`smart-wake-v2-hr`: 20-s windows, 60 s sustained, threshold 0.45→0.35; experimental, synthetic traces only). Delivery: SET(now+60) → RUN → haptics event within 40 s = "strap reported"; failures re-arm the deadline and the Mac rings. Deadline arm reads before writing (writes 49 → 2/day, CONFIRMED). Follow-up buzzes every 3 min (≤ 3). "I'm awake — skip" is explicit only; nothing auto-suppresses an alarm.
- On-device alarm confirmed only for fw 50.43.1.0. Smart wake needs the Mac awake, NOOP running and connected.

## 4 · Known issues and limits

- On battery the Mac dark-wakes ~every 36 s while asleep: the strap re-sends an LE connection-parameter request that macOS leaves pending during dark wake, and each repeat wakes the Mac (R86). Each sleep/wake gave a CoreBluetooth poweredOff/poweredOn + NOOP reconnect, which builds before R86 counted as `bluetoothOff` (~1,100–1,800/day since 11-22, when the Mac began sleeping 15–21 h/day). Counting fixed (`systemSleep`); the wakes themselves are not (releasing the link at sleep needs a hardware trial).
- Lost-record holes: whole seconds missing from every history stream in 30–61 s runs (264 since 11-17, R85); not removals, cause unknown.
- No CI; local test evidence only (§8). `BLEManager` CoreBluetooth paths (ack wiring, stream ownership, counters) are code-reviewed, not unit-tested. Alarm delivery is tested against a fake link.
- Experimental, unvalidated: walking/running time, skin-temperature change (no reference thermometer), VO₂max, functional age/pace, nap detection, smart-wake thresholds, health-monitor and check-in thresholds.
- Not visually checked: several Settings/Health/Overview states in dark mode, VoiceOver, keyboard, Reduce Motion (owner deferred). The window's minimum is 1000 pt, so 760/420 pt exist only in test renders. Seen, not changed: scrolled content passes under the floating battery badge (it can cover the zone bar's right end) and the window buttons.
- Stage source label shows the current scoring version; rows don't store their own.
- `Tools/whoop_re/fixtures/whoop5_frames.json` is untracked (`.gitignore` `Fixtures/` matches case-insensitively on macOS), so `test_whoop5_decode.py` fails in fresh clones.
- Older dated reports live in `docs/archive/` and describe superseded behavior. `ALARM_CAPABILITIES.md` rows predating H02b/H04/H07 are stale.
- A stash `stash@{0}` (issue/46 docs backup) exists in the original checkout; contents not reviewed.

## 5 · Build, configuration, runtime switches

- Phone/archive sprint adds no current target, setting or permission; proposed configuration is gated in `docs/sprints/PHONE_MAC_ARCHIVE.md`; future API gateways remain opt-in and out of sprint scope.

- `project.yml` (XcodeGen) is canonical and regenerates `Info.plist` (version from `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`); `Strand.xcodeproj` is generated and ignored. macOS 13+, Swift 5 mode, minimal strict concurrency. BLEManager's main-actor delegate warnings are expected.
- Entitlements: sandbox, Bluetooth, user-selected read/write. `Signing.xcconfig` optionally includes ignored `Local.xcconfig` (template `Local.xcconfig.example`).
- GitHub `main` protection: PR required, resolved conversations, linear history, admins included, no force-push/deletion; no required checks.

```sh
xcodegen generate
swift test --package-path Packages/<WhoopProtocol|WhoopStore|StrandAnalytics|StrandImport|StrandDesign>
python3 -m unittest discover -s Tools/whoop_re -p 'test_*.py'
python3 -m unittest discover -s Tools/reverse_engineer -p 'test_*.py'
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/noop-derived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
NOOP_FIXTURE_STORE=<db copy> /tmp/noop-derived/Build/Products/Debug/NOOP.app/Contents/MacOS/NOOP   # prints [perf] store open / launch-to-content / refresh
```

StrandAnalytics tests take ~3.5 min. Tools that open `WhoopStore` can migrate the DB: use a SQLite-backup copy (`sqlite3 src ".backup dst"`), never the live file.

| Switch / key | Meaning |
| --- | --- |
| `LaunchMode.diagnostics` / `NOOP_DIAGNOSTICS` | True in Debug; Release opts in only with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=NOOP_DIAGNOSTICS` (fixture timing). Gates every row below that is test/diagnostic |
| env `NOOP_TEST_HOST` | Isolated test host (set by scheme; diagnostic builds) |
| env `NOOP_FIXTURE_STORE` | DB **copy** path; CoreBluetooth off; prints launch timings (diagnostic builds) |
| `-noop.fixture.tab trends\|health\|alarms\|settings`, `-noop.fixture.live YES`, `-noop.fixture.battery cycle\|charging`, `-noop.fixture.alarmHistory YES`, `-noop.fixture.alarmDetail YES`, `-noop.fixture.detail strain\|sleep\|recovery`, `-noop.fixture.day yyyy-MM-dd`, `-noop.fixture.scrollTo <view id>` (e.g. `strain-tiles`), `-noop.fixture.width <pt>` (≥ 1000, the window minimum), `-noop.fixture.appearance dark\|light` | Fixture-only launch options |
| `noop.onboarded`, `scoringVersionApplied` (5) | First-run done; applied scoring migration |
| `noop.bluetoothChoice` | `undecided`/`allowed`/`declined` |
| `noop.clock.autoResync`, `noop.clock.lastResyncAt` | Daily 5.0 strap-clock re-sync (default on); last attempt |
| `noop.research.fullHistoryCapture` | Active/ended research capture (JSON) |
| `enableRawCapture`, `listenToHRBroadcast` | Raw capture (off); standard HR subscription (off). `noop.keepDataOnStrap` was removed; a stored value is ignored |
| `noop.deviceInfo`, `lastSyncedAt`, `backfillLastAt`, `hrBroadcastLastSet` | Cached DIS info; sync timestamps |
| `alarm.specs`, `alarm.capabilities`, `alarm.fired`, `alarm.earlyAttempted`, `alarm.armedTargets`, `alarm.ownsStrapAlarm`, `alarm.followUp` | Alarm state |
| `profile.age/sex/heightCm/weightKg/hrMaxOverride`, `profile.birthDate`, `profile.vo2max/vo2maxMethod/vo2maxDate` | `ProfileStore` |
| `notify.batteryLow/batteryFull/batteryAlertState` | `BatteryMonitor` |
| `noop.trends.segment`, `noop.settings.segment`, `noop.live.detailsOpen`, `noop.highlights.range`, `noop.highlights.source` | UI state |
| `checkin.morning.enabled/prompts/reminder`, `checkin.evening.*`, `checkin.inviteDismissed` | Check-ins |

## 6 · Folder boundaries

| Path | Treatment |
| --- | --- |
| `Strand/`, `Packages/*/{Sources,Tests}`, `StrandTests/`, `Tools/`, `docs/` | First-party; indexed in §7 |
| `docs/archive/` | Historical reports; not maintained, not evidence of current behavior |
| `Strand.xcodeproj/`, `Packages/*/.build/`, `Tools/*/.build/`, `.swiftpm/`, DerivedData | Generated; don't edit |
| `.local/ai-prompts/` | Ignored historical prompt notes |
| `Local.xcconfig`, SQLite files, private exports, secrets | Ignored; never copy contents here |

## 7 · File index

Format: `file` — purpose. Tests list `Suite(methods)`.

### Root
- `README.md` — product overview, build/run. `ATTRIBUTION.md` — credits. `DISCLAIMER.md` — independence notice. `project.yml` — XcodeGen. `Signing.xcconfig` / `Local.xcconfig.example` — signing. `.gitignore` — generated/personal exclusions.

### `Strand/App`
- `StrandApp.swift` — `AppEntry` test-host gate; window + menu-bar scenes. `AppModel.swift` — owns BLE, repository (prewarm), scoring schedule, imports, battery monitor, alarms. `RootView.swift` — `NavItem`/`FloatingNav`, `LiveSheet` (+ `DismissOnOutsideClick`), `BatteryBadge`. `ContentView.swift` — shell + onboarding overlay.

### `Strand/BLE`
- `BLEManager.swift` — CoreBluetooth central, 4.0/5.0 decode, history offload + ack, charging/battery/alarm link, reconnect, polling. `Commands.swift` — allowed command set. `FrameRouter.swift` — realtime → `LiveState`. `LiveState.swift` — published live status. `LiveHeartRate.swift` — smoothed HR. `StandardHeartRate.swift` — 0x2A37 parser. `BackfillPolicy.swift` — sync rate limit. `StuckStrapDetector.swift` — data-vs-frontier check. `BluetoothChoice.swift` — access choice, reconnect interval.

### `Strand/Collect`
- `Collector.swift` — frame buffer/flush. `Backfiller.swift` — persist-then-ack. `HistoryAckGate.swift` — which ENDs may be acked. `RawHistoryArchive.swift` — undecoded/research/live-rr JSONL. `ResearchCapture.swift` — bounded capture policy. `OpsCounterStore.swift` — ops-counter day files. `ClockCorrelation.swift`, `ClockPolicy.swift` (+ `ClockResyncPolicy`). `RawCaptureWindow.swift` — bounded raw capture. `StorePaths.swift` — DB path, `LaunchMode`.

### `Strand/Data`
- `Repository.swift` — UI read model (prewarm, merged days/sleep/workouts, field provenance, steps). `IntelligenceEngine.swift` — scoring orchestration. `CheckInSettings.swift` — check-in prefs + reminders. `WhoopImporter.swift` — export → store. `DataBackup.swift` — export/restore. `MetricCatalog.swift` — explorer metrics (WHOOP import keys). `Profile.swift` — `ProfileStore`.

### `Strand/Device`, `Strand/Alarm`, `Strand/MenuBar`, `Strand/Onboarding`
- `BatteryPresentation.swift`, `BatteryMonitor.swift`, `StrapBatteryPanel.swift`. `AlarmController.swift` — alarm runtime + `AlarmStrapLink`/`AlarmNotifying`/`AlarmHistorySink`. `MenuBarContent.swift`. `OnboardingWizard.swift`.

### `Strand/Screens`
- `TodayView.swift` (Overview), `HeartRateDayChart.swift` (shared-axis HR + activation), `TodayDetailViews.swift` (recovery/sleep/strain detail, steps tile, `DayMath`).
- `TrendsView.swift` (Scores), `TrendSections.swift` (Sleep/Vitals/Activity, shared trend UI), `HighlightsView.swift`, `Hubs.swift` (`TrendsHub`, `SettingsHub`, `AdvancedSettings`).
- `HealthPageView.swift` (Health tab), `ActivationViews.swift` (activation palette/load, `VO2MaxCard`), `HealthView.swift` (HR/vitals detail).
- `CheckInViews.swift`, `ScreenScaffold.swift` (+ `ComingSoon` empty state), `SleepView.swift`, `SleepSessionsCard.swift` (+ `AdjustSleepSheet`), `SleepNeedCard.swift`, `WorkoutsView.swift`, `WorkoutDetailView.swift`.
- `SettingsView.swift`, `AlarmsView.swift`, `AlarmHistoryView.swift`, `DataSourcesView.swift`, `LiveView.swift`, `LiveStatusView.swift`, `PairingResetNotice.swift`, `MetricExplorerView.swift`, `RecoveryDiagnosticsView.swift`, `RecentCyclesCard.swift`.

### `Strand/Resources`
- `Info.plist`, `Strand.entitlements`, `Assets.xcassets/` (`Contents.json`, `AppIcon.appiconset/Contents.json` + icons).

### `StrandTests` (hosted, 118)
- `TrendsAuditTests.swift` = `TrendWindowTests`(9) + `TrendsRenderTests`(4, env). `HeartRateCardRenderTests`(1, env), `ActivationLoadTests`(3), `SleepPairingImportTests`(2), `StrapStepsTests`(4), `ActivityTileTests`(2, 1 env), `FieldProvenanceTests`(2), `AlarmControllerTests`(35), `NightlyMaxHRVTests`(6), `BluetoothChoiceTests`(5), `CollectorBatteryTests`(2), `LivePresentationTests`(16), `HistoryAckGateTests`(5), `FunctionalAgeRenderTests`(1, env), `FunctionalAgeInputsTests`(1), `ClockResyncPolicyTests`(4), `RawHistoryArchiveTests`(6), `ProfileCardRenderTests`(1, env) + `ProfileStoreAgeTests`(1), `OutsideClickDismissTests`(4), `StrandSmokeTests`(1).

### `Packages/WhoopProtocol`
- Sources: `DeviceFamily`, `Framing` (CRC, `Reassembler`), `Interpreter`, `Schema` (+ `Resources/whoop_protocol.json`), `Values`, `PostHooks`, `Streams` (incl. 5.0 realtime/historical), `HistoricalStreams`, `HistoricalMeta`, `OpsCounters`, `Whoop5RealtimeTally`, `Whoop5ConfigRead`, `Whoop5Messages` (+ `Whoop5Charging`, `Whoop5Alarm`), `ChargingModel`, `BatteryPolicy`, `DeviceClock`, `SyncCoverage`, `Redaction`, `WhoopProtocol` (schema URL).
- Tests: BiometricStreamsParityTests, DeviceFamilyFramingTests, DeviceLogicTests, FramingTests, HistoricalMetaTests, HistoricalStreamsParityTests, HistoricalV24Tests, InterpreterEnvelopeTests, ParityTests, PostHooksTests, ReassemblerTests (+ Whoop5RealtimeTallyTests), SchemaTests, SmokeTests, StreamsParityTests, StreamsTests, ValuesTests, Whoop5ChargingTests + ChargingModelTests + PackInfoModelTests, Whoop5MessagesTests, Whoop5ConfigReadTests, OpsCountersTests. `Resources/`: `frames.json`, `golden.json`, `historical_frames.json`, `historical_golden.json`, `streams_golden.json`, `biometric_streams_golden.json`, `whoop5_frames.json`.

### `Packages/WhoopStore`
- Sources: `WhoopStore` (actor, `WhoopStoreInfo`), `Database` (migrations v1–v19), `StreamStore`, `Reads`, `Cursors`, `RawOutbox` (append-only raw batches), `MetricsCache`, `MetricSeriesStore`, `DerivedStore`, `JournalWorkoutAppleCache` (journal + workouts; file name is historical), `TrainingLogStore`, `AlarmHistoryStore`, `CheckInStore`. `Package.swift`, `Package.resolved`.
- Tests: AlarmHistoryStoreTests, CheckInStoreTests, BiometricStreamTests + SkinTempUnitTests, CursorTests, DerivedWriteTests, InsertTests, JournalWorkoutAppleCacheTests, LatestSampleTests, MetricSeriesStoreTests, MetricsCacheTests, MigrationTests, RRSequenceTests, RawOutboxTests, ReadTests, ScaffoldTests, SleepCorrectionTests, TrainingLogStoreTests.

### `Packages/StrandAnalytics`
- Orchestration: `AnalyticsEngine`, `IncrementalScorer`, `CausalReplay`, `CausalReference`, `Baselines`, `MetricProvenance`, `TrendPeriodComparison`.
- HR & load: `HRQuality`, `SupportedHR`, `HRCalibration`, `HRZones`, `ZoneTimeline`, `CardioLoad`, `StrainScorer`, `WorkoutDetector`, `WorkoutLabels`, `TrainingLog`.
- Sleep & recovery: `SkinTemperature`, `WristWear`, `SleepStager`, `SleepSessions`, `SleepAccounting`, `SleepNeed`, `SleepState`, `SleepVitals`, `HRVAnalyzer`, `RespiratoryRate`, `RecoveryAssessment`, `RecoveryScorer`.
- Alarms: `AlarmEngine`, `SmartWake`, `AlarmDelivery`, `AlarmHistory`. Day UI: `DayCoverage`, `DayTimeAxis`, `ActivityCoverage` (walking/running vs synced time, #83).
- Health/highlights/check-ins: `FunctionalAgeSnapshot`, `FunctionalAgeReplay`, `FunctionalAge`, `FitnessEstimates` (`VO2MaxEstimate`, `SleepPerformance`, `SleepPairing`), `PersonalRangePosition`, `HealthMonitor`, `DataHighlights`, `CheckIns`.
- Other: `ComparisonEngine`, `CorrelationEngine` (metric explorer), `EstimateAccuracy` (Data comparison), `StagingEvaluation`, `DetectionEvaluation` (evaluation harnesses), `StrandAnalytics` (module info).
- Tests: ActivityCoverageTests, DayTimeAxisTests, AlarmDeliveryTests, AlarmEngineTests, AlarmHistoryTests, CheckInInsightsTests, DataHighlightsTests, DayCoverageTests, HealthMonitorTests, PersonalRangePositionTests, FitnessEstimatesTests, FunctionalAgeTests, FunctionalAgeSnapshotTests, FunctionalAgeReplayTests, SmartWakeTests, AnalyticsEngineTests, BaselinesTests, CardioLoadTests, ComparisonEngineTests, CorrelationEngineTests, EstimateAccuracyTests, HRVAnalyzerTests, HRZonesTests, IncrementalScorerTests, MeasurementValidityTests, RecoveryScorerTests, ReplayRegressionTests, RespiratoryRateTests, SleepNeedTests, SleepSessionClassifierTests, SleepStagerTests, SleepStrainScenarioTests, SkinTemperatureTests, WristWearTests, SleepVitalsTests, StrainScorerTests, TrendPeriodComparisonTests, WorkoutDetectorTests, ZoneTimelineTests. `Package.swift`, `Package.resolved`.

### `Packages/StrandImport`
- Sources: `ImportCoordinator` (WHOOP export entry), `WhoopExportImporter`, `CSVParsing`, `ImportModels`. Tests: ImportCoordinatorTests, WhoopExportImporterTests, `Helpers.swift`; `Resources/` synthetic `journal_entries.csv`, `physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`. `Package.swift`, `Package.resolved`.

### `Packages/StrandDesign`
- Sources: `Palette`, `Typography`, `Motion`, `Components` (+ `SectionTabBar`, `strandFocusRing`, `SegmentedPillControl`), `StrandCard`, `StatePill`, `Widgets`, `TrendChart`, `ChartHover`, `Sparkline`, `Hypnogram`, `RecoveryRing`, `YearHeatStrip`, `ChargingIllustration`, `ZoneSpectrum`, `StrandDesign`. Tests: `PlaceholderTests` (25), `ZoneSpectrumTests`, `TrendChartGapTests`, `WidgetSnapshotTests` (env). `Package.swift`.

### `Tools`
- `ble_probe/` — `Sources/ble_probe/main.swift` read-only research probe (`--passive`, `--pack-rev1`, `--c08 --c08-approved`, `--k01 --k01-approved`; SET twins hard-blocked); `make_app.sh`; `bundle/Info.plist`; `Package.swift`.
- `perf_probe/` — `main.swift` repository/scoring timing on a DB copy (`--score`, `--hash`, `--fa-replay`, `--sleepperf`); `Package.swift`, `Package.resolved`. `strain_replay/` — `main.swift` strain replay; `Package.swift`, `Package.resolved`.
- `whoop_re/` (stdlib, read-only on copies) — `whoop5_decode.py` + `test_whoop5_decode.py` (needs untracked fixture) + `test_whoop5_realtime.py`; `step_walk_check.py` + `test_step_walk_check.py`; `rr_unit_audit.py` + `test_rr_unit_audit.py`; `live_rr_audit.py` + `test_live_rr_audit.py`; `research_archive_check.py` + `test_research_archive_check.py`; `strap_clock_offset.py`, `step_reset_scan.py`, `ppg_burst_check.py`, `event120_check.py` (+ `--holdout`) with `test_offline_checks.py`; `r18_field_inventory.py` + `test_r18_field_inventory.py`; `rewarm_check.py` + `test_rewarm_check.py` (re-warming after re-wear, nightly sensitivity); `ops_metrics.py` + `test_ops_metrics.py`.
- `reverse_engineer/` — `analyze_export.py` (export score analysis), `sleep_performance_eval.py` + `test_sleep_performance_eval.py`.

### `docs`
- `sprints/DATA_FUNCTIONALITY.md` — issue review and Sprint 2. `sprints/SPRINT_3_PHONE_MAC.md` — foreground LAN sync and Mac analysis.
- `sprints/PHONE_MAC_ARCHIVE.md` — planned iPhone collector/local archive sprint, ordered work packages, acceptance gates, GitHub tracking and future API gateway boundaries.
- Current: `README.md` (index), `ARCHITECTURE.md`, `BUILD.md`, `CONTRIBUTING.md`, `PRIVACY_SECURITY.md`, `PROJECT_PROGRESS.md`, `PROTOCOL.md` (wire format), `MEASUREMENT_VALIDITY.md`, `SLEEP_SESSIONS.md`, `NAP_DETECTION.md`, `HEALTH_MODELS.md`. `assets/` — `banner.svg`, `logo.svg`.
- `archive/` (historical): `SLEEP_STRAIN_AUDIT.md`, `SLEEP_RECOVERY_RESEARCH_2026-10-27.md`, `WORKOUT_STRAIN_RESEARCH_2026-10-30.md`, `WORKOUT_STRAIN_REPORT.md`, `WHOOP_REVERSE_ENGINEERING.md`, `HR_BROADCAST_RESEARCH.md`, `BLE_REVERSE_ENGINEERING.md`, `AUDIT.md`, `TEST_RESULTS.md`, `UNKNOWN_CAPABILITIES.md`.
- `reverse-engineering/` — `README.md`, `EVIDENCE_MATRIX.md` (evidence levels, firmware review, **#25 closure + backlog §8**), `CAPABILITY_MATRIX.md`, `RESEARCH_CAPTURE.md`, `SAFETY_MATRIX.md`, `COMMAND_REGISTRY.md` + `whoop5_commands.json`, `GATT_MAP.md`, `PROTOCOL_SPEC.md`, `PACKET_TYPES.md`, `SENSOR_STREAMS.md`, `STATE_MACHINE.md`, `ALARM_CAPABILITIES.md`, `EXPERIMENT_LOG.md`.
- `reverse-engineering/captures/` — redacted JSONL: `E01-passive-gatt`, `E02-readonly-matrix`, `E04-realtime-hr`, `H01-get-alarm`, `H02-H03-H06-slot0`, `H02b`, `H05-disable`, `H07`, `C02a-wear-off-on`, `C06a-C07-afe-pack-reads`, `C06b-pack-reads`, `C08-config-reads`, `K01-set-clock`.

## 8 · Verification record

What is established, and how (older per-change rows are in git history and the merged PRs):

- **2026-11-21 sprint plan:** documentation only; source compared for target, storage, cursor and backup boundaries. Path/link, whitespace and §8 index checks passed; GitHub milestones 7/8 and issues #76–#82 created. No app tests or hardware checks run; phone/sync/retention and API gateway behavior remain unimplemented.

- **2026-11-26 HO1:** frozen R18 (`r18_field_inventory.py --since 2026-11-20`, 481,897 records) and event-120 (`event120_check.py --holdout`, 83 reports) hold-outs run on a research-history copy and a SQLite-backup copy: every frozen rule passed / 3 of 3 candidates SUPPORTED (EXPERIMENT_LOG HO1). Docs only; no app change, no tests run.

- **2026-11-22 T04:** passive read of a SQLite-backup copy: first nightly skin-temperature change (−0.61 °C, night ending 11-22) and a 3-min in-night removal with no samples while off (EXPERIMENT_LOG T04). Docs only; no tests run.

- **Hardware-confirmed (fw 50.43.1.0):** on-device alarm + read-back (H04); alarm writes 2/day after read-before-write; event 3 charging bit; 151 `[01]` pack layout and 117 = 4 full (C06b); wrist events 10/9 (C02a, T03); 121/128 read layout (C08); SET_CLOCK + daily re-sync; live R–R ms (L01); research capture A01; step counter tracks walking/running, alarm-linked resets (S01).
- **Unit/integration-tested only:** everything else in §3, including alarm delivery (fake link), charging presentation, ack gate, check-ins, highlights, functional age.
- **Looked at in renders/fixture app:** Trends sections × ranges (#18), Overview HR card (#26), Health hero, profile card, Settings at 1180 pt light. Not done: VoiceOver, keyboard, Reduce Motion, most narrow/dark states.
- **2026-11-20 #25 close-out cleanup:** removed dead code (Apple Health importer/aggregator/tables API and UI tiles, BehaviorInsights, server-sync raw pruning and upload/pull cursors, unused BLE alarm helpers, unused repository/stager/store functions), fixed `WhoopStoreInfo.schemaVersion` (15 → 19), added `Repository.prewarm` + single shared store open. Release fixture launch on a SQLite-backup copy (5 runs): store open began ~70 ms after launch (was ~340–380 ms), first refresh 3 ms (was 75–160 ms), launch-to-content median ~334 ms (was ~479 ms, 3 runs). PASS WhoopProtocol 193, WhoopStore 105, StrandAnalytics 505, StrandImport 14, StrandDesign 40 (2 skips), app build + hosted 115 (7 env skips, 0 failures), Python whoop_re + reverse_engineer OK. Docs consolidated (5 guides → `ARCHITECTURE.md`, 10 reports → `docs/archive/`, #18 QA renders removed). NOT done: the running app inspected by eye after the Apple tile removals (Activity trends, strain detail, explorer).

- **2026-11-26 #83:** `StepCounterSample.Window.spanSeconds/syncedSeconds` + `ActivityCoverage` + Strain-detail tile. PASS WhoopProtocol 193, StrandAnalytics 512 (`ActivityCoverageTests` 7: empty day, missing reference, midday gap, reset, DST 23/25 h, today/sync lag), app build + hosted 116 (7 env skips, 0 failures; `StrapStepsTests` +1 repository-backed tile test). NOT done: tile looked at in the running app or with VoiceOver (#86).

- **2026-11-26 #86 (partial):** `ActivityTileTests` renders complete / partial / today states at 1180 light, 760 dark, 420 light+dark (`NOOP_RENDER_ACTIVITY=1`) and they were looked at; the today render exposed "≥ 0m" from a normal 20-min sync lag, fixed with the sync grace. Spoken labels asserted (no "≥", no "h"/"m" abbreviations). An `NSHostingView` accessibility-tree walk returns nothing in the test host, so real VoiceOver is NOT checked. Hosted 118 (8 env skips, 0 failures), `ActivityCoverageTests` 7 pass. Running app on a SQLite-backup copy (`-noop.fixture.detail strain -noop.fixture.day … -noop.fixture.scrollTo strain-tiles`, window captured with `screencapture -l`): a past day with a 45-min gap and a counter reset and today (34-min gap, sync lag within grace) both showed "≥" totals whose walking/running and other time add up to the synced time; light, 1180 pt. VoiceOver by ear dropped by the owner 2026-11-26. Not done: dark/narrow in the running app, #49 real-input check. Seen, not changed: the Steps tile shows no "≥" for today while the day is unfinished (`Window.isComplete` ignores elapsed time).

- **2026-11-26 R86 (Bluetooth power-off counts):** offline: `log show` (NOOP + bluetoothd + kernel, 03:57–13:40) and `pmset -g log` (11-19 → 11-26), counter copies. Cause: each counted power-off is a Mac sleep (sleeps/day = `bluetoothOff` within 3); dark wakes every ~36 s come from the strap's repeated LE parameter request left pending in dark wake (EXPERIMENT_LOG R86). Fix: `PowerOffClassifier` → `systemSleep` vs `bluetoothOff`. PASS WhoopProtocol 196 (+3), app build + hosted 118 (8 env skips), `test_ops_metrics` 9. NOT done: the new counter observed in a running app across a real sleep; link release at sleep (hardware trial).
- **2026-11-26 #85:** offline on a SQLite-backup copy and `ops-counters` copies (EXPERIMENT_LOG R85). `rewarm_check.py` 7 tests pass. Re-warming measured on 3 strap-reported removals (one in-night); excluding up to 10 min after re-wear moves the in-night night value 0.01 °C → `skin-temp-night-v2` kept. No charge sessions since 11-20 (gate open). Docs + tool only; no app change.

- **2026-11-27 v0.2.0:** 11-27 lost its night (two blocks each missing one strict bar: 0.840 quiet / 0.075 dip). `sleep-core-fragments-v2` + 3 `SleepStagerTests`. On a SQLite-backup copy, 21 days re-scored: 11-27 now 540 min / recovery 74.9; 11-20 starts 23:59 (still, HR ~60 from 23:30; 411 → 464 min, recovery 45.0 → 41.5); other nights within 2 min, recovery ≤ 0.3 pt. PASS StrandAnalytics 515, hosted 118 (8 env skips), Release build (fixture/test-host/`[perf]` strings absent from the binary). NOT done: the Release app launched against the strap (would compete with the running Debug app), other packages not re-run (unchanged).

- **2026-11-27 #86 close-out:** running Debug app on a SQLite-backup copy with `-noop.fixture.width/appearance` (window captured with `screencapture -l`): Strain tiles for 11-19 (25-min gap + reset) at 1180 and 1000 pt dark, 11-26 (two resets, 37-min gap) and today at 1000 pt dark, plus 1000 pt light. Walking/running + other time = synced time on every day; "≥" and gap lines match; no clipping. Real VoiceOver dropped by the owner; #49's real-input check stays on #49. No tests needed (fixture-only options).

- **2026-11-27 #84 (owner decision):** step counter accepted as accurate without W04; Steps tile caption and spoken text no longer say "experimental". PASS app build + hosted 118 (8 env skips, 0 failures). Not looked at in the running app (caption text only).

Index check (run after file changes; expects no output):

```sh
git ls-files --cached --others --exclude-standard | grep -v -e '^AGENTS.md$' -e 'AppIcon.appiconset/icon_' | while read f; do b=$(basename "$f"); b=${b%.*}; grep -qF "$b" AGENTS.md || echo "unindexed: $f"; done
```

## 9 · Change log (latest 8)

| Date | Change | Checks / remaining |
| --- | --- | --- |
| 2026-11-27 | #84 closed by owner decision: step counter accepted as accurate (W01–W03, S01; W04 not run); Steps tile caption/spoken text drop "experimental". Walking & running keeps it; steps Trends and #49 steps stay off. W04/reset checks dropped from every backlog; functional-age message no longer says "not validated". | Hosted 118 + FunctionalAgeSnapshotTests pass; running app not checked. |
| 2026-11-27 | #86 closed: activity tiles checked in the running app in dark mode and at the 1000-pt window minimum (fixture `width`/`appearance` options added). | Running-app captures on a DB copy; VoiceOver by ear dropped. |
| 2026-11-27 | v0.2.0 pre-release: sleep fragments v2 (night split into two near-miss blocks no longer lost); Release build compiles out test/diagnostic paths (`LaunchMode.diagnostics`); version 0.2.0 (2); BUILD.md release section. | Analytics 515 + hosted 118 pass; DB-copy re-score; Release app not run against the strap. |
| 2026-11-26 | R86: "Bluetooth powered off" ~1/min was the Mac sleeping (dark wakes every ~36 s on battery, driven by the strap's repeated LE parameter request); power-offs across a sleep now count as `systemSleep`. | WhoopProtocol 196 + hosted 118 pass; wakes themselves not changed. |
| 2026-11-26 | #85: `rewarm_check.py`; re-warming ~3–5 min awake / ~10–12 min asleep, nightly value insensitive (kept); charging gate still unobserved; ops counters show ~1/min Bluetooth power-off/reconnect since 11-22. | Copies only; tool tests pass; Bluetooth churn cause open. |
| 2026-11-26 | #86 partial: activity/steps tile renders (3 states × 4 width/scheme), VoiceOver spoken text for both tiles, 30-min sync grace before "≥"; fixture options to open a detail page on a day and scroll to a section; tiles checked in the running app on a DB copy. | Hosted 118 pass; VoiceOver by ear dropped by owner. |
| 2026-11-26 | #83: Walking & running tile in Strain detail with synced coverage and lower-bound labelling (`ActivityCoverage`); steps tile keeps only count caveats. | Package + hosted tests pass; not looked at in the app (#86). |
| 2026-11-26 | HO1: R18 hold-out passed (float@33 acceleration holds, @29 not a delayed HR copy, @105 ≈ log motion energy, exploratory); event-120 hold-out 3/3 SUPPORTED; EVIDENCE_MATRIX backlog 1–2 done. | Offline on copies; docs only. R18 scale still needs wearer scenarios. |
