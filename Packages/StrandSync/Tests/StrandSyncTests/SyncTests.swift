import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandSync

/// Phone → Mac transfer (#77): envelope checks, Mac ingest order, replay after a lost reply, failure before commit.
final class SyncTests: XCTestCase {
    private func batch(_ seq: Int64 = 1, id: String = "b1", hr: [HRSample] = [HRSample(ts: 100, bpm: 60)],
                       undecoded: [String] = []) -> SyncBatch {
        SyncBatch(batchId: id, sourceId: "phone-1", sequence: seq, deviceId: "my-whoop", createdAt: 1_000,
                  streams: Streams(hr: hr, rr: [RRInterval(ts: 100, rrMs: 460), RRInterval(ts: 100, rrMs: 460)]),
                  undecoded: undecoded)
    }

    final class Sink { var calls: [[String]] = []; var fail = false }
    private func ingestor(_ store: WhoopStore, _ sink: Sink) -> MacArchiveIngestor {
        MacArchiveIngestor(store: store) { lines, _ in
            struct DiskFull: Error {}
            if sink.fail { throw DiskFull() }
            sink.calls.append(lines)
        }
    }

    // MARK: envelope

    func testSealOpenRoundTrip() throws {
        let env = try SyncEnvelope.seal(batch())
        XCTAssertEqual(try SyncEnvelope.open(env.encoded()), env)
        XCTAssertEqual(env.digest.count, 64)
    }

    func testDigestChangesWithContent() throws {
        let a = try SyncEnvelope.digest(of: batch(hr: [HRSample(ts: 100, bpm: 60)]))
        let b = try SyncEnvelope.digest(of: batch(hr: [HRSample(ts: 100, bpm: 61)]))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, try SyncEnvelope.digest(of: batch(hr: [HRSample(ts: 100, bpm: 60)])), "digest is deterministic")
    }

    func testTamperedEnvelopeIsRejected() throws {
        let env = try SyncEnvelope.seal(batch())
        let forged = SyncEnvelope(batch: batch(hr: [HRSample(ts: 100, bpm: 99)]), digest: env.digest)
        XCTAssertThrowsError(try SyncEnvelope.open(forged.encoded())) { XCTAssertEqual($0 as? SyncError, .digestMismatch) }
    }

    func testIncompatibleVersionIsRejectedBeforeDecodingTheRest() throws {
        let json = #"{"batch":{"formatVersion":2,"somethingNew":true},"digest":"x"}"#
        XCTAssertThrowsError(try SyncEnvelope.open(Data(json.utf8))) {
            XCTAssertEqual($0 as? SyncError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try SyncEnvelope.open(Data("not json".utf8))) { XCTAssertEqual($0 as? SyncError, .unreadable) }
    }

    // MARK: Mac ingest

    func testIngestArchivesUndecodedFirstThenRowsAndReceipt() async throws {
        let store = try await WhoopStore.inMemory(); let sink = Sink()
        let env = try SyncEnvelope.seal(batch(undecoded: [#"{"line":1}"#]))
        let receipt = try await ingestor(store, sink).ingest(env.encoded())
        XCTAssertTrue(receipt.newlyArchived)
        XCTAssertTrue(receipt.confirms(env))
        XCTAssertEqual(sink.calls, [[#"{"line":1}"#]])
        let rr = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: 1000, limit: 10)
        XCTAssertEqual(rr.count, 2, "same-second beats survive the transfer")
    }

    func testReplayAfterLostReplyAnswersWithoutWriting() async throws {
        let store = try await WhoopStore.inMemory(); let sink = Sink()
        let data = try SyncEnvelope.seal(batch(undecoded: ["u"])).encoded()
        let first = try await ingestor(store, sink).ingest(data)
        let again = try await ingestor(store, sink).ingest(data)   // the phone never saw `first`
        XCTAssertFalse(again.newlyArchived)
        XCTAssertEqual(again.committedAt, first.committedAt)
        XCTAssertEqual(sink.calls.count, 1, "undecoded lines are not archived twice")
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 1)
    }

    func testRawArchiveFailureWritesNoRowsAndRetrySucceeds() async throws {
        let store = try await WhoopStore.inMemory(); let sink = Sink(); sink.fail = true
        let data = try SyncEnvelope.seal(batch(undecoded: ["u"])).encoded()
        do { _ = try await ingestor(store, sink).ingest(data); XCTFail("expected failure") } catch {}
        var counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 0)
        let none = try await store.syncReceipt(batchId: "b1")
        XCTAssertNil(none)
        sink.fail = false
        let receipt = try await ingestor(store, sink).ingest(data)
        XCTAssertTrue(receipt.newlyArchived)
        counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 1)
    }

    func testOutOfOrderAndLateBatchesEachArchiveOnce() async throws {
        let store = try await WhoopStore.inMemory(); let sink = Sink()
        let late = try SyncEnvelope.seal(batch(2, id: "b2", hr: [HRSample(ts: 50, bpm: 55)]))   // older data, newer sequence
        let early = try SyncEnvelope.seal(batch(1, id: "b1"))
        _ = try await ingestor(store, sink).ingest(late.encoded())
        _ = try await ingestor(store, sink).ingest(early.encoded())
        _ = try await ingestor(store, sink).ingest(late.encoded())
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 2)
        XCTAssertEqual(counts.rr, 2, "the same beats in two batches are stored once")
    }

    func testReceiptDoesNotConfirmADifferentBatch() async throws {
        let store = try await WhoopStore.inMemory()
        let env = try SyncEnvelope.seal(batch())
        let receipt = try await ingestor(store, Sink()).ingest(env.encoded())
        let other = try SyncEnvelope.seal(batch(2, id: "b2"))
        XCTAssertFalse(receipt.confirms(other))
    }

    func testReceiptCarriesArchiveGeneration() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.bumpSyncArchiveGeneration()
        let receipt = try await ingestor(store, Sink()).ingest(try SyncEnvelope.seal(batch()).encoded())
        let id = try await store.syncArchiveIdentity()
        XCTAssertEqual(receipt.archiveId, id.archiveId)
        XCTAssertEqual(receipt.generation, 2)
    }
}
