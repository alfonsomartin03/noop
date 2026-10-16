import Foundation
import WhoopProtocol

// WorkoutDetector.swift — retroactive workout detection from the 1 Hz store.
//
// Ported from server/ingest/app/analysis/exercise.py (+ activity.py, calories.py).
//
// A workout is a SUSTAINED window (≥ MIN_EXERCISE_MIN) of elevated HR (above
// resting + HR_MARGIN_BPM) AND sustained motion (gravity-derived intensity above
// MOTION_THRESHOLD). Both gates must hold for a sample to count as active.
//
// Per detected bout: avg/peak HR, duration, Edwards zone time-%, mean %HRR,
// strain (StrainScorer), and estimated calories (Keytel 2005 active + revised
// Harris–Benedict BMR resting, age/sex/weight/height adjusted).
//
// All intensity/energy outputs are APPROXIMATE and not medical advice.

// MARK: - Profile + result

/// User profile for calorie estimation.
public struct UserProfile: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double
    public var age: Double
    public var sex: String   // "male" | "female" | "nonbinary"
    public init(weightKg: Double = 70.0, heightCm: Double = 170.0,
                age: Double = 30.0, sex: String = "nonbinary") {
        self.weightKg = weightKg; self.heightCm = heightCm
        self.age = age; self.sex = sex
    }
}

/// A detected workout window. All intensity fields are APPROXIMATE.
public struct ExerciseSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let avgHR: Double
    public let peakHR: Int
    public let strain: Double?
    public let durationS: Double
    /// Edwards zone (0–5) time breakdown as % of HR samples; sums to 100.
    public let zoneTimePct: [Int: Double]
    /// Mean Karvonen %HRR over the bout, clamped [0, 100], or nil.
    public let avgHRRPct: Double?
    /// Effective HRmax used for zone math (bpm), or nil.
    public let hrmax: Double?
    /// "caller" | "observed" | "tanaka" | "unknown".
    public let hrmaxSource: String
    public let caloriesKcal: Double?
    public let caloriesKJ: Double?

    public init(start: Int, end: Int, avgHR: Double, peakHR: Int, strain: Double?,
                durationS: Double, zoneTimePct: [Int: Double], avgHRRPct: Double?,
                hrmax: Double?, hrmaxSource: String,
                caloriesKcal: Double?, caloriesKJ: Double?) {
        self.start = start; self.end = end; self.avgHR = avgHR; self.peakHR = peakHR
        self.strain = strain; self.durationS = durationS; self.zoneTimePct = zoneTimePct
        self.avgHRRPct = avgHRRPct; self.hrmax = hrmax; self.hrmaxSource = hrmaxSource
        self.caloriesKcal = caloriesKcal; self.caloriesKJ = caloriesKJ
    }
}

public enum WorkoutDetector {

    // MARK: - Constants (exercise.py)

    public static let minExerciseMin: Double = 5.0
    public static let hrMarginBPM: Double = 15.0
    public static let motionThreshold: Double = 0.20
    public static let motionSmoothS: Double = 10.0
    public static let mergeGapS: Double = 150.0
    public static let minIntensityZ2Plus: Double = 0.50
    public static let alignToleranceS: Double = 5.0
    public static let restingPercentile: Double = 10.0

    // HR-only detector (catches cycling / rowing / lifting where the wrist barely moves). Modelled on
    // published auto-detection approaches (WHOOP: sustained HR rise over baseline + enough duration to
    // reject spikes; patents describe threshold-based start/end of an elevated interval, then a check).
    /// Rolling-median window smoothing single-sample HR spikes.
    public static let hrSmoothS: Int = 60
    /// Smoothed HR must exceed rest + max(hrOnlyMarginBPM, hrOnlyMinHRRFrac × HRR) to count as active.
    public static let hrOnlyMarginBPM: Double = 30.0
    public static let hrOnlyMinHRRFrac: Double = 0.35
    /// Minimum length of an HR-only bout (longer than the motion-gated 5 min: no motion corroboration).
    public static let hrOnlyMinMin: Double = 10.0
    /// Gaps up to this long inside an effort are bridged (rest between sets, a stop light, a drink).
    public static let hrOnlyBridgeS: Int = 300

    // MARK: - Activity series (activity.py)

    public struct ActivityPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
    }

    /// Per-record motion-intensity series: L2 magnitude of the gravity change vs
    /// the previous record. First row → 0. Empty input → []. (GravitySample always
    /// carries finite x/y/z, so no dropout sentinel is required here.)
    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var series: [ActivityPoint] = []
        series.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0 { intensity = 0.0 }
            else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else { intensity = 0.0 }
            series.append(ActivityPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return series
    }

    // MARK: - Helpers

    /// Sorted (ts, bpm) pairs.
    static func cleanHR(_ hr: [HRSample]) -> [(ts: Int, bpm: Double)] {
        hr.map { (ts: $0.ts, bpm: Double($0.bpm)) }.sorted { $0.ts < $1.ts }
    }

    /// Day resting-HR baseline = nearest-rank RESTING_PERCENTILE of bpm values.
    static func deriveRestingHR(_ hrSeg: [(ts: Int, bpm: Double)]) -> Double {
        let bpms = hrSeg.map { $0.bpm }.sorted()
        precondition(!bpms.isEmpty, "deriveRestingHR called with empty segment")
        let rank = max(1, Int(ceil(restingPercentile / 100.0 * Double(bpms.count))))
        return bpms[rank - 1]
    }

    /// Value whose ts is nearest to `ts` within `tol` seconds, else nil. Ties go
    /// to the later timestamp (matches the Python <= behaviour).
    static func nearest(_ sortedTs: [Int], _ values: [Double], _ ts: Int, _ tol: Double) -> Double? {
        if sortedTs.isEmpty { return nil }
        // bisect_left
        var lo = 0, hi = sortedTs.count
        while lo < hi { let mid = (lo + hi) / 2; if sortedTs[mid] < ts { lo = mid + 1 } else { hi = mid } }
        let i = lo
        var bestV: Double? = nil
        var bestD = tol
        for j in [i - 1, i] where j >= 0 && j < sortedTs.count {
            let d = abs(Double(sortedTs[j] - ts))
            if d <= bestD { bestD = d; bestV = values[j] }
        }
        return bestV
    }

    /// Trailing rolling mean (over window_s) of intensities (all finite here).
    static func smoothedIntensity(_ motion: [ActivityPoint], windowS: Double) -> [Double] {
        let ts = motion.map { $0.ts }
        let raw = motion.map { $0.intensity.isFinite ? $0.intensity : 0.0 }
        var out: [Double] = []
        out.reserveCapacity(motion.count)
        var lo = 0
        var running = 0.0
        for i in 0..<motion.count {
            running += raw[i]
            while Double(ts[i] - ts[lo]) > windowS { running -= raw[lo]; lo += 1 }
            out.append(running / Double(i - lo + 1))
        }
        return out
    }

    /// Per-bout Edwards zone breakdown (%) + mean %HRR. APPROXIMATE.
    static func boutIntensity(_ hrSeries: [(ts: Int, bpm: Double)],
                              restingHR: Double, maxHR: Double) -> ([Int: Double], Double?) {
        if hrSeries.isEmpty || maxHR <= restingHR { return ([:], nil) }
        let hrReserve = maxHR - restingHR
        var zoneCounts = [Int: Int]()
        for z in 0...5 { zoneCounts[z] = 0 }
        var hrrVals: [Double] = []
        for r in hrSeries {
            let z = StrainScorer.zoneWeight(r.bpm, restingHR: restingHR, hrReserve: hrReserve)
            zoneCounts[z, default: 0] += 1
            hrrVals.append(StrainScorer.pctHRR(r.bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
        let n = Double(hrSeries.count)
        var zonePct = [Int: Double]()
        for (z, c) in zoneCounts { zonePct[z] = ((Double(c) / n * 100.0) * 10).rounded() / 10 }
        let avgHRR = ((hrrVals.reduce(0, +) / n) * 10).rounded() / 10
        return (zonePct, avgHRR)
    }

    /// Rolling median of bpm over the trailing `windowS` seconds (robust to single-sample spikes).
    static func smoothedHR(_ hr: [(ts: Int, bpm: Double)], windowS: Int) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(hr.count)
        var lo = 0
        for i in 0..<hr.count {
            while hr[i].ts - hr[lo].ts > windowS { lo += 1 }
            let w = hr[lo...i].map { $0.bpm }.sorted()
            out.append(w[w.count / 2])
        }
        return out
    }

    /// Runs of sustained elevated HR (no motion needed), ≥ hrOnlyMinMin long after bridging short dips.
    static func hrOnlyRuns(_ hr: [(ts: Int, bpm: Double)], restingHR: Double, maxHR: Double?) -> [(Int, Int)] {
        guard hr.count > 1 else { return [] }
        let hrr = max(0.0, (maxHR ?? 190.0) - restingHR)
        let threshold = restingHR + max(hrOnlyMarginBPM, hrOnlyMinHRRFrac * hrr)
        let sm = smoothedHR(hr, windowS: hrSmoothS)
        var raw: [(Int, Int)] = []
        var start: Int? = nil
        var last = 0
        for (i, r) in hr.enumerated() {
            if sm[i] > threshold {
                if start == nil { start = r.ts }
                last = r.ts
            } else if let s0 = start, r.ts - last > 1 {
                raw.append((s0, last)); start = nil
            }
        }
        if let s0 = start { raw.append((s0, last)) }
        // The trailing median lags the true edges by ~half its window, so clip each run to its first/last
        // raw sample above the threshold.
        return unionRuns(raw, bridgeS: hrOnlyBridgeS).compactMap { r -> (Int, Int)? in
            let hot = hr.filter { $0.ts >= r.0 && $0.ts <= r.1 && $0.bpm > threshold }
            guard let a = hot.first?.ts, let b = hot.last?.ts else { return nil }
            return Double(b - a) >= hrOnlyMinMin * 60.0 ? (a, b) : nil
        }
    }

    /// Sort and merge runs whose gap is ≤ bridgeS.
    static func unionRuns(_ runs: [(Int, Int)], bridgeS: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for r in runs.sorted(by: { $0.0 < $1.0 }) {
            if let l = out.last, r.0 - l.1 <= bridgeS { out[out.count - 1].1 = max(l.1, r.1) } else { out.append(r) }
        }
        return out
    }

    // MARK: - Public API

    /// Detect workouts from the 1 Hz HR + gravity store.
    ///
    /// - Parameters:
    ///   - hr: heart-rate stream (required; empty → []).
    ///   - gravity: gravity stream (required; empty → []).
    ///   - restingHR: day resting-HR baseline (bpm). nil → derived as the 10th
    ///     percentile of the day's HR.
    ///   - maxHR: HRmax (bpm). nil → estimated via StrainScorer.estimateHRmax.
    ///   - age: used only for the Tanaka fallback when maxHR is nil.
    ///   - profile: when provided, per-bout calories are estimated.
    public static func detect(hr: [HRSample],
                              gravity: [GravitySample],
                              restingHR: Double? = nil,
                              maxHR: Double? = nil,
                              age: Double? = nil,
                              profile: UserProfile? = nil) -> [ExerciseSession] {
        let hrSeg = cleanHR(hr)
        let motion = activitySeries(gravity)
        if hrSeg.isEmpty { return [] }

        let restHR = restingHR ?? deriveRestingHR(hrSeg)
        let hrFloor = restHR + hrMarginBPM

        let effMaxHR: Double?
        let hrmaxSource: String
        if let m = maxHR {
            effMaxHR = m; hrmaxSource = "caller"
        } else {
            let (est, src) = StrainScorer.estimateHRmax(hrSeg.map { $0.bpm }, age: age)
            effMaxHR = est == 0.0 ? nil : est
            hrmaxSource = src
        }

        let hrTs = hrSeg.map { $0.ts }
        let hrBpm = hrSeg.map { $0.bpm }
        let smooth = smoothedIntensity(motion, windowS: motionSmoothS)

        // Detector 1 — motion + HR: walk the gravity timeline; flag samples where BOTH gates hold.
        var activeTs: [Int] = []
        for (p, inten) in zip(motion, smooth) {
            if inten <= motionThreshold { continue }
            guard let bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS), bpm > hrFloor else { continue }
            activeTs.append(p.ts)
        }

        // Group contiguous active samples into runs, merging gaps < MERGE_GAP_S.
        var runs: [(Int, Int)] = []
        if let first = activeTs.first {
            var runStart = first
            var prev = first
            for ts in activeTs.dropFirst() {
                if Double(ts - prev) > mergeGapS { runs.append((runStart, prev)); runStart = ts }
                prev = ts
            }
            runs.append((runStart, prev))
        }
        // Onset latency tolerance equal to the smoothing window (same rule as before).
        runs = runs.filter { Double($0.1 - $0.0) >= minExerciseMin * 60.0 - motionSmoothS }

        // Detector 2 — HR only: sustained smoothed HR well above rest, regardless of wrist motion.
        let hrOnly = hrOnlyRuns(hrSeg, restingHR: restHR, maxHR: effMaxHR)

        // Union both detectors' runs; overlapping or nearly-touching runs become one workout.
        runs = unionRuns(runs + hrOnly, bridgeS: Int(mergeGapS))
        if runs.isEmpty { return [] }

        var sessions: [ExerciseSession] = []
        for (start, end) in runs {
            let window = hrSeg.filter { $0.ts >= start && $0.ts <= end }
            if window.isEmpty { continue }
            let bpms = window.map { $0.bpm }
            let hrSamples = window.map { HRSample(ts: $0.ts, bpm: Int($0.bpm.rounded())) }

            var zonePct: [Int: Double] = [:]
            var avgHRR: Double? = nil
            if let m = effMaxHR, m > restHR {
                (zonePct, avgHRR) = boutIntensity(window, restingHR: restHR, maxHR: m)
            }

            // Intensity qualification: require ≥ MIN_INTENSITY_Z2PLUS in zone 2+.
            if !zonePct.isEmpty {
                let z2plus = (2...5).reduce(0.0) { $0 + (zonePct[$1] ?? 0.0) } / 100.0
                if z2plus < minIntensityZ2Plus { continue }
            }

            var kcal: Double? = nil
            var kj: Double? = nil
            if let profile = profile {
                let (k, j) = Calories.estimateBoutCalories(hrSamples, profile: profile,
                                                           hrmax: effMaxHR, restingHR: restHR)
                kcal = k; kj = j
            }

            let avg = bpms.reduce(0, +) / Double(bpms.count)
            let peak = Int(bpms.max()!.rounded())
            let strain = StrainScorer.strain(hrSamples, maxHR: effMaxHR, restingHR: restHR)

            sessions.append(ExerciseSession(
                start: start, end: end, avgHR: avg, peakHR: peak, strain: strain,
                durationS: Double(end - start), zoneTimePct: zonePct, avgHRRPct: avgHRR,
                hrmax: effMaxHR, hrmaxSource: hrmaxSource, caloriesKcal: kcal, caloriesKJ: kj))
        }
        return sessions
    }
}

// MARK: - Calories (calories.py)

/// HR-based calorie estimation (Keytel 2005 active + revised Harris–Benedict BMR).
/// APPROXIMATE — not laboratory calorimetry, not medical advice.
public enum Calories {

    struct Coeffs {
        let restingAlpha: Double
        let restingWeight: Double
        let restingHeight: Double  // applied to height in METRES
        let restingAge: Double
        let workoutHR: Double
        let workoutWeight: Double
        let workoutAge: Double
        let workoutAlpha: Double
    }

    static let male = Coeffs(restingAlpha: 88.362, restingWeight: 13.397, restingHeight: 479.9,
                             restingAge: 5.677, workoutHR: 0.6309, workoutWeight: 0.1988,
                             workoutAge: 0.2017, workoutAlpha: -55.0969)
    static let female = Coeffs(restingAlpha: 447.593, restingWeight: 9.247, restingHeight: 309.8,
                               restingAge: 4.33, workoutHR: 0.4472, workoutWeight: -0.1263,
                               workoutAge: 0.0740, workoutAlpha: -20.4022)
    static let nonbinary = Coeffs(restingAlpha: 267.9775, restingWeight: 11.322, restingHeight: 394.85,
                                  restingAge: 5.0035, workoutHR: 0.53905, workoutWeight: 0.03625,
                                  workoutAge: 0.13785, workoutAlpha: -37.74955)

    static let activeHRRFraction = 0.30
    static let workoutDivisor = 251.04  // 60 s/min × 4.184 kJ/kcal

    static func resolveCoeffs(_ sex: String) -> Coeffs {
        switch sex.lowercased() {
        case "male": return male
        case "female": return female
        case "nonbinary": return nonbinary
        default: return nonbinary
        }
    }

    static func restingKcalPerS(_ c: Coeffs, weightKg: Double, heightCm: Double, age: Double) -> Double {
        let heightM = heightCm / 100.0
        let bmr = c.restingAlpha + c.restingWeight * weightKg + c.restingHeight * heightM - c.restingAge * age
        return max(0.0, bmr) / 86_400.0
    }

    static func activeKcalPerS(_ c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double) -> Double {
        let eeKjMin = c.workoutHR * min(hr, hrmax) + c.workoutWeight * weightKg
            + c.workoutAge * age + c.workoutAlpha
        return max(0.0, eeKjMin) / workoutDivisor
    }

    /// Estimate (kcal, kJ) for a workout bout. Each HR sample = 1 second of data.
    public static func estimateBoutCalories(_ hrSamples: [HRSample],
                                            profile: UserProfile,
                                            hrmax: Double?,
                                            restingHR: Double?) -> (Double, Double) {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = resolveCoeffs(profile.sex)

        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)

        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)

        var totalKcal = 0.0
        for s in hrSamples {
            let bpm = Double(s.bpm)
            if bpm < activeThreshold {
                totalKcal += restingRate
            } else {
                totalKcal += activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age)
            }
        }
        return (totalKcal, totalKcal * 4.184)
    }
}
