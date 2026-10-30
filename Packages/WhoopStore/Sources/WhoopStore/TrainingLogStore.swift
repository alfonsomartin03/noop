import Foundation
import GRDB

// TrainingLogStore.swift — what the user reported about a workout (session effort, logged sets).
//
// These rows are source data, kept apart from everything `writeDerived` / `deleteDerived` replace: they have no deviceId
// and are not in `derivedTables`, so a re-score cannot reach them. Rows mirror StrandAnalytics `SessionRPE` / `StrengthSet`
// as plain values, with the workout identity and provenance those types don't carry.

/// How a training-log value got here. Only the user enters these; nothing is estimated from HR.
public enum TrainingLogProvenance {
    public static let userEntered = "user-entered"
}

/// One reported session effort. Natural key `workoutStartTs`; no row means no response.
public struct SessionEffortRow: Equatable, Codable, Sendable {
    public let workoutStartTs: Int
    public let workoutEndTs: Int
    public let scale: String
    public let rpe: Double
    public let sessionMinutes: Double
    public let collectedAt: Int
    public let provenance: String
    public init(workoutStartTs: Int, workoutEndTs: Int, scale: String, rpe: Double, sessionMinutes: Double,
                collectedAt: Int, provenance: String = TrainingLogProvenance.userEntered) {
        self.workoutStartTs = workoutStartTs; self.workoutEndTs = workoutEndTs; self.scale = scale; self.rpe = rpe
        self.sessionMinutes = sessionMinutes; self.collectedAt = collectedAt; self.provenance = provenance
    }
}

/// One logged set. Natural key (`workoutStartTs`, `setIndex`). `externalKg` nil = no external load logged.
public struct StrengthSetRow: Equatable, Codable, Sendable {
    public let workoutStartTs: Int
    /// Position within the workout, in logged order; assigned by `addStrengthSet`. Gaps after a delete are harmless.
    public let setIndex: Int
    public let workoutEndTs: Int
    public let exercise: String
    public let reps: Int
    public let externalKg: Double?
    public let rir: Int?
    public let collectedAt: Int
    public let provenance: String
    public init(workoutStartTs: Int, setIndex: Int = 0, workoutEndTs: Int, exercise: String, reps: Int, externalKg: Double?,
                rir: Int?, collectedAt: Int, provenance: String = TrainingLogProvenance.userEntered) {
        self.workoutStartTs = workoutStartTs; self.setIndex = setIndex; self.workoutEndTs = workoutEndTs
        self.exercise = exercise; self.reps = reps; self.externalKg = externalKg; self.rir = rir
        self.collectedAt = collectedAt; self.provenance = provenance
    }
}

/// Everything logged against one workout. `workoutStartTs` / `workoutEndTs` are the span it was logged under, which a
/// re-score may have since moved: later writes for this entry must keep using them.
public struct TrainingLogEntry: Equatable, Sendable {
    public let workoutStartTs: Int
    public let workoutEndTs: Int
    public let effort: SessionEffortRow?
    public let sets: [StrengthSetRow]
    public init(workoutStartTs: Int, workoutEndTs: Int, effort: SessionEffortRow?, sets: [StrengthSetRow]) {
        self.workoutStartTs = workoutStartTs; self.workoutEndTs = workoutEndTs; self.effort = effort; self.sets = sets
    }
}

extension WhoopStore {
    /// Tables holding user-entered training data. Never derived; see the file header.
    static let trainingLogTables = ["sessionEffort", "strengthSet", "workoutLabel"]

    /// Record or replace the effort reported for a workout.
    public func upsertSessionEffort(_ r: SessionEffortRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO sessionEffort (workoutStartTs, workoutEndTs, scale, rpe, sessionMinutes, collectedAt, provenance)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(workoutStartTs) DO UPDATE SET
                    workoutEndTs = excluded.workoutEndTs,
                    scale = excluded.scale,
                    rpe = excluded.rpe,
                    sessionMinutes = excluded.sessionMinutes,
                    collectedAt = excluded.collectedAt,
                    provenance = excluded.provenance
                """, arguments: [r.workoutStartTs, r.workoutEndTs, r.scale, r.rpe, r.sessionMinutes, r.collectedAt, r.provenance])
        }
    }

    /// Withdraw a response; the workout goes back to having no reported effort.
    public func deleteSessionEffort(workoutStartTs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM sessionEffort WHERE workoutStartTs = ?", arguments: [workoutStartTs])
        }
    }

    /// Append a set after the workout's existing sets; `setIndex` on the input is ignored. Returns the stored row.
    @discardableResult
    public func addStrengthSet(_ r: StrengthSetRow) async throws -> StrengthSetRow {
        try syncWrite { db in
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(setIndex) + 1, 0) FROM strengthSet WHERE workoutStartTs = ?",
                                        arguments: [r.workoutStartTs]) ?? 0
            try db.execute(sql: """
                INSERT INTO strengthSet
                    (workoutStartTs, setIndex, workoutEndTs, exercise, reps, externalKg, rir, collectedAt, provenance)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.workoutStartTs, next, r.workoutEndTs, r.exercise, r.reps, r.externalKg, r.rir,
                                 r.collectedAt, r.provenance])
            return StrengthSetRow(workoutStartTs: r.workoutStartTs, setIndex: next, workoutEndTs: r.workoutEndTs,
                                  exercise: r.exercise, reps: r.reps, externalKg: r.externalKg, rir: r.rir,
                                  collectedAt: r.collectedAt, provenance: r.provenance)
        }
    }

    public func deleteStrengthSet(workoutStartTs: Int, setIndex: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM strengthSet WHERE workoutStartTs = ? AND setIndex = ?",
                           arguments: [workoutStartTs, setIndex])
        }
    }

    /// What was logged against the workout spanning [startTs, endTs), or nil if nothing was. An entry under exactly this
    /// start wins. Otherwise a re-score has moved the workout, so take the entry whose logged span overlaps it most.
    public func trainingLog(workoutStartTs startTs: Int, workoutEndTs endTs: Int) async throws -> TrainingLogEntry? {
        try syncRead { db in
            let spans = try Row.fetchAll(db, sql: """
                SELECT workoutStartTs, workoutEndTs FROM sessionEffort
                WHERE workoutStartTs = ? OR (workoutStartTs < ? AND workoutEndTs > ?)
                UNION
                SELECT workoutStartTs, workoutEndTs FROM strengthSet
                WHERE workoutStartTs = ? OR (workoutStartTs < ? AND workoutEndTs > ?)
                ORDER BY workoutStartTs
                """, arguments: [startTs, endTs, startTs, startTs, endTs, startTs])
                .map { (start: $0["workoutStartTs"] as Int, end: $0["workoutEndTs"] as Int) }
            let overlap = { (s: (start: Int, end: Int)) in min(s.end, endTs) - max(s.start, startTs) }
            guard let span = spans.first(where: { $0.start == startTs })
                    ?? spans.max(by: { overlap($0) < overlap($1) }) else { return nil }

            let effort = try Row.fetchOne(db, sql: "SELECT * FROM sessionEffort WHERE workoutStartTs = ?", arguments: [span.start])
                .map { SessionEffortRow(workoutStartTs: $0["workoutStartTs"], workoutEndTs: $0["workoutEndTs"], scale: $0["scale"],
                                        rpe: $0["rpe"], sessionMinutes: $0["sessionMinutes"], collectedAt: $0["collectedAt"],
                                        provenance: $0["provenance"]) }
            let sets = try Row.fetchAll(db, sql: "SELECT * FROM strengthSet WHERE workoutStartTs = ? ORDER BY setIndex",
                                        arguments: [span.start])
                .map { StrengthSetRow(workoutStartTs: $0["workoutStartTs"], setIndex: $0["setIndex"], workoutEndTs: $0["workoutEndTs"],
                                      exercise: $0["exercise"], reps: $0["reps"], externalKg: $0["externalKg"], rir: $0["rir"],
                                      collectedAt: $0["collectedAt"], provenance: $0["provenance"]) }
            return TrainingLogEntry(workoutStartTs: span.start, workoutEndTs: span.end, effort: effort, sets: sets)
        }
    }
}

/// What a workout was, as stored. `provenance` is a StrandAnalytics `LabelProvenance` raw value. No row means no one said.
public struct WorkoutLabelRow: Equatable, Codable, Sendable {
    public let workoutStartTs: Int
    public let workoutEndTs: Int
    public let activity: String
    public let provenance: String
    public let updatedAt: Int
    public init(workoutStartTs: Int, workoutEndTs: Int, activity: String, provenance: String, updatedAt: Int) {
        self.workoutStartTs = workoutStartTs; self.workoutEndTs = workoutEndTs; self.activity = activity
        self.provenance = provenance; self.updatedAt = updatedAt
    }
}

extension WhoopStore {
    public func setWorkoutLabel(_ r: WorkoutLabelRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO workoutLabel (workoutStartTs, workoutEndTs, activity, provenance, updatedAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(workoutStartTs) DO UPDATE SET workoutEndTs = excluded.workoutEndTs, activity = excluded.activity,
                    provenance = excluded.provenance, updatedAt = excluded.updatedAt
                """, arguments: [r.workoutStartTs, r.workoutEndTs, r.activity, r.provenance, r.updatedAt])
        }
    }

    public func clearWorkoutLabel(workoutStartTs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workoutLabel WHERE workoutStartTs = ?", arguments: [workoutStartTs])
        }
    }

    public func workoutLabels() async throws -> [WorkoutLabelRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM workoutLabel ORDER BY workoutStartTs").map {
                WorkoutLabelRow(workoutStartTs: $0["workoutStartTs"], workoutEndTs: $0["workoutEndTs"], activity: $0["activity"],
                                provenance: $0["provenance"], updatedAt: $0["updatedAt"])
            }
        }
    }
}
