import XCTest
import GRDB
@testable import WhoopStore

final class JournalWorkoutAppleCacheTests: XCTestCase {

    // MARK: - migration (v8 creates the three tables with the right PKs)

    func testV8CreatesTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("journal"))
        XCTAssertTrue(tables.contains("workout"))
        XCTAssertTrue(tables.contains("appleDaily"))

        let journalPK = try await store.primaryKeyColumns("journal")
        XCTAssertEqual(journalPK, ["deviceId", "day", "question"])
        let workoutPK = try await store.primaryKeyColumns("workout")
        XCTAssertEqual(workoutPK, ["deviceId", "startTs", "sport"])
        let applePK = try await store.primaryKeyColumns("appleDaily")
        XCTAssertEqual(applePK, ["deviceId", "day"])
    }

    func testExistingTablesStillPresentAfterV8() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
                  "sleepSession", "dailyMetric"] {
            XCTAssertTrue(tables.contains(t), "v8 must not drop \(t)")
        }
    }

    // MARK: - journal

    func testJournalUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let e = JournalEntry(day: "2026-05-23", question: "Did you drink alcohol?",
                             answeredYes: true, notes: "two beers")
        try await store.upsertJournal([e], deviceId: "devA")

        var rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], e)

        // Re-upsert same natural key with changed values → no duplicate, value updated.
        let e2 = JournalEntry(day: "2026-05-23", question: "Did you drink alcohol?",
                              answeredYes: false, notes: nil)
        try await store.upsertJournal([e2], deviceId: "devA")
        rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(rows.count, 1, "same (deviceId,day,question) must not duplicate")
        XCTAssertEqual(rows[0].answeredYes, false)
        XCTAssertNil(rows[0].notes)
    }

    func testJournalDistinctQuestionsCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertJournal([
            JournalEntry(day: "2026-05-23", question: "Caffeine?", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-05-23", question: "Alcohol?", answeredYes: false, notes: nil),
        ], deviceId: "devA")
        let rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-23", to: "2026-05-23")
        XCTAssertEqual(rows.map { $0.question }, ["Alcohol?", "Caffeine?"]) // question ASC
    }

    func testJournalDayRangeAndDeviceFilter() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertJournal([
            JournalEntry(day: "2026-05-01", question: "Q", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-05-20", question: "Q", answeredYes: true, notes: nil),
        ], deviceId: "devA")
        try await store.upsertJournal([
            JournalEntry(day: "2026-05-20", question: "Q", answeredYes: false, notes: nil),
        ], deviceId: "devB")
        let rows = try await store.journalEntries(deviceId: "devA", from: "2026-05-10", to: "2026-05-31")
        XCTAssertEqual(rows.map { $0.day }, ["2026-05-20"])
        XCTAssertEqual(rows[0].answeredYes, true, "must not bleed devB's row")
    }

    func testUpsertJournalReturnsChangeCount() async throws {
        let store = try await WhoopStore.inMemory()
        let n = try await store.upsertJournal([
            JournalEntry(day: "2026-05-01", question: "A", answeredYes: true, notes: nil),
            JournalEntry(day: "2026-05-01", question: "B", answeredYes: false, notes: nil),
        ], deviceId: "devA")
        XCTAssertEqual(n, 2)
    }

    // MARK: - workout

    func testWorkoutUpsertReadAndIdempotency() async throws {
        let store = try await WhoopStore.inMemory()
        let w = WorkoutRow(startTs: 1_000, endTs: 4_600, sport: "run", source: "apple",
                           durationS: 3600, energyKcal: 520.5, avgHr: 148, maxHr: 176,
                           strain: 12.4, distanceM: 8000, zonesJSON: "{\"z1\":10,\"z2\":40}",
                           notes: "easy")
        try await store.upsertWorkouts([w], deviceId: "devA")

        var rows = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], w)

        // Re-upsert same natural key with updated values → no duplicate, value updated.
        let w2 = WorkoutRow(startTs: 1_000, endTs: 5_000, sport: "run", source: "whoop",
                            durationS: 4000, energyKcal: 600, avgHr: 150, maxHr: 180,
                            strain: 14.0, distanceM: 9000, zonesJSON: nil, notes: nil)
        try await store.upsertWorkouts([w2], deviceId: "devA")
        rows = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "same (deviceId,startTs,sport) must not duplicate")
        XCTAssertEqual(rows[0], w2)
        XCTAssertNil(rows[0].zonesJSON)
        XCTAssertNil(rows[0].notes)
    }

    func testWorkoutDistinctSportSameStartCoexist() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 1_000, endTs: 2_000, sport: "run", source: "apple",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil),
            WorkoutRow(startTs: 1_000, endTs: 2_000, sport: "cycle", source: "apple",
                       durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil),
        ], deviceId: "devA")
        let rows = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 2, "same startTs but different sport are distinct rows")
    }

    func testWorkoutNullableMetricsRoundTripAsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let w = WorkoutRow(startTs: 50, endTs: 60, sport: "yoga", source: "apple",
                           durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                           distanceM: nil, zonesJSON: nil, notes: nil)
        try await store.upsertWorkouts([w], deviceId: "devA")
        let rows = try await store.workouts(deviceId: "devA", from: 0, to: 100, limit: 10)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertNil(r.durationS); XCTAssertNil(r.energyKcal); XCTAssertNil(r.avgHr)
        XCTAssertNil(r.maxHr); XCTAssertNil(r.strain); XCTAssertNil(r.distanceM)
        XCTAssertNil(r.zonesJSON); XCTAssertNil(r.notes)
    }

    func testWorkoutRangeAndLimit() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertWorkouts([
            WorkoutRow(startTs: 100, endTs: 200, sport: "run", source: "a", durationS: nil,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil),
            WorkoutRow(startTs: 500, endTs: 600, sport: "run", source: "a", durationS: nil,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil),
            WorkoutRow(startTs: 900, endTs: 1000, sport: "run", source: "a", durationS: nil,
                       energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                       zonesJSON: nil, notes: nil),
        ], deviceId: "devA")
        let ranged = try await store.workouts(deviceId: "devA", from: 400, to: 1000, limit: 100)
        XCTAssertEqual(ranged.map { $0.startTs }, [500, 900])
        let limited = try await store.workouts(deviceId: "devA", from: 0, to: 100_000, limit: 1)
        XCTAssertEqual(limited.map { $0.startTs }, [100], "limit honoured, oldest first")
    }


}
