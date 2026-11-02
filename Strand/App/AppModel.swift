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
    /// Wake alarms (host-driven; see AlarmController).
    let alarms = AlarmController()

    /// Import status surfaced to Settings → Data.
    @Published var importing = false
    @Published var importSummary: String?

    /// Smoothed, display-ready live heart rate — median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var analysisDebounce: Task<Void, Never>?
    private var lastDataVersionBump = Date.distantPast
    private var hrCancellables = Set<AnyCancellable>()

    // Wiring order: live state -> BLE engine -> repository -> analytics, then the refresh hooks below.
    init() {
        // Log the system time zone (it follows the device's location) so each night resolves on the clock it was slept on.
        ZoneTimeline.shared.startTracking()
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live, deviceId: "my-whoop")
        self.repo = Repository(deviceId: "my-whoop")
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
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
        // Sleeping-HR reference for smart wake: the most recent nightly resting HR.
        alarms.sleepingHR = { [weak self] in self?.repo.days.last(where: { $0.restingHr != nil })?.restingHr.map(Double.init) }
        // Sleep-goal progress: tonight's session so far (from the latest sync) against the estimated need.
        alarms.sleepProgress = { [weak self] in
            guard let self else { return nil }
            let now = Int(Date().timeIntervalSince1970)
            let recent = self.repo.recentSleepEpisodes.filter { $0.endTs > now - 3 * 3600 }
            guard let sid = recent.max(by: { $0.endTs < $1.endTs })?.sessionId else { return nil }
            let asleep = recent.filter { $0.sessionId == sid }
                .reduce(0.0) { $0 + Double($1.endTs - $1.startTs) * ($1.efficiency ?? 0.9) } / 60
            let past = self.repo.days.suffix(14).compactMap(\.totalSleepMin)
            let need = SleepNeed.summarize(officialNeed: nil, officialDebt: nil, asleep: asleep, recentAsleep: past)?.needMin
            return need.map { (asleep, $0) }
        }
        // A finished (or stopped) pull goes straight to processing, shown as its own stage.
        ble.onSyncDownloadFinished = { [weak self] complete in self?.runPostSyncProcessing(downloadComplete: complete) }
        // Smooth HR centrally so it's solid everywhere it's shown.
        // Both signals feed one smoother, so every screen shows the same steady bpm.
        live.$heartRate.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)
        // Each (re)connect measures the strap clock; re-store the next alarm on the strap then, so a deadline set while
        // disconnected (or consumed when it rang) is put back and verified by read-back.
        live.$clock.compactMap { $0 }.removeDuplicates { abs($0.measuredAt - $1.measuredAt) < 60 }
            .sink { [weak self] _ in self?.alarms.syncDeviceAlarm() }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)

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

    /// Fold a fresh reading into the smoothing window and republish a stable bpm.
    /// Prefers the strap's reported HR; falls back to 60000/R-R. Clamps to a plausible
    /// 30–220 range (rejects 0 / garbage spikes) and publishes the window MEDIAN.
    // Smoothing: keep ~10 s of readings, drop implausible ones, publish the median so single beats don't make the number jump.
    private func ingestHR() {
        var inst: Double?
        if let hr = live.heartRate, hr >= 30, hr <= 220 {
            inst = Double(hr)
        } else if let rr = live.rr.last, rr > 0 {
            let v = 60_000.0 / Double(rr)
            if v >= 30, v <= 220 { inst = v }
        }
        guard let inst else {
            // No live reading (stream stopped): clear the smoother so a stale bpm isn't shown.
            hrWindow.removeAll(); bpm = nil
            return
        }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
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

    func scan() { ble.connect() }
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
    func startRealtimeHR() { ble.startRealtime() }
    /// Stop the realtime stream and clear the live reading (HR is still recorded by the strap and offloaded in history).
    func stopRealtimeHR() { ble.stopRealtime() }
    /// Turn the strap's standard heart-rate broadcast on/off (WHOOP 4.0).
    func setHRBroadcast(_ on: Bool) { ble.setHRBroadcast(on) }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { ble.send(.getBatteryLevel, payload: [0x00]) }

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
