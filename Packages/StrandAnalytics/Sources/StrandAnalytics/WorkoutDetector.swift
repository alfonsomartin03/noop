import Foundation
import WhoopProtocol

// WorkoutDetector.swift — retroactive detection of episodes that may be exercise, from the 1 Hz store.
//
// Ported from server/ingest/app/analysis/exercise.py (+ activity.py, calories.py), then reworked around supported time.
//
// What this does and does not establish: it finds sustained elevated heart rate. Elevated HR alone does not prove a
// workout happened (heat, stress, illness), and a quiet wrist does not prove inactivity (cycling, lifting), so a result
// is a POSSIBLE activity with its evidence attached, not a confirmed session, and no sport is named. Thresholds and
// durations here are engineering parameters that have not been tuned on labelled data (see `DetectionEvaluation`).
//
// HOW IT WORKS (big picture)
// --------------------------
//   1. HR-only trigger: smoothed HR above the bottom of Zone 1, with hysteresis, forms raw active runs. A sensor gap past
//      the bounded hold ends a run, because nothing is known about the time inside it.
//   2. Runs join when what separates them is short, and only if that stretch was mostly observed: a hole in the data is
//      never bridged as if the effort continued.
//   3. Every second of an episode is then active, paused (observed, HR dropped) or unknown (not observed), and these
//      partition its elapsed time. Acceptance needs enough ACTIVE time and coverage, never wall-clock span alone.
//   4. Motion is context. The channel is a ~1 Hz unit gravity vector (≈1 g magnitude), an orientation signal rather than
//      raw acceleration, so raw-accelerometer activity models do not apply to it. It labels the evidence and never
//      rejects an episode: arm movement alone once made detection far too eager, and a still wrist is normal on a bike.
//
// Per episode: time-weighted HR, %HRmax zones, load and index (all via `CardioLoad`, the same code the daily total uses),
// and estimated calories (Keytel 2005 active + revised Harris–Benedict BMR resting, age/sex/weight/height adjusted).
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

/// What supports an episode. Categorical on purpose: no calibration study exists to back a probability.
public enum ActivityEvidence: String, Codable, Sendable {
    case heartRateAndMotion        // sustained HR with sustained wrist movement
    case heartRateStillWrist       // sustained HR, wrist mostly still (cycling, lifting, or not exercise at all)
    case heartRateNoMotionData     // sustained HR, too little motion data to say

    /// Short plain-language label for stored notes and the UI.
    public var note: String {
        switch self {
        case .heartRateAndMotion: return "Auto-detected: sustained heart rate and wrist movement"
        case .heartRateStillWrist: return "Auto-detected: sustained heart rate, wrist mostly still"
        case .heartRateNoMotionData: return "Auto-detected: sustained heart rate, no motion data"
        }
    }
}

/// A detected episode, half-open [start, end). All intensity fields are APPROXIMATE.
public struct ExerciseSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// Time-weighted mean over supported seconds.
    public let avgHR: Double
    public let peakHR: Int
    /// Display index of this episode's load.
    public let strain: Double?
    /// Elapsed seconds. `load` splits them into active, paused and unknown.
    public let durationS: Double
    /// %HRmax zone (0–5) time as % of observed seconds; sums to ~100.
    public let zoneTimePct: [Int: Double]
    /// Time-weighted mean Karvonen %HRR, or nil when resting HR is unknown.
    public let avgHRRPct: Double?
    /// HRmax used (bpm).
    public let hrmax: Double?
    /// `HRCalibration.MaxSource` raw value.
    public let hrmaxSource: String
    public let caloriesKcal: Double?
    public let caloriesKJ: Double?
    /// The accounting behind these numbers, as stored.
    public let load: SessionLoadRecord
}

public enum WorkoutDetector {

    // MARK: - Constants (engineering parameters, not tuned on labelled data)

    /// Smoothed gravity-change magnitude above this means "moving".
    public static let motionThreshold: Double = 0.20
    /// Trailing window (seconds) used to average the motion signal.
    public static let motionSmoothS: Double = 10.0
    /// Below this share of observed seconds with a gravity sample, motion says nothing about the episode.
    public static let minMotionCoverage: Double = 0.5
    /// Share of an episode's motion samples that must be "moving" to call it heart rate AND motion.
    public static let minMovingFraction: Double = 0.25

    /// Rolling-median window smoothing single-sample HR spikes.
    public static let hrSmoothS: Int = 60
    /// Zone 1 floor as a fraction of HRmax; smoothed HR must exceed it to count as active.
    public static let zone1Floor: Double = 0.50
    /// Once an effort has started it continues until smoothed HR falls this many bpm below the Zone 1 floor,
    /// so cardiac drift or an easy descent does not chop a session.
    public static let exitBelowFloorBPM: Double = 5.0
    /// Supported ACTIVE time (minutes) an episode needs.
    public static let hrOnlyMinMin: Double = 15.0
    /// Pauses up to this long inside an effort are bridged (rest between sets, a stop light, a drink).
    public static let hrOnlyBridgeS: Int = 300
    /// Two long efforts (each ≥ longEffortMin active) separated by a pause up to this long are one session
    /// (a café stop mid-ride, a red-light queue, refilling a bottle).
    public static let longBridgeS: Int = 1500
    public static let longEffortMin: Double = 15.0
    /// Most unobserved time a bridge may contain. Past this, the two sides are separate: the data cannot say it was one.
    public static let maxUnknownBridgeS: Int = 300
    /// Share of an episode's elapsed time that must be observed.
    public static let minEpisodeCoverage: Double = 0.8

    // MARK: - Activity series (activity.py)

    /// One motion reading: timestamp plus how much the wrist orientation changed since the last one.
    public struct ActivityPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
    }

    /// Per-record motion-intensity series: L2 magnitude of the gravity change vs the previous record. First row → 0, as is
    /// a row after a gap past the hold (a change across a gap is not a per-second change). Empty input → [].
    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }   // never trust input order
        var series: [ActivityPoint] = []
        series.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for row in rows {
            var intensity = 0.0
            if let p = prev, row.ts - p.ts <= SupportedHR.maxHoldS {
                // Euclidean distance between consecutive gravity vectors: 0 = still, bigger = more movement.
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            }
            series.append(ActivityPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return series
    }

    // MARK: - Helpers

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

    /// Rolling median of bpm over the trailing `windowS` seconds (robust to single-sample spikes). bpm values are small
    /// integers, so the window is a histogram: sorting it per sample was the detector's main cost.
    static func smoothedHR(_ hr: [HRSample], windowS: Int) -> [Double] {
        guard let lowest = hr.map(\.bpm).min(), let highest = hr.map(\.bpm).max() else { return [] }
        var counts = [Int](repeating: 0, count: highest - lowest + 1)
        var out: [Double] = []
        out.reserveCapacity(hr.count)
        var lo = 0   // oldest sample still inside the trailing window
        for i in 0..<hr.count {
            counts[hr[i].bpm - lowest] += 1
            while hr[i].ts - hr[lo].ts > windowS { counts[hr[lo].bpm - lowest] -= 1; lo += 1 }
            // Median (middle of the sorted window) so one-sample spikes/dropouts don't matter.
            let rank = (i - lo + 1) / 2
            var seen = 0, bin = 0
            while true {
                seen += counts[bin]
                if seen > rank { break }
                bin += 1
            }
            out.append(Double(bin + lowest))
        }
        return out
    }

    /// Where an episode's elapsed time went. active + paused + unknown == end − start.
    struct Episode: Equatable {
        let start: Int
        let end: Int
        let activeS: Int
        let pausedS: Int
        let unknownS: Int
    }

    /// Raw active runs: smoothed HR past the entry line, held with hysteresis, broken by any gap past the bounded hold.
    static func activeRuns(_ hr: [HRSample], entry: Double, exit: Double) -> [TimeSpan] {
        let sm = smoothedHR(hr, windowS: hrSmoothS)
        var raw: [TimeSpan] = []
        var start: Int? = nil   // start ts of the run being built (nil = not in a run)
        var last = 0            // ts of the most recent active sample
        for (i, r) in hr.enumerated() {
            if let s0 = start, r.ts - last > SupportedHR.maxHoldS {
                raw.append(TimeSpan(s0, last + 1)); start = nil
            }
            // Start only above the entry line; once running, stay in until HR falls below the exit line.
            let active = sm[i] > entry || (start != nil && sm[i] > exit)
            if active {
                if start == nil { start = r.ts }
                last = r.ts
            } else if let s0 = start, r.ts - last > 1 {
                // Inactive for more than a 1 s hiccup → close the current run.
                raw.append(TimeSpan(s0, last + 1)); start = nil
            }
        }
        if let s0 = start { raw.append(TimeSpan(s0, last + 1)) }   // data ended mid-effort
        return raw
    }

    /// Episodes of sustained elevated HR. Steps: (1) raw active runs, (2) bridge short pauses, (3) trim edges to raw samples,
    /// (4) join long efforts split by a stop, (5) account every second, (6) require active time and coverage.
    static func episodes(_ hr: [HRSample], support: SupportedHR, hrMax: Double) -> [Episode] {
        guard hr.count > 1 else { return [] }
        let entry = hrMax * zone1Floor
        let exit = entry - exitBelowFloorBPM
        let raw = activeRuns(hr, entry: entry, exit: exit)

        func unknownBetween(_ a: TimeSpan, _ b: TimeSpan) -> Int {
            let gap = TimeSpan(a.end, b.start)
            return gap.duration - support.observedSeconds(in: gap)
        }
        func activeSeconds(_ span: TimeSpan) -> Int {
            raw.reduce(0) { acc, r in
                let s = TimeSpan(max(r.start, span.start), min(r.end, span.end))
                return acc + support.observedSeconds(in: s)
            }
        }

        var bridged: [TimeSpan] = []
        for r in raw {
            if let l = bridged.last, r.start - l.end <= hrOnlyBridgeS, unknownBetween(l, r) <= maxUnknownBridgeS {
                bridged[bridged.count - 1] = TimeSpan(l.start, r.end)
            } else { bridged.append(r) }
        }
        // The trailing median lags the true edges by ~half its window, so clip each run to its first/last
        // raw sample above the exit threshold.
        let trimmed = bridged.compactMap { r -> TimeSpan? in
            let hot = hr.filter { $0.ts >= r.start && $0.ts < r.end && Double($0.bpm) > exit }
            guard let a = hot.first?.ts, let b = hot.last?.ts else { return nil }
            return TimeSpan(a, b + 1)
        }
        // Join long efforts split by a longer pause (one ride with a stop). Both sides must be substantial and the
        // pause observed; the join is cumulative, so a ride with several stops chains into one session.
        var joined: [TimeSpan] = []
        for r in trimmed {
            if let l = joined.last, r.start - l.end <= longBridgeS, unknownBetween(l, r) <= maxUnknownBridgeS,
               Double(activeSeconds(l)) >= longEffortMin * 60.0, Double(activeSeconds(r)) >= longEffortMin * 60.0 {
                joined[joined.count - 1] = TimeSpan(l.start, r.end)
            } else { joined.append(r) }
        }
        return joined.compactMap { s in
            let observed = support.observedSeconds(in: s)
            let active = activeSeconds(s)
            guard Double(active) >= hrOnlyMinMin * 60.0,
                  Double(observed) / Double(s.duration) >= minEpisodeCoverage else { return nil }
            return Episode(start: s.start, end: s.end, activeS: active, pausedS: observed - active,
                           unknownS: s.duration - observed)
        }
    }

    /// What motion says about an episode, and the share of it spent moving (nil when motion can't say).
    static func motionEvidence(_ span: TimeSpan, ts: [Int], smoothed: [Double], observedS: Int) -> (ActivityEvidence, Double?) {
        var lo = 0, hi = ts.count
        while lo < hi { let mid = (lo + hi) / 2; if ts[mid] < span.start { lo = mid + 1 } else { hi = mid } }
        var n = 0, moving = 0
        var i = lo
        while i < ts.count, ts[i] < span.end {
            n += 1
            if smoothed[i] >= motionThreshold { moving += 1 }
            i += 1
        }
        guard observedS > 0, Double(n) / Double(observedS) >= minMotionCoverage else { return (.heartRateNoMotionData, nil) }
        let fraction = Double(moving) / Double(n)
        return (fraction >= minMovingFraction ? .heartRateAndMotion : .heartRateStillWrist, fraction)
    }

    // MARK: - Public API

    /// Detect possible activity from raw streams.
    ///
    /// - Parameters:
    ///   - hr: heart-rate stream (required; empty → []).
    ///   - gravity: gravity stream; may be empty, which only changes the reported evidence.
    ///   - restingHR: declared resting HR (bpm); nil leaves %HRR unavailable.
    ///   - maxHR: declared HRmax (bpm).
    ///   - age: for the labelled Tanaka estimate when `maxHR` is nil.
    ///   - profile: when provided, per-bout calories are estimated.
    public static func detect(hr: [HRSample],
                              gravity: [GravitySample],
                              restingHR: Double? = nil,
                              maxHR: Double? = nil,
                              age: Double? = nil,
                              profile: UserProfile? = nil) -> [ExerciseSession] {
        let cleaned = HRQuality.clean(hr)
        return detect(cleaned: cleaned, support: SupportedHR(cleaned: cleaned), gravity: gravity,
                      calibration: .resolve(declaredMax: maxHR, age: age, declaredResting: restingHR), profile: profile)
    }

    /// Detect over validated samples and their supported intervals, under one calibration snapshot. With no usable HRmax
    /// there is no defined zone floor, so nothing is detected (rather than assuming a universal 190). Seconds in
    /// `sleep` never count toward a session's load, so a session can't report more than the awake-time day holds.
    public static func detect(cleaned hr: [HRSample], support: SupportedHR, gravity: [GravitySample],
                              calibration: HRCalibration, profile: UserProfile? = nil,
                              sleep: [TimeSpan] = []) -> [ExerciseSession] {
        guard let hrMax = calibration.hrMax, !hr.isEmpty else { return [] }
        let found = episodes(hr, support: support, hrMax: hrMax)
        if found.isEmpty { return [] }
        let motion = activitySeries(gravity)
        let motionTs = motion.map(\.ts)
        let smoothed = smoothedIntensity(motion, windowS: motionSmoothS)

        var sessions: [ExerciseSession] = []
        for e in found {
            let span = TimeSpan(e.start, e.end)
            let segment = support.clipped(to: span, excluding: sleep)
            let summary = LoadSummary(segment, requestedS: span.duration - SleepAccounting.totalSeconds(sleep, clippedTo: span),
                                      hrMax: hrMax)
            guard let mean = summary.meanHR, let peak = summary.peakHR else { continue }
            let (evidence, moving) = motionEvidence(span, ts: motionTs, smoothed: smoothed, observedS: summary.observedS)

            // Calories only when the caller supplied a body profile.
            var kcal: Double? = nil
            var kj: Double? = nil
            if let profile = profile {
                let (k, j) = Calories.estimateBoutCalories(hr.filter { $0.ts >= e.start && $0.ts < e.end }, profile: profile,
                                                           hrmax: hrMax, restingHR: calibration.restingHR)
                kcal = k; kj = j
            }
            let record = SessionLoadRecord(start: e.start, end: e.end, activeS: e.activeS, pausedS: e.pausedS,
                                           unknownS: e.unknownS, summary: summary, evidence: evidence,
                                           movingFraction: moving, calibration: calibration,
                                           loadVersion: CardioLoad.loadVersion, detectorVersion: CardioLoad.detectorVersion)
            sessions.append(ExerciseSession(
                start: e.start, end: e.end, avgHR: mean, peakHR: peak,
                strain: StrainScorer.activityIndex(load: summary.zoneLoad),
                durationS: Double(span.duration), zoneTimePct: summary.zonePercent,
                avgHRRPct: CardioLoad.meanPercentHRR(segment, calibration: calibration).map { ($0 * 10).rounded() / 10 },
                hrmax: hrMax, hrmaxSource: calibration.hrMaxSource.rawValue,
                caloriesKcal: kcal, caloriesKJ: kj, load: record))
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

    /// Estimate kcal over a day of HR samples, on the same supported seconds as the day's coverage (see `SupportedHR`),
    /// so "recorded" means one thing everywhere. Uses the same resting/active split as `estimateBoutCalories`. Sleep stays
    /// in: this is total-day energy, and excluding sleep from strain must not remove resting energy.
    public static func estimateDayCalories(_ hrSamples: [HRSample],
                                           profile: UserProfile,
                                           hrmax: Double?,
                                           restingHR: Double?) -> Double {
        estimateDayCalories(SupportedHR(raw: hrSamples), profile: profile, hrmax: hrmax, restingHR: restingHR)
    }

    public static func estimateDayCalories(_ support: SupportedHR,
                                           profile: UserProfile,
                                           hrmax: Double?,
                                           restingHR: Double?) -> Double {
        guard !support.intervals.isEmpty else { return 0 }
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = resolveCoeffs(profile.sex)
        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)
        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)

        var total = 0.0
        for x in support.intervals {
            let bpm = Double(x.bpm)
            total += (bpm < activeThreshold ? restingRate : activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age)) * Double(x.seconds)
        }
        return total
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
