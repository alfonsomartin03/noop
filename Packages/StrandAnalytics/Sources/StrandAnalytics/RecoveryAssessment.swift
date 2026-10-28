import Foundation

// RecoveryAssessment.swift — recovery as separate, explainable dimensions instead of one opaque percentage.
//
//   legacy        RecoveryScorer's logistic composite, weights fitted to ONE person's WHOOP export. Kept, versioned,
//                 for continuity/comparison. It is an index, not a measured percentage of anything recovered.
//   sleep         24-h sleep vs a declared target (SleepAccounting.shortfall). Efficiency is shown, never used to
//                 call a short night adequate.
//   autonomic     ln RMSSD and sleeping resting HR vs causal robust personal references (CausalReference), as
//                 signed deviations. No "good/bad" direction is implied: unusually HIGH HRV or LOW HR is flagged too.
//   unusual       deviations large enough to look at, each with the measurement quality behind it.
//
// Correlated signals are not stacked as independent confirmations: respiration inferred from the same R-R series as
// HRV is not added as evidence (it is experimental and shown elsewhere), and there is no separate "stress" term.
// Every threshold below is a provisional NOOP choice exposed as a static to tune, not a validated cut-off.

/// Measurement quality of a night's vitals (from SleepVitals).
public struct VitalsQuality: Equatable, Sendable {
    public let hrvWindows: Int
    public let hrvPairs: Int
    public let hrvWindowsByThird: [Int]
    public let hrvTemporalCoverage: Double
    public let hrWindows: Int
    public var hrvSpansNight: Bool { hrvWindowsByThird.filter { $0 > 0 }.count >= 2 }

    public init(hrvWindows: Int, hrvPairs: Int, hrvWindowsByThird: [Int], hrvTemporalCoverage: Double, hrWindows: Int) {
        self.hrvWindows = hrvWindows; self.hrvPairs = hrvPairs; self.hrvWindowsByThird = hrvWindowsByThird
        self.hrvTemporalCoverage = hrvTemporalCoverage; self.hrWindows = hrWindows
    }
    public init(_ v: SleepVitals) {
        self.init(hrvWindows: v.hrvWindowCount, hrvPairs: v.hrvPairCount, hrvWindowsByThird: v.hrvWindowsByThird,
                  hrvTemporalCoverage: v.hrvTemporalCoverage, hrWindows: v.hrWindowCount)
    }
}

public enum Completeness: String, Equatable, Sendable { case complete, partial, unavailable }

public struct RecoveryAssessment: Equatable, Sendable {
    public struct Legacy: Equatable, Sendable {
        public let modelVersion: String
        public let score: Double?
        public let breakdown: RecoveryScorer.Breakdown?
        /// Why `score` is nil although inputs existed (quality guard), else nil.
        public let withheldReason: String?
    }
    public struct SleepSufficiency: Equatable, Sendable {
        public let shortfall: SleepAccounting.Shortfall
        /// Descriptive only (sleep ÷ observed inferred period, 0…1).
        public let efficiency: Double?
    }
    public struct Autonomic: Equatable, Sendable {
        public let lnRMSSD: Double?
        public let lnRMSSDz: Double?
        public let rmssdReference: ReferenceSnapshot?
        public let restingHR: Double?
        public let restingHRz: Double?
        public let restingHRReference: ReferenceSnapshot?
        public let quality: VitalsQuality?
        public let completeness: Completeness
        public let notes: [String]
    }
    public struct Flag: Equatable, Sendable {
        public let metric: String
        public let message: String
        /// True when the measurement behind it is marginal: look, but don't act on it.
        public let lowQuality: Bool
    }

    public let legacy: Legacy
    public let sleep: SleepSufficiency
    public let autonomic: Autonomic
    public let unusual: [Flag]
    public let completeness: Completeness
}

public enum RecoveryAssessor {
    /// RecoveryScorer weights/logistic fitted to a single WHOOP export (docs/WHOOP_REVERSE_ENGINEERING.md), raw-unit
    /// RMSSD, EWMA mean-abs-dev baselines. Any change to that model must change this string.
    public static let legacyModelVersion = "legacy-whoop-fit-v1"
    /// Valid 5-min HRV windows (and spread over ≥ 2 thirds of the night) for a night to count as good quality.
    public static var goodQualityHRVWindows = 12
    /// |z| beyond which a deviation is "extreme" (legacy guard) / "unusual" (flag).
    public static var extremeZ = 3.0
    public static var unusualZ = 2.0

    public static func assess(sleep24hMin: Double?, mainSleepS: Double, efficiency: Double?,
                              hrv: Double?, restingHR: Int?, quality: VitalsQuality?,
                              baselines: AnalyticsEngine.ProfileBaselines,
                              minMainSleepS: Double) -> RecoveryAssessment {
        let goodQuality = quality.map { $0.hrvWindows >= goodQualityHRVWindows && $0.hrvSpansNight } ?? false

        // ── Legacy composite (comparison path) ──
        var legacyScore: Double? = nil, legacyBreakdown: RecoveryScorer.Breakdown? = nil, withheld: String? = nil
        if mainSleepS >= minMainSleepS, let h = hrv, let r = restingHR, let hb = baselines.hrv {
            // Respiration is NOT passed: the fitted weight belongs to WHOOP's measured rate, not NOOP's inferred one.
            legacyBreakdown = RecoveryScorer.breakdown(
                hrv: h, rhr: Double(r), resp: nil,
                hrvBaseline: .init(hb), rhrBaseline: baselines.restingHR.map(RecoveryScorer.DriverBaseline.init),
                respBaseline: nil, sleepPerf: efficiency, hrvBaselineUsable: hb.usable)
            if let b = legacyBreakdown {
                let hrvZ = b.terms.first { $0.name.hasPrefix("HRV") }?.z ?? 0
                if !goodQuality && abs(hrvZ) > extremeZ {
                    withheld = "extreme HRV deviation (z \(String(format: "%.1f", hrvZ))) from a marginal-quality night"
                } else { legacyScore = b.score }
            }
        }
        let legacy = RecoveryAssessment.Legacy(modelVersion: legacyModelVersion, score: legacyScore,
                                               breakdown: legacyBreakdown, withheldReason: withheld)

        // ── Sleep sufficiency ──
        let sleep = RecoveryAssessment.SleepSufficiency(
            shortfall: SleepAccounting.shortfall(sleepMin: sleep24hMin, targetMin: baselines.sleepTargetMin),
            efficiency: efficiency)

        // ── Autonomic deviation ──
        var notes: [String] = []
        func z(_ x: Double?, _ ref: ReferenceSnapshot?, _ name: String) -> Double? {
            guard let x else { return nil }
            guard let ref else { notes.append("\(name): no prior nights"); return nil }
            guard ref.state == .provisional || ref.state == .established else {
                notes.append("\(name): reference \(ref.state.rawValue)"); return nil
            }
            return (x - ref.center) / ref.scale
        }
        let lnH = hrv.flatMap { $0 > 0 && $0.isFinite ? Foundation.log($0) : nil }
        let zH = z(lnH, baselines.lnRMSSDReference, "HRV")
        let rhrD = restingHR.map(Double.init)
        let zR = z(rhrD, baselines.restingHRReference, "Resting HR")
        if let q = quality, !q.hrvSpansNight, hrv != nil { notes.append("valid HRV windows cover only one third of the night") }
        if let q = quality, hrv != nil, q.hrvWindows < goodQualityHRVWindows {
            notes.append("only \(q.hrvWindows) valid HRV windows")
        }
        let autoC: Completeness = (zH != nil && zR != nil) ? .complete : (zH != nil || zR != nil) ? .partial : .unavailable
        let autonomic = RecoveryAssessment.Autonomic(
            lnRMSSD: lnH, lnRMSSDz: zH, rmssdReference: baselines.lnRMSSDReference,
            restingHR: rhrD, restingHRz: zR, restingHRReference: baselines.restingHRReference,
            quality: quality, completeness: autoC, notes: notes)

        // ── Unusual values (either direction) ──
        var flags: [RecoveryAssessment.Flag] = []
        if let v = zH, abs(v) >= unusualZ {
            flags.append(.init(metric: "HRV (ln RMSSD)",
                               message: "\(v > 0 ? "above" : "below") personal reference (z \(String(format: "%.1f", v)))",
                               lowQuality: !goodQuality))
        }
        if let v = zR, abs(v) >= unusualZ {
            flags.append(.init(metric: "Resting HR (sleep)",
                               message: "\(v > 0 ? "above" : "below") personal reference (z \(String(format: "%.1f", v)))",
                               lowQuality: (quality?.hrWindows ?? 0) < goodQualityHRVWindows))
        }

        let parts = [sleep.shortfall.sleepMin != nil, autoC == .complete]
        let overall: Completeness = parts.allSatisfy { $0 } ? .complete
            : (sleep.shortfall.sleepMin != nil || autoC != .unavailable) ? .partial : .unavailable
        return RecoveryAssessment(legacy: legacy, sleep: sleep, autonomic: autonomic, unusual: flags, completeness: overall)
    }
}
