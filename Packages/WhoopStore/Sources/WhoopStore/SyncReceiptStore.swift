import Foundation
import GRDB
import WhoopProtocol

// SyncReceiptStore.swift — the Mac side of phone → Mac sync (#77, migration v20).
//
// A batch's rows and its receipt are written in ONE transaction: either the Mac has the data and a receipt, or neither.
// Replaying a batch the Mac already archived returns the stored receipt and writes nothing. A different batch claiming
// an archived batch's id or (source, sequence) is refused before any write. The archive identity (id + generation)
// is stamped on every receipt; a restore bumps the generation so older receipts no longer allow phone deletion.

public struct SyncReceiptRow: Equatable, Codable, Sendable {
    public let batchId: String
    public let sourceId: String
    public let sequence: Int64
    public let digest: String
    public let archiveId: String
    public let generation: Int
    public let committedAt: Int
    public init(batchId: String, sourceId: String, sequence: Int64, digest: String,
                archiveId: String, generation: Int, committedAt: Int) {
        self.batchId = batchId; self.sourceId = sourceId; self.sequence = sequence; self.digest = digest
        self.archiveId = archiveId; self.generation = generation; self.committedAt = committedAt
    }
}

public struct SyncArchiveIdentity: Equatable, Codable, Sendable {
    public let archiveId: String
    public let generation: Int
}

public enum SyncIngestResult: Equatable, Sendable {
    /// Newly archived; `inserted` = rows actually written (rows already present are skipped, never duplicated).
    case committed(SyncReceiptRow, inserted: Int)
    /// Already archived earlier; nothing written. The stored receipt is returned so a lost reply can be answered.
    case duplicate(SyncReceiptRow)
    public var receipt: SyncReceiptRow {
        switch self { case .committed(let r, _), .duplicate(let r): return r }
    }
}

public enum SyncIngestError: Error, Equatable {
    /// The batch id is archived with different contents.
    case digestMismatch(batchId: String)
    /// Another batch already holds this (source, sequence).
    case sequenceTaken(sourceId: String, sequence: Int64, byBatch: String)
}

extension WhoopStore {
    /// This database's archive identity, created on first use.
    public func syncArchiveIdentity() async throws -> SyncArchiveIdentity {
        try syncWrite { db in try Self.archiveIdentity(db) }
    }

    /// After restoring this archive from a backup: receipts issued before now no longer count.
    @discardableResult
    public func bumpSyncArchiveGeneration() async throws -> SyncArchiveIdentity {
        try syncWrite { db in
            // Time-based so a restore of an OLDER backup (with a lower stored generation) still moves forward.
            let current = try Self.archiveIdentity(db)
            let next = max(current.generation + 1, Int(Date().timeIntervalSince1970))
            try db.execute(sql: "UPDATE syncArchive SET generation = ? WHERE id = 1", arguments: [next])
            return SyncArchiveIdentity(archiveId: current.archiveId, generation: next)
        }
    }

    public func syncReceipt(batchId: String) async throws -> SyncReceiptRow? {
        try syncRead { db in try Self.receipt(db, batchId: batchId) }
    }

    /// Archives one phone batch and its receipt atomically. See the file header for the rules.
    public func ingestSyncBatch(batchId: String, sourceId: String, sequence: Int64, digest: String,
                                deviceId: String, streams: Streams, rrSeq: [Int]? = nil,
                                now: Date = Date()) async throws -> SyncIngestResult {
        try ingestSyncBatch(batchId: batchId, sourceId: sourceId, sequence: sequence, digest: digest,
                            deviceId: deviceId, streams: streams, rrSeq: rrSeq, now: now, beforeReceipt: nil)
    }

    /// `beforeReceipt` runs inside the transaction after the rows are written (tests use it to fail mid-way).
    func ingestSyncBatch(batchId: String, sourceId: String, sequence: Int64, digest: String, deviceId: String,
                         streams: Streams, rrSeq: [Int]? = nil, now: Date,
                         beforeReceipt: (() throws -> Void)?) throws -> SyncIngestResult {
        try syncWrite { db in
            if let existing = try Self.receipt(db, batchId: batchId) {
                guard existing.digest == digest else { throw SyncIngestError.digestMismatch(batchId: batchId) }
                // A receipt from before a restore (#81): its rows were restored with it (same transaction), so this
                // archive does hold the batch; re-stamp it with the current identity so the phone can trust it.
                let id = try Self.archiveIdentity(db)
                guard existing.archiveId != id.archiveId || existing.generation != id.generation else { return .duplicate(existing) }
                try db.execute(sql: "UPDATE syncReceipt SET archiveId = ?, generation = ? WHERE batchId = ?",
                               arguments: [id.archiveId, id.generation, batchId])
                return .duplicate(try Self.receipt(db, batchId: batchId)!)
            }
            if let other = try String.fetchOne(db, sql: "SELECT batchId FROM syncReceipt WHERE sourceId = ? AND sequence = ?",
                                               arguments: [sourceId, sequence]) {
                throw SyncIngestError.sequenceTaken(sourceId: sourceId, sequence: sequence, byBatch: other)
            }
            let before = db.totalChangesCount
            if let rrSeq, rrSeq.count == streams.rr.count, !streams.rr.isEmpty {
                // The sender knows each beat's position within its second: store exactly that (a second's beats may
                // be split across batches, and value-based alignment would merge two identical beats).
                var rest = streams; rest.rr = []
                _ = try Self.insertRows(rest, deviceId: deviceId, db: db)
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, seq, rrMs) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, seq, rrMs) DO NOTHING
                    """)
                for (beat, seq) in zip(streams.rr, rrSeq) {
                    try stmt.execute(arguments: [deviceId, beat.ts, seq, beat.rrMs])
                }
            } else {
                _ = try Self.insertRows(streams, deviceId: deviceId, db: db)
            }
            let inserted = db.totalChangesCount - before
            try beforeReceipt?()
            let id = try Self.archiveIdentity(db)
            let row = SyncReceiptRow(batchId: batchId, sourceId: sourceId, sequence: sequence, digest: digest,
                                     archiveId: id.archiveId, generation: id.generation,
                                     committedAt: Int(now.timeIntervalSince1970))
            try db.execute(sql: """
                INSERT INTO syncReceipt (batchId, sourceId, sequence, digest, archiveId, generation, committedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [row.batchId, row.sourceId, row.sequence, row.digest, row.archiveId, row.generation,
                                 row.committedAt])
            return .committed(row, inserted: inserted)
        }
    }

    static func archiveIdentity(_ db: Database) throws -> SyncArchiveIdentity {
        if let row = try Row.fetchOne(db, sql: "SELECT archiveId, generation FROM syncArchive WHERE id = 1") {
            return SyncArchiveIdentity(archiveId: row["archiveId"], generation: row["generation"])
        }
        let fresh = SyncArchiveIdentity(archiveId: UUID().uuidString, generation: 1)
        try db.execute(sql: "INSERT INTO syncArchive (id, archiveId, generation) VALUES (1, ?, ?)",
                       arguments: [fresh.archiveId, fresh.generation])
        return fresh
    }

    static func receipt(_ db: Database, batchId: String) throws -> SyncReceiptRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM syncReceipt WHERE batchId = ?", arguments: [batchId]).map {
            SyncReceiptRow(batchId: $0["batchId"], sourceId: $0["sourceId"], sequence: $0["sequence"],
                           digest: $0["digest"], archiveId: $0["archiveId"], generation: $0["generation"],
                           committedAt: $0["committedAt"])
        }
    }
}
