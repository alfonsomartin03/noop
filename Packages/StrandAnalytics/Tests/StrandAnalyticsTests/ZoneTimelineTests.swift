import XCTest
@testable import StrandAnalytics

final class ZoneTimelineTests: XCTestCase {
    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0, utc: Bool = true) -> Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return Int(c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!.timeIntervalSince1970)
    }

    func testPastNightKeepsItsOwnZoneAfterTravel() {
        let tl = ZoneTimeline(entries: [])
        tl.record(TimeZone(identifier: "America/New_York")!, at: 0)
        let flight = ts(2026, 10, 20, 12)
        tl.record(TimeZone(identifier: "Europe/Madrid")!, at: flight)
        // 03:30 UTC Oct 18 = 23:30 Oct 17 in New York (before the trip), not 05:30 Oct 18 in Madrid.
        let t = ts(2026, 10, 18, 3, 30)
        XCTAssertEqual(tl.hourMinute(t).hour, 23)
        XCTAssertEqual(tl.dayString(t), "2026-10-17")
        // After the flight the same UTC clock reads in Madrid.
        let t2 = ts(2026, 10, 22, 6, 30)
        XCTAssertEqual(tl.hourMinute(t2).hour, 8)
        XCTAssertEqual(tl.dayString(t2), "2026-10-22")
    }

    func testRecordIgnoresUnchangedZoneAndNeverRewritesPast() {
        let tl = ZoneTimeline(entries: [])
        let ny = TimeZone(identifier: "America/New_York")!
        tl.record(ny, at: 100); tl.record(ny, at: 200)
        XCTAssertEqual(tl.snapshot.count, 1)
        tl.record(TimeZone(identifier: "Europe/Madrid")!, at: 500)
        tl.record(TimeZone(identifier: "Asia/Tokyo")!, at: 300)   // earlier than the newest entry: clamped forward
        XCTAssertEqual(tl.snapshot.last!.since, 500)
    }

    func testDayRangeHandlesDSTLength() {
        let tl = ZoneTimeline(entries: [])
        tl.record(TimeZone(identifier: "America/New_York")!, at: 0)
        let spring = tl.dayRange("2026-03-08")!   // 23 h day
        XCTAssertEqual(spring.to - spring.from, 23 * 3600)
        let fall = tl.dayRange("2026-11-01")!     // 25 h day
        XCTAssertEqual(fall.to - fall.from, 25 * 3600)
        XCTAssertEqual(tl.dayString(spring.from), "2026-03-08")
        XCTAssertEqual(tl.dayString(spring.to - 1), "2026-03-08")
        XCTAssertEqual(tl.dayString(spring.to), "2026-03-09")
    }

    func testSpanZoneUsesMidpoint() {
        let tl = ZoneTimeline(entries: [ZoneEntry(since: 0, id: "America/New_York"), ZoneEntry(since: 1000, id: "Europe/Madrid")])
        XCTAssertEqual(tl.zone(forSpan: 900, 1200).identifier, "Europe/Madrid")
        XCTAssertEqual(tl.zone(forSpan: 100, 500).identifier, "America/New_York")
    }
}
