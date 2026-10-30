import Foundation
import GRDB

// DerivedStore.swift — NOOP's own derived rows written all-or-nothing, with their provenance.
//
// A re-score must never leave the dashboard half-replaced: archive, delete and write happen in ONE transaction, so any
// failure (disk full, constraint, crash) leaves the previous rows exactly as they were. Imported rows and raw samples
// live under other device ids / tables and are never touched here.

/// How a derived value was produced (mirrors StrandAnalytics `MetricIdentity` as plain strings; "unknown" is explicit).
public struct ProvenanceRecord: Equatable, Codable, Sendable {
    public let day: String
    public let key: String
    public let definition: String
    public let unit: String
    public let source: String
    public let hardware: String
    public let algorithmVersion: String
    public let context: String
    public let aggregation: String
    public let coverage: Double?
    /// Exclusion / unavailability reasons; empty = value eligible.
    public let exclusionReasons: [String]
    public let scoringVersion: Int

    public init(day: String, key: String, definition: String, unit: String, source: String, hardware: String,
                algorithmVersion: String, context: String, aggregation: String, coverage: Double? = nil,
                exclusionReasons: [String] = [], scoringVersion: Int) {
        self.day = day; self.key = key; self.definition = definition; self.unit = unit; self.source = source
        self.hardware = hardware; self.algorithmVersion = algorithmVersion; self.context = context
        self.aggregation = aggregation; self.coverage = coverage; self.exclusionReasons = exclusionReasons
        self.scoringVersion = scoringVersion
    }
}

/// The accounting behind one derived day or session. `payload` is JSON owned by StrandAnalytics.
public struct LoadRecordRow: Equatable, Codable, Sendable {
    public static let dayScope = "day"
    public static let sessionScope = "session"

    public let day: String
    public let scope: String
    /// Session start (unix s); 0 for a day row.
    public let startTs: Int
    public let algorithmVersion: String
    public let payload: String
    public init(day: String, scope: String, startTs: Int, algorithmVersion: String, payload: String) {
        self.day = day; self.scope = scope; self.startTs = startTs
        self.algorithmVersion = algorithmVersion; self.payload = payload
    }
}

/// What one stored day's score was computed from; see StrandAnalytics `IncrementalScorer`.
public struct DayScoreRow: Equatable, Sendable {
    public let day: String
    public let algorithmKey: String
    public let configKey: String
    /// Sum of the stream high-water marks when computed.
    public let inputRevision: Int
    public let calibrationKey: String
    public let baselineKey: String
    public let knownSessionsKey: String
    public let rangeStart: Int
    public let rangeEnd: Int
    /// Over and fully checked: config changes no longer reach this day.
    public let finalized: Bool
    /// False for a day with too little data, so it isn't re-read on every run.
    public let hasResult: Bool
    public init(day: String, algorithmKey: String, configKey: String, inputRevision: Int, calibrationKey: String,
                baselineKey: String, knownSessionsKey: String, rangeStart: Int, rangeEnd: Int, finalized: Bool, hasResult: Bool) {
        self.day = day; self.algorithmKey = algorithmKey; self.configKey = configKey; self.inputRevision = inputRevision
        self.calibrationKey = calibrationKey; self.baselineKey = baselineKey; self.knownSessionsKey = knownSessionsKey
        self.rangeStart = rangeStart; self.rangeEnd = rangeEnd; self.finalized = finalized; self.hasResult = hasResult
    }
}

/// Everything one scoring run produced.
public struct DerivedBatch: Sendable {
    public var dailies: [DailyMetric]
    public var sleepSessions: [CachedSleepSession]
    public var workouts: [WorkoutRow]
    public var series: [MetricPoint]
    public var provenance: [ProvenanceRecord]
    public var loadRecords: [LoadRecordRow]
    public var scoreStates: [DayScoreRow]
    /// Written with the rows, so a high-water mark can never pass results that failed to commit.
    public var cursors: [String: Int]
    public init(dailies: [DailyMetric] = [], sleepSessions: [CachedSleepSession] = [], workouts: [WorkoutRow] = [],
                series: [MetricPoint] = [], provenance: [ProvenanceRecord] = [], loadRecords: [LoadRecordRow] = [],
                scoreStates: [DayScoreRow] = [], cursors: [String: Int] = [:]) {
        self.dailies = dailies; self.sleepSessions = sleepSessions; self.workouts = workouts
        self.series = series; self.provenance = provenance; self.loadRecords = loadRecords
        self.scoreStates = scoreStates; self.cursors = cursors
    }
}

public enum DerivedWriteScope: Sendable {
    /// Partial replay: the run re-scored exactly these days. Everything derived for them is replaced — including
    /// keys, sessions and workouts the new run no longer produces — so a replay leaves the same state a full re-score
    /// would. `ranges` are the days' [from, to) in unix seconds.
    case replaceDays([String], ranges: [ClosedRange<Int>])
    /// Rule-version re-score from `fromDay` on: ALL current derived rows are first copied to `archiveId`, then rows
    /// from `fromDay` / `fromTs` on are replaced. Older rows (outside the re-scored horizon) stay, marked by provenance.
    case rescore(archiveId: String, fromDay: String, fromTs: Int)
}

extension WhoopStore {
    static let derivedTables = ["dailyMetric", "sleepSession", "workout", "metricSeries", "metricProvenance", "loadRecord", "dayScoreState"]
    /// Tables replaced by day.
    static let derivedDayTables = ["dailyMetric", "metricSeries", "metricProvenance", "loadRecord", "dayScoreState"]
    /// Decoded streams that feed scoring, all insert-only.
    static let scoringStreams = ["hrSample", "rrInterval", "respSample", "gravitySample"]

    /// Write a scoring run atomically. Throws (and changes nothing) if any step fails.
    public func writeDerived(_ batch: DerivedBatch, deviceId: String, scope: DerivedWriteScope) async throws {
        try syncWrite { db in
            switch scope {
            case let .replaceDays(days, ranges):
                for d in days {
                    for t in Self.derivedDayTables {
                        try db.execute(sql: "DELETE FROM \(t) WHERE deviceId = ? AND day = ?", arguments: [deviceId, d])
                    }
                }
                for r in ranges {
                    try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND endTs >= ? AND endTs < ?",
                                   arguments: [deviceId, r.lowerBound, r.upperBound])
                    try db.execute(sql: "DELETE FROM workout WHERE deviceId = ? AND startTs >= ? AND startTs < ?",
                                   arguments: [deviceId, r.lowerBound, r.upperBound])
                }
            case let .rescore(archiveId, fromDay, fromTs):
                try Self.copyDerived(db, deviceId: deviceId, archiveId: archiveId)
                for t in Self.derivedDayTables {
                    try db.execute(sql: "DELETE FROM \(t) WHERE deviceId = ? AND day >= ?", arguments: [deviceId, fromDay])
                }
                try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND endTs >= ?", arguments: [deviceId, fromTs])
                try db.execute(sql: "DELETE FROM workout WHERE deviceId = ? AND startTs >= ?", arguments: [deviceId, fromTs])
            }
            _ = try Self.upsertDailyMetricRows(db, batch.dailies, deviceId: deviceId)
            _ = try Self.upsertSleepSessionRows(db, batch.sleepSessions, deviceId: deviceId)
            _ = try Self.upsertWorkoutRows(db, batch.workouts, deviceId: deviceId)
            _ = try Self.upsertMetricSeriesRows(db, batch.series, deviceId: deviceId)
            try Self.upsertProvenanceRows(db, batch.provenance, deviceId: deviceId)
            for r in batch.loadRecords {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO loadRecord (deviceId, day, scope, startTs, algorithmVersion, payload)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, r.day, r.scope, r.startTs, r.algorithmVersion, r.payload])
            }
            for s in batch.scoreStates {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO dayScoreState (deviceId, day, algorithmKey, configKey, inputRevision, calibrationKey,
                        baselineKey, knownSessionsKey, rangeStart, rangeEnd, finalized, hasResult)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, s.day, s.algorithmKey, s.configKey, s.inputRevision, s.calibrationKey, s.baselineKey,
                                     s.knownSessionsKey, s.rangeStart, s.rangeEnd, s.finalized, s.hasResult])
            }
            for (name, value) in batch.cursors {
                try db.execute(sql: """
                    INSERT INTO cursors (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value
                    """, arguments: [name, value])
            }
        }
    }

    static func copyDerived(_ db: Database, deviceId: String, archiveId: String) throws {
        for t in derivedTables {
            let cols = try db.columns(in: t).map(\.name)
            let select = cols.map { $0 == "deviceId" ? "?" : $0 }.joined(separator: ", ")
            try db.execute(sql: "INSERT OR REPLACE INTO \(t) (\(cols.joined(separator: ", "))) SELECT \(select) FROM \(t) WHERE deviceId = ?",
                           arguments: [archiveId, deviceId])
        }
    }

    /// Copy all current derived rows to `archiveId` and set the cursor `marker`, in one transaction.
    public func archiveDerived(deviceId: String, archiveId: String, marker: String) async throws {
        try syncWrite { db in
            try Self.copyDerived(db, deviceId: deviceId, archiveId: archiveId)
            try db.execute(sql: "INSERT OR REPLACE INTO cursors (name, value) VALUES (?, 1)", arguments: [marker])
        }
    }

    public func dayScoreStates(deviceId: String) async throws -> [String: DayScoreRow] {
        try syncRead { db in
            var out: [String: DayScoreRow] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT * FROM dayScoreState WHERE deviceId = ?", arguments: [deviceId]) {
                let s = DayScoreRow(day: r["day"], algorithmKey: r["algorithmKey"], configKey: r["configKey"],
                                    inputRevision: r["inputRevision"], calibrationKey: r["calibrationKey"],
                                    baselineKey: r["baselineKey"], knownSessionsKey: r["knownSessionsKey"],
                                    rangeStart: r["rangeStart"], rangeEnd: r["rangeEnd"], finalized: r["finalized"],
                                    hasResult: r["hasResult"])
                out[s.day] = s
            }
            return out
        }
    }

    /// Highest rowid of each scoring stream. Streams are insert-only, so a rowid past a saved mark is exactly a new row.
    public func streamMarks() async throws -> [String: Int] {
        try syncRead { db in
            var out: [String: Int] = [:]
            for t in Self.scoringStreams { out[t] = try Int.fetchOne(db, sql: "SELECT max(rowid) FROM \(t)") ?? 0 }
            return out
        }
    }

    /// Hours (ts / 3600) holding rows of this device added after `since`.
    public func changedHours(deviceId: String, since: [String: Int]) async throws -> Set<Int> {
        try syncRead { db in
            var out: Set<Int> = []
            for t in Self.scoringStreams {
                let hours = try Int.fetchAll(db, sql: "SELECT DISTINCT ts / 3600 FROM \(t) WHERE rowid > ? AND deviceId = ?",
                                             arguments: [since[t] ?? 0, deviceId])
                out.formUnion(hours)
            }
            return out
        }
    }

    /// Load records for days in [from, to] (YYYY-MM-DD, inclusive), ordered by day, scope and start.
    public func loadRecords(deviceId: String, from: String, to: String) async throws -> [LoadRecordRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM loadRecord WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day, scope, startTs
                """, arguments: [deviceId, from, to]).map {
                LoadRecordRow(day: $0["day"], scope: $0["scope"], startTs: $0["startTs"],
                              algorithmVersion: $0["algorithmVersion"], payload: $0["payload"])
            }
        }
    }

    static func upsertProvenanceRows(_ db: Database, _ rows: [ProvenanceRecord], deviceId: String) throws {
        for r in rows {
            try db.execute(sql: """
                INSERT INTO metricProvenance
                    (deviceId, day, key, definition, unit, source, hardware, algorithmVersion, context, aggregation,
                     coverage, exclusionReasons, scoringVersion)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, day, key) DO UPDATE SET
                    definition = excluded.definition, unit = excluded.unit, source = excluded.source,
                    hardware = excluded.hardware, algorithmVersion = excluded.algorithmVersion,
                    context = excluded.context, aggregation = excluded.aggregation, coverage = excluded.coverage,
                    exclusionReasons = excluded.exclusionReasons, scoringVersion = excluded.scoringVersion
                """, arguments: [deviceId, r.day, r.key, r.definition, r.unit, r.source, r.hardware,
                                 r.algorithmVersion, r.context, r.aggregation, r.coverage,
                                 r.exclusionReasons.joined(separator: "\u{1F}"), r.scoringVersion])
        }
    }

    /// Provenance rows for days in [from, to] (YYYY-MM-DD, inclusive), ordered by day then key.
    public func provenance(deviceId: String, from: String, to: String) async throws -> [ProvenanceRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM metricProvenance WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day, key
                """, arguments: [deviceId, from, to]).map { r in
                let reasons: String = r["exclusionReasons"]
                return ProvenanceRecord(day: r["day"], key: r["key"], definition: r["definition"], unit: r["unit"],
                                        source: r["source"], hardware: r["hardware"],
                                        algorithmVersion: r["algorithmVersion"], context: r["context"],
                                        aggregation: r["aggregation"], coverage: r["coverage"],
                                        exclusionReasons: reasons.isEmpty ? [] : reasons.components(separatedBy: "\u{1F}"),
                                        scoringVersion: r["scoringVersion"])
            }
        }
    }

    /// Test seams for the analytics package: make the next derived writes fail, then allow them again.
    public func failDerivedWritesForTest() async throws {
        try executeForTest("CREATE TRIGGER failDerived BEFORE INSERT ON dayScoreState BEGIN SELECT RAISE(ABORT, 'injected'); END")
    }
    public func allowDerivedWritesForTest() async throws { try executeForTest("DROP TRIGGER failDerived") }

    /// Test seam: run raw SQL (e.g. install a failing trigger to prove atomicity).
    func executeForTest(_ sql: String) throws { try syncWrite { db in try db.execute(sql: sql) } }
}
