import Foundation
import WhoopProtocol

// SleepVitals.swift — sleep-derived HR and HRV, measured only inside the detected sleep session.
//
// Four different quantities are kept apart (they are NOT interchangeable):
//   minSampleHR   lowest single HR sample of the session        (diagnostic only)
//   minWindowHR   lowest 5-min mean HR                          (the old "resting HR"; a floor, not a typical value)
//   avgSleepHR    mean HR over all valid sleep windows
//   restingHR     SLEEP-DERIVED resting HR = mean of the lowest quartile of valid 5-min windows
// Awake resting HR is a separate quantity and is not produced here.
//
// HRV is RMSSD (Task Force 1996) per 5-min window from beat-to-beat intervals only, never from HR. The selected
// value is the MEDIAN of the valid windows, so a handful of artifact-inflated windows cannot raise it
// (a mean over unfiltered windows gave 74 ms where the same night's median of clean windows is ~51 ms).
//
// A 5-min window is used for a metric only when: it lies inside the session and outside the first
// `edgeStartMin` / last `edgeEndMin` minutes (sleep-onset and waking transitions), it is ≥ 90 % non-wake AND
// ≥ 90 % known-state per the staged hypnogram (an unscored/off-wrist stretch cannot be confirmed as sleep), and it has
// enough data (HR: ≥ 60 % of the window's SECONDS carry a sample — distinct seconds, so duplicated rows add nothing;
// HRV: beats ≥ 50 % of those expected from the window's HR, ≥ 60 clean intervals, ≥ 80 % of intervals surviving
// artifact rejection, and the beats' summed durations not exceeding the window's elapsed time by more than 15 %,
// which only duplicated or overlapping beat streams can do).
// With fewer than `minValidWindows` valid windows the metric is nil: unavailable, never guessed.
//
// Every numeric gate here is a NOOP engineering choice, not an established validity cutoff. The temporal
// distribution of valid HRV windows (per third of the session) is reported so a value built from 30 minutes at onset
// is visibly different from one spread across the night (`hrvSpansNight`).

public struct VitalWindow: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let meanHR: Double?
    public let hrSamples: Int
    public let beats: Int          // RR intervals in the window
    public let cleanBeats: Int     // surviving range + artifact rejection
    /// Valid adjacent NN pairs behind `rmssd` (its denominator).
    public var pairs: Int = 0
    public let rmssd: Double?
    public let beatCoverage: Double?   // beats ÷ beats expected from meanHR
    public let wakeFraction: Double
    /// Why the window is excluded from HR metrics / HRV (nil = used).
    public let hrRejection: String?
    public let hrvRejection: String?
    /// Breaths/min inferred from this window's R-R (see `RespiratoryRate`); nil when unreliable.
    public var respRate: Double? = nil
    public var usedForHR: Bool { hrRejection == nil }
    public var usedForHRV: Bool { hrvRejection == nil }
}

public struct SleepVitals: Equatable, Sendable {
    public let windows: [VitalWindow]
    public let restingHR: Int?
    public let avgSleepHR: Double?
    public let minWindowHR: Double?
    public let minSampleHR: Int?
    public let hrv: Double?
    /// Median breaths/min over the valid windows, or nil with fewer than `minValidWindows`.
    public var respRate: Double? = nil
    public let onsetHR: Double?       // first used window
    public let wakeHR: Double?        // last used window
    public let hrSamples: Int
    public let rrBeats: Int
    public let rrClean: Int
    public let rejectionCounts: [String: Int]
    public var hrvWindowCount: Int { windows.filter { $0.usedForHRV }.count }
    public var hrWindowCount: Int { windows.filter { $0.usedForHR }.count }
    /// Valid adjacent NN pairs summed over the windows used for HRV.
    public var hrvPairCount: Int { windows.filter { $0.usedForHRV }.reduce(0) { $0 + $1.pairs } }
    /// Valid HRV windows falling in the first / middle / last third of the session (by window midpoint).
    public var hrvWindowsByThird: [Int] = [0, 0, 0]
    /// Share of the session's windows that were valid for HRV (0…1): temporal coverage, not beat coverage.
    public var hrvTemporalCoverage: Double {
        windows.isEmpty ? 0 : Double(hrvWindowCount) / Double(windows.count)
    }
    /// True when valid HRV windows occur in at least two thirds of the night (a provisional representativeness flag).
    public var hrvSpansNight: Bool { hrvWindowsByThird.filter { $0 > 0 }.count >= 2 }
}

public enum SleepVitalsCalculator {
    public static let windowS = 300
    public static let edgeStartMin = 10
    public static let edgeEndMin = 5
    public static let minValidWindows = 6
    public static let maxWakeFraction = 0.10
    public static let minHRCoverage = 0.60
    public static let minBeatCoverage = 0.50
    public static let minCleanBeats = 60
    public static let minCleanShare = 0.80
    /// Summed R-R may exceed elapsed window time by at most this share (beat boundaries + stamping jitter).
    public static let maxBeatTimeExcess = 0.15
    /// Fraction of the lowest valid HR windows averaged into the resting HR.
    public static let restingQuantile = 0.25

    public static func compute(start: Int, end: Int, stages: [StageSegment],
                               hr: [HRSample], rr: [RRInterval]) -> SleepVitals {
        let hrS = hr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let rrS = rr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let wake = stages.filter { $0.stage == SleepState.wake.rawValue }
        let unknown = stages.filter { $0.stage == SleepState.unknown.rawValue }

        func frac(_ segs: [StageSegment], _ a: Int, _ b: Int) -> Double {
            let w = segs.reduce(0) { $0 + max(0, min($1.end, b) - max($1.start, a)) }
            return Double(w) / Double(max(1, b - a))
        }

        var windows: [VitalWindow] = []
        var counts: [String: Int] = [:]
        var t = start
        while t + windowS <= end {
            let e = t + windowS
            let h = hrS.filter { $0.ts >= t && $0.ts < e }
            let r = rrS.filter { $0.ts >= t && $0.ts < e }
            let meanHR: Double? = h.isEmpty ? nil : Double(h.reduce(0) { $0 + $1.bpm }) / Double(h.count)
            let wf = frac(wake, t, e)
            let hrSeconds = Set(h.map(\.ts)).count

            var common: String? = nil
            if t - start < edgeStartMin * 60 { common = "onset transition" }
            else if end - e < edgeEndMin * 60 { common = "waking transition" }
            else if wf > maxWakeFraction { common = "awake" }
            else if frac(unknown, t, e) > maxWakeFraction { common = "sleep state unknown" }

            var hrRej = common
            if hrRej == nil, Double(hrSeconds) < minHRCoverage * Double(windowS) { hrRej = "low HR coverage" }

            var hrvRej = common
            var result = HRVAnalyzer.HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil, nInput: r.count, nClean: 0)
            var coverage: Double? = nil
            if let m = meanHR, m > 0 { coverage = Double(r.count) / (m * Double(windowS) / 60.0) }
            if hrvRej == nil {
                let beatTimeS = Double(r.reduce(0) { $0 + $1.rrMs }) / 1000.0
                if let c = coverage, c < minBeatCoverage { hrvRej = "missing RR intervals" }
                else if coverage == nil { hrvRej = "no HR to validate RR" }
                else if beatTimeS > (1 + maxBeatTimeExcess) * Double(windowS) { hrvRej = "excess beats (duplicated stream)" }
            }
            if hrvRej == nil {
                result = HRVAnalyzer.analyzeTimed(r)
                if result.rmssd == nil || result.nClean < minCleanBeats { hrvRej = "too few clean intervals" }
                else if Double(result.nClean) < minCleanShare * Double(result.nInput) { hrvRej = "artifacts" }
            }
            // Respiration rides on the same clean-window gate as HRV, plus its own signal-quality checks.
            var resp: Double? = nil
            if hrvRej == nil {
                let est = RespiratoryRate.estimate(beats: r)
                resp = est.breathsPerMin
                if let why = est.rejection { counts["Resp: " + why, default: 0] += 1 }
            }
            if let x = hrRej { counts["HR: " + x, default: 0] += 1 }
            if let x = hrvRej { counts["HRV: " + x, default: 0] += 1 }
            windows.append(VitalWindow(start: t, end: e, meanHR: meanHR, hrSamples: h.count, beats: r.count,
                                       cleanBeats: result.nClean, pairs: result.nPairs,
                                       rmssd: hrvRej == nil ? result.rmssd : nil,
                                       beatCoverage: coverage, wakeFraction: wf,
                                       hrRejection: hrRej, hrvRejection: hrvRej, respRate: resp))
            t = e
        }

        let hrUsed = windows.filter { $0.usedForHR }.compactMap { $0.meanHR }
        let hrvUsed = windows.compactMap { $0.rmssd }
        var resting: Int? = nil
        if hrUsed.count >= minValidWindows {
            let k = max(1, Int((Double(hrUsed.count) * restingQuantile).rounded(.up)))
            let low = hrUsed.sorted().prefix(k)
            resting = Int((low.reduce(0, +) / Double(low.count)).rounded())
        }
        var hrv: Double? = nil
        if hrvUsed.count >= minValidWindows { hrv = HRVAnalyzer.median(hrvUsed) }

        let respUsed = windows.compactMap { $0.respRate }
        let resp: Double? = respUsed.count >= minValidWindows ? HRVAnalyzer.median(respUsed) : nil

        var thirds = [0, 0, 0]
        let span = Double(max(1, end - start))
        for w in windows where w.usedForHRV {
            thirds[min(2, Int(Double((w.start + w.end) / 2 - start) / span * 3))] += 1
        }

        return SleepVitals(
            windows: windows,
            restingHR: resting,
            avgSleepHR: hrUsed.isEmpty ? nil : hrUsed.reduce(0, +) / Double(hrUsed.count),
            minWindowHR: hrUsed.min(),
            minSampleHR: hrS.map { $0.bpm }.min(),
            hrv: hrv, respRate: resp,
            onsetHR: windows.first(where: { $0.usedForHR })?.meanHR,
            wakeHR: windows.last(where: { $0.usedForHR })?.meanHR,
            hrSamples: hrS.count, rrBeats: rrS.count,
            rrClean: windows.reduce(0) { $0 + $1.cleanBeats },
            rejectionCounts: counts, hrvWindowsByThird: thirds)
    }
}
