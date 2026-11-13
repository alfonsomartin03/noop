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
    /// NOOP's own sleep sessions of every kind (primary, interrupted, nap, uncertain) for the last few days, one row per
    /// episode — the sleep screen's session list and correction controls read this.
    @Published var recentSleepEpisodes: [CachedSleepSession] = []
    @Published var loaded = false
    /// Bumped whenever new strap data lands in the store; screens key their loads on it.
    @Published var dataVersion = 0
    /// Bumped when a check-in is saved or cleared (kept apart from `dataVersion`: check-ins never trigger scoring).
    @Published var checkInVersion = 0
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
        let wasLoaded = loaded
        defer { Self.reportFixtureTiming(refreshStarted: now, firstLoad: !wasLoaded) }
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

        // Assign only what changed: every assignment invalidates every view observing the repository, and most
        // refreshes (periodic scoring, post-sync) find the same rows.
        assign(\.days, Self.mergeDaily(imported: imported, computed: computed))
        // Main sleep only for the nightly views; an interrupted night's episodes are recombined into one row (its awake
        // gaps kept as wake) so the night isn't shown as its longest fragment.
        assign(\.sleeps, Self.mergeSleep(imported: impSleep, computed: Self.combineSessions(compSleep.filter(\.isMainSleep))))
        assign(\.recentSleepEpisodes, compSleep.filter { $0.endTs >= nowTs - 3 * 86_400 })
        assign(\.officialDays, Set(imported.map(\.day)))
        assign(\.official, Dictionary(imported.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b }))
        assign(\.estimates, Dictionary(computed.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b }))
        assign(\.loaded, true)
    }

    /// Key-path setter rather than `inout`: an inout access writes the property back (and publishes) even when unchanged.
    private func assign<T: Equatable>(_ key: ReferenceWritableKeyPath<Repository, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    /// Fixture launches print launch-to-content and refresh timings (see `LaunchMode`); normal launches print nothing.
    private static func reportFixtureTiming(refreshStarted: Date, firstLoad: Bool) {
        guard LaunchMode.fixtureStore != nil else { return }
        let ms = { (d: Date) in Int((Date().timeIntervalSince(d) * 1000).rounded()) }
        var line = "[perf] repository refresh \(ms(refreshStarted)) ms\n"
        if firstLoad { line = "[perf] launch-to-content \(ms(LaunchMode.started)) ms\n" + line }
        FileHandle.standardError.write(Data(line.utf8))   // unbuffered, so a killed process keeps its lines
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
    /// Join episode rows that share a session id into one row spanning the session. Gaps become `wake` stages.
    static func combineSessions(_ rows: [CachedSleepSession]) -> [CachedSleepSession] {
        var out: [CachedSleepSession] = []
        var bySession: [String: [CachedSleepSession]] = [:]
        for r in rows {
            if let id = r.sessionId { bySession[id, default: []].append(r) } else { out.append(r) }
        }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (_, eps) in bySession {
            let e = eps.sorted { $0.startTs < $1.startTs }
            guard e.count > 1, let first = e.first, let last = e.last else { out.append(contentsOf: eps); continue }
            var stages: [StageSegment] = []
            for (i, ep) in e.enumerated() {
                if i > 0 { stages.append(StageSegment(start: e[i - 1].endTs, end: ep.startTs, stage: "wake")) }
                if let j = ep.stagesJSON?.data(using: .utf8), let st = try? decoder.decode([StageSegment].self, from: j) {
                    stages += st
                }
            }
            let span = Double(last.endTs - first.startTs)
            let eff = e.reduce(0.0) { $0 + ($1.efficiency ?? 0) * Double($1.endTs - $1.startTs) } / max(span, 1)
            out.append(CachedSleepSession(
                startTs: first.startTs, endTs: last.endTs, efficiency: eff,
                restingHr: e.compactMap(\.restingHr).min(), avgHrv: weightedHRV(e),
                stagesJSON: (try? encoder.encode(stages)).flatMap { String(data: $0, encoding: .utf8) },
                kind: first.kind, sessionId: first.sessionId, reason: first.reason, confidence: first.confidence))
        }
        return out.sorted { $0.startTs < $1.startTs }
    }

    /// Duration-weighted HRV across a session's episodes (the same weighting the scorer uses for the night).
    private static func weightedHRV(_ e: [CachedSleepSession]) -> Double? {
        let pairs = e.compactMap { r in r.avgHrv.map { ($0, Double(r.endTs - r.startTs)) } }
        let w = pairs.reduce(0) { $0 + $1.1 }
        return w > 0 ? pairs.reduce(0) { $0 + $1.0 * $1.1 } / w : nil
    }

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

    /// NOOP's own sleep episodes (raw rows, never recombined, so no repository-inserted gap labels) overlapping a span.
    /// Imported rows are excluded: they hold stage totals, not a timeline.
    func noopSleepEpisodes(from: Int, to: Int) async -> [CachedSleepSession] {
        guard let store = await ensureStore() else { return [] }
        return ((try? await store.sleepSessions(deviceId: computedDeviceId, from: from - 86_400, to: to + 86_400, limit: 200)) ?? [])
            .filter { $0.endTs > from && $0.startTs < to }
    }

    /// Newest stored heart-rate timestamp (any day): how far synced data reaches.
    func latestHRTimestamp() async -> Int? {
        guard let store = await ensureStore() else { return nil }
        return try? await store.latestHRSampleTs(deviceId: deviceId)
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

    /// Every stored day for Data Highlights, per source, read straight from the store (all history, not the UI cache).
    /// Imported WHOOP rows and NOOP's computed rows stay apart; NOOP's sleep performance is its own `SleepPerformance`
    /// (hours vs NOOP's estimated need), never WHOOP's imported score.
    func highlightInputs() async -> [HighlightSource: HighlightInputs] {
        guard let store = await ensureStore() else { return [:] }
        let lo = "0000-01-01", hi = "9999-12-31"
        let imported = (try? await store.dailyMetrics(deviceId: deviceId, from: lo, to: hi)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: lo, to: hi)) ?? []
        let perf = ((try? await store.metricSeries(deviceId: deviceId, key: "sleep_performance", from: lo, to: hi)) ?? [])
            .map { (day: $0.day, value: $0.value) }
        func inputs(_ rows: [DailyMetric], sleep: [(day: String, value: Double)]) -> HighlightInputs {
            func pick(_ f: (DailyMetric) -> Double?) -> [(day: String, value: Double)] { rows.compactMap { r in f(r).map { (r.day, $0) } } }
            return HighlightInputs(sleepPerformance: sleep, recovery: pick(\.recovery), strain: pick(\.strain),
                                   restingHR: pick { $0.restingHr.map(Double.init) }, hrv: pick(\.avgHrv))
        }
        return [.whoop: inputs(imported, sleep: perf), .noop: inputs(computed, sleep: SleepPerformance.series(computed))]
    }

    /// One stored day's row from one source, for a highlight's supporting-day sheet.
    func dailyMetric(_ day: String, source: HighlightSource) async -> DailyMetric? {
        guard let store = await ensureStore() else { return nil }
        let id = source == .whoop ? deviceId : computedDeviceId
        return ((try? await store.dailyMetrics(deviceId: id, from: day, to: day)) ?? []).first
    }

    // MARK: - Health page

    /// Nightly vitals per source for the Health Monitor. Imported WHOOP skin temperature is absolute °C while NOOP stores a
    /// deviation from baseline, so imported skin temperature is left out rather than compared with a different quantity.
    func healthInputs() async -> (noop: [HealthMetric: [HealthPoint]], imported: [HealthMetric: [HealthPoint]]) {
        guard let store = await ensureStore() else { return ([:], [:]) }
        let lo = "0000-01-01", hi = "9999-12-31"
        let imported = (try? await store.dailyMetrics(deviceId: deviceId, from: lo, to: hi)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: lo, to: hi)) ?? []
        func points(_ rows: [DailyMetric], skin: Bool) -> [HealthMetric: [HealthPoint]] {
            func pick(_ f: (DailyMetric) -> Double?) -> [HealthPoint] { rows.compactMap { r in f(r).map { HealthPoint(day: r.day, value: $0) } } }
            var out: [HealthMetric: [HealthPoint]] = [
                .respiratoryRate: pick(\.respRateBpm), .spo2: pick(\.spo2Pct),
                .restingHR: pick { $0.restingHr.map(Double.init) }, .hrv: pick(\.avgHrv),
            ]
            if skin { out[.skinTemp] = pick(\.skinTempDevC) }
            return out
        }
        return (points(computed, skin: true), points(imported, skin: false))
    }

    // MARK: - Check-ins (user-entered context; never read by scoring)

    func checkIns(from: String = "0000-01-01", to: String = "9999-12-31") async -> [CheckInEntryRow] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.checkIns(from: from, to: to)) ?? []
    }

    @discardableResult
    func saveCheckIn(_ entry: CheckInEntryRow) async -> Bool {
        guard let store = await ensureStore() else { return false }
        do { try await store.saveCheckIn(entry); checkInVersion += 1; return true } catch { return false }
    }

    @discardableResult
    func deleteCheckIn(localDate: String, session: CheckInSession) async -> Bool {
        guard let store = await ensureStore() else { return false }
        do { try await store.deleteCheckIn(localDate: localDate, session: session.rawValue); checkInVersion += 1; return true } catch { return false }
    }

    /// Outcome values per day for check-in comparisons, one source at a time (NOOP's own rows, or imported WHOOP rows).
    func checkInOutcomes(source: HighlightSource) async -> [String: CheckInOutcomeDay] {
        guard let store = await ensureStore() else { return [:] }
        let id = source == .whoop ? deviceId : computedDeviceId
        let rows = (try? await store.dailyMetrics(deviceId: id, from: "0000-01-01", to: "9999-12-31")) ?? []
        var out: [String: CheckInOutcomeDay] = [:]
        for r in rows {
            var v: [CheckInMeasure: Double] = [:]
            v[.sleepDuration] = r.totalSleepMin
            v[.disturbances] = r.disturbances.map(Double.init)
            v[.recovery] = r.recovery
            v[.hrv] = r.avgHrv
            v[.restingHR] = r.restingHr.map(Double.init)
            v[.respiratoryRate] = r.respRateBpm
            v[.dayStrain] = r.strain
            out[r.day] = CheckInOutcomeDay(day: r.day, values: v)
        }
        return out
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
        // WHOOP/Apple workout, and show one row per event (see WorkoutReconciliation).
        let detected = ((try? await store.workouts(deviceId: deviceId + "-noop", from: lo, to: hi, limit: 5000)) ?? [])
        rows += WorkoutReconciliation.reconcile(detected.filter { w in
            !rows.contains(where: { w.startTs < $0.endTs && $0.startTs < w.endTs })
        })
        let labels = (try? await store.workoutLabels()) ?? []
        return WorkoutLabels.applying(labels, to: rows).sorted { $0.startTs > $1.startTs }
    }

    /// The label behind a workout, with who set it.
    func activityLabel(_ w: WorkoutRow) async -> ActivityLabel {
        guard let store = await ensureStore() else { return .unknown }
        // `w` as screens hold it already carries a resolved name, so resolve from the stored row.
        var stored = w
        if w.source != "noop" {
            for id in [deviceId, "apple-health"] {
                let rows = (try? await store.workouts(deviceId: id, from: w.startTs, to: w.startTs, limit: 5)) ?? []
                if let raw = rows.first { stored = raw; break }
            }
        }
        return WorkoutLabels.resolve(stored, labels: (try? await store.workoutLabels()) ?? [])
    }

    /// Record the user's choice; nil removes it. An existing label keeps the span it was set under. This changes no
    /// score: screens reload, nothing is recalculated.
    func setActivity(_ type: ActivityType?, for w: WorkoutRow, current: ActivityLabel) async {
        guard let store = await ensureStore() else { return }
        let start = current.stored?.workoutStartTs ?? w.startTs, end = current.stored?.workoutEndTs ?? w.endTs
        if let type {
            try? await store.setWorkoutLabel(WorkoutLabelRow(workoutStartTs: start, workoutEndTs: end, activity: type.rawValue,
                                                             provenance: LabelProvenance.userSelected.rawValue,
                                                             updatedAt: Int(Date().timeIntervalSince1970)))
        } else {
            try? await store.clearWorkoutLabel(workoutStartTs: start)
        }
        dataVersion += 1
    }

    /// NOOP's load accounting for a day, if it scored that day.
    func dayLoad(_ day: String) async -> DayLoadRecord? {
        guard let store = await ensureStore() else { return nil }
        let rows = (try? await store.loadRecords(deviceId: deviceId + "-noop", from: day, to: day)) ?? []
        return rows.compactMap(DayLoadRecord.init(row:)).first
    }

    /// NOOP's day load records (awake supported time, zone seconds) for every scored day in [from, to].
    func dayLoads(from: String, to: String) async -> [DayLoadRecord] {
        guard let store = await ensureStore() else { return [] }
        let rows = (try? await store.loadRecords(deviceId: deviceId + "-noop", from: from, to: to)) ?? []
        return rows.compactMap(DayLoadRecord.init(row:))
    }

    /// NOOP's load accounting for a detected session, if the row is one.
    func sessionLoad(_ w: WorkoutRow) async -> SessionLoadRecord? {
        guard let store = await ensureStore() else { return nil }
        let day = AnalyticsEngine.dayString(w.startTs)
        let rows = (try? await store.loadRecords(deviceId: deviceId + "-noop", from: day, to: day)) ?? []
        return rows.compactMap(SessionLoadRecord.init(row:)).first { $0.start == w.startTs }
    }

    /// What the user logged against this workout, if anything.
    func trainingLog(_ w: WorkoutRow) async -> TrainingLogEntry? {
        guard let store = await ensureStore() else { return nil }
        return try? await store.trainingLog(workoutStartTs: w.startTs, workoutEndTs: w.endTs)
    }

    // User-entered, so these write straight to the training-log tables; none of this touches scores or `dataVersion`.
    /// Returns false if nothing was stored. Pass the span an existing entry was logged under (see `TrainingLogEntry`).
    func saveEffort(_ rpe: SessionRPE, workoutStartTs: Int, workoutEndTs: Int) async -> Bool {
        await writeLog { try await $0.upsertSessionEffort(rpe.row(workoutStartTs: workoutStartTs, workoutEndTs: workoutEndTs)) }
    }

    func clearEffort(workoutStartTs: Int) async -> Bool {
        await writeLog { try await $0.deleteSessionEffort(workoutStartTs: workoutStartTs) }
    }

    func addSet(_ set: StrengthSet, workoutStartTs: Int, workoutEndTs: Int, collectedAt: Int) async -> Bool {
        await writeLog {
            try await $0.addStrengthSet(set.row(workoutStartTs: workoutStartTs, workoutEndTs: workoutEndTs, collectedAt: collectedAt))
        }
    }

    func deleteSet(workoutStartTs: Int, setIndex: Int) async -> Bool {
        await writeLog { try await $0.deleteStrengthSet(workoutStartTs: workoutStartTs, setIndex: setIndex) }
    }

    private func writeLog(_ write: (WhoopStore) async throws -> Void) async -> Bool {
        guard let store = await ensureStore() else { return false }
        do { try await write(store); return true } catch { return false }
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
