import Foundation

// DayCoverage.swift — how much of a day has recorded (supported) heart rate, for captions only. It never changes
// scoring. The relevant span is the day's real length (23/25 h on DST days) clipped to now: future time is never
// missing. Supported intervals are clipped and unioned to that span. Missing time splits into recording gaps (inside
// data the store already has) and the trailing stretch still awaiting a sync. A gap only means no heart rate was
// stored; it does not prove the strap was off.

public struct DayCoverage: Equatable, Sendable {
    public struct Gap: Equatable, Sendable { public let start: Int; public let end: Int; public var seconds: Int { end - start } }

    public let dayStart: Int
    public let dayEnd: Int
    /// min(dayEnd, now): the end of the time that has actually passed.
    public let elapsedEnd: Int
    public let isToday: Bool
    public let isFuture: Bool
    public let recordedSeconds: Int
    /// Newest recorded second in the span; nil = nothing recorded.
    public let dataThrough: Int?
    /// Recording gaps ≥ `minGapSeconds` that lie within synced data (leading, internal, and after the last sample up to
    /// what the store already holds).
    public let gaps: [Gap]
    /// Seconds after the last stored data that are still awaiting a sync (today, or a day that just ended).
    public let awaitingSyncSeconds: Int
    /// The day has an imported summary but no raw heart rate.
    public let importedSummaryOnly: Bool

    public var elapsedSeconds: Int { max(0, elapsedEnd - dayStart) }
    public var daySeconds: Int { dayEnd - dayStart }
    public var gapSeconds: Int { gaps.reduce(0) { $0 + $1.seconds } }

    public static let minGapSeconds = 10 * 60
    /// Normal sync delay: the strap syncs every ~15 min, so up to this much unsynced time is not worth mentioning.
    public static let syncGraceSeconds = 30 * 60
    /// Longer than this without a sync is called out (not as missing data).
    public static let staleSyncSeconds = 2 * 3600

    /// - Parameters:
    ///   - intervals: supported HR intervals (any order, may overlap or extend past the day).
    ///   - syncedThrough: newest HR timestamp the store holds overall (from any day); nil = unknown.
    public static func compute(dayStart: Int, dayEnd: Int, now: Int, intervals: [(start: Int, end: Int)],
                               syncedThrough: Int?, hasImportedSummary: Bool = false) -> DayCoverage {
        let isFuture = now < dayStart
        let elapsedEnd = max(dayStart, min(dayEnd, now))
        let isToday = now >= dayStart && now < dayEnd
        // Clip, sort, union.
        let clipped = intervals.compactMap { iv -> (Int, Int)? in
            let a = max(iv.start, dayStart), b = min(iv.end, elapsedEnd)
            return b > a ? (a, b) : nil
        }.sorted { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for iv in clipped {
            if let last = merged.last, iv.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, iv.1) } else { merged.append(iv) }
        }
        let recorded = merged.reduce(0) { $0 + ($1.1 - $1.0) }
        let through = merged.last?.1
        // Holes between dayStart and the last data are recording gaps.
        var gaps: [Gap] = []
        var cursor = dayStart
        for iv in merged {
            if iv.0 - cursor >= minGapSeconds { gaps.append(Gap(start: cursor, end: iv.0)) }
            cursor = iv.1
        }
        // After the last data: what the store already covers is a gap; the rest awaits a sync.
        let trailingStart = through ?? dayStart
        let syncedEdge = min(elapsedEnd, max(trailingStart, syncedThrough ?? (isToday ? trailingStart : elapsedEnd)))
        if syncedEdge - trailingStart >= minGapSeconds { gaps.append(Gap(start: trailingStart, end: syncedEdge)) }
        let awaiting = max(0, elapsedEnd - syncedEdge)
        return DayCoverage(dayStart: dayStart, dayEnd: dayEnd, elapsedEnd: elapsedEnd, isToday: isToday, isFuture: isFuture,
                           recordedSeconds: recorded, dataThrough: through, gaps: gaps, awaitingSyncSeconds: awaiting,
                           importedSummaryOnly: merged.isEmpty && hasImportedSummary)
    }

    /// Worth a warning: real missing elapsed time (not the normal sync delay).
    public var warrantsWarning: Bool {
        guard !isFuture, elapsedSeconds > 0, !importedSummaryOnly else { return false }
        let meaningfulGap = gapSeconds >= 3600 && Double(gapSeconds) >= 0.1 * Double(elapsedSeconds)
        return meaningfulGap || awaitingSyncSeconds > Self.staleSyncSeconds
    }

    /// Short headline: neutral wording.
    public func caption(duration: (Int) -> String = DayCoverage.duration) -> String {
        if isFuture { return "This day hasn't started yet." }
        if importedSummaryOnly { return "Imported summary only — no raw heart rate stored." }
        if recordedSeconds == 0 { return isToday ? "No heart rate recorded yet today." : "No heart rate recorded for this day." }
        if isToday { return "\(duration(recordedSeconds)) recorded so far." }
        return "\(duration(recordedSeconds)) recorded of \(duration(daySeconds))."
    }

    /// Secondary details: data-through time, gaps, sync lag. Never says the strap was off.
    public func details(clock: (Int) -> String, duration: (Int) -> String = DayCoverage.duration) -> [String] {
        guard !isFuture, !importedSummaryOnly else { return [] }
        var out: [String] = []
        if let t = dataThrough, awaitingSyncSeconds > 0 || !isToday && t < elapsedEnd { out.append("Data through \(clock(t)).") }
        if !gaps.isEmpty {
            out.append("\(gaps.count) stretch\(gaps.count == 1 ? "" : "es") without heart rate, \(duration(gapSeconds)) in total.")
        }
        if awaitingSyncSeconds > Self.syncGraceSeconds {
            out.append("\(duration(awaitingSyncSeconds)) not synced yet\(awaitingSyncSeconds > Self.staleSyncSeconds ? " — check the strap connection" : "").")
        }
        return out
    }

    /// "7 h 42 min", "24 h", "45 min".
    public static func duration(_ s: Int) -> String {
        let m = (s + 30) / 60, h = m / 60, mm = m % 60
        if h == 0 { return "\(mm) min" }
        return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
    }
}
