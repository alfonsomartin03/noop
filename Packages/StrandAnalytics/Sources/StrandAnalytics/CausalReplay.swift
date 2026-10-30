import Foundation
import WhoopStore

// CausalReplay.swift — the day-by-day scoring loop, separated from I/O so its replay properties are testable.
//
// Invariant: replaying any suffix of days, seeded with what an earlier run stored for the days before it, yields
// exactly what a full replay from scratch yields for that suffix. Every day in the plan is REPLACED — by its new
// result, or removed when it now yields none — and seeded rows count only when their persisted provenance matches the
// current identity.

public enum CausalReplay {
    public struct Output<R> {
        /// Results for the plan days that produced one, oldest first.
        public let results: [(day: String, result: R)]
        /// Provenance for every resulting day (to persist with the rows).
        public let provenance: [ProvenanceRecord]
        /// Days actually analyzed, oldest first, including those that yielded no result. Reused days are absent.
        public let processed: [String]
    }

    /// - Parameters:
    ///   - days: plan days, any order (processed oldest first).
    ///   - seed / seedProvenance: stored NOOP rows and their provenance (any days; a plan day's are used only if reused).
    ///   - reuse: true keeps a plan day's stored row instead of analyzing it, given the baselines it would see now.
    ///   - analyze: scores one day against baselines from strictly earlier days; nil = no data for that day.
    ///   - daily / assessment / load: extract the stored row, assessment and load record from a result.
    public static func run<R>(days: [String], seed: [DailyMetric], seedProvenance: [ProvenanceRecord],
                              scoringVersion: Int,
                              reuse: (String, AnalyticsEngine.ProfileBaselines) -> Bool = { _, _ in false },
                              analyze: (String, AnalyticsEngine.ProfileBaselines) async throws -> R?,
                              daily: (R) -> DailyMetric,
                              assessment: (R) -> RecoveryAssessment?,
                              load: (R) -> DayLoadRecord? = { _ in nil }) async rethrows -> Output<R> {
        var rows: [String: DailyMetric] = [:]
        for r in seed { rows[r.day] = r }
        var prov: [String: [ProvenanceRecord]] = Dictionary(grouping: seedProvenance, by: \.day)
        var processed: [String] = []
        var results: [(day: String, result: R)] = []
        var outProv: [ProvenanceRecord] = []
        for day in days.sorted() {
            let prior = rows.values.filter { $0.day < day }.sorted { $0.day < $1.day }
            let obs = MetricObservation.noopNightly(prior, provenance: prior.flatMap { prov[$0.day] ?? [] })
            let baselines = CausalBaselines.legacyProfile(rmssd: obs.rmssd, restingHR: obs.restingHR, before: day)
            if reuse(day, baselines) { continue }
            processed.append(day)
            // Replaced or removed either way: this day's stored row must not reach its successors.
            rows[day] = nil; prov[day] = nil
            guard let res = try await analyze(day, baselines) else { continue }
            let d = daily(res)
            let p = ProvenanceKey.records(for: d, assessment: assessment(res), scoringVersion: scoringVersion)
                + (load(res).map { ProvenanceKey.records(forLoad: $0, scoringVersion: scoringVersion) } ?? [])
            rows[day] = d; prov[day] = p
            results.append((day, res)); outProv.append(contentsOf: p)
        }
        return Output(results: results, provenance: outProv, processed: processed)
    }
}
