import Foundation
import GRDB

// MARK: - v8 cache: journal entries, workouts, and Apple-Health daily aggregates
// Mirrors the MetricsCache pattern: Codable structs, idempotent ON CONFLICT upserts keyed by
// natural key, and range-read accessors. All write/read GRDB work runs via the actor's
// syncWrite/syncRead helpers (off the main thread).

/// One journal answer. Natural key (deviceId, day, question).
// A yes/no answer to a daily journal question, with optional notes.
public struct JournalEntry: Equatable, Codable {
    public let day: String          // YYYY-MM-DD
    public let question: String
    public let answeredYes: Bool
    public let notes: String?
    public init(day: String, question: String, answeredYes: Bool, notes: String?) {
        self.day = day; self.question = question
        self.answeredYes = answeredYes; self.notes = notes
    }
}

/// One workout. Natural key (deviceId, startTs, sport). All metric columns nullable.
/// `zonesJSON` is verbatim JSON of HR-zone percentages, stored as a string so the cache stays
/// schema-agnostic about the zone shape.
// zonesJSON is kept as raw JSON so the zone format can change without a schema migration.
public struct WorkoutRow: Equatable, Codable, Sendable {
    public let startTs: Int          // unix seconds
    public let endTs: Int            // unix seconds
    public let sport: String
    public let source: String
    public let durationS: Double?
    public let energyKcal: Double?
    public let avgHr: Int?
    public let maxHr: Int?
    public let strain: Double?
    public let distanceM: Double?
    public let zonesJSON: String?
    public let notes: String?
    public init(startTs: Int, endTs: Int, sport: String, source: String, durationS: Double?,
                energyKcal: Double?, avgHr: Int?, maxHr: Int?, strain: Double?, distanceM: Double?,
                zonesJSON: String?, notes: String?) {
        self.startTs = startTs; self.endTs = endTs; self.sport = sport; self.source = source
        self.durationS = durationS; self.energyKcal = energyKcal; self.avgHr = avgHr
        self.maxHr = maxHr; self.strain = strain; self.distanceM = distanceM
        self.zonesJSON = zonesJSON; self.notes = notes
    }
}

extension WhoopStore {

    // MARK: - Upserts (idempotent by natural key; latest value wins on conflict)

    /// Upsert journal entries. Natural key (deviceId, day, question). Returns rows changed.
    @discardableResult
    public func upsertJournal(_ rows: [JournalEntry], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO journal
                        (deviceId, day, question, answeredYes, notes)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, question) DO UPDATE SET
                        answeredYes = excluded.answeredYes,
                        notes = excluded.notes
                    """, arguments: [deviceId, r.day, r.question, r.answeredYes ? 1 : 0, r.notes])
                n += db.changesCount
            }
            return n
        }
    }

    /// Upsert workouts. Natural key (deviceId, startTs, sport). Returns rows changed.
    @discardableResult
    // Keyed by (start, sport), so re-importing the same workout updates it instead of duplicating.
    public func upsertWorkouts(_ rows: [WorkoutRow], deviceId: String) async throws -> Int {
        try syncWrite { db in try Self.upsertWorkoutRows(db, rows, deviceId: deviceId) }
    }

    /// Same upsert inside a caller's transaction (see `writeDerived`).
    static func upsertWorkoutRows(_ db: Database, _ rows: [WorkoutRow], deviceId: String) throws -> Int {
        var n = 0
        for r in rows {
            try db.execute(sql: """
                INSERT INTO workout
                    (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                     avgHr, maxHr, strain, distanceM, zonesJSON, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                    endTs = excluded.endTs,
                    source = excluded.source,
                    durationS = excluded.durationS,
                    energyKcal = excluded.energyKcal,
                    avgHr = excluded.avgHr,
                    maxHr = excluded.maxHr,
                    strain = excluded.strain,
                    distanceM = excluded.distanceM,
                    zonesJSON = excluded.zonesJSON,
                    notes = excluded.notes
                """, arguments: [deviceId, r.startTs, r.endTs, r.sport, r.source, r.durationS,
                                 r.energyKcal, r.avgHr, r.maxHr, r.strain, r.distanceM,
                                 r.zonesJSON, r.notes])
            n += db.changesCount
        }
        return n
    }

    // MARK: - Reads

    /// Journal entries for days in [from, to] (lexicographic YYYY-MM-DD compare),
    /// oldest day first, then by question.
    public func journalEntries(deviceId: String, from: String, to: String) async throws -> [JournalEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, question, answeredYes, notes FROM journal
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day ASC, question ASC
                """, arguments: [deviceId, from, to])
                .map {
                    JournalEntry(day: $0["day"], question: $0["question"],
                                 answeredYes: ($0["answeredYes"] as Int) != 0,
                                 notes: $0["notes"])
                }
        }
    }

    /// Workouts overlapping [from, to] (by startTs), oldest first.
    public func workouts(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WorkoutRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                               source: $0["source"], durationS: $0["durationS"],
                               energyKcal: $0["energyKcal"], avgHr: $0["avgHr"], maxHr: $0["maxHr"],
                               strain: $0["strain"], distanceM: $0["distanceM"],
                               zonesJSON: $0["zonesJSON"], notes: $0["notes"])
                }
        }
    }

}
