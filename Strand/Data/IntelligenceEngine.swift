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
    /// v4: load over supported intervals (no rest-day floor), one calibration snapshot, gap-aware episode detection.
    /// v5: strain and its zones cover awake time only (confident sleep and naps excluded); energy on supported seconds.
    static let scoringVersion = 5
    private static let scoringVersionKey = "scoringVersionApplied"

    /// Days recomputed in one transaction of a re-score. Each batch commits on its own, so an interruption keeps them
    /// and the next launch continues with what's left.
    private static let rescoreBatchDays = 30

    /// Explicit retrospective re-score of everything under the current rules, including calibration. The user's own
    /// action: past days otherwise keep the calibration they were scored with.
    func recomputeAll(maxDays: Int = 730) async {
        guard let store = await repo.storeHandle() else { return }
        try? await IncrementalScorer.requestFullRescore(store: store, computedId: deviceId + "-noop")
        await rescoreStaleDays(maxDays: maxDays)
    }

    /// Runs the re-score once per scoring version (first launch after an update to the rules). If it was interrupted, this
    /// picks it up again: finished days carry the current version and are reused.
    func recomputeIfRulesChanged() async {
        if UserDefaults.standard.integer(forKey: Self.scoringVersionKey) < Self.scoringVersion { await rescoreStaleDays(maxDays: 730) }
    }

    /// Archive the current rows once to "-noop-v<old>", then recompute stale days oldest first in atomic batches. WHOOP
    /// imports and raw samples are never touched. The version is marked applied only when no stale day remains.
    private func rescoreStaleDays(maxDays: Int) async {
        guard let store = await repo.storeHandle(), !computing else { return }
        computing = true
        defer { computing = false }
        let old = UserDefaults.standard.integer(forKey: Self.scoringVersionKey)
        let computedId = deviceId + "-noop"
        do {
            try await IncrementalScorer.archiveOnce(store: store, computedId: computedId,
                                                    archiveId: deviceId + "-noop-v" + (old > 0 ? String(old) : "pre"),
                                                    scoringVersion: Self.scoringVersion)
            while true {
                let outcome = try await score(store: store, maxDays: maxDays, batch: Self.rescoreBatchDays)
                note = outcome.remaining > 0 ? "Updating scores: \(outcome.remaining) days to go. Older and newer days use different rules until this finishes." : nil
                if outcome.remaining == 0 { break }
            }
            UserDefaults.standard.set(Self.scoringVersion, forKey: Self.scoringVersionKey)
            await repo.refresh()
        } catch {
            note = "Scoring stopped; finished days are kept and the rest continue next launch: \(error.localizedDescription)"
        }
    }

    /// One scoring pass off the main actor. Bumps nothing and touches no screen when no day needed work.
    private func score(store: WhoopStore, maxDays: Int, batch: Int? = nil) async throws -> ScoringOutcome {
        let request = ScoringRequest(rawId: deviceId,
                                     profile: UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                                                          age: Double(profile.age), sex: profile.sex),
                                     maxHROverride: profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil,
                                     scoringVersion: Self.scoringVersion, now: Int(Date().timeIntervalSince1970),
                                     maxDays: maxDays, maxRecomputedDays: batch)
        return try await Task.detached(priority: .utility) {
            try await IncrementalScorer.run(store: store, request: request)
        }.value
    }

    /// Personal baselines for scoring `day`: built ONLY from NOOP's own computed nights (`noopHistory`, the "-noop"
    /// rows) dated strictly BEFORE `day` whose PERSISTED provenance matches the current metric identity (rows from an
    /// older algorithm version, or with no provenance, are excluded). Imported WHOOP values never enter. Shared with
    /// the diagnostics panel so both show the same numbers.
    static func baselines(for day: String, noopHistory: [DailyMetric],
                          provenance: [ProvenanceRecord]) -> AnalyticsEngine.ProfileBaselines {
        let obs = MetricObservation.noopNightly(noopHistory, provenance: provenance)
        return CausalBaselines.legacyProfile(rmssd: obs.rmssd, restingHR: obs.restingHR, before: day)
    }

    /// Bring scores up to date: reuses every stored day whose inputs are unchanged and recomputes the rest, oldest first
    /// (see IncrementalScorer). A day is written atomically with its state, or not at all.
    /// Returns true when the store is current.
    @discardableResult
    func analyzeRecent(maxDays: Int = 21) async -> Bool {
        guard let store = await repo.storeHandle() else { note = "No on-device store yet."; return false }
        guard !computing else { return false }   // never overlap two runs
        computing = true
        defer { computing = false }
        do {
            let outcome = try await score(store: store, maxDays: maxDays)
            let rows = try await store.dailyMetrics(deviceId: deviceId + "-noop", from: "0000-00-00", to: "9999-99-99")
            results = rows.reversed().map { d in
                Computed(day: d.day, recovery: d.recovery, strain: d.strain, sleepMin: d.totalSleepMin, hrv: d.avgHrv, rhr: d.restingHr)
            }
            note = results.isEmpty
                ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your recovery, strain and sleep itself, no WHOOP cloud required."
                : nil
            // Reload the dashboard caches only when a score actually changed.
            if !outcome.recomputed.isEmpty { await repo.refresh() }
            return true
        } catch {
            note = "Scoring stopped (nothing saved): \(error.localizedDescription)"
            return false
        }
    }
}
