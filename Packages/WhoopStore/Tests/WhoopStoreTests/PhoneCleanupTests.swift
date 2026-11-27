import XCTest
import WhoopProtocol
@testable import WhoopStore

/// #81: phone rows are deleted only after a trusted, current receipt and the grace period; a restored or replaced Mac
/// sends batches back to pending; rowids never restart; deletion is whole or nothing.
final class PhoneCleanupTests: XCTestCase {
    private let a1 = SyncArchiveRef(archiveId: "mac", generation: 100)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let grace: TimeInterval = 3600

    private func collectAndCut(_ store: WhoopStore, _ ts: ClosedRange<Int>) async throws -> Int64 {
        try await store.insert(Streams(hr: ts.map { HRSample(ts: $0, bpm: 60) }), deviceId: "my-whoop")
        return try await store.cutOutboxBatch(deviceId: "my-whoop")!.sequence
    }

    private func hrCount(_ store: WhoopStore) async throws -> Int { try await store.storageStats_rowCountsForTest().hr }

    func testNothingIsDeletedBeforeAReceiptOrBeforeTheGracePeriod() async throws {
        let store = try await WhoopStore.inMemory()
        let seq = try await collectAndCut(store, 1...10)
        var del = try await store.deleteOutboxBatch(sequence: seq, now: t0, grace: grace)
        XCTAssertNil(del, "no receipt yet")
        try await store.recordOutboxReceipt(sequence: seq, receiptJSON: "{}", archive: a1, now: t0)
        del = try await store.deleteOutboxBatch(sequence: seq, now: t0.addingTimeInterval(grace - 1), grace: grace)
        XCTAssertNil(del, "still inside the grace period")
        var n = try await hrCount(store)
        XCTAssertEqual(n, 10)
        del = try await store.deleteOutboxBatch(sequence: seq, now: t0.addingTimeInterval(grace), grace: grace)
        XCTAssertEqual(del, 9, "the newest row of the table is kept")
        n = try await hrCount(store)
        XCTAssertEqual(n, 1)
    }

    func testUnbatchedAndUnconfirmedRowsAreNeverTouched() async throws {
        let store = try await WhoopStore.inMemory()
        let s1 = try await collectAndCut(store, 1...5)
        let s2 = try await collectAndCut(store, 6...8)                       // cut but not confirmed
        try await store.insert(Streams(hr: [HRSample(ts: 9, bpm: 60)]), deviceId: "my-whoop")   // not batched
        try await store.recordOutboxReceipt(sequence: s1, receiptJSON: "{}", archive: a1, now: t0)
        let deletable = try await store.deletableOutboxBatches(now: t0.addingTimeInterval(grace), grace: grace)
        XCTAssertEqual(deletable, [s1])
        _ = try await store.deleteOutboxBatch(sequence: s1, now: t0.addingTimeInterval(grace), grace: grace)
        let left = try await store.outboxBatch(sequence: s2).streams.hr.map(\.ts)
        XCTAssertEqual(left, [6, 7, 8])
        let n = try await hrCount(store)
        XCTAssertEqual(n, 4, "batch 2 (3 rows) + the unbatched row")
    }

    func testRowidsKeepRisingAfterTheTableIsEmptiedSoNewRowsAreStillSent() async throws {
        let store = try await WhoopStore.inMemory()
        let s1 = try await collectAndCut(store, 1...3)
        try await store.recordOutboxReceipt(sequence: s1, receiptJSON: "{}", archive: a1, now: t0)
        _ = try await store.deleteOutboxBatch(sequence: s1, now: t0.addingTimeInterval(grace), grace: grace)
        try await store.insert(Streams(hr: [HRSample(ts: 50, bpm: 70), HRSample(ts: 51, bpm: 71)]), deviceId: "my-whoop")
        let s2 = try await store.cutOutboxBatch(deviceId: "my-whoop")
        let sent = try await store.outboxBatch(sequence: s2!.sequence).streams.hr.map(\.ts)
        XCTAssertEqual(sent, [50, 51], "new rows are claimed, not hidden below an old range")
    }

    func testARestoredMacSendsConfirmedBatchesBackAndFlagsDeletedOnes() async throws {
        let store = try await WhoopStore.inMemory()
        let s1 = try await collectAndCut(store, 1...3)       // will be deleted under generation 100
        let s2 = try await collectAndCut(store, 10...12)     // confirmed, still on the phone
        let s3 = try await collectAndCut(store, 20...22)     // confirmed after the restore
        try await store.recordOutboxReceipt(sequence: s1, receiptJSON: "{}", archive: a1, now: t0)
        try await store.recordOutboxReceipt(sequence: s2, receiptJSON: "{}", archive: a1, now: t0)
        _ = try await store.deleteOutboxBatch(sequence: s1, now: t0.addingTimeInterval(grace), grace: grace)
        let restored = SyncArchiveRef(archiveId: "mac", generation: 200)
        let outcome = try await store.recordOutboxReceipt(sequence: s3, receiptJSON: "{}", archive: restored, now: t0)
        XCTAssertEqual(outcome, .archiveChanged(requeued: 1, newlyPossiblyLost: 1))
        let pending = try await store.pendingOutboxBatches().map(\.sequence)
        XCTAssertEqual(pending, [s2], "batch 2 goes to the restored Mac again")
        let deletable = try await store.deletableOutboxBatches(now: t0.addingTimeInterval(grace), grace: grace)
        XCTAssertEqual(deletable, [s3])
        let storage = try await store.phoneStorage()
        XCTAssertEqual(storage.possiblyLost, [1...3], "the whole span batch 1 covered")
    }

    func testAnotherMacArchiveAlsoRequeues() async throws {
        let store = try await WhoopStore.inMemory()
        let s1 = try await collectAndCut(store, 1...3)
        let s2 = try await collectAndCut(store, 5...6)
        try await store.recordOutboxReceipt(sequence: s1, receiptJSON: "{}", archive: a1, now: t0)
        let outcome = try await store.recordOutboxReceipt(sequence: s2, receiptJSON: "{}",
                                                          archive: SyncArchiveRef(archiveId: "new-mac", generation: 1), now: t0)
        XCTAssertEqual(outcome, .archiveChanged(requeued: 1, newlyPossiblyLost: 0))
        let pending = try await store.pendingOutboxBatches().map(\.sequence)
        XCTAssertEqual(pending, [s1])
    }

    func testAStaleReceiptIsNotRecorded() async throws {
        let store = try await WhoopStore.inMemory()
        let s1 = try await collectAndCut(store, 1...3)
        let s2 = try await collectAndCut(store, 5...6)
        try await store.recordOutboxReceipt(sequence: s1, receiptJSON: "{}", archive: a1, now: t0)
        let outcome = try await store.recordOutboxReceipt(sequence: s2, receiptJSON: "{}",
                                                          archive: SyncArchiveRef(archiveId: "mac", generation: 50), now: t0)
        XCTAssertEqual(outcome, .stale)
        let pending = try await store.pendingOutboxBatches().map(\.sequence)
        XCTAssertEqual(pending, [s2])
    }

    func testDeletedSpaceIsReusedSoTheFileStopsGrowing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("phone.sqlite").path)
        func day(_ base: Int) async throws {
            let ts = base..<(base + 20_000)
            try await store.insert(Streams(hr: ts.map { HRSample(ts: $0, bpm: 60) },
                                           gravity: ts.map { GravitySample(ts: $0, x: 0.1, y: 0.2, z: 0.97) }),
                                   deviceId: "my-whoop")
            let seq = try await store.cutOutboxBatch(deviceId: "my-whoop")!.sequence
            try await store.recordOutboxReceipt(sequence: seq, receiptJSON: "{}", archive: a1, now: t0)
            _ = try await store.deleteOutboxBatch(sequence: seq, now: t0.addingTimeInterval(grace), grace: grace)
            try await store.checkpointWAL()
        }
        try await day(0)
        let afterFirst = try await store.phoneStorage().databaseBytes
        for i in 1...4 { try await day(i * 100_000) }
        let afterFive = try await store.phoneStorage().databaseBytes
        XCTAssertLessThan(Double(afterFive), Double(afterFirst) * 1.3, "five days of collect+delete reuse the same pages")
    }
}
