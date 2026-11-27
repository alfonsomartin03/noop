import Foundation
import CryptoKit
import GRDB

// SummaryStore.swift — daily score summaries the Mac sends back to the phone (#79, migration v22).
//
// Mac: `dailySummaries(since:)` reads NOOP's own daily rows (`dailyMetric` for `<strap>-noop`) and their coverage
// (`metricProvenance`), gives every day whose content changed since it was last served a new global revision, and
// returns the days newer than `since`. A day that disappears (re-scored away) is sent once as `removed`. Missing values
// are left out, never sent as 0. Phone: `cacheSummaries` keeps the newest revision per day.

public struct DailySummary: Equatable, Codable, Sendable {
    public let day: String                 // local calendar day, "YYYY-MM-DD"
    public let revision: Int64             // global; higher = newer
    /// When the Mac noticed this content (unix seconds): the analysis time the phone shows.
    public let changedAt: Int
    /// Metric key → value. Keys and units: see `DailySummary.units`. Absent = not available that day.
    public let values: [String: Double]
    /// Metric key → coverage 0…1 as recorded by the Mac's provenance, when it recorded one.
    public let coverage: [String: Double]
    public let removed: Bool

    public init(day: String, revision: Int64, changedAt: Int, values: [String: Double], coverage: [String: Double],
                removed: Bool) {
        self.day = day; self.revision = revision; self.changedAt = changedAt; self.values = values
        self.coverage = coverage; self.removed = removed
    }

    public static let units: [String: String] = [
        "recovery": "%", "strain": "strain (0–21)", "totalSleepMin": "min", "efficiency": "%",
        "deepMin": "min", "remMin": "min", "lightMin": "min", "disturbances": "count",
        "restingHr": "bpm", "avgHrv": "ms", "respRateBpm": "breaths/min", "spo2Pct": "%",
        "skinTempDevC": "°C vs baseline", "exerciseCount": "count",
    ]
}

extension WhoopStore {
    static let summaryColumns = ["recovery", "strain", "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin",
                                 "disturbances", "restingHr", "avgHrv", "respRateBpm", "spo2Pct", "skinTempDevC",
                                 "exerciseCount"]

    /// Mac side. Refreshes revisions for `deviceId` (NOOP's derived identity, e.g. `my-whoop-noop`) and returns days
    /// with a revision above `since`, oldest revision first, at most `limit`.
    public func dailySummaries(deviceId: String, since: Int64, limit: Int = 400,
                               now: Date = Date()) async throws -> [DailySummary] {
        try syncWrite { db in
            var current: [String: (values: [String: Double], coverage: [String: Double])] = [:]
            let cols = Self.summaryColumns.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: "SELECT day, \(cols) FROM dailyMetric WHERE deviceId = ?",
                                        arguments: [deviceId]) {
                var v: [String: Double] = [:]
                for c in Self.summaryColumns { if let x: Double = row[c] { v[c] = x } }
                current[row["day"]] = (v, [:])
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT day, key, coverage FROM metricProvenance WHERE deviceId = ? AND coverage IS NOT NULL
                """, arguments: [deviceId]) {
                let day: String = row["day"]
                guard current[day] != nil else { continue }
                current[day]!.coverage[row["key"]] = row["coverage"]
            }
            var known: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT day, digest FROM summaryRevision") { known[row["day"]] = row["digest"] }
            var next = (try Int64.fetchOne(db, sql: "SELECT MAX(revision) FROM summaryRevision") ?? 0) + 1
            let stamp = Int(now.timeIntervalSince1970)
            func bump(_ day: String, _ digest: String) throws {
                try db.execute(sql: """
                    INSERT INTO summaryRevision (day, digest, revision, changedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(day) DO UPDATE SET digest = excluded.digest, revision = excluded.revision,
                                                   changedAt = excluded.changedAt
                    """, arguments: [day, digest, next, stamp])
                next += 1
            }
            for day in current.keys.sorted() {
                let d = Self.digest(current[day]!)
                if known[day] != d { try bump(day, d) }
            }
            for day in known.keys.sorted() where current[day] == nil && known[day] != "removed" {
                try bump(day, "removed")
            }
            return try Row.fetchAll(db, sql: """
                SELECT day, revision, changedAt, digest FROM summaryRevision WHERE revision > ? ORDER BY revision LIMIT ?
                """, arguments: [since, limit]).map { row in
                let day: String = row["day"]
                let removed = (row["digest"] as String) == "removed"
                let c = current[day]
                return DailySummary(day: day, revision: row["revision"], changedAt: row["changedAt"],
                                    values: removed ? [:] : (c?.values ?? [:]),
                                    coverage: removed ? [:] : (c?.coverage ?? [:]), removed: removed)
            }
        }
    }

    static func digest(_ c: (values: [String: Double], coverage: [String: Double])) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        let data = (try? e.encode(["v": c.values, "c": c.coverage])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Phone side. Keeps each day's newest revision; returns how many days changed.
    @discardableResult
    public func cacheSummaries(_ summaries: [DailySummary], now: Date = Date()) async throws -> Int {
        try syncWrite { db in
            var changed = 0
            for s in summaries {
                let have = try Int64.fetchOne(db, sql: "SELECT revision FROM scoreCache WHERE day = ?", arguments: [s.day])
                guard have == nil || have! < s.revision else { continue }
                let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO scoreCache (day, revision, payloadJSON, receivedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(day) DO UPDATE SET revision = excluded.revision, payloadJSON = excluded.payloadJSON,
                                                   receivedAt = excluded.receivedAt
                    """, arguments: [s.day, s.revision, json, Int(now.timeIntervalSince1970)])
                changed += 1
            }
            return changed
        }
    }

    /// Phone side: highest revision cached (ask the Mac for anything newer).
    public func cachedSummaryRevision() async throws -> Int64 {
        try syncRead { db in try Int64.fetchOne(db, sql: "SELECT MAX(revision) FROM scoreCache") ?? 0 }
    }

    /// Phone side: cached summaries from `fromDay` on, by day. Removed days are left out.
    public func cachedSummaries(fromDay: String = "0000-00-00") async throws -> [DailySummary] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT payloadJSON FROM scoreCache WHERE day >= ? ORDER BY day",
                                arguments: [fromDay])
                .compactMap { try? JSONDecoder().decode(DailySummary.self, from: Data($0.utf8)) }
                .filter { !$0.removed }
        }
    }
}
