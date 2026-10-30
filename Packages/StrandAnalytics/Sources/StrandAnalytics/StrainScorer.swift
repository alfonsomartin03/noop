import Foundation

// StrainScorer.swift — maps raw cardiovascular load (see CardioLoad.swift) onto NOOP's versioned 0–21 display index.
//
// This index is a presentation of load, not a measurement. It is an INDEPENDENT implementation (WHOOP-*like*, not a
// reproduction of the proprietary algorithm; not medical advice), it does not establish recovery need or comparability
// between people, and fitting another product's outputs does not validate physiology. Raw load is stored beside it.
//
// The mapping is applied once, to summed load:
//   activity index = softCeiling(4.56 · ln(1 + load))
//   day index      = softCeiling(4.67 · ln(1 + load))
// Scales and zone weights come from one person's WHOOP export (see docs/WHOOP_REVERSE_ENGINEERING.md; the fit's figures
// are repository claims, not independently reproduced). The fit's rest-day constant was removed: it stood in for load
// that was never measured, whereas day load is now integrated over the whole observed day.
//
// References: Tanaka 2001 (HRmax = 208 − 0.7×age).

public enum StrainScorer {

    /// Identifies this mapping in stored results; bump it if any constant below changes.
    public static let indexVersion = "noop-strain-index-1"

    /// Top of the scale.
    public static let maxStrain: Double = 21.0

    /// Per-minute weight of zones 1…5 (%HRmax bands, see `HRZones`). A zone-5 minute is worth ~18 zone-1 minutes.
    public static let whoopZoneWeights: [Double] = [0.105, 0.110, 0.347, 0.749, 1.875]
    /// Scale of the activity log map.
    public static let whoopActivityScale: Double = 4.56
    /// Scale of the day log map.
    public static let whoopDayScale: Double = 4.67

    /// Above this the curve flattens (see `softCeiling`); below it scores are untouched.
    static let strainKnee: Double = 16.0
    /// Highest value that can ever be reported; 21 itself is unreachable, like WHOOP.
    static let strainTop: Double = 20.99

    /// Smoothly squeezes a raw log-scale value into [0, 21). Identity up to `strainKnee`; beyond it each extra unit of
    /// effort adds less, approaching 21 but never reaching it (slope is 1 at the knee, so there is no visible kink).
    /// This saturation is deliberate: compare raw load between hard days.
    static func softCeiling(_ raw: Double) -> Double {
        guard raw > strainKnee else { return max(0, raw) }
        let room = maxStrain - strainKnee
        return min(strainTop, strainKnee + room * (1 - exp(-(raw - strainKnee) / room)))
    }

    private static func index(load: Double, scale: Double) -> Double? {
        guard load.isFinite, load >= 0 else { return nil }
        return (softCeiling(scale * log(1.0 + load)) * 100).rounded() / 100
    }

    /// Index of one session's load. Nil for load that is not a finite, non-negative number.
    public static func activityIndex(load: Double) -> Double? { index(load: load, scale: whoopActivityScale) }

    /// Index of a day's summed load. Never add session indices to get this: the map is logarithmic.
    public static func dayIndex(load: Double) -> Double? { index(load: load, scale: whoopDayScale) }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent). A population estimate.
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Linear-interpolated percentile of an already-sorted sequence (numpy-style).
    // Same interpolation as numpy.percentile so results match the Python reference.
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }
}
