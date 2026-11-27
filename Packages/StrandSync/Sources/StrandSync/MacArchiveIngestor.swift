import Foundation
import WhoopStore
import WhoopProtocol

/// What the Mac sends back for a batch it has durably archived. The phone may delete the batch only after it holds a
/// receipt whose `batchId` and `digest` match what it sent and whose archive identity it trusts (#81).
public struct SyncReceipt: Equatable, Codable, Sendable {
    public let batchId: String
    public let sourceId: String
    public let sequence: Int64
    public let digest: String
    public let archiveId: String
    public let generation: Int
    public let committedAt: Int
    /// false when this batch had already been archived (a replay after a lost reply).
    public let newlyArchived: Bool

    init(_ row: SyncReceiptRow, newlyArchived: Bool) {
        batchId = row.batchId; sourceId = row.sourceId; sequence = row.sequence; digest = row.digest
        archiveId = row.archiveId; generation = row.generation; committedAt = row.committedAt
        self.newlyArchived = newlyArchived
    }

    /// True when this receipt confirms exactly `envelope`.
    public func confirms(_ envelope: SyncEnvelope) -> Bool {
        batchId == envelope.batch.batchId && digest == envelope.digest
            && sourceId == envelope.batch.sourceId && sequence == envelope.batch.sequence
    }
}

/// Mac side of one upload: check the envelope, archive undecoded lines first, then rows + receipt in one transaction,
/// then answer. Undecoded lines go through `rawSink` (the app's fsync'ed `RawHistoryArchive`); a failure there stops
/// before any database write. A crash between the two leaves at most duplicate undecoded lines, which the retry
/// re-sends and readers tolerate; it never leaves rows without a receipt or a receipt without rows.
public struct MacArchiveIngestor {
    public typealias RawSink = (_ lines: [String], _ batch: SyncBatch) throws -> Void
    let store: WhoopStore
    let rawSink: RawSink

    public init(store: WhoopStore, rawSink: @escaping RawSink) {
        self.store = store; self.rawSink = rawSink
    }

    public func ingest(_ data: Data, now: Date = Date()) async throws -> SyncReceipt {
        let env = try SyncEnvelope.open(data)
        let b = env.batch
        if let existing = try await store.syncReceipt(batchId: b.batchId) {
            // Replay after a lost reply (or to a restored archive): write no rows or undecoded lines; the store answers
            // from the stored receipt, re-stamped with the current archive identity if it predates a restore (#81).
            guard existing.digest == env.digest else { throw SyncIngestError.digestMismatch(batchId: b.batchId) }
            let r = try await store.ingestSyncBatch(batchId: b.batchId, sourceId: b.sourceId, sequence: b.sequence,
                                                    digest: env.digest, deviceId: b.deviceId, streams: Streams(), now: now)
            return SyncReceipt(r.receipt, newlyArchived: false)
        }
        if !b.undecoded.isEmpty { try rawSink(b.undecoded, b) }
        let result = try await store.ingestSyncBatch(batchId: b.batchId, sourceId: b.sourceId, sequence: b.sequence,
                                                     digest: env.digest, deviceId: b.deviceId, streams: b.streams,
                                                     rrSeq: b.rrSeq.isEmpty ? nil : b.rrSeq, now: now)
        switch result {
        case .committed(let row, _): return SyncReceipt(row, newlyArchived: true)
        case .duplicate(let row): return SyncReceipt(row, newlyArchived: false)
        }
    }
}
