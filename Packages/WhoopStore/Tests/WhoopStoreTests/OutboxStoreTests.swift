import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Phone outbox (#77): batches claim row ranges in order, rebuild identically, survive a reopen, never reuse a sequence.
final class OutboxStoreTests: XCTestCase {
    private func hr(_ ts: Int) -> Streams { Streams(hr: [HRSample(ts: ts, bpm: 60)]) }

    func testNothingNewMeansNoBatch() async throws {
        let store = try await WhoopStore.inMemory()
        let none = try await store.cutOutboxBatch(deviceId: "my-whoop")
        XCTAssertNil(none)
    }

    func testBatchesClaimOnlyNewRowsInOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 1, bpm: 60), HRSample(ts: 2, bpm: 61)]), deviceId: "my-whoop")
        let a = try await store.cutOutboxBatch(deviceId: "my-whoop")
        XCTAssertEqual(a?.sequence, 1)
        try await store.insert(hr(3), deviceId: "my-whoop")
        let b = try await store.cutOutboxBatch(deviceId: "my-whoop")
        XCTAssertEqual(b?.sequence, 2)
        let cb = try await store.outboxBatch(sequence: 2)
        XCTAssertEqual(cb.streams.hr.map(\.ts), [3])
        let none = try await store.cutOutboxBatch(deviceId: "my-whoop")
        XCTAssertNil(none)
    }

    func testMaxRowsSplitsIntoSeveralBatches() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: (1...5).map { HRSample(ts: $0, bpm: 60) }), deviceId: "my-whoop")
        var seen: [Int] = []
        while let m = try await store.cutOutboxBatch(deviceId: "my-whoop", maxRowsPerTable: 2) {
            seen += try await store.outboxBatch(sequence: m.sequence).streams.hr.map(\.ts)
        }
        XCTAssertEqual(seen, [1, 2, 3, 4, 5])
    }

    func testATableSkippedByOneBatchContinuesWhereItLeftOff() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(hr(1), deviceId: "my-whoop")
        _ = try await store.cutOutboxBatch(deviceId: "my-whoop")                       // hr 1
        try await store.insert(Streams(rr: [RRInterval(ts: 5, rrMs: 800)]), deviceId: "my-whoop")
        _ = try await store.cutOutboxBatch(deviceId: "my-whoop")                       // rr only
        try await store.insert(hr(2), deviceId: "my-whoop")
        let m = try await store.cutOutboxBatch(deviceId: "my-whoop")
        let c = try await store.outboxBatch(sequence: m!.sequence)
        XCTAssertEqual(c.streams.hr.map(\.ts), [2], "hr 1 is not sent twice")
        XCTAssertTrue(c.streams.rr.isEmpty)
    }

    func testRebuildIsIdenticalAndCarriesUndecodedAndEvents() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)],
                                       events: [WhoopEvent(ts: 1, kind: "WRIST_OFF", payload: ["a": .int(1)])],
                                       battery: [BatterySample(ts: 1, soc: 50, mv: 3900, charging: true)],
                                       steps: [StepCounterSample(ts: 1, counter: 9, activity: 1)]), deviceId: "my-whoop")
        try await store.appendSyncUndecoded(["u1", "u2"])
        let m = try await store.cutOutboxBatch(deviceId: "my-whoop")!
        let a = try await store.outboxBatch(sequence: m.sequence)
        let b = try await store.outboxBatch(sequence: m.sequence)
        XCTAssertEqual(a.streams, b.streams)
        XCTAssertEqual(a.undecoded, ["u1", "u2"])
        XCTAssertEqual(a.streams.events.first?.payload["a"], .int(1))
        XCTAssertEqual(a.streams.battery.first?.charging, true)
        XCTAssertEqual(a.streams.steps.count, 1)
    }

    func testOtherDeviceRowsAreLeftOutAndCounted() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(hr(1), deviceId: "my-whoop")
        try await store.insert(hr(2), deviceId: "other")
        let m = try await store.cutOutboxBatch(deviceId: "my-whoop")!
        let c = try await store.outboxBatch(sequence: m.sequence)
        XCTAssertEqual(c.streams.hr.map(\.ts), [1])
        XCTAssertEqual(c.skippedOtherDevice, 1)
    }

    func testDigestIsFixedOnceSet() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(hr(1), deviceId: "my-whoop")
        let m = try await store.cutOutboxBatch(deviceId: "my-whoop")!
        try await store.setOutboxDigest(sequence: m.sequence, digest: "abc")
        try await store.setOutboxDigest(sequence: m.sequence, digest: "abc")
        do { try await store.setOutboxDigest(sequence: m.sequence, digest: "xyz"); XCTFail("expected refusal") }
        catch let e as OutboxError { XCTAssertEqual(e, .digestChanged(sequence: m.sequence)) }
    }

    func testReceiptClearsPendingAndCountsUnbatched() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 1, bpm: 60), HRSample(ts: 2, bpm: 60)]), deviceId: "my-whoop")
        var unbatched = try await store.unbatchedRowCount()
        XCTAssertEqual(unbatched, 2)
        let m = try await store.cutOutboxBatch(deviceId: "my-whoop")!
        unbatched = try await store.unbatchedRowCount()
        XCTAssertEqual(unbatched, 0)
        var pending = try await store.pendingOutboxBatches()
        XCTAssertEqual(pending.map(\.sequence), [m.sequence])
        try await store.recordOutboxReceipt(sequence: m.sequence, receiptJSON: "{}", archive: SyncArchiveRef(archiveId: "a", generation: 1), now: Date(timeIntervalSince1970: 50))
        pending = try await store.pendingOutboxBatches()
        XCTAssertTrue(pending.isEmpty)
        let last = try await store.lastOutboxReceiptAt()
        XCTAssertEqual(last, 50)
    }

    func testSequenceAndSourceSurviveReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("phone.sqlite").path
        var source = ""
        do {
            let store = try await WhoopStore(path: path)
            source = try await store.syncSourceId()
            try await store.insert(hr(1), deviceId: "my-whoop")
            _ = try await store.cutOutboxBatch(deviceId: "my-whoop")
        }
        let reopened = try await WhoopStore(path: path)
        let again = try await reopened.syncSourceId()
        XCTAssertEqual(again, source)
        try await reopened.insert(hr(2), deviceId: "my-whoop")
        let m = try await reopened.cutOutboxBatch(deviceId: "my-whoop")
        XCTAssertEqual(m?.sequence, 2)
        let c = try await reopened.outboxBatch(sequence: 2)
        XCTAssertEqual(c.streams.hr.map(\.ts), [2])
    }
}
