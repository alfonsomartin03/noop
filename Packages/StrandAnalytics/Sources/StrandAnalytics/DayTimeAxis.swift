import Foundation

// One explicit time domain for a local day, shared by every display that plots that day against the clock (issue #26:
// the Overview heart-rate curve and its activation strip). Positions depend only on a timestamp and the day's real
// bounds (23–25 h across DST), never on sample index or on how much of the day has data, so equal timestamps land at
// equal x on every display and late syncs fill in without moving what is already drawn.

public struct DayTimeAxis: Equatable, Sendable {
    /// Local-day bounds [start, end) in Unix seconds.
    public let start: Int
    public let end: Int
    /// The clock the display is drawn at; time after it is "upcoming", never missing or calm.
    public let now: Int

    public init(start: Int, end: Int, now: Int) {
        self.start = start
        self.end = max(end, start + 1)
        self.now = now
    }

    public var length: Int { end - start }
    /// End of elapsed time within the day: `start` for a future day, `end` for a finished one.
    public var cutoff: Int { min(max(now, start), end) }
    public var hasUpcoming: Bool { cutoff < end }

    /// Horizontal position 0…1 of a timestamp (clamped to the day).
    public func fraction(_ ts: Int) -> Double {
        Double(min(max(ts, start), end) - start) / Double(length)
    }

    /// The timestamp at a horizontal position 0…1.
    public func timestamp(atFraction f: Double) -> Int {
        start + Int((min(max(f, 0), 1) * Double(length)).rounded())
    }

    /// Local wall-clock ticks (default midnight, 6, 12, 18 and the next midnight) at their true instants, so a 23/25-hour
    /// day keeps its ticks under the right bins. Hours that don't exist that day (spring-forward) are skipped.
    public func ticks(hours: [Int] = [0, 6, 12, 18], zone: TimeZone) -> [Int] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let day = Date(timeIntervalSince1970: TimeInterval(start))
        var out: [Int] = []
        for h in hours {
            guard let d = cal.date(bySettingHour: h, minute: 0, second: 0, of: day),
                  cal.component(.hour, from: d) == h else { continue }
            let ts = Int(d.timeIntervalSince1970)
            if ts >= start && ts < end { out.append(ts) }
        }
        out.append(end)
        return out
    }

    // MARK: Heart rate

    public struct Point: Equatable, Sendable {
        public let ts: Int
        public let bpm: Double
        public init(ts: Int, bpm: Double) { self.ts = ts; self.bpm = bpm }
    }

    /// Readings further apart than this break the curve: a gap is drawn as a gap, not interpolated.
    public static let hrGapSeconds = 300
    /// Drawing resolution: readings are averaged per bucket (≤ 720 points per day at 1 Hz input).
    public static let hrBucketSeconds = 120

    /// Heart-rate runs on this day's time domain: in-day, elapsed readings only, sorted (input order is irrelevant),
    /// duplicate seconds collapsed, split wherever consecutive readings are more than `maxGap` apart, then averaged per
    /// `bucket` within each run (each point sits at the mean time of its readings).
    public func hrRuns(_ samples: [(ts: Int, bpm: Int)], bucket: Int = hrBucketSeconds, maxGap: Int = hrGapSeconds) -> [[Point]] {
        let sorted = samples.filter { $0.ts >= start && $0.ts < cutoff && $0.bpm >= 30 && $0.bpm <= 230 }
            .sorted { $0.ts < $1.ts }
        var runs: [[Point]] = []
        var run: [Point] = []
        var bucketKey: Int?
        var sumTs = 0, sumBpm = 0, n = 0, prevTs: Int?
        func flushBucket() {
            if n > 0 { run.append(Point(ts: sumTs / n, bpm: Double(sumBpm) / Double(n))) }
            sumTs = 0; sumBpm = 0; n = 0
        }
        for s in sorted {
            if let p = prevTs, s.ts == p { continue }
            if let p = prevTs, s.ts - p > maxGap {
                flushBucket()
                if !run.isEmpty { runs.append(run); run = [] }
                bucketKey = nil
            }
            let key = (s.ts - start) / max(bucket, 1)
            if key != bucketKey { flushBucket(); bucketKey = key }
            sumTs += s.ts; sumBpm += s.bpm; n += 1
            prevTs = s.ts
        }
        flushBucket()
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    // MARK: Activation

    public enum SpanKind: Equatable, Hashable, Sendable {
        /// A classified bin (asleep, workout, low/moderate/high activation).
        case observed(HRActivation.Level)
        /// Elapsed time without enough readings, sleep or a workout.
        case missing
        /// Time that hasn't happened yet.
        case upcoming
    }

    public struct Span: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let kind: SpanKind
        public init(start: Int, end: Int, kind: SpanKind) { self.start = start; self.end = end; self.kind = kind }
    }

    /// The whole day as contiguous spans: activation bins at their own timestamps (clipped to elapsed time), elapsed
    /// time without a classified bin as `.missing`, and time after the cutoff as `.upcoming`. Adjacent equal kinds merge.
    /// Bins are never stretched: a bin only covers its own [start, end).
    public func activationSpans(_ bins: [HRActivation.Bin]) -> [Span] {
        var raw: [Span] = []
        var cursor = start
        for b in bins.sorted(by: { $0.start < $1.start }) {
            let s = max(b.start, cursor), e = min(b.end, cutoff)
            guard e > s else { continue }
            if s > cursor { raw.append(Span(start: cursor, end: s, kind: .missing)) }
            raw.append(Span(start: s, end: e, kind: b.level == .noData ? .missing : .observed(b.level)))
            cursor = e
        }
        if cursor < cutoff { raw.append(Span(start: cursor, end: cutoff, kind: .missing)) }
        if cutoff < end { raw.append(Span(start: cutoff, end: end, kind: .upcoming)) }
        var merged: [Span] = []
        for s in raw {
            if let last = merged.last, last.kind == s.kind, last.end == s.start {
                merged[merged.count - 1] = Span(start: last.start, end: s.end, kind: s.kind)
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// The span containing `ts`, if any.
    public static func span(at ts: Int, in spans: [Span]) -> Span? {
        spans.first { $0.start <= ts && ts < $0.end } ?? spans.last.flatMap { ts == $0.end ? $0 : nil }
    }

    /// The drawn heart-rate point nearest `ts`, if one lies within `within` seconds.
    public static func nearest(_ ts: Int, in runs: [[Point]], within: Int = hrGapSeconds / 2) -> Point? {
        var best: Point?
        for run in runs {
            guard let f = run.first, let l = run.last, ts >= f.ts - within, ts <= l.ts + within else { continue }
            for p in run where abs(p.ts - ts) <= within {
                if best == nil || abs(p.ts - ts) < abs(best!.ts - ts) { best = p }
            }
        }
        return best
    }
}
