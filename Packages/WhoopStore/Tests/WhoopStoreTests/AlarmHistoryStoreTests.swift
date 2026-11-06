import XCTest
@testable import WhoopStore

final class AlarmHistoryStoreTests: XCTestCase {
    func testV16AddsAlarmTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("alarmEvent"))
        XCTAssertTrue(tables.contains("alarmAnnotation"))
    }

    /// The same strap event arrives live and again from a history pull: stored once, with the live copy's attribution.
    func testLiveAndHistoryCopiesDeduplicate() async throws {
        let store = try await WhoopStore.inMemory()
        let key = "strap:60:1793643904:120"
        let live = AlarmEventRow(occurrenceId: "a@1", kind: "strapEvent", recordedAt: 100, deviceTs: 1_793_643_904,
                                 mappedHostTs: 1_793_643_920, receivedAt: 100, provenance: AlarmEventRow.Provenance.live,
                                 dedupeKey: key, payload: "{\"event\":\"HAPTICS_FIRED\"}")
        let hist = AlarmEventRow(occurrenceId: nil, kind: "strapEvent", recordedAt: 900, deviceTs: 1_793_643_904,
                                 receivedAt: 900, provenance: AlarmEventRow.Provenance.history, dedupeKey: key)
        let n1 = try await store.appendAlarmEvents([live])
        let n2 = try await store.appendAlarmEvents([hist])
        XCTAssertEqual(n1, 1); XCTAssertEqual(n2, 0)
        let rows = try await store.alarmEvents()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].occurrenceId, "a@1")
        XCTAssertEqual(rows[0].provenance, "live")
    }

    /// Host rows (no dedupe key) always append; ordering is newest first; annotations are separate.
    func testAppendOnlyOrderingAndAnnotations() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.appendAlarmEvents([
            AlarmEventRow(occurrenceId: "a@1", kind: "scheduled", recordedAt: 10, provenance: "host"),
            AlarmEventRow(occurrenceId: "a@1", kind: "decision", recordedAt: 20, provenance: "host"),
            AlarmEventRow(occurrenceId: "a@1", kind: "decision", recordedAt: 20, provenance: "host"),
        ])
        let rows = try await store.alarmEvents()
        XCTAssertEqual(rows.map(\.kind), ["decision", "decision", "scheduled"])
        try await store.setAlarmAnnotation(AlarmAnnotationRow(occurrenceId: "a@1", label: "feltIt", createdAt: 30))
        try await store.setAlarmAnnotation(AlarmAnnotationRow(occurrenceId: "a@1", label: "sleptThrough", createdAt: 31))
        let notes = try await store.alarmAnnotations()
        XCTAssertEqual(notes, [AlarmAnnotationRow(occurrenceId: "a@1", label: "sleptThrough", createdAt: 31)])
        let after = try await store.alarmEvents()
        XCTAssertEqual(after.count, 3)   // notes never touch device evidence
    }
}
