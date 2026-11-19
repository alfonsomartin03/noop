import XCTest
@testable import WhoopProtocol

/// #46 ordinary-use counters: synthetic times only.
final class OpsCountersTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func t(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
    }

    func testCountsCommandsAndEventsPerLocalDay() {
        var b = OpsCounterBook(calendar: cal, app: "0.1.0 (1)", now: t(19, 8))
        b.command("Get Clock", at: t(19, 8))
        b.command("Get Clock", at: t(19, 9))
        b.count(.pullStarted, at: t(19, 9))
        b.count(.historyFrames, by: 120, at: t(19, 9))
        b.count(.rxBytes, by: 0, at: t(19, 9))            // zero adds nothing
        b.firmware("50.43.1.0", at: t(19, 9))
        b.firmware("50.43.1.0", at: t(19, 10))
        let days = b.snapshot(at: t(19, 10))
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].day, "2026-11-19")
        XCTAssertEqual(days[0].timeZone, "America/New_York")
        XCTAssertEqual(days[0].commands, ["Get Clock": 2])
        XCTAssertEqual(days[0].counts, ["pullStarted": 1, "historyFrames": 120])
        XCTAssertEqual(days[0].firmware, ["50.43.1.0"])
        XCTAssertEqual(days[0].app, "0.1.0 (1)")
    }

    func testConnectedTimeSplitsAtMidnightAndFinishedDaysAreHandedOutOnce() {
        var b = OpsCounterBook(calendar: cal, app: "a", now: t(18, 23))
        b.linkUp(at: t(18, 23))
        b.command("Get Clock", at: t(19, 0, 30))            // first event after midnight closes 23:00–00:00 into the 18th
        b.linkDown(at: t(19, 1))
        let days = b.snapshot(at: t(19, 2))
        XCTAssertEqual(days.map(\.day), ["2026-11-18", "2026-11-19"])
        XCTAssertEqual(days[0].connectedSeconds, 3600, accuracy: 0.001)
        XCTAssertEqual(days[1].connectedSeconds, 3600, accuracy: 0.001)
        XCTAssertEqual(days[0].counts["connect"], 1)
        XCTAssertEqual(days[1].counts["disconnect"], 1)
        XCTAssertEqual(days[1].commands["Get Clock"], 1)
        // Next snapshot: only the current day, with no time added while disconnected.
        let again = b.snapshot(at: t(19, 5))
        XCTAssertEqual(again.map(\.day), ["2026-11-19"])
        XCTAssertEqual(again[0].connectedSeconds, 3600, accuracy: 0.001)
    }

    func testOpenLinkAccruesAcrossSeveralMidnightsAndDST() {
        // 2026-11-01 is the fall-back day in New York (25 h).
        var b = OpsCounterBook(calendar: cal, app: "a", now: t(31, 12, month: 10))
        b.linkUp(at: t(31, 12, month: 10))
        let days = b.snapshot(at: t(2, 6))
        XCTAssertEqual(days.map(\.day), ["2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(days.map(\.connectedSeconds), [12 * 3600, 25 * 3600, 6 * 3600])
        XCTAssertTrue(b.isConnected)
    }

    func testDisconnectCountedOnceAndRepeatedLinkUpKeepsTheStart() {
        var b = OpsCounterBook(calendar: cal, app: "a", now: t(19, 8))
        b.linkUp(at: t(19, 8))
        b.linkUp(at: t(19, 8, 30))                          // duplicate callback
        b.linkDown(at: t(19, 9))
        b.linkDown(at: t(19, 9, 1))                         // Bluetooth off after didDisconnect
        let d = b.snapshot(at: t(19, 10))[0]
        XCTAssertEqual(d.counts["connect"], 2)
        XCTAssertEqual(d.counts["disconnect"], 1)
        XCTAssertEqual(d.connectedSeconds, 3600, accuracy: 0.001)
    }

    func testResumeOnlyForTheSameDayAndRoundTrip() throws {
        var stored = OpsDay(day: "2026-11-19", timeZone: "America/New_York", app: "a")
        stored.commands = ["Get Clock": 5]
        stored.connectedSeconds = 100
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(OpsDay.self, from: data)
        XCTAssertEqual(decoded, stored)

        var same = OpsCounterBook(calendar: cal, app: "b", resume: decoded, now: t(19, 12))
        same.command("Get Clock", at: t(19, 12))
        XCTAssertEqual(same.snapshot(at: t(19, 12))[0].commands["Get Clock"], 6)

        var next = OpsCounterBook(calendar: cal, app: "b", resume: decoded, now: t(20, 0, 1))
        next.command("Get Clock", at: t(20, 0, 1))
        let d = next.snapshot(at: t(20, 0, 1))
        XCTAssertEqual(d.map(\.day), ["2026-11-20"])
        XCTAssertEqual(d[0].commands["Get Clock"], 1)
    }

    func testBackwardClockStepReopensTheEarlierDayInsteadOfDuplicatingIt() {
        var b = OpsCounterBook(calendar: cal, app: "a", now: t(18, 23))
        b.command("Get Clock", at: t(18, 23, 59))
        b.command("Get Clock", at: t(19, 0, 1))
        b.command("Get Clock", at: t(18, 23, 59))           // clock stepped back before the snapshot
        let days = b.snapshot(at: t(19, 0, 2))
        XCTAssertEqual(days.map(\.day), ["2026-11-18", "2026-11-19"])
        XCTAssertEqual(days[0].commands["Get Clock"], 2)
        XCTAssertEqual(days[1].commands["Get Clock"], 1)
    }
}
