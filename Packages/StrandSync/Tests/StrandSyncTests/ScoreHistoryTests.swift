import XCTest
import WhoopStore
@testable import StrandSync

/// #80: browsing returned scores by week and month, through DST changes and time zones, with missing never 0.
final class ScoreHistoryTests: XCTestCase {
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; return c
    }
    private func s(_ day: String, _ values: [String: Double], rev: Int64 = 1, removed: Bool = false) -> DailySummary {
        DailySummary(day: day, revision: rev, changedAt: 0, values: values, coverage: [:], removed: removed)
    }

    func testWeekAcrossTheAutumnDSTChangeHasSevenDistinctDays() {
        // America/New_York falls back on Sunday 2026-11-01 (a 25-hour day).
        let w = ScoreHistory.week(containing: "2026-11-01", calendar: cal("America/New_York"))
        XCTAssertEqual(w, ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"])
    }

    func testWeekAcrossTheSpringDSTChangeHasSevenDistinctDays() {
        // America/New_York springs forward on Sunday 2026-03-08 (a 23-hour day).
        let w = ScoreHistory.week(containing: "2026-03-08", calendar: cal("America/New_York"))
        XCTAssertEqual(w, ["2026-03-02", "2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07", "2026-03-08"])
        XCTAssertEqual(ScoreHistory.shift("2026-03-07", by: 1, calendar: cal("America/New_York")), "2026-03-08")
        XCTAssertEqual(ScoreHistory.shift("2026-03-08", by: 1, calendar: cal("America/New_York")), "2026-03-09")
    }

    func testDaysAreLabelsAndDoNotMoveWithThePhonesZone() {
        // The same Mac day is the same week in Tokyo, London and Honolulu.
        for tz in ["Asia/Tokyo", "Europe/London", "Pacific/Honolulu", "America/New_York"] {
            XCTAssertEqual(ScoreHistory.week(containing: "2026-11-27", calendar: cal(tz)).first, "2026-11-23", tz)
            XCTAssertEqual(ScoreHistory.lastDays(3, through: "2026-11-01", calendar: cal(tz)),
                           ["2026-10-30", "2026-10-31", "2026-11-01"], tz)
        }
    }

    func testMonthsGroupNewestFirstAndDropRemovedDays() {
        let m = ScoreHistory.months([s("2026-10-31", [:]), s("2026-11-02", [:]), s("2026-11-01", [:]),
                                     s("2026-11-03", [:], removed: true)])
        XCTAssertEqual(m.map(\.month), ["2026-11", "2026-10"])
        XCTAssertEqual(m[0].days.map(\.day), ["2026-11-02", "2026-11-01"])
    }

    func testSeriesAndAverageNeverTreatMissingAsZero() {
        let days = ["2026-11-01", "2026-11-02", "2026-11-03"]
        let sums = [s("2026-11-01", ["recovery": 80]), s("2026-11-02", ["strain": 9])]   // 11-02 has no recovery, 11-03 nothing
        let series = ScoreHistory.series("recovery", days: days, in: sums)
        XCTAssertEqual(series, [80, nil, nil])
        XCTAssertEqual(ScoreHistory.average(series), ScoreHistory.Average(value: 80, daysWithValue: 1, daysAsked: 3))
        XCTAssertNil(ScoreHistory.average([nil, nil]))
    }

    func testSeriesUsesTheNewestRevisionOfADay() {
        let series = ScoreHistory.series("recovery", days: ["2026-11-01"],
                                         in: [s("2026-11-01", ["recovery": 50], rev: 2), s("2026-11-01", ["recovery": 70], rev: 9)])
        XCTAssertEqual(series, [70])
    }

    /// Cache size (#80 acceptance): a full year of summaries as the phone stores them.
    func testAYearOfCachedSummariesIsSmall() async throws {
        let store = try await WhoopStore.inMemory()
        let full: [String: Double] = ["recovery": 74.9, "strain": 11.23, "totalSleepMin": 452.5, "efficiency": 92.1,
                                      "deepMin": 97.2, "remMin": 129.4, "lightMin": 225.9, "disturbances": 11,
                                      "restingHr": 53, "avgHrv": 48.2, "respRateBpm": 15.7, "spo2Pct": 97.1,
                                      "skinTempDevC": -0.61, "exerciseCount": 1]
        let days = ScoreHistory.lastDays(365, through: "2026-11-27", calendar: cal("UTC"))
        try await store.cacheSummaries(days.enumerated().map { i, d in
            DailySummary(day: d, revision: Int64(i + 1), changedAt: 1_795_000_000, values: full,
                         coverage: ["recovery": 0.98, "strain": 0.97, "totalSleepMin": 1], removed: false)
        })
        // What the cache stores per day: the summary's JSON, the day key and two integers.
        let cached = try await store.cachedSummaries()
        XCTAssertEqual(cached.count, 365)
        let bytes = try cached.reduce(0) { $0 + (try JSONEncoder().encode($1)).count + $1.day.count + 16 }
        print("[cache] 365 days ≈ \(bytes) bytes of rows")
        XCTAssertLessThan(bytes, 400_000, "a year of scores stays well under half a megabyte")
    }
}
