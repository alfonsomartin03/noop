import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Derived (NOOP-computed) rows: all-or-nothing writes, partial-replay cleanup, version archive, persisted provenance.
final class DerivedWriteTests: XCTestCase {
    private func daily(_ day: String, hrv: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 90, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: 52, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
    }
    private func prov(_ day: String, _ key: String, version: String = "vitals-2026.10") -> ProvenanceRecord {
        ProvenanceRecord(day: day, key: key, definition: "rmssd", unit: "ms", source: "noop", hardware: "unknown",
                         algorithmVersion: version, context: "sleep", aggregation: "medianOf5MinWindows",
                         coverage: 0.7, exclusionReasons: ["a", "b"], scoringVersion: 3)
    }
    // Day 2026-10-02 spans [1000, 2000) in these fixtures.
    private func seedRun(_ store: WhoopStore) async throws {
        try await store.writeDerived(DerivedBatch(
            dailies: [daily("2026-10-01", hrv: 50), daily("2026-10-02", hrv: 51)],
            sleepSessions: [CachedSleepSession(startTs: 900, endTs: 1500, efficiency: 0.9, restingHr: 52, avgHrv: 51, stagesJSON: nil)],
            workouts: [WorkoutRow(startTs: 1200, endTs: 1300, sport: "Activity", source: "noop", durationS: 100,
                                  energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)],
            series: [MetricPoint(day: "2026-10-02", key: "noop.ln_rmssd_z", value: -1.2)],
            provenance: [prov("2026-10-01", "avgHrv"), prov("2026-10-02", "avgHrv")]),
            deviceId: "d-noop", scope: .replaceDays(["2026-10-01", "2026-10-02"], ranges: [0...999, 1000...1999]))
    }

    func testProvenanceIsPersistedAndRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRun(store)
        let p = try await store.provenance(deviceId: "d-noop", from: "2026-10-02", to: "2026-10-02")
        XCTAssertEqual(p, [prov("2026-10-02", "avgHrv")])
        XCTAssertEqual(p.first?.exclusionReasons, ["a", "b"])
        XCTAssertEqual(p.first?.coverage, 0.7)
    }

    func testPartialReplayReplacesEverythingForTheReplayedDayOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRun(store)
        // Replay of 2026-10-02 that no longer yields a z-score, a session or a workout.
        try await store.writeDerived(DerivedBatch(dailies: [daily("2026-10-02", hrv: nil)]),
                                     deviceId: "d-noop", scope: .replaceDays(["2026-10-02"], ranges: [1000...1999]))
        let z = try await store.metricSeries(deviceId: "d-noop", key: "noop.ln_rmssd_z", from: "2026-01-01", to: "2026-12-31")
        let sessions = try await store.sleepSessions(deviceId: "d-noop", from: 0, to: 5000, limit: 10)
        let workouts = try await store.workouts(deviceId: "d-noop", from: 0, to: 5000, limit: 10)
        let p2 = try await store.provenance(deviceId: "d-noop", from: "2026-10-02", to: "2026-10-02")
        let p1 = try await store.provenance(deviceId: "d-noop", from: "2026-10-01", to: "2026-10-01")
        let days = try await store.dailyMetrics(deviceId: "d-noop", from: "2026-01-01", to: "2026-12-31")
        XCTAssertTrue(z.isEmpty, "stale component key from the earlier run must not survive")
        XCTAssertTrue(sessions.isEmpty); XCTAssertTrue(workouts.isEmpty); XCTAssertTrue(p2.isEmpty)
        XCTAssertEqual(p1.count, 1, "untouched day keeps its provenance")
        XCTAssertEqual(days.map(\.avgHrv), [50, nil])
    }

    private func load(_ day: String, _ scope: String = LoadRecordRow.dayScope, startTs: Int = 0, payload: String = "{}") -> LoadRecordRow {
        LoadRecordRow(day: day, scope: scope, startTs: startTs, algorithmVersion: "cardio-load-test", payload: payload)
    }

    func testLoadRecordsRoundTripAndAreReplacedWithTheirDay() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = [load("2026-10-01"), load("2026-10-02"), load("2026-10-02", LoadRecordRow.sessionScope, startTs: 1200)]
        try await store.writeDerived(DerivedBatch(loadRecords: rows), deviceId: "d-noop",
                                     scope: .replaceDays(["2026-10-01", "2026-10-02"], ranges: [0...999, 1000...1999]))
        let stored = try await store.loadRecords(deviceId: "d-noop", from: "2026-10-01", to: "2026-10-02")
        XCTAssertEqual(stored, rows)
        // Replaying one day drops its stale session row and leaves the other day alone.
        try await store.writeDerived(DerivedBatch(loadRecords: [load("2026-10-02", payload: "{\"v\":2}")]), deviceId: "d-noop",
                                     scope: .replaceDays(["2026-10-02"], ranges: [1000...1999]))
        let after = try await store.loadRecords(deviceId: "d-noop", from: "2026-10-01", to: "2026-10-02")
        XCTAssertEqual(after, [load("2026-10-01"), load("2026-10-02", payload: "{\"v\":2}")])
    }

    func testRescoreArchivesLoadRecords() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.writeDerived(DerivedBatch(loadRecords: [load("2026-10-02")]), deviceId: "d-noop",
                                     scope: .replaceDays(["2026-10-02"], ranges: [1000...1999]))
        try await store.writeDerived(DerivedBatch(loadRecords: [load("2026-10-02", payload: "{\"v\":2}")]), deviceId: "d-noop",
                                     scope: .rescore(archiveId: "d-noop-v3", fromDay: "2026-01-01", fromTs: 0))
        let archived = try await store.loadRecords(deviceId: "d-noop-v3", from: "2026-01-01", to: "2026-12-31")
        let current = try await store.loadRecords(deviceId: "d-noop", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(archived, [load("2026-10-02")])
        XCTAssertEqual(current, [load("2026-10-02", payload: "{\"v\":2}")])
    }

    func testFailedWriteChangesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRun(store)
        try await store.executeForTest("""
            CREATE TRIGGER failProv BEFORE INSERT ON metricProvenance WHEN NEW.key = 'boom'
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        for scope in [DerivedWriteScope.replaceDays(["2026-10-02"], ranges: [1000...1999]),
                      .rescore(archiveId: "d-noop-v2", fromDay: "2026-01-01", fromTs: 0)] {
            do {
                try await store.writeDerived(DerivedBatch(dailies: [daily("2026-10-02", hrv: 99)],
                                                          provenance: [prov("2026-10-02", "boom")]),
                                             deviceId: "d-noop", scope: scope)
                XCTFail("write should fail")
            } catch {}
            let days = try await store.dailyMetrics(deviceId: "d-noop", from: "2026-01-01", to: "2026-12-31")
            let sessions = try await store.sleepSessions(deviceId: "d-noop", from: 0, to: 5000, limit: 10)
            let z = try await store.metricSeries(deviceId: "d-noop", key: "noop.ln_rmssd_z", from: "2026-01-01", to: "2026-12-31")
            let archived = try await store.dailyMetrics(deviceId: "d-noop-v2", from: "2026-01-01", to: "2026-12-31")
            XCTAssertEqual(days.map(\.avgHrv), [50, 51], "previous rows intact after a failed \(scope)")
            XCTAssertEqual(sessions.count, 1); XCTAssertEqual(z.count, 1)
            XCTAssertTrue(archived.isEmpty, "no half-written archive")
        }
    }

    func testRescoreArchivesAllDerivedTablesThenReplacesHorizonOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRun(store)
        try await store.upsertDailyMetrics([daily("2026-10-05", hrv: 1)], deviceId: "d")          // an import
        try await store.writeDerived(DerivedBatch(dailies: [daily("2026-10-02", hrv: 60)],
                                                  provenance: [prov("2026-10-02", "avgHrv", version: "vitals-next")]),
                                     deviceId: "d-noop", scope: .rescore(archiveId: "d-noop-v3", fromDay: "2026-10-02", fromTs: 1000))
        let cur = try await store.dailyMetrics(deviceId: "d-noop", from: "2026-01-01", to: "2026-12-31")
        let arch = try await store.dailyMetrics(deviceId: "d-noop-v3", from: "2026-01-01", to: "2026-12-31")
        let archProv = try await store.provenance(deviceId: "d-noop-v3", from: "2026-01-01", to: "2026-12-31")
        let archSessions = try await store.sleepSessions(deviceId: "d-noop-v3", from: 0, to: 5000, limit: 10)
        let archWorkouts = try await store.workouts(deviceId: "d-noop-v3", from: 0, to: 5000, limit: 10)
        let archZ = try await store.metricSeries(deviceId: "d-noop-v3", key: "noop.ln_rmssd_z", from: "2026-01-01", to: "2026-12-31")
        let curProv = try await store.provenance(deviceId: "d-noop", from: "2026-01-01", to: "2026-12-31")
        let imported = try await store.dailyMetrics(deviceId: "d", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(cur.map(\.avgHrv), [50, 60], "day before the horizon kept; horizon replaced")
        XCTAssertEqual(arch.map(\.avgHrv), [50, 51])
        XCTAssertEqual(archProv.count, 2); XCTAssertEqual(archSessions.count, 1)
        XCTAssertEqual(archWorkouts.count, 1); XCTAssertEqual(archZ.count, 1)
        XCTAssertEqual(curProv.map(\.algorithmVersion), ["vitals-2026.10", "vitals-next"],
                       "the kept older row still says which version produced it")
        XCTAssertEqual(imported.count, 1)
    }

    func testV11AddsProvenanceTable() async throws {
        let store = try await WhoopStore.inMemory()
        let pk = try await store.primaryKeyColumns("metricProvenance")
        XCTAssertEqual(pk, ["deviceId", "day", "key"])
    }
}
