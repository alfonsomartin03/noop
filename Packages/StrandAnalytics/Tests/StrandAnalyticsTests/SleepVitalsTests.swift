import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepVitalsTests: XCTestCase {

    // MARK: Builders

    /// RR series (ms) starting at `start`, one beat per cumulative interval, timestamps = whole seconds.
    private func rrSeries(start: Int, seconds: Int, base: Double, swing: Double) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(start), flip = 1.0
        while t < Double(start + seconds) {
            let rr = base + flip * swing
            out.append(RRInterval(ts: Int(t), rrMs: Int(rr.rounded())))
            t += rr / 1000.0
            flip = -flip
        }
        return out
    }
    private func hr(start: Int, seconds: Int, bpm: Int) -> [HRSample] { (0..<seconds).map { HRSample(ts: start + $0, bpm: bpm) } }

    private let t0 = 1_000_000

    // MARK: RMSSD maths

    func testRMSSDKnownSequenceByHand() {
        // diffs: +20, -30, +10 → squares 400, 900, 100 → mean 466.667 → sqrt = 21.6025
        let nn: [Double] = [800, 820, 790, 800]
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(nn)!, (1400.0 / 3.0).squareRoot(), accuracy: 1e-9)
    }

    func testAlternatingSeriesRMSSDIsTwiceTheSwing() {
        // 1000 ± 25 alternating: every successive difference is 50 → RMSSD 50 exactly.
        let rr = (0..<200).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 975 : 1025) }
        XCTAssertEqual(HRVAnalyzer.analyzeTimed(rr).rmssd!, 50, accuracy: 1e-9)
    }

    func testRemovedBeatDoesNotCreateAcrossGapDifference() {
        // 100 steady beats alternating ±5 (RMSSD 10) with one isolated artifact. The spike is rejected and the
        // pair around it must NOT be differenced, so RMSSD stays 10.
        var rr = (0..<100).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 995 : 1005) }
        rr[50] = RRInterval(ts: 50, rrMs: 1800)
        XCTAssertEqual(HRVAnalyzer.analyzeTimed(rr).rmssd!, 10, accuracy: 0.5)
    }

    func testDataGapIsNotDifferenced() {
        var rr = (0..<60).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 995 : 1005) }
        rr += (0..<60).map { RRInterval(ts: 3600 + $0, rrMs: $0 % 2 == 0 ? 1195 : 1205) }   // an hour later, slower beat
        let r = HRVAnalyzer.analyzeTimed(rr).rmssd!
        XCTAssertEqual(r, 10, accuracy: 0.5, "the 200 ms step across the gap must not enter RMSSD")
    }

    // MARK: Window selection

    private func night(minutes: Int, bpm: Int = 52, base: Double = 1150, swing: Double = 25,
                       extra: (inout [HRSample], inout [RRInterval]) -> Void = { _, _ in }) -> (HRStreams) {
        let secs = minutes * 60
        var h = hr(start: t0, seconds: secs, bpm: bpm)
        var r = rrSeries(start: t0, seconds: secs, base: base, swing: swing)
        extra(&h, &r)
        return HRStreams(hr: h, rr: r, start: t0, end: t0 + secs)
    }
    struct HRStreams { var hr: [HRSample]; var rr: [RRInterval]; var start: Int; var end: Int }

    private func vitals(_ s: HRStreams, stages: [StageSegment] = []) -> SleepVitals {
        SleepVitalsCalculator.compute(start: s.start, end: s.end, stages: stages, hr: s.hr, rr: s.rr)
    }

    func testUninterruptedNightGivesExpectedValues() {
        let v = vitals(night(minutes: 480))
        XCTAssertEqual(v.restingHR, 52)
        XCTAssertEqual(v.hrv!, 50, accuracy: 1.0)          // 1150 ± 25 → RMSSD 50
        XCTAssertGreaterThan(v.hrvWindowCount, 80)
    }

    func testOnlyMeasurementsInsideTheSessionAreUsed() {
        // Samples outside [start, end] (high HR, wild RR) must not leak in.
        var s = night(minutes: 240)
        s.hr += hr(start: s.end + 1, seconds: 3600, bpm: 110)
        s.hr += hr(start: s.start - 3600, seconds: 3599, bpm: 110)
        s.rr += rrSeries(start: s.end + 1, seconds: 3600, base: 600, swing: 200)
        XCTAssertEqual(vitals(s).restingHR, 52)
        XCTAssertEqual(vitals(s).hrv!, 50, accuracy: 1.0)
    }

    func testOnsetAndWakeTransitionsAreExcluded() {
        // High HR (75) in the first 8 min and last 4 min must not set the resting HR or the HRV.
        var s = night(minutes: 240)
        for i in 0..<(8 * 60) { s.hr[i] = HRSample(ts: s.hr[i].ts, bpm: 75) }
        for i in (s.hr.count - 4 * 60)..<s.hr.count { s.hr[i] = HRSample(ts: s.hr[i].ts, bpm: 75) }
        let v = vitals(s)
        XCTAssertEqual(v.restingHR, 52)
        XCTAssertEqual(v.onsetHR!, 52, accuracy: 0.5)       // first USED window, not the raw edge
    }

    func testRestingHRIsNotTheMinimumDip() {
        // A 10-min dip to 44 bpm inside a 54-bpm night: the floor is 44, the resting HR must stay near 54.
        var s = night(minutes: 300, bpm: 54)
        for i in (120 * 60)..<(130 * 60) { s.hr[i] = HRSample(ts: s.hr[i].ts, bpm: 44) }
        let v = vitals(s)
        XCTAssertEqual(v.minWindowHR!, 44, accuracy: 0.6)
        XCTAssertGreaterThanOrEqual(v.restingHR!, 52)
        XCTAssertEqual(v.minSampleHR, 44)
    }

    func testFewArtifactWindowsDoNotInflateHRV() {
        // 5 windows of garbage RR (random ±400 ms, within the plausible range) in a clean 50 ms night.
        var s = night(minutes: 480)
        var g = SystemRandomNumberGenerator()
        _ = g
        var seed: UInt64 = 42
        func rnd() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % 800) + 500 }
        for w in [20, 35, 50, 70, 90] {
            let a = s.start + w * 300, b = a + 300
            s.rr.removeAll { $0.ts >= a && $0.ts < b }
            var t = a
            while t < b { s.rr.append(RRInterval(ts: t, rrMs: rnd())); t += 1 }
        }
        let v = vitals(s)
        XCTAssertEqual(v.hrv!, 50, accuracy: 3.0, "median over windows resists a few corrupted windows")
        XCTAssertGreaterThanOrEqual(v.rejectionCounts["HRV: artifacts", default: 0] + v.rejectionCounts["HRV: too few clean intervals", default: 0], 3)
    }

    func testMissingRRMakesHRVUnavailableNotInvented() {
        var s = night(minutes: 240)
        s.rr = []
        let v = vitals(s)
        XCTAssertNil(v.hrv)
        XCTAssertEqual(v.restingHR, 52)
    }

    func testSparseRRWindowsAreRejected() {
        // 1 beat in 10 survives: coverage far below 50 % of what HR implies → no HRV.
        var s = night(minutes: 240)
        s.rr = s.rr.enumerated().filter { $0.offset % 10 == 0 }.map { $0.element }
        XCTAssertNil(vitals(s).hrv)
    }

    func testAwakeStretchInsideSleepIsExcluded() {
        // Staged wake 90–130 min with HR 85 and noisy RR must not enter either metric.
        var s = night(minutes: 300)
        let a = s.start + 90 * 60, b = s.start + 130 * 60
        for i in s.hr.indices where s.hr[i].ts >= a && s.hr[i].ts < b { s.hr[i] = HRSample(ts: s.hr[i].ts, bpm: 85) }
        s.rr.removeAll { $0.ts >= a && $0.ts < b }
        s.rr += rrSeries(start: a, seconds: 40 * 60, base: 700, swing: 90)
        let stages = [StageSegment(start: s.start, end: a, stage: "light"), StageSegment(start: a, end: b, stage: "wake"),
                      StageSegment(start: b, end: s.end, stage: "light")]
        let v = vitals(s, stages: stages)
        XCTAssertEqual(v.restingHR, 52)
        XCTAssertEqual(v.hrv!, 50, accuracy: 1.5)
        XCTAssertGreaterThan(v.rejectionCounts["HRV: awake", default: 0], 6)
    }

    func testSameInputsSameOutputsAndDuplicatesChangeNothing() {
        let s = night(minutes: 240)
        let a = vitals(s), b = vitals(s)
        XCTAssertEqual(a, b)
        var d = s
        d.hr += s.hr; d.rr += s.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rrMs) }   // duplicated delivery
        // duplicates do not change resting HR; RR duplicates are removed by the store key (ts, rrMs) in the app
        XCTAssertEqual(vitals(d).restingHR, a.restingHR)
    }

    func testAthleticLowRHRAndGenuinelyHighHRVSurvive() {
        // 38 bpm sleeper (RR ~1580) with ±60 ms alternation → RMSSD 120: both must be reported as measured.
        let s = night(minutes: 300, bpm: 38, base: 1580, swing: 60)
        let v = vitals(s)
        XCTAssertEqual(v.restingHR, 38)
        XCTAssertEqual(v.hrv!, 120, accuracy: 2)
    }

    func testIncompleteNightIsUnavailable() {
        XCTAssertNil(vitals(night(minutes: 40)).hrv)   // fewer than 6 valid windows after edge trimming
    }

    // MARK: Recovery

    private func base(_ m: Double, _ s: Double) -> RecoveryScorer.DriverBaseline { .init(mean: m, spread: s) }

    func testContributionsSumToCompositeAndMatchScore() {
        let b = RecoveryScorer.breakdown(hrv: 50, rhr: 52, resp: nil, hrvBaseline: base(41, 7.4), rhrBaseline: base(58, 2.4),
                                         respBaseline: nil, sleepPerf: 0.95)!
        XCTAssertEqual(b.terms.reduce(0) { $0 + $1.contributionZ }, b.compositeZ, accuracy: 1e-12)
        XCTAssertEqual(b.terms.reduce(0) { $0 + $1.normalizedWeight }, 1, accuracy: 1e-12)
        XCTAssertEqual(RecoveryScorer.recovery(hrv: 50, rhr: 52, resp: nil, hrvBaseline: base(41, 7.4), rhrBaseline: base(58, 2.4),
                                               respBaseline: nil, sleepPerf: 0.95)!, b.score, accuracy: 1e-12)
    }

    func testBetterSleepAndStressfulNightMoveRecoveryTheRightWay() {
        func rec(_ hrv: Double, _ rhr: Double, _ eff: Double) -> Double {
            RecoveryScorer.recovery(hrv: hrv, rhr: rhr, resp: nil, hrvBaseline: base(41, 7.4), rhrBaseline: base(58, 2.4),
                                    respBaseline: nil, sleepPerf: eff)!
        }
        XCTAssertGreaterThan(rec(46, 56, 0.95), rec(41, 58, 0.80))      // improved night
        XCTAssertLessThan(rec(30, 63, 0.70), rec(41, 58, 0.90))         // stressful night
    }

    func testRecoveryRecomputesWhenSleepBoundariesChange() {
        // Same raw data, session end moved earlier by 2 h (a corrected boundary) → vitals are recomputed from
        // the new window only; nothing stale from the longer window survives.
        let s = night(minutes: 480)
        let full = SleepVitalsCalculator.compute(start: s.start, end: s.end, stages: [], hr: s.hr, rr: s.rr)
        let short = SleepVitalsCalculator.compute(start: s.start, end: s.end - 120 * 60, stages: [], hr: s.hr, rr: s.rr)
        XCTAssertGreaterThan(full.hrvWindowCount, short.hrvWindowCount)
        XCTAssertEqual(short.rrBeats, s.rr.filter { $0.ts <= s.end - 120 * 60 }.count)
    }
}
