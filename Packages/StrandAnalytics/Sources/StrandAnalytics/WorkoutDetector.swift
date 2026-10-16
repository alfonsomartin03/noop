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
//
// HOW IT WORKS (big picture)
// --------------------------
// Two independent detectors each propose time windows ("runs"):
//   1. Motion + HR  — wrist movement AND elevated HR at the same time (running, HIIT, sports).
//   2. HR only      — sustained elevated HR with no motion needed (cycling, rowing, lifting,
//                     where the wrist barely moves).
// Their runs are unioned (overlapping/nearly-touching ones become one), then each candidate is
// checked for real intensity (zone time) before being reported with its stats.
// Pipeline: detect() → both detectors → unionRuns → intensity gate → ExerciseSession.

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

    // --- Detector 1 (motion + HR) and shared constants ---
    /// Minimum length of a motion-gated bout, in minutes.
    public static let minExerciseMin: Double = 5.0
    /// A sample only counts as active if HR is above resting + this many bpm.
    public static let hrMarginBPM: Double = 15.0
    /// Smoothed gravity-change magnitude above this means "moving".
    public static let motionThreshold: Double = 0.20
    /// Trailing window (seconds) used to average the motion signal.
    public static let motionSmoothS: Double = 10.0
    /// Active samples separated by less than this (seconds) belong to the same run.
    public static let mergeGapS: Double = 150.0
    /// Intensity gate: fraction of bout HR samples that must sit in Edwards zone 2+ (≥60% HRR).
    public static let minIntensityZ2Plus: Double = 0.50
    /// Max time difference (seconds) when pairing a motion sample with its nearest HR sample.
    public static let alignToleranceS: Double = 5.0
    /// Resting HR is estimated as this percentile of the day's HR when the caller gives none.
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
    /// Hysteresis: once an effort has started it continues while smoothed HR stays above
    /// rest + hrOnlyExitFrac × (entry margin), so steady endurance work that drifts just under the
    /// entry line (cardiac drift, easy descents) is not chopped up or clipped short.
    public static let hrOnlyExitFrac: Double = 0.75
    /// Two long efforts (each ≥ longEffortMin) separated by a pause up to this long are one session
    /// (a café stop mid-ride, a red-light queue, refilling a bottle).
    public static let longBridgeS: Int = 1500
    public static let longEffortMin: Double = 15.0
    /// Efforts at least this long are endurance sessions: zone 1+ time is enough to qualify them.
    public static let enduranceMin: Double = 30.0
    public static let enduranceMinZ1Plus: Double = 0.60

    // MARK: - Activity series (activity.py)

    /// One motion reading: timestamp plus how much the wrist orientation changed since the last one.
    public struct ActivityPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
    }

    /// Per-record motion-intensity series: L2 magnitude of the gravity change vs
    /// the previous record. First row → 0. Empty input → []. (GravitySample always
    /// carries finite x/y/z, so no dropout sentinel is required here.)
    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }   // never trust input order
        var series: [ActivityPoint] = []
        series.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0 { intensity = 0.0 }
            else if let p = prev {
                // Euclidean distance between consecutive gravity vectors: 0 = still, bigger = more movement.
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
        // Nearest-rank percentile (1-based rank). The low end of the day's HR approximates resting,
        // while ignoring brief sensor dips below the true baseline.
        let rank = max(1, Int(ceil(restingPercentile / 100.0 * Double(bpms.count))))
        return bpms[rank - 1]
    }

    /// Value whose ts is nearest to `ts` within `tol` seconds, else nil. Ties go
    /// to the later timestamp (matches the Python <= behaviour).
    static func nearest(_ sortedTs: [Int], _ values: [Double], _ ts: Int, _ tol: Double) -> Double? {
        if sortedTs.isEmpty { return nil }
        // Binary search (bisect_left) for the first timestamp >= ts, then compare it
        // with its left neighbour to find which one is closest.
        var lo = 0, hi = sortedTs.count
        while lo < hi { let mid = (lo + hi) / 2; if sortedTs[mid] < ts { lo = mid + 1 } else { hi = mid } }
        let i = lo
        var bestV: Double? = nil
        var bestD = tol          // anything farther than the tolerance is rejected
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
        // Sliding window: `running` is the sum of values in [lo, i]; the window start
        // advances whenever it is older than windowS seconds.
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
        let hrReserve = maxHR - restingHR      // Karvonen heart-rate reserve (HRR)
        var zoneCounts = [Int: Int]()
        for z in 0...5 { zoneCounts[z] = 0 }
        var hrrVals: [Double] = []
        for r in hrSeries {
            let z = StrainScorer.zoneWeight(r.bpm, restingHR: restingHR, hrReserve: hrReserve)
            zoneCounts[z, default: 0] += 1
            hrrVals.append(StrainScorer.pctHRR(r.bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
        // Convert counts to percentages (1 decimal) and average the %HRR.
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
        var lo = 0   // oldest sample still inside the trailing window
        for i in 0..<hr.count {
            while hr[i].ts - hr[lo].ts > windowS { lo += 1 }
            // Median (middle of the sorted window) so one-sample spikes/dropouts don't matter.
            let w = hr[lo...i].map { $0.bpm }.sorted()
            out.append(w[w.count / 2])
        }
        return out
    }

    /// Detector 2: runs of sustained elevated HR (no motion needed), ≥ hrOnlyMinMin long after bridging
    /// short dips. Returns (startTs, endTs) pairs.
    ///
    /// Steps: (1) compute enter/exit HR thresholds, (2) smooth HR, (3) walk the series with hysteresis to
    /// find raw runs, (4) bridge short dips, (5) trim run edges, (6) join long efforts split by a stop,
    /// (7) drop runs that are too short.
    static func hrOnlyRuns(_ hr: [(ts: Int, bpm: Double)], restingHR: Double, maxHR: Double?) -> [(Int, Int)] {
        guard hr.count > 1 else { return [] }
        let hrr = max(0.0, (maxHR ?? 190.0) - restingHR)   // heart-rate reserve; 190 if HRmax unknown
        // Threshold scales with fitness/HRR but never drops below a fixed bpm margin.
        // Example: rest 55, HRmax 190 → HRR 135 → margin max(30, 47) = 47 → enter above 102 bpm.
        let margin = max(hrOnlyMarginBPM, hrOnlyMinHRRFrac * hrr)
        let threshold = restingHR + margin
        // Lower "stay in" line (hysteresis): easier to remain in a workout than to start one.
        let exitThreshold = restingHR + margin * hrOnlyExitFrac
        let sm = smoothedHR(hr, windowS: hrSmoothS)
        var raw: [(Int, Int)] = []
        var start: Int? = nil   // start ts of the run being built (nil = not in a run)
        var last = 0            // ts of the most recent active sample
        for (i, r) in hr.enumerated() {
            // Start only above the entry line; once running, stay in until HR falls below the exit line.
            let active = sm[i] > threshold || (start != nil && sm[i] > exitThreshold)
            if active {
                if start == nil { start = r.ts }
                last = r.ts
            } else if let s0 = start, r.ts - last > 1 {
                // Inactive for more than a 1 s hiccup → close the current run.
                raw.append((s0, last)); start = nil
            }
        }
        if let s0 = start { raw.append((s0, last)) }   // data ended mid-effort
        // The trailing median lags the true edges by ~half its window, so clip each run to its first/last
        // raw sample above the exit threshold.
        var runs = unionRuns(raw, bridgeS: hrOnlyBridgeS).compactMap { r -> (Int, Int)? in
            let hot = hr.filter { $0.ts >= r.0 && $0.ts <= r.1 && $0.bpm > exitThreshold }
            guard let a = hot.first?.ts, let b = hot.last?.ts else { return nil }
            return (a, b)
        }
        // Join long efforts split by a longer pause (one ride with a stop). Both sides must be
        // substantial (≥ longEffortMin) and the pause ≤ longBridgeS; the join is cumulative, so a
        // ride with several stops chains into one session.
        var joined: [(Int, Int)] = []
        for r in runs {
            if let l = joined.last, r.0 - l.1 <= longBridgeS,
               Double(l.1 - l.0) >= longEffortMin * 60.0, Double(r.1 - r.0) >= longEffortMin * 60.0 {
                joined[joined.count - 1].1 = r.1
            } else { joined.append(r) }
        }
        runs = joined
        // Finally reject anything shorter than the HR-only minimum (filters out spikes).
        return runs.filter { Double($0.1 - $0.0) >= hrOnlyMinMin * 60.0 }
    }

    /// Sort and merge runs whose gap is ≤ bridgeS (overlaps always merge, since the gap is then ≤ 0).
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
        // --- Prepare inputs ---
        let hrSeg = cleanHR(hr)
        let motion = activitySeries(gravity)
        if hrSeg.isEmpty { return [] }

        let restHR = restingHR ?? deriveRestingHR(hrSeg)
        let hrFloor = restHR + hrMarginBPM   // detector 1's minimum HR for an "active" sample

        // HRmax: caller value wins; otherwise estimated (observed peak / Tanaka by age).
        // nil means unknown, in which case zone math and the intensity gate are skipped.
        let effMaxHR: Double?
        let hrmaxSource: String
        if let m = maxHR {
            effMaxHR = m; hrmaxSource = "caller"
        } else {
            let (est, src) = StrainScorer.estimateHRmax(hrSeg.map { $0.bpm }, age: age)
            effMaxHR = est == 0.0 ? nil : est
            hrmaxSource = src
        }

        // Parallel arrays so nearest() can binary-search timestamps.
        let hrTs = hrSeg.map { $0.ts }
        let hrBpm = hrSeg.map { $0.bpm }
        let smooth = smoothedIntensity(motion, windowS: motionSmoothS)

        // Detector 1 — motion + HR: walk the gravity timeline; flag samples where BOTH gates hold.
        var activeTs: [Int] = []   // timestamps where the wrist is moving AND HR is above the floor
        for (p, inten) in zip(motion, smooth) {
            if inten <= motionThreshold { continue }
            guard let bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS), bpm > hrFloor else { continue }
            activeTs.append(p.ts)
        }

        // Group contiguous active samples into runs, merging gaps < MERGE_GAP_S.
        var runs: [(Int, Int)] = []   // (start, end) timestamps of candidate workouts
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

        // Union both detectors' runs (a ride picked up by both, or split by a short pause, becomes one); overlapping or nearly-touching runs become one workout.
        runs = unionRuns(runs + hrOnly, bridgeS: Int(mergeGapS))
        if runs.isEmpty { return [] }

        // --- Build a session (stats + intensity gate) for each candidate run ---
        var sessions: [ExerciseSession] = []
        for (start, end) in runs {
            // All HR samples inside the run drive the stats below.
            let window = hrSeg.filter { $0.ts >= start && $0.ts <= end }
            if window.isEmpty { continue }
            let bpms = window.map { $0.bpm }
            let hrSamples = window.map { HRSample(ts: $0.ts, bpm: Int($0.bpm.rounded())) }

            // Zone breakdown only possible when HRmax is known and above resting.
            var zonePct: [Int: Double] = [:]
            var avgHRR: Double? = nil
            if let m = effMaxHR, m > restHR {
                (zonePct, avgHRR) = boutIntensity(window, restingHR: restHR, maxHR: m)
            }

            // Intensity qualification: require ≥ MIN_INTENSITY_Z2PLUS in zone 2+.
            if !zonePct.isEmpty {
                let z2plus = (2...5).reduce(0.0) { $0 + (zonePct[$1] ?? 0.0) } / 100.0
                let z1plus = z2plus + (zonePct[1] ?? 0.0) / 100.0
                // Long steady endurance work (easy/Z2 riding) lives mostly in zone 1, so it qualifies on
                // zone 1+ time; short bouts still need real zone 2+ intensity.
                let endurance = Double(end - start) >= enduranceMin * 60.0 && z1plus >= enduranceMinZ1Plus
                if z2plus < minIntensityZ2Plus && !endurance { continue }
            }

            // Calories only when the caller supplied a body profile.
            var kcal: Double? = nil
            var kj: Double? = nil
            if let profile = profile {
                let (k, j) = Calories.estimateBoutCalories(hrSamples, profile: profile,
                                                           hrmax: effMaxHR, restingHR: restHR)
                kcal = k; kj = j
            }

            // Summary stats for the session.
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
