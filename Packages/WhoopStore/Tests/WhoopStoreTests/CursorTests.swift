import XCTest
import GRDB
@testable import WhoopStore

final class CursorTests: XCTestCase {
    func testV2CreatesCursorsTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let pkCols = try await store.primaryKeyColumns("cursors")
        XCTAssertTrue(tables.contains("cursors"))
        XCTAssertEqual(pkCols, ["name"])
    }
    func testCursorRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.cursor("strap_trim")
        XCTAssertNil(before)
        try await store.setCursor("strap_trim", 12345)
        let after = try await store.cursor("strap_trim")
        XCTAssertEqual(after, 12345)
    }
    func testCursorUpsertsOnConflict() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.setCursor("strap_trim", 1)
        try await store.setCursor("strap_trim", 2)
        let v = try await store.cursor("strap_trim")
        XCTAssertEqual(v, 2)
    }
}
