import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically — important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Insert or update a device row (natural key = id).
    // Upsert: first call sets firstSeen; later calls only refresh mac/name/lastSeen.
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// NOTE: the `synced` column (added by migration v5 for a since-removed server-upload feature)
    /// is intentionally NOT written here — it is unused and defaults to 0. The column is left in the
    /// schema to avoid a DROP COLUMN migration over existing data; nothing reads it.
    @discardableResult
    // DO NOTHING on conflict makes imports/backfills idempotent: re-ingesting the same samples never duplicates rows.
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        return try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            // Reuse one prepared statement per table instead of recompiling the same SQL on every
            // row. This is the hottest write path (every Collector.flush + every Backfiller chunk
            // over potentially millions of historical rows). cachedStatement persists the compiled
            // statement on the connection across insert() calls too. Each loop is guarded so empty
            // streams (the common live case) compile nothing.
            // Same pattern for each stream below: skip empty streams, reuse one prepared statement, count rows actually inserted.
            if !streams.hr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.hr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm])
                    hr += db.changesCount
                }
            }
            if !streams.rr.isEmpty {
                // Beats are keyed by their position within the second ACROSS batches: a second's beats can arrive in
                // two inserts (a live flush boundary, a re-pulled chunk), so the incoming beats are aligned against
                // what is already stored for that second instead of being numbered from 0 again.
                let existingStmt = try db.cachedStatement(sql: """
                    SELECT rrMs FROM rrInterval WHERE deviceId = ? AND ts = ? ORDER BY seq ASC, rowid ASC
                    """)
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, seq, rrMs) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, seq, rrMs) DO NOTHING
                    """)
                for (ts, group) in WhoopStore.groupBySecond(streams.rr) {
                    let existing = try Int.fetchAll(existingStmt, arguments: [deviceId, ts])
                    for (rrMs, seq) in WhoopStore.newBeats(existing: existing, incoming: group) {
                        try stmt.execute(arguments: [deviceId, ts, seq, rrMs])
                        rr += db.changesCount
                    }
                }
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
            }
            if !streams.spo2.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.spo2 {
                    try stmt.execute(arguments: [deviceId, s.ts, s.red, s.ir])
                    spo2 += db.changesCount
                }
            }
            if !streams.skinTemp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.skinTemp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    skin += db.changesCount
                }
            }
            if !streams.resp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.resp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    resp += db.changesCount
                }
            }
            if !streams.gravity.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.gravity {
                    try stmt.execute(arguments: [deviceId, s.ts, s.x, s.y, s.z])
                    grav += db.changesCount
                }
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav)
        }
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try syncRead { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0)
        }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }
}

extension WhoopStore {
    /// Longest span (ms) the beats AFTER the first one in a single whole-second bucket can plausibly cover: each beat
    /// ends inside that second, so only the first interval may reach back before it. 100 ms of slack for stamping jitter.
    static let rrBucketSpanMs = 1_100

    /// Beats grouped by whole second, seconds in first-appearance order, beats in acquisition order.
    static func groupBySecond(_ rr: [RRInterval]) -> [(Int, [Int])] {
        var order: [Int] = [], groups: [Int: [Int]] = [:]
        for r in rr {
            if groups[r.ts] == nil { order.append(r.ts) }
            groups[r.ts, default: []].append(r.rrMs)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// Which incoming beats of one second are new, and the `seq` each gets, given the beats already stored for that
    /// second (in seq order). Deterministic, so any re-delivery maps to the same keys:
    ///   1. the incoming beats occur as a contiguous run of the stored ones → an exact re-delivery, nothing new;
    ///   2. the longest stored suffix that equals an incoming prefix is the overlap of a re-pulled chunk → dropped;
    ///   3. the rest is appended after the stored beats; a repeated value that no longer fits the one-second bucket
    ///      (`rrBucketSpanMs`) is a retransmission, not physiology, and is dropped.
    /// Residual ambiguity, resolved toward never duplicating: an incoming group identical to stored beats is treated
    /// as a re-delivery even when, at > ~120 bpm, it could be a genuine new beat of the same length.
    static func newBeats(existing: [Int], incoming: [Int]) -> [(rrMs: Int, seq: Int)] {
        guard !incoming.isEmpty else { return [] }
        if incoming.count <= existing.count {
            for off in 0...(existing.count - incoming.count) where Array(existing[off..<off + incoming.count]) == incoming {
                return []
            }
        }
        var overlap = 0
        for k in stride(from: min(existing.count, incoming.count), through: 1, by: -1)
            where Array(existing.suffix(k)) == Array(incoming.prefix(k)) { overlap = k; break }
        var bucket = existing
        var out: [(rrMs: Int, seq: Int)] = []
        for v in incoming.dropFirst(overlap) {
            let spanAfterFirst = bucket.dropFirst().reduce(0, +) + (bucket.isEmpty ? 0 : v)
            if bucket.contains(v) && spanAfterFirst > rrBucketSpanMs { continue }
            out.append((v, bucket.count))
            bucket.append(v)
        }
        return out
    }
}
