import Foundation
import GRDB

// PhoneCleanupStore.swift — deleting phone data once the Mac has it (#81, migration v23).
//
// Rules:
// - A batch's rows are deleted only when its receipt comes from the archive the phone trusts now (id AND generation)
//   and a grace period has passed since the receipt (so a Mac restore soon after still finds the data on the phone).
// - When a receipt shows a newer generation or another archive (the Mac was restored or replaced), every batch still on
//   the phone that was confirmed by the old one goes back to pending and is sent again; batches already deleted under
//   the old one are flagged `possiblyLost` with their time span, for the user to check.
// - A stale receipt (older generation of the current archive) is not recorded: the batch stays pending.
// - Each table keeps its highest-rowid row, so SQLite never reuses rowids below what the outbox already claimed.
// - Deleting a batch is one transaction; a crash leaves it either whole or not deleted.

public struct SyncArchiveRef: Equatable, Sendable {
    public let archiveId: String
    public let generation: Int
    public init(archiveId: String, generation: Int) { self.archiveId = archiveId; self.generation = generation }
}

public enum OutboxReceiptOutcome: Equatable, Sendable {
    case recorded
    /// The receipt came from a newer generation or another archive; this many batches went back to pending.
    case archiveChanged(requeued: Int, newlyPossiblyLost: Int)
    /// From an older generation than the phone already trusts: not recorded, the batch stays pending.
    case stale
}

public struct PhoneStorage: Equatable, Sendable {
    public let databaseBytes: Int
    public let reusableBytes: Int
    public let pendingBatches: Int
    public let waitingToDelete: Int
    public let deletedBatches: Int
    public let lastReceiptAt: Int?
    /// Time spans (unix seconds) deleted from the phone after being confirmed by an archive that was later restored
    /// or replaced: they may exist on neither device.
    public let possiblyLost: [ClosedRange<Int>]
}

extension WhoopStore {
    public static let defaultDeletionGrace: TimeInterval = 48 * 3600

    public func currentSyncArchive() async throws -> SyncArchiveRef? {
        try syncRead { db in try Self.currentArchive(db) }
    }

    /// Records a receipt already checked against the batch it confirms. See the rules above.
    @discardableResult
    public func recordOutboxReceipt(sequence: Int64, receiptJSON: String, archive: SyncArchiveRef,
                                    now: Date = Date()) async throws -> OutboxReceiptOutcome {
        try syncWrite { db in
            let current = try Self.currentArchive(db)
            if let c = current, c.archiveId == archive.archiveId, archive.generation < c.generation { return .stale }
            var outcome = OutboxReceiptOutcome.recorded
            if current != archive {
                try db.execute(sql: """
                    INSERT INTO syncCurrentArchive (id, archiveId, generation) VALUES (1, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET archiveId = excluded.archiveId, generation = excluded.generation
                    """, arguments: [archive.archiveId, archive.generation])
                if current != nil {
                    try db.execute(sql: """
                        UPDATE syncOutbox SET receiptJSON = NULL, receiptedAt = NULL, receiptArchiveId = NULL,
                               receiptGeneration = NULL
                        WHERE deletedAt IS NULL AND receiptedAt IS NOT NULL AND sequence != ?
                          AND (receiptArchiveId IS NOT ? OR receiptGeneration IS NOT ?)
                        """, arguments: [sequence, archive.archiveId, archive.generation])
                    let requeued = db.changesCount
                    try db.execute(sql: """
                        UPDATE syncOutbox SET possiblyLost = 1
                        WHERE deletedAt IS NOT NULL AND possiblyLost = 0
                          AND (receiptArchiveId IS NOT ? OR receiptGeneration IS NOT ?)
                        """, arguments: [archive.archiveId, archive.generation])
                    outcome = .archiveChanged(requeued: requeued, newlyPossiblyLost: db.changesCount)
                }
            }
            try db.execute(sql: """
                UPDATE syncOutbox SET receiptJSON = ?, receiptedAt = ?, receiptArchiveId = ?, receiptGeneration = ?
                WHERE sequence = ? AND deletedAt IS NULL
                """, arguments: [receiptJSON, Int(now.timeIntervalSince1970), archive.archiveId, archive.generation,
                                 sequence])
            return outcome
        }
    }

    /// Batches whose rows may be deleted now.
    public func deletableOutboxBatches(now: Date = Date(), grace: TimeInterval = WhoopStore.defaultDeletionGrace)
        async throws -> [Int64] {
        try syncRead { db in
            guard let c = try Self.currentArchive(db) else { return [] }
            return try Int64.fetchAll(db, sql: """
                SELECT sequence FROM syncOutbox
                WHERE deletedAt IS NULL AND receiptedAt IS NOT NULL AND receiptedAt <= ?
                  AND receiptArchiveId = ? AND receiptGeneration = ?
                ORDER BY sequence
                """, arguments: [Int(now.timeIntervalSince1970 - grace), c.archiveId, c.generation])
        }
    }

    /// Deletes one confirmed batch's rows in a single transaction (eligibility re-checked inside). Returns rows deleted,
    /// or nil when the batch is not deletable (any more).
    @discardableResult
    public func deleteOutboxBatch(sequence: Int64, now: Date = Date(),
                                  grace: TimeInterval = WhoopStore.defaultDeletionGrace) async throws -> Int? {
        try syncWrite { db in
            guard let c = try Self.currentArchive(db),
                  let row = try Row.fetchOne(db, sql: """
                      SELECT * FROM syncOutbox WHERE sequence = ? AND deletedAt IS NULL AND receiptedAt IS NOT NULL
                        AND receiptedAt <= ? AND receiptArchiveId = ? AND receiptGeneration = ?
                      """, arguments: [sequence, Int(now.timeIntervalSince1970 - grace), c.archiveId, c.generation])
            else { return nil }
            let meta = try Self.meta(row)
            var lo: Int?, hi: Int?, deleted = 0
            for (table, r) in meta.ranges {
                if table == "syncUndecoded" {
                    try db.execute(sql: "DELETE FROM syncUndecoded WHERE id BETWEEN ? AND ?", arguments: [r.lo, r.hi])
                    deleted += db.changesCount
                    continue
                }
                let span = try Row.fetchOne(db, sql: """
                    SELECT MIN(ts) AS a, MAX(ts) AS b FROM \(table) WHERE rowid BETWEEN ? AND ? AND deviceId = ?
                    """, arguments: [r.lo, r.hi, meta.deviceId])
                if let a: Int = span?["a"] { lo = min(lo ?? a, a) }
                if let b: Int = span?["b"] { hi = max(hi ?? b, b) }
                // Keep the table's newest row so rowids stay above everything the outbox has claimed.
                try db.execute(sql: """
                    DELETE FROM \(table) WHERE rowid BETWEEN ? AND ? AND deviceId = ?
                      AND rowid < (SELECT MAX(rowid) FROM \(table))
                    """, arguments: [r.lo, r.hi, meta.deviceId])
                deleted += db.changesCount
            }
            try db.execute(sql: "UPDATE syncOutbox SET deletedAt = ?, tsLo = ?, tsHi = ? WHERE sequence = ?",
                           arguments: [Int(now.timeIntervalSince1970), lo, hi, sequence])
            return deleted
        }
    }

    public func phoneStorage(now: Date = Date(), grace: TimeInterval = WhoopStore.defaultDeletionGrace)
        async throws -> PhoneStorage {
        try syncRead { db in
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let waiting = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM syncOutbox WHERE deletedAt IS NULL AND receiptedAt IS NOT NULL
                """) ?? 0
            return PhoneStorage(
                databaseBytes: pages * pageSize, reusableBytes: free * pageSize,
                pendingBatches: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOutbox WHERE receiptedAt IS NULL") ?? 0,
                waitingToDelete: waiting,
                deletedBatches: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncOutbox WHERE deletedAt IS NOT NULL") ?? 0,
                lastReceiptAt: try Int.fetchOne(db, sql: "SELECT MAX(receiptedAt) FROM syncOutbox"),
                possiblyLost: try Row.fetchAll(db, sql: """
                    SELECT tsLo, tsHi FROM syncOutbox WHERE possiblyLost = 1 AND tsLo IS NOT NULL ORDER BY tsLo
                    """).map { ($0["tsLo"] as Int)...($0["tsHi"] as Int) })
        }
    }

    static func currentArchive(_ db: Database) throws -> SyncArchiveRef? {
        try Row.fetchOne(db, sql: "SELECT archiveId, generation FROM syncCurrentArchive WHERE id = 1").map {
            SyncArchiveRef(archiveId: $0["archiveId"], generation: $0["generation"])
        }
    }
}
