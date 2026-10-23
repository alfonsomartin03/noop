import Foundation
import WhoopProtocol

// StrainScorer.swift — cardiovascular load on a 0–21 logarithmic strain scale.
//
// Ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation of
// published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
// proprietary algorithm; not medical advice).
//
// Pipeline:
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
//   2. Per-sample intensity as %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
//   3. TRIMP accumulated over the window:
//        a. Edwards 5-zone summation (default): sample contributes its zone weight
//           (1..5 at 50/60/70/80/90 %HRR cut-offs) × duration.
//        b. Banister exponential: sample contributes duration × x × 0.64 × e^(b·x).
//   4. Logarithmic compression onto [0, 21]:
//        strain = 21 × ln(TRIMP + 1) / ln(D),  D = STRAIN_DENOMINATOR.
//
// References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
// (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 − 0.7×age).

// Entry points: strain() for one HR segment, dayStrain() to combine workouts into a day score.
// Three methods exist; .whoop (fitted to real WHOOP exports) is the default.
public enum StrainScorer {

    // MARK: - Constants (strain.py)

    /// Minimum HR readings before computing strain (≈10 min at 1 Hz).
    public static let minReadings: Int = 600
    /// Top of the strain scale.
    public static let maxStrain: Double = 21.0

    /// Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
    /// (top zone weight 5 sustained 24 h = 7200) maps to exactly 21.0:
    /// D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1.
    public static let strainDenominator: Double = 7201.0
    static var lnStrainDenominator: Double { log(strainDenominator) }

    /// Fallback per-sample duration (minutes) — 1 s at 1 Hz.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Minimum HR samples before the observed high-percentile HRmax is trusted.
    public static let hrmaxMinSamples: Int = 600
    /// Upper percentile for the observed-HRmax estimate.
    public static let hrmaxPercentile: Double = 99.5

    /// Banister coefficients.
    public static let banisterScale: Double = 0.64
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    // MARK: - WHOOP-fitted model
    //
    // Fitted on a WHOOP export (428 workouts, 628 days; see docs/WHOOP_REVERSE_ENGINEERING.md):
    //   activity strain = 4.56 · ln(1 + Σ_z w_z · minutes in zone z)      MAE 0.67 on 0–21
    //   day strain      = 4.67 · ln(1 + 1.66 + Σ over workouts of the same sum)   MAE 0.90
    // Zones are %HRmax bands 50–60 / 60–70 / 70–80 / 80–90 / 90–100, the zones WHOOP reports.
    // The weights climb steeply: a zone-5 minute is worth ~18 zone-1 minutes.

    /// Per-minute weight of zones 1…5.
    public static let whoopZoneWeights: [Double] = [0.105, 0.110, 0.347, 0.749, 1.875]
    /// Lower edge of zones 1…5 as a fraction of HRmax.
    static let whoopZoneFloors: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    /// Scale of the activity-strain log map.
    public static let whoopActivityScale: Double = 4.56
    /// Scale of the day-strain log map.
    public static let whoopDayScale: Double = 4.67
    /// Constant added inside the day-strain log: the all-day baseline load (a rest day lands near 4.5).
    public static let whoopDayFloor: Double = 1.66

    /// Above this the strain curve flattens (see `softCeiling`): scores below it are untouched, so the
    /// fit to WHOOP's own numbers stays exact for normal days.
    static let strainKnee: Double = 16.0
    /// Highest value that can ever be reported; 21 itself is unreachable, like WHOOP.
    static let strainTop: Double = 20.99

    /// Smoothly squeezes a raw log-scale strain into [0, 21). Identity up to `strainKnee`; beyond it each
    /// extra unit of effort adds less, approaching 21 but never reaching it (slope is 1 at the knee, so
    /// there is no visible kink). Without this, a long hard day simply clamped to a flat 21.0.
    static func softCeiling(_ raw: Double) -> Double {
        guard raw > strainKnee else { return max(0, raw) }
        let room = maxStrain - strainKnee
        return min(strainTop, strainKnee + room * (1 - exp(-(raw - strainKnee) / room)))
    }

    /// TRIMP accumulation method.
    public enum Method: Sendable { case edwards, banister, whoop }

    /// Σ w_z · minutes-in-zone-z over `hr`, zones taken from %HRmax. Below zone 1 contributes nothing.
    // Walks every HR sample, finds the highest %HRmax zone floor it clears and adds that zone's
    // per-minute weight. Samples below 50% HRmax add nothing, so idle time never inflates strain.
    static func whoopZoneLoad(_ hr: [HRSample], maxHR: Double, sampleDurationMin: Double) -> Double {
        var load = 0.0
        for s in hr {
            let frac = Double(s.bpm) / maxHR
            if let z = whoopZoneFloors.lastIndex(where: { frac >= $0 }) {
                load += whoopZoneWeights[z] * sampleDurationMin
            }
        }
        return load
    }

    /// Longest span (s) one sample may be credited with. A longer gap is missing data (strap off, BLE drop) and earns
    /// nothing, so gaps can never add invented load.
    public static let maxCreditS: Double = 5

    /// Zone load by TIME: each sample is credited the time to the next one (capped at `maxCreditS`), so duplicates add
    /// nothing, gaps add nothing and the result does not depend on the sampling rate. Input is sorted internally.
    public static func whoopZoneLoadTimed(_ hr: [HRSample], maxHR: Double) -> Double {
        guard maxHR > 0, !hr.isEmpty else { return 0 }
        let s = hr.sorted { $0.ts < $1.ts }
        var load = 0.0
        for i in s.indices {
            let dt = i + 1 < s.count ? min(Double(s[i + 1].ts - s[i].ts), maxCreditS) : 1.0
            guard dt > 0 else { continue }
            let frac = Double(s[i].bpm) / maxHR
            if let z = whoopZoneFloors.lastIndex(where: { frac >= $0 }) { load += whoopZoneWeights[z] * dt / 60.0 }
        }
        return load
    }

    /// Waking time over which the rest-day baseline fully accrues (a typical 16 h waking day).
    public static let awakeDaySeconds: Double = 16 * 3600

    /// Seconds of the half-open [from, to) actually covered by HR (each sample credited like the load above),
    /// leaving out time inside `excluding` spans (sleep): the baseline is a waking-hours load.
    public static func coveredSeconds(_ hr: [HRSample], from: Int, to: Int,
                                      excluding: [(start: Int, end: Int)] = []) -> Double {
        let s = hr.filter { x in x.ts >= from && x.ts < to && !excluding.contains { x.ts >= $0.start && x.ts <= $0.end } }
            .sorted { $0.ts < $1.ts }
        var c = 0.0
        for i in s.indices { c += i + 1 < s.count ? min(Double(s[i + 1].ts - s[i].ts), 60) : 1 }
        return c
    }

    /// Day strain from the zone loads of the day's workouts. The floor stands in for the unmeasured
    /// all-day load, so pass workout segments only (not the whole day's HR) to avoid double counting.
    // Log-compress so strain has diminishing returns: the 10th hard hour adds far less than the 1st.
    // `coverage` (0…1) is the share of a full waking day the HR actually covers (sleep excluded). The rest-day floor is the all-day baseline,
    // so it accrues with recorded time: a day that has just begun (or a strap-off day) must not start at ~4.6.
    public static func dayStrain(workoutLoads: [Double], coverage: Double = 1.0) -> Double {
        let floor = whoopDayFloor * max(0, min(1, coverage))
        let value = softCeiling(whoopDayScale * log(1.0 + floor + workoutLoads.reduce(0, +)))
        return (value * 100).rounded() / 100
    }

    /// Sustained high-intensity effort the motion gate misses (cycling, rowing, lifting: wrist barely
    /// moves while HR is high). Runs of HR ≥ 70 % HRmax lasting ≥ `minHighHRRunS`, bridging gaps of up
    /// to `mergeGapS`, outside `excluding` (already-counted workout ranges). Returns their zone load.
    public static let minHighHRRunS = 300
    // Cycling/rowing safety net: counts long hard-HR stretches that detection did not already claim as a workout.
    public static func highEffortLoad(_ hr: [HRSample], maxHR: Double,
                                      excluding: [(start: Int, end: Int)]) -> Double {
        guard maxHR > 0 else { return 0 }
        let sorted = hr.sorted { $0.ts < $1.ts }
        // Keep only samples at >=70% HRmax that fall outside already-counted workout ranges.
        let hot = sorted.filter { s in
            Double(s.bpm) / maxHR >= 0.7 && !excluding.contains { s.ts >= $0.start && s.ts <= $0.end }
        }
        guard !hot.isEmpty else { return 0 }
        var load = 0.0
        var run: [HRSample] = [hot[0]]
        // Only runs lasting >= minHighHRRunS count; shorter ones are just spikes (stairs, a sprint to the bus).
        func flush() {
            if let f = run.first, let l = run.last, l.ts - f.ts >= minHighHRRunS {
                load += whoopZoneLoadTimed(run, maxHR: maxHR)
            }
        }
        for h in hot.dropFirst() {
            // A gap over 150 s ends the current run and starts a new one.
            if h.ts - run[run.count - 1].ts > 150 { flush(); run = [h] } else { run.append(h) }
        }
        flush()
        return load
    }

    /// Fitted activity strain (0–21) of one workout's HR segment: 4.56 · ln(1 + zone load).
    public static func activityStrain(_ hr: [HRSample], maxHR: Double) -> Double {
        guard maxHR > 0, !hr.isEmpty else { return 0 }
        let load = whoopZoneLoadTimed(hr, maxHR: maxHR)
        return (softCeiling(whoopActivityScale * log(1.0 + load)) * 100).rounded() / 100
    }

    /// Zone load of one HR segment, or nil when it is too short or maxHR is unusable.
    // Needs >= minReadings samples so a few seconds of data can't yield a score.
    public static func whoopLoad(_ hr: [HRSample], maxHR: Double? = nil) -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        guard hr.count >= minReadings, effMax > 0 else { return nil }
        return whoopZoneLoad(hr, maxHR: effMax, sampleDurationMin: sampleDurationMinutes(hr))
    }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent).
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Classic 220 − age. Last-resort fallback only.
    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

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

    /// Estimate a personalized HRmax from a trailing HR series.
    /// Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
    // Prefer the observed 99.5th-percentile HR once enough data exists, but never go below Tanaka:
    // a lazy week of data must not lower the user's HRmax and inflate every zone.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let n = hrHistory.count
        let tanaka = age.map { tanakaHRmax(age: $0) }

        if n >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    // MARK: - Karvonen %HRR and Edwards zone weight

    /// Karvonen %HRR, clamped [0, 100].
    static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        if pct < 0 { return 0 }
        if pct > 100 { return 100 }
        return pct
    }

    /// Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
    /// the clamped path at both ends).
    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - TRIMP accumulation

    /// Infer per-sample duration (minutes) from the first two timestamps. Falls
    /// back to 1 s when fewer than two samples or coincident timestamps.
    // Duration is inferred from sample spacing so the same maths works for 1 Hz and sparser data.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let deltaS = abs(Double(hr[1].ts - hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                             sampleDurationMin: Double) -> Double {
        var weighted = 0
        for s in hr { weighted += zoneWeight(Double(s.bpm), restingHR: restingHR, hrReserve: hrReserve) }
        return Double(weighted) * sampleDurationMin
    }

    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                              sampleDurationMin: Double, b: Double) -> Double {
        var acc = 0.0
        for s in hr {
            let x = pctHRR(Double(s.bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 { acc += sampleDurationMin * x * banisterScale * exp(b * x) }
        }
        return acc
    }

    // MARK: - Logarithmic map

    /// Map accumulated TRIMP onto [0, 21] via 21 × ln(TRIMP+1) / ln(D), 2 dp.
    /// TRIMP ≤ 0 → 0.
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        if trimp <= 0 { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        return (value * 100).rounded() / 100
    }

    // MARK: - Denominator calibration

    /// Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
    /// least-squares line: ln(D) = 21 × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
    /// Throws when fewer than 2 usable pairs (TRIMP>0, strain>0) or degenerate.
    // Least-squares calibration of the log map against reference strain values (used by Tools/).
    public static func fitStrainDenominator(_ pairs: [(trimp: Double, strain: Double)]) throws -> Double {
        let usable = pairs.filter { $0.trimp > 0 && $0.strain > 0 }
        guard usable.count >= 2 else { throw StrainError.tooFewPairs }
        var sumXX = 0.0, sumXY = 0.0
        for (trimp, strain) in usable {
            let x = log(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        guard sumXY > 0 && sumXX > 0 else { throw StrainError.degenerate }
        return exp(maxStrain * sumXX / sumXY)
    }

    public enum StrainError: Error, Equatable, Sendable {
        case tooFewPairs
        case degenerate
    }

    // MARK: - Public API

    /// Cardiovascular strain (0–21) from an HR series. APPROXIMATE.
    ///
    /// Returns nil when there are fewer than `minReadings` samples or
    /// maxHR ≤ restingHR (invalid HRR).
    ///
    /// - Parameters:
    ///   - hr: time-ordered `[HRSample]`.
    ///   - maxHR: HRmax (bpm). Defaults to 220 − defaultAge when nil.
    ///   - restingHR: resting HR (bpm) for the HRR denominator (default 60).
    ///   - method: `.whoop` (default, fitted to WHOOP's activity strain: %HRmax zones, weights 1:1:3.3:7:18),
    ///     `.edwards` or `.banister`. `denominator` applies to those two only.
    ///   - sex: "male"/"female" — selects the Banister coefficient (ignored by Edwards).
    ///   - denominator: log-map D (default STRAIN_DENOMINATOR).
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              method: Method = .whoop,
                              sex: String = "male",
                              denominator: Double = strainDenominator) -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        // Refuse to score on too little data or an impossible HRR rather than return a misleading number.
        if hr.count < minReadings || effMax <= restingHR { return nil }

        let sampleDur = sampleDurationMinutes(hr)
        let hrReserve = effMax - restingHR

        if method == .whoop {
            let load = whoopZoneLoad(hr, maxHR: effMax, sampleDurationMin: sampleDur)
            if load <= 0 { return 0 }
            return (softCeiling(whoopActivityScale * log(1.0 + load)) * 100).rounded() / 100
        }

        let trimp: Double
        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            trimp = banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                  sampleDurationMin: sampleDur, b: b)
        case .edwards, .whoop:
            trimp = edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                 sampleDurationMin: sampleDur)
        }
        return trimpToStrain(trimp, denominator: denominator)
    }
}
