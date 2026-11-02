import Foundation
import Combine
import WhoopProtocol

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
// Single observable snapshot the UI binds to; FrameRouter and BLEManager are the only writers.
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
    /// WHOOP 5.0 stored-data ("history") pull. Saved chunks are acknowledged unless "keep data on strap" is on.
    @Published public var historyStatus: String = "Idle"
    @Published public var historyRange: String? = nil          // what the strap says it holds
    @Published public var historyFrames: Int = 0               // history-related frames captured this pull
    @Published public var historyCaptureFile: String? = nil    // local file the raw frames were saved to
    @Published public var historyBusy: Bool = false
    /// Offload progress (drives the Today progress strip): rows saved this pull, newest record time
    /// reached, and the span the strap says it holds (unix s) so progress = (newest-lo)/(hi-lo).
    @Published public var syncSavedRows: Int = 0
    @Published public var syncNewestTs: Int? = nil
    @Published public var syncRangeLo: Int? = nil
    @Published public var syncRangeHi: Int? = nil
    @Published public var historySummary: String? = nil        // what the decoded records contained / were saved
    /// The current WHOOP 5.0 pull, measured in strap time (nil = no pull, or the strap's range is not known yet).
    @Published public var syncSession: SyncSession? = nil
    /// Set while the app recomputes sleep / recovery / strain after a pull; nil otherwise.
    @Published public var processingStatus: String? = nil
    /// Result of the last pull + processing, for a brief confirmation or an error ("partial", "failed").
    @Published public var lastSyncOutcome: String? = nil
    /// Standard Device Information (180A): read once per connection, cached across launches. Serial is never stored here.
    @Published public var deviceInfo: DeviceInfo? = DeviceInfo.cached
    /// host ≈ strap + offset, from GET_CLOCK (WHOOP 5.0). nil until measured this connection.
    @Published public var clock: ClockEstimate? = nil
    /// Battery with its source and age. `batteryPct` stays as the plain value existing views read.
    @Published public var battery: BatteryStatus? = nil
    /// Realtime HR stream (type 40) state: on while frames keep arriving.
    @Published public var realtimeStreaming = false
    /// Recent strap events (newest first, capped) for the diagnostics panel; unknown numbers are kept.
    @Published public var recentEvents: [String] = []
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

    /// Funnel for typed battery readings (2A19, GET_BATTERY_LEVEL). Keeps `batteryPct` and the hook in step.
    public func updateBattery(_ r: BatteryReading) {
        battery = BatteryStatus(reading: r)
        setBattery(Double(r.percent))
        onBatteryReading?(r)
    }
    /// Typed battery hook (wired by AppModel to the notification monitor).
    public var onBatteryReading: ((BatteryReading) -> Void)?

    public func record(event line: String) {
        recentEvents.insert(line, at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast(recentEvents.count - 50) }
    }

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    // One funnel for battery updates so every source also notifies the alert hook.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    /// Clear per-connection telemetry (called on disconnect).
    public func resetTelemetry() {
        family = nil; historyBusy = false; realtimeStreaming = false; clock = nil; hrSubscribed = false; hrBroadcast = nil; hrPackets = 0; strapFrames = 0; lastDataAt = nil
    }

    // Capped at 200 lines so the debug log can't grow without bound.
    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// Battery level with provenance, so the UI can say how fresh it is and never invent a charging state.
public struct BatteryStatus: Equatable {
    public let percent: Int
    public let at: Date
    public let source: BatteryReading.Source
    /// nil = not known. Only a verified source sets it; a rising percentage never does.
    public let charging: Bool?
    public init(reading r: BatteryReading) {
        percent = r.percent; at = Date(timeIntervalSince1970: r.at); source = r.source; charging = r.charging
    }
    public func isStale(now: Date = Date(), after: TimeInterval = 600) -> Bool { now.timeIntervalSince(at) > after }
}

/// Standard Device Information service values. Cached in UserDefaults so Settings can show them offline.
public struct DeviceInfo: Equatable, Codable {
    public var manufacturer: String?
    public var model: String?
    public var firmware: String?
    public var hardware: String?
    public var readAt: Date?
    static let key = "noop.deviceInfo"
    public static var cached: DeviceInfo? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceInfo.self, from: d)
    }
    public func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: DeviceInfo.key) }
    }
}
