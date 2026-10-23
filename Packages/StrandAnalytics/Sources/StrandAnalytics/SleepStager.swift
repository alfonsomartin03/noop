import Foundation
import WhoopProtocol

// SleepStager.swift — sleep/wake detection + APPROXIMATE 4-class staging.
//
// Ported from server/ingest/app/analysis/sleep.py and sleep_features.py.
//
// HONEST HEDGING: these stages are APPROXIMATIONS, not PSG-validated, not medical
// advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019).
// Light/deep separation is the weakest link — deep-minute estimates are the least
// reliable output.
//
// Pipeline (30 s epochs):
//   Stage 0  gravity-stillness sleep/wake spine → in-bed sessions. Cole–Kripke
//            (te Lindert 30 s) computed as a citable cross-check; HR confirms runs.
//   Stage 1  per-epoch cardiorespiratory features over a rolling 5-min window
//            (mean HR, DoG-HR variability, RMSSD/SDNN from RR, resp rate + RRV).
//   Stage 2  transparent percentile-band classifier → {wake, light, deep, rem}.
//   Stage 3  median smoothing + physiology re-imposition (no early REM, deep in
//            the first third of the night).
//
// NOTE: the Python source computes RMSSD/SDNN/HF/LF/LFHF via neurokit2 per epoch.
// On-device we have no neurokit2/scipy, so frequency-domain features (HF, LF/HF)
// are omitted and the parasympathetic-tone signal is RMSSD only. Respiration rate
// + RRV are derived from the raw 1 Hz resp channel with a simple peak detector
// (the Python source explicitly derives these "robustly ourselves" too, so this
// path is a faithful port rather than an approximation). The classifier seam,
// percentile bands, smoothing, and physiology rules are reproduced exactly.

// MARK: - Public output shapes

/// A contiguous sleep-stage segment. Times are wall-clock unix seconds.
public struct StageSegment: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var stage: String  // "wake" | "light" | "deep" | "rem"
    public init(start: Int, end: Int, stage: String) {
        self.start = start; self.end = end; self.stage = stage
    }
}

/// Main (night) sleep vs a daytime nap. Sedentary rest that merely looks like sleep is never emitted.
public enum SleepKind: String, Equatable, Sendable { case main, nap }

/// A detected sleep session (in-bed span) with APPROXIMATE staging.
public struct SleepSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// asleep / in-bed in [0, 1] (AASM TST/TIB; asleep = in-bed − wake).
    public let efficiency: Double
    public let stages: [StageSegment]
    /// Lowest 5-min rolling-mean HR during the session (bpm), or nil.
    public let restingHR: Int?
    /// Mean RMSSD over 5-min windows across the session (ms), or nil.
    public let avgHRV: Double?
    /// Night vs nap (see `SleepStager.classifyCandidate`).
    public let kind: SleepKind
    /// True while the final wake cannot yet be trusted (the recording ends within `provisionalWindowMin` of it).
    public let isProvisional: Bool

    public init(start: Int, end: Int, efficiency: Double, stages: [StageSegment],
                restingHR: Int?, avgHRV: Double?, kind: SleepKind = .main, isProvisional: Bool = false) {
        self.start = start; self.end = end; self.efficiency = efficiency
        self.stages = stages; self.restingHR = restingHR; self.avgHRV = avgHRV
        self.kind = kind; self.isProvisional = isProvisional
    }
}

public enum SleepStager {

    // MARK: - Stage 0 constants (sleep.py)

    /// Per-sample gravity change (g) at/below which a sample is "still".
    public static let gravityStillThresholdG: Double = 0.01
    /// Rolling stillness window (minutes).
    public static let stillWindowMin: Int = 15
    /// Fraction of still samples to call the window-center "sleep".
    public static let stillFraction: Double = 0.70
    /// Data gap (minutes) that always breaks a run.
    public static let maxGapMin: Int = 20
    /// Runs shorter than this (minutes) are absorbed into neighbours.
    public static let mergeMin: Int = 15
    /// A sleep run must exceed this (minutes) to count as a session.
    public static let minSleepMin: Int = 60
    /// Assumed sample interval (seconds) when not inferable.
    public static let defaultIntervalS: Double = 60.0
    /// Floor on the rolling-window size in samples.
    public static let minWindowSamples: Int = 3
    /// A run is HR-confirmed only if mean HR ≤ baseline × this.
    public static let hrSleepBaselineMult: Double = 1.05
    /// Skip HR refinement (trust gravity) when fewer than this many HR samples.
    public static let hrRefineMinSamples: Int = 30
    /// Consecutive sleep epochs required to declare onset.
    public static let onsetPersistEpochs: Int = 3

    // MARK: - Sleep vs sedentary-rest discrimination
    //
    // Wrist actigraphy alone over-calls sleep: sensitivity ~0.97 but specificity only ~0.33 against PSG
    // (Marino 2013, Sleep 36:1747), so quiet wakefulness (couch, desk, reading in bed) scores as sleep.
    // Even a 30 s-epoch HR+motion model only reaches ~60% wake specificity (Walch 2019, Sleep 42:zsz180).
    // A resting heart rate that "drops to sleep levels" is not discriminating either, so we gate on the
    // sleeping body being *motionless minute after minute* and on a clear HR dip versus the awake-moving
    // baseline, then label main sleep vs nap by duration and time of day.

    /// A 60 s bin is "quiet" when no sample-to-sample gravity change reaches this (g).
    public static let quietMinuteThresholdG: Double = 0.02
    /// Centered window (minutes) and quiet-minute fraction needed for a minute to count as sleep.
    public static let quietWindowMin: Int = 15
    public static let quietMinuteFraction: Double = 0.80
    /// Whole-candidate quiet-minute fraction required for a night / a nap.
    public static let mainMinQuietFrac: Double = 0.85
    public static let napMinQuietFrac: Double = 0.90
    /// Required HR dip (1 − sleepMedianHR / awakeMovingMedianHR). Sleep HR is typically 10–25% below
    /// waking levels (Trinder 2001, J Sleep Res 10:253), but naps dip less.
    public static let mainMinHRDip: Double = 0.08
    public static let napMinHRDip: Double = 0.10
    /// Minimum awake-moving HR samples to trust the awake reference; else the HR-dip test is skipped.
    public static let awakeRefMinSamples: Int = 300
    /// Duration bounds (minutes): a nap needs ≥30 min; ≥180 min is a night (unless a short daytime siesta).
    public static let napMinMin: Int = 30
    public static let mainMinMin: Int = 180
    /// Daytime (local hours) sleeps shorter than `siestaMaxMin` are naps even if ≥ 3 h.
    public static let siestaStartHour: Int = 10
    public static let siestaEndHour: Int = 18
    public static let siestaMaxMin: Int = 240
    /// Wake gaps up to this long between two sleep fragments always belong to one session (bathroom, water, phone,
    /// a short walk). 50 min is WHOOP's documented interruption benchmark; it is a compatibility default, not a
    /// physiological constant, so it is a tunable.
    public static let sameNightGapMin: Int = 50
    /// Gaps up to this long (but over `sameNightGapMin`) still join when the wearer stayed in bed: few moving minutes
    /// in the gap means lying awake / dozing, whereas a gap spent moving around is a real separate wake.
    public static let maxBridgeGapMin: Int = 90
    public static let bridgeMaxMovingFrac: Double = 0.35
    /// A gap must have gravity data in at least this share of its minutes to be bridged: missing data is never
    /// assumed to be sleep (strap off, charging, BLE loss).
    public static let minGapCoverage: Double = 0.5
    /// Trim lying-awake time off the ends of a session: the first/last minute whose 5-min mean HR is within
    /// max(`edgeHRTolMinBPM`, `edgeHRTolFrac`·level) of the session's sleeping level counts as onset / final wake.
    /// Loose on purpose: HR alone separates quiet wake from sleep poorly (Walch 2019: ~60% wake specificity).
    public static let edgeHRTolMinBPM: Double = 12
    public static let edgeHRTolFrac: Double = 0.25
    /// Data must extend this far past a session's end before its final wake is trusted; before that it is
    /// provisional (the wearer may still go back to sleep).
    public static let provisionalWindowMin: Int = 60
    /// A nap must also look like the wearer's own sleep: its median HR within max(12 bpm, 25%) of their usual sleeping
    /// HR (this window's main sleep, else `sleepHRHint`). With no reference at all it needs a larger dip vs waking HR.
    public static let napNoReferenceMinHRDip: Double = 0.18
    /// Final-wake extension: after the strict (quiet) core of a night, sleep continues through restless 5-min blocks
    /// while HR stays at sleeping level (+ `edgeHR` tolerance) and ≥ `extendMinQuietFrac` of minutes are quiet.
    /// Light morning sleep is physically restless (position changes, brief arousals), so motion alone ends nights too soon.
    public static let extendBlockS: Int = 300
    public static let extendMinQuietFrac: Double = 0.5
    /// A returning stretch must hold at least this many sleep-like blocks to count as sleep after a wake.
    public static let extendMinGoodBlocks: Int = 4

    // MARK: - Stage 1–3 constants (sleep_features.py)

    public static let epochS: Double = 30.0
    public static let featureWindowS: Double = 5 * 60.0
    public static let ckCountDivisor: Double = 100.0
    public static let ckCountClip: Double = 300.0
    public static let moveDeltaThresholdG: Double = 0.01
    public static let hrDogSigma1S: Double = 120.0
    public static let hrDogSigma2S: Double = 600.0

    public static let stageHRLowPct: Double = 25.0
    public static let stageHRHighPct: Double = 70.0
    public static let stageHRVHighPct: Double = 70.0
    public static let stageHRVarHighPct: Double = 65.0
    public static let stageRRVHighPct: Double = 65.0
    public static let stageRRVLowPct: Double = 50.0
    /// Population-prior share of sleep assigned to deep / REM at most, and the minimum score (z) to qualify.
    public static let stageDeepTargetPct: Double = 17.0
    public static let stageREMTargetPct: Double = 22.0
    public static let stageScoreMargin: Double = 0.25
    public static let stageWakeMoveFrac: Double = 0.15
    public static let stageStillMoveFrac: Double = 0.10

    public static let smoothEpochs: Int = 5
    // Healthy REM latency is ~70–120 min (Carskadon & Dement); <15–20 min is pathological
    // (narcolepsy, severe deprivation), so 30 min is a conservative hard floor.
    public static let noREMAfterOnsetMin: Double = 30.0
    // N3 is concentrated in the first two NREM cycles (first ~half of the night); the earlier
    // "first third" cut-off zeroed deep sleep on nights whose HR/HRV peak comes late (circadian effect).
    public static let deepFirstFraction: Double = 0.5
    /// Half-width (epochs) of the local-trend window used to detrend HR/RMSSD: ±45 min ≈ one ultradian cycle.
    public static let trendHalfWindowEpochs: Int = 90

    /// te Lindert 30 s Cole–Kripke weights [A₋₄..A₊₂]. SI = 0.001·Σ wᵢ·Aᵢ; sleep iff SI<1.
    public static let ckWeights: [Double] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0]
    public static let ckScale: Double = 0.001
    public static let ckBack: Int = 4
    public static let ckFwd: Int = 2

    // MARK: - Gravity deltas

    /// Per-record movement proxy = L2 magnitude of the gravity change vs the
    /// previous record. First record → 0. (No dropout sentinel needed: GravitySample
    /// always carries finite x/y/z.)
    static func gravityDeltas(_ grav: [GravitySample]) -> [Double] {
        var deltas: [Double] = []
        deltas.reserveCapacity(grav.count)
        var prev: GravitySample? = nil
        for (i, r) in grav.enumerated() {
            if i == 0 {
                deltas.append(0.0)
            } else if let p = prev {
                let dx = p.x - r.x, dy = p.y - r.y, dz = p.z - r.z
                deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
            } else {
                deltas.append(0.0)
            }
            prev = r
        }
        return deltas
    }

    /// Median spacing between consecutive timestamps, restricted to (0, 300 s).
    static func medianIntervalS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return defaultIntervalS }
        var gaps: [Double] = []
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return defaultIntervalS }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }

    static func windowSize(_ times: [Int]) -> Int {
        let interval = medianIntervalS(times)
        return max(minWindowSamples, Int(Double(stillWindowMin * 60) / interval))
    }

    /// Per-record sleep flags from a rolling fraction of "still" samples.
    // A sample is 'sleep' when >= 70% of samples in a ~15 min window around it are still.
    static func classifyStill(_ grav: [GravitySample], _ deltas: [Double]) -> [Bool] {
        let n = grav.count
        if n < 2 { return [Bool](repeating: false, count: n) }
        let half = windowSize(grav.map { $0.ts }) / 2
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        // Prefix count of still samples so each window is O(1) instead of re-scanning ~15 min of samples per record.
        var stillPrefix = [Int](repeating: 0, count: n + 1)
        for j in 0..<n { stillPrefix[j + 1] = stillPrefix[j] + (deltas[j] < gravityStillThresholdG ? 1 : 0) }
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let stillCount = stillPrefix[hi] - stillPrefix[lo]
            flags.append(Double(stillCount) / Double(hi - lo) >= stillFraction)
        }
        return flags
    }

    struct Period { var stage: String; var start: Int; var end: Int }

    /// Collapse per-record flags into contiguous runs, breaking on class change
    /// or a gap > maxGapMin minutes.
    // Turns the per-sample flags into runs; a >20 min data gap always splits a run (strap was off).
    static func buildRuns(_ grav: [GravitySample], _ flags: [Bool]) -> [Period] {
        let n = grav.count
        if n == 0 { return [] }
        let times = grav.map { $0.ts }
        let maxGapS = maxGapMin * 60
        var periods: [Period] = []
        var runStart = 0
        for i in 1...n {
            let atEnd = (i == n)
            let close: Bool
            if atEnd {
                close = true
            } else {
                let classChanged = flags[i] != flags[runStart]
                let gapExceeded = (times[i] - times[i - 1]) > maxGapS
                close = classChanged || gapExceeded
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: times[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Absorb runs shorter than mergeMin minutes into their neighbours.
    // Short blips (<15 min) are absorbed so a toilet trip doesn't split one night into two sessions.
    static func mergePeriods(_ periods: [Period], mergeMinutes: Int = mergeMin) -> [Period] {
        if periods.isEmpty { return [] }
        var pending = periods
        let thresholdS = mergeMinutes * 60
        var merged: [Period] = []
        var i = 0
        while i < pending.count {
            let current = pending[i]
            let tooShort = (current.end - current.start) < thresholdS
            if !tooShort { merged.append(current); i += 1; continue }

            let hasPrev = i > 0 && !merged.isEmpty
            let hasNext = i + 1 < pending.count
            // If a short run sits between two runs of the same kind, all three become one.
            let bridgesSame = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage

            if bridgesSame {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: pending[i + 1].end))
                i += 2
            } else if hasNext {
                pending[i + 1] = Period(stage: pending[i + 1].stage,
                                        start: current.start, end: pending[i + 1].end)
                i += 1
            } else if hasPrev {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    // MARK: - HR refinement

    static func rowsBetween<T>(_ rows: [T], start: Int, end: Int, ts: (T) -> Int) -> [T] {
        rows.filter { ts($0) >= start && ts($0) <= end }
    }

    /// Day HR baseline = median bpm over all HR samples; nil if none.
    static func hrBaseline(_ hr: [HRSample]) -> Double? {
        let vals = hr.map { Double($0.bpm) }
        guard !vals.isEmpty else { return nil }
        return HRVAnalyzer.median(vals)
    }

    // Gravity says 'still'; HR confirms. Reading in bed while awake has HR well above the day's median.
    static func confirmSleepWithHR(_ p: Period, hr: [HRSample], baseline: Double?) -> Bool {
        guard let baseline = baseline else { return true }
        let seg = rowsBetween(hr, start: p.start, end: p.end) { $0.ts }
        if seg.count < hrRefineMinSamples { return true }
        let meanHR = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        return meanHR <= baseline * hrSleepBaselineMult
    }

    // MARK: - Quiet-minute grid

    /// One state per absolute minute (ts/60): -1 no data, 0 moving, 1 quiet.
    struct MinuteGrid {
        let first: Int
        let state: [Int8]
        func at(_ minute: Int) -> Int8 {
            let i = minute - first
            return i >= 0 && i < state.count ? state[i] : -1
        }
        /// Share of minutes in [startTs, endTs] that have gravity data at all.
        func coverage(_ startTs: Int, _ endTs: Int) -> Double {
            let a = startTs / 60, b = max(startTs, endTs) / 60
            var n = 0
            for m in a...b where at(m) >= 0 { n += 1 }
            return Double(n) / Double(b - a + 1)
        }
        /// Share of data minutes in [startTs, endTs] with real movement.
        func movingFraction(_ startTs: Int, _ endTs: Int) -> Double {
            1.0 - (quietFraction(startTs, endTs) ?? 1.0)
        }
        /// Fraction of minutes with data in [startTs, endTs] that are quiet; nil if none.
        func quietFraction(_ startTs: Int, _ endTs: Int) -> Double? {
            var q = 0, n = 0
            for m in (startTs / 60)...(max(startTs, endTs) / 60) {
                let v = at(m)
                if v >= 0 { n += 1; if v == 1 { q += 1 } }
            }
            return n > 0 ? Double(q) / Double(n) : nil
        }
    }

    static func buildMinuteGrid(_ grav: [GravitySample], _ deltas: [Double]) -> MinuteGrid {
        guard let f = grav.first, let l = grav.last else { return MinuteGrid(first: 0, state: []) }
        let first = f.ts / 60, last = l.ts / 60
        var state = [Int8](repeating: -1, count: last - first + 1)
        for (g, d) in zip(grav, deltas) {
            let i = g.ts / 60 - first
            if d >= quietMinuteThresholdG { state[i] = 0 }
            else if state[i] == -1 { state[i] = 1 }
        }
        return MinuteGrid(first: first, state: state)
    }

    /// Per-record sleep flags: a minute is "sleep" when ≥80% of data minutes in a centered 15-min window are quiet.
    static func classifyQuietMinutes(_ grav: [GravitySample], _ grid: MinuteGrid) -> [Bool] {
        let n = grid.state.count
        var quietP = [Int](repeating: 0, count: n + 1), dataP = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            quietP[i + 1] = quietP[i] + (grid.state[i] == 1 ? 1 : 0)
            dataP[i + 1] = dataP[i] + (grid.state[i] >= 0 ? 1 : 0)
        }
        let half = quietWindowMin / 2
        let minuteFlag: [Bool] = (0..<n).map { i in
            let lo = max(0, i - half), hi = min(n, i + half + 1)
            let data = dataP[hi] - dataP[lo]
            return data > 0 && Double(quietP[hi] - quietP[lo]) / Double(data) >= quietMinuteFraction
        }
        return grav.map { minuteFlag[$0.ts / 60 - grid.first] }
    }

    // MARK: - Candidate classification

    struct Evidence {
        var quietFrac: Double?
        var hrDip: Double?        // nil when no HR to judge
    }

    static func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : HRVAnalyzer.median(v) }

    /// Night / nap / not-sleep verdict for one stillness run. `awakeRef` = median HR while moving.
    static func classifyCandidate(start: Int, end: Int, ev: Evidence) -> SleepKind? {
        let durMin = (end - start) / 60
        if durMin < napMinMin { return nil }
        let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(start)))
        let daytime = hour >= siestaStartHour && hour < siestaEndHour
        let isNap = durMin < mainMinMin || (daytime && durMin < siestaMaxMin)
        let minQuiet = isNap ? napMinQuietFrac : mainMinQuietFrac
        let minDip = isNap ? napMinHRDip : mainMinHRDip
        guard let q = ev.quietFrac, q >= minQuiet else { return nil }
        if let dip = ev.hrDip, dip < minDip { return nil }
        return isNap ? .nap : .main
    }

    /// Whether the gap between two sleep fragments is a wake INSIDE one session. Missing data never bridges.
    static func canBridge(_ gapStart: Int, _ gapEnd: Int, grid: MinuteGrid) -> Bool {
        // The 15-min stillness window erodes each fragment by ~half a window, so the measured gap overstates the real
        // wake by about `quietWindowMin`; judge the gap on its core.
        let erode = (quietWindowMin / 2) * 60
        let a = gapStart + erode, b = gapEnd - erode
        let gapMin = (b - a) / 60
        if gapMin <= 0 { return true }
        if gapMin > maxBridgeGapMin { return false }
        if grid.coverage(gapStart, gapEnd) < minGapCoverage { return false }
        if gapMin <= sameNightGapMin { return true }
        return grid.movingFraction(a, b) <= bridgeMaxMovingFrac
    }

    /// Extend a night's END through restless-but-sleeping blocks (see `extendMinQuietFrac`). A wake of up to
    /// `sameNightGapMin` followed by ≥ `extendMinGoodBlocks` sleep-like blocks is bridged, mirroring the 50-min rule.
    static func extendFinalWake(_ p: Period, hr: [HRSample], grid: MinuteGrid, dataEnd: Int) -> Period {
        let core = rowsBetween(hr, start: p.start, end: p.end) { $0.ts }.map { Double($0.bpm) }
        guard core.count >= 600, let level = median(core) else { return p }
        let limit = level + max(edgeHRTolMinBPM, edgeHRTolFrac * level)
        let maxBad = sameNightGapMin * 60 / extendBlockS
        var accepted = p.end
        var t = p.end
        var bad = 0, goodRun = 0
        var runStart = t
        while t + extendBlockS <= dataEnd {
            let e = t + extendBlockS
            let w = rowsBetween(hr, start: t, end: e - 1) { $0.ts }
            let hrMean: Double? = w.count >= 30 ? Double(w.reduce(0) { $0 + $1.bpm }) / Double(w.count) : nil
            let covered = grid.coverage(t, e - 1) >= minGapCoverage
            let quiet = grid.quietFraction(t, e - 1) ?? 0
            let good = covered && quiet >= extendMinQuietFrac && (hrMean.map { $0 <= limit } ?? false)
            if good {
                if goodRun == 0 { runStart = t }
                goodRun += 1
                bad = 0
                // Blocks directly continuing the core count at once; a stretch after a wake needs `extendMinGoodBlocks`.
                if goodRun >= extendMinGoodBlocks || runStart == p.end { accepted = e }
            } else {
                goodRun = 0
                bad += 1
                if bad > maxBad { break }
            }
            t = e
        }
        return Period(stage: "sleep", start: p.start, end: accepted)
    }

    /// Trim motionless-but-awake time from both ends using the 5-min mean HR (see `edgeHRTolFrac`).
    static func refineEdges(_ p: Period, hr: [HRSample]) -> Period {
        let seg = hr.filter { $0.ts >= p.start && $0.ts <= p.end }
        guard seg.count >= 600, p.end - p.start >= 2 * 3600 else { return p }
        // 5-min mean HR on a 1-min step.
        var means: [(t: Int, v: Double)] = []
        var t = p.start
        while t + 300 <= p.end {
            let w = seg.filter { $0.ts >= t && $0.ts < t + 300 }
            if w.count >= 30 { means.append((t + 150, Double(w.reduce(0) { $0 + $1.bpm }) / Double(w.count))) }
            t += 60
        }
        guard means.count >= 60 else { return p }
        let mid = means[(means.count / 4)..<(means.count * 3 / 4)].map { $0.v }
        guard let level = median(mid) else { return p }
        let tol = max(edgeHRTolMinBPM, edgeHRTolFrac * level)
        let ok = means.map { $0.v <= level + tol }
        func sustained(_ i: Int, _ dir: Int) -> Bool {   // ≥10 of the next 15 minutes sleep-like
            var good = 0, n = 0
            for k in 0..<15 { let j = i + dir * k; if j >= 0 && j < ok.count { n += 1; if ok[j] { good += 1 } } }
            return n > 0 && good >= 10
        }
        guard let first = (0..<ok.count).first(where: { ok[$0] && sustained($0, 1) }),
              let last = (0..<ok.count).reversed().first(where: { ok[$0] && sustained($0, -1) }), last > first else { return p }
        let newStart = max(p.start, means[first].t - 150), newEnd = min(p.end, means[last].t + 150)
        // Only act on a meaningful trim; otherwise keep the motion-based edge.
        return Period(stage: "sleep",
                      start: newStart - p.start >= 600 ? newStart : p.start,
                      end: p.end - newEnd >= 600 ? newEnd : p.end)
    }

    // MARK: - detectSleep (public)

    /// Detect sleep sessions from biometric streams. Empty/absent gravity → [].
    /// Gravity-only input degrades gracefully (HR/RR/resp refinements skipped).
    // Flow: quiet-minute runs -> merge -> per-run evidence (quiet fraction, HR dip vs awake) -> night/nap/reject
    //       -> join same-night fragments -> stage each.
    public static func detectSleep(hr: [HRSample] = [],
                                   rr: [RRInterval] = [],
                                   resp: [RespSample] = [],
                                   gravity: [GravitySample],
                                   sleepHRHint: Double? = nil) -> [SleepSession] {
        let grav = gravity.sorted { $0.ts < $1.ts }
        if grav.count < 2 { return [] }

        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sorted { $0.ts < $1.ts }
        let respS = resp.sorted { $0.ts < $1.ts }

        let deltas = gravityDeltas(grav)
        let grid = buildMinuteGrid(grav, deltas)
        let flags = classifyQuietMinutes(grav, grid)
        var runs = buildRuns(grav, flags)
        runs = mergePeriods(runs)

        // Awake reference: HR during minutes with real motion (walking, desk fidgeting, commuting...).
        let awakeHR = hrS.filter { grid.at($0.ts / 60) == 0 }.map { Double($0.bpm) }
        // Too little waking-motion HR → no dip judgement (the day median is contaminated by the sleep itself).
        let awakeRef: Double? = awakeHR.count >= awakeRefMinSamples ? median(awakeHR) : nil

        func evidence(_ start: Int, _ end: Int) -> Evidence {
            let seg = rowsBetween(hrS, start: start, end: end) { $0.ts }.map { Double($0.bpm) }
            var dip: Double? = nil
            if let ref = awakeRef, ref > 0, seg.count >= hrRefineMinSamples, let m = median(seg) { dip = 1.0 - m / ref }
            return Evidence(quietFrac: grid.quietFraction(start, end), hrDip: dip)
        }

        // 1) Fragments that clear the lenient (night) bars; 2) join fragments split by a short wake (bathroom,
        // phone) into one span; 3) judge each joined span with the strict bars for its length / time of day.
        var coreQuietMerged: [Double?] = []
        var fragments: [Period] = []
        for p in runs where p.stage == "sleep" && (p.end - p.start) >= napMinMin * 60 {
            let ev = evidence(p.start, p.end)
            if (ev.quietFrac ?? 0) >= mainMinQuietFrac, (ev.hrDip ?? 1) >= min(mainMinHRDip, napMinHRDip) {
                fragments.append(p)
            }
        }
        var spans: [Period] = []
        for f in fragments {
            if let l = spans.last, canBridge(l.end, f.start, grid: grid) {
                spans[spans.count - 1] = Period(stage: "sleep", start: l.start, end: f.end)
            } else { spans.append(f) }
        }
        // The strict core is judged on motion; remember its quiet fraction, then let the night run on through
        // restless-but-sleeping blocks (HR still at sleep level) so late light sleep is not cut off.
        let dataEnd = grav.last!.ts
        let coreQuiet = spans.map { grid.quietFraction($0.start, $0.end) }
        if spans.count > 0 {
            for i in spans.indices where spans[i].end - spans[i].start >= mainMinMin * 60 / 2 {
                spans[i] = extendFinalWake(spans[i], hr: hrS, grid: grid, dataEnd: dataEnd)
            }
            // Extension can reach the next span: merge any that now touch or overlap.
            var m: [Period] = [], q: [Double?] = []
            for (i, sp) in spans.enumerated() {
                if let l = m.last, sp.start <= l.end { m[m.count - 1] = Period(stage: "sleep", start: l.start, end: max(l.end, sp.end)); q[q.count - 1] = max(q.last! ?? 0, coreQuiet[i] ?? 0) }
                else { m.append(sp); q.append(coreQuiet[i]) }
            }
            spans = m
            coreQuietMerged = q
        }
        // Lying awake before the first / after the last real sleep is not sleep: trim to the HR-supported span.
        spans = spans.map { refineEdges($0, hr: hrS) }
        var joined: [(p: Period, kind: SleepKind)] = spans.enumerated().compactMap { i, sp in
            var ev = evidence(sp.start, sp.end)
            // The strict core already passed the motion test; the restless tail must not fail it.
            if i < coreQuietMerged.count, let cq = coreQuietMerged[i] { ev.quietFrac = max(ev.quietFrac ?? 0, cq) }
            return classifyCandidate(start: sp.start, end: sp.end, ev: ev).map { (sp, $0) }
        }
        // Naps must look like THIS wearer's sleep. Quiet couch time after a workout can pass the motion and
        // waking-HR-dip tests, but its HR sits well above their sleeping HR.
        let mainHR = joined.filter { $0.kind == .main }.flatMap { m in
            rowsBetween(hrS, start: m.p.start, end: m.p.end) { $0.ts }.map { Double($0.bpm) }
        }
        let sleepLevel: Double? = median(mainHR) ?? sleepHRHint.map { $0 * 1.12 }
        joined = joined.filter { j in
            guard j.kind == .nap else { return true }
            let napHR = rowsBetween(hrS, start: j.p.start, end: j.p.end) { $0.ts }.map { Double($0.bpm) }
            guard let m = median(napHR) else { return true }
            if let lvl = sleepLevel { return m <= lvl + max(12, 0.25 * lvl) }
            if let ref = awakeRef, ref > 0 { return 1.0 - m / ref >= napNoReferenceMinHRDip }
            return true
        }

        var sessions: [SleepSession] = []
        for (p, kind) in joined {
            let stages = stageSession(start: p.start, end: p.end, grav: grav,
                                      hr: hrS, rr: rrS, resp: respS)
            let eff = efficiency(start: p.start, end: p.end, stages: stages)
            // Resting HR and HRV come only from valid windows INSIDE this session (see SleepVitals).
            let vitals = SleepVitalsCalculator.compute(start: p.start, end: p.end, stages: stages, hr: hrS, rr: rrS)
            let resting = vitals.restingHR
            let avgHrv = vitals.hrv
            sessions.append(SleepSession(start: p.start, end: p.end, efficiency: eff,
                                         stages: stages, restingHR: resting, avgHRV: avgHrv, kind: kind,
                                         isProvisional: dataEnd - p.end < provisionalWindowMin * 60))
        }
        sessions.sort { $0.start < $1.start }
        return sessions
    }

    /// asleep / in-bed in [0, 1]; asleep = in-bed − wake.
    // Efficiency = (time in bed - wake) / time in bed.
    static func efficiency(start: Int, end: Int, stages: [StageSegment]) -> Double {
        let inBed = Double(end - start)
        if inBed <= 0 { return 0 }
        let wake = stages.filter { $0.stage == "wake" }.reduce(0.0) { $0 + Double($1.end - $1.start) }
        let asleep = max(0.0, inBed - wake)
        return min(1.0, asleep / inBed)
    }

    // MARK: - Stage 1–3: staging over a 30 s epoch grid

    /// First persistent-sleep epoch (onset) and last sleep epoch (final wake).
    // Onset needs several consecutive sleep epochs so a single still epoch doesn't count.
    static func onsetAndFinalWake(_ ckFlags: [Bool]) -> (Int, Int) {
        let n = ckFlags.count
        if n == 0 { return (0, 0) }
        var onset: Int? = nil
        var run = 0
        for (i, s) in ckFlags.enumerated() {
            run = s ? run + 1 : 0
            if run >= onsetPersistEpochs { onset = i - onsetPersistEpochs + 1; break }
        }
        var final: Int? = nil
        for i in stride(from: n - 1, through: 0, by: -1) where ckFlags[i] { final = i; break }
        let o = onset ?? 0
        var f = final ?? (n - 1)
        if f < o { f = n - 1 }
        return (o, f)
    }

    /// Build a 30 s hypnogram for [start, end] and return StageSegments.
    static func stageSession(start: Int, end: Int, grav: [GravitySample],
                             hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> [StageSegment] {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return [StageSegment(start: start, end: end, stage: "light")] }

        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }

        let hrSeg = rowsBetween(hr, start: start, end: end) { $0.ts }
        let rrSeg = rowsBetween(rr, start: start, end: end) { $0.ts }
        let respSeg = rowsBetween(resp, start: start, end: end) { $0.ts }

        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: hrSeg, rr: rrSeg, resp: respSeg)
        if grid.nEpochs == 0 { return [StageSegment(start: start, end: end, stage: "light")] }

        let rescaled = rescaleCounts(grid.counts)
        let ckFlags = coleKripke(rescaled)
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)

        let dogHR = dogHRVariability(grid.hr)
        let feats = extractFeatures(grid: grid, ckFlags: ckFlags, dogHR: dogHR,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        var labels = classifyEpochs(feats)
        labels = smoothLabels(labels)
        labels = reimposePhysiology(labels, features: feats,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        // Pre-onset and post-final-wake epochs are not sleep → force wake.
        for i in 0..<labels.count where i < onsetIdx || i > finalWakeIdx { labels[i] = "wake" }
        // Epochs with no sensor data are unscored, never sleep (zero motion counts would otherwise read as deep rest).
        for i in 0..<labels.count where !grid.covered[i] { labels[i] = "wake" }

        // Merge consecutive same-stage epochs into segments tiling [start, end].
        var segments: [StageSegment] = []
        for (i, stage) in labels.enumerated() {
            let segStart = Int(grid.edges[i].rounded())
            let segEnd = Int(grid.edges[i + 1].rounded())
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].end = segEnd
            } else {
                segments.append(StageSegment(start: segStart, end: segEnd, stage: stage))
            }
        }
        if !segments.isEmpty { segments[segments.count - 1].end = end }
        return segments
    }

    // MARK: - Epoch grid

    struct EpochGrid {
        let start: Double
        let end: Double
        let edges: [Double]
        let counts: [Double]      // per-epoch summed |Δgravity| (raw, pre-rescale)
        let moveFrac: [Double]    // scale-robust per-epoch moving-sample fraction
        let covered: [Bool]       // epoch has gravity data (no data ≠ asleep)
        let hr: [Double]          // per-epoch mean HR (bpm) or NaN
        let rr: [[Double]]        // per-epoch RR intervals (ms)
        let resp: [[Double]]      // per-epoch raw respiration samples
        var nEpochs: Int { counts.count }
        func epochMid(_ i: Int) -> Double { edges[i] + epochS / 2.0 }
    }

    static func buildEpochGrid(start: Double, end: Double,
                               gravTimes: [Int], gravDeltas: [Double],
                               hr: [HRSample], rr: [RRInterval], resp: [RespSample]) -> EpochGrid {
        if end <= start {
            return EpochGrid(start: start, end: end, edges: [start], counts: [],
                             moveFrac: [], covered: [], hr: [], rr: [], resp: [])
        }
        let nEpochs = max(1, Int(ceil((end - start) / epochS)))
        var edges = (0...nEpochs).map { start + Double($0) * epochS }
        edges[nEpochs] = max(edges[nEpochs], end)

        var counts = [Double](repeating: 0, count: nEpochs)
        var moveN = [Int](repeating: 0, count: nEpochs)
        var gravN = [Int](repeating: 0, count: nEpochs)
        var hrSum = [Double](repeating: 0, count: nEpochs)
        var hrCnt = [Int](repeating: 0, count: nEpochs)
        var rrBuckets = [[Double]](repeating: [], count: nEpochs)
        var respBuckets = [[Double]](repeating: [], count: nEpochs)

        func idx(_ ts: Double) -> Int? {
            if ts < start || ts >= end {
                if ts == end { return nEpochs - 1 }
                return nil
            }
            let i = Int((ts - start) / epochS)
            return min(i, nEpochs - 1)
        }

        for (t, d) in zip(gravTimes, gravDeltas) {
            guard let i = idx(Double(t)) else { continue }
            counts[i] += d
            gravN[i] += 1
            if d >= moveDeltaThresholdG { moveN[i] += 1 }
        }
        for r in hr {
            guard let i = idx(Double(r.ts)) else { continue }
            hrSum[i] += Double(r.bpm); hrCnt[i] += 1
        }
        for r in rr {
            guard let i = idx(Double(r.ts)) else { continue }
            rrBuckets[i].append(Double(r.rrMs))
        }
        for r in resp {
            guard let i = idx(Double(r.ts)) else { continue }
            respBuckets[i].append(Double(r.raw))
        }

        let hrMean = (0..<nEpochs).map { hrCnt[$0] > 0 ? hrSum[$0] / Double(hrCnt[$0]) : Double.nan }
        // No gravity coverage → 1.0 (treat as moving; conservative).
        let moveFrac = (0..<nEpochs).map { gravN[$0] > 0 ? Double(moveN[$0]) / Double(gravN[$0]) : 1.0 }

        return EpochGrid(start: start, end: end, edges: edges, counts: counts,
                         moveFrac: moveFrac, covered: (0..<nEpochs).map { gravN[$0] > 0 },
                         hr: hrMean, rr: rrBuckets, resp: respBuckets)
    }

    // MARK: - Cole–Kripke

    static func rescaleCounts(_ counts: [Double]) -> [Double] {
        counts.map { min($0 / ckCountDivisor, ckCountClip) }
    }

    static func coleKripke(_ rescaled: [Double]) -> [Bool] {
        let n = rescaled.count
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            var si = 0.0
            for (k, w) in ckWeights.enumerated() {
                let j = i - ckBack + k
                let a = (j >= 0 && j < n) ? rescaled[j] : 0.0
                si += w * a
            }
            si *= ckScale
            flags.append(si < 1.0)
        }
        return flags
    }

    // MARK: - Walch difference-of-Gaussians HR variability

    static func gaussianKernel(sigmaS: Double, dtS: Double = epochS) -> [Double] {
        let sigma = max(sigmaS / dtS, 1e-6)  // σ in epochs
        let radius = max(1, Int(ceil(3 * sigma)))
        var k = [Double]()
        for x in -radius...radius { k.append(exp(-0.5 * pow(Double(x) / sigma, 2))) }
        let sum = k.reduce(0, +)
        return k.map { $0 / sum }
    }

    /// Same-length convolution with reflect padding (edge-stable).
    static func convolveReflect(_ x: [Double], _ kernel: [Double]) -> [Double] {
        let r = kernel.count / 2
        if r == 0 || x.isEmpty { return x }
        // Reflect padding: numpy 'reflect' mirrors WITHOUT repeating the edge sample.
        var padded = [Double]()
        padded.reserveCapacity(x.count + 2 * r)
        for i in 0..<r { padded.append(x[r - i]) }            // x[r], x[r-1], ... x[1]
        padded.append(contentsOf: x)
        for i in 0..<r { padded.append(x[x.count - 2 - i]) }  // x[n-2], x[n-3], ...
        // Valid convolution, then take the first x.count outputs.
        var out = [Double]()
        out.reserveCapacity(x.count)
        let m = kernel.count
        // np.convolve(padded, kernel, 'valid') has length padded.count - m + 1.
        for i in 0...(padded.count - m) {
            var acc = 0.0
            for j in 0..<m { acc += padded[i + j] * kernel[m - 1 - j] }
            out.append(acc)
            if out.count == x.count { break }
        }
        return out
    }

    /// DoG-filtered HR (σ1=120 s minus σ2=600 s). NaNs linearly interpolated first;
    /// all-NaN → zeros.
    static func dogHRVariability(_ hrPerEpoch: [Double]) -> [Double] {
        let n = hrPerEpoch.count
        if n == 0 { return [] }
        let maskIdx = (0..<n).filter { !hrPerEpoch[$0].isNaN }
        if maskIdx.isEmpty { return [Double](repeating: 0, count: n) }

        // Linear interpolation over the grid (numpy.interp semantics: clamp at edges).
        var filled = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if !hrPerEpoch[i].isNaN { filled[i] = hrPerEpoch[i]; continue }
            // find surrounding known points
            if i <= maskIdx.first! { filled[i] = hrPerEpoch[maskIdx.first!]; continue }
            if i >= maskIdx.last! { filled[i] = hrPerEpoch[maskIdx.last!]; continue }
            var lo = maskIdx.first!, hi = maskIdx.last!
            for m in maskIdx { if m <= i { lo = m } ; if m >= i { hi = m; break } }
            if hi == lo { filled[i] = hrPerEpoch[lo] }
            else {
                let frac = Double(i - lo) / Double(hi - lo)
                filled[i] = hrPerEpoch[lo] + frac * (hrPerEpoch[hi] - hrPerEpoch[lo])
            }
        }

        let k1 = gaussianKernel(sigmaS: hrDogSigma1S)
        let k2 = gaussianKernel(sigmaS: hrDogSigma2S)
        let g1 = convolveReflect(filled, k1)
        let g2 = convolveReflect(filled, k2)
        return (0..<n).map { g1[$0] - g2[$0] }
    }

    // MARK: - Respiration rate + RRV (raw 1 Hz)

    /// Estimate respiratory rate (breaths/min) and RRV (s) from a raw resp window.
    /// Detrend → peak-pick (≥2 s apart) → breath intervals (1.5–12 s) → rate =
    /// 60/median interval, RRV = std of intervals. (nan, nan) when too few samples.
    ///
    /// NOTE: faithful port of sleep_features.resp_rate_and_rrv (which the Python
    /// source derives without neurokit), using a simple local-maxima peak finder.
    static func respRateAndRRV(_ respRaw: [Double], dtS: Double = 1.0) -> (Double, Double) {
        let nan = Double.nan
        if respRaw.count < 8 { return (nan, nan) }
        let mean = respRaw.reduce(0, +) / Double(respRaw.count)
        let x = respRaw.map { $0 - mean }
        if x.allSatisfy({ abs($0) < 1e-12 }) { return (nan, nan) }

        let std = standardDeviation(x)
        if std <= 0 { return (nan, nan) }

        let minDistance = max(2, Int((2.0 / dtS).rounded()))
        let peaks = findPeaks(x, distance: minDistance, height: 0.0)
        if peaks.count < 3 { return (nan, nan) }

        var intervals: [Double] = []
        for i in 1..<peaks.count {
            let iv = Double(peaks[i] - peaks[i - 1]) * dtS
            if iv >= 1.5 && iv <= 12.0 { intervals.append(iv) }
        }
        if intervals.count < 2 { return (nan, nan) }
        let rate = 60.0 / HRVAnalyzer.median(intervals)
        let rrv = standardDeviation(intervals)  // population std (numpy default)
        return (rate, rrv)
    }

    /// Local-maxima peak finder mirroring scipy.find_peaks(distance, height):
    /// a sample is a peak if strictly greater than both neighbours and ≥ height;
    /// peaks closer than `distance` are resolved by keeping the taller.
    static func findPeaks(_ x: [Double], distance: Int, height: Double) -> [Int] {
        let n = x.count
        if n < 3 { return [] }
        var candidates: [Int] = []
        var i = 1
        while i < n - 1 {
            if x[i] > x[i - 1] && x[i] >= height {
                // handle flat plateaus: find right edge of the plateau
                var j = i
                while j + 1 < n && x[j + 1] == x[i] { j += 1 }
                if j + 1 < n && x[j + 1] < x[i] {
                    candidates.append((i + j) / 2)  // plateau midpoint
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        if distance <= 1 || candidates.isEmpty { return candidates }
        // Enforce minimum distance: greedily keep tallest, scipy-style.
        let byHeight = candidates.sorted { x[$0] > x[$1] }
        var keep = [Bool](repeating: true, count: candidates.count)
        let indexOf = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1, $0) })
        for p in byHeight {
            guard let pi = indexOf[p], keep[pi] else { continue }
            for (qi, q) in candidates.enumerated() where qi != pi && keep[qi] {
                if abs(q - p) < distance { keep[qi] = false }
            }
        }
        return candidates.enumerated().filter { keep[$0.offset] }.map { $0.element }.sorted()
    }

    // MARK: - Per-epoch features

    struct EpochFeatures {
        let index: Int
        let midTs: Double
        let count: Double      // rescaled Cole–Kripke activity count
        let moveFrac: Double
        let ckSleep: Bool
        let hr: Double         // mean HR over the feature window
        let hrVar: Double      // Walch DoG-HR windowed std
        let rmssd: Double      // ms
        let sdnn: Double       // ms
        let respRate: Double   // breaths/min
        let rrv: Double        // respiratory-rate variability (s)
        let clock: Double      // normalized time since onset, 0..1
    }

    static func extractFeatures(grid: EpochGrid, ckFlags: [Bool], dogHR: [Double],
                                onsetIdx: Int, finalWakeIdx: Int) -> [EpochFeatures] {
        let n = grid.nEpochs
        let rescaled = rescaleCounts(grid.counts)
        let halfW = Int((featureWindowS / epochS / 2).rounded())
        let span = Double(max(1, finalWakeIdx - onsetIdx))

        var feats: [EpochFeatures] = []
        feats.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - halfW)
            let hi = min(n, i + halfW + 1)

            let winHR = (lo..<hi).map { grid.hr[$0] }.filter { !$0.isNaN }
            let hrMean = winHR.isEmpty ? Double.nan : winHR.reduce(0, +) / Double(winHR.count)

            let winDog = (lo..<hi).map { dogHR.isEmpty ? 0.0 : dogHR[$0] }
            let hrVar = winDog.count >= 2 ? standardDeviation(winDog) : Double.nan

            // RMSSD/SDNN over the pooled RR window (range-filtered, like the
            // Python per-epoch hrv_from_rr which uses RAW range-filtered RR).
            var winRR: [Double] = []
            for j in lo..<hi { winRR.append(contentsOf: grid.rr[j]) }
            let filteredRR = HRVAnalyzer.rangeFilter(winRR)
            let rmssd = filteredRR.count >= 5 ? (HRVAnalyzer.rmssdRaw(filteredRR) ?? Double.nan) : Double.nan
            let sdnn = filteredRR.count >= 5 ? (HRVAnalyzer.sdnnRaw(filteredRR) ?? Double.nan) : Double.nan

            var winResp: [Double] = []
            for j in lo..<hi { winResp.append(contentsOf: grid.resp[j]) }
            let (respRate, rrv) = respRateAndRRV(winResp)

            let clock = min(1.0, max(0.0, Double(i - onsetIdx) / span))

            feats.append(EpochFeatures(
                index: i, midTs: grid.epochMid(i), count: rescaled[i],
                moveFrac: grid.moveFrac[i],
                ckSleep: i < ckFlags.count ? ckFlags[i] : true,
                hr: hrMean, hrVar: hrVar, rmssd: rmssd, sdnn: sdnn,
                respRate: respRate, rrv: rrv, clock: clock))
        }
        return feats
    }

    // MARK: - Percentile helper

    /// numpy-style linear-interpolated percentile over finite values; nil if none.
    static func percentile(_ values: [Double], _ pct: Double) -> Double? {
        let vals = values.filter { $0.isFinite }.sorted()
        if vals.isEmpty { return nil }
        return StrainScorer.percentile(vals, pct)
    }

    // MARK: - Classifier seam (Stage 2)

    static func classifyEpochs(_ rawFeatures: [EpochFeatures]) -> [String] {
        let n = rawFeatures.count
        if n == 0 { return [] }

        let features = detrended(rawFeatures)
        // Session-relative reference distributions over SLEEP-PERIOD epochs.
        let sleepFeats = features.contains { $0.ckSleep } ? features.filter { $0.ckSleep } : features
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)

        let base = features.map {
            classifyOne($0, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                        hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo)
        }

        // Rank still, non-wake epochs by autonomic "depth" and "activation" scores, then assign the most
        // extreme ones to deep / REM up to adult norms (N3 ≈ 13–23%, REM ≈ 20–25% of TST: Ohayon 2004,
        // Sleep 27:1255). Autonomic cues: NREM → parasympathetic dominance, low/steady HR, high RMSSD, deepest in
        // N3; REM → wake-like, variable HR, low RMSSD (Trinder 2001; Boudreau 2013). The absolute margin keeps
        // a noisy / featureless night from being forced into the population split.
        func z(_ v: [Double], _ idx: [Int]) -> [Double] {
            let vals = idx.map { v[$0] }.filter { $0.isFinite }
            guard vals.count >= 2 else { return [Double](repeating: 0, count: v.count) }
            let m = vals.reduce(0, +) / Double(vals.count)
            let sd = standardDeviation(vals)
            return v.map { $0.isFinite && sd > 1e-9 ? ($0 - m) / sd : 0 }
        }
        let pool = (0..<n).filter { base[$0] != "wake" && features[$0].moveFrac <= stageStillMoveFrac }
        guard pool.count >= 20 else { return base }
        let zHR = z(features.map { $0.hr }, pool), zRM = z(features.map { $0.rmssd }, pool)
        let zVar = z(features.map { $0.hrVar }, pool), zRRV = z(features.map { $0.rrv }, pool)
        let depth = (0..<n).map { -zHR[$0] + zRM[$0] - 0.5 * zVar[$0] }
        let act = (0..<n).map { zHR[$0] + 0.5 * zVar[$0] - zRM[$0] + 0.5 * zRRV[$0] + 0.5 * (features[$0].clock - 0.5) }

        var out = base.map { $0 == "wake" ? "wake" : "light" }
        let total = Double(features.filter { $0.ckSleep }.count)
        func top(_ cands: [Int], _ score: [Double], count: Int) -> [Int] {
            cands.filter { score[$0] > stageScoreMargin }.sorted { score[$0] > score[$1] }.prefix(count).map { $0 }
        }
        let deepPool = pool.filter { features[$0].clock <= deepFirstFraction }
        let deepIdx = top(deepPool, depth, count: Int(total * stageDeepTargetPct / 100.0))
        for i in deepIdx { out[i] = "deep" }
        let remPool = pool.filter { out[$0] == "light" && features[$0].clock * Double(max(1, n)) * epochS / 60.0 >= noREMAfterOnsetMin }
        for i in top(remPool, act, count: Int(total * stageREMTargetPct / 100.0)) { out[i] = "rem" }
        return out
    }

    /// Replace HR and RMSSD by their residual from a ±45 min rolling median. HR falls and HRV rises across
    /// the night with circadian phase and sleep pressure independent of stage (Boudreau 2013, Sleep 36:1919;
    /// Trinder 2001), so stage cues must be relative to the *local* level, not the whole-night distribution.
    static func detrended(_ f: [EpochFeatures]) -> [EpochFeatures] {
        func resid(_ v: [Double]) -> [Double] {
            (0..<v.count).map { i in
                guard v[i].isFinite else { return Double.nan }
                let lo = max(0, i - trendHalfWindowEpochs), hi = min(v.count, i + trendHalfWindowEpochs + 1)
                let w = v[lo..<hi].filter { $0.isFinite }
                return w.isEmpty ? Double.nan : v[i] - HRVAnalyzer.median(w)
            }
        }
        let h = resid(f.map { $0.hr }), r = resid(f.map { $0.rmssd })
        return f.enumerated().map { i, e in
            EpochFeatures(index: e.index, midTs: e.midTs, count: e.count, moveFrac: e.moveFrac,
                          ckSleep: e.ckSleep, hr: h[i], hrVar: e.hrVar, rmssd: r[i], sdnn: e.sdnn,
                          respRate: e.respRate, rrv: e.rrv, clock: e.clock)
        }
    }

    static func classifyOne(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                            rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?) -> String {
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!

        // NOTE: HF omitted (no neurokit2). Parasympathetic tone = RMSSD only.
        let parasympHigh = f.rmssd.isFinite && rmssdHi != nil && f.rmssd >= rmssdHi!

        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh

        let rrvIrregular = f.rrv.isFinite && rrvHi != nil && f.rrv >= rrvHi!
        // Missing respiration (NaN RRV) treated as "regular" (pro-deep bias).
        let rrvRegular = (!f.rrv.isFinite) || (rrvLo != nil && f.rrv <= rrvLo!)

        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // WAKE: sustained motion + activated cardiac (or no HR to vet motion).
        if moving && (cardiacActivated || !hasHR) { return "wake" }
        // DEEP: still + high parasympathetic tone + low HR + regular respiration.
        if still && parasympHigh && hrLow && rrvRegular { return "deep" }
        // REM: still body + activated cardiac + irregular respiration.
        if still && cardiacActivated && rrvIrregular { return "rem" }
        // REM fallback when respiration unavailable: require BOTH cardiac signals.
        if still && hrHigh && hrvarHigh && !f.rrv.isFinite { return "rem" }
        return "light"
    }

    // MARK: - Post-processing (Stage 3)

    static func smoothLabels(_ labels: [String], window: Int = smoothEpochs) -> [String] {
        let n = labels.count
        if n == 0 || window <= 1 { return labels }
        var w = window
        if w % 2 == 0 { w += 1 }
        let half = w / 2
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            var counts: [String: Int] = [:]
            var order: [String] = []
            for s in labels[lo..<hi] {
                if counts[s] == nil { order.append(s) }
                counts[s, default: 0] += 1
            }
            let best = counts.values.max()!
            let winners = order.filter { counts[$0] == best }  // insertion order preserved
            out.append(winners.contains(labels[i]) ? labels[i] : winners[0])
        }
        return out
    }

    static func reimposePhysiology(_ labels: [String], features: [EpochFeatures],
                                   onsetIdx: Int, finalWakeIdx: Int) -> [String] {
        var out = labels
        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        for (i, f) in features.enumerated() {
            if i < onsetIdx || i > finalWakeIdx { continue }
            if out[i] == "rem" && (i - onsetIdx) < noREMEpochs { out[i] = "light" }
            if out[i] == "deep" && f.clock > deepFirstFraction { out[i] = "light" }
        }
        return out
    }

    // MARK: - AASM hypnogram metrics

    /// AASM-style metrics from a session's stage segments.
    public struct HypnogramMetrics: Equatable, Sendable {
        public let tibS: Double
        public let tstS: Double
        public let sptS: Double
        public let solS: Double
        public let remLatencyS: Double  // NaN if no REM
        public let wasoS: Double
        public let efficiency: Double
        public let disturbances: Int
        public let deepMin: Double
        public let remMin: Double
        public let lightMin: Double
        public let deepPct: Double
        public let remPct: Double
        public let lightPct: Double
    }

    public static func hypnogramMetrics(_ session: SleepSession) -> HypnogramMetrics {
        let segs = session.stages.sorted { $0.start < $1.start }
        let tib = max(0.0, Double(session.end - session.start))

        func dur(_ s: StageSegment) -> Double { Double(s.end - s.start) }
        let sleepSegs = segs.filter { $0.stage == "light" || $0.stage == "deep" || $0.stage == "rem" }
        let tst = sleepSegs.reduce(0.0) { $0 + dur($1) }
        let deepS = segs.filter { $0.stage == "deep" }.reduce(0.0) { $0 + dur($1) }
        let remS = segs.filter { $0.stage == "rem" }.reduce(0.0) { $0 + dur($1) }
        let lightS = segs.filter { $0.stage == "light" }.reduce(0.0) { $0 + dur($1) }

        let onset: Double, sptEnd: Double, sol: Double
        if let first = sleepSegs.first, let last = sleepSegs.last {
            onset = Double(first.start)
            sptEnd = Double(last.end)
            sol = max(0.0, onset - Double(session.start))
        } else {
            onset = Double(session.end)
            sptEnd = Double(session.end)
            sol = tib
        }

        let remSegs = segs.filter { $0.stage == "rem" }
        let remLatency = remSegs.first.map { Double($0.start) - onset } ?? Double.nan

        var waso = 0.0
        var disturbances = 0
        for s in segs where s.stage == "wake" {
            let w0 = max(Double(s.start), onset)
            let w1 = min(Double(s.end), sptEnd)
            if w1 > w0 { waso += (w1 - w0); disturbances += 1 }
        }

        let se = tib > 0 ? tst / tib : 0.0
        func pct(_ x: Double) -> Double { tst > 0 ? x / tst * 100.0 : 0.0 }

        return HypnogramMetrics(
            tibS: tib, tstS: tst, sptS: max(0.0, sptEnd - onset), solS: sol,
            remLatencyS: remLatency, wasoS: waso, efficiency: min(1.0, se),
            disturbances: disturbances, deepMin: deepS / 60.0, remMin: remS / 60.0,
            lightMin: lightS / 60.0, deepPct: pct(deepS), remPct: pct(remS), lightPct: pct(lightS))
    }

    // MARK: - Small stats helpers

    /// Population standard deviation (numpy default, ddof=0).
    static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return (ss / Double(values.count)).squareRoot()
    }
}
