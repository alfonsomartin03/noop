import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Read model over the on-device WhoopStore. Opens its own handle (WAL + busy-timeout makes the
/// two-handle BLEManager+Repository pattern safe) and publishes the dashboard caches the screens bind to.
@MainActor
// Read model for the UI: owns a store handle and publishes the merged dashboard data.
final class Repository: ObservableObject {
    let deviceId: String
    /// Source id for on-device computed scores (recovery/strain/sleep derived from the raw strap
    /// streams by IntelligenceEngine). Merged UNDER the imported `deviceId` rows at read time, so a
    /// real WHOOP import always wins and the strap-only user still gets a populated dashboard.
    // Rows computed on-device live under their own id and are merged under imported ones at read time.
    private var computedDeviceId: String { deviceId + "-noop" }
    private var store: WhoopStore?

    /// Daily metrics (recovery/strain/sleep/HRV/RHR…) over the recent window, oldest→newest.
    @Published var days: [DailyMetric] = []
    /// Cached sleep sessions over the recent window, oldest→newest.
    @Published var sleeps: [CachedSleepSession] = []
    @Published var loaded = false
    /// Bumped whenever new strap data lands in the store; screens key their loads on it.
    @Published var dataVersion = 0
    /// Days whose merged row is an official WHOOP value (imported). Every other day is a NOOP estimate.
    @Published var officialDays: Set<String> = []
    /// NOOP's own estimates keyed by day, kept even where an official value hides them in `days`.
    @Published var estimates: [String: DailyMetric] = [:]
    /// Imported (official) rows keyed by day.
    @Published var official: [String: DailyMetric] = [:]

    init(deviceId: String) { self.deviceId = deviceId }

    /// The most recent day with data (treated as "today" for the dashboard hero).
    var today: DailyMetric? { days.last }
    /// The trailing 7 days (for the week strip), oldest→newest.
    var week: [DailyMetric] { Array(days.suffix(7)) }

    // Lazy open: the database is created on first use.
    private func ensureStore() async -> WhoopStore? {
        if let store { return store }
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        let s = try? await WhoopStore(path: path)
        if let s { try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP") }
        store = s
        return s
    }

    /// Expose the shared store handle (used by the importer to persist mapped rows).
    func storeHandle() async -> WhoopStore? { await ensureStore() }

    /// Checkpoint the WAL into the main DB file if the store is already open, so a file-level
    /// backup captures everything. No-op (returns false) if no handle exists yet — the caller
    /// then copies the on-disk files as-is, which still includes the -wal sidecar.
    func checkpointForBackup() async -> Bool {
        guard let store else { return false }
        do { try await store.checkpointWAL(); return true } catch { return false }
    }

    /// Reload the dashboard caches over the last `nDays`, merging imported history with the
    /// on-device computed scores so a strap-only user still gets a populated dashboard.
    // Loads imported + computed rows, merges them, and records which days are 'official' (imported) vs NOOP estimates.
    func refresh(days nDays: Int = 4000) async {
        guard let store = await ensureStore() else { return }
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        let lo = nowTs - nDays * 86_400, hi = nowTs + 86_400

        let imported = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
        // Drop computed rows dated after local today: older builds keyed days in UTC, so after ~8 pm a
        // near-empty "tomorrow" row existed and shadowed the real today in `today = days.last`.
        let todayKey = Self.dayString(now)
        // Rows dated after local today are dropped (older builds keyed days in UTC and created a bogus 'tomorrow').
        let computed = ((try? await store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)) ?? [])
            .filter { $0.day <= todayKey }
        let impSleep = (try? await store.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: 4000)) ?? []
        let compSleep = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []

        self.days = Self.mergeDaily(imported: imported, computed: computed)
        self.sleeps = Self.mergeSleep(imported: impSleep, computed: compSleep)
        self.officialDays = Set(imported.map(\.day))
        self.official = Dictionary(imported.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        self.estimates = Dictionary(computed.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        self.loaded = true
    }

    /// Today's stored heart-rate samples (local midnight → now), oldest→newest.
    func todayHeartRate() async -> [HRSample] {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        return await hrSamples(from: start, to: Int(Date().timeIntervalSince1970) + 60, limit: 200_000)
    }

    /// True when `day`'s shown scores come from a WHOOP import rather than a NOOP estimate.
    func isOfficial(_ day: String?) -> Bool { day.map(officialDays.contains) ?? false }

    /// Official-vs-estimate comparison for one metric over days that have both.
    func accuracy(_ pick: (DailyMetric) -> Double?) -> EstimateAccuracy.Result? {
        func series(_ m: [String: DailyMetric]) -> [String: Double] {
            m.compactMapValues(pick)
        }
        return EstimateAccuracy.compare(official: series(official), estimate: series(estimates))
    }

    /// WHOOP-imported values are treated as the more accurate source and win per FIELD; NOOP's own
    /// computed values only fill the fields (or whole days) the import doesn't have.
    // Precedence is per field: WHOOP-imported values win, NOOP fills only what is missing.
    private static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric]) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for i in imported {
            guard let c = byDay[i.day] else { byDay[i.day] = i; continue }
            byDay[i.day] = DailyMetric(
                day: i.day,
                totalSleepMin: i.totalSleepMin ?? c.totalSleepMin, efficiency: i.efficiency ?? c.efficiency,
                deepMin: i.deepMin ?? c.deepMin, remMin: i.remMin ?? c.remMin, lightMin: i.lightMin ?? c.lightMin,
                disturbances: i.disturbances ?? c.disturbances, restingHr: i.restingHr ?? c.restingHr,
                avgHrv: i.avgHrv ?? c.avgHrv, recovery: i.recovery ?? c.recovery, strain: i.strain ?? c.strain,
                exerciseCount: i.exerciseCount ?? c.exerciseCount, spo2Pct: i.spo2Pct ?? c.spo2Pct,
                skinTempDevC: i.skinTempDevC ?? c.skinTempDevC, respRateBpm: i.respRateBpm ?? c.respRateBpm)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Same precedence for sleep sessions, keyed by the day the night ends on.
    // Sleep sessions are matched by the day the night ENDS; imported replaces computed.
    private static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            dayString(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        // One session per ending day, and it must be the night: the LONGEST that day, not whichever sorts last
        // (a later short session used to replace the night). Imported sessions still beat computed ones.
        func longest(_ rows: [CachedSleepSession]) -> [String: CachedSleepSession] {
            var m: [String: CachedSleepSession] = [:]
            for s in rows {
                let k = endDay(s)
                if let cur = m[k], cur.endTs - cur.startTs >= s.endTs - s.startTs { continue }
                m[k] = s
            }
            return m
        }
        var byDay = longest(computed)
        for (k, s) in longest(imported) { byDay[k] = s }
        return byDay.values.sorted { $0.startTs < $1.startTs }
    }

    // MARK: - Detail passthroughs

    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
    }

    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    func sleepSessions(from: Int, to: Int, limit: Int = 100) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    // MARK: - Metric explorer reads (generic substrate)

    /// Daily series for any metric key from a given source ("my-whoop" / "apple-health").
    func series(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        let from = Self.dayString(now.addingTimeInterval(-Double(days) * 86_400))
        let to = Self.dayString(now.addingTimeInterval(86_400))
        let pts = (try? await store.metricSeries(deviceId: source, key: key, from: from, to: to)) ?? []
        return pts.map { ($0.day, $0.value) }
    }

    func availableKeys(source: String) async -> [String] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.metricKeys(deviceId: source)) ?? []
    }

    /// Logged behaviours (Whoop journal) for correlation insights.
    func journalEntries(days: Int = 4000) async -> [JournalEntry] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.journalEntries(
            deviceId: deviceId,
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// All workouts (Whoop + Apple Health), newest first.
    // Combines WHOOP + Apple workouts with NOOP-detected ones, hiding detections that overlap a real workout.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await ensureStore() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        var rows = (try? await store.workouts(deviceId: deviceId, from: lo, to: hi, limit: 5000)) ?? []
        rows += (try? await store.workouts(deviceId: "apple-health", from: lo, to: hi, limit: 5000)) ?? []
        // NOOP auto-detected workouts fill in what no import covers: hide any that overlap a real
        // WHOOP/Apple workout, and collapse re-detections of the same session (edges shift a little
        // between analysis windows).
        let detected = ((try? await store.workouts(deviceId: deviceId + "-noop", from: lo, to: hi, limit: 5000)) ?? [])
            .sorted { $0.startTs < $1.startTs }
        var kept: [WorkoutRow] = []
        for w in detected where !rows.contains(where: { w.startTs < $0.endTs && $0.startTs < w.endTs }) {
            if let l = kept.last, w.startTs <= l.endTs {
                if (w.durationS ?? 0) > (l.durationS ?? 0) { kept[kept.count - 1] = w }
            } else { kept.append(w) }
        }
        rows += kept
        return rows.sorted { $0.startTs > $1.startTs }
    }

    /// Apple Health daily aggregates (steps/energy/vo2/hr).
    func appleDailyRows(days: Int = 4000) async -> [AppleDaily] {
        guard let store = await ensureStore() else { return [] }
        let now = Date()
        return (try? await store.appleDaily(
            deviceId: "apple-health",
            from: Self.dayString(now.addingTimeInterval(-Double(days) * 86_400)),
            to: Self.dayString(now.addingTimeInterval(86_400)))) ?? []
    }

    /// Day key on the wearer's clock, in the zone in force at that instant (`ZoneTimeline`).
    static func dayString(_ d: Date) -> String { ZoneTimeline.shared.dayString(Int(d.timeIntervalSince1970)) }
}
