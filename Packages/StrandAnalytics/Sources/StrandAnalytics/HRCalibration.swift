import Foundation

// HRCalibration.swift — the one set of heart-rate reference values behind a result.
//
// Detection, load and zones for a day all read the same snapshot, and the snapshot is stored with the result, so a past
// day keeps the values it was scored with until the user asks for an explicit re-score.
//
// HRmax: a declared value wins and may sit below the population equation; a person's measured maximum can. Tanaka 2001
// (208 − 0.7·age, https://pubmed.ncbi.nlm.nih.gov/11153730/) is a population estimate and labelled as one. A percentile of
// one day's ordinary HR is not a maximal test, so it is no longer used, and no universal value stands in for an unknown
// HRmax: load is withheld with a reason instead.
//
// Resting HR: the protocol is the overnight low quantile of `SleepVitals`, not a standardized awake resting HR. The two
// are not interchangeable. When a day has no night, the causal reference built from strictly earlier nights is used; when
// there is none it stays unknown rather than becoming 60. Only %HRR-based outputs need it.

public struct HRCalibration: Codable, Equatable, Sendable {
    public enum MaxSource: String, Codable, Sendable {
        case declared                // user override or caller-supplied value
        case tanaka                  // population estimate from age
        case unavailable
    }
    public enum RestingSource: String, Codable, Sendable {
        case declared
        case sameDaySleep            // low quantile of this day's main sleep
        case causalSleepReference    // reference from nights strictly before this day
        case unavailable
    }

    /// Bump when the resolution rules below change.
    public static let version = "hr-calibration-1"
    /// A declared HRmax outside this range is treated as a typo, not a measurement.
    static let plausibleMaxBPM: ClosedRange<Double> = 100...240

    public let hrMax: Double?
    public let hrMaxSource: MaxSource
    public let restingHR: Double?
    public let restingSource: RestingSource
    /// Day this snapshot was resolved for ("YYYY-MM-DD"), if any.
    public let effectiveDay: String?
    public let version: String

    public init(hrMax: Double?, hrMaxSource: MaxSource, restingHR: Double?, restingSource: RestingSource,
                effectiveDay: String? = nil, version: String = HRCalibration.version) {
        self.hrMax = hrMax; self.hrMaxSource = hrMaxSource; self.restingHR = restingHR
        self.restingSource = restingSource; self.effectiveDay = effectiveDay; self.version = version
    }

    /// True when HRmax is a population estimate, not a declared personal value.
    public var hrMaxIsEstimate: Bool { hrMaxSource == .tanaka }

    /// Heart-rate reserve, when both ends are known and valid.
    public var hrReserve: Double? {
        guard let hrMax, let restingHR, hrMax > restingHR else { return nil }
        return hrMax - restingHR
    }

    public static func resolve(day: String? = nil, declaredMax: Double?, age: Double?,
                               declaredResting: Double? = nil, sleepResting: Double? = nil,
                               causalResting: Double? = nil) -> HRCalibration {
        let hrMax: Double?
        let maxSource: MaxSource
        if let m = declaredMax, m.isFinite, plausibleMaxBPM.contains(m) {
            (hrMax, maxSource) = (m, .declared)
        } else if let a = age, a.isFinite, a > 0 {
            (hrMax, maxSource) = (StrainScorer.tanakaHRmax(age: a), .tanaka)
        } else {
            (hrMax, maxSource) = (nil, .unavailable)
        }
        let candidates: [(Double?, RestingSource)] = [(declaredResting, .declared), (sleepResting, .sameDaySleep),
                                                      (causalResting, .causalSleepReference)]
        let usable = candidates.first { c in
            guard let v = c.0, v.isFinite, v > 0 else { return false }
            return hrMax.map { v < $0 } ?? true
        }
        return HRCalibration(hrMax: hrMax, hrMaxSource: maxSource, restingHR: usable?.0,
                             restingSource: usable?.1 ?? .unavailable, effectiveDay: day)
    }
}
