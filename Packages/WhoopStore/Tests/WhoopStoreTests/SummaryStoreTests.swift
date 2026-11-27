import XCTest
@testable import WhoopStore

/// Scores sent back to the phone (#79): per-day revisions on the Mac, newest-wins cache on the phone.
final class SummaryStoreTests: XCTestCase {
    private let dev = "my-whoop-noop"

    private func day(_ d: String, recovery: Double?, strain: Double? = 10, rhr: Int? = 55) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 420, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: nil, recovery: recovery, strain: strain,
                    exerciseCount: nil)
    }

    func testFirstCallSendsEveryDayWithMissingValuesLeftOut() async throws {
        let mac = try await WhoopStore.inMemory()
        _ = try await mac.upsertDailyMetrics([day("2026-11-25", recovery: 70), day("2026-11-26", recovery: nil)], deviceId: dev)
        let s = try await mac.dailySummaries(deviceId: dev, since: 0, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(s.map(\.day), ["2026-11-25", "2026-11-26"])
        XCTAssertEqual(s[0].values["recovery"], 70)
        XCTAssertNil(s[1].values["recovery"], "missing is absent, never 0")
        XCTAssertNil(s[0].values["efficiency"])
        XCTAssertEqual(s[0].changedAt, 100)
        XCTAssertLessThan(s[0].revision, s[1].revision)
    }

    func testOnlyChangedDaysGetANewRevision() async throws {
        let mac = try await WhoopStore.inMemory()
        _ = try await mac.upsertDailyMetrics([day("2026-11-25", recovery: 70), day("2026-11-26", recovery: 60)], deviceId: dev)
        let first = try await mac.dailySummaries(deviceId: dev, since: 0)
        let top = first.map(\.revision).max()!
        let none = try await mac.dailySummaries(deviceId: dev, since: top)
        XCTAssertTrue(none.isEmpty, "nothing changed, nothing new")
        _ = try await mac.upsertDailyMetrics([day("2026-11-25", recovery: 72)], deviceId: dev)   // late data re-scored
        let changed = try await mac.dailySummaries(deviceId: dev, since: top)
        XCTAssertEqual(changed.map(\.day), ["2026-11-25"])
        XCTAssertEqual(changed[0].values["recovery"], 72)
        XCTAssertGreaterThan(changed[0].revision, top)
    }

    func testOtherSourcesAreNotSent() async throws {
        let mac = try await WhoopStore.inMemory()
        _ = try await mac.upsertDailyMetrics([day("2026-11-25", recovery: 70)], deviceId: "whoop-import")
        let s = try await mac.dailySummaries(deviceId: dev, since: 0)
        XCTAssertTrue(s.isEmpty)
    }

    func testPhoneKeepsTheNewestRevisionPerDay() async throws {
        let phone = try await WhoopStore.inMemory()
        let old = DailySummary(day: "2026-11-25", revision: 3, changedAt: 1, values: ["recovery": 70], coverage: [:], removed: false)
        let new = DailySummary(day: "2026-11-25", revision: 9, changedAt: 2, values: ["recovery": 72], coverage: [:], removed: false)
        var n = try await phone.cacheSummaries([new])
        XCTAssertEqual(n, 1)
        n = try await phone.cacheSummaries([old])       // a stale reply arriving late
        XCTAssertEqual(n, 0)
        let cached = try await phone.cachedSummaries()
        XCTAssertEqual(cached.first?.values["recovery"], 72)
        let rev = try await phone.cachedSummaryRevision()
        XCTAssertEqual(rev, 9)
    }

    func testCacheSurvivesReopenForOfflineDisplay() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("phone.sqlite").path
        do {
            let phone = try await WhoopStore(path: path)
            try await phone.cacheSummaries([DailySummary(day: "2026-11-25", revision: 1, changedAt: 1,
                                                         values: ["strain": 12.5], coverage: ["strain": 0.9], removed: false)])
        }
        let reopened = try await WhoopStore(path: path)
        let cached = try await reopened.cachedSummaries()
        XCTAssertEqual(cached.first?.coverage["strain"], 0.9)
    }

    func testADayScoredAwayIsSentOnceAsRemoved() async throws {
        let mac = try await WhoopStore.inMemory()
        _ = try await mac.upsertDailyMetrics([day("2026-11-25", recovery: 70)], deviceId: dev)
        let top = try await mac.dailySummaries(deviceId: dev, since: 0).map(\.revision).max()!
        try await mac.dbQueue.write { try $0.execute(sql: "DELETE FROM dailyMetric") }
        let gone = try await mac.dailySummaries(deviceId: dev, since: top)
        XCTAssertEqual(gone.map(\.removed), [true])
        let again = try await mac.dailySummaries(deviceId: dev, since: gone[0].revision)
        XCTAssertTrue(again.isEmpty, "a removal is sent once")
        let phone = try await WhoopStore.inMemory()
        try await phone.cacheSummaries(try await mac.dailySummaries(deviceId: dev, since: 0))
        let shown = try await phone.cachedSummaries()
        XCTAssertTrue(shown.isEmpty, "the phone stops showing a removed day")
    }

    func testDetailAddsValuesAndWorkoutsAndOnlyChangesRevisionWhenItChanges() async throws {
        let mac = try await WhoopStore.inMemory()
        _ = try await mac.upsertDailyMetrics([day("2026-11-25", recovery: 70)], deviceId: dev)
        let top = try await mac.dailySummaries(deviceId: dev, since: 0).map(\.revision).max()!
        let w = WorkoutSummary(sport: "Running", startTs: 1_795_000_000, durationMin: 42, strain: 12.1, avgHr: 151, maxHr: 178, kcal: 480)
        let detail = SummaryDetail(values: ["kcal": 2400, "zone2Min": 35, "recovery": 1], workouts: [w])
        try await mac.setSummaryDetail(deviceId: dev, day: "2026-11-25", detail: detail)
        let s = try await mac.dailySummaries(deviceId: dev, since: top)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].values["kcal"], 2400)
        XCTAssertEqual(s[0].values["recovery"], 70, "a detail value never overrides the scored value")
        XCTAssertEqual(s[0].workouts, [w])
        try await mac.setSummaryDetail(deviceId: dev, day: "2026-11-25", detail: detail)          // same content again
        let none = try await mac.dailySummaries(deviceId: dev, since: s[0].revision)
        XCTAssertTrue(none.isEmpty)
        let missing = try await mac.daysMissingSummaryDetail(deviceId: dev)
        XCTAssertTrue(missing.isEmpty)
    }

    func testOldCachedSummariesWithoutWorkoutsStillDecode() throws {
        let json = #"{"day":"2026-11-25","revision":1,"changedAt":1,"values":{"recovery":70},"coverage":{},"removed":false}"#
        let s = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(s.workouts)
    }
}
