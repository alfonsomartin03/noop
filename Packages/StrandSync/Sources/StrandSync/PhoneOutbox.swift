import Foundation
import WhoopStore

/// How the phone reaches the Mac. The real local-network transport is #79; tests use `InMemoryTransport`.
public protocol SyncTransport {
    /// Sends one sealed envelope and returns the Mac's encoded `SyncReceipt`. Throws if no reply arrived.
    func send(_ envelope: Data) async throws -> Data
}

/// Phone side of one sync pass (#77): resend pending batches oldest first, then cut new ones, and keep a batch pending
/// until a receipt that confirms exactly what was sent is stored. Deleting receipted rows is #81 and is not done here.
public struct PhoneOutbox {
    public struct Status: Equatable, Sendable {
        public let pendingBatches: Int
        public let unbatchedRows: Int
        public let lastReceiptAt: Int?
    }

    public struct PassResult: Equatable, Sendable {
        public var confirmed: [Int64] = []
        /// Batches sent again because the Mac's archive was restored or replaced (#81).
        public var requeued = 0
        /// Already-deleted batches whose data may now be on neither device (see `PhoneStorage.possiblyLost`).
        public var newlyPossiblyLost = 0
        /// The pass stopped at this batch (no reply, or a reply that didn't confirm it); it stays pending.
        public var stoppedAt: Int64?
    }

    let store: WhoopStore
    let deviceId: String
    let maxRowsPerTable: Int
    /// How long confirmed data stays on the phone before deletion (#81).
    let deletionGrace: TimeInterval

    public init(store: WhoopStore, deviceId: String = "my-whoop", maxRowsPerTable: Int = 20_000,
                deletionGrace: TimeInterval = WhoopStore.defaultDeletionGrace) {
        self.store = store; self.deviceId = deviceId; self.maxRowsPerTable = maxRowsPerTable
        self.deletionGrace = deletionGrace
    }

    /// Deletes the rows of every batch the trusted archive confirmed at least `deletionGrace` ago, one batch per
    /// transaction, then truncates the WAL. Freed pages are reused by new collection (the file stops growing; it is
    /// not shrunk, which would need a full VACUUM during collection). Returns rows deleted.
    @discardableResult
    public func cleanUp(now: Date = Date()) async throws -> Int {
        var rows = 0
        for seq in try await store.deletableOutboxBatches(now: now, grace: deletionGrace) {
            rows += try await store.deleteOutboxBatch(sequence: seq, now: now, grace: deletionGrace) ?? 0
        }
        if rows > 0 { try? await store.checkpointWAL() }
        return rows
    }

    /// The sealed envelope for a batch, rebuilt from its ranges. The digest is stored on first seal and must match later.
    public func envelope(sequence: Int64) async throws -> SyncEnvelope {
        let c = try await store.outboxBatch(sequence: sequence)
        let batch = SyncBatch(batchId: c.meta.batchId, sourceId: c.meta.sourceId, sequence: c.meta.sequence,
                              deviceId: c.meta.deviceId, createdAt: c.meta.createdAt, streams: c.streams,
                              rrSeq: c.rrSeq, undecoded: c.undecoded)
        let env = try SyncEnvelope.seal(batch)
        try await store.setOutboxDigest(sequence: sequence, digest: env.digest)
        return env
    }

    /// One pass: pending batches first (in order), then new batches until nothing is left or a send fails.
    public func sync(over transport: SyncTransport, now: Date = Date()) async throws -> PassResult {
        var result = PassResult()
        var queue = try await store.pendingOutboxBatches().map(\.sequence)
        while true {
            if queue.isEmpty {
                guard let cut = try await store.cutOutboxBatch(deviceId: deviceId, maxRowsPerTable: maxRowsPerTable,
                                                               now: now) else { break }
                queue = [cut.sequence]
            }
            let seq = queue.removeFirst()
            let env = try await envelope(sequence: seq)
            let reply: Data
            do { reply = try await transport.send(try env.encoded()) } catch { result.stoppedAt = seq; break }
            guard let receipt = try? JSONDecoder().decode(SyncReceipt.self, from: reply), receipt.confirms(env) else {
                result.stoppedAt = seq; break
            }
            let outcome = try await store.recordOutboxReceipt(
                sequence: seq, receiptJSON: String(decoding: reply, as: UTF8.self),
                archive: SyncArchiveRef(archiveId: receipt.archiveId, generation: receipt.generation), now: now)
            switch outcome {
            case .stale:
                result.stoppedAt = seq; return result
            case .archiveChanged(let requeued, let lost):
                result.requeued += requeued; result.newlyPossiblyLost += lost
                queue = try await store.pendingOutboxBatches().map(\.sequence).filter { $0 != seq }
            case .recorded: break
            }
            result.confirmed.append(seq)
        }
        return result
    }

    public func status() async throws -> Status {
        let pending = try await store.pendingOutboxBatches()
        return Status(pendingBatches: pending.count, unbatchedRows: try await store.unbatchedRowCount(),
                      lastReceiptAt: try await store.lastOutboxReceiptAt())
    }
}

/// Test/in-process transport straight into a `MacArchiveIngestor`. `dropReplies` simulates a reply lost after the Mac
/// committed; `failSends` simulates the Mac being unreachable.
public final class InMemoryTransport: SyncTransport {
    public let mac: MacArchiveIngestor
    public var dropReplies = 0
    public var failSends = false
    public private(set) var sent = 0

    public init(mac: MacArchiveIngestor) { self.mac = mac }

    struct Unreachable: Error {}
    struct ReplyLost: Error {}

    public func send(_ envelope: Data) async throws -> Data {
        if failSends { throw Unreachable() }
        sent += 1
        let receipt = try await mac.ingest(envelope)
        if dropReplies > 0 { dropReplies -= 1; throw ReplyLost() }
        return try JSONEncoder().encode(receipt)
    }
}
