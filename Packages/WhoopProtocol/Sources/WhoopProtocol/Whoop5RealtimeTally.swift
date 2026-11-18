import Foundation

/// Evidence for the live R-R unit (#39): what NOOP's own realtime (type 40) packets carry during normal streaming.
/// E04 saw 42 packets at rest, all 32 bytes, none with intervals. Counting every packet across ordinary use shows whether
/// intervals ever appear (and when), without sending the strap anything new. A session ends at a strap-time gap of more
/// than `sessionGap` seconds (the stream stopped); the caller logs `summary` then and every `logEvery` packets.
public struct Whoop5RealtimeTally: Equatable, Sendable {
    public static let sessionGap: UInt32 = 10
    public static let logEvery = 300

    public private(set) var packets = 0
    public private(set) var withIntervals = 0
    public private(set) var truncated = 0
    public private(set) var words = 0
    public private(set) var maxCount = 0
    public private(set) var frameLengths: [Int: Int] = [:]
    public private(set) var firstSecond: UInt32?
    public private(set) var lastSecond: UInt32?

    public init() {}

    /// Whether `rt` starts a new session (more than `sessionGap` s after the last packet, or the clock went back).
    public func startsNewSession(_ rt: Whoop5Realtime) -> Bool {
        guard let last = lastSecond else { return false }
        return rt.timestamp > last &+ Self.sessionGap || rt.timestamp < last
    }

    public mutating func add(_ rt: Whoop5Realtime, frameLength: Int) {
        packets += 1
        if !rt.rr.isEmpty { withIntervals += 1; words += rt.rr.count; maxCount = max(maxCount, rt.rr.count) }
        if rt.rrTruncated { truncated += 1 }
        frameLengths[frameLength, default: 0] += 1
        if firstSecond == nil { firstSecond = rt.timestamp }
        lastSecond = rt.timestamp
    }

    /// One log line, aggregates only (no heart rate, no interval values).
    public var summary: String {
        let span = firstSecond.flatMap { f in lastSecond.map { Int($0) - Int(f) + 1 } } ?? 0
        let lengths = frameLengths.sorted { $0.key < $1.key }.map { "\($0.key) B×\($0.value)" }.joined(separator: ", ")
        return "Live R-R: \(packets) packet(s) over \(span) s; \(withIntervals) with intervals (\(words) word(s), max \(maxCount)/packet); "
            + "\(truncated) truncated; lengths \(lengths.isEmpty ? "-" : lengths)"
    }
}
