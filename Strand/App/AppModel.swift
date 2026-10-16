import SwiftUI
import AppKit
import Combine
import WhoopProtocol
import WhoopStore

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

    /// Import status surfaced to the Import & Export screen.
    @Published var importing = false
    @Published var importSummary: String?

    /// Smoothed, display-ready live heart rate — median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var hrCancellables = Set<AnyCancellable>()

    // Wiring order: live state -> BLE engine -> repository -> analytics, then the refresh hooks below.
    init() {
        let live = LiveState()
        self.live = live
        self.ble = BLEManager(state: live, deviceId: "my-whoop")
        self.repo = Repository(deviceId: "my-whoop")
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: "my-whoop")
        // New strap data (offload / stored-data pull) → recompute scores, refresh caches, redraw screens.
        // When new strap data lands: show raw rows immediately, recompute scores, then refresh the UI again.
        ble.onStoredDataChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.repo.dataVersion += 1                       // stored HR shows at once
                await self.intelligence.analyzeRecent()          // then scores catch up (refreshes the repo)
                await self.repo.refresh()
                self.repo.dataVersion += 1
            }
        }
        // Smooth HR centrally so it's solid everywhere it's shown.
        // Both signals feed one smoother, so every screen shows the same steady bpm.
        live.$heartRate.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] _ in self?.ingestHR() }.store(in: &hrCancellables)

        // Turn the strap's offloaded raw data into dashboard scores on launch and every 15
        // minutes, so recovery / strain / sleep populate from the strap itself with no import.
        // IntelligenceEngine computes, persists under "my-whoop-noop", and refreshes the dashboard.
        // Background loop: analyse on launch, then every 15 min (same cadence as the strap offload).
        Task { [weak self] in
            guard let self else { return }
            await self.repo.refresh()                          // surface any imported data at once
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
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
        guard let inst else { return }
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
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
    /// Stop the realtime stream (the lightweight 0x2A37 HR keeps recording regardless).
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
