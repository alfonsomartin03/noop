import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud — for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
// Turns raw strap streams into recovery/strain/sleep/workouts on-device and stores them under a separate '-noop' device id.
final class IntelligenceEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        var id: String { day }
    }

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// Bump when scoring rules change: the app then wipes its own derived rows and re-scores all history once.
    /// v3: causal NOOP-only baselines, unknown sleep state, vitals quality gates, separate recovery components.
    static let scoringVersion = 3
    private static let scoringVersionKey = "scoringVersionApplied"

    /// Re-score everything from the raw strap data. Only NOOP's own derived rows (the "-noop" id) are wiped;
    /// WHOOP imports and raw samples are never touched. The previous version's daily rows are first archived under
    /// "-noop-v<old>" (never read by the dashboard) so outputs of earlier algorithm versions stay comparable.
    func recomputeAll(maxDays: Int = 730) async {
        guard !computing, let store = await repo.storeHandle() else { return }
        let computedId = deviceId + "-noop"
        let old = UserDefaults.standard.integer(forKey: Self.scoringVersionKey)
        if let rows = try? await store.dailyMetrics(deviceId: computedId, from: "0000-00-00", to: "9999-99-99"),
           !rows.isEmpty {
            _ = try? await store.upsertDailyMetrics(rows, deviceId: computedId + "-v\(old)")
        }
        try? await store.deleteDerived(deviceId: computedId)
        await analyzeRecent(maxDays: maxDays)
        UserDefaults.standard.set(Self.scoringVersion, forKey: Self.scoringVersionKey)
    }

    /// Runs the full re-score once per scoring version (first launch after an update to the rules).
    func recomputeIfRulesChanged() async {
        if UserDefaults.standard.integer(forKey: Self.scoringVersionKey) < Self.scoringVersion { await recomputeAll() }
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    /// Personal baselines for scoring `day`: built ONLY from NOOP's own computed nights (`noopHistory`, the "-noop"
    /// rows) dated strictly BEFORE `day`. Imported WHOOP values are a different measurement (different processing and
    /// aggregation) and never enter; a later night can never change an earlier day's score. Shared with the
    /// diagnostics panel so both show the same numbers.
    static func baselines(for day: String, noopHistory: [DailyMetric]) -> AnalyticsEngine.ProfileBaselines {
        let obs = MetricObservation.noopNightly(noopHistory)
        return CausalBaselines.legacyProfile(rmssd: obs.rmssd, restingHR: obs.restingHR, before: day)
    }

    // Per day, OLDEST FIRST: read a window of raw streams -> baselines from earlier NOOP nights only ->
    // AnalyticsEngine.analyzeDay -> the result joins the history for later days -> save once at the end.
    func analyzeRecent(maxDays: Int = 21) async {
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return }

        guard !computing else { return }   // never overlap two full re-scores
        computing = true
        defer { computing = false }

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        var detected: [WorkoutRow] = []
        var components: [MetricPoint] = []

        // Walk back one calendar day at a time from today, on the wearer's own clock: the day keys and the
        // day boundaries come from the zone in force on each date (so DST days and trips are handled), not from
        // "now minus k×24 h", which drifts across a clock change and mislabels days. Then score OLDEST FIRST.
        ZoneTimeline.shared.refreshFromSystem()
        var cursor = now
        var plan: [(day: String, range: (from: Int, to: Int))] = []
        for _ in 0..<maxDays {
            let day = AnalyticsEngine.dayString(cursor)
            guard let range = ZoneTimeline.shared.dayRange(day) else { break }
            cursor = range.from - 1          // previous calendar day for the next pass
            plan.append((day, range))
        }
        plan.reverse()

        // NOOP's own nightly history as stored (current scoring version: a version bump wipes and rebuilds it).
        // Read from the store, not `repo.estimates`, which can be stale right after `recomputeAll` wiped the rows.
        let computedId = deviceId + "-noop"
        var history: [String: DailyMetric] = Dictionary(
            ((try? await store.dailyMetrics(deviceId: computedId, from: "0000-00-00", to: "9999-99-99")) ?? [])
                .map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })

        var analyzedRanges: [(from: Int, to: Int)] = []
        for (day, range) in plan {
            // A night ending on this day can begin the previous evening: read from 16 h before the day starts
            // (enough waking context for the HR reference) to the day's end. Sleep that ends today is fully inside.
            let from = range.from - 16 * 3_600
            let to = range.to

            let hr = (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            // (ranges are recorded below once a day actually has raw data)
            // Skip days without real raw data (a stray sample isn't enough to score).
            guard hr.count >= 200 else { continue }   // need real raw data, not a stray sample
            analyzedRanges.append(range)
            let rr = (try? await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            let resp = (try? await store.respSamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []
            let grav = (try? await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: 200_000)) ?? []

            // Strictly-prior NOOP nights only; this day's own result joins the history after it is scored.
            let baselines = Self.baselines(for: day, noopHistory: history.values.filter { $0.day < day })
            // Pure CPU work on value arrays: run it off the main thread so the UI stays responsive while scoring.
            let res = await Task.detached(priority: .utility) {
                AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav,
                                           profile: up, baselines: baselines, maxHROverride: maxHR,
                                           dayRange: range)
            }.value
            out.append(Computed(day: day, recovery: res.recovery, strain: res.strain,
                                sleepMin: res.daily.totalSleepMin, hrv: res.daily.avgHrv,
                                rhr: res.daily.restingHr))
            dailies.append(res.daily)
            history[day] = res.daily
            components.append(contentsOf: Self.componentPoints(day: day, res: res))
            // Each detected workout becomes a stored row with its zone breakdown and strain.
            for w in res.workouts {
                let seg = HRQuality.clean(hr.filter { $0.ts >= w.start && $0.ts <= w.end })
                let zones = Dictionary(uniqueKeysWithValues: (1...5).map { ("z\($0)", w.zoneTimePct[$0] ?? 0) })
                let zjson = (try? JSONSerialization.data(withJSONObject: zones)).flatMap { String(data: $0, encoding: .utf8) }
                let maxF = w.hrmax ?? maxHR ?? 190
                detected.append(WorkoutRow(
                    startTs: w.start, endTs: w.end, sport: "Activity", source: "noop",
                    durationS: w.durationS, energyKcal: w.caloriesKcal,
                    avgHr: Int(w.avgHR.rounded()), maxHr: w.peakHR,
                    strain: StrainScorer.activityStrain(seg, maxHR: maxF),
                    distanceM: nil, zonesJSON: zjson, notes: "Auto-detected"))
            }
            cachedSleep.append(contentsOf: res.cachedSleep)
        }

        // Persist the computed scores under a dedicated "-noop" source so the WHOLE dashboard
        // (Today / Recovery / Strain / Sleep / Trends), not just this screen, reads them. The
        // Repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP import
        // always wins; this only fills the days the strap collected but no import covered.
        // Computed data is kept under a separate id so it never overwrites real WHOOP-imported rows.
        if !dailies.isEmpty { _ = try? await store.upsertDailyMetrics(dailies, deviceId: computedId) }
        if !components.isEmpty { _ = try? await store.upsertMetricSeries(components, deviceId: computedId) }
        // Overlapping day windows re-detect the same workout with slightly different edges; keep one
        // (the longest) per overlapping group so the Workouts page doesn't list it twice.
        // Overlapping day windows re-detect the same workout with slightly different edges; keep the longest of each overlap.
        var uniq: [WorkoutRow] = []
        for w in detected.sorted(by: { $0.startTs < $1.startTs }) {
            if let l = uniq.last, w.startTs <= l.endTs {
                if (w.durationS ?? 0) > (l.durationS ?? 0) { uniq[uniq.count - 1] = w }
            } else { uniq.append(w) }
        }
        if !uniq.isEmpty { _ = try? await store.upsertWorkouts(uniq, deviceId: computedId) }
        // Replace, don't accumulate: drop the computed sessions in the re-scored span first, so a session found by
        // an earlier version of the detector (e.g. an evening couch block) cannot linger beside the new result.
        for r in analyzedRanges { try? await store.deleteSleepSessions(deviceId: computedId, from: r.from, to: r.to) }
        if !cachedSleep.isEmpty { _ = try? await store.upsertSleepSessions(cachedSleep, deviceId: computedId) }

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your recovery, strain and sleep itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately.
        if !dailies.isEmpty { await repo.refresh() }
    }

    /// The separate recovery dimensions as long-format points under the "-noop" id (keys prefixed "noop."), so they
    /// persist with the day and can be compared with outcomes later. Not in MetricCatalog, so not yet shown in the UI.
    static func componentPoints(day: String, res: AnalyticsEngine.DayResult) -> [MetricPoint] {
        guard let a = res.assessment else { return [] }
        var p: [MetricPoint] = [MetricPoint(day: day, key: "noop.scoring_version", value: Double(scoringVersion))]
        func add(_ k: String, _ v: Double?) { if let v, v.isFinite { p.append(MetricPoint(day: day, key: k, value: v)) } }
        add("noop.sleep_24h_min", a.sleep.shortfall.sleepMin)
        add("noop.sleep_target_min", a.sleep.shortfall.targetMin)
        add("noop.sleep_shortfall_min", a.sleep.shortfall.shortfallMin)
        add("noop.ln_rmssd", a.autonomic.lnRMSSD)
        add("noop.ln_rmssd_z", a.autonomic.lnRMSSDz)
        add("noop.resting_hr_z", a.autonomic.restingHRz)
        add("noop.hrv_valid_windows", a.autonomic.quality.map { Double($0.hrvWindows) })
        add("noop.hrv_temporal_coverage", a.autonomic.quality?.hrvTemporalCoverage)
        add("noop.legacy_recovery_withheld", a.legacy.withheldReason == nil ? 0 : 1)
        add("noop.inferred_resp_bpm_experimental", res.daily.respRateBpm)
        return p
    }
}
