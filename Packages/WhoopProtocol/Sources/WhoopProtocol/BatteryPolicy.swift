import Foundation

/// One battery observation. `charging` is nil unless a verified source reported it — a rising percentage
/// is never taken as proof of charging.
public struct BatteryReading: Equatable, Sendable {
    public enum Source: String, Sendable, Codable { case standardLevel, vendorCommand, event }
    public let percent: Int
    public let charging: Bool?
    public let at: Double
    public let source: Source
    public init(percent: Int, charging: Bool?, at: Double, source: Source) {
        self.percent = percent; self.charging = charging; self.at = at; self.source = source
    }
}

/// Persisted notification state (survives restarts, so a reconnect never re-sends the same alert).
public struct BatteryAlertState: Equatable, Sendable, Codable {
    /// Low alert sent; re-armed only once the level is back at or above `rearmPercent`.
    public var lowAlerted = false
    /// Full alert sent for the current charging session; cleared when a new session begins.
    public var fullAlerted = false
    /// Last confirmed charging state (nil = never confirmed).
    public var lastCharging: Bool?
    public init() {}
}

/// Decides when to raise the low-battery and charging-complete notifications.
///
/// Policy (documented in docs/reverse-engineering/SAFETY_MATRIX.md → Battery alerts):
/// - Low: the first fresh reading below `lowPercent` alerts once, whether it is a crossing or the first
///   reading after launch/connect (an already-low strap is exactly when the user needs to know). No new
///   low alert until a reading reaches `rearmPercent` (hysteresis stops 19/20/19 flapping).
/// - Full: only when charging is confirmed true and the level reads 100. One alert per charging session;
///   a session starts on a confirmed not-charging → charging transition (or the first confirmed charging
///   reading). Unknown charging → never a full alert.
/// - Readings older than `staleAfter` are ignored for alerts.
/// - When alerts are disabled, state still advances so enabling them later doesn't fire a backlog.
public struct BatteryAlertPolicy: Sendable {
    public enum Alert: Equatable, Sendable { case low(percent: Int), full }

    public var lowPercent = 20
    public var rearmPercent = 25
    /// Longer than the 15-min battery poll: between polls the strap pushes a reading only on a ~1 % step.
    public var staleAfter: Double = 20 * 60
    public init() {}

    public func evaluate(_ r: BatteryReading, now: Double, state: inout BatteryAlertState,
                         lowEnabled: Bool, fullEnabled: Bool) -> [Alert] {
        guard (0...100).contains(r.percent), now - r.at <= staleAfter else { return [] }
        var out: [Alert] = []

        if r.percent >= rearmPercent { state.lowAlerted = false }
        if r.percent < lowPercent, !state.lowAlerted, r.charging != true {
            state.lowAlerted = true
            if lowEnabled { out.append(.low(percent: r.percent)) }
        }

        if let c = r.charging {
            if c && state.lastCharging != true { state.fullAlerted = false }   // a new charging session
            state.lastCharging = c
            if c, r.percent >= 100, !state.fullAlerted {
                state.fullAlerted = true
                if fullEnabled { out.append(.full) }
            }
        }
        return out
    }
}
