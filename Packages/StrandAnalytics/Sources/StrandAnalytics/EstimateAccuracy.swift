import Foundation

// EstimateAccuracy.swift — how close NOOP's own estimate is to the score WHOOP reported.
//
// Pure and DB-free. Only days where BOTH an official (imported) value and a NOOP estimate exist
// are compared. This is a descriptive comparison on the user's own data, not a validation claim.

public enum EstimateAccuracy {
    /// Version tag of the on-device estimate formulas. Bump when scoring math changes (keep in
    /// step with Kotlin `EstimateAccuracy.MODEL_VERSION`).
    public static let modelVersion = "noop-est-1"

    /// Below this many shared days the comparison is not shown (cold start).
    public static let minDays = 7

    public struct Result: Equatable, Sendable {
        /// Number of days with both an official value and an estimate.
        public let days: Int
        /// Mean absolute difference, in the metric's own unit.
        public let meanAbsError: Double
        /// Mean signed difference (estimate − official); positive = NOOP reads higher.
        public let bias: Double
        public var isReliable: Bool { days >= EstimateAccuracy.minDays }
    }

    /// Compare day-keyed official values with day-keyed estimates. Nil when no day overlaps.
    // Only days present in both sets are compared. bias > 0 means NOOP reads higher than WHOOP.
    public static func compare(official: [String: Double], estimate: [String: Double]) -> Result? {
        var diffs: [Double] = []
        for (day, o) in official {
            if let e = estimate[day] { diffs.append(e - o) }
        }
        guard !diffs.isEmpty else { return nil }
        let n = Double(diffs.count)
        return Result(days: diffs.count,
                      meanAbsError: diffs.reduce(0) { $0 + abs($1) } / n,
                      bias: diffs.reduce(0, +) / n)
    }
}
