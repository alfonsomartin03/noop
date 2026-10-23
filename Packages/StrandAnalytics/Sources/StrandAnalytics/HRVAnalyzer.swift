import Foundation
import WhoopProtocol

// HRVAnalyzer.swift — RMSSD + SDNN from RR intervals with cleaning.
//
// Ported from server/ingest/app/analysis/hrv.py. The Task Force (1996) RMSSD and
// SDNN definitions are reproduced exactly:
//
//   RMSSD = sqrt( mean( (NN[i+1] − NN[i])^2 ) )           (Task Force 1996)
//   SDNN  = sample standard deviation of NN (ddof = 1)     (Task Force 1996)
//
// Cleaning pipeline:
//   1. Range filter: drop intervals outside [RR_MIN_MS, RR_MAX_MS] = [300, 2000] ms.
//   2. Ectopic rejection: drop beats whose RR deviates > ~20% from a local median
//      (Malik-style filter).
//   3. Require >= MIN_BEATS (20) valid intervals before a trustworthy result.
//
// NOTE: the Python source runs neurokit2's Kubios / Lipponen–Tarvainen (2019)
// artifact classifier, which is unavailable on-device. We substitute the
// classical Malik 20% local-median rule (Malik et al. 1989), the most widely
// cited ectopic-rejection heuristic. This is a simpler, fully-deterministic
// approximation of the same intent — remove physiologically impossible
// beat-to-beat jumps before computing HRV — at the cost of not modelling the
// missed/extra-beat insertion that Kubios does.

public enum HRVAnalyzer {

    /// Minimum plausible RR interval (ms) — 300 ms ≈ 200 bpm.
    public static let rrMinMs: Double = 300
    /// Maximum plausible RR interval (ms) — 2000 ms ≈ 30 bpm.
    public static let rrMaxMs: Double = 2000
    /// Minimum valid intervals required for a trustworthy RMSSD/SDNN.
    public static let minBeats: Int = 20
    /// Malik-style ectopic threshold: a beat deviating more than this fraction
    /// from the local median is rejected. 0.20 == 20%.
    public static let ectopicThreshold: Double = 0.20
    /// Half-width (in beats) of the local-median window used for ectopic rejection.
    /// A window of 2*radius+1 beats (5 beats at radius 2) matches the common
    /// Malik moving-window implementations.
    public static let ectopicWindowRadius: Int = 2

    /// Result of an HRV computation over a window.
    public struct HRVResult: Equatable, Sendable {
        /// RMSSD in milliseconds, or nil when too few valid beats.
        public let rmssd: Double?
        /// SDNN (sample SD, ddof=1) in milliseconds, or nil when too few valid beats.
        public let sdnn: Double?
        /// Mean NN interval (ms) over the cleaned beats, or nil.
        public let meanNN: Double?
        /// pNN50: % of successive |ΔNN| > 50 ms, or nil.
        public let pnn50: Double?
        /// Count of RR intervals supplied to the analysis (before cleaning).
        public let nInput: Int
        /// Count of clean NN intervals after range + ectopic filtering.
        public let nClean: Int

        public init(rmssd: Double?, sdnn: Double?, meanNN: Double?, pnn50: Double?,
                    nInput: Int, nClean: Int) {
            self.rmssd = rmssd
            self.sdnn = sdnn
            self.meanNN = meanNN
            self.pnn50 = pnn50
            self.nInput = nInput
            self.nClean = nClean
        }

        /// An empty/insufficient-data result that preserves the input count.
        static func empty(nInput: Int) -> HRVResult {
            HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                      nInput: nInput, nClean: 0)
        }
    }

    // MARK: - Primitive Task Force statistics (no filtering)

    /// Task Force (1996) RMSSD over already-clean NN intervals (ms). Returns nil
    /// when fewer than 2 values (no successive differences). No filtering applied.
    // RMSSD: root-mean-square of beat-to-beat differences; reflects short-term (parasympathetic) variability.
    public static func rmssdRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(nn.count - 1)).squareRoot()
    }

    /// Sample standard deviation (ddof = 1) of NN intervals (ms). Returns nil for
    /// fewer than 2 values. Matches neurokit2 HRV_SDNN. No filtering applied.
    public static func sdnnRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        var ss = 0.0
        for v in nn { let d = v - mean; ss += d * d }
        return (ss / Double(nn.count - 1)).squareRoot()
    }

    // MARK: - Cleaning

    /// Range filter: keep only intervals in [rrMinMs, rrMaxMs], preserving order.
    public static func rangeFilter(_ rr: [Double]) -> [Double] {
        rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    }

    /// Malik-style ectopic rejection: drop any beat that deviates from its local
    /// median by more than `ectopicThreshold` (20%). The local median is taken
    /// over a centered window of `2*ectopicWindowRadius+1` beats (excluding the
    /// beat under test). Beats with too small a neighbourhood are kept.
    ///
    /// NOTE: this replaces neurokit2's Kubios classifier (see file header).
    // Compare each beat to the median of its neighbours (excluding itself); big jumps are ectopic/artifact beats.
    public static func rejectEctopic(_ nn: [Double]) -> [Double] {
        guard nn.count > ectopicWindowRadius else { return nn }
        var kept: [Double] = []
        kept.reserveCapacity(nn.count)
        for i in 0..<nn.count {
            let lo = max(0, i - ectopicWindowRadius)
            let hi = min(nn.count - 1, i + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != i { neighbours.append(nn[j]) }
            // Too few neighbours (edges of the series): keep the beat rather than guess.
            guard neighbours.count >= 2 else { kept.append(nn[i]); continue }
            let med = median(neighbours)
            if med <= 0 { kept.append(nn[i]); continue }
            let deviation = abs(nn[i] - med) / med
            if deviation <= ectopicThreshold {
                kept.append(nn[i])
            }
            // else: drop this beat as ectopic.
        }
        return kept
    }

    /// Full clean: range filter → ectopic rejection. Returns the clean NN series.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        rejectEctopic(rangeFilter(rr))
    }

    // MARK: - Windowed analysis

    /// Compute HRV (RMSSD/SDNN/meanNN/pNN50) over the RR intervals whose ts falls
    /// in [windowStart, windowEnd] (inclusive). Pass nil bounds to use all rows.
    ///
    /// Applies the range filter, Malik ectopic rejection, then requires
    /// `minBeats` clean intervals; otherwise returns an empty result.
    public static func analyze(_ rr: [RRInterval],
                               windowStart: Int? = nil,
                               windowEnd: Int? = nil) -> HRVResult {
        let inWindow = rr.filter { sample in
            if let s = windowStart, sample.ts < s { return false }
            if let e = windowEnd, sample.ts > e { return false }
            return true
        }
        return analyzeTimed(inWindow)
    }

    /// Beats further apart than this (s) are not neighbours: RMSSD must never difference across a data gap.
    public static let maxBeatGapS = 3

    /// Compute HRV from raw RR-interval values (ms), applying the full cleaning
    /// pipeline. Returns an empty result when fewer than `minBeats` survive.
    /// The values are taken as one uninterrupted beat series.
    public static func analyze(rawRR: [Double]) -> HRVResult {
        analyze(values: rawRR, contiguousWithPrevious: [Bool](repeating: true, count: rawRR.count))
    }

    /// Time-aware HRV for a window of timestamped intervals: successive differences are only taken between beats that
    /// are neighbours in the recording (no beat removed between them, timestamps ≤ `maxBeatGapS` apart).
    public static func analyzeTimed(_ rr: [RRInterval]) -> HRVResult {
        let s = rr.sorted { $0.ts < $1.ts }
        var contiguous = [Bool](repeating: false, count: s.count)
        for i in s.indices.dropFirst() { contiguous[i] = s[i].ts - s[i - 1].ts <= maxBeatGapS }
        return analyze(values: s.map { Double($0.rrMs) }, contiguousWithPrevious: contiguous)
    }

    /// Core: range filter → Malik ectopic mask → RMSSD/pNN50 over ADJACENT surviving pairs, SDNN over survivors.
    // A rejected beat breaks the chain: the pair (i-1, i+1) around it is NOT differenced, which would be a
    // two-interval jump and inflates RMSSD.
    static func analyze(values: [Double], contiguousWithPrevious: [Bool]) -> HRVResult {
        let nInput = values.count
        // Range filter first; Malik then judges each beat against the in-range neighbours only.
        let inRangeIdx = values.indices.filter { values[$0] >= rrMinMs && values[$0] <= rrMaxMs }
        let inRange = inRangeIdx.map { values[$0] }
        var keep = [Bool](repeating: false, count: values.count)
        let kept = rejectEctopicMask(inRange)
        for (k, idx) in inRangeIdx.enumerated() where kept[k] { keep[idx] = true }
        let clean = values.indices.filter { keep[$0] }.map { values[$0] }
        guard clean.count >= minBeats else { return .empty(nInput: nInput) }

        var sumSq = 0.0, pairs = 0, nn50 = 0
        for i in values.indices.dropFirst() where keep[i] && keep[i - 1] && contiguousWithPrevious[i] {
            let d = values[i] - values[i - 1]
            sumSq += d * d; pairs += 1
            if abs(d) > 50 { nn50 += 1 }
        }
        guard pairs >= minBeats / 2 else { return .empty(nInput: nInput) }
        return HRVResult(rmssd: (sumSq / Double(pairs)).squareRoot(), sdnn: sdnnRaw(clean),
                         meanNN: clean.reduce(0, +) / Double(clean.count),
                         pnn50: Double(nn50) / Double(pairs) * 100.0, nInput: nInput, nClean: clean.count)
    }

    /// Which beats survive Malik rejection (same rule as `rejectEctopic`, but as a mask).
    static func rejectEctopicMask(_ nn: [Double]) -> [Bool] {
        guard nn.count > ectopicWindowRadius else { return [Bool](repeating: true, count: nn.count) }
        return nn.indices.map { i in
            let lo = max(0, i - ectopicWindowRadius), hi = min(nn.count - 1, i + ectopicWindowRadius)
            let neighbours = (lo...hi).filter { $0 != i }.map { nn[$0] }
            guard neighbours.count >= 2 else { return true }
            let med = median(neighbours)
            return med <= 0 || abs(nn[i] - med) / med <= ectopicThreshold
        }
    }

    // MARK: - Helpers

    /// Median of a non-empty array. (Caller guarantees non-empty.)
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
