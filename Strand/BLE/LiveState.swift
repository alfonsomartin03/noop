import Foundation
import Combine

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    @Published public var bonded: Bool = false
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// Wrist-wear state from WRIST_ON/WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event arrives; flipped by FrameRouter on a real event.
    @Published public var worn: Bool = true
    /// Data-pipeline telemetry (counts only — never payload contents) so the UI can say exactly what the
    /// app is waiting for. `family` is "whoop4" / "whoop5" once the strap's services are known.
    @Published public var family: String? = nil
    /// Strap's standard HR broadcast switch, as last reported by BLE_HR_PROFILE_ENABLED/DISABLED
    /// events. nil = not reported yet this session.
    @Published public var hrBroadcast: Bool? = nil
    @Published public var hrSubscribed: Bool = false  // standard heart-rate notifications are enabled
    @Published public var hrPackets: Int = 0          // standard 0x2A37 heart-rate notifications received
    @Published public var strapFrames: Int = 0        // frames received on the strap's custom channels
    @Published public var lastDataAt: Date? = nil     // last notification of any kind (throttled to 1 Hz)
    /// WHOOP 5.0 stored-data ("history") pull — SAFE MODE (reads only; never acknowledges, so the strap keeps its data).
    @Published public var historyStatus: String = "Idle"
    @Published public var historyRange: String? = nil          // what the strap says it holds
    @Published public var historyFrames: Int = 0               // history-related frames captured this pull
    @Published public var historyCaptureFile: String? = nil    // local file the raw frames were saved to
    @Published public var historyBusy: Bool = false
    @Published public var historySummary: String? = nil        // what the decoded records contained / were saved
    /// True when macOS holds a pairing the strap has forgotten (CBError 14, "Peer removed pairing
    /// information"). Auto-retry stops; the user must forget the strap in System Settings and re-pair.
    @Published public var pairingStale = false
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// Fired (live only) when the strap reports a DOUBLE_TAP gesture. Wired by AppModel to the
    /// user's chosen action. Debounced in AppModel.
    public var onDoubleTap: (() -> Void)?
    /// Fired (live only) when wrist-wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    /// Clear per-connection telemetry (called on disconnect).
    public func resetTelemetry() {
        family = nil; historyBusy = false; hrSubscribed = false; hrBroadcast = nil; hrPackets = 0; strapFrames = 0; lastDataAt = nil
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
