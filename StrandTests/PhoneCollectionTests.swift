import XCTest
import WhoopStore
@testable import NOOP

/// #78: companion mode switches the Mac's strap link off; undecoded history reaches the phone's outbox whole and once.
@MainActor
final class PhoneCollectionTests: XCTestCase {
    override func tearDown() { CompanionMode.set(false) }

    func testCompanionModeTurnsTheMacsStrapLinkOff() {
        CompanionMode.set(false)
        XCTAssertTrue(LaunchMode.bluetoothEnabled)
        CompanionMode.set(true)
        XCTAssertFalse(LaunchMode.bluetoothEnabled, "no central, scan, reconnect or command while the iPhone collects")
        CompanionMode.set(false)
        XCTAssertTrue(LaunchMode.bluetoothEnabled)
    }

    func testUndecodedLinesMoveWholeAndOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "noop.test.forwarder.\(UUID().uuidString)")!
        let store = try await WhoopStore.inMemory()
        let file = dir.appendingPathComponent("2026-11-27.jsonl")
        try Data("{\"a\":1}\n{\"a\":2}\n{\"a\":3".utf8).write(to: file)          // last line still being written
        try await UndecodedForwarder.forward(into: store, directory: dir, defaults: defaults)
        var batch = try await store.cutOutboxBatch(deviceId: "my-whoop")
        var lines = try await store.outboxBatch(sequence: batch!.sequence).undecoded
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"a\":2}"], "a partial line waits")
        let h = try FileHandle(forWritingTo: file); try h.seekToEnd(); try h.write(contentsOf: Data("}\n".utf8)); try h.close()
        try await UndecodedForwarder.forward(into: store, directory: dir, defaults: defaults)
        try await UndecodedForwarder.forward(into: store, directory: dir, defaults: defaults)   // nothing new
        batch = try await store.cutOutboxBatch(deviceId: "my-whoop")
        lines = try await store.outboxBatch(sequence: batch!.sequence).undecoded
        XCTAssertEqual(lines, ["{\"a\":3}"])
    }
}
