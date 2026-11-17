import Foundation
import WhoopProtocol

// WristWear.swift — when the strap itself reported being off the wrist.
//
// Evidence (issue #25, C02a, fw 50.43.1.0): event 10 arrived ~14 s after the wearer took the strap off and event 9
// ~15 s after it was put back on, both live on fd4b0004 with empty bodies. CONFIRMED once; the strap's own wear
// detector decides, NOOP only reads its verdict. Events are matched by NUMBER (the payload's "event" field), so rows
// stored before they were named (`EVENT_9`/`EVENT_10`) count too.
//
// An off-wrist interval runs from an off event to the next on event. Repeated off events keep the earliest; an on event
// with no open interval is ignored. An interval still open at the end of the known data ends at `until` and is flagged
// open-ended (the strap may simply not have synced its on event yet). Without `until`, an open interval is dropped:
// nothing is claimed past what is known.

public enum WristWear {
    public static let version = "wrist-events-v1"
    public static let offEvent = 10
    public static let onEvent = 9

    public struct OffInterval: Equatable, Sendable {
        public let start: Int
        public let end: Int
        /// No on event yet: ends where the known data ends.
        public let openEnded: Bool
        public var seconds: Int { max(0, end - start) }
    }

    /// The event number a stored event carries, if any.
    public static func number(_ e: WhoopEvent) -> Int? {
        switch e.payload["event"] {
        case .int(let n)?: return n
        case .double(let d)? where d == d.rounded(): return Int(d)
        default: return nil
        }
    }

    /// Off-wrist intervals from stored events (any order, any kinds; only 9/10 are read).
    public static func offIntervals(_ events: [WhoopEvent], until: Int?) -> [OffInterval] {
        offIntervals(events.compactMap { e in number(e).map { (ts: e.ts, number: $0) } }, until: until)
    }

    public static func offIntervals(_ events: [(ts: Int, number: Int)], until: Int?) -> [OffInterval] {
        var out: [OffInterval] = []
        var openSince: Int?
        for e in events.filter({ $0.number == offEvent || $0.number == onEvent })
            .sorted(by: { $0.ts != $1.ts ? $0.ts < $1.ts : $0.number > $1.number }) {   // same second: off before on
            if e.number == offEvent {
                if openSince == nil { openSince = e.ts }
            } else if let s = openSince, e.ts > s {   // an on event in the off event's own second closes nothing
                out.append(OffInterval(start: s, end: e.ts, openEnded: false))
                openSince = nil
            }
        }
        if let s = openSince, let u = until, u > s { out.append(OffInterval(start: s, end: u, openEnded: true)) }
        return out
    }

    /// Seconds of `intervals` inside [from, to), overlaps counted once.
    public static func seconds(_ intervals: [OffInterval], from: Int, to: Int) -> Int {
        let clipped = intervals.compactMap { iv -> (Int, Int)? in
            let a = max(iv.start, from), b = min(iv.end, to)
            return b > a ? (a, b) : nil
        }.sorted { $0.0 < $1.0 }
        var total = 0, cursor = Int.min
        for (a, b) in clipped {
            let s = max(a, cursor)
            if b > s { total += b - s }
            cursor = max(cursor, b)
        }
        return total
    }

    /// True when `ts` lies inside an interval.
    public static func contains(_ intervals: [OffInterval], _ ts: Int) -> Bool {
        intervals.contains { ts >= $0.start && ts < $0.end }
    }
}
