import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandSync

/// Phone → Mac round trips (#77) over the in-memory transport: everything collected reaches the Mac once, a lost reply
/// or an unreachable Mac leaves batches pending, and only a receipt for exactly what was sent clears one.
final class PhoneOutboxTests: XCTestCase {
    private var phone: WhoopStore!
    private var mac: WhoopStore!
    private var undecodedOnMac: [String] = []

    override func setUp() async throws {
        phone = try await WhoopStore.inMemory()
        mac = try await WhoopStore.inMemory()
        undecodedOnMac = []
    }

    private func transport() -> InMemoryTransport {
        InMemoryTransport(mac: MacArchiveIngestor(store: mac) { [unowned self] lines, _ in self.undecodedOnMac += lines })
    }

    private func collect(_ hr: ClosedRange<Int>, rr: [RRInterval] = []) async throws {
        try await phone.insert(Streams(hr: hr.map { HRSample(ts: $0, bpm: 60) }, rr: rr), deviceId: "my-whoop")
    }

    func testEverythingCollectedReachesTheMacOnce() async throws {
        try await collect(1...10, rr: [RRInterval(ts: 5, rrMs: 460), RRInterval(ts: 5, rrMs: 460)])
        try await phone.appendSyncUndecoded(["u1"])
        let outbox = PhoneOutbox(store: phone, maxRowsPerTable: 4)
        let r = try await outbox.sync(over: transport())
        XCTAssertEqual(r.confirmed, [1, 2, 3])
        XCTAssertNil(r.stoppedAt)
        let counts = try await mac.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 10)
        XCTAssertEqual(counts.rr, 2)
        XCTAssertEqual(undecodedOnMac, ["u1"])
        let status = try await outbox.status()
        XCTAssertEqual(status.pendingBatches, 0)
        XCTAssertEqual(status.unbatchedRows, 0)
    }

    func testSameSecondBeatsSplitAcrossBatchesAreBothKept() async throws {
        try await collect(1...1, rr: [RRInterval(ts: 5, rrMs: 460), RRInterval(ts: 5, rrMs: 460)])
        _ = try await PhoneOutbox(store: phone, maxRowsPerTable: 1).sync(over: transport())
        let rr = try await mac.rrIntervals(deviceId: "my-whoop", from: 0, to: 100, limit: 10)
        XCTAssertEqual(rr.count, 2)
    }

    func testLostReplyKeepsTheBatchPendingAndTheResendIsNotDuplicated() async throws {
        try await collect(1...3)
        let t = transport(); t.dropReplies = 1
        let outbox = PhoneOutbox(store: phone)
        let first = try await outbox.sync(over: t)
        XCTAssertEqual(first.confirmed, [])
        XCTAssertEqual(first.stoppedAt, 1)
        var pending = try await phone.pendingOutboxBatches()
        XCTAssertEqual(pending.count, 1, "the Mac committed, but the phone has no receipt yet")
        let second = try await outbox.sync(over: t)
        XCTAssertEqual(second.confirmed, [1])
        XCTAssertEqual(t.sent, 2, "the same batch was sent again, not a new one")
        pending = try await phone.pendingOutboxBatches()
        XCTAssertTrue(pending.isEmpty)
        let counts = try await mac.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 3)
    }

    func testUnreachableMacLeavesEverythingPendingAndLaterCatchesUp() async throws {
        try await collect(1...3)
        let t = transport(); t.failSends = true
        let outbox = PhoneOutbox(store: phone)
        let away = try await outbox.sync(over: t)
        XCTAssertEqual(away.stoppedAt, 1)
        try await collect(4...6)                        // still collecting while the Mac is away
        t.failSends = false
        let back = try await outbox.sync(over: t)
        XCTAssertEqual(back.confirmed, [1, 2], "the old batch first, then the new rows")
        let counts = try await mac.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 6)
    }

    func testAReceiptForSomethingElseDoesNotClearTheBatch() async throws {
        try await collect(1...2)
        struct WrongReceipt: SyncTransport {
            let mac: MacArchiveIngestor
            func send(_ envelope: Data) async throws -> Data {
                var env = try SyncEnvelope.open(envelope)
                env = try SyncEnvelope.seal(SyncBatch(batchId: "other", sourceId: env.batch.sourceId, sequence: 99,
                                                      deviceId: env.batch.deviceId, createdAt: 0, streams: Streams()))
                return try JSONEncoder().encode(try await mac.ingest(env.encoded()))
            }
        }
        let r = try await PhoneOutbox(store: phone).sync(over: WrongReceipt(mac: MacArchiveIngestor(store: mac) { _, _ in }))
        XCTAssertEqual(r.stoppedAt, 1)
        let pending = try await phone.pendingOutboxBatches()
        XCTAssertEqual(pending.count, 1)
    }

    func testABatchCutBeforeACrashIsSentWithTheSameContents() async throws {
        try await collect(1...3)
        let cut = try await phone.cutOutboxBatch(deviceId: "my-whoop")!   // the app died right after this
        let outbox = PhoneOutbox(store: phone)
        let sealedOnce = try await outbox.envelope(sequence: cut.sequence)
        let r = try await outbox.sync(over: transport())
        XCTAssertEqual(r.confirmed, [cut.sequence])
        let receipt = try await mac.syncReceipt(batchId: cut.batchId)
        XCTAssertEqual(receipt?.digest, sealedOnce.digest)
    }
}
