import XCTest
@testable import WhoopStore

final class SleepCorrectionTests: XCTestCase {
    func testV15AddsSessionLabelsAndCorrections() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("sleepCorrection"))
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        for c in ["kind", "sessionId", "reason", "confidence"] { XCTAssertTrue(cols.contains(c), c) }
    }

    func testLabelledSessionsRoundTripAndLegacyRowsAreMain() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 100, endTs: 200, efficiency: 0.9, restingHr: 50, avgHrv: 60, stagesJSON: nil),
            CachedSleepSession(startTs: 300, endTs: 400, efficiency: 0.8, restingHr: nil, avgHrv: nil, stagesJSON: nil,
                               kind: "nap", sessionId: "sleep-5", reason: "r", confidence: 0.6),
        ], deviceId: "d")
        let rows = try await store.sleepSessions(deviceId: "d", from: 0, to: 1000, limit: 10)
        XCTAssertTrue(rows[0].isMainSleep)
        XCTAssertFalse(rows[1].isMainSleep)
        XCTAssertEqual(rows[1].sessionId, "sleep-5")
        XCTAssertEqual(rows[1].confidence, 0.6)
    }

    func testCorrectionsSaveQueryDelete() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveSleepCorrection(SleepCorrectionRow(id: "a", action: "markNap", startTs: 100, endTs: 200,
                                                               atTs: nil, newStartTs: nil, newEndTs: nil, createdAt: 1))
        try await store.saveSleepCorrection(SleepCorrectionRow(id: "b", action: "split", startTs: 1000, endTs: 2000,
                                                               atTs: 1500, newStartTs: nil, newEndTs: nil, createdAt: 2))
        let first = try await store.sleepCorrections(from: 0, to: 500)
        XCTAssertEqual(first.map(\.id), ["a"])
        let both = try await store.sleepCorrections(from: 0, to: 5000)
        XCTAssertEqual(both.map(\.id), ["a", "b"])
        try await store.deleteSleepCorrection(id: "a")
        let left = try await store.sleepCorrections(from: 0, to: 5000)
        XCTAssertEqual(left.map(\.id), ["b"])
    }
}
