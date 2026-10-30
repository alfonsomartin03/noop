import Foundation
import WhoopProtocol

// SupportedHR.swift — the one time-accounting layer: which seconds a heart rate is actually known for.
//
// Every load, coverage, mean HR, zone time and session summary is computed from these intervals, so they cannot
// disagree about what was observed. A timestamp is not proof of continuous measurement until the next timestamp.
//
// Acquisition contract: the strap reports one HR value per second (type-47 records carry a real unix timestamp). On the
// reference device, 804,460 of 804,555 consecutive gaps over 15 days were exactly 1 s; the rest were sensor gaps.
//   measured  [ts, ts + nominalS)  the second the reading describes.
//   held      up to maxHoldS from ts, stopping at the next reading: a bounded hold across a short dropout. It is an
//             ESTIMATE, labelled as such and counted separately. Time past the hold is unknown, not low or zero.
// The last reading gets its own measured second and no hold: nothing confirms the signal continued.
//
// Intervals are half-open, sorted and non-overlapping. Clipping and exclusion are exact, so a span crossing midnight or
// an exclusion splits by elapsed time and no second is ever counted twice. maxHoldS is an engineering choice (it covers
// the short dropouts seen in practice), not a physiological constant.

public enum HRSupport: String, Codable, Sendable { case measured, held }

public struct HRInterval: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let bpm: Int
    public let support: HRSupport
    /// Timestamp of the reading this interval came from. For a hold, that reading lies before `start`.
    public let readingTs: Int
    public var seconds: Int { end - start }
}

public struct SupportedHR: Equatable, Sendable {
    /// Seconds one reading describes.
    public static let nominalS = 1
    /// Furthest a reading may be held across a dropout, counted from its timestamp.
    public static let maxHoldS = 5
    /// Identifies this policy in stored results; bump it if the two values above change.
    public static let policyVersion = "hr-support-1hz-hold5-v1"

    public let intervals: [HRInterval]

    /// `cleaned` must be sorted with unique timestamps, as `HRQuality.clean` returns.
    public init(cleaned samples: [HRSample]) {
        var out: [HRInterval] = []
        out.reserveCapacity(samples.count)
        for (i, s) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1].ts : nil
            let measuredEnd = min(s.ts + Self.nominalS, next ?? Int.max)
            out.append(HRInterval(start: s.ts, end: measuredEnd, bpm: s.bpm, support: .measured, readingTs: s.ts))
            if let next {
                let heldEnd = min(s.ts + Self.maxHoldS, next)
                if heldEnd > measuredEnd {
                    out.append(HRInterval(start: measuredEnd, end: heldEnd, bpm: s.bpm, support: .held, readingTs: s.ts))
                }
            }
        }
        intervals = out
    }

    public init(raw samples: [HRSample]) { self.init(cleaned: HRQuality.clean(samples)) }

    init(intervals: [HRInterval]) { self.intervals = intervals }

    public var observedSeconds: Int { intervals.reduce(0) { $0 + $1.seconds } }

    /// Only the parts inside `span` and outside `excluding`, cut exactly at each boundary. A reading inside an excluded
    /// span carries nothing out of it: its hold is dropped, so what is excluded can never reach the time that remains.
    public func clipped(to span: TimeSpan, excluding: [TimeSpan] = []) -> SupportedHR {
        guard span.end > span.start else { return SupportedHR(intervals: []) }
        let holes = SleepAccounting.union(excluding)
        var out: [HRInterval] = []
        var i = firstIndex(endingAfter: span.start)
        while i < intervals.count, intervals[i].start < span.end {
            let x = intervals[i]
            i += 1
            if holes.contains(where: { x.readingTs >= $0.start && x.readingTs < $0.end }) { continue }
            func piece(_ a: Int, _ b: Int) -> HRInterval {
                HRInterval(start: a, end: b, bpm: x.bpm, support: x.support, readingTs: x.readingTs)
            }
            var from = max(x.start, span.start)
            let to = min(x.end, span.end)
            for h in holes where h.end > from && h.start < to {
                if h.start > from { out.append(piece(from, h.start)) }
                from = max(from, h.end)
            }
            if to > from { out.append(piece(from, to)) }
        }
        return SupportedHR(intervals: out)
    }

    /// Seconds of support inside `span`.
    public func observedSeconds(in span: TimeSpan) -> Int {
        guard span.end > span.start else { return 0 }
        var total = 0
        var i = firstIndex(endingAfter: span.start)
        while i < intervals.count, intervals[i].start < span.end {
            total += min(intervals[i].end, span.end) - max(intervals[i].start, span.start)
            i += 1
        }
        return total
    }

    private func firstIndex(endingAfter t: Int) -> Int {
        var lo = 0, hi = intervals.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if intervals[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
