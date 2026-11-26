import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #83: walking/running time shown with synced coverage; activity only over synced seconds; partial = lower bound.
final class ActivityCoverageTests: XCTestCase {
    let d0 = 1_793_592_000
    let day = 86_400

    private func s(_ dt: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: d0 + dt, counter: c, activity: a) }
    private func known(_ ranges: Range<Int>...) -> [Range<Int>] {
        StepCounterSample.knownRuns(ranges.flatMap { r in (r.lowerBound..<r.upperBound).map { d0 + $0 } })
    }
    private func cov(_ rows: [StepCounterSample], len: Int? = nil, until: Int, known k: [Range<Int>], now: Int? = nil) -> ActivityCoverage {
        let end = d0 + (len ?? day)
        let w = StepCounterSample.window(rows, from: d0, to: end, until: d0 + until, known: k)
        return ActivityCoverage.compute(window: w, dayStart: d0, dayEnd: end, now: now.map { d0 + $0 } ?? end + day)
    }

    func testFullySyncedPastDayIsExact() {
        let rows = [s(-60, 500, 0), s(3600, 500, 1), s(3600 + 1200, 2_000, 2), s(3600 + 1800, 3_000, 0)]
        let c = cov(rows, until: day + 60, known: known(-60..<(day + 60)))
        XCTAssertEqual(c.walkingSeconds, 1200)
        XCTAssertEqual(c.runningSeconds, 600)
        XCTAssertEqual(c.syncedSeconds, day)
        XCTAssertEqual(c.otherSeconds, day - 1800)
        XCTAssertFalse(c.isLowerBound)
        XCTAssertEqual(c.value(), "30 min")
        XCTAssertEqual(c.caption(), "Over 24 h synced of 24 h")
        XCTAssertEqual(c.details(), ["Walking 20 min · Running 10 min", "Not walking or running: 23 h 30 min."])
    }

    func testEmptyDayHasNoSyncedTimeAndNoBreakdown() {
        // A row exists only from yesterday; nothing synced in the day (the repository returns no tile then, but the
        // model must still never report activity it did not see).
        let c = cov([s(-600, 10, 1)], until: -500, known: known(-600..<(-500)))
        XCTAssertEqual(c.syncedSeconds, 0)
        XCTAssertEqual(c.activeSeconds, 0)
        XCTAssertEqual(c.awaitingSyncSeconds, day)
        XCTAssertTrue(c.isLowerBound)
        XCTAssertEqual(c.caption(), "No synced strap data for this day.")
        XCTAssertEqual(c.details(), [])
    }

    func testMissingFirstReferenceCountsOnlyFromTheFirstSyncedSecond() {
        // Nothing synced before 06:00; walking from 06:00 to 06:10.
        let rows = [s(-7200, 9_000, 1), s(6 * 3600, 9_100, 1), s(6 * 3600 + 600, 9_900, 0)]
        let c = cov(rows, until: day, known: known((6 * 3600)..<day))
        XCTAssertEqual(c.walkingSeconds, 600, "yesterday's walking code is not carried across the unsynced morning")
        XCTAssertEqual(c.gapSeconds, 6 * 3600)
        XCTAssertTrue(c.isLowerBound)
        XCTAssertEqual(c.value(), "≥ 10 min")
        XCTAssertEqual(c.details(), ["Walking 10 min", "Not walking or running: 17 h 50 min.",
                                     "No synced data for 6 h; activity there is unknown.",
                                     "Totals are at least these: unsynced time is not counted."])
    }

    func testMiddayGapIsUnknownNotStill() {
        // Running 12:00–13:00; 12:20–12:50 never synced.
        let t = 12 * 3600
        let rows = [s(-60, 0, 0), s(t, 0, 2), s(t + 3600, 8_000, 0)]
        let c = cov(rows, until: day + 60, known: known(-60..<(t + 1200), (t + 3000)..<(day + 60)))
        XCTAssertEqual(c.runningSeconds, 1200 + 600)
        XCTAssertEqual(c.gapSeconds, 1800)
        XCTAssertEqual(c.syncedSeconds + c.gapSeconds, day)
        XCTAssertEqual(c.value(), "≥ 30 min")
    }

    func testResetDoesNotChangeActivityTime() {
        // Counter drops at 07:00 (alarm-linked reset, S01); walking 07:00–07:05 continues across it.
        let rows = [s(-60, 9_000, 0), s(7 * 3600, 3, 1), s(7 * 3600 + 300, 500, 0)]
        let k = known(-60..<(day + 60))
        let w = StepCounterSample.window(rows, from: d0, to: d0 + day, until: d0 + day + 60, known: k)
        XCTAssertEqual(w.resets, 1)
        let c = ActivityCoverage.compute(window: w, dayStart: d0, dayEnd: d0 + day, now: d0 + 2 * day)
        XCTAssertEqual(c.walkingSeconds, 300)
        XCTAssertFalse(c.isLowerBound, "activity time is complete; only the step count is affected by a reset")
    }

    func testDSTDayUsesItsRealLength() {
        for len in [23 * 3600, 25 * 3600] {
            let rows = [s(-60, 0, 0), s(len - 3600, 0, 1), s(len - 1800, 3_000, 0)]
            let c = cov(rows, len: len, until: len + 60, known: known(-60..<(len + 60)))
            XCTAssertEqual(c.daySeconds, len)
            XCTAssertEqual(c.syncedSeconds, len)
            XCTAssertEqual(c.walkingSeconds, 1800)
            XCTAssertFalse(c.isLowerBound)
            XCTAssertEqual(c.caption(), "Over \(len / 3600) h synced of \(len / 3600) h")
        }
    }

    func testTodayClipsToNowAndReportsSyncLag() {
        // 09:00 now; synced through 08:40; walking 08:30 onwards.
        let rows = [s(-60, 0, 0), s(8 * 3600 + 1800, 0, 1)]
        let c = cov(rows, until: 8 * 3600 + 2400, known: known(-60..<(8 * 3600 + 2400)), now: 9 * 3600)
        XCTAssertTrue(c.isToday)
        XCTAssertEqual(c.elapsedSeconds, 9 * 3600)
        XCTAssertEqual(c.walkingSeconds, 600, "walking stops at the newest synced second")
        XCTAssertEqual(c.awaitingSyncSeconds, 1200)
        XCTAssertEqual(c.caption(), "Over 8 h 40 min synced of 9 h so far")
        XCTAssertFalse(c.isLowerBound, "a normal sync delay is not missing data")
        XCTAssertEqual(c.value(), "10 min")
        XCTAssertFalse(c.details().contains { $0.contains("not synced yet") })
        // Over 30 min behind: now the total is "at least" and the lag is said.
        let late = cov(rows, until: 8 * 3600 + 2400, known: known(-60..<(8 * 3600 + 2400)), now: 9 * 3600 + 1800)
        XCTAssertTrue(late.isLowerBound)
        XCTAssertEqual(late.value(), "≥ 10 min")
        XCTAssertTrue(late.details().contains("50 min not synced yet."))
    }
}
