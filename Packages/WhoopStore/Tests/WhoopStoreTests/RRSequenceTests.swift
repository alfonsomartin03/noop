import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// Beat order and identity inside one whole second: the inputs to every successive difference (RMSSD, pNN50).
final class RRSequenceTests: XCTestCase {
    private func streams(_ rr: [RRInterval]) -> Streams { Streams(rr: rr) }

    func testTwoIdenticalBeatsInOneSecondAreBothKept() async throws {
        let store = try await WhoopStore.inMemory()
        // 130 bpm: two genuine 460 ms beats end inside the same second.
        let n = try await store.insert(streams([RRInterval(ts: 100, rrMs: 460), RRInterval(ts: 100, rrMs: 460)]), deviceId: "d")
        XCTAssertEqual(n.rr, 2)
        let back = try await store.rrIntervals(deviceId: "d", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(back.count, 2)
    }

    func testSameSecondBeatsReturnInAcquisitionOrderNotByValue() async throws {
        let store = try await WhoopStore.inMemory()
        let rr = [RRInterval(ts: 99, rrMs: 900), RRInterval(ts: 100, rrMs: 520), RRInterval(ts: 100, rrMs: 480),
                  RRInterval(ts: 101, rrMs: 700)]
        try await store.insert(streams(rr), deviceId: "d")
        let back = try await store.rrIntervals(deviceId: "d", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(back.map(\.rrMs), [900, 520, 480, 700])
    }

    func testResavingTheSameChunkIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let rr = [RRInterval(ts: 100, rrMs: 460), RRInterval(ts: 100, rrMs: 460), RRInterval(ts: 101, rrMs: 800)]
        try await store.insert(streams(rr), deviceId: "d")
        let again = try await store.insert(streams(rr), deviceId: "d")
        XCTAssertEqual(again.rr, 0)
        let back = try await store.rrIntervals(deviceId: "d", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(back.count, 3)
    }

    func testRetransmittedRecordInsideOneBatchIsNotDoubled() async throws {
        // One record [800, 820] delivered twice in the same batch. 820 + 800 + 820 ms cannot all end within one
        // second, so the repeats are re-deliveries, not beats.
        let rr = [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820),
                  RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)]
        XCTAssertEqual(WhoopStore.newBeats(existing: [], incoming: rr.map(\.rrMs)).map(\.rrMs), [800, 820])
    }

    // MARK: Split-batch ingestion (one second's beats arriving in two inserts)

    private func stored(_ store: WhoopStore) async throws -> [RRInterval] {
        try await store.rrIntervals(deviceId: "d", from: 0, to: 10_000, limit: 100)
    }

    func testSecondSplitAcrossTwoBatchesKeepsBothBeatsInOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(streams([RRInterval(ts: 99, rrMs: 900), RRInterval(ts: 100, rrMs: 520)]), deviceId: "d")
        try await store.insert(streams([RRInterval(ts: 100, rrMs: 480), RRInterval(ts: 101, rrMs: 700)]), deviceId: "d")
        let got = try await stored(store)
        XCTAssertEqual(got.map(\.rrMs), [900, 520, 480, 700])
    }

    func testResaveWithShiftedBatchBoundaryDoesNotDuplicate() async throws {
        let store = try await WhoopStore.inMemory()
        let whole = [RRInterval(ts: 100, rrMs: 520), RRInterval(ts: 100, rrMs: 480)]
        try await store.insert(streams(whole), deviceId: "d")
        // The same second re-pulled in pieces, in any split.
        let a = try await store.insert(streams([whole[1]]), deviceId: "d")
        let b = try await store.insert(streams([whole[0]]), deviceId: "d")
        let c = try await store.insert(streams(whole + [RRInterval(ts: 101, rrMs: 700)]), deviceId: "d")
        XCTAssertEqual([a.rr, b.rr, c.rr], [0, 0, 1])
        let got = try await stored(store)
        XCTAssertEqual(got.map(\.rrMs), [520, 480, 700])
    }

    func testOverlappingChunkAppendsOnlyTheNewTail() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(streams([RRInterval(ts: 100, rrMs: 330), RRInterval(ts: 100, rrMs: 340)]), deviceId: "d")
        // Re-pulled chunk overlaps the stored beats and carries one more (180 bpm: three beats fit in one second).
        try await store.insert(streams([RRInterval(ts: 100, rrMs: 340), RRInterval(ts: 100, rrMs: 335)]), deviceId: "d")
        let got = try await stored(store)
        XCTAssertEqual(got.map(\.rrMs), [330, 340, 335])
    }

    func testIdenticalValueContinuationIsResolvedTowardNoDuplicate() {
        // Documented ambiguity: [460] then [460] could be a genuine second beat or a re-delivery; never duplicate.
        XCTAssertTrue(WhoopStore.newBeats(existing: [460], incoming: [460]).isEmpty)
        // Within ONE batch the same pair is unambiguous: two beats.
        XCTAssertEqual(WhoopStore.newBeats(existing: [], incoming: [460, 460]).map(\.seq), [0, 1])
    }

    func testV9DataSurvivesV10MigrationInOrder() throws {
        let q = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(q, upTo: "v9")
        try q.write { db in
            // v9 inserted in acquisition order; distinct values only (the old key forbade repeats in a second).
            for (ts, ms) in [(100, 520), (100, 480), (101, 700), (102, 650)] {
                try db.execute(sql: "INSERT INTO rrInterval (deviceId, ts, rrMs) VALUES ('d', ?, ?)", arguments: [ts, ms])
            }
            try db.execute(sql: "UPDATE rrInterval SET synced = 1 WHERE ts = 102")
        }
        try migrator.migrate(q)
        let rows = try q.read { db in
            try Row.fetchAll(db, sql: "SELECT ts, seq, rrMs, synced FROM rrInterval ORDER BY ts, seq, rowid")
        }
        XCTAssertEqual(rows.map { [$0["ts"], $0["seq"], $0["rrMs"], $0["synced"]] as [Int] },
                       [[100, 0, 520, 0], [100, 1, 480, 0], [101, 0, 700, 0], [102, 0, 650, 1]])
    }
}

/// A re-score wipes ONLY NOOP's own derived rows: imported records and raw samples survive with their provenance.
final class DerivedIsolationTests: XCTestCase {
    func testDeleteDerivedKeepsImportsAndRawSamples() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = DailyMetric(day: "2026-10-01", totalSleepMin: 420, efficiency: 91, deepMin: nil, remMin: nil,
                                   lightMin: nil, disturbances: nil, restingHr: 51, avgHrv: 62, recovery: 70,
                                   strain: nil, exerciseCount: nil)
        let computed = DailyMetric(day: "2026-10-01", totalSleepMin: 400, efficiency: 88, deepMin: nil, remMin: nil,
                                   lightMin: nil, disturbances: nil, restingHr: 53, avgHrv: 48, recovery: 55,
                                   strain: nil, exerciseCount: nil)
        try await store.upsertDailyMetrics([imported], deviceId: "dev")
        try await store.upsertDailyMetrics([computed], deviceId: "dev-noop")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "hrv", value: 62)], deviceId: "dev")
        try await store.upsertMetricSeries([MetricPoint(day: "2026-10-01", key: "noop.ln_rmssd_z", value: -1)],
                                           deviceId: "dev-noop")
        try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 55)], rr: [RRInterval(ts: 100, rrMs: 1000)]),
                               deviceId: "dev")

        try await store.deleteDerived(deviceId: "dev-noop")

        let keptImport = try await store.dailyMetrics(deviceId: "dev", from: "2026-01-01", to: "2026-12-31")
        let goneComputed = try await store.dailyMetrics(deviceId: "dev-noop", from: "2026-01-01", to: "2026-12-31")
        let keptSeries = try await store.metricSeries(deviceId: "dev", key: "hrv", from: "2026-01-01", to: "2026-12-31")
        let goneSeries = try await store.metricSeries(deviceId: "dev-noop", key: "noop.ln_rmssd_z",
                                                      from: "2026-01-01", to: "2026-12-31")
        let rr = try await store.rrIntervals(deviceId: "dev", from: 0, to: 1000, limit: 10)
        let hr = try await store.hrSamples(deviceId: "dev", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(keptImport, [imported])
        XCTAssertTrue(goneComputed.isEmpty)
        XCTAssertEqual(keptSeries.count, 1)
        XCTAssertTrue(goneSeries.isEmpty)
        XCTAssertEqual(rr.count, 1)
        XCTAssertEqual(hr.count, 1)
    }
}
