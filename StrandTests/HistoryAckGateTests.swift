import XCTest
@testable import NOOP

/// #38: which HISTORY_END frames of a pull may be acknowledged. Sequences mirror `commitWhoop5HistoryChunk`:
/// `begin` when an END arrives, `refuse` on an archive/store failure, `finish` when the slot holder's save ends,
/// `mayAck` right before the ack write.
final class HistoryAckGateTests: XCTestCase {
    func testOrdinaryChunksAreEachAcked() {
        var g = HistoryAckGate()
        for _ in 0..<3 {
            XCTAssertTrue(g.begin(session: 1))
            XCTAssertTrue(g.mayAck(session: 1))
            g.finish(session: 1)
        }
    }

    /// The review case: the archive write fails, and the strap repeats END before the async stop has run.
    func testRepeatedEndAfterArchiveFailureIsNeverAcked() {
        var g = HistoryAckGate()
        let first = g.begin(session: 7)
        XCTAssertTrue(first)
        g.refuse(session: 7)                 // archive failure, recorded synchronously
        g.finish(session: 7)
        // The pull's stop task has not run yet; the strap repeats END with the same end_data (empty chunk).
        XCTAssertFalse(g.begin(session: 7), "repeat END must not take the ack slot")
        XCTAssertFalse(g.mayAck(session: 7))
        XCTAssertFalse(g.begin(session: 7), "nor any later END in this pull")
    }

    /// A repeat END while the first END's save is still awaited is never acked, even if the repeat saves first.
    func testRepeatWhileSavingIsNotAckedAndStoreFailureBlocksTheRest() {
        var g = HistoryAckGate()
        XCTAssertTrue(g.begin(session: 3))   // END 1: save in flight
        XCTAssertFalse(g.begin(session: 3))  // repeat END: saved only
        g.refuse(session: 3)                 // END 1's save fails (store unavailable)
        g.finish(session: 3)
        XCTAssertFalse(g.mayAck(session: 3))
        XCTAssertFalse(g.begin(session: 3))
    }

    func testRepeatWhileSavingThenFirstSucceeds() {
        var g = HistoryAckGate()
        XCTAssertTrue(g.begin(session: 4))
        XCTAssertFalse(g.begin(session: 4))  // repeat: never acked
        XCTAssertTrue(g.mayAck(session: 4))  // END 1 saved → its ack goes out
        g.finish(session: 4)
        XCTAssertTrue(g.begin(session: 4), "the next real chunk proceeds")
    }

    func testNewPullClearsRefusalAndStaleSessionNeverAcks() {
        var g = HistoryAckGate()
        XCTAssertTrue(g.begin(session: 5))
        g.refuse(session: 5)
        XCTAssertTrue(g.begin(session: 6), "next pull starts clean")
        XCTAssertFalse(g.mayAck(session: 5), "a late task of the old pull never acks")
        XCTAssertTrue(g.mayAck(session: 6))
        g.finish(session: 5)                 // late finish from the old pull does not free the new slot
        XCTAssertFalse(g.begin(session: 6))
    }
}
