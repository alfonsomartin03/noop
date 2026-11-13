import Foundation

// PersonalRangePosition.swift — one rule for "how usual is tonight's value for me", shared by every HRV surface
// (Health Monitor tile/detail, Recovery detail). Issue #17.
//
// The personal range is `HealthMonitor.baseline`: median ± max(2 robust SD, metric floor) over up to 30 earlier nights
// (≥ 14 kept after a 4-SD MAD trim, never including the night shown). Inside that range, a value within ONE robust SD
// of the median (floored at half the metric's range floor, so a very steady history doesn't call a 1 ms change unusual)
// reads as "typical for you". Between one and two spreads it is still within range but noticeably higher/lower than
// usual; outside the range it is above/below. No population cut-offs are involved and none of this is clinical.

public enum PersonalRangePosition: String, Equatable, Sendable {
    case typical, higherThanUsual, lowerThanUsual, aboveRange, belowRange

    /// Half-width of the "typical" band around the median.
    public static func typicalHalfWidth(_ b: PersonalBaseline, metric: HealthMetric) -> Double {
        max(b.robustSD, metric.minHalfWidth / 2)
    }

    public static func assess(_ value: Double, baseline b: PersonalBaseline, metric: HealthMetric) -> PersonalRangePosition {
        if value > b.high { return .aboveRange }
        if value < b.low { return .belowRange }
        let t = typicalHalfWidth(b, metric: metric)
        if value > b.median + t { return .higherThanUsual }
        if value < b.median - t { return .lowerThanUsual }
        return .typical
    }

    /// Causal: the baseline is built only from nights before `day` (same source as `points`).
    public static func assess(day: String, value: Double, points: [HealthPoint], metric: HealthMetric) -> (PersonalRangePosition, PersonalBaseline)? {
        let from = HighlightCalendar.addDays(day, -HealthMonitor.lookbackDays) ?? day
        let prior = points.filter { $0.day >= from && $0.day < day && $0.value.isFinite && metric.plausible.contains($0.value) }
        guard let b = HealthMonitor.baseline(prior, metric: metric) else { return nil }
        return (assess(value, baseline: b, metric: metric), b)
    }

    public var label: String {
        switch self {
        case .typical: return "Typical for you"
        case .higherThanUsual: return "Within your range, higher than usual"
        case .lowerThanUsual: return "Within your range, lower than usual"
        case .aboveRange: return "Above your range"
        case .belowRange: return "Below your range"
        }
    }
    public var isWithinRange: Bool { self != .aboveRange && self != .belowRange }
}

// MARK: - Nightly maximum HRV

/// The highest RMSSD among the night's quality-filtered 5-minute windows — the same windows (`VitalWindow.usedForHRV`:
/// inside the sleep session, past onset/before waking edges, ≥ 90 % asleep and known state, enough clean beats) whose
/// MEDIAN is the representative nightly HRV used by recovery. Shown for context only; it never replaces that median.
/// Unavailable (nil) with fewer than `SleepVitalsCalculator.minValidWindows` valid windows: no substitute value.
public struct NightlyMaxHRV: Equatable, Sendable {
    public let rmssd: Double
    /// Window start/end (unix seconds) where the maximum occurred.
    public let windowStart: Int
    public let windowEnd: Int
    /// Valid windows the maximum was taken over.
    public let validWindows: Int

    public static func from(_ v: SleepVitals) -> NightlyMaxHRV? { from([v]) }

    /// Over every episode of the night's main sleep (an interrupted primary sleep has several).
    public static func from(_ episodes: [SleepVitals]) -> NightlyMaxHRV? {
        let valid = episodes.flatMap(\.windows).filter { $0.usedForHRV && $0.rmssd != nil }
        guard valid.count >= SleepVitalsCalculator.minValidWindows,
              let top = valid.max(by: { $0.rmssd! < $1.rmssd! }) else { return nil }
        return NightlyMaxHRV(rmssd: top.rmssd!, windowStart: top.start, windowEnd: top.end, validWindows: valid.count)
    }
}
