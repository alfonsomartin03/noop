import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Mac side of phone → Mac sync (#77): rows and receipt in one transaction, idempotent replay, refusals before writes.
final class SyncReceiptTests: XCTestCase {
    private let streams = Streams(hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 101, bpm: 61)],
                                  rr: [RRInterval(ts: 100, rrMs: 460), RRInterval(ts: 100, rrMs: 460)],
                                  steps: [StepCounterSample(ts: 100, counter: 5, activity: 1)])

    private func ingest(_ store: WhoopStore, batch: String = "b1", seq: Int64 = 1, digest: String = "d1",
                        streams s: Streams? = nil) async throws -> SyncIngestResult {
        try await store.ingestSyncBatch(batchId: batch, sourceId: "phone", sequence: seq, digest: digest,
                                        deviceId: "my-whoop", streams: s ?? streams, now: Date(timeIntervalSince1970: 1_000))
    }

    func testCommitWritesRowsAndReceiptWithArchiveIdentity() async throws {
        let store = try await WhoopStore.inMemory()
        let r = try await ingest(store)
        guard case .committed(let receipt, let inserted) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(inserted, 5, "2 HR + 2 same-second R–R + 1 step")
        let id = try await store.syncArchiveIdentity()
        XCTAssertEqual(receipt.archiveId, id.archiveId)
        XCTAssertEqual(receipt.generation, 1)
        XCTAssertEqual(receipt.committedAt, 1_000)
        let stored = try await store.syncReceipt(batchId: "b1")
        XCTAssertEqual(stored, receipt)
        let rr = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(rr.count, 2, "two identical beats in one second are both kept")
    }

    func testReplayReturnsTheStoredReceiptAndWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let first = try await ingest(store)
        let again = try await ingest(store)
        XCTAssertEqual(again, .duplicate(first.receipt))
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 2); XCTAssertEqual(counts.rr, 2)
    }

    func testSameBatchIdWithDifferentContentsIsRefused() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await ingest(store)
        do {
            _ = try await ingest(store, digest: "other", streams: Streams(hr: [HRSample(ts: 500, bpm: 90)]))
            XCTFail("expected refusal")
        } catch let e as SyncIngestError { XCTAssertEqual(e, .digestMismatch(batchId: "b1")) }
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 2, "nothing from the refused batch was written")
    }

    func testTakenSequenceIsRefusedBeforeAnyWrite() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await ingest(store)
        do {
            _ = try await ingest(store, batch: "b2", digest: "d2", streams: Streams(hr: [HRSample(ts: 500, bpm: 90)]))
            XCTFail("expected refusal")
        } catch let e as SyncIngestError { XCTAssertEqual(e, .sequenceTaken(sourceId: "phone", sequence: 1, byBatch: "b1")) }
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 2)
    }

    func testFailureBeforeTheReceiptRollsBackTheRows() async throws {
        let store = try await WhoopStore.inMemory()
        struct Boom: Error {}
        do {
            _ = try await store.ingestSyncBatch(batchId: "b1", sourceId: "phone", sequence: 1, digest: "d1",
                                                deviceId: "my-whoop", streams: streams, now: Date(),
                                                beforeReceipt: { throw Boom() })
            XCTFail("expected the injected failure")
        } catch is Boom {}
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 0); XCTAssertEqual(counts.rr, 0)
        let receipt = try await store.syncReceipt(batchId: "b1")
        XCTAssertNil(receipt)
        // The retry then commits normally.
        let retry = try await ingest(store)
        guard case .committed = retry else { return XCTFail("\(retry)") }
    }

    func testOverlapWithRowsAlreadyOnTheMacIsNotDuplicated() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "my-whoop")
        let r = try await ingest(store)
        guard case .committed(_, let inserted) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(inserted, 4, "the HR second the Mac already had is skipped")
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 2)
    }

    func testGenerationBumpStampsLaterReceipts() async throws {
        let store = try await WhoopStore.inMemory()
        let first = try await ingest(store).receipt
        let bumped = try await store.bumpSyncArchiveGeneration()
        XCTAssertEqual(bumped.generation, 2)
        XCTAssertEqual(bumped.archiveId, first.archiveId)
        let second = try await ingest(store, batch: "b2", seq: 2, digest: "d2",
                                      streams: Streams(hr: [HRSample(ts: 300, bpm: 70)])).receipt
        XCTAssertEqual(second.generation, 2)
    }
}
