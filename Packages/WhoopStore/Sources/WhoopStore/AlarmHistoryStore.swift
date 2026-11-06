import Foundation
import GRDB

// AlarmHistoryStore.swift — append-only alarm history (migration v16).
//
// Every alarm occurrence leaves a trail: what was scheduled (with a snapshot of the alarm's settings), the decision and
// its evidence, each command and its answer, what the strap reported (with its own timestamp, the mapped Mac time, when
// NOOP received it, and whether it came live or from a history pull), the notification outcome and the dismissal.
// Rows are never updated or deleted by alarm edits, deletion or re-scoring. Strap events carry a `dedupeKey`; inserting
// a second copy of the same event (live, then again from history) is ignored.

public struct AlarmEventRow: Equatable, Codable, Sendable {
    public enum Provenance {
        public static let host = "host"        // NOOP's own action or decision
        public static let live = "live"        // strap event received as it happened
        public static let history = "history"  // strap event replayed in a history pull
    }
    public let id: Int64?
    /// nil = a strap event NOOP could not attribute to an occurrence (kept unmatched, never guessed).
    public let occurrenceId: String?
    public let kind: String
    public let recordedAt: Double
    public let deviceTs: Int?
    public let mappedHostTs: Double?
    public let receivedAt: Double?
    public let provenance: String
    public let dedupeKey: String?
    /// JSON details (configuration snapshot, evidence summary, command, status …).
    public let payload: String?

    public init(id: Int64? = nil, occurrenceId: String?, kind: String, recordedAt: Double, deviceTs: Int? = nil,
                mappedHostTs: Double? = nil, receivedAt: Double? = nil, provenance: String, dedupeKey: String? = nil,
                payload: String? = nil) {
        self.id = id; self.occurrenceId = occurrenceId; self.kind = kind; self.recordedAt = recordedAt
        self.deviceTs = deviceTs; self.mappedHostTs = mappedHostTs; self.receivedAt = receivedAt
        self.provenance = provenance; self.dedupeKey = dedupeKey; self.payload = payload
    }
}

public struct AlarmAnnotationRow: Equatable, Codable, Sendable {
    public let occurrenceId: String
    public let label: String
    public let createdAt: Double
    public init(occurrenceId: String, label: String, createdAt: Double) {
        self.occurrenceId = occurrenceId; self.label = label; self.createdAt = createdAt
    }
}

extension WhoopStore {
    /// Append rows. A row whose `dedupeKey` already exists is skipped. Returns how many were inserted.
    @discardableResult
    public func appendAlarmEvents(_ rows: [AlarmEventRow]) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO alarmEvent
                        (occurrenceId, kind, recordedAt, deviceTs, mappedHostTs, receivedAt, provenance, dedupeKey, payload)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.occurrenceId, r.kind, r.recordedAt, r.deviceTs, r.mappedHostTs, r.receivedAt,
                                     r.provenance, r.dedupeKey, r.payload])
                n += db.changesCount
            }
            return n
        }
    }

    /// Newest-first history since `since` (unix seconds), at most `limit` rows.
    public func alarmEvents(since: Double = 0, limit: Int = 2000) async throws -> [AlarmEventRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM alarmEvent WHERE recordedAt >= ? ORDER BY recordedAt DESC, id DESC LIMIT ?
                """, arguments: [since, limit]).map {
                AlarmEventRow(id: $0["id"], occurrenceId: $0["occurrenceId"], kind: $0["kind"], recordedAt: $0["recordedAt"],
                              deviceTs: $0["deviceTs"], mappedHostTs: $0["mappedHostTs"], receivedAt: $0["receivedAt"],
                              provenance: $0["provenance"], dedupeKey: $0["dedupeKey"], payload: $0["payload"])
            }
        }
    }

    /// Record or replace the wearer's note on an occurrence.
    public func setAlarmAnnotation(_ a: AlarmAnnotationRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO alarmAnnotation (occurrenceId, label, createdAt) VALUES (?, ?, ?)
                ON CONFLICT(occurrenceId) DO UPDATE SET label = excluded.label, createdAt = excluded.createdAt
                """, arguments: [a.occurrenceId, a.label, a.createdAt])
        }
    }

    public func alarmAnnotations() async throws -> [AlarmAnnotationRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM alarmAnnotation").map {
                AlarmAnnotationRow(occurrenceId: $0["occurrenceId"], label: $0["label"], createdAt: $0["createdAt"])
            }
        }
    }
}
