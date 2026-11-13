import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepStagerTests: XCTestCase {

    // MARK: - Cole–Kripke

    func testColeKripkeAllStillIsSleep() {
        // Zero activity → SI = 0 < 1 for every epoch → all sleep.
        let flags = SleepStager.coleKripke([Double](repeating: 0, count: 20))
        XCTAssertTrue(flags.allSatisfy { $0 })
    }

    func testColeKripkeHighActivityIsWake() {
        // A large clipped count at the center weight (230) → SI ≥ 1 → wake.
        // rescaled count of 300 (the clip) at A0: 0.001 * 230 * 300 = 69 ≥ 1.
        var counts = [Double](repeating: 0, count: 9)
        counts[4] = 300
        let flags = SleepStager.coleKripke(counts)
        XCTAssertFalse(flags[4])  // center epoch is wake
    }

    func testRescaleCountsDivideAndClip() {
        XCTAssertEqual(SleepStager.rescaleCounts([200]), [2.0])
        XCTAssertEqual(SleepStager.rescaleCounts([50000]), [300.0])  // clipped
    }

    // MARK: - Gravity stillness spine

    /// Build a still gravity stream (constant orientation) at 1 Hz.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// Build an active gravity stream (oscillating) at 1 Hz.
    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { i -> GravitySample in
            let phase = Double(i % 2) * 0.5  // 0.5 g jumps per sample → clearly moving
            return GravitySample(ts: start + i, x: phase, y: 0, z: 1.0)
        }
    }

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testDetectSleepFindsStillNight() {
        // 90 min still + low HR (50 bpm) → one sleep session.
        let start = 1_000_000
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.start, start)
        XCTAssertGreaterThan(s.efficiency, 0.5)
        XCTAssertEqual(s.restingHR, 50)
    }

    func testDetectSleepRejectsShortBout() {
        // Only 20 min still — below napMinMin (30) → no session.
        let start = 2_000_000
        let grav = stillGravity(start: start, durationS: 20 * 60)
        let hr = hrStream(start: start, durationS: 20 * 60, bpm: 50)
        XCTAssertTrue(SleepStager.detectSleep(hr: hr, gravity: grav).isEmpty)
    }

    func testDetectSleepEmptyGravity() {
        XCTAssertTrue(SleepStager.detectSleep(gravity: []).isEmpty)
    }

    func testDetectSleepHRConfirmationRejectsHighHR() {
        // Still gravity but HR is well above the day median*1.05. The daytime is
        // long (4 h) and low-HR (55) so the day median stays ~55; the still 90-min
        // "night" runs at 120 bpm, which exceeds 55*1.05 → the run is HR-rejected.
        let start = 3_000_000
        let sleepDur = 90 * 60
        let dayDur = 4 * 60 * 60
        let dayGrav = activeGravity(start: start, durationS: dayDur)
        let dayHR = hrStream(start: start, durationS: dayDur, bpm: 55)
        let nightGrav = stillGravity(start: start + dayDur, durationS: sleepDur)
        let nightHR = hrStream(start: start + dayDur, durationS: sleepDur, bpm: 120)
        let sessions = SleepStager.detectSleep(hr: dayHR + nightHR, gravity: dayGrav + nightGrav)
        // The still run's mean HR (120) >> median(55)*1.05 → rejected.
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Staging output integrity

    func testStagesTileSessionExactly() {
        let start = 4_000_000
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let s = SleepStager.detectSleep(hr: hr, gravity: grav)[0]
        XCTAssertFalse(s.stages.isEmpty)
        // Segments must be contiguous and span exactly [start, end].
        XCTAssertEqual(s.stages.first!.start, s.start)
        XCTAssertEqual(s.stages.last!.end, s.end)
        for i in 0..<(s.stages.count - 1) {
            XCTAssertEqual(s.stages[i].end, s.stages[i + 1].start)
        }
        // Every stage label is one of the four valid classes.
        for seg in s.stages {
            XCTAssertTrue(["wake", "light", "deep", "rem"].contains(seg.stage))
        }
    }

    func testEfficiencyComputation() {
        // A 1000 s session with 100 s of wake → efficiency = 0.9.
        let stages = [
            StageSegment(start: 0, end: 100, stage: "wake"),
            StageSegment(start: 100, end: 1000, stage: "light"),
        ]
        let eff = SleepStager.efficiency(start: 0, end: 1000, stages: stages)
        XCTAssertEqual(eff, 0.9, accuracy: 1e-9)
    }

    // MARK: - Hypnogram metrics

    func testHypnogramMetricsAASM() {
        // SOL 60 s, then light 540 s, deep 300 s, wake 60 s (disturbance), rem 240 s.
        let stages = [
            StageSegment(start: 0, end: 60, stage: "wake"),       // pre-onset latency
            StageSegment(start: 60, end: 600, stage: "light"),    // 540 s
            StageSegment(start: 600, end: 900, stage: "deep"),    // 300 s
            StageSegment(start: 900, end: 960, stage: "wake"),    // WASO 60 s
            StageSegment(start: 960, end: 1200, stage: "rem"),    // 240 s
        ]
        let session = SleepSession(start: 0, end: 1200, efficiency: 0.95,
                                   stages: stages, restingHR: 50, avgHRV: 60)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.tibS, 1200, accuracy: 1e-9)
        XCTAssertEqual(m.tstS, 540 + 300 + 240, accuracy: 1e-9)  // 1080
        XCTAssertEqual(m.solS, 60, accuracy: 1e-9)
        XCTAssertEqual(m.wasoS, 60, accuracy: 1e-9)
        XCTAssertEqual(m.disturbances, 1)
        XCTAssertEqual(m.deepMin, 5.0, accuracy: 1e-9)
        XCTAssertEqual(m.remMin, 4.0, accuracy: 1e-9)
        XCTAssertEqual(m.lightMin, 9.0, accuracy: 1e-9)
        // Percentages sum to ~100.
        XCTAssertEqual(m.deepPct + m.remPct + m.lightPct, 100.0, accuracy: 1e-6)
    }

    func testHypnogramREMLatency() {
        let stages = [
            StageSegment(start: 0, end: 300, stage: "light"),   // onset at 0
            StageSegment(start: 300, end: 600, stage: "rem"),   // first REM at 300
        ]
        let session = SleepSession(start: 0, end: 600, efficiency: 1.0,
                                   stages: stages, restingHR: nil, avgHRV: nil)
        let m = SleepStager.hypnogramMetrics(session)
        XCTAssertEqual(m.remLatencyS, 300, accuracy: 1e-9)
    }

    // MARK: - Respiration helper

    func testRespRateFromSyntheticBreathing() {
        // Synthesize a clean 0.25 Hz breathing wave (15 br/min) over 60 s at 1 Hz.
        let n = 60
        let resp = (0..<n).map { i -> Double in sin(2 * Double.pi * 0.25 * Double(i)) * 10 + 100 }
        let (rate, rrv) = SleepStager.respRateAndRRV(resp)
        XCTAssertFalse(rate.isNaN)
        XCTAssertEqual(rate, 15.0, accuracy: 2.0)  // ~15 breaths/min
        XCTAssertGreaterThanOrEqual(rrv, 0)
    }

    func testRespRateTooFewSamples() {
        let (rate, rrv) = SleepStager.respRateAndRRV([1, 2, 3])
        XCTAssertTrue(rate.isNaN)
        XCTAssertTrue(rrv.isNaN)
    }

    // MARK: - Night vs nap vs sedentary rest

    /// Still body with one small fidget (0.05 g) every minute: quiet to a 0.01 g per-sample test, not a sleeper.
    private func fidgetGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: ($0 % 60 == 0 && $0 > 0) ? 0.05 : 0, y: 0, z: 1.0) }
    }

    func testSedentaryRestWithLowHRIsNotSleep() {
        let start = 5_000_000
        let day = 3 * 3600, couch = 2 * 3600
        let grav = activeGravity(start: start, durationS: day) + fidgetGravity(start: start + day, durationS: couch)
        let hr = hrStream(start: start, durationS: day, bpm: 85) + hrStream(start: start + day, durationS: couch, bpm: 55)
        XCTAssertTrue(SleepStager.detectSleep(hr: hr, gravity: grav).isEmpty)
    }

    func testNightIsMainAndShortDaySleepIsNap() {
        let start = 6_000_000
        let day = 4 * 3600, night = 7 * 3600, gap = 3 * 3600, nap = 45 * 60
        var grav = activeGravity(start: start, durationS: day)
        var hr = hrStream(start: start, durationS: day, bpm: 85)
        grav += stillGravity(start: start + day, durationS: night)
        hr += hrStream(start: start + day, durationS: night, bpm: 52)
        let napStart = start + day + night
        grav += activeGravity(start: napStart, durationS: gap)
        hr += hrStream(start: napStart, durationS: gap, bpm: 85)
        grav += stillGravity(start: napStart + gap, durationS: nap)
        hr += hrStream(start: napStart + gap, durationS: nap, bpm: 62)
        let s = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(s.map { $0.kind }, [.main, .nap])
    }

    func testShortWakeInsideNightStaysOneNight() {
        let start = 7_000_000
        let day = 3 * 3600, half = 3 * 3600, wake = 25 * 60
        var grav = activeGravity(start: start, durationS: day)
        var hr = hrStream(start: start, durationS: day, bpm: 85)
        grav += stillGravity(start: start + day, durationS: half) + activeGravity(start: start + day + half, durationS: wake)
            + stillGravity(start: start + day + half + wake, durationS: half)
        hr += hrStream(start: start + day, durationS: half, bpm: 52) + hrStream(start: start + day + half, durationS: wake, bpm: 80)
            + hrStream(start: start + day + half + wake, durationS: half, bpm: 52)
        let s = SleepStager.detectSleep(hr: hr, gravity: grav)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.kind, .main)
    }

    // MARK: nap evidence v2 (issue #19)

    /// Night, active afternoon, then a still 60-min daytime span with the given HR (nil = none recorded).
    private func dayWithStillSpan(hr spanHR: [HRSample]?) -> (hr: [HRSample], grav: [GravitySample], spanStart: Int) {
        let start = 9_000_000
        let day = 4 * 3600, night = 7 * 3600, gap = 3 * 3600, still = 60 * 60
        var grav = activeGravity(start: start, durationS: day)
        var hr = hrStream(start: start, durationS: day, bpm: 85)
        grav += stillGravity(start: start + day, durationS: night)
        hr += hrStream(start: start + day, durationS: night, bpm: 52)
        let after = start + day + night
        grav += activeGravity(start: after, durationS: gap)
        hr += hrStream(start: after, durationS: gap, bpm: 85)
        grav += stillGravity(start: after + gap, durationS: still)
        hr += spanHR ?? []
        grav += activeGravity(start: after + gap + still, durationS: 3600)
        hr += hrStream(start: after + gap + still, durationS: 3600, bpm: 85)
        return (hr, grav, after + gap)
    }

    func testStillSpanWithoutHeartRateIsNotANap() {
        // Off-wrist on a table / no HR: perfectly still, nothing to confirm sleep. v1 called this a nap.
        let d = dayWithStillSpan(hr: nil)
        let s = SleepStager.detectSleep(hr: d.hr, gravity: d.grav)
        XCTAssertEqual(s.filter { !$0.lowEvidence }.map(\.kind), [.main])
        // The span is kept only as a correctable candidate, with no invented heart rate, HRV or stage.
        let weak = try! XCTUnwrap(s.first(where: \.lowEvidence))
        XCTAssertEqual(Double(weak.start), Double(d.spanStart), accuracy: 15 * 60)
        XCTAssertNil(weak.restingHR)
        XCTAssertNil(weak.avgHRV)
        XCTAssertFalse(weak.stages.contains { $0.state.isStaged }, "no stage estimate without cardiac data")
    }

    func testStillSpanWithSparseHeartRateIsNotANap() {
        // Ten readings in an hour: too little to judge a dip, so it can't be confirmed as sleep.
        let e = dayWithStillSpan(hr: nil)
        let sparse = (0..<10).map { HRSample(ts: e.spanStart + $0 * 360, bpm: 60) }
        let s = SleepStager.detectSleep(hr: (e.hr + sparse).sorted { $0.ts < $1.ts }, gravity: e.grav)
        XCTAssertEqual(s.filter { !$0.lowEvidence }.map(\.kind), [.main])
        XCTAssertEqual(s.filter(\.lowEvidence).count, 1)
    }

    func testStillSpanWithSleepLevelHeartRateIsStillANap() {
        let e = dayWithStillSpan(hr: nil)
        let napHR = hrStream(start: e.spanStart, durationS: 3600, bpm: 60)
        let s = SleepStager.detectSleep(hr: (e.hr + napHR).sorted { $0.ts < $1.ts }, gravity: e.grav)
        XCTAssertEqual(s.map(\.kind), [.main, .nap])
        XCTAssertFalse(s.contains(where: \.lowEvidence))
    }

    // MARK: low-evidence spans and user corrections (issue #19 review, P1)

    private func analyze(_ d: (hr: [HRSample], grav: [GravitySample], spanStart: Int), corrections: [SleepCorrection]) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: AnalyticsEngine.dayString(d.spanStart + 3600), hr: d.hr, gravity: d.grav,
                                   profile: UserProfile(age: 30), dayRange: (9_000_000, 9_000_000 + 16 * 3600),
                                   sleepCorrections: corrections)
    }
    private func overlapping(_ r: AnalyticsEngine.DayResult, _ start: Int) -> ClassifiedSleepSession? {
        r.classifiedSleep.first { $0.start < start + 3600 && $0.end > start }
    }

    func testLowEvidenceSpanIsUncertainAndCountsNowhere() throws {
        let d = dayWithStillSpan(hr: nil)
        try XCTSkipUnless(AnalyticsEngine.dayString(d.spanStart - 3 * 3600) == AnalyticsEngine.dayString(d.spanStart + 3600),
                          "fixture night and still span fall on different local days in this time zone")
        let r = analyze(d, corrections: [])
        let s = try XCTUnwrap(overlapping(r, d.spanStart))
        XCTAssertEqual(s.kind, .uncertain)
        XCTAssertEqual(s.reason, SleepSessionClassifier.lowEvidenceReason)
        XCTAssertFalse(s.userCorrected)
        XCTAssertTrue(r.napSessions.isEmpty)
        XCTAssertEqual(r.classifiedSleep.filter(\.isPrimary).count, 1)
        // Not confident sleep: its hour is not taken out of the day's load.
        let excluded = try XCTUnwrap(r.load?.sleepExcludedS)
        XCTAssertEqual(Double(excluded), 7 * 3600, accuracy: 20 * 60)
    }

    func testStoredNapCorrectionOnALowEvidenceSpanSurvivesRescoring() throws {
        // The reported failure: a still hour without heart rate that the wearer had marked as a nap. v2's first cut
        // deleted the candidate before corrections ran, so the stored correction had nothing to act on.
        let d = dayWithStillSpan(hr: nil)
        try XCTSkipUnless(AnalyticsEngine.dayString(d.spanStart - 3 * 3600) == AnalyticsEngine.dayString(d.spanStart + 3600),
                          "fixture night and still span fall on different local days in this time zone")
        let plain = analyze(d, corrections: [])
        let nap = SleepCorrection(action: .markNap, start: d.spanStart, end: d.spanStart + 3600, createdAt: 1)
        let r = analyze(d, corrections: [nap])                       // what a version re-score runs with the stored row
        let s = try XCTUnwrap(overlapping(r, d.spanStart))
        XCTAssertEqual(s.kind, .nap)
        XCTAssertTrue(s.userCorrected)
        XCTAssertEqual(r.napSessions.count, 1)
        XCTAssertEqual(r.cachedSleep.filter { $0.kind == "nap" }.count, 1)
        // Nothing is invented for it: no heart rate, HRV or stage estimate.
        let e = try XCTUnwrap(r.napSessions.first)
        XCTAssertNil(e.restingHR); XCTAssertNil(e.avgHRV)
        XCTAssertFalse(e.stages.contains { $0.state.isStaged })
        // Main sleep, and everything recovery reads from it, is unchanged.
        XCTAssertEqual(r.daily.totalSleepMin, plain.daily.totalSleepMin)
        XCTAssertEqual(r.daily.restingHr, plain.daily.restingHr)
        XCTAssertEqual(r.daily.avgHrv, plain.daily.avgHrv)
        XCTAssertEqual(r.recovery, plain.recovery)
        XCTAssertEqual(r.sleepSessions.map(\.start), plain.sleepSessions.map(\.start))
        // The confirmed nap now counts as sleep for the day and is excluded from load.
        let before = try XCTUnwrap(plain.load?.sleepExcludedS), after = try XCTUnwrap(r.load?.sleepExcludedS)
        XCTAssertEqual(Double(after - before), 3600, accuracy: 15 * 60)
        XCTAssertGreaterThan(s.asleepSeconds, 30 * 60)

        // confirm and markPrimary act on it too; reject removes it.
        XCTAssertEqual(overlapping(analyze(d, corrections: [SleepCorrection(action: .confirm, start: d.spanStart, end: d.spanStart + 3600, createdAt: 1)]), d.spanStart)?.kind, .nap)
        XCTAssertEqual(overlapping(analyze(d, corrections: [SleepCorrection(action: .markPrimary, start: d.spanStart, end: d.spanStart + 3600, createdAt: 1)]), d.spanStart)?.isPrimary, true)
        XCTAssertNil(overlapping(analyze(d, corrections: [SleepCorrection(action: .reject, start: d.spanStart, end: d.spanStart + 3600, createdAt: 1)]), d.spanStart))
    }

    func testLowEvidenceSpanNeverJoinsRealSleep() {
        // 20 min after a real night: close enough to join any other episode, but not one without evidence.
        let night = SleepSession(start: 0, end: 7 * 3600, efficiency: 0.95, stages: [StageSegment(start: 0, end: 7 * 3600, stage: "light")],
                                 restingHR: 52, avgHRV: 50)
        let weak = SleepSession(start: 7 * 3600 + 1200, end: 8 * 3600 + 1200, efficiency: 1,
                                stages: [StageSegment(start: 7 * 3600 + 1200, end: 8 * 3600 + 1200, stage: "asleep", reason: SleepStateReason.noCardiacData)],
                                restingHR: nil, avgHRV: nil, kind: .nap, lowEvidence: true)
        let c = SleepSessionClassifier.classify([night, weak], habit: .fallback, wakeDay: { _ in "d" })
        XCTAssertEqual(c.map(\.kind), [.primary, .uncertain])
        XCTAssertEqual(c.first?.episodes.count, 1)
        // Without the flag the same pair is one interrupted night.
        let plain = SleepSession(start: weak.start, end: weak.end, efficiency: 1, stages: weak.stages, restingHR: nil, avgHRV: nil, kind: .nap)
        XCTAssertEqual(SleepSessionClassifier.classify([night, plain], habit: .fallback, wakeDay: { _ in "d" }).map(\.kind), [.interruptedPrimary])
    }

    func testNapRulesArePartOfTheAlgorithmKey() {
        let key = IncrementalScorer.algorithmKey(scoringVersion: 5, generation: 0)
        XCTAssertTrue(key.contains(SleepStager.napDetectionVersion))
        XCTAssertTrue(key.contains(SleepSessionClassifier.version))
    }

    func testHRMinuteCoverage() {
        let hr = (0..<30).map { HRSample(ts: 1_000 + $0 * 60, bpm: 60) }
        XCTAssertEqual(SleepStager.hrMinuteCoverage(hr, start: 1_000, end: 1_000 + 60 * 60), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SleepStager.hrMinuteCoverage([], start: 0, end: 3600), 0)
    }
}
