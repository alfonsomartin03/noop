import Foundation
import Combine
import WhoopStore

/// The iPhone's strap collector (#78): the same BLEManager, Collector and Backfiller as the Mac (persist before ack,
/// undecoded history kept), writing into this phone's store, which is also the sync outbox. Foreground only: when iOS
/// suspends the app the link drops, and nothing was acknowledged that was not saved. Bluetooth starts only after the
/// user taps "Collect from strap".
@MainActor
final class PhoneCollector: ObservableObject {
    let live = LiveState()
    private(set) var ble: BLEManager?
    @Published private(set) var active = false
    private var cancellables = Set<AnyCancellable>()
    /// Called when new strap data was saved, and when a history download finished.
    var onDataSaved: (() -> Void)?
    var onDownloadFinished: (() -> Void)?

    init() {
        // Relaunch: resume collecting if the user had started it.
        if BluetoothChoice.stored() == .allowed { start() }
        live.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    func start() {
        if ble == nil {
            let b = BLEManager(state: live, deviceId: "my-whoop")
            b.onStoredDataChanged = { [weak self] in self?.onDataSaved?() }
            b.onSyncDownloadFinished = { [weak self] _ in self?.onDownloadFinished?() }
            ble = b
        }
        ble?.setBluetoothAllowed(true)
        active = true
    }

    func stop() {
        ble?.setBluetoothAllowed(false)
        active = false
    }

    var statusLine: String {
        guard active else { return "Not collecting" }
        if live.historyBusy { return "Downloading history · \(live.syncSavedRows) rows saved" }
        if live.connected {
            var parts = ["Connected"]
            if let hr = live.heartRate { parts.append("\(hr) bpm") }
            if let b = live.batteryPct { parts.append("battery \(Int(b.rounded()))%") }
            return parts.joined(separator: " · ")
        }
        return "Looking for your strap…"
    }
}
