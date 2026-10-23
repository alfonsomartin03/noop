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
// `edgeStartMin` / last `edgeEndMin` minutes (sleep-onset and waking transitions), it is ≥ 90 % non-wake per the
// staged hypnogram, and it has enough data (HR: ≥ 60 % of seconds; HRV: beats ≥ 50 % of those expected from the
// window's HR, ≥ 60 clean intervals, ≥ 80 % of intervals surviving artifact rejection).
// With fewer than `minValidWindows` valid windows the metric is nil: unavailable, never guessed.

public struct VitalWindow: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let meanHR: Double?
    public let hrSamples: Int
    public let beats: Int          // RR intervals in the window
    public let cleanBeats: Int     // surviving range + artifact rejection
    public let rmssd: Double?
    public let beatCoverage: Double?   // beats ÷ beats expected from meanHR
    public let wakeFraction: Double
    /// Why the window is excluded from HR metrics / HRV (nil = used).
    public let hrRejection: String?
    public let hrvRejection: String?
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
    public let onsetHR: Double?       // first used window
    public let wakeHR: Double?        // last used window
    public let hrSamples: Int
    public let rrBeats: Int
    public let rrClean: Int
    public let rejectionCounts: [String: Int]
    public var hrvWindowCount: Int { windows.filter { $0.usedForHRV }.count }
    public var hrWindowCount: Int { windows.filter { $0.usedForHR }.count }
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
    /// Fraction of the lowest valid HR windows averaged into the resting HR.
    public static let restingQuantile = 0.25

    public static func compute(start: Int, end: Int, stages: [StageSegment],
                               hr: [HRSample], rr: [RRInterval]) -> SleepVitals {
        let hrS = hr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let rrS = rr.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        let wake = stages.filter { $0.stage == "wake" }

        func wakeFrac(_ a: Int, _ b: Int) -> Double {
            let w = wake.reduce(0) { $0 + max(0, min($1.end, b) - max($1.start, a)) }
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
            let wf = wakeFrac(t, e)

            var common: String? = nil
            if t - start < edgeStartMin * 60 { common = "onset transition" }
            else if end - e < edgeEndMin * 60 { common = "waking transition" }
            else if wf > maxWakeFraction { common = "awake" }

            var hrRej = common
            if hrRej == nil, Double(h.count) < minHRCoverage * Double(windowS) { hrRej = "low HR coverage" }

            var hrvRej = common
            var result = HRVAnalyzer.HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil, nInput: r.count, nClean: 0)
            var coverage: Double? = nil
            if let m = meanHR, m > 0 { coverage = Double(r.count) / (m * Double(windowS) / 60.0) }
            if hrvRej == nil {
                if let c = coverage, c < minBeatCoverage { hrvRej = "missing RR intervals" }
                else if coverage == nil { hrvRej = "no HR to validate RR" }
            }
            if hrvRej == nil {
                result = HRVAnalyzer.analyzeTimed(r)
                if result.rmssd == nil || result.nClean < minCleanBeats { hrvRej = "too few clean intervals" }
                else if Double(result.nClean) < minCleanShare * Double(result.nInput) { hrvRej = "artifacts" }
            }
            if let x = hrRej { counts["HR: " + x, default: 0] += 1 }
            if let x = hrvRej { counts["HRV: " + x, default: 0] += 1 }
            windows.append(VitalWindow(start: t, end: e, meanHR: meanHR, hrSamples: h.count, beats: r.count,
                                       cleanBeats: result.nClean, rmssd: hrvRej == nil ? result.rmssd : nil,
                                       beatCoverage: coverage, wakeFraction: wf,
                                       hrRejection: hrRej, hrvRejection: hrvRej))
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

        return SleepVitals(
            windows: windows,
            restingHR: resting,
            avgSleepHR: hrUsed.isEmpty ? nil : hrUsed.reduce(0, +) / Double(hrUsed.count),
            minWindowHR: hrUsed.min(),
            minSampleHR: hrS.map { $0.bpm }.min(),
            hrv: hrv,
            onsetHR: windows.first(where: { $0.usedForHR })?.meanHR,
            wakeHR: windows.last(where: { $0.usedForHR })?.meanHR,
            hrSamples: hrS.count, rrBeats: rrS.count,
            rrClean: windows.reduce(0) { $0 + $1.cleanBeats },
            rejectionCounts: counts)
    }
}
