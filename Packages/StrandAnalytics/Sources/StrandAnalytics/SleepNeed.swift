import Foundation

// SleepNeed.swift — how much sleep a night asked for, and how far short it fell.
//
// Prefers the need/debt WHOOP reported in the export. With no reported need, NOOP falls back to a
// simple estimate: the larger of 7.5 h and your recent average sleep. The estimate is only the
// shortfall for that one night, not WHOOP's accumulated debt, so the two are labelled differently.
// Pure and DB-free; mirrored in Kotlin `SleepNeed`.

public enum SleepNeed {
    /// Floor for the estimated need, minutes (7.5 h).
    public static let floorMin = 450.0

    public struct Summary: Equatable, Sendable {
        public let needMin: Double
        public let asleepMin: Double
        /// Official: WHOOP's reported sleep debt. Estimate: this night's shortfall vs need.
        public let debtMin: Double
        /// True when need (and debt, if present) came from the WHOOP export.
        public let isOfficial: Bool
    }

    /// - Parameters:
    ///   - officialNeed / officialDebt: values from the WHOOP export for the same day, if any.
    ///   - asleep: minutes asleep that night. Nil → no summary.
    ///   - recentAsleep: recent nights' minutes asleep, used only for the fallback need.
    // Official WHOOP need wins; otherwise estimate = max(7.5 h, recent average) and debt = just this night's shortfall.
    public static func summarize(officialNeed: Double?, officialDebt: Double?,
                                 asleep: Double?, recentAsleep: [Double]) -> Summary? {
        guard let asleep, asleep > 0 else { return nil }
        if let need = officialNeed, need > 0 {
            return Summary(needMin: need, asleepMin: asleep,
                           debtMin: officialDebt ?? max(0, need - asleep), isOfficial: true)
        }
        let valid = recentAsleep.filter { $0 > 0 }
        let typical = valid.isEmpty ? 0 : valid.reduce(0, +) / Double(valid.count)
        let need = max(floorMin, typical)
        return Summary(needMin: need, asleepMin: asleep, debtMin: max(0, need - asleep), isOfficial: false)
    }
}
