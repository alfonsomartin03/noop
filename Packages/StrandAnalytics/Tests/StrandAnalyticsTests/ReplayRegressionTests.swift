import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Regression tests for the reviewed issues: partial replay, persisted provenance, true 24-h clipping and implicit
/// gaps in sleep segments. Bookkeeping invariants only — no physiological accuracy is implied.
final class ReplayRegressionTests: XCTestCase {

    private func days(_ n: Int) -> [String] {
        let base = CalendarDay.index("2026-01-01")!
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return (0..<n).map { f.string(from: Date(timeIntervalSince1970: Double((base + $0) * 86_400))) }
    }

    private struct Res { let daily: DailyMetric; let usedBaseline: Double? }

    /// A day's "result" depends on its own data AND on the causal baseline, so any leakage or replay drift shows up.
    private func analyze(_ skip: Set<Int>, _ all: [String]) -> (String, AnalyticsEngine.ProfileBaselines) async -> Res? {
        { day, b in
            let i = all.firstIndex(of: day)!
            if skip.contains(i) { return nil }
            let base = b.hrv?.usable == true ? b.hrv!.baseline : nil
            return Res(daily: DailyMetric(day: day, totalSleepMin: 420, efficiency: 90, deepMin: nil, remMin: nil,
                                          lightMin: nil, disturbances: nil, restingHr: 50 + i % 3,
                                          avgHrv: 40 + Double((i * 7) % 13), recovery: base, strain: nil,
                                          exerciseCount: nil),
                       usedBaseline: base)
        }
    }

    private func replay(_ plan: [String], seed: [DailyMetric] = [], prov: [ProvenanceRecord] = [],
                        skip: Set<Int> = [], all: [String]) async -> CausalReplay.Output<Res> {
        await CausalReplay.run(days: plan, seed: seed, seedProvenance: prov, scoringVersion: 3,
                               analyze: analyze(skip, all), daily: { $0.daily }, assessment: { _ in nil })
    }

    // MARK: Partial replay

    func testPartialReplayEqualsFullReplay() async {
        let all = days(40), skip: Set<Int> = [5, 6, 22]
        let full = await replay(all, skip: skip, all: all)
        // Earlier run over the first 30 days, persisted (rows + provenance); then a 10-day incremental replay.
        let first = await replay(Array(all.prefix(30)), skip: skip, all: all)
        let tail = await replay(Array(all.suffix(10)), seed: first.results.map(\.result.daily),
                                prov: first.provenance, skip: skip, all: all)
        let fullTail = full.results.filter { $0.day >= all[30] }
        XCTAssertEqual(tail.results.map(\.result.daily), fullTail.map(\.result.daily))
        XCTAssertEqual(tail.provenance, full.provenance.filter { $0.day >= all[30] })
        XCTAssertNotNil(fullTail.last?.result.usedBaseline, "fixture must exercise a real baseline")
    }

    func testReplayedDaysIgnoreTheirOwnStaleStoredRows() async {
        let all = days(20)
        let clean = await replay(all, all: all)
        // A stale stored row for a plan day (an earlier run; plausible, so no outlier gate hides it) must not leak into
        // its successors —
        // including when that day now yields no result.
        var seed = clean.results.map(\.result.daily).filter { $0.day < all[10] }
        seed.append(DailyMetric(day: all[12], totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                                disturbances: nil, restingHr: 54, avgHrv: 58, recovery: nil, strain: nil, exerciseCount: nil))
        let prov = clean.provenance.filter { $0.day < all[10] }
            + ProvenanceKey.records(for: seed.last!, assessment: nil, scoringVersion: 3)
        let tail = await replay(Array(all.suffix(10)), seed: seed, prov: prov, all: all)
        XCTAssertEqual(tail.results.map(\.result.daily), clean.results.filter { $0.day >= all[10] }.map(\.result.daily))

        let skipped = await replay(Array(all.suffix(10)), seed: seed, prov: prov, skip: [12], all: all)
        let reference = await replay(all, skip: [12], all: all)
        XCTAssertEqual(skipped.results.map(\.result.daily),
                       reference.results.filter { $0.day >= all[10] }.map(\.result.daily))
    }

    // MARK: Persisted provenance

    func testProvenanceRoundTripsThroughStoredRecord() {
        let id = MetricIdentity.noopNightlyRMSSD(hardware: "whoop-4.0")
        let rec = id.record(day: "2026-01-02", key: ProvenanceKey.avgHrv, coverage: 0.6, exclusionReasons: [], scoringVersion: 3)
        XCTAssertEqual(MetricIdentity(record: rec), id)
        let unknownFuture = ProvenanceRecord(day: "2026-01-02", key: "avgHrv", definition: "rmssd-v9", unit: "ms",
                                             source: "noop", hardware: "unknown", algorithmVersion: "x",
                                             context: "sleep", aggregation: "medianOf5MinWindows", scoringVersion: 9)
        XCTAssertNil(MetricIdentity(record: unknownFuture), "unreadable provenance is never assumed compatible")
    }

    func testRowsWithoutOrWithOldProvenanceNeverSeedTheBaseline() {
        let d = days(12)
        let rows = (0..<10).map { i in DailyMetric(day: d[i], totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                                                   lightMin: nil, disturbances: nil, restingHr: 50, avgHrv: 50, recovery: nil,
                                                   strain: nil, exerciseCount: nil) }
        let current = rows.flatMap { ProvenanceKey.records(for: $0, assessment: nil, scoringVersion: 3) }
        let old = current.map { r in ProvenanceRecord(day: r.day, key: r.key, definition: r.definition, unit: r.unit,
                                                      source: r.source, hardware: r.hardware, algorithmVersion: "vitals-2025",
                                                      context: r.context, aggregation: r.aggregation, scoringVersion: 2) }
        func profile(_ p: [ProvenanceRecord]) -> AnalyticsEngine.ProfileBaselines {
            let o = MetricObservation.noopNightly(rows, provenance: p)
            return CausalBaselines.legacyProfile(rmssd: o.rmssd, restingHR: o.restingHR, before: d[11])
        }
        XCTAssertEqual(profile(current).hrv?.nValid, 10)
        XCTAssertNil(profile([]).hrv, "no persisted provenance → not trusted as current-version history")
        XCTAssertNil(profile(old).hrv, "older algorithm version → separate partition")
        XCTAssertNil(profile(old).lnRMSSDReference)
    }

    func testUnavailableValuesStillGetProvenanceWithReason() {
        let r = ProvenanceKey.records(for: DailyMetric(day: "2026-01-01", totalSleepMin: 400, efficiency: nil, deepMin: nil,
                                                       remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                                                       avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil),
                                      assessment: nil, scoringVersion: 3)
        XCTAssertEqual(r.first { $0.key == ProvenanceKey.avgHrv }?.exclusionReasons, ["unavailable"])
        XCTAssertEqual(r.first { $0.key == ProvenanceKey.respRateBpm }?.exclusionReasons, ["unavailable", "experimental"])
        XCTAssertEqual(r.first { $0.key == ProvenanceKey.totalSleepMin }?.exclusionReasons, [])
    }

    // MARK: Actual 24-hour clipping

    func testSleep24hIsExactlyTheTwentyFourHoursEndingAtFinalAwakening() {
        let wake = 1_000_000                                       // final awakening of the day
        let h = 3600
        let night = [StageSegment(start: wake - 9 * h, end: wake, stage: "light")]           // 9 h, inside
        let napYesterday = [StageSegment(start: wake - 17 * h, end: wake - 16 * h, stage: "asleep")]  // 1 h, inside
        let straddling = [StageSegment(start: wake - 25 * h, end: wake - 23 * h, stage: "deep")]      // 1 h of 2 inside
        let older = [StageSegment(start: wake - 40 * h, end: wake - 32 * h, stage: "light")]          // outside
        let afterWake = [StageSegment(start: wake + h, end: wake + 2 * h, stage: "light")]            // next window
        let total = SleepAccounting.sleep24h([night, napYesterday, straddling, older, afterWake], endingAt: wake)
        XCTAssertEqual(total, 11 * h)
        XCTAssertEqual(SleepAccounting.window24h(endingAt: wake).duration, 86_400)
        // A single record longer than 24 h can never contribute more than 24 h.
        let marathon = [StageSegment(start: wake - 30 * h, end: wake, stage: "light")]
        XCTAssertEqual(SleepAccounting.sleep24h([marathon], endingAt: wake), 86_400)
    }

    func testAnalyzeDayNo24hSleepWithoutAnySession() {
        let r = AnalyticsEngine.analyzeDay(day: "2026-01-01", profile: UserProfile())
        XCTAssertNil(r.assessment?.sleep.shortfall.sleepMin, "no detected sleep is unknown, not 0 h")
    }

    // MARK: Implicit gaps in sleep segments

    private let gappy = [StageSegment(start: 0, end: 3600, stage: "light"),
                         // 3600–5400 covered by nothing
                         StageSegment(start: 5400, end: 9000, stage: "deep"),
                         StageSegment(start: 8000, end: 10_800, stage: "wake")]   // overlaps the previous one

    func testNormalizedTilesThePeriodWithExplicitUnknown() {
        let n = SleepAccounting.normalized(gappy, period: TimeSpan(0, 12_000))
        XCTAssertEqual(n.map(\.stage), ["light", "unknown", "deep", "wake", "unknown"])
        XCTAssertEqual(n.map(\.start), [0, 3600, 5400, 9000, 10_800])
        XCTAssertEqual(n.last?.end, 12_000)
        XCTAssertEqual(n[1].reason, SleepStateReason.noSegment)
        XCTAssertEqual(n.reduce(0) { $0 + $1.end - $1.start }, 12_000, "every second exactly once")
    }

    func testGapsCountAsUnknownInEveryAccountingPath() {
        let s = SleepAccounting.summarize(gappy, period: TimeSpan(0, 12_000))
        XCTAssertEqual(s.tstS, 7200)
        XCTAssertEqual(s.unknownS, 1800 + 1200)
        XCTAssertEqual(s.tstBoundsS, 7200...10_200)
        XCTAssertEqual(s.wasoS, 0, "the gap inside the sleep period is not wake")
        XCTAssertEqual(s.unknownInSleepPeriodS, 1800)

        let session = SleepSession(start: 0, end: 12_000, efficiency: 0, stages: gappy, restingHR: nil, avgHRV: nil)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.unknownS, 3000)
        XCTAssertEqual(m.tstS, 7200)
        XCTAssertEqual(m.efficiency, 7200.0 / 9000.0, accuracy: 1e-12, "observed = period − unknown")
        XCTAssertEqual(SleepStager.efficiency(start: 0, end: 12_000, stages: gappy), 7200.0 / 9000.0, accuracy: 1e-12)
    }

    func testGapInsideEpisodeIsNotWornWakeForSRI() {
        let ep = [StageSegment(start: 0, end: 3600, stage: "light"), StageSegment(start: 7200, end: 10_800, stage: "light")]
        let grid = SleepAccounting.stateGrid(episodes: [ep], covered: [TimeSpan(0, 14_400)], from: 0, to: 14_400, epochS: 3600)
        XCTAssertEqual(grid, [.asleep, .unknown, .asleep, .wake])
    }

    func testVitalsWindowsInsideAGapAreNotUsed() {
        let start = 2_000_000, end = start + 7200
        var hr: [HRSample] = [], rr: [RRInterval] = []
        for t in start..<end {
            hr.append(HRSample(ts: t, bpm: 60)); rr.append(RRInterval(ts: t, rrMs: (t - start) % 2 == 0 ? 990 : 1010))
        }
        // Hypnogram covers the first hour only; the second hour has no segment.
        let stages = [StageSegment(start: start, end: start + 3600, stage: "light")]
        let v = SleepVitalsCalculator.compute(start: start, end: end, stages: stages, hr: hr, rr: rr)
        XCTAssertTrue(v.windows.filter { $0.start >= start + 3600 }.allSatisfy { !$0.usedForHRV && !$0.usedForHR })
        XCTAssertGreaterThan(v.rejectionCounts["HRV: sleep state unknown"] ?? 0, 0)
    }
}
