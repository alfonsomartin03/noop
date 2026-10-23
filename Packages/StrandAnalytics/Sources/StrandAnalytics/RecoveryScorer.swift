import Foundation
import WhoopProtocol

// RecoveryScorer.swift — resting HR during sleep + a transparent 0–100 recovery score.
//
// Ported from server/ingest/app/analysis/recovery.py.
//
// recovery() is a z-score + logistic composite. It is APPROXIMATE — not
// WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
// HRV-dominant, baseline-normalized proxy.
//
// Weighting, refitted to a WHOOP export (628 nights, MAE 4.5 vs WHOOP's score; was 5.8 with the
// previous 0.60/0.20/0.05/0.15 — see docs/WHOOP_REVERSE_ENGINEERING.md). HRV carries nearly all of it:
//   higher HRV vs baseline       → higher recovery  (W_HRV   = 0.86, dominant)
//   lower resting HR vs baseline → higher recovery  (W_RHR   = 0.04)
//   lower resp vs baseline       → higher recovery  (W_RESP  = 0.07)
//   higher sleep performance     → higher recovery  (W_SLEEP = 0.03)
//
// Each metric is standardized to a robust z-score against the personal baseline
// (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
// renormalized. The composite z is squashed through a logistic anchored so that
// Z = 0 → ~58% (WHOOP's published population-average recovery).
//
// Cold-start: if the HRV baseline (dominant driver) is not yet usable
// (< MIN_NIGHTS_SEED valid nights), recovery() returns nil. Callers may use
// RECOVERY_POPULATION_MEAN (58.0) as a fallback but should flag it.

public enum RecoveryScorer {

    // MARK: - Constants (recovery.py)

    public static let wHRV: Double = 0.86
    public static let wRHR: Double = 0.04
    public static let wResp: Double = 0.07
    public static let wSleep: Double = 0.03

    /// Logistic steepness (fitted): ±3 z-units spans roughly 4%–96%.
    public static let logisticK: Double = 1.1
    /// Logistic offset so Z=0 → ~60% (fitted; WHOOP quotes a 58% population mean).
    public static let logisticZ0: Double = -0.39
    /// WHOOP-published population-average recovery (%). Cold-start fallback.
    public static let populationMean: Double = 58.0

    /// Recovery band thresholds (WHOOP color scheme).
    public static let bandRedMax: Double = 34.0
    public static let bandYellowMax: Double = 67.0

    /// Sleep-performance center ("good night" at ~85% efficiency).
    public static let sleepPerfCenter: Double = 0.85
    /// Sleep-performance scale (±2 z spans the normal range).
    public static let sleepPerfScale: Double = 0.12

    /// Rolling-mean HR window (seconds) for the resting-HR estimate.
    public static let restingHRWindowS: Int = 5 * 60

    // MARK: - Resting HR

    /// NOTE: this is the lowest 5-min mean HR ("floor"), NOT a resting heart rate: it sits ~5–10 bpm under a
    /// representative sleeping HR. The app's sleep-derived resting HR is `SleepVitalsCalculator` (mean of the
    /// lowest quartile of valid sleep windows). Kept for comparison and legacy callers.
    ///
    /// Lowest sustained HR during the in-bed window (bpm, rounded), or nil.
    ///
    /// "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
    /// samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
    /// the night's true floor. Returns nil when there are no HR samples in window.
    // Averages 5-minute bins and takes the lowest: robust to single-beat dips, still finds the night's floor.
    public static func restingHR(_ hr: [HRSample], start: Int, end: Int) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }

        var means: [Double] = []
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + restingHRWindowS }
            if !win.isEmpty {
                means.append(Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count))
            }
            t += restingHRWindowS
        }
        let floor: Double
        if let m = means.min() {
            floor = m
        } else {
            floor = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        }
        return Int(floor.rounded())
    }

    // MARK: - Recovery band

    /// WHOOP-style color band for a recovery score [0, 100].
    public static func band(_ score: Double) -> String {
        if score < bandRedMax { return "red" }
        if score < bandYellowMax { return "yellow" }
        return "green"
    }

    // MARK: - Recovery score

    /// A baseline driver: mean + spread (internal abs-dev units, as in BaselineState).
    public struct DriverBaseline: Equatable, Sendable {
        public let mean: Double
        public let spread: Double
        public init(mean: Double, spread: Double) {
            self.mean = mean; self.spread = spread
        }
        public init(_ state: BaselineState) {
            self.mean = state.baseline; self.spread = state.spread
        }
    }

    /// Robust z-score using EWMA spread: (value − mean) / (1.253 × spread).
    // 1.253 x mean-abs-deviation approximates a standard deviation, so the z-score is robust to outliers.
    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /// One driver's share of a recovery score, for diagnostics.
    public struct Term: Equatable, Sendable {
        public let name: String
        public let value: Double
        public let baselineMean: Double?
        public let baselineSpread: Double?
        public let z: Double
        public let weight: Double           // nominal weight
        public let normalizedWeight: Double // after dropping missing terms
        /// normalizedWeight × z: this driver's exact contribution to the composite z.
        public var contributionZ: Double { normalizedWeight * z }
    }

    public struct Breakdown: Equatable, Sendable {
        public let terms: [Term]
        public let compositeZ: Double
        public let score: Double
    }

    /// Z-score + logistic recovery with every term exposed. nil when the HRV baseline is unusable or no term exists.
    public static func breakdown(hrv: Double, rhr: Double, resp: Double?,
                                 hrvBaseline: DriverBaseline?, rhrBaseline: DriverBaseline?,
                                 respBaseline: DriverBaseline?, sleepPerf: Double?,
                                 hrvBaselineUsable: Bool = true) -> Breakdown? {
        if !hrvBaselineUsable { return nil }
        var raw: [(String, Double, DriverBaseline?, Double, Double)] = []   // name, value, baseline, z, w
        if let b = hrvBaseline { raw.append(("HRV (RMSSD)", hrv, b, zScore(hrv, mean: b.mean, spread: b.spread), wHRV)) }
        if let b = rhrBaseline { raw.append(("Resting HR", rhr, b, zScore(b.mean, mean: rhr, spread: b.spread), wRHR)) }
        if let r = resp, let b = respBaseline { raw.append(("Respiration", r, b, zScore(b.mean, mean: r, spread: b.spread), wResp)) }
        if let sp = sleepPerf { raw.append(("Sleep efficiency", sp, nil, (sp - sleepPerfCenter) / sleepPerfScale, wSleep)) }
        let total = raw.reduce(0) { $0 + $1.4 }
        guard !raw.isEmpty, total > 0 else { return nil }
        let terms = raw.map { Term(name: $0.0, value: $0.1, baselineMean: $0.2?.mean, baselineSpread: $0.2?.spread,
                                   z: $0.3, weight: $0.4, normalizedWeight: $0.4 / total) }
        let z = terms.reduce(0) { $0 + $1.contributionZ }
        let score = max(0.0, min(100.0, 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))))
        return Breakdown(terms: terms, compositeZ: z, score: score)
    }

    /// Z-score + logistic recovery score in [0, 100]. APPROXIMATE. (See `breakdown` for the per-driver terms.)
    ///
    /// Returns nil when the HRV baseline (dominant driver) is not yet usable, or no valid driver is available.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: DriverBaseline?,
                                rhrBaseline: DriverBaseline?,
                                respBaseline: DriverBaseline?,
                                sleepPerf: Double?,
                                hrvBaselineUsable: Bool = true) -> Double? {
        breakdown(hrv: hrv, rhr: rhr, resp: resp, hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                  respBaseline: respBaseline, sleepPerf: sleepPerf, hrvBaselineUsable: hrvBaselineUsable)?.score
    }

    /// Convenience overload taking BaselineState directly. Enforces the cold-start
    /// gate using `hrvBaseline.usable`.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: BaselineState,
                                rhrBaseline: BaselineState?,
                                respBaseline: BaselineState?,
                                sleepPerf: Double?) -> Double? {
        recovery(hrv: hrv,
                 rhr: rhr,
                 resp: resp,
                 hrvBaseline: DriverBaseline(hrvBaseline),
                 rhrBaseline: rhrBaseline.map(DriverBaseline.init),
                 respBaseline: respBaseline.map(DriverBaseline.init),
                 sleepPerf: sleepPerf,
                 hrvBaselineUsable: hrvBaseline.usable)
    }
}
