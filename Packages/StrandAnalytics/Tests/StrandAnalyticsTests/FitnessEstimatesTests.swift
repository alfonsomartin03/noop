import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Issue #16: VO₂max estimate inputs/unavailable states, NOOP sleep performance, latest activation.
final class FitnessEstimatesTests: XCTestCase {
    private func nights(_ values: [Double], endingOn last: String) -> [HealthPoint] {
        values.enumerated().map { HealthPoint(day: HighlightCalendar.addDays(last, $0.offset - values.count + 1)!, value: $0.element) }
    }

    func testVO2UsesMedianRestingAndEnteredMax() throws {
        let r = VO2MaxEstimate.estimate(restingHR: nights([50, 52, 51, 49, 50, 80, 50], endingOn: "2026-11-10"),
                                        age: 35, enteredMaxHR: 190, today: "2026-11-10")
        guard case .estimate(let e) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.restingHR, 50)
        XCTAssertEqual(e.maxHRSource, .entered)
        XCTAssertEqual(e.vo2, 15.3 * 190 / 50, accuracy: 1e-9)
        XCTAssertEqual(e.version, VO2MaxEstimate.version)
    }

    func testVO2FallsBackToAgePredictedMax() throws {
        let r = VO2MaxEstimate.estimate(restingHR: nights(Array(repeating: 60, count: 6), endingOn: "2026-11-10"),
                                        age: 40, enteredMaxHR: nil, today: "2026-11-11")
        guard case .estimate(let e) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(e.maxHR, 180)
        XCTAssertEqual(e.maxHRSource, .agePredicted)
    }

    func testVO2UnavailableWithoutInputs() {
        if case .estimate = VO2MaxEstimate.estimate(restingHR: [], age: nil, enteredMaxHR: nil, today: "2026-11-10") { XCTFail() }
        guard case .unavailable(_, let missing) = VO2MaxEstimate.estimate(
            restingHR: nights([55, 55, 55], endingOn: "2026-11-10"), age: nil, enteredMaxHR: nil, today: "2026-11-10") else { return XCTFail() }
        XCTAssertEqual(missing.count, 2)
        // Enough nights but stale (newest is 5 days old).
        guard case .unavailable = VO2MaxEstimate.estimate(restingHR: nights(Array(repeating: 55, count: 7), endingOn: "2026-11-02"),
                                                           age: 30, enteredMaxHR: nil, today: "2026-11-07") else { return XCTFail() }
    }

    private func day(_ d: String, sleep: Double?) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testSleepPerformanceIsCausalCappedAndSkipsMissing() {
        let rows = [day("2026-11-01", sleep: 360), day("2026-11-02", sleep: 540), day("2026-11-03", sleep: nil), day("2026-11-04", sleep: 450)]
        let n = SleepPerformance.nights(rows)
        XCTAssertEqual(n.map(\.day), ["2026-11-01", "2026-11-02", "2026-11-04"], "missing sleep is no value, not 0 %")
        XCTAssertEqual(n[0].needMin, 450)                   // no history: 7.5 h floor
        XCTAssertEqual(n[0].performance, 80, accuracy: 1e-9)
        XCTAssertEqual(n[1].performance, 100)               // capped
        XCTAssertEqual(n[2].needMin, 450)                   // max(450, mean(360, 540) = 450)
        XCTAssertEqual(n[2].performance, 100)
        // A later night never changes an earlier one.
        XCTAssertEqual(SleepPerformance.nights(Array(rows.prefix(2))).map(\.performance), n.prefix(2).map(\.performance))
    }

    func testLatestActivationSkipsNoData() {
        let bins = [HRActivation.Bin(start: 0, end: 900, level: .low, meanHR: 60),
                    HRActivation.Bin(start: 900, end: 1800, level: .moderate, meanHR: 80),
                    HRActivation.Bin(start: 1800, end: 2700, level: .noData, meanHR: nil)]
        XCTAssertEqual(HRActivation.latest(bins)?.level, .moderate)
        XCTAssertEqual(HRActivation.coverage(bins), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertNil(HRActivation.latest([]))
    }

    // MARK: issue #16 pairing (interval, not date string)

    private func night(_ day: String, perf: Double, asleep: Double = 420, need: Double = 450) -> SleepPerformance.Night {
        SleepPerformance.Night(day: day, performance: perf, asleepMin: asleep, needMin: need)
    }

    func testPairingMatchesByIntervalNotByDateKey() {
        let h = 3600
        // NOOP night keyed by its WAKE day (Jan 2); WHOOP's cycle starts the evening before (Jan 1 23:00).
        let wake = 1_767_330_000           // some Jan-2 morning
        let noop = SleepPairing.Interval(start: wake - 8 * h, end: wake)
        let whoop = SleepPairing.Interval(start: wake - 8 * h + 600, end: wake - 300)
        // Cycle starts at WAKE, 7 h+ after onset (like the bundled export fixture); the link is its declared sleep.
        let cycles = [SleepPairing.Cycle(start: whoop.end, declaredSleep: whoop,
                                         values: ["sleep_performance": 90, "sleep_total_min": 400, "sleep_need_min": 380,
                                                  "hours_vs_needed_pct": 105.3]),
                      SleepPairing.Cycle(start: whoop.end + 86_400, declaredSleep: .init(start: whoop.start + 86_400, end: whoop.end + 86_400),
                                         values: ["sleep_performance": 10])]
        let r = SleepPairing.pair(nights: [night("2026-01-02", perf: 93.3)], noopSleep: ["2026-01-02": noop],
                                  whoopSleeps: [whoop], cycles: cycles)
        XCTAssertEqual(r.pairs.count, 1)
        XCTAssertEqual(r.pairs[0].whoop["sleep_performance"], 90)     // the cycle that starts at that sleep, not the next
        XCTAssertTrue(r.pairs[0].warmUp)                               // first night: no earlier NOOP nights

        let rep = SleepPairing.report(r.pairs).rows
        XCTAssertEqual(rep[0].all?.bias ?? .nan, 3.3, accuracy: 0.001)
        XCTAssertEqual(rep[1].all?.bias ?? .nan, 93.3 - 100, accuracy: 0.001)   // capped at 100
        XCTAssertEqual(rep[2].all?.bias ?? .nan, 93.3 - 105.3, accuracy: 0.001) // importer's uncapped value
        XCTAssertNil(rep[0].stable)                                              // warm-up night only
    }

    func testPairingExcludesMissingAmbiguousAndDoubleClaims() {
        let h = 3600, t = 1_767_330_000
        let a = SleepPairing.Interval(start: t, end: t + 8 * h)
        let whoop = [SleepPairing.Interval(start: t + 300, end: t + 8 * h)]
        let cycles = [SleepPairing.Cycle(start: t + 8 * h, declaredSleep: whoop[0], values: ["sleep_performance": 80])]
        // Two NOOP nights over the same WHOOP sleep; one with no main sleep; one far away.
        let r = SleepPairing.pair(nights: [night("d1", perf: 1), night("d2", perf: 2), night("d3", perf: 3), night("d4", perf: 4)],
                                  noopSleep: ["d1": a, "d2": a, "d4": .init(start: t + 40 * h, end: t + 48 * h)],
                                  whoopSleeps: whoop, cycles: cycles)
        XCTAssertTrue(r.pairs.isEmpty)
        XCTAssertEqual(r.excluded["WHOOP sleep matched by two NOOP nights"], 2)
        XCTAssertEqual(r.excluded["no NOOP main sleep"], 1)
        XCTAssertEqual(r.excluded["no overlapping WHOOP sleep"], 1)
        // Two overlapping WHOOP sleeps → ambiguous.
        let amb = SleepPairing.pair(nights: [night("d1", perf: 1)], noopSleep: ["d1": a],
                                    whoopSleeps: [a, .init(start: t + 60, end: t + 8 * h - 60)], cycles: cycles)
        XCTAssertEqual(amb.excluded["ambiguous (several WHOOP sleeps)"], 1)
    }

    /// Review 2026-11-13 (P2): the cycle↔sleep link is the export's declared sleep, never timing between cycle start and onset.
    func testCycleLinkUsesTheDeclaredSleepOnly() {
        let t = 1_767_330_000, sleep = SleepPairing.Interval(start: t, end: t + 26_100)   // 23:15 → 06:30 (fixture)
        let n = [night("d1", perf: 85)]
        func run(_ cycles: [SleepPairing.Cycle]) -> SleepPairing.Result {
            SleepPairing.pair(nights: n, noopSleep: ["d1": sleep], whoopSleeps: [sleep], cycles: cycles)
        }
        // Declared: cycle starts at wake (26 100 s after onset) → paired.
        XCTAssertEqual(run([.init(start: t + 26_100, declaredSleep: sleep, values: ["sleep_performance": 85])]).pairs.count, 1)
        // A neighbouring cycle starting right at onset but declaring ANOTHER sleep is never used.
        let other = SleepPairing.Interval(start: t - 86_400, end: t - 60_000)
        let r = run([.init(start: t, declaredSleep: other, values: ["sleep_performance": 10])])
        XCTAssertEqual(r.excluded["no WHOOP cycle declares that sleep"], 1)
        // No declared sleep at all → no link (no timing fallback).
        XCTAssertEqual(run([.init(start: t, declaredSleep: nil, values: [:])]).excluded["no WHOOP cycle declares that sleep"], 1)
        // Two cycles declaring the same sleep → ambiguous, excluded.
        let two = run([.init(start: t + 26_100, declaredSleep: sleep, values: [:]), .init(start: t + 26_160, declaredSleep: sleep, values: [:])])
        XCTAssertEqual(two.excluded["several WHOOP cycles declare that sleep"], 1)
    }

    func testStableHistorySeparatesWarmUpNights() {
        let rows = (1...20).map { day(String(format: "2026-01-%02d", $0), sleep: 420) }
        let nights = SleepPerformance.nights(rows)
        let t = 1_767_330_000
        var noopSleep: [String: SleepPairing.Interval] = [:], whoop: [SleepPairing.Interval] = [], cycles: [SleepPairing.Cycle] = []
        for (i, n) in nights.enumerated() {
            let s = t + i * 86_400
            noopSleep[n.day] = .init(start: s, end: s + 25_200)
            whoop.append(.init(start: s + 60, end: s + 25_200))
            cycles.append(.init(start: s + 60, declaredSleep: .init(start: s + 60, end: s + 25_200), values: ["sleep_performance": 90]))
        }
        let rep = SleepPairing.report(SleepPairing.pair(nights: nights, noopSleep: noopSleep, whoopSleeps: whoop, cycles: cycles).pairs)
        XCTAssertEqual(rep.rows[0].all?.n, 20)
        XCTAssertEqual(rep.rows[0].stable?.n, 6)   // nights 15…20 have ≥ 14 earlier nights
        XCTAssertEqual(rep.rows[1].missing, 20)    // no asleep/need exported → nothing compared, counted as missing
    }
}
