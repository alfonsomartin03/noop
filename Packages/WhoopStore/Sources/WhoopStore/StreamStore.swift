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
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, seq, rrMs) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, seq, rrMs) DO NOTHING
                    """)
                for (r, seq) in WhoopStore.sequenceRR(streams.rr) {
                    try stmt.execute(arguments: [deviceId, r.ts, seq, r.rrMs])
                    rr += db.changesCount
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

    /// Assign each beat its position among the beats of the same second (acquisition order), and drop exact
    /// re-deliveries of a beat inside one batch. A repeated value is a genuine beat while the bucket still fits in
    /// one second (two 450 ms beats at 130 bpm); once a repeat would push the bucket past `rrBucketSpanMs`, it is a
    /// retransmitted record, not physiology. Deterministic, so re-saving the same chunk maps to the same keys.
    static func sequenceRR(_ rr: [RRInterval]) -> [(RRInterval, Int)] {
        var buckets: [Int: [Int]] = [:]          // ts → rrMs kept so far, in order
        var out: [(RRInterval, Int)] = []
        out.reserveCapacity(rr.count)
        for r in rr {
            var b = buckets[r.ts, default: []]
            let spanAfterFirst = b.dropFirst().reduce(0, +) + (b.isEmpty ? 0 : r.rrMs)
            if b.contains(r.rrMs) && spanAfterFirst > rrBucketSpanMs { continue }
            out.append((r, b.count))
            b.append(r.rrMs)
            buckets[r.ts] = b
        }
        return out
    }
}
