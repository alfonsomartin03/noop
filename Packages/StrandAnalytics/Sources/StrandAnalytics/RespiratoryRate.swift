import Foundation
import WhoopProtocol

// RespiratoryRate.swift — breathing rate inferred from beat-to-beat (R-R) intervals alone.
//
// Breathing modulates heart rate (respiratory sinus arrhythmia): R-R lengthens on exhale and shortens on
// inhale, so the R-R series carries a periodic component at the breathing frequency. Per window:
//   1. drop implausible / ectopic intervals (range + deviation from the local median),
//   2. place each surviving interval on a time axis built from the cumulative interval lengths (the stored
//      timestamps are whole seconds, too coarse to use directly) and resample to 4 Hz by linear interpolation,
//   3. remove the slow trend with a moving average (so the <0.1 Hz drift cannot masquerade as breathing),
//   4. take the Hann-windowed power spectrum over 0.15–0.40 Hz (9–24 breaths/min; below 9 sits the ~0.1 Hz baroreflex rhythm, which on real nights was mistaken for breathing) with Goertzel,
//   5. accept the peak only when it holds a clear share of the band's power; otherwise there is no estimate.
// An unreliable window yields nil, never a guess.
//
// EVIDENCE STATUS: experimental. This is an INFERRED respiratory-sinus-arrhythmia frequency, not a direct breath
// count, and it has not been validated against a respiratory reference on NOOP's own data. The synthetic tests only
// show the arithmetic recovers a known frequency (breaths/min = 60 × Hz); they say nothing about physiological
// accuracy. It is kept out of the recovery score (see AnalyticsEngine) and must not be compared with a direct
// respiration channel or a WHOOP-reported rate in one baseline.
//
// Time axis: cumulative interval length is a valid clock ONLY while the beat series is continuous. A dropped packet
// removes beats without removing time, so `estimate(beats:)` first splits the timestamped series wherever stamped
// time and summed R-R time disagree (`contiguousRuns`) and analyses one continuous run; `estimate(rrMs:)` assumes the
// caller already guarantees continuity.

public enum RespiratoryRate {
    public static let sampleHz = 4.0
    public static let bandLowHz = 0.15
    public static let bandHighHz = 0.40
    public static let binHz = 0.005
    /// Minimum seconds of usable signal. 2 min holds ≥ 12 breaths at the low end of the band.
    public static let minSpanS = 120.0
    /// Share of intervals that must survive artifact rejection.
    public static let minKeptShare = 0.80
    /// Longest stretch (s) without a surviving interval that is still bridged by interpolation.
    public static let maxGapS = 8.0
    /// Share of band power that must sit within ±`peakHalfWidthHz` of the peak.
    public static let minPeakShare = 0.35
    public static let peakHalfWidthHz = 0.025
    static let trendWindowS = 10.0

    public struct Result: Equatable, Sendable {
        /// Breaths per minute, or nil when the window cannot support an estimate.
        public let breathsPerMin: Double?
        /// Share of in-band power near the peak (0…1); a confidence proxy.
        public let peakShare: Double
        public let rejection: String?
    }

    /// Largest disagreement (s) between a beat's stamp and the summed R-R clock of its run before the run is cut:
    /// 1 s of whole-second stamping plus slack. A missing ~1 s beat or packet exceeds it within a beat or two.
    public static let maxClockDriftS = 2.0

    /// Split timestamped beats (acquisition order) into runs that are continuous in the original recording: consecutive
    /// stamps no more than `HRVAnalyzer.maxBeatGapS` apart AND the summed intervals agreeing with the stamps within
    /// `maxClockDriftS`. Too much stamped time means beats were lost; too little means duplicated/overlapping beats.
    public static func contiguousRuns(_ beats: [RRInterval]) -> [[RRInterval]] {
        var runs: [[RRInterval]] = []
        var cur: [RRInterval] = []
        var anchorTs = 0, clock = 0.0
        for b in beats {
            if let last = cur.last {
                clock += Double(b.rrMs) / 1000.0
                let drift = Double(b.ts - anchorTs) - clock
                if b.ts - last.ts > HRVAnalyzer.maxBeatGapS || b.ts < last.ts || abs(drift) > maxClockDriftS {
                    runs.append(cur); cur = []
                }
            }
            if cur.isEmpty { anchorTs = b.ts; clock = 0 }
            cur.append(b)
        }
        if !cur.isEmpty { runs.append(cur) }
        return runs
    }

    /// Timestamp-aware estimate: analyse the longest continuous run (never splice across a gap).
    public static func estimate(beats: [RRInterval]) -> Result {
        let runs = contiguousRuns(beats)
        guard let longest = runs.max(by: { $0.count < $1.count }) else {
            return Result(breathsPerMin: nil, peakShare: 0, rejection: "too few intervals")
        }
        let r = estimate(rrMs: longest.map { Double($0.rrMs) })
        if r.breathsPerMin == nil, runs.count > 1, r.rejection == "short signal" || r.rejection == "too few intervals" {
            return Result(breathsPerMin: nil, peakShare: 0, rejection: "gap")
        }
        return r
    }

    /// Estimate breaths/min from consecutive R-R intervals (ms) in recording order. The caller guarantees the series
    /// is continuous (no lost beats); use `estimate(beats:)` for stored, timestamped data.
    public static func estimate(rrMs: [Double]) -> Result {
        func fail(_ why: String) -> Result { Result(breathsPerMin: nil, peakShare: 0, rejection: why) }
        guard rrMs.count >= 30 else { return fail("too few intervals") }

        // Beat times from cumulative interval length (each beat stamped at the end of its interval).
        var times = [Double](), vals = [Double]()
        var clock = 0.0
        var kept = 0
        for (i, rr) in rrMs.enumerated() {
            clock += rr / 1000.0
            guard rr >= 300, rr <= 2000 else { continue }
            let lo = max(0, i - 3), hi = min(rrMs.count - 1, i + 3)
            let local = HRVAnalyzer.median(Array(rrMs[lo...hi]))
            guard abs(rr - local) <= 0.20 * local else { continue }
            times.append(clock); vals.append(rr); kept += 1
        }
        guard Double(kept) >= minKeptShare * Double(rrMs.count) else { return fail("artifacts") }
        guard let first = times.first, let last = times.last, last - first >= minSpanS else { return fail("short signal") }
        for i in 1..<times.count where times[i] - times[i - 1] > maxGapS { return fail("gap") }

        // Resample to a uniform grid.
        let n = Int((last - first) * sampleHz)
        var x = [Double](repeating: 0, count: n)
        var j = 0
        for k in 0..<n {
            let t = first + Double(k) / sampleHz
            while j + 2 < times.count && times[j + 1] < t { j += 1 }
            let t0 = times[j], t1 = times[j + 1]
            let f = t1 > t0 ? min(1, max(0, (t - t0) / (t1 - t0))) : 0
            x[k] = vals[j] + f * (vals[j + 1] - vals[j])
        }

        // Detrend with a centred moving average, then apply a Hann window.
        let half = Int(trendWindowS * sampleHz / 2)
        var prefix = [Double](repeating: 0, count: n + 1)
        for k in 0..<n { prefix[k + 1] = prefix[k] + x[k] }
        for k in 0..<n {
            let a = max(0, k - half), b = min(n, k + half + 1)
            let mean = (prefix[b] - prefix[a]) / Double(b - a)
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n - 1))
            x[k] = (x[k] - mean) * w
        }

        // Goertzel power at each band bin.
        let bins = Int(((bandHighHz - bandLowHz) / binHz).rounded()) + 1
        var freqs = [Double](), power = [Double]()
        for b in 0..<bins {
            let f = bandLowHz + Double(b) * binHz
            let coeff = 2 * cos(2 * Double.pi * f / sampleHz)
            var s1 = 0.0, s2 = 0.0
            for v in x { let s = v + coeff * s1 - s2; s2 = s1; s1 = s }
            freqs.append(f); power.append(max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2))
        }
        let total = power.reduce(0, +)
        guard total > 0, let peak = power.indices.max(by: { power[$0] < power[$1] }) else { return fail("no signal") }
        // A peak hugging the band edge is leakage from slow drift or fast artifacts, not breathing.
        guard peak >= 3, peak <= bins - 4 else { return Result(breathsPerMin: nil, peakShare: 0, rejection: "peak at band edge") }
        let near = power.indices.filter { abs(freqs[$0] - freqs[peak]) <= peakHalfWidthHz }
        let share = near.reduce(0.0) { $0 + power[$1] } / total
        guard share >= minPeakShare else { return Result(breathsPerMin: nil, peakShare: share, rejection: "no clear breathing peak") }

        // Power-weighted centroid around the peak refines the estimate below the bin spacing.
        let wSum = near.reduce(0.0) { $0 + power[$1] }
        let centroid = near.reduce(0.0) { $0 + freqs[$1] * power[$1] } / wSum
        return Result(breathsPerMin: centroid * 60.0, peakShare: share, rejection: nil)
    }
}
