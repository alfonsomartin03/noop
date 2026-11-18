import Foundation

/// Pure decision: should we SET_CLOCK on this connect? Mirrors WHOOP — set only when the strap's RTC
/// has drifted beyond a small threshold (or is frozen/way off), not blindly every connect. Avoids
/// gratuitous clock resets that could introduce discontinuities in derived historical timestamps.
enum ClockPolicy {
    /// `deviceClock` = the strap's current RTC reading (unix seconds, from GET_CLOCK). `wallNow` =
    /// phone wall time (unix seconds). Returns true if |drift| >= threshold.
    // Only resets the strap clock if it drifted by >= 2 s, avoiding needless resets that could cause timestamp jumps.
    static func shouldSetClock(deviceClock: Int, wallNow: Int, driftThreshold: Int = 2) -> Bool {
        abs(wallNow - deviceClock) >= driftThreshold
    }
}

/// WHOOP 5.0 strap-clock re-sync (K01). The strap clock free-runs about 1.4 s/day slow (fw 50.43.1.0); the owner-
/// approved one-shot test (2026-11-18) showed SET_CLOCK latches (40.5 s → 0.07 s) and history keeps flowing. NOOP
/// therefore corrects it at most once a day, after a completed history pull (a quiet point), and reads it back.
enum ClockResyncPolicy {
    /// UserDefaults: `false` turns the re-sync off (default on). Last attempt time (unix s), success or not.
    static let enabledKey = "noop.clock.autoResync"
    static let lastAttemptKey = "noop.clock.lastResyncAt"
    /// Correct only drift of at least this much (s): smaller is within the estimate's own noise.
    static let threshold: Double = 1
    /// At most one attempt per day; a large offset (e.g. after the strap lost time) may retry hourly.
    static let minInterval: Double = 86_400
    static let largeOffset: Double = 30
    static let largeOffsetInterval: Double = 3_600
    /// The estimate must be fresh and tight enough to trust its offset.
    static let maxEstimateAge: Double = 20 * 60
    static let maxUncertainty: Double = 1

    static func isEnabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: enabledKey) as? Bool ?? true }

    /// `offset` = Mac − strap seconds (positive = strap behind). Pure decision.
    static func shouldResync(offset: Double, uncertainty: Double, measuredAt: Double,
                             lastAttemptAt: Double?, now: Double) -> Bool {
        guard offset.isFinite, abs(offset) >= threshold, uncertainty <= maxUncertainty,
              now - measuredAt >= 0, now - measuredAt <= maxEstimateAge else { return false }
        guard let last = lastAttemptAt, last <= now else { return true }   // never tried, or a clock moved backwards
        return now - last >= (abs(offset) >= largeOffset ? largeOffsetInterval : minInterval)
    }
}
