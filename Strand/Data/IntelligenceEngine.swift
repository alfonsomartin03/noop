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
    static let scoringVersion = 2
    private static let scoringVersionKey = "scoringVersionApplied"

    /// Re-score everything from the raw strap data. Only NOOP's own derived rows (the "-noop" id) are wiped;
    /// WHOOP imports and raw samples are never touched.
    func recomputeAll(maxDays: Int = 730) async {
        guard !computing, let store = await repo.storeHandle() else { return }
        try? await store.deleteDerived(deviceId: deviceId + "-noop")
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
    // Per day: read a window of raw streams -> AnalyticsEngine.analyzeDay -> collect daily rows, sleep sessions and workouts -> save once at the end.
    /// Personal HRV / resting-HR baselines folded from the nightly history (ascending). Shared with the diagnostics
    /// panel so both show the same numbers. NOTE: the history mixes imported WHOOP nights and NOOP's own, which are
    /// measured by different methods; the panel reports how many of each so the offset is visible.
    static func baselines(from hist: [DailyMetric]) -> AnalyticsEngine.ProfileBaselines? {
        guard let hrvCfg = Baselines.metricCfg["hrv"], let rhrCfg = Baselines.metricCfg["resting_hr"] else { return nil }
        return AnalyticsEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(hist.map { $0.avgHrv }, cfg: hrvCfg),
            restingHR: Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg))
    }

    func analyzeRecent(maxDays: Int = 21) async {
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return }
        guard let baselines = Self.baselines(from: repo.days) else { return }

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

        // Walk back one calendar day at a time from today, on the wearer's own clock: the day keys and the
        // day boundaries come from the zone in force on each date (so DST days and trips are handled), not from
        // "now minus k×24 h", which drifts across a clock change and mislabels days.
        ZoneTimeline.shared.refreshFromSystem()
        var cursor = now
        var analyzedRanges: [(from: Int, to: Int)] = []
        for _ in 0..<maxDays {
            let day = AnalyticsEngine.dayString(cursor)
            guard let range = ZoneTimeline.shared.dayRange(day) else { break }
            cursor = range.from - 1          // previous calendar day for the next pass
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
        let computedId = deviceId + "-noop"
        if !dailies.isEmpty { _ = try? await store.upsertDailyMetrics(dailies, deviceId: computedId) }
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
}
