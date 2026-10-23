import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Deterministic synthetic-day scenarios for sleep boundaries, fragmented sleep, data gaps and strain.
final class SleepStrainScenarioTests: XCTestCase {

    enum Seg { case moving(min: Int, bpm: Int), sleep(min: Int, bpm: Int), lyingAwake(min: Int, bpm: Int), restless(min: Int, bpm: Int), noData(min: Int) }

    struct Built { var hr: [HRSample] = [], grav: [GravitySample] = [], t0 = 0, end = 0 }

    /// Local 15:00 on a fixed date, so clock-time rules (siesta window) behave the same everywhere.
    private var t0: Int {
        let c = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 15))!
        return Int(c.timeIntervalSince1970)
    }

    private func build(_ segs: [Seg]) -> Built {
        var b = Built(); b.t0 = t0
        var t = t0
        var j = 0
        for seg in segs {
            switch seg {
            case .noData(let m): t += m * 60
            case .moving(let m, let bpm), .sleep(let m, let bpm), .lyingAwake(let m, let bpm), .restless(let m, let bpm):
                let still: Bool
                var micro = false
                switch seg {
                case .moving: still = false
                case .sleep, .restless: still = true
                default: still = true; micro = false
                }
                _ = micro
                for i in 0..<(m * 60) {
                    j += 1
                    b.hr.append(HRSample(ts: t + i, bpm: bpm + (j % 3) - 1))
                    var restlessJolt = false
                    if case .restless = seg { restlessJolt = (i / 60) % 4 == 0 && i % 60 < 3 }   // 1 moving minute in 4
                    if still && !restlessJolt { b.grav.append(GravitySample(ts: t + i, x: 0, y: 0, z: 1)) }
                    else if still { b.grav.append(GravitySample(ts: t + i, x: Double(i % 2) * 0.3, y: 0, z: 1)) }
                    else { b.grav.append(GravitySample(ts: t + i, x: Double(i % 2) * 0.5, y: 0, z: 1)) }
                }
                t += m * 60
            }
        }
        b.end = t
        return b
    }

    private func sessions(_ segs: [Seg]) -> (Built, [SleepSession]) {
        let b = build(segs)
        return (b, SleepStager.detectSleep(hr: b.hr, gravity: b.grav))
    }

    private func min(_ ts: Int, from b: Built) -> Int { (ts - b.t0) / 60 }

    // MARK: Sleep

    func testNormalNightIsOneMainSession() {
        let (b, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 480, bpm: 52), .moving(min: 120, bpm: 85)])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].kind, .main)
        XCTAssertEqual(Double(min(s[0].start, from: b)), 480, accuracy: 20)
        XCTAssertEqual(Double(min(s[0].end, from: b)), 960, accuracy: 20)
        XCTAssertFalse(s[0].isProvisional)
    }

    func testShortAndMediumWakesStayInsideOneSession() {
        for wake in [5, 10, 30] {
            let (b, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 300, bpm: 52), .moving(min: wake, bpm: 78),
                                   .sleep(min: 120, bpm: 52), .moving(min: 120, bpm: 85)])
            XCTAssertEqual(s.count, 1, "wake \(wake) min")
            XCTAssertEqual(Double(min(s[0].end, from: b)), Double(480 + 300 + wake + 120), accuracy: 20, "final wake after a \(wake) min wake")
        }
    }

    func testFortyFiveMinuteWakeThenSleepIsOneSessionWithFinalWakeLater() {
        let (b, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 360, bpm: 52), .moving(min: 45, bpm: 80),
                               .sleep(min: 120, bpm: 52), .moving(min: 120, bpm: 85)])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(Double(min(s[0].end, from: b)), Double(480 + 360 + 45 + 120), accuracy: 20)
    }

    func testNinetyMinuteWakeIsNotSilentlyMerged() {
        let (_, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 360, bpm: 52), .moving(min: 95, bpm: 80),
                               .sleep(min: 90, bpm: 54), .moving(min: 120, bpm: 85)])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first?.kind, .main)
        XCTAssertEqual(s.last?.kind, .nap)
    }

    func testLyingAwakeMotionlessBeforeSleepIsNotScoredAsSleep() {
        let (b, s) = sessions([.moving(min: 480, bpm: 85), .lyingAwake(min: 60, bpm: 74), .sleep(min: 420, bpm: 52), .moving(min: 120, bpm: 85)])
        XCTAssertEqual(s.count, 1)
        XCTAssertGreaterThan(min(s[0].start, from: b), 480 + 40, "onset should be after the awake hour")
    }

    func testDeviceOffInsideNightIsNeverBridgedOrCountedAsSleep() {
        let (b, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 240, bpm: 52), .noData(min: 120), .sleep(min: 240, bpm: 52), .moving(min: 60, bpm: 85)])
        XCTAssertGreaterThanOrEqual(s.count, 2)
        for x in s {
            // no session may span the unrecorded 2 h
            XCTAssertFalse(x.start < b.t0 + (480 + 240) * 60 && x.end > b.t0 + (480 + 360) * 60)
            let m = SleepStager.hypnogramMetrics(x)
            XCTAssertLessThanOrEqual(m.tstS, Double(x.end - x.start) + 1)
        }
    }

    func testRestlessLightSleepAtSleepHRIsNotCutOff() {
        // Quiet core, then 150 min of restless (1 moving minute in 4) sleep at sleeping HR, then up. The final wake
        // must be the real one, not the end of the quiet core.
        let (b, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 360, bpm: 52), .restless(min: 150, bpm: 55), .moving(min: 120, bpm: 85)])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(Double(min(s[0].end, from: b)), Double(480 + 360 + 150), accuracy: 20)
    }

    func testRestlessButAwakeHRIsNotExtended() {
        let (b, s) = sessions([.moving(min: 480, bpm: 85), .sleep(min: 360, bpm: 52), .restless(min: 150, bpm: 80), .moving(min: 120, bpm: 85)])
        XCTAssertEqual(s.count, 1)
        XCTAssertLessThan(min(s[0].end, from: b), 480 + 360 + 40)
    }

    func testShortStillSofaAfternoonIsNotSleep() {
        let (_, s) = sessions([.moving(min: 240, bpm: 85), .lyingAwake(min: 40, bpm: 70), .moving(min: 240, bpm: 85)])
        XCTAssertTrue(s.isEmpty)
    }

    func testInvariantsAndDeterminism() {
        let segs: [Seg] = [.moving(min: 480, bpm: 85), .sleep(min: 300, bpm: 52), .moving(min: 20, bpm: 78), .sleep(min: 150, bpm: 52), .moving(min: 60, bpm: 85)]
        let (_, a) = sessions(segs), (_, b) = sessions(segs)
        XCTAssertEqual(a, b)
        for x in a {
            let m = SleepStager.hypnogramMetrics(x)
            XCTAssertLessThanOrEqual(m.tstS, Double(x.end - x.start))
            XCTAssertGreaterThanOrEqual(m.wasoS, 0)
            XCTAssertTrue((0...1).contains(x.efficiency))
            XCTAssertLessThanOrEqual(x.start, x.end)
        }
    }

    func testProvisionalUntilDataExtendsPastWake() {
        let atEnd = sessions([.moving(min: 480, bpm: 85), .sleep(min: 420, bpm: 52)]).1
        XCTAssertEqual(atEnd.first?.isProvisional, true)
        let later = sessions([.moving(min: 480, bpm: 85), .sleep(min: 420, bpm: 52), .moving(min: 120, bpm: 85)]).1
        XCTAssertEqual(later.first?.isProvisional, false)
    }

    // MARK: Strain

    private func strain(_ segs: [Seg], dayStartOffsetMin: Int = 0, extra: [HRSample] = []) -> Double? {
        let b = build(segs)
        let from = b.t0 + dayStartOffsetMin * 60
        return AnalyticsEngine.analyzeDay(day: AnalyticsEngine.dayString(from + 3600), hr: b.hr + extra, gravity: b.grav,
                                          profile: UserProfile(age: 30), dayRange: (from, from + 86_400)).strain
    }

    func testIdleMorningHasNegligibleStrain() {
        let v = strain([.sleep(min: 120, bpm: 55)])
        XCTAssertNotNil(v)
        XCTAssertLessThan(v!, 1.5, "a day that just began must not start at the ~4.6 rest-day floor")
    }

    func testBaselineBuildsOverTheWakingDay() {
        // Night, then idle waking time at light HR: strain starts at 0 on waking and grows toward the ~4.5 rest-day level.
        let night: [Seg] = [.moving(min: 240, bpm: 85), .sleep(min: 420, bpm: 52)]
        // The day (midnight) starts at the beginning of the night here, as it does for a person who sleeps past midnight.
        let wake = strain(night + [.moving(min: 5, bpm: 72)], dayStartOffsetMin: 240)!
        let midday = strain(night + [.moving(min: 360, bpm: 72)], dayStartOffsetMin: 240)!
        let evening = strain(night + [.moving(min: 960, bpm: 72)], dayStartOffsetMin: 240)!
        XCTAssertLessThan(wake, 0.5)
        XCTAssertGreaterThan(midday, wake)
        XCTAssertEqual(evening, 4.6, accuracy: 0.6)
    }

    func testSingleArtifactSpikeDoesNotMoveStrain() {
        let segs: [Seg] = [.moving(min: 120, bpm: 72)]
        let b = build(segs)
        let spike = [HRSample(ts: b.t0 + 3600, bpm: 210)]
        XCTAssertEqual(strain(segs), strain(segs, extra: spike))
    }

    func testDuplicateSamplesDoNotDoubleStrain() {
        let segs: [Seg] = [.moving(min: 90, bpm: 150)]
        let b = build(segs)
        XCTAssertEqual(strain(segs), strain(segs, extra: b.hr))
    }

    func testSustainedCyclingAddsLoad() {
        let rest = strain([.sleep(min: 180, bpm: 60)])!
        let ride = strain([.sleep(min: 60, bpm: 60), .moving(min: 90, bpm: 155), .sleep(min: 30, bpm: 60)])!
        XCTAssertGreaterThan(ride, rest + 3)
        XCTAssertLessThanOrEqual(ride, 21)
    }

    func testMissingDataEarnsNoLoad() {
        let hr = [HRSample(ts: 0, bpm: 160), HRSample(ts: 7200, bpm: 160)]
        XCTAssertLessThan(StrainScorer.whoopZoneLoadTimed(hr, maxHR: 190), 0.2)   // ~6 s of credit, not 2 h
    }

    func testPreviousDayWindowDoesNotLeakIntoStrain() {
        // A hard ride at the start of the buffer, outside the day's range, must not score on this day.
        let b = build([.moving(min: 90, bpm: 160), .sleep(min: 300, bpm: 60)])
        let from = b.t0 + 120 * 60
        let withRide = AnalyticsEngine.analyzeDay(day: "d", hr: b.hr, gravity: b.grav, profile: UserProfile(age: 30), dayRange: (from, from + 86_400)).strain
        let without = AnalyticsEngine.analyzeDay(day: "d", hr: b.hr.filter { $0.ts >= from }, gravity: b.grav.filter { $0.ts >= from },
                                                 profile: UserProfile(age: 30), dayRange: (from, from + 86_400)).strain
        XCTAssertEqual(withRide, without)
    }

    func testHRQualityKeepsSustainedEffortsAndDropsOnlyIsolatedSpikes() {
        var hr = (0..<60).map { HRSample(ts: $0, bpm: 70) }
        hr[30] = HRSample(ts: 30, bpm: 210)
        XCTAssertEqual(HRQuality.clean(hr).count, 59)
        let sprint = (0..<60).map { HRSample(ts: $0, bpm: $0 < 20 ? 70 : 175) }   // a real, sustained jump
        XCTAssertEqual(HRQuality.clean(sprint).count, 60)
    }
}
