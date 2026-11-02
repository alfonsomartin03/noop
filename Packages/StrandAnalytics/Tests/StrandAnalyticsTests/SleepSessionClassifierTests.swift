import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Scenario tests for layers C/D (grouping + labels). Episodes are synthetic and fully asleep unless stated, in a
/// fixed zone so clock-time rules are deterministic.
final class SleepSessionClassifierTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// Unix time for 2026-10-<day> hh:mm New York.
    func t(_ day: Int, _ h: Int, _ m: Int = 0, month: Int = 10) -> Int {
        Int(cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!.timeIntervalSince1970)
    }

    func ep(_ s: Int, _ e: Int, awakeInside: [(Int, Int)] = [], provisional: Bool = false) -> SleepSession {
        var stages: [StageSegment] = []
        var cur = s
        for (a, b) in awakeInside {
            stages.append(StageSegment(start: cur, end: a, stage: "light"))
            stages.append(StageSegment(start: a, end: b, stage: "wake"))
            cur = b
        }
        stages.append(StageSegment(start: cur, end: e, stage: "light"))
        return SleepSession(start: s, end: e, efficiency: 0.9, stages: stages, restingHR: 55, avgHRV: 60,
                            kind: .main, isProvisional: provisional)
    }

    func classify(_ eps: [SleepSession], habit: SleepHabit = .fallback, corrections: [SleepCorrection] = []) -> [ClassifiedSleepSession] {
        SleepSessionClassifier.classify(eps, habit: habit, corrections: corrections, calendar: cal)
    }

    // MARK: basic

    func testNormalNight() {
        let s = classify([ep(t(10, 23), t(11, 7))])
        XCTAssertEqual(s.map(\.kind), [.primary])
    }

    func testShortAfternoonNapBesideNight() {
        let s = classify([ep(t(10, 23), t(11, 7)), ep(t(11, 14), t(11, 14, 40))])
        XCTAssertEqual(s.map(\.kind), [.primary, .nap])
    }

    func testTwentyMinuteNapStaysUncertain() {
        // A single 20-min episode: below the confident-episode length, so it waits for the user.
        let s = classify([ep(t(10, 23), t(11, 7)), ep(t(11, 15), t(11, 15, 22))])
        XCTAssertEqual(s.last?.kind, .uncertain)
    }

    func testLongAfternoonNapIsNotPrimaryWhenNightExists() {
        let s = classify([ep(t(10, 23, 30), t(11, 6, 30)), ep(t(11, 13), t(11, 15, 30))])
        XCTAssertEqual(s.map(\.kind), [.primary, .nap])
    }

    // MARK: interrupted nights

    func testBriefAwakeningStaysOneSessionWithGapKept() {
        let s = classify([ep(t(10, 23), t(11, 3)), ep(t(11, 3, 20), t(11, 7))])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].kind, .interruptedPrimary)
        XCTAssertEqual(s[0].gaps.count, 1)
        XCTAssertEqual(s[0].gaps[0].end - s[0].gaps[0].start, 20 * 60)
    }

    func testSeventyFiveMinuteNightAwakeningIsNotANap() {
        let s = classify([ep(t(10, 23), t(11, 2)), ep(t(11, 3, 15), t(11, 7, 30))])
        XCTAssertEqual(s.map(\.kind), [.interruptedPrimary])
    }

    func testWakeAtFiveBackToSleepAtSeven() {
        // 2-h morning wake inside the habitual window: one interrupted night, not a night plus a nap.
        let s = classify([ep(t(10, 23), t(11, 5)), ep(t(11, 7), t(11, 8, 30))])
        XCTAssertEqual(s.map(\.kind), [.interruptedPrimary])
        XCTAssertEqual(s[0].episodes.count, 2)
    }

    func testMultipleAwakenings() {
        let s = classify([ep(t(10, 23), t(11, 1)), ep(t(11, 1, 30), t(11, 3)), ep(t(11, 3, 40), t(11, 6, 50))])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].gaps.count, 2)
    }

    // MARK: schedules

    func testNightShiftDaySleepIsPrimary() {
        // Learned habit: sleeps 08:30–15:30. A 7-h day sleep is the main sleep; a 1-h evening sleep is a nap.
        let habit = SleepHabit(midpointMinute: 12 * 60, typicalMinutes: 420, nights: 14)
        let s = classify([ep(t(11, 8, 30), t(11, 15, 30)), ep(t(11, 19), t(11, 20))], habit: habit)
        XCTAssertEqual(s.map(\.kind), [.primary, .nap])
    }

    func testLongDaySleepWithoutNightIsPrimary() {
        // No night at all; a 6-h daytime sleep is the primary even with a nighttime habit.
        let s = classify([ep(t(11, 9), t(11, 15))])
        XCTAssertEqual(s.map(\.kind), [.primary])
    }

    func testShortNightSleepCanBeANap() {
        // A 1-h sleep at 22:00 followed by the real night after a 3-h awake gap: the short one is a nap.
        let s = classify([ep(t(10, 20), t(10, 21)), ep(t(11, 0, 30), t(11, 8))])
        XCTAssertEqual(s.map(\.kind), [.nap, .primary])
    }

    func testSplitSleepBiphasic() {
        // 4 h + 3 h with a 3.5-h awake middle: too long to join; the bigger, better-aligned part is primary.
        let s = classify([ep(t(10, 21), t(11, 1)), ep(t(11, 4, 30), t(11, 7, 30))])
        XCTAssertEqual(s.filter(\.isPrimary).count, 1)
        XCTAssertEqual(s.count, 2)
    }

    func testTwoNightsInOneWindowKeepTwoPrimaries() {
        let s = classify([ep(t(10, 23), t(11, 7)), ep(t(11, 23), t(12, 7))])
        XCTAssertEqual(s.map(\.kind), [.primary, .primary])
    }

    func testDSTFallBackNight() {
        // 2026-11-01: clocks fall back at 02:00 in New York. The 9-h elapsed night is still one primary.
        let s = classify([ep(t(31, 23), t(1, 7, month: 11))])
        XCTAssertEqual(s.map(\.kind), [.primary])
        XCTAssertEqual(s[0].asleepSeconds, 9 * 3600)
    }

    func testTravelShiftedNightStillPrimary() {
        // Home habit 03:30 midpoint; a night 6 h shifted by travel still has the most sleep → primary.
        let s = classify([ep(t(11, 5), t(11, 12, 30)), ep(t(11, 17), t(11, 17, 45))])
        XCTAssertEqual(s.map(\.kind), [.primary, .nap])
    }

    func testProvisionalSessionHasLowerConfidence() {
        let s = classify([ep(t(10, 23), t(11, 7), provisional: true)])
        XCTAssertEqual(s[0].kind, .primary)
        XCTAssertLessThanOrEqual(s[0].confidence, 0.5)
    }

    func testOffWristGapInsideNightIsNotSleep() {
        // An episode boundary from missing data: two parts 40 min apart join, but the gap is not counted as sleep.
        let s = classify([ep(t(10, 23), t(11, 2)), ep(t(11, 2, 40), t(11, 7))])
        XCTAssertEqual(s[0].asleepSeconds, (3 * 60 + 4 * 60 + 20) * 60)
    }

    // MARK: corrections

    func testUserMarksNapAsPrimaryAndOnlyOnePrimaryRemains() {
        let night = ep(t(10, 23), t(11, 7)), nap = ep(t(11, 14), t(11, 15))
        let c = SleepCorrection(action: .markPrimary, start: nap.start, end: nap.end, createdAt: 1)
        let s = classify([night, nap], corrections: [c])
        XCTAssertEqual(s.map(\.kind), [.nap, .primary])
        XCTAssertTrue(s[1].userCorrected)
    }

    func testCorrectionSurvivesLateDataExtendingTheSession() {
        let c = SleepCorrection(action: .markNap, start: t(11, 14), end: t(11, 15), createdAt: 1)
        // Later sync extends the episode by 10 min; the overlap match still applies the user's label.
        let s = classify([ep(t(10, 23), t(11, 7)), ep(t(11, 14), t(11, 15, 10))], corrections: [c])
        XCTAssertEqual(s.last?.kind, .nap)
        XCTAssertTrue(s.last?.userCorrected ?? false)
    }

    func testRejectQuietRest() {
        let rest = ep(t(11, 13), t(11, 13, 50))
        let c = SleepCorrection(action: .reject, start: rest.start, end: rest.end, createdAt: 1)
        let s = classify([ep(t(10, 23), t(11, 7)), rest], corrections: [c])
        XCTAssertEqual(s.count, 1)
    }

    func testMergeAndSplit() {
        let a = ep(t(10, 21), t(11, 1)), b = ep(t(11, 4, 30), t(11, 7, 30))
        let merged = classify([a, b], corrections: [SleepCorrection(action: .merge, start: a.start, end: b.end, createdAt: 1)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].kind, .interruptedPrimary)
        let x = ep(t(10, 23), t(11, 3)), y = ep(t(11, 3, 20), t(11, 7))
        let split = classify([x, y], corrections: [SleepCorrection(action: .split, start: x.start, end: y.end, at: t(11, 3, 10), createdAt: 1)])
        XCTAssertEqual(split.count, 2)
    }

    func testAdjustBoundsClipsSleepWithoutRewritingEpisodes() {
        let night = ep(t(10, 23), t(11, 7))
        let c = SleepCorrection(action: .adjust, start: night.start, end: night.end, newStart: t(10, 23, 30), newEnd: t(11, 7), createdAt: 1)
        let s = classify([night], corrections: [c])
        XCTAssertEqual(s[0].asleepSeconds, 7 * 3600 + 30 * 60)
        XCTAssertEqual(s[0].episodes[0].start, night.start)   // raw episode untouched
    }

    func testConfirmUncertainBecomesNap() {
        let short = ep(t(11, 15), t(11, 15, 22))
        let c = SleepCorrection(action: .confirm, start: short.start, end: short.end, createdAt: 1)
        let s = classify([ep(t(10, 23), t(11, 7)), short], corrections: [c])
        XCTAssertEqual(s.last?.kind, .nap)
    }

    // MARK: habit

    func testHabitLearnsNightShift() {
        let prim = (1...7).map { d in (start: t(d, 8), end: t(d, 15)) }
        let h = SleepHabit.learn(primaries: prim, calendar: cal)
        XCTAssertEqual(h.midpointMinute, 11 * 60 + 30, accuracy: 5)
        XCTAssertEqual(h.typicalMinutes, 420)
    }

    func testHabitAcrossMidnightCircularMean() {
        let prim = [(t(1, 23), t(2, 7)), (t(3, 0), t(3, 8)), (t(3, 22, 30), t(4, 6, 30))].map { (start: $0.0, end: $0.1) }
        let h = SleepHabit.learn(primaries: prim, calendar: cal)
        XCTAssertEqual(h.midpointMinute, 3 * 60, accuracy: 20)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b)", file: file, line: line)
}
