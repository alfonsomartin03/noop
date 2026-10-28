import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Acceptance tests for measurement validity: accounting invariants and real failure cases. Numbers are hand-checkable
/// fixtures, not re-derivations of the implementation. Passing them shows the arithmetic and bookkeeping are right;
/// it does NOT show any estimate is physiologically accurate.
final class MeasurementValidityTests: XCTestCase {

    // MARK: 1. Hand-checkable HRV; rejected beats and gaps create no artificial pairs

    /// 30 beats alternating 800/820 ms: every successive difference is ±20 ms.
    /// RMSSD = 20; pNN50 = 0; SDNN = sqrt(30·10² / 29) = 10.1710.
    func testHandCheckableRMSSDSDNNpNN50() {
        let nn = (0..<30).map { $0 % 2 == 0 ? 800.0 : 820.0 }
        let r = HRVAnalyzer.analyze(rawRR: nn)
        XCTAssertEqual(r.rmssd!, 20, accuracy: 1e-9)
        XCTAssertEqual(r.pnn50!, 0, accuracy: 1e-9)
        XCTAssertEqual(r.sdnn!, (3000.0 / 29.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(r.nPairs, 29)
        XCTAssertEqual(r.nClean, 30)

        // 800/860: |Δ| = 60 > 50 for every pair → pNN50 = 100 %.
        let wide = HRVAnalyzer.analyze(rawRR: (0..<30).map { $0 % 2 == 0 ? 800.0 : 860.0 })
        XCTAssertEqual(wide.rmssd!, 60, accuracy: 1e-9)
        XCTAssertEqual(wide.pnn50!, 100, accuracy: 1e-9)
    }

    func testRejectedBeatCreatesNoArtificialPair() {
        // Insert an ectopic 1600 ms beat at position 15. Differencing its two neighbours (both 800 or both 820)
        // would add a 0 ms pair and pull RMSSD below 20.
        var nn = (0..<31).map { $0 % 2 == 0 ? 800.0 : 820.0 }
        nn[15] = 1600
        let r = HRVAnalyzer.analyze(rawRR: nn)
        XCTAssertEqual(r.rmssd!, 20, accuracy: 1e-9)
        XCTAssertEqual(r.nClean, 30)
        XCTAssertEqual(r.nPairs, 28, "pairs (14,15) and (15,16) both lost; (14,16) is never formed")
    }

    func testPacketGapCreatesNoArtificialPair() {
        var t = 1000, beats: [RRInterval] = []
        for i in 0..<30 {
            if i == 15 { t += 20 }                              // 20 s of lost packets
            let v = i % 2 == 0 ? 800 : 820
            beats.append(RRInterval(ts: t, rrMs: v)); t += 1
        }
        let r = HRVAnalyzer.analyzeTimed(beats)
        XCTAssertEqual(r.nPairs, 28)
        XCTAssertEqual(r.rmssd!, 20, accuracy: 1e-9)
    }

    // MARK: 2. Duplicates add nothing; two genuine beats in one second stay distinct and in order

    func testTwoBeatsInOneSecondStayDistinctAndOrdered() {
        // ~125 bpm with alternating 470/490 ms: many seconds hold two beats sharing one stamp.
        var clock = 0.0, beats: [RRInterval] = [], values: [Double] = []
        for i in 0..<80 {
            let v = i % 2 == 0 ? 470 : 490
            clock += Double(v) / 1000
            beats.append(RRInterval(ts: 5000 + Int(clock), rrMs: v)); values.append(Double(v))
        }
        XCTAssertGreaterThan(Set(beats.map(\.ts)).count, 0)
        XCTAssertLessThan(Set(beats.map(\.ts)).count, beats.count, "fixture must contain shared seconds")
        let timed = HRVAnalyzer.analyzeTimed(beats)
        XCTAssertEqual(timed.nClean, 80)
        XCTAssertEqual(timed.rmssd!, 20, accuracy: 1e-9, "same-second beats must keep acquisition order")
        XCTAssertEqual(timed.rmssd!, HRVAnalyzer.analyze(rawRR: values).rmssd!, accuracy: 1e-9)
    }

    /// 2 h still night, 60 bpm, R-R alternating 990/1010 ms, one beat per second.
    private func vitalsNight(duplicateRR: Bool = false, hrEvery: Int = 1, duplicateHR: Bool = false)
        -> SleepVitals {
        let start = 2_000_000, end = start + 7200
        var hr: [HRSample] = [], rr: [RRInterval] = []
        for t in start..<end {
            if (t - start) % hrEvery == 0 {
                hr.append(HRSample(ts: t, bpm: 60))
                if duplicateHR { hr.append(HRSample(ts: t, bpm: 60)) }
            }
            let v = (t - start) % 2 == 0 ? 990 : 1010
            rr.append(RRInterval(ts: t, rrMs: v))
            if duplicateRR { rr.append(RRInterval(ts: t, rrMs: v)) }
        }
        return SleepVitalsCalculator.compute(start: start, end: end, stages: [], hr: hr, rr: rr)
    }

    func testDuplicatedBeatStreamIsRejectedNotScored() {
        let clean = vitalsNight()
        XCTAssertEqual(clean.hrv!, 20, accuracy: 1e-9)
        let dup = vitalsNight(duplicateRR: true)
        XCTAssertNil(dup.hrv, "a doubled beat stream would produce RMSSD from 0 ms 'pairs'")
        XCTAssertGreaterThan(dup.rejectionCounts["HRV: excess beats (duplicated stream)"] ?? 0, 0)
    }

    func testDuplicateHRRowsDoNotRaiseCoverage() {
        // HR in only half the seconds: below the 60 % gate whether or not every row is duplicated.
        let half = vitalsNight(hrEvery: 2)
        let halfDup = vitalsNight(hrEvery: 2, duplicateHR: true)
        XCTAssertNil(half.restingHR)
        XCTAssertNil(halfDup.restingHR, "duplicated rows must not count as extra seconds of coverage")
        XCTAssertEqual(half.hrWindowCount, halfDup.hrWindowCount)
    }

    func testValidWindowDistributionIsReported() {
        let v = vitalsNight()
        XCTAssertEqual(v.hrvWindowsByThird.count, 3)
        XCTAssertTrue(v.hrvSpansNight)
        XCTAssertEqual(v.hrvPairCount, v.windows.filter(\.usedForHRV).reduce(0) { $0 + $1.pairs })
        XCTAssertGreaterThan(v.hrvTemporalCoverage, 0.5)
    }

    // MARK: 3. Missing data is unknown — never wake, sleep or a stage

    func testMissingGravityEpochsBecomeUnknownNotWake() {
        let start = 3_000_000, end = start + 4 * 3600
        // Gravity only in the first 2 h (strap off afterwards); HR/RR throughout.
        let grav = (start..<(start + 7200)).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let hr = (start..<end).map { HRSample(ts: $0, bpm: 55) }
        let segs = SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: [], resp: [])
        let lateHalf = segs.filter { $0.end > start + 7260 }
        XCTAssertFalse(lateHalf.contains { $0.state == .wake }, "unscored time must not be wake")
        XCTAssertFalse(lateHalf.contains { $0.state.isSleep && $0.start >= start + 7230 }, "nor sleep")
        XCTAssertTrue(segs.contains { $0.state == .unknown && $0.reason == SleepStateReason.noMotionData })

        let session = SleepSession(start: start, end: end, efficiency: 0, stages: segs, restingHR: nil, avgHRV: nil)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertGreaterThan(m.unknownS, 7000)
        XCTAssertLessThanOrEqual(m.tstS + m.unknownS, m.tibS)
        XCTAssertEqual(m.wasoS, segs.filter { $0.state == .wake }.reduce(0.0) { $0 + Double($1.end - $1.start) },
                       accuracy: 61, "WASO counts observed wake only")
    }

    func testNoMotionDataAtAllIsUnknownNotLightSleep() {
        let segs = SleepStager.stageSession(start: 0, end: 3600, grav: [], hr: [], rr: [], resp: [])
        XCTAssertEqual(segs.map(\.state), [.unknown])
        let s = SleepAccounting.summarize(segs, period: TimeSpan(0, 3600))
        XCTAssertEqual(s.tstS, 0)
        XCTAssertEqual(s.tstBoundsS, 0...3600, "missingness bounds, not a confidence interval")
        XCTAssertNil(s.wasoS); XCTAssertNil(s.solS); XCTAssertNil(s.efficiencyTIB)
        XCTAssertNil(s.classifiedFractions); XCTAssertNil(s.stagedCoverage)
        XCTAssertEqual(SleepStager.efficiency(start: 0, end: 3600, stages: segs), 0)
    }

    func testUnstagedSleepIsSleepButNotAStage() {
        let segs = [StageSegment(start: 0, end: 3600, stage: "light"),
                    StageSegment(start: 3600, end: 7200, stage: "asleep", reason: SleepStateReason.noCardiacData),
                    StageSegment(start: 7200, end: 9000, stage: "deep")]
        let s = SleepAccounting.summarize(segs, period: TimeSpan(0, 9000))
        XCTAssertEqual(s.tstS, 9000)
        XCTAssertEqual(s.stagedS, 5400)
        XCTAssertEqual(s.stagedCoverage!, 0.6, accuracy: 1e-12)
        XCTAssertEqual(s.classifiedFractions!.light + s.classifiedFractions!.deep + s.classifiedFractions!.rem, 1, accuracy: 1e-12)
        let whole = s.wholeSleepFractions!
        XCTAssertEqual(whole.light + whole.deep + whole.rem, 0.6, accuracy: 1e-12, "whole-sleep fractions don't sum to 1")
    }

    func testSOLAndTIBEfficiencyNeedRealBoundaries() {
        let segs = [StageSegment(start: 600, end: 1200, stage: "wake"), StageSegment(start: 1200, end: 7200, stage: "light")]
        let inferred = SleepAccounting.summarize(segs, period: TimeSpan(600, 7200))
        XCTAssertNil(inferred.solS); XCTAssertNil(inferred.efficiencyTIB)
        let known = SleepAccounting.summarize(segs, period: TimeSpan(0, 7200), inBed: TimeSpan(0, 7200), attemptTs: 300)
        XCTAssertEqual(known.solS, 900)
        XCTAssertEqual(known.efficiencyTIB!, 100.0 * 6000 / 7200, accuracy: 1e-9)
    }

    func testWakeBoutsAreNotMergedAcrossUnknown() {
        let segs = [StageSegment(start: 0, end: 1000, stage: "light"),
                    StageSegment(start: 1000, end: 1100, stage: "wake"),
                    StageSegment(start: 1100, end: 1130, stage: "unknown"),
                    StageSegment(start: 1130, end: 1230, stage: "wake"),
                    StageSegment(start: 1230, end: 3000, stage: "light")]
        let bouts = SleepAccounting.wakeBouts(segs, within: TimeSpan(0, 3000), minBoutS: 60, mergeGapS: 120)
        XCTAssertEqual(bouts.count, 2)
    }

    // MARK: 4. Four efficient hours are four hours

    func testFourEfficientHoursAreNotAdequate() {
        let sf = SleepAccounting.shortfall(sleepMin: 240, targetMin: 480)
        XCTAssertEqual(sf.shortfallMin, 240)
        XCTAssertEqual(sf.meetsTarget, false)

        let a = RecoveryAssessor.assess(sleep24hMin: 240, mainSleepS: 240 * 60, efficiency: 0.99, hrv: nil, restingHR: nil,
                                        quality: nil, baselines: .init(sleepTargetMin: 480), minMainSleepS: 3 * 3600)
        XCTAssertEqual(a.sleep.shortfall.meetsTarget, false)
        XCTAssertEqual(a.sleep.shortfall.sleepMin, 240)
        XCTAssertEqual(SleepAccounting.shortfall(sleepMin: nil).meetsTarget, nil, "unknown is not adequate or short")
    }

    func testWindowShortfallTreatsMissingDaysAsUnknown() {
        let w = SleepAccounting.windowShortfall([420, nil, 300, nil, 480], targetMin: 420)
        XCTAssertEqual(w.observedShortfallMin, 120)
        XCTAssertEqual(w.observedDays, 3)
        XCTAssertEqual(w.completeness, 0.6, accuracy: 1e-12)
    }

    // MARK: 5. Overlaps, naps across midnight, DST: elapsed time without double counting

    func testOverlappingImportsAndNapsCountOnce() {
        let noop = [StageSegment(start: 0, end: 28_800, stage: "light")]
        let whoopImport = [StageSegment(start: 1800, end: 30_000, stage: "deep")]   // same night, other source
        let nap = [StageSegment(start: 50_000, end: 52_400, stage: "asleep")]
        let total = SleepAccounting.sleepSeconds([noop, whoopImport, nap], window: TimeSpan(0, 86_400))
        XCTAssertEqual(total, 30_000 + 2400)
    }

    func testNapAcrossMidnightSplitsByElapsedTime() {
        let midnight = 86_400
        let nap = [StageSegment(start: midnight - 1800, end: midnight + 2700, stage: "light")]
        let d1 = SleepAccounting.sleepSeconds([nap], window: TimeSpan(0, midnight))
        let d2 = SleepAccounting.sleepSeconds([nap], window: TimeSpan(midnight, 2 * midnight))
        XCTAssertEqual(d1, 1800); XCTAssertEqual(d2, 2700); XCTAssertEqual(d1 + d2, 4500)
    }

    func testDSTNightKeepsElapsedDuration() {
        // America/New_York springs forward 2026-03-08 02:00 → 03:00 (a 23-h day).
        let tz = TimeZone(identifier: "America/New_York")!
        let zt = ZoneTimeline(entries: [ZoneEntry(since: 0, id: tz.identifier)])
        let d7 = zt.dayRange("2026-03-07")!, d8 = zt.dayRange("2026-03-08")!
        XCTAssertEqual(d8.to - d8.from, 23 * 3600)
        let bed = d8.from - 3600                     // 23:00 EST on Mar 7
        let wake = d8.from + 6 * 3600                // 07:00 EDT on Mar 8 (only 6 elapsed hours after midnight)
        let night = [StageSegment(start: bed, end: wake, stage: "light")]
        XCTAssertEqual(SleepAccounting.sleepSeconds([night], window: TimeSpan(bed, wake)), 7 * 3600)
        let split = SleepAccounting.sleepSeconds([night], window: TimeSpan(d7.from, d7.to))
            + SleepAccounting.sleepSeconds([night], window: TimeSpan(d8.from, d8.to))
        XCTAssertEqual(split, 7 * 3600)
        XCTAssertEqual(zt.hourMinute(wake).hour, 7)
    }

    // MARK: 6. Circular clock times and SRI

    func testCircularMidpointAcrossMidnight() {
        let utc = TimeZone(identifier: "UTC")!
        let c = SleepAccounting.circularClock([23 * 3600 + 55 * 60, 86_400 + 5 * 60], zone: { _ in utc })!
        let distFromMidnight = min(c.meanMinute, 1440 - c.meanMinute)
        XCTAssertEqual(distFromMidnight, 0, accuracy: 1e-6)
        XCTAssertLessThan(c.circularSDMin, 6)
        XCTAssertGreaterThan(c.resultantLength, 0.999)
    }

    func testSRIConstantScheduleIs100AndInverseIsMinus100() {
        // 3 days of 1-h epochs: asleep 00–08, awake otherwise.
        let day: [SleepState] = (0..<24).map { $0 < 8 ? .asleep : .wake }
        let same = SleepAccounting.sleepRegularityIndex(states: day + day + day, epochS: 3600)
        XCTAssertEqual(same.sri, 100)
        let inverse = day.map { $0 == .wake ? SleepState.asleep : .wake }
        let flip = SleepAccounting.sleepRegularityIndex(states: day + inverse, epochS: 3600)
        XCTAssertEqual(flip.sri, -100, "SRI is not clipped to 0–100")
    }

    func testSRIUsesOnlyValidPairsAndDoesNotInventWake() {
        var day2: [SleepState] = (0..<24).map { $0 < 8 ? .asleep : .wake }
        for h in 12..<20 { day2[h] = .unknown }      // strap off in the afternoon
        let day1: [SleepState] = (0..<24).map { $0 < 8 ? .asleep : .wake }
        let r = SleepAccounting.sleepRegularityIndex(states: day1 + day2, epochS: 3600)
        XCTAssertEqual(r.validPairs, 16); XCTAssertEqual(r.possiblePairs, 24); XCTAssertEqual(r.sri, 100)
        // The grid builder leaves uncovered time unknown instead of filling it with wake.
        let grid = SleepAccounting.stateGrid(episodes: [[StageSegment(start: 0, end: 3600, stage: "light")]],
                                             covered: [TimeSpan(0, 7200)], from: 0, to: 4 * 3600, epochS: 3600)
        XCTAssertEqual(grid, [.asleep, .wake, .unknown, .unknown])
    }

    // MARK: 7. Identity partitions: SDNN never enters an RMSSD baseline

    private func obs(_ id: MetricIdentity, _ day: String, _ v: Double?) -> MetricObservation {
        MetricObservation(identity: id, day: day, value: v)
    }
    private func days(_ n: Int, from start: String = "2026-01-01") -> [String] {
        let base = CalendarDay.index(start)!
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return (0..<n).map { f.string(from: Date(timeIntervalSince1970: Double((base + $0) * 86_400))) }
    }

    func testSDNNNeverEntersRMSSDReference() {
        let rmssd = MetricIdentity.noopNightlyRMSSD()
        let d = days(10)
        var input = (0..<8).map { obs(rmssd, d[$0], 50 + Double($0 % 3)) }
        input.append(obs(.appleHealthSDNN, d[8], 140))
        input.append(obs(rmssd, d[9], 51))
        let scored = CausalReference.scoreSequence(input, identity: rmssd, cfg: .lnRMSSD)
        let sdnn = scored.first { $0.observation.identity == .appleHealthSDNN }!
        XCTAssertEqual(sdnn.outcome, .excluded)
        XCTAssertFalse(sdnn.updatesReference)
        XCTAssertTrue(sdnn.reasons.contains("incompatible identity"))
        let last = scored.last!
        XCTAssertEqual(last.reference?.count, 8, "only the 8 RMSSD nights")

        let legacyMixed = Baselines.causalState(input, identity: rmssd, before: "2026-02-01", cfg: Baselines.hrvCfg)
        let legacyClean = Baselines.causalState(input.filter { $0.identity == rmssd }, identity: rmssd,
                                                before: "2026-02-01", cfg: Baselines.hrvCfg)
        XCTAssertEqual(legacyMixed, legacyClean)
    }

    func testAlgorithmOrSourceChangeIsIncompatible() {
        let v1 = MetricIdentity.noopNightlyRMSSD()
        let v2 = MetricIdentity(definition: .rmssd, unit: "ms", source: .noopComputed, algorithmVersion: "vitals-next",
                                context: .sleep, aggregation: .medianOf5MinWindows)
        XCTAssertFalse(v1.isBaselineCompatible(with: v2))
        XCTAssertFalse(v1.isBaselineCompatible(with: .whoopExportRMSSD), "same statistic, different processing")
        XCTAssertFalse(MetricIdentity.noopNightlyRMSSD(hardware: "whoop-4").isBaselineCompatible(with: v1),
                       "unknown hardware is not a wildcard")
    }

    // MARK: 8. Causality, score-then-update, determinism

    func testFutureNightCannotChangeEarlierScores() {
        let id = MetricIdentity.noopNightlyRMSSD()
        let d = days(30)
        let base = (0..<20).map { obs(id, d[$0], 45 + Double(($0 * 7) % 11)) }
        let a = CausalReference.scoreSequence(base, identity: id, cfg: .lnRMSSD)
        let b = CausalReference.scoreSequence(base + [obs(id, d[25], 140), obs(id, d[29], 12)], identity: id, cfg: .lnRMSSD)
        XCTAssertEqual(Array(b.prefix(20)), a)

        let early = Baselines.causalState(base, identity: id, before: d[15], cfg: Baselines.hrvCfg)
        let earlyWithFuture = Baselines.causalState(base + [obs(id, d[16], 200)], identity: id, before: d[15], cfg: Baselines.hrvCfg)
        XCTAssertEqual(early, earlyWithFuture)
    }

    func testScoreThenUpdateDiffersFromSelfInclusion() {
        let id = MetricIdentity.noopNightlyRMSSD()
        let d = days(9)
        let input = (0..<8).map { obs(id, d[$0], 50) } + [obs(id, d[8], 25)]   // a sharp drop on the last night
        let last = CausalReference.scoreSequence(input, identity: id, cfg: .lnRMSSD).last!
        XCTAssertEqual(last.reference?.count, 8, "the night itself is not in its own reference")
        XCTAssertEqual(last.reference!.center, log(50), accuracy: 1e-12)
        XCTAssertEqual(last.z!, (log(25) - log(50)) / 0.05, accuracy: 1e-9, "zero MAD → floored scale")
        XCTAssertTrue(last.updatesReference, "a valid unusual night still informs later days")
    }

    func testReplayIsDeterministicAndOrderIndependent() {
        let id = MetricIdentity.noopNightlyRMSSD()
        let d = days(15)
        let input = (0..<15).map { obs(id, d[$0], 40 + Double(($0 * 5) % 9)) }
        let a = CausalReference.scoreSequence(input, identity: id, cfg: .lnRMSSD)
        let b = CausalReference.scoreSequence(input.reversed(), identity: id, cfg: .lnRMSSD)
        let c = CausalReference.scoreSequence(input, identity: id, cfg: .lnRMSSD)
        XCTAssertEqual(a, b); XCTAssertEqual(a, c)
    }

    func testCalendarGapsAreElapsedNightsNotConsecutiveRows() {
        let id = MetricIdentity.noopNightlyRMSSD()
        let d = days(40)
        let input = (0..<6).map { obs(id, d[$0], 50) }
        let st = Baselines.causalState(input, identity: id, before: d[35], cfg: Baselines.hrvCfg)!
        XCTAssertEqual(st.nightsSinceUpdate, 29, "days 6…34 had no observation (day 35 is the one being scored)")
        XCTAssertEqual(st.status, .stale)
        let ref = CausalReference.reference(for: d[35], history: input, identity: id, cfg: .lnRMSSD)!
        XCTAssertEqual(ref.daysSinceLast, 30)
        XCTAssertEqual(ref.state, .stale)
    }

    /// The app rebuilds every day's baselines during a 2-year re-score; this must stay well under a second-scale cost.
    func testTwoYearCausalRescoreIsFast() {
        let d = days(730)
        let rows = (0..<730).map { i in
            DailyMetric(day: d[i], totalSleepMin: 420, efficiency: 90, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: 50 + i % 4, avgHrv: i % 9 == 0 ? nil : 45 + Double(i % 13),
                        recovery: nil, strain: nil, exerciseCount: nil)
        }
        let obs = MetricObservation.noopNightly(rows)
        let t0 = Date()
        var usable = 0
        for i in stride(from: 0, to: 730, by: 1) {
            let p = CausalBaselines.legacyProfile(rmssd: obs.rmssd, restingHR: obs.restingHR, before: d[i])
            if p.hrv?.usable == true { usable += 1 }
        }
        XCTAssertGreaterThan(usable, 700)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10, "per-day causal baselines must not be cubic in history")
    }

    // MARK: 9. Cold start, zero variance, stale, nonfinite → explicit states, no population fallback

    func testColdStartAndNonfiniteGiveStatesNotScores() {
        let id = MetricIdentity.noopNightlyRMSSD()
        let d = days(4)
        let scored = CausalReference.scoreSequence([obs(id, d[0], 50), obs(id, d[1], .nan), obs(id, d[2], -3),
                                                    obs(id, d[3], 48)], identity: id, cfg: .lnRMSSD)
        XCTAssertEqual(scored[0].outcome, .noReference)
        XCTAssertEqual(scored[1].outcome, .excluded)
        XCTAssertEqual(scored[2].outcome, .excluded)
        XCTAssertEqual(scored[3].outcome, .noReference)
        XCTAssertEqual(scored[3].reference?.state, .calibrating)
        XCTAssertNil(scored[3].z)

        let a = RecoveryAssessor.assess(sleep24hMin: 450, mainSleepS: 450 * 60, efficiency: 0.9, hrv: 50, restingHR: 52,
                                        quality: nil, baselines: .init(), minMainSleepS: 3 * 3600)
        XCTAssertNil(a.legacy.score, "no HRV baseline → no score, never a population average")
        XCTAssertEqual(a.autonomic.completeness, .unavailable)
        XCTAssertEqual(a.completeness, .partial)
    }

    // MARK: 10. Poor-quality extreme HRV cannot produce a confident maximum

    private let warmBaselines = AnalyticsEngine.ProfileBaselines(
        hrv: BaselineState(baseline: 50, spread: 5, nValid: 30, nightsSinceUpdate: 0, status: .trusted),
        restingHR: BaselineState(baseline: 52, spread: 2, nValid: 30, nightsSinceUpdate: 0, status: .trusted))

    func testPoorQualityExtremeHRVIsWithheld() {
        let marginal = VitalsQuality(hrvWindows: 6, hrvPairs: 1500, hrvWindowsByThird: [6, 0, 0], hrvTemporalCoverage: 0.08,
                                     hrWindows: 30)
        let a = RecoveryAssessor.assess(sleep24hMin: 450, mainSleepS: 450 * 60, efficiency: 0.9, hrv: 150, restingHR: 52,
                                        quality: marginal, baselines: warmBaselines, minMainSleepS: 3 * 3600)
        XCTAssertNil(a.legacy.score)
        XCTAssertNotNil(a.legacy.withheldReason)
        XCTAssertNotNil(a.legacy.breakdown, "inputs remain inspectable")

        let good = VitalsQuality(hrvWindows: 60, hrvPairs: 15_000, hrvWindowsByThird: [20, 20, 20], hrvTemporalCoverage: 0.7,
                                 hrWindows: 70)
        let b = RecoveryAssessor.assess(sleep24hMin: 450, mainSleepS: 450 * 60, efficiency: 0.9, hrv: 150, restingHR: 52,
                                        quality: good, baselines: warmBaselines, minMainSleepS: 3 * 3600)
        XCTAssertNotNil(b.legacy.score, "a well-measured unusual night stays visible")
        XCTAssertNil(b.legacy.withheldReason)
    }

    func testUnusualFlagsBothDirections() {
        var hist: [MetricObservation] = []
        let d = days(21)
        for i in 0..<20 { hist.append(obs(.noopNightlyRMSSD(), d[i], 50 + Double(i % 5) - 2)) }
        let ref = CausalReference.reference(for: d[20], history: hist, identity: .noopNightlyRMSSD(), cfg: .lnRMSSD)
        let bl = AnalyticsEngine.ProfileBaselines(lnRMSSDReference: ref)
        for v in [20.0, 140.0] {
            let a = RecoveryAssessor.assess(sleep24hMin: 450, mainSleepS: 450 * 60, efficiency: 0.9, hrv: v, restingHR: nil,
                                            quality: nil, baselines: bl, minMainSleepS: 3 * 3600)
            XCTAssertEqual(a.unusual.count, 1, "\(v)")
            XCTAssertEqual(a.unusual.first?.message.hasPrefix(v > 50 ? "above" : "below"), true)
            XCTAssertEqual(a.unusual.first?.lowQuality, true, "no quality info → marked low quality")
        }
    }

    func testLegacyContributionsSumToCompositeAndMissingTermsAreVisible() {
        let a = RecoveryAssessor.assess(sleep24hMin: 450, mainSleepS: 450 * 60, efficiency: 0.9, hrv: 55, restingHR: 50,
                                        quality: nil, baselines: warmBaselines, minMainSleepS: 3 * 3600)
        let b = a.legacy.breakdown!
        XCTAssertEqual(b.terms.reduce(0) { $0 + $1.contributionZ }, b.compositeZ, accuracy: 1e-12)
        XCTAssertFalse(b.terms.contains { $0.name == "Respiration" }, "inferred respiration is not a legacy input")
        XCTAssertEqual(a.legacy.modelVersion, RecoveryAssessor.legacyModelVersion)
    }

    // MARK: 11. Inferred respiration respects gaps (synthetic checks only)

    private func breathingBeats(seconds: Double, bpm: Double, dropFrom: Double? = nil, dropTo: Double? = nil)
        -> [RRInterval] {
        var t = 0.0, out: [RRInterval] = [], i = 0
        while t < seconds {
            let rr = (950 + 35 * sin(2 * .pi * bpm / 60 * t) + 4 * sin(Double(i) * 1.7)).rounded()
            t += rr / 1000; i += 1
            if let a = dropFrom, let b = dropTo, t >= a && t < b { continue }
            out.append(RRInterval(ts: 10_000 + Int(t), rrMs: Int(rr)))
        }
        return out
    }

    func testRespirationRecoversKnownFrequencyFromTimestampedBeats() {
        let r = RespiratoryRate.estimate(beats: breathingBeats(seconds: 290, bpm: 15))
        XCTAssertEqual(r.breathsPerMin ?? 0, 15, accuracy: 0.7)
    }

    func testDroppedPacketSplitsTheTimeAxis() {
        let beats = breathingBeats(seconds: 290, bpm: 15, dropFrom: 100, dropTo: 160)
        let runs = RespiratoryRate.contiguousRuns(beats)
        XCTAssertEqual(runs.count, 2)
        for run in runs { XCTAssertFalse(run.contains { $0.ts > 10_100 } && run.contains { $0.ts < 10_099 }) }
        // Both halves too short (< 120 s each) → no estimate, rather than one spliced across the hole.
        let short = breathingBeats(seconds: 220, bpm: 15, dropFrom: 100, dropTo: 120)
        XCTAssertEqual(RespiratoryRate.estimate(beats: short).rejection, "gap")
        XCTAssertNotNil(RespiratoryRate.estimate(rrMs: short.map { Double($0.rrMs) }).breathsPerMin,
                        "the old value-only path splices the gap and still reports a rate")
    }

    // MARK: Staging evaluation harness

    func testEvaluationPerfectAndAbstention() {
        let ref: [SleepState] = [.wake, .light, .light, .deep, .rem, .rem, .wake, .light]
        let perfect = StagingEvaluation.evaluate([.init(participant: "a", reference: ref, predicted: ref),
                                                  .init(participant: "b", reference: ref, predicted: ref)],
                                                 bootstrapReplicates: 50)
        XCTAssertEqual(perfect.kappa!, 1, accuracy: 1e-12)
        XCTAssertEqual(perfect.macroF1!, 1, accuracy: 1e-12)
        XCTAssertEqual(perfect.sleepSensitivity, 1); XCTAssertEqual(perfect.wakeSpecificity, 1)
        XCTAssertEqual(perfect.tstMinutes?.bias, 0)

        var abst = ref; abst[1] = .asleep; abst[3] = .unknown
        let r = StagingEvaluation.evaluate([.init(participant: "a", reference: ref, predicted: abst)], bootstrapReplicates: 0)
        XCTAssertEqual(r.confusion.joined().reduce(0, +), 6, "abstained epochs are neither right nor wrong")
        XCTAssertEqual(r.sleepWakeCoverage, 7.0 / 8.0, accuracy: 1e-12)
        XCTAssertEqual(r.stageCoverage, 4.0 / 5.0, accuracy: 1e-12)
    }

    func testEvaluationIsDeterministicAndFoldsAreParticipantDisjoint() {
        var nights: [StagingEvaluation.Night] = []
        for p in 0..<6 {
            let ref: [SleepState] = (0..<40).map { [.wake, .light, .deep, .rem][($0 / 5 + p) % 4] }
            let pred = ref.enumerated().map { i, s in i % (p + 3) == 0 ? .light : s }
            nights.append(.init(participant: "p\(p)", reference: ref, predicted: pred))
        }
        let a = StagingEvaluation.evaluate(nights, bootstrapReplicates: 200, seed: 7)
        let b = StagingEvaluation.evaluate(nights, bootstrapReplicates: 200, seed: 7)
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a.kappaCI)
        let folds = StagingEvaluation.participantFolds(nights.map(\.participant), k: 3, seed: 3)
        XCTAssertEqual(Set(folds.flatMap { $0 }).count, 6)
        XCTAssertEqual(folds.flatMap { $0 }.count, 6, "each participant in exactly one fold")
    }
}
