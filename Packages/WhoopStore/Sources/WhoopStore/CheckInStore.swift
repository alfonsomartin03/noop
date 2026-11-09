import Foundation
import GRDB

// CheckInStore.swift — morning / evening check-ins (migration v17).
//
// One entry per (local date, session). Saving an entry replaces its answers atomically; the local date the entry was
// made for never changes on edit, and each answer keeps the prompt id and prompt version it was asked under, so wording
// changes never re-interpret history. Answers are stored as given: "yes", "no", "notSure", "skipped", "unanswered".
// Nothing here is read by scoring.

public struct CheckInAnswerRow: Equatable, Codable, Sendable {
    public let promptId: String
    public let promptVersion: Int
    public let answer: String
    public let position: Int
    public init(promptId: String, promptVersion: Int, answer: String, position: Int) {
        self.promptId = promptId; self.promptVersion = promptVersion; self.answer = answer; self.position = position
    }
}

public struct CheckInEntryRow: Equatable, Codable, Sendable {
    public let localDate: String
    public let session: String
    /// "completed" or "skipped" (the whole session skipped for that date).
    public let status: String
    public let note: String?
    /// Time-zone identifier the entry's local date was taken in.
    public let timeZone: String
    public let createdAt: Double
    public let updatedAt: Double
    public let answers: [CheckInAnswerRow]
    public init(localDate: String, session: String, status: String, note: String?, timeZone: String,
                createdAt: Double, updatedAt: Double, answers: [CheckInAnswerRow]) {
        self.localDate = localDate; self.session = session; self.status = status; self.note = note
        self.timeZone = timeZone; self.createdAt = createdAt; self.updatedAt = updatedAt; self.answers = answers
    }
}

extension WhoopStore {
    /// Insert or replace an entry and all of its answers in one transaction. An existing entry keeps its `createdAt`
    /// and original time zone (an edit never moves an entry to another day).
    public func saveCheckIn(_ e: CheckInEntryRow) async throws {
        try syncWrite { db in
            let existing = try Row.fetchOne(db, sql: "SELECT createdAt, timeZone FROM checkInEntry WHERE localDate = ? AND session = ?",
                                            arguments: [e.localDate, e.session])
            let created: Double = existing?["createdAt"] ?? e.createdAt
            let zone: String = existing?["timeZone"] ?? e.timeZone
            try db.execute(sql: """
                INSERT INTO checkInEntry (localDate, session, status, note, timeZone, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(localDate, session) DO UPDATE SET status = excluded.status, note = excluded.note,
                    updatedAt = excluded.updatedAt
                """, arguments: [e.localDate, e.session, e.status, e.note, zone, created, e.updatedAt])
            try db.execute(sql: "DELETE FROM checkInAnswer WHERE localDate = ? AND session = ?", arguments: [e.localDate, e.session])
            for a in e.answers {
                try db.execute(sql: """
                    INSERT INTO checkInAnswer (localDate, session, promptId, promptVersion, answer, position)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [e.localDate, e.session, a.promptId, a.promptVersion, a.answer, a.position])
            }
        }
    }

    /// Entries with local dates in [from, to] (inclusive), oldest first, answers in their asked order.
    public func checkIns(from: String, to: String) async throws -> [CheckInEntryRow] {
        try syncRead { db in
            let answers = try Row.fetchAll(db, sql: """
                SELECT * FROM checkInAnswer WHERE localDate >= ? AND localDate <= ? ORDER BY position
                """, arguments: [from, to])
            var byKey: [String: [CheckInAnswerRow]] = [:]
            for r in answers {
                let key = (r["localDate"] as String) + "|" + (r["session"] as String)
                byKey[key, default: []].append(CheckInAnswerRow(promptId: r["promptId"], promptVersion: r["promptVersion"],
                                                                answer: r["answer"], position: r["position"]))
            }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM checkInEntry WHERE localDate >= ? AND localDate <= ? ORDER BY localDate, session
                """, arguments: [from, to]).map { r in
                let d: String = r["localDate"], s: String = r["session"]
                return CheckInEntryRow(localDate: d, session: s, status: r["status"], note: r["note"], timeZone: r["timeZone"],
                                       createdAt: r["createdAt"], updatedAt: r["updatedAt"], answers: byKey[d + "|" + s] ?? [])
            }
        }
    }

    /// Remove one entry and its answers (the user clearing a day).
    public func deleteCheckIn(localDate: String, session: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM checkInAnswer WHERE localDate = ? AND session = ?", arguments: [localDate, session])
            try db.execute(sql: "DELETE FROM checkInEntry WHERE localDate = ? AND session = ?", arguments: [localDate, session])
        }
    }
}
