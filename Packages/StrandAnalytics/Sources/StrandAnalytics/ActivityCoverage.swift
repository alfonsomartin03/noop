import Foundation
import WhoopProtocol

// ActivityCoverage.swift — a day's recorded walking/running time from the 5.0 strap's activity code (payload 55), shown
// next to how much of the day was synced (#83). Display only; never read by scoring. Activity is counted only across
// synced seconds (`StepCounterSample.window` with `known`), so time with no synced record is unknown, not still. The day
// is its real length (23/25 h on DST days) clipped to now, like `DayCoverage`: future time is never missing. Missing
// elapsed time splits into gaps inside synced data and the stretch after the newest synced second awaiting a sync.
// Any gap, or a sync delay past the normal one, makes the walking/running totals lower bounds.

public struct ActivityCoverage: Equatable, Sendable {
    public let daySeconds: Int
    /// Seconds of the day that have passed (min(dayEnd, now) − dayStart).
    public let elapsedSeconds: Int
    /// Elapsed seconds holding a synced record.
    public let syncedSeconds: Int
    /// Elapsed seconds inside synced data with no record (interior and leading gaps).
    public let gapSeconds: Int
    /// Elapsed seconds after the newest synced second, still awaiting a sync.
    public let awaitingSyncSeconds: Int
    /// Activity code 1 (walking; SUPPORTED) seconds, synced only.
    public let walkingSeconds: Int
    /// Activity code 2 (running; CONFIRMED) seconds, synced only.
    public let runningSeconds: Int

    public var activeSeconds: Int { walkingSeconds + runningSeconds }
    /// Synced seconds with any other code (0 = still is only SUPPORTED, so not called "still").
    public var otherSeconds: Int { max(0, syncedSeconds - activeSeconds) }
    public var isToday: Bool { elapsedSeconds < daySeconds }
    /// True when elapsed time has no synced record beyond the normal sync delay (`DayCoverage.syncGraceSeconds`, the
    /// same rule as the Overview caption): walking/running totals are then "at least". Within the delay the caption's
    /// "so far" already says the day is synced up to now, and a "≥" on every fresh reading would only be noise.
    public var isLowerBound: Bool { gapSeconds > 0 || awaitingSyncSeconds > DayCoverage.syncGraceSeconds }

    /// - Parameters:
    ///   - window: `StepCounterSample.window` over [dayStart, dayEnd) with `until` and `known` given.
    ///   - now: wall-clock now; clips the day so future time is never missing.
    public static func compute(window w: StepCounterSample.Window, dayStart: Int, dayEnd: Int, now: Int) -> ActivityCoverage {
        let day = max(0, dayEnd - dayStart)
        let elapsed = max(0, min(dayEnd, now) - dayStart)
        // The window's span ends at the newest synced second; the strap clock can run a little ahead of the Mac's.
        let span = min(w.spanSeconds, elapsed)
        let synced = min(w.syncedSeconds, span)
        // Clip activity to synced time so walking + running ≤ synced even with a span clipped to now.
        let walk = min(w.activityOneSeconds, synced)
        let run = min(w.activityTwoSeconds, max(0, synced - walk))
        return ActivityCoverage(daySeconds: day, elapsedSeconds: elapsed, syncedSeconds: synced, gapSeconds: span - synced,
                                awaitingSyncSeconds: elapsed - span, walkingSeconds: walk, runningSeconds: run)
    }

    /// Main figure: walking + running, prefixed "≥ " when it is a lower bound.
    public func value(duration: (Int) -> String = DayCoverage.duration) -> String {
        (isLowerBound ? "≥ " : "") + duration(activeSeconds)
    }

    /// One line: synced time against the elapsed day ("so far" today).
    public func caption(duration: (Int) -> String = DayCoverage.duration) -> String {
        if elapsedSeconds == 0 { return "This day hasn't started yet." }
        if syncedSeconds == 0 { return "No synced strap data for this day." }
        return "Over \(duration(syncedSeconds)) synced of \(duration(elapsedSeconds))" + (isToday ? " so far" : "")
    }

    /// Breakdown lines: walking, running, other synced time, and what is missing. Minutes under one are left out of the
    /// walking/running lines; missing time is always stated when ≥ 1 min.
    public func details(duration: (Int) -> String = DayCoverage.duration) -> [String] {
        guard elapsedSeconds > 0, syncedSeconds > 0 else { return [] }
        var out: [String] = []
        var motion: [String] = []
        if walkingSeconds >= 60 { motion.append("Walking \(duration(walkingSeconds))") }
        if runningSeconds >= 60 { motion.append("Running \(duration(runningSeconds))") }
        out.append(motion.isEmpty ? "No walking or running recorded." : motion.joined(separator: " · "))
        if otherSeconds >= 60 { out.append("Not walking or running: \(duration(otherSeconds)).") }
        if gapSeconds >= 60 { out.append("No synced data for \(duration(gapSeconds)); activity there is unknown.") }
        if awaitingSyncSeconds > DayCoverage.syncGraceSeconds { out.append("\(duration(awaitingSyncSeconds)) not synced yet.") }
        if isLowerBound { out.append("Totals are at least these: unsynced time is not counted.") }
        return out
    }
}
