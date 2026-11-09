import XCTest
@testable import WhoopStore

final class CheckInStoreTests: XCTestCase {
    private func entry(_ date: String, _ session: String = "morning", status: String = "completed", tz: String = "America/New_York",
                       created: Double = 100, updated: Double = 100, answers: [(String, String)]) -> CheckInEntryRow {
        CheckInEntryRow(localDate: date, session: session, status: status, note: nil, timeZone: tz, createdAt: created, updatedAt: updated,
                        answers: answers.enumerated().map { CheckInAnswerRow(promptId: $1.0, promptVersion: 1, answer: $1.1, position: $0) })
    }

    func testV17AddsCheckInTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("checkInEntry"))
        XCTAssertTrue(tables.contains("checkInAnswer"))
    }

    func testAnswerStatesRoundTripDistinctly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveCheckIn(entry("2026-11-01", answers: [("alcohol", "yes"), ("caffeine", "no"), ("screen", "notSure"),
                                                                  ("meal", "skipped"), ("noise", "unanswered")]))
        let rows = try await store.checkIns(from: "2026-11-01", to: "2026-11-01")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].answers.map(\.answer), ["yes", "no", "notSure", "skipped", "unanswered"])
        XCTAssertEqual(rows[0].answers.map(\.promptId), ["alcohol", "caffeine", "screen", "meal", "noise"])
    }

    func testEditReplacesAnswersButKeepsDateCreationAndZone() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveCheckIn(entry("2026-11-01", answers: [("alcohol", "yes"), ("caffeine", "no")]))
        try await store.saveCheckIn(entry("2026-11-01", tz: "Europe/Madrid", created: 900, updated: 900, answers: [("alcohol", "no")]))
        let rows = try await store.checkIns(from: "2026-11-01", to: "2026-11-01")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].answers.map(\.answer), ["no"])
        XCTAssertEqual(rows[0].createdAt, 100)
        XCTAssertEqual(rows[0].updatedAt, 900)
        XCTAssertEqual(rows[0].timeZone, "America/New_York")
    }

    func testSessionsAreIndependentAndRangeIsInclusive() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveCheckIn(entry("2026-11-01", "morning", answers: [("alcohol", "yes")]))
        try await store.saveCheckIn(entry("2026-11-01", "evening", status: "skipped", answers: []))
        try await store.saveCheckIn(entry("2026-11-03", "morning", answers: [("alcohol", "no")]))
        let rows = try await store.checkIns(from: "2026-11-01", to: "2026-11-02")
        XCTAssertEqual(rows.map { "\($0.localDate) \($0.session) \($0.status)" },
                       ["2026-11-01 evening skipped", "2026-11-01 morning completed"])
        try await store.deleteCheckIn(localDate: "2026-11-01", session: "morning")
        let after = try await store.checkIns(from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(after.count, 2)
    }
}
