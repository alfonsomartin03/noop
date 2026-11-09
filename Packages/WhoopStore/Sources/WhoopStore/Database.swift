import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    // Migrations are append-only: never edit an old one, add a new vN so existing installs upgrade in place.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        // v2: key/value cursors (sync positions).
        migrator.registerMigration("v2") { db in
            try db.create(table: "cursors") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .integer)
            }
        }
        // v3: extra biometric streams (SpO2, skin temp, respiration, gravity).
        migrator.registerMigration("v3") { db in
            // type-47 biometric streams (mirror the existing decoded tables, PK (deviceId, ts)).
            try db.create(table: "spo2Sample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("red", .integer).notNull()
                t.column("ir", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "skinTempSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "respSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "gravitySample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        // v4: cached derived results (sleep sessions, daily metrics).
        migrator.registerMigration("v4") { db in
            // Server-derived metrics cached locally (Task 3.1: History = union(phone, server)).
            // sleepSession: one row per sleep session, natural key (deviceId, startTs).
            try db.create(table: "sleepSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("efficiency", .double)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("stagesJSON", .text)
                t.primaryKey(["deviceId", "startTs"])
            }
            // dailyMetric: one row per calendar day (YYYY-MM-DD), natural key (deviceId, day).
            try db.create(table: "dailyMetric") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("totalSleepMin", .double)
                t.column("efficiency", .double)
                t.column("deepMin", .double)
                t.column("remMin", .double)
                t.column("lightMin", .double)
                t.column("disturbances", .integer)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("recovery", .double)
                t.column("strain", .double)
                t.column("exerciseCount", .integer)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-row upload sync flag for the decoded streams (mirrors rawBatch.syncedAt).
            // The OLD upload path used a forward-only highwater per stream, which permanently
            // stranded backfilled (older-ts) rows once the highwater jumped to a recent ts.
            // The fix: `synced` is set to 1 only after a successful upload, so the Uploader can
            // drain WHERE synced=0 regardless of ts order. Existing rows default to 0 → they
            // re-upload once (idempotent server-side), catching up the currently-stranded rows.
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                try db.alter(table: table) { t in
                    t.add(column: "synced", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v6") { db in
            // Charging flag for the dense BATTERY_LEVEL-event battery series (nullable: the
            // command-response battery path doesn't report it).
            try db.alter(table: "battery") { t in
                t.add(column: "charging", .boolean)
            }
        }
        migrator.registerMigration("v7") { db in
            // In-sleep signal aggregates cached from /v1/daily so the Sleep tab can display
            // SpO2, skin-temperature deviation, and respiration rate without a network round-trip.
            // All three are nullable: they require sufficient raw biometric data on the server.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Pct", .double)
                t.add(column: "skinTempDevC", .double)
                t.add(column: "respRateBpm", .double)
            }
        }
        // v8: journal, workouts and Apple Health daily aggregates.
        migrator.registerMigration("v8") { db in
            // Journal, workouts, and Apple-Health daily aggregates.
            // journal: one row per (deviceId, day, question) — user-answered daily prompts.
            try db.create(table: "journal") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("question", .text).notNull()
                t.column("answeredYes", .integer).notNull()
                t.column("notes", .text)
                t.primaryKey(["deviceId", "day", "question"])
            }
            // workout: one row per (deviceId, startTs, sport). All metric columns nullable.
            try db.create(table: "workout") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("sport", .text).notNull()
                t.column("source", .text).notNull()
                t.column("durationS", .double)
                t.column("energyKcal", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("strain", .double)
                t.column("distanceM", .double)
                t.column("zonesJSON", .text)
                t.column("notes", .text)
                t.primaryKey(["deviceId", "startTs", "sport"])
            }
            // appleDaily: Apple-Health-specific daily aggregates, one row per (deviceId, day).
            // All metric columns nullable.
            try db.create(table: "appleDaily") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("steps", .integer)
                t.column("activeKcal", .double)
                t.column("basalKcal", .double)
                t.column("vo2max", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("walkingHr", .integer)
                t.column("weightKg", .double)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v9") { db in
            // Generic long-format metric store: the substrate for a metric explorer where every
            // metric is queryable/comparable uniformly. One row per (deviceId, day, key); `value`
            // is always a REAL so any scalar metric (server-derived, Apple-Health, journal-encoded,
            // …) can be projected into a single tall table and read back by key with no per-metric
            // schema. Natural key (deviceId, day, key).
            try db.create(table: "metricSeries") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .double).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            // Per-metric range reads scan (deviceId, key) then walk days in order. The PK is
            // (deviceId, day, key) so it can't serve those reads efficiently; this index makes
            // metricSeries(key:from:to:) and metricDays(key:) index-only.
            try db.create(index: "idx_metricSeries_device_key_day",
                          on: "metricSeries", columns: ["deviceId", "key", "day"])
        }
        migrator.registerMigration("v10") { db in
            // R-R beats need their order WITHIN a second. Timestamps are whole seconds, so two genuine beats can share
            // one; the v1 key (deviceId, ts, rrMs) silently dropped a second beat with the same ms value, and reads
            // sorted same-second beats by value instead of by acquisition. `seq` = position of the beat among the
            // beats of its second, in acquisition order. Existing rows keep their insertion order (rowid) as seq.
            try db.create(table: "rrInterval_v10") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.column("synced", .integer).notNull().defaults(to: 0)
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deviceId", "ts", "seq", "rrMs"])
            }
            try db.execute(sql: """
                INSERT INTO rrInterval_v10 (deviceId, ts, rrMs, synced, seq)
                SELECT deviceId, ts, rrMs, synced,
                       ROW_NUMBER() OVER (PARTITION BY deviceId, ts ORDER BY rowid) - 1
                FROM rrInterval ORDER BY deviceId, ts, rowid
                """)
            try db.drop(table: "rrInterval")
            try db.rename(table: "rrInterval_v10", to: "rrInterval")
        }
        migrator.registerMigration("v11") { db in
            // Provenance of each DERIVED value: what it is, how and by which algorithm version it was computed, its
            // coverage and why it may be unavailable. Lets a later run tell current-version values from stale ones
            // instead of trusting every stored row (see StrandAnalytics MetricIdentity). One row per (device, day, key).
            try db.create(table: "metricProvenance") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("definition", .text).notNull()
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("hardware", .text).notNull()
                t.column("algorithmVersion", .text).notNull()
                t.column("context", .text).notNull()
                t.column("aggregation", .text).notNull()
                t.column("coverage", .double)
                t.column("exclusionReasons", .text).notNull().defaults(to: "")
                t.column("scoringVersion", .integer).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
        }
        migrator.registerMigration("v12") { db in
            // Load accounting behind a derived day or session: coverage, calibration snapshot, versions and reasons, as
            // JSON (StrandAnalytics owns the shape, like stagesJSON). Lets a past day keep the calibration it was scored
            // with. One row per day (scope "day", startTs 0) and per detected session (scope "session").
            try db.create(table: "loadRecord") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("algorithmVersion", .text).notNull()
                t.column("payload", .text).notNull()
                t.primaryKey(["deviceId", "day", "scope", "startTs"])
            }
        }
        migrator.registerMigration("v13") { db in
            // What the user reported about a workout: session effort and logged strength sets. These are source data,
            // not derived rows, so they have no deviceId: the derived writers delete and archive by deviceId and can
            // never match them. A workout is identified by the start it had when logged; workoutEndTs keeps that span
            // so the entry can be found again if a re-score moves the start. One effort row per workout: a missing
            // response is no row, never a zero.
            try db.create(table: "sessionEffort") { t in
                t.column("workoutStartTs", .integer).notNull().primaryKey()
                t.column("workoutEndTs", .integer).notNull()
                t.column("scale", .text).notNull()
                t.column("rpe", .double).notNull().check(sql: "rpe >= 0 AND rpe <= 10")
                t.column("sessionMinutes", .double).notNull().check(sql: "sessionMinutes > 0")
                t.column("collectedAt", .integer).notNull()
                t.column("provenance", .text).notNull()
            }
            // externalKg NULL = no external load logged (bodyweight work); never filled in with body mass.
            try db.create(table: "strengthSet") { t in
                t.column("workoutStartTs", .integer).notNull()
                t.column("setIndex", .integer).notNull()
                t.column("workoutEndTs", .integer).notNull()
                t.column("exercise", .text).notNull().check(sql: "length(trim(exercise)) > 0")
                t.column("reps", .integer).notNull().check(sql: "reps > 0")
                t.column("externalKg", .double).check(sql: "externalKg >= 0")
                t.column("rir", .integer).check(sql: "rir >= 0")
                t.column("collectedAt", .integer).notNull()
                t.column("provenance", .text).notNull()
                t.primaryKey(["workoutStartTs", "setIndex"])
            }
        }
        migrator.registerMigration("v14") { db in
            // Who says what a workout was. Source data like the training log: no deviceId, so a re-score can't reach it,
            // and workoutEndTs keeps the span so the label still finds its workout if detection moves the edges.
            try db.create(table: "workoutLabel") { t in
                t.column("workoutStartTs", .integer).notNull().primaryKey()
                t.column("workoutEndTs", .integer).notNull()
                t.column("activity", .text).notNull()
                t.column("provenance", .text).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            // What each stored day's score was computed from, so unchanged history is reused and only affected days are
            // recomputed. Written in the same transaction as the day's results (see DerivedStore).
            try db.create(table: "dayScoreState") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("algorithmKey", .text).notNull()
                t.column("configKey", .text).notNull()
                t.column("inputRevision", .integer).notNull()
                t.column("calibrationKey", .text).notNull()
                t.column("baselineKey", .text).notNull()
                t.column("knownSessionsKey", .text).notNull()
                t.column("rangeStart", .integer).notNull()
                t.column("rangeEnd", .integer).notNull()
                t.column("finalized", .boolean).notNull()
                t.column("hasResult", .boolean).notNull()
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v15") { db in
            // Sleep sessions carry their classification (primary / interruptedPrimary / nap / uncertain) and the session
            // they belong to, so naps and interrupted nights can be shown and corrected. NULL kind = a legacy row, which
            // was always main sleep.
            try db.alter(table: "sleepSession") { t in
                t.add(column: "kind", .text)
                t.add(column: "sessionId", .text)
                t.add(column: "reason", .text)
                t.add(column: "confidence", .double)
            }
            // User sleep corrections. Source data like workoutLabel: no deviceId, never touched by re-scoring.
            try db.create(table: "sleepCorrection") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("action", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("atTs", .integer)
                t.column("newStartTs", .integer)
                t.column("newEndTs", .integer)
                t.column("createdAt", .integer).notNull()
            }
        }
        migrator.registerMigration("v16") { db in
            // Append-only alarm history (AlarmHistoryStore.swift). Source data: no deviceId, never touched by re-scoring,
            // alarm edits or deletion. `dedupeKey` is unique so live and history copies of one strap event land once.
            try db.create(table: "alarmEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("occurrenceId", .text)
                t.column("kind", .text).notNull()
                t.column("recordedAt", .double).notNull()
                t.column("deviceTs", .integer)
                t.column("mappedHostTs", .double)
                t.column("receivedAt", .double)
                t.column("provenance", .text).notNull()
                t.column("dedupeKey", .text).unique()
                t.column("payload", .text)
            }
            try db.create(index: "alarmEvent_occurrence", on: "alarmEvent", columns: ["occurrenceId", "recordedAt"])
            // The wearer's own notes about an occurrence ("felt it", …), kept apart from device evidence.
            try db.create(table: "alarmAnnotation") { t in
                t.column("occurrenceId", .text).notNull().primaryKey()
                t.column("label", .text).notNull()
                t.column("createdAt", .double).notNull()
            }
        }
        migrator.registerMigration("v17") { db in
            // Morning / evening check-ins (CheckInStore.swift). User-entered context: never read by scoring. One entry per
            // local date and session; each answer keeps the prompt id + version it was given under.
            try db.create(table: "checkInEntry") { t in
                t.column("localDate", .text).notNull()
                t.column("session", .text).notNull()
                t.column("status", .text).notNull()
                t.column("note", .text)
                t.column("timeZone", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.primaryKey(["localDate", "session"])
            }
            try db.create(table: "checkInAnswer") { t in
                t.column("localDate", .text).notNull()
                t.column("session", .text).notNull()
                t.column("promptId", .text).notNull()
                t.column("promptVersion", .integer).notNull()
                t.column("answer", .text).notNull()
                t.column("position", .integer).notNull()
                t.primaryKey(["localDate", "session", "promptId"])
            }
        }
        return migrator
    }
}
