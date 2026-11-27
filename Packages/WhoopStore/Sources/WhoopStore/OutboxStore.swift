import Foundation
import GRDB
import WhoopProtocol

// OutboxStore.swift — the phone side of phone → Mac sync (#77, migration v21).
//
// The phone keeps collected rows in the normal stream tables. `cutOutboxBatch` claims the next unbatched rows of each
// table (by rowid, in insertion order) plus pending undecoded lines into a numbered batch and records only the ranges.
// `outboxBatch(sequence:)` rebuilds that batch from the ranges, identically every time, so a crash after the cut loses
// nothing. Sequences are persisted and never reused. Assumes one strap identity per phone store: rows of any other
// deviceId inside a claimed range are left out and reported in `skippedOtherDevice`.

public struct OutboxRange: Equatable, Codable, Sendable {
    public let lo: Int64
    public let hi: Int64
}

public struct OutboxBatchMeta: Equatable, Sendable {
    public let sequence: Int64
    public let batchId: String
    public let sourceId: String
    public let deviceId: String
    public let createdAt: Int
    public let ranges: [String: OutboxRange]
    public let digest: String?
    public let receiptJSON: String?
    public let receiptedAt: Int?
    public var isReceipted: Bool { receiptedAt != nil }
}

public struct OutboxBatchContents {
    public let meta: OutboxBatchMeta
    public let streams: Streams
    public let undecoded: [String]
    /// Position of each `streams.rr` beat within its second, as stored on the phone.
    public let rrSeq: [Int]
    public let skippedOtherDevice: Int
}

public enum OutboxError: Error, Equatable {
    case noSuchBatch(Int64)
    case unreadableEvent(rowid: Int64)
    case digestChanged(sequence: Int64)
}

extension WhoopStore {
    /// Tables that make up a batch, in a fixed order. `syncUndecoded` holds undecoded-history lines.
    static let outboxTables = ["hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
                               "event", "battery", "stepCounterSample", "syncUndecoded"]

    /// This phone's stable source identity, created on first use.
    public func syncSourceId() async throws -> String {
        try syncWrite { db in try Self.sourceId(db) }
    }

    /// Keeps undecoded-history lines until the Mac has them (the phone's counterpart of `RawHistoryArchive`).
    public func appendSyncUndecoded(_ lines: [String]) async throws {
        guard !lines.isEmpty else { return }
        try syncWrite { db in
            let stmt = try db.cachedStatement(sql: "INSERT INTO syncUndecoded (line) VALUES (?)")
            for l in lines { try stmt.execute(arguments: [l]) }
        }
    }

    /// Claims up to `maxRowsPerTable` new rows of each table into the next batch. nil when nothing is new.
    public func cutOutboxBatch(deviceId: String, maxRowsPerTable: Int = 20_000,
                               now: Date = Date()) async throws -> OutboxBatchMeta? {
        try syncWrite { db in
            let source = try Self.sourceId(db)
            let last = try Row.fetchOne(db, sql: "SELECT sequence, rangesJSON FROM syncOutbox ORDER BY sequence DESC LIMIT 1")
            let lastRanges: [String: OutboxRange] = try last.map { try Self.decodeRanges($0["rangesJSON"]) } ?? [:]
            var ranges: [String: OutboxRange] = [:]
            for t in Self.outboxTables {
                // Continue after the highest rowid any earlier batch claimed (a table untouched so far starts at 1).
                let start = try Self.claimedHigh(db, table: t, latest: lastRanges[t]) + 1
                guard let hi = try Int64.fetchOne(db, sql: """
                    SELECT MAX(rowid) FROM (SELECT rowid FROM \(t) WHERE rowid >= ? ORDER BY rowid LIMIT ?)
                    """, arguments: [start, maxRowsPerTable]) else { continue }
                ranges[t] = OutboxRange(lo: start, hi: hi)
            }
            guard !ranges.isEmpty else { return nil }
            let seq = (last?["sequence"] as Int64? ?? 0) + 1
            let meta = OutboxBatchMeta(sequence: seq, batchId: UUID().uuidString, sourceId: source, deviceId: deviceId,
                                       createdAt: Int(now.timeIntervalSince1970), ranges: ranges, digest: nil,
                                       receiptJSON: nil, receiptedAt: nil)
            try db.execute(sql: """
                INSERT INTO syncOutbox (sequence, batchId, sourceId, deviceId, createdAt, rangesJSON)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [seq, meta.batchId, source, deviceId, meta.createdAt, try Self.encodeRanges(ranges)])
            return meta
        }
    }

    /// Batches without a receipt, oldest first.
    public func pendingOutboxBatches() async throws -> [OutboxBatchMeta] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM syncOutbox WHERE receiptedAt IS NULL ORDER BY sequence")
                .map(Self.meta)
        }
    }

    public func outboxBatchMeta(sequence: Int64) async throws -> OutboxBatchMeta? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM syncOutbox WHERE sequence = ?", arguments: [sequence]).map(Self.meta)
        }
    }

    /// Rebuilds a batch's contents from its ranges.
    public func outboxBatch(sequence: Int64) async throws -> OutboxBatchContents {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM syncOutbox WHERE sequence = ?", arguments: [sequence])
            else { throw OutboxError.noSuchBatch(sequence) }
            let meta = try Self.meta(row)
            var s = Streams(); var undecoded: [String] = []; var rrSeq: [Int] = []; var skipped = 0
            for (table, r) in meta.ranges {
                let args: StatementArguments = [r.lo, r.hi]
                if table == "syncUndecoded" {
                    undecoded = try String.fetchAll(db, sql: "SELECT line FROM syncUndecoded WHERE id BETWEEN ? AND ? ORDER BY id",
                                                    arguments: args)
                    continue
                }
                skipped += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE rowid BETWEEN ? AND ? AND deviceId != ?",
                                            arguments: [r.lo, r.hi, meta.deviceId]) ?? 0
                let rows = try Row.fetchAll(db, sql: "SELECT rowid AS rid, * FROM \(table) WHERE rowid BETWEEN ? AND ? AND deviceId = ? ORDER BY rowid",
                                            arguments: [r.lo, r.hi, meta.deviceId])
                switch table {
                case "hrSample": s.hr = rows.map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
                case "rrInterval":
                    s.rr = rows.map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
                    rrSeq = rows.map { $0["seq"] }
                case "spo2Sample": s.spo2 = rows.map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
                case "skinTempSample": s.skinTemp = rows.map { SkinTempSample(ts: $0["ts"], raw: $0["raw"], unit: $0["unit"]) }
                case "respSample": s.resp = rows.map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
                case "gravitySample": s.gravity = rows.map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]) }
                case "battery": s.battery = rows.map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"], charging: $0["charging"]) }
                case "stepCounterSample": s.steps = rows.map { StepCounterSample(ts: $0["ts"], counter: $0["counter"], activity: $0["activity"]) }
                case "event":
                    s.events = try rows.map { row in
                        let json: String = row["payloadJSON"]
                        // Strict: a payload that cannot be read must not travel as an empty one.
                        guard let payload = try? JSONDecoder().decode([String: ParsedValue].self, from: Data(json.utf8))
                        else { throw OutboxError.unreadableEvent(rowid: row["rid"]) }
                        return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                    }
                default: break
                }
            }
            return OutboxBatchContents(meta: meta, streams: s, undecoded: undecoded, rrSeq: rrSeq, skippedOtherDevice: skipped)
        }
    }

    /// Records the digest computed for a batch. A second call must give the same digest (rebuilds are identical).
    public func setOutboxDigest(sequence: Int64, digest: String) async throws {
        try syncWrite { db in
            guard let existing = try Row.fetchOne(db, sql: "SELECT digest FROM syncOutbox WHERE sequence = ?", arguments: [sequence])
            else { throw OutboxError.noSuchBatch(sequence) }
            if let d: String = existing["digest"] {
                guard d == digest else { throw OutboxError.digestChanged(sequence: sequence) }
                return
            }
            try db.execute(sql: "UPDATE syncOutbox SET digest = ? WHERE sequence = ?", arguments: [digest, sequence])
        }
    }

    /// Stores the Mac's receipt (already checked by the caller against the batch it sent). Idempotent.
    public func recordOutboxReceipt(sequence: Int64, receiptJSON: String, now: Date = Date()) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE syncOutbox SET receiptJSON = ?, receiptedAt = ? WHERE sequence = ? AND receiptedAt IS NULL
                """, arguments: [receiptJSON, Int(now.timeIntervalSince1970), sequence])
        }
    }

    /// Rows collected but not yet claimed by any batch (for "pending" status), per table.
    public func unbatchedRowCount() async throws -> Int {
        try syncRead { db in
            let last = try Row.fetchOne(db, sql: "SELECT rangesJSON FROM syncOutbox ORDER BY sequence DESC LIMIT 1")
            let lastRanges: [String: OutboxRange] = try last.map { try Self.decodeRanges($0["rangesJSON"]) } ?? [:]
            var n = 0
            for t in Self.outboxTables {
                let start = try Self.claimedHigh(db, table: t, latest: lastRanges[t]) + 1
                n += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t) WHERE rowid >= ?", arguments: [start]) ?? 0
            }
            return n
        }
    }

    // MARK: helpers

    static func sourceId(_ db: Database) throws -> String {
        if let s = try String.fetchOne(db, sql: "SELECT sourceId FROM syncSource WHERE id = 1") { return s }
        let s = UUID().uuidString
        try db.execute(sql: "INSERT INTO syncSource (id, sourceId) VALUES (1, ?)", arguments: [s])
        return s
    }

    /// Highest rowid of `table` claimed by any batch. A batch may skip a table with no new rows, so the latest batch
    /// alone is not enough; fall back to scanning earlier batches only when the latest has no range for this table.
    static func claimedHigh(_ db: Database, table: String, latest: OutboxRange?) throws -> Int64 {
        if let latest { return latest.hi }
        var best: Int64 = 0
        for json in try String.fetchAll(db, sql: "SELECT rangesJSON FROM syncOutbox ORDER BY sequence DESC") {
            if let r = try decodeRanges(json)[table] { best = r.hi; break }
        }
        return best
    }

    static func encodeRanges(_ r: [String: OutboxRange]) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(r), as: UTF8.self)
    }

    static func decodeRanges(_ json: String) throws -> [String: OutboxRange] {
        try JSONDecoder().decode([String: OutboxRange].self, from: Data(json.utf8))
    }

    static func meta(_ row: Row) throws -> OutboxBatchMeta {
        OutboxBatchMeta(sequence: row["sequence"], batchId: row["batchId"], sourceId: row["sourceId"],
                        deviceId: row["deviceId"], createdAt: row["createdAt"],
                        ranges: try decodeRanges(row["rangesJSON"]), digest: row["digest"],
                        receiptJSON: row["receiptJSON"], receiptedAt: row["receiptedAt"])
    }
}

extension WhoopStore {
    /// When the newest receipt arrived, or nil before the first.
    public func lastOutboxReceiptAt() async throws -> Int? {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT MAX(receiptedAt) FROM syncOutbox") }
    }
}
