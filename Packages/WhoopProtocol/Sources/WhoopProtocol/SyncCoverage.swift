import Foundation

/// Closed time interval in strap seconds.
public struct SyncSpan: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public init(_ start: Int, _ end: Int) { self.start = min(start, end); self.end = max(start, end) }
    public var duration: Int { end - start }
}

/// Set of covered intervals; merges overlaps and neighbours closer than `joinGap`.
public struct IntervalSet: Equatable, Sendable {
    public private(set) var spans: [SyncSpan] = []
    public let joinGap: Int
    public init(joinGap: Int = 1) { self.joinGap = joinGap }

    public mutating func insert(_ s: SyncSpan) {
        var merged = s
        var out: [SyncSpan] = []
        for x in spans {
            if x.end + joinGap < merged.start || merged.end + joinGap < x.start { out.append(x) }
            else { merged = SyncSpan(min(x.start, merged.start), max(x.end, merged.end)) }
        }
        out.append(merged)
        spans = out.sorted { $0.start < $1.start }
    }

    /// Seconds of `window` covered by the set.
    public func covered(within window: SyncSpan) -> Int {
        spans.reduce(0) { acc, s in
            let lo = max(s.start, window.start), hi = min(s.end, window.end)
            return acc + max(0, hi - lo)
        }
    }

    /// Parts of `window` not covered, longer than `minGap`.
    public func gaps(within window: SyncSpan, minGap: Int) -> [SyncSpan] {
        var out: [SyncSpan] = []
        var cursor = window.start
        for s in spans where s.end > window.start && s.start < window.end {
            if s.start - cursor > minGap { out.append(SyncSpan(cursor, s.start)) }
            cursor = max(cursor, s.end)
        }
        if window.end - cursor > minGap { out.append(SyncSpan(cursor, window.end)) }
        return out
    }
}

/// Progress of one WHOOP 5.0 history pull, measured in strap time — not bytes, not records.
///
/// The strap serves its history in order, starting at its trim pointer (= `strapFrom`, the last record of
/// the previous acknowledged pull) and ending at the newest record it held when the session began
/// (`target`, fixed for the session so the goalposts never move). Because the stream is in order, a chunk
/// that has been durably saved accounts for everything before its newest record: either the records
/// arrived, or the strap held none for that stretch (off-wrist, not recording). The two are told apart
/// with `recordedCoverage`, which is built from the record timestamps themselves.
public struct SyncSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing, downloading, processing, complete
        case partial(String)    // ended early; saved data is kept, progress shows what was accounted for
        case failed(String)
    }

    /// Where the local database's contiguous history ended before this pull (nil = empty database).
    public let localFrom: Int?
    /// First second the strap will send this pull (its last-synced record).
    public let strapFrom: Int
    /// Newest record on the strap when the session started. Data newer than this waits for the next pull.
    public let target: Int
    public private(set) var phase: Phase = .preparing
    /// Newest record time in a chunk that is durably saved. Never moves backwards.
    public private(set) var savedFrontier: Int
    /// Seconds for which a record was actually received and saved.
    public private(set) var recordedCoverage = IntervalSet(joinGap: 1)
    public private(set) var savedRecords = 0
    public private(set) var duplicateRecords = 0

    public init(localFrom: Int?, strapFrom: Int, target: Int) {
        self.localFrom = localFrom
        self.strapFrom = strapFrom
        self.target = max(target, strapFrom)
        self.savedFrontier = strapFrom
    }

    /// History the database lacks but the strap no longer offers (already handed to another app or aged
    /// out). Never counted as downloaded.
    public var unavailable: SyncSpan? {
        guard let l = localFrom, l < strapFrom else { return nil }
        return SyncSpan(l, strapFrom)
    }

    public var required: SyncSpan { SyncSpan(strapFrom, target) }

    public mutating func begin() { if phase == .preparing { phase = .downloading } }

    /// A chunk's records were committed to the database (call only after the write succeeded).
    /// `newRows` = rows the store actually inserted; the rest were already stored (idempotent import).
    public mutating func chunkSaved(recordTimes: [Int], newRows: Int) {
        guard phase == .downloading || phase == .preparing else { return }
        phase = .downloading
        for t in recordTimes where t >= strapFrom - 1 { recordedCoverage.insert(SyncSpan(t, t + 1)) }
        savedRecords += newRows
        duplicateRecords += max(0, recordTimes.count - newRows)
        if let hi = recordTimes.max() { savedFrontier = max(savedFrontier, min(hi, target)) }
    }

    /// The strap sent HISTORY_COMPLETE and every chunk before it was saved.
    public mutating func downloadFinished() {
        guard phase == .downloading || phase == .preparing else { return }
        savedFrontier = max(savedFrontier, target)
        phase = .processing
    }

    public mutating func processingFinished() { if phase == .processing { phase = .complete } }
    public mutating func end(early reason: String) {
        switch phase {
        case .complete, .failed: return
        default: phase = savedRecords > 0 || savedFrontier > strapFrom ? .partial(reason) : .failed(reason)
        }
    }

    /// Seconds of the required span accounted for (received, or confirmed empty by the in-order stream).
    public var accountedSeconds: Int { max(0, min(savedFrontier, target) - strapFrom) }
    public var remainingSeconds: Int { max(0, target - strapFrom - accountedSeconds) }

    /// 0…1. Shows 100 % only once the strap confirmed completion; until then capped just below.
    public var fraction: Double {
        let total = target - strapFrom
        if phase == .processing || phase == .complete { return 1 }
        guard total > 0 else { return 0 }
        return min(0.99, Double(accountedSeconds) / Double(total))
    }

    /// Stretches inside the accounted span with no records at all (strap not recording). Informational.
    public func recordingGaps(minimum: Int = 300) -> [SyncSpan] {
        recordedCoverage.gaps(within: SyncSpan(strapFrom, min(savedFrontier, target)), minGap: minimum)
    }
}
