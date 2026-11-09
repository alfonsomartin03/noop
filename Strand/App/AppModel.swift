import SwiftUI
import AppKit
import os
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Root app state: owns the live BLE connection state, the CoreBluetooth engine, the on-device
/// store read model, and the WHOOP-export importer.
@MainActor
final class AppModel: ObservableObject {
    /// Shared device id for both live capture (BLEManager) and imported history.
    // Single-strap app: one fixed id keys everything in the database.
    let deviceId = "my-whoop"
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// CoreBluetooth engine — scans, connects, bonds, streams.
    let ble: BLEManager
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile = ProfileStore()
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine
    /// Low-battery / charging-complete notifications.
    let batteryMonitor = BatteryMonitor()
    /// Wake alarms (host-driven; see AlarmController). History persists in the local store.
    let alarms: AlarmController
    /// Morning / evening check-in preferences (entries live in the store).
    let checkIns = CheckInSettings()

    /// Import status surfaced to Settings → Data.
    @Published var importing = false
    @Published var importSummary: String?

    /// Smoothed, display-ready live heart rate. Every screen shows this, not the raw per-beat value (which swings with
    /// HRV). Kept off AppModel so ~1 Hz beats don't redraw every view that observes the model.
    let heart: LiveHeartRate
    private var analysisDebounce: Task<Void, Never>?
    private var lastDataVersionBump = Date.distantPast
    private var hrCancellables = Set<AnyCancellable>()

    // Wiring order: live state -> BLE engine -> repository -> analytics, then the refresh hooks below.
    init() {
        // Log the system time zone (it follows the device's location) so each night resolves on the clock it was slept on.
        ZoneTimeline.shared.startTracking()
        CheckInReminders.shared.install()
        let live = LiveState()
        self.live = live
        self.heart = LiveHeartRate(following: live)
        self.ble = BLEManager(state: live, deviceId: "my-whoop")
        self.repo = Repository(deviceId: "my-whoop")
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
        let repoRef = repo
        self.alarms = AlarmController(history: { await repoRef.storeHandle() })
        // New strap data (offload / stored-data pull) → recompute scores, refresh caches, redraw screens.
        // When new strap data lands: show raw rows immediately, recompute scores, then refresh the UI again.
        ble.onStoredDataChanged = { [weak self] in
            guard let self else { return }
            // A pull saves dozens of chunks per second. Re-scoring 21 days after each one pinned the CPU, so show raw rows
            // at a throttled rate and run the (expensive) scoring once, after the chunks stop arriving.
            let nowT = Date()
            if nowT.timeIntervalSince(self.lastDataVersionBump) > 2 {
                self.lastDataVersionBump = nowT
                self.repo.dataVersion += 1                       // stored HR shows promptly
            }
            self.analysisDebounce?.cancel()
            self.analysisDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)   // quiet period after the last chunk
                guard let self, !Task.isCancelled else { return }
                await self.intelligence.analyzeRecent()          // then scores catch up (refreshes the repo)
                await self.repo.refresh()
                self.repo.dataVersion += 1
            }
        }
        // Battery readings (0x2A19, GET_BATTERY_LEVEL) feed the notification policy.
        live.onBatteryReading = { [weak self] r in self?.batteryMonitor.ingest(r) }
        if BatteryMonitor.isEnabled(BatteryMonitor.lowEnabledKey) || BatteryMonitor.isEnabled(BatteryMonitor.fullEnabledKey) {
            BatteryMonitor.requestAuthorization()
        }
        alarms.attach(live: live, ble: ble)
        // Sleeping-HR baseline for smart wake, with provenance: NOOP's own most recent nightly resting HR, else an
        // imported one (labelled as such). Its age is checked by the policy.
        alarms.baseline = { [weak self] in
            guard let self else { return nil }
            func pick(_ rows: [DailyMetric], _ label: String) -> WakeBaseline? {
                guard let d = rows.last(where: { $0.restingHr != nil }), let hr = d.restingHr,
                      let r = ZoneTimeline.shared.dayRange(d.day) else { return nil }
                return WakeBaseline(bpm: Double(hr), source: "\(label) \(d.day)", asOf: Date(timeIntervalSince1970: TimeInterval(r.from)))
            }
            return pick(self.repo.estimates.values.sorted { $0.day < $1.day }, "noop-resting-hr")
                ?? pick(self.repo.official.values.sorted { $0.day < $1.day }, "imported-resting-hr")
        }
        // Sleep-goal progress: tonight's main session so far (from the latest sync) against the estimated need, with the
        // time the synced data reaches so the policy can reject stale progress.
        alarms.sleepProgress = { [weak self] in
            guard let self else { return nil }
            let now = Int(Date().timeIntervalSince1970)
            let recent = self.repo.recentSleepEpisodes.filter { $0.endTs > now - 3 * 3600 && $0.isMainSleep }
            guard let last = recent.max(by: { $0.endTs < $1.endTs }), let sid = last.sessionId else { return nil }
            let eps = recent.filter { $0.sessionId == sid }
            let asleep = eps.reduce(0.0) { $0 + Double($1.endTs - $1.startTs) * ($1.efficiency ?? 0.9) } / 60
            let past = self.repo.days.suffix(14).compactMap(\.totalSleepMin)
            guard let need = SleepNeed.summarize(officialNeed: nil, officialDebt: nil, asleep: asleep, recentAsleep: past)?.needMin else { return nil }
            return SleepGoalProgress(asleepMin: asleep, needMin: need, sessionId: sid, sessionKind: last.kind,
                                     dataThrough: Date(timeIntervalSince1970: TimeInterval(last.endTs)))
        }
        // A finished (or stopped) pull goes straight to processing, shown as its own stage.
        ble.onSyncDownloadFinished = { [weak self] complete in self?.runPostSyncProcessing(downloadComplete: complete) }
        // Each (re)connect measures the strap clock; re-store the next alarm on the strap then, so a deadline set while
        // disconnected (or consumed when it rang) is put back and verified by read-back.
        live.$clock.compactMap { $0 }.removeDuplicates { abs($0.measuredAt - $1.measuredAt) < 60 }
            .sink { [weak self] _ in self?.alarms.syncDeviceAlarm() }.store(in: &hrCancellables)

        if let mode = LaunchMode.fixtureBattery, ["cycle", "charging"].contains(mode) { playFixtureBattery(mode) }
        if LaunchMode.fixtureAlarmHistory { seedFixtureAlarmHistory() }

        // Turn the strap's offloaded raw data into dashboard scores on launch and every 15
        // minutes, so recovery / strain / sleep populate from the strap itself with no import.
        // IntelligenceEngine computes, persists under "my-whoop-noop", and refreshes the dashboard.
        // Background loop: analyse on launch, then every 15 min (same cadence as the strap offload).
        Task { [weak self] in
            guard let self else { return }
            await self.repo.refresh()                          // surface any imported data at once
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            await self.intelligence.recomputeIfRulesChanged()  // one-time full re-score after a scoring-rule change
            while !Task.isCancelled {
                await self.intelligence.analyzeRecent()
                try? await Task.sleep(nanoseconds: 900_000_000_000)  // 15 min, matches the offload cadence
            }
        }
    }

    private static let syncLog = Logger(subsystem: "com.noopapp.noop", category: "sync")

    /// Post-download stage: recompute sleep, recovery and strain from what was saved, then refresh the dashboard.
    /// The UI shows "Processing" until this returns; success is reported only if scoring actually finished.
    private func runPostSyncProcessing(downloadComplete: Bool) {
        analysisDebounce?.cancel()
        live.processingStatus = "Updating sleep, recovery, and activity metrics…"
        let started = Date()
        AppModel.syncLog.notice("Processing: started (download \(downloadComplete ? "complete" : "ended early", privacy: .public))")
        Task { @MainActor [weak self] in
            guard let self else { return }
            var ok = await self.intelligence.analyzeRecent()
            // A periodic run may already be scoring; wait for it (bounded) and score again so this pull is included.
            var waited = 0
            while !ok, self.intelligence.computing, waited < 120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
                if !self.intelligence.computing { ok = await self.intelligence.analyzeRecent() }
            }
            await self.repo.refresh()
            self.repo.dataVersion += 1
            self.live.processingStatus = nil
            AppModel.syncLog.notice("Processing: \(ok ? "finished" : "FAILED", privacy: .public) in \(Int(Date().timeIntervalSince(started)), privacy: .public) s")
            if ok {
                if downloadComplete {
                    self.live.syncSession?.processingFinished()
                    self.live.lastSyncOutcome = nil
                }
            } else {
                self.live.lastSyncOutcome = "Data saved, but updating scores failed: \(self.intelligence.note ?? "unknown error")"
            }
        }
    }

    /// Save a sleep correction and re-score the days it touches. The correction is stored as source data, so later
    /// syncs and re-scores keep applying it; automatic labels never override it.
    func correctSleep(_ c: SleepCorrection) {
        Task { @MainActor in
            guard let store = await repo.storeHandle() else { return }
            do { try await store.saveSleepCorrection(SleepCorrections.row(c)) } catch { return }
            await intelligence.analyzeRecent()
            await repo.refresh()
            repo.dataVersion += 1
        }
    }

    /// Remove a correction (back to automatic classification for that span).
    func undoSleepCorrection(id: String) {
        Task { @MainActor in
            guard let store = await repo.storeHandle() else { return }
            try? await store.deleteSleepCorrection(id: id)
            await intelligence.analyzeRecent()
            await repo.refresh()
            repo.dataVersion += 1
        }
    }

    /// Synthetic alarm history in the fixture copy (see `LaunchMode.fixtureAlarmHistory`): one occurrence per status, at
    /// 06:40 on each of the last four mornings so the timeline can line up with the copy's own sleep estimates.
    private func seedFixtureAlarmHistory() {
        Task { @MainActor [weak self] in
            guard let self, LaunchMode.fixtureStore != nil, let store = await self.repo.storeHandle() else { return }
            let cal = Calendar.current
            var rows: [AlarmEventRow] = []
            let kinds = ["dismissed", "unconfirmed", "macOnly", "failed"]
            for (i, k) in kinds.enumerated() {
                guard let day = cal.date(byAdding: .day, value: -(i + 1), to: cal.startOfDay(for: Date())),
                      let deadline = cal.date(bySettingHour: 7, minute: 0, second: 0, of: day) else { continue }
                let occ = "fixture-\(k)@\(Int(deadline.timeIntervalSince1970))"
                let decided = deadline.addingTimeInterval(-20 * 60).timeIntervalSince1970
                func row(_ kind: String, _ dt: Double, _ p: [String: Any], prov: String = "host", strap: Bool = false) -> AlarmEventRow {
                    AlarmEventRow(occurrenceId: occ, kind: kind, recordedAt: decided + dt, deviceTs: strap ? Int(decided + dt) : nil,
                                  mappedHostTs: strap ? decided + dt : nil, receivedAt: decided + dt, provenance: prov,
                                  dedupeKey: "fixture:\(occ):\(kind):\(dt)", payload: AlarmHistory.payload(p))
                }
                rows.append(row(AlarmHistoryKind.scheduled, -1200, ["alarmId": "fixture", "mode": "Smart wake, 30-min window",
                                                                   "deadline": deadline.timeIntervalSince1970,
                                                                   "windowStart": deadline.timeIntervalSince1970 - 1800,
                                                                   "timeZone": TimeZone.current.identifier, "policyVersion": SmartWakePolicy.current.version]))
                rows.append(row(AlarmHistoryKind.decision, 0, ["trigger": "hrRun", "reason": "Heart rate stayed above your sleeping level for 60 s",
                                                               "evidenceQuality": "3 qualifying windows, 58 samples", "baselineSource": "noop-resting-hr (fixture)",
                                                               "policyVersion": SmartWakePolicy.current.version]))
                rows.append(row(AlarmHistoryKind.notification, 1, ["outcome": "submitted"]))
                switch k {
                case "dismissed":
                    rows.append(row(AlarmHistoryKind.commandRequested, 1, ["command": "run"]))
                    rows.append(row(AlarmHistoryKind.strapEvent, 2, ["event": "HAPTICS_FIRED"], prov: "live", strap: true))
                    rows.append(row(AlarmHistoryKind.dismissal, 18, ["source": "strap"]))
                case "unconfirmed":
                    rows.append(row(AlarmHistoryKind.commandRequested, 1, ["command": "run"]))
                    rows.append(row(AlarmHistoryKind.deliveryOutcome, 32, ["outcome": "unconfirmed", "detail": "The strap accepted the alarm but didn't report vibrating"]))
                case "macOnly":
                    rows.append(row(AlarmHistoryKind.deliveryOutcome, 1, ["outcome": "macOnly", "detail": "Strap not reachable for a buzz"]))
                default:
                    rows.append(row(AlarmHistoryKind.deliveryOutcome, 11, ["outcome": "failed", "detail": "No answer from the strap to the alarm time"]))
                }
            }
            _ = try? await store.appendAlarmEvents(rows)
            self.alarms.loadHistory()
            FileHandle.standardError.write(Data("[fixture] alarm history seeded (\(rows.count) rows)\n".utf8))
        }
    }

    /// Synthetic battery states for visual checks of a fixture launch (see `LaunchMode.fixtureBattery`): 8 s each.
    private func playFixtureBattery(_ mode: String) {
        // Each step: connection, percent, then the strap events that state would come from.
        typealias Step = (connected: Bool, pct: Int, events: [Whoop5EventKind])
        let steps: [Step] = mode == "charging" ? [(true, 62, [.batteryPackConnected, .chargingOn])]
            : [(true, 62, [.batteryPackRemoved]),                       // detached (explicit event)
               (true, 62, [.batteryPackConnected]),             // attached, charging unknown
               (true, 63, [.chargingOn]),                       // confirmed charging
               (true, 100, []),                                 // full
               (false, 100, [])]                                // disconnected: stale, unknown
        Task { @MainActor [weak self] in
            for (i, s) in steps.enumerated() {
                guard let self else { return }
                if s.connected && !self.live.connected { self.live.beginConnection() }
                self.live.connected = s.connected
                if !s.connected { self.live.resetTelemetry() }
                if s.connected {
                    for e in s.events { self.live.applyChargingEvent(e, eventAt: Date()) }
                    self.live.updateBattery(BatteryReading(percent: s.pct, charging: nil, at: Date().timeIntervalSince1970, source: .vendorCommand))
                }
                FileHandle.standardError.write(Data("[fixture] battery step \(i)\n".utf8))
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func scan() { ble.connect() }
    /// Remember whether NOOP may use Bluetooth (survives relaunch). Allowing while macOS denies NOOP opens the
    /// Privacy pane, since only the system can lift that.
    func setBluetoothAllowed(_ allowed: Bool) {
        ble.setBluetoothAllowed(allowed)
        if allowed, live.bluetoothDeniedBySystem { openBluetoothPrivacySettings() }
    }
    /// Open System Settings ▸ Privacy & Security ▸ Bluetooth.
    func openBluetoothPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
    func disconnect() { ble.disconnect() }
    /// Retry pairing from scratch after the strap forgot this Mac (see `LiveState.pairingStale`).
    func restartPairing() { ble.restartPairing() }
    /// Open System Settings ▸ Bluetooth, where the stale WHOOP entry has to be forgotten.
    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Enable the realtime stream + mark it wanted so the keep-alive re-arms it (can't lapse).
    func startRealtimeHR(owner: String = "ui") { ble.startRealtime(owner: owner) }
    /// Stop the realtime stream and clear the live reading (HR is still recorded by the strap and offloaded in history).
    func stopRealtimeHR(owner: String = "ui") { ble.stopRealtime(owner: owner) }
    /// Turn the strap's standard heart-rate broadcast on/off (WHOOP 4.0).
    func setHRBroadcast(_ on: Bool) { ble.setHRBroadcast(on) }
    /// Ask the strap for a fresh battery reading and whether its charging pack is on (5.0; ignored on 4.0).
    func getBattery() { ble.send(.getBatteryLevel, payload: [0x00]); ble.refreshChargingState() }

    /// Import a Whoop CSV export (.zip or folder) → on-device store, then refresh the dashboard.
    // security-scoped access is required to read files picked from the file dialog in a sandboxed app.
    func importWhoop(url: URL) {
        importing = true
        importSummary = nil
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    importSummary = "Couldn't open the local store."; importing = false; return
                }
                let summary = try await WhoopImporter.importExport(url: url, into: store, deviceId: deviceId)
                await repo.refresh()
                await intelligence.analyzeRecent()   // refresh NOOP estimates so they can be compared with the import
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))–\(f.string(from: b))"
                } else { span = "" }
                importSummary = "Imported \(summary.recordCount) records\(span)"
            } catch {
                importSummary = "Import failed: \(error)"
            }
            importing = false
        }
    }
}
