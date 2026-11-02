import XCTest
@testable import StrandAnalytics

/// Alarm scheduling and smart-wake decisions on a simulated clock (no BLE, no timers).
final class AlarmEngineTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    func d(_ month: Int, _ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }

    // MARK: scheduling

    func testExactNextOccurrenceToday() {
        let a = AlarmSpec(hour: 7, minute: 0)
        let o = AlarmPlanner.next(a, after: d(11, 2, 6), calendar: cal)
        XCTAssertEqual(o?.deadline, d(11, 2, 7))
        XCTAssertEqual(o?.windowStart, o?.deadline)
    }

    func testRollsToTomorrowAfterTime() {
        let o = AlarmPlanner.next(AlarmSpec(hour: 7, minute: 0), after: d(11, 2, 7, 1), calendar: cal)
        XCTAssertEqual(o?.deadline, d(11, 3, 7))
    }

    func testWeekdaysOnly() {
        // 2026-11-07 is a Saturday; weekdays Mon–Fri (2…6) → next is Monday 11-09.
        let a = AlarmSpec(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6])
        XCTAssertEqual(AlarmPlanner.next(a, after: d(11, 7, 8), calendar: cal)?.deadline, d(11, 9, 7))
    }

    func testSmartWindowStart() {
        let a = AlarmSpec(hour: 7, minute: 0, mode: .smart(windowMin: 30))
        XCTAssertEqual(AlarmPlanner.next(a, after: d(11, 2, 1), calendar: cal)?.windowStart, d(11, 2, 6, 30))
    }

    func testDSTFallBackRingsOnce() {
        // 2026-11-01 01:30 happens twice in New York; the alarm rings the first time only.
        let a = AlarmSpec(hour: 1, minute: 30)
        let first = AlarmPlanner.next(a, after: d(10, 31, 23), calendar: cal)!
        let second = AlarmPlanner.next(a, after: first.deadline, calendar: cal)!
        XCTAssertEqual(second.deadline.timeIntervalSince(first.deadline), 25 * 3600)   // next day, not an hour later
    }

    func testDSTSpringForwardSkippedTime() {
        // 2027-03-14 02:30 does not exist in New York; the alarm rings at the next valid time, not never.
        let a = AlarmSpec(hour: 2, minute: 30)
        let after = cal.date(from: DateComponents(year: 2027, month: 3, day: 14, hour: 0))!
        let o = AlarmPlanner.next(a, after: after, calendar: cal)!
        XCTAssertLessThan(o.deadline.timeIntervalSince(after), 4 * 3600)
    }

    func testDisabledAndMultipleAlarms() {
        let off = AlarmSpec(hour: 5, minute: 0, enabled: false)
        let late = AlarmSpec(hour: 8, minute: 0), early = AlarmSpec(hour: 6, minute: 45)
        XCTAssertNil(AlarmPlanner.next(off, after: d(11, 2, 1), calendar: cal))
        XCTAssertEqual(AlarmPlanner.nextAcross([off, late, early], after: d(11, 2, 1), calendar: cal)?.alarmId, early.id)
    }

    // MARK: smart wake

    func occ(_ mode: AlarmSpec.Mode) -> AlarmOccurrence {
        AlarmPlanner.next(AlarmSpec(hour: 7, minute: 0, mode: mode), after: d(11, 2, 1), calendar: cal)!
    }
    func ev(_ t: Date, _ p: Double, usable: Bool = true) -> WakeEvidence { WakeEvidence(at: t, wakeLikelihood: p, usable: usable) }

    func testNoEarlyFireBeforeWindow() {
        var s = SmartWakeDecider(occurrence: occ(.smart(windowMin: 30)), mode: .smart(windowMin: 30))
        for m in 0..<10 { XCTAssertEqual(s.step(now: d(11, 2, 6, m), evidence: ev(d(11, 2, 6, m), 1)), .wait) }
    }

    func testStableLightnessFiresEarlyOnce() {
        var s = SmartWakeDecider(occurrence: occ(.smart(windowMin: 30)), mode: .smart(windowMin: 30))
        XCTAssertEqual(s.step(now: d(11, 2, 6, 35), evidence: ev(d(11, 2, 6, 35), 0.8)), .wait)
        XCTAssertEqual(s.step(now: d(11, 2, 6, 36), evidence: ev(d(11, 2, 6, 36), 0.7)), .wait)
        guard case .fireEarly = s.step(now: d(11, 2, 6, 37), evidence: ev(d(11, 2, 6, 37), 0.9)) else { return XCTFail("no fire") }
        XCTAssertEqual(s.step(now: d(11, 2, 7), evidence: nil), .wait)   // never twice (no duplicate execution)
    }

    func testSingleNoisyMinuteDoesNotFire() {
        var s = SmartWakeDecider(occurrence: occ(.smart(windowMin: 30)), mode: .smart(windowMin: 30))
        let seq = [0.9, 0.2, 0.9, 0.1, 0.95, 0.3]
        for (i, p) in seq.enumerated() {
            XCTAssertEqual(s.step(now: d(11, 2, 6, 40 + i), evidence: ev(d(11, 2, 6, 40 + i), p)), .wait)
        }
    }

    func testNoLightOpportunityFallsBackToDeadline() {
        var s = SmartWakeDecider(occurrence: occ(.smart(windowMin: 30)), mode: .smart(windowMin: 30))
        for m in 30..<60 { _ = s.step(now: d(11, 2, 6, m), evidence: ev(d(11, 2, 6, m), 0.1)) }
        XCTAssertEqual(s.step(now: d(11, 2, 7), evidence: nil), .fireAtDeadline)
    }

    func testMissingDataNeverFiresEarlyButDeadlineHolds() {
        var s = SmartWakeDecider(occurrence: occ(.smart(windowMin: 30)), mode: .smart(windowMin: 30))
        for m in 30..<60 { XCTAssertEqual(s.step(now: d(11, 2, 6, m), evidence: ev(d(11, 2, 6, m), 1, usable: false)), .wait) }
        XCTAssertEqual(s.step(now: d(11, 2, 7, 3), evidence: nil), .fireAtDeadline)   // late tick (host was busy) still fires
    }

    func testSleepGoalFiresWhenReached() {
        let mode = AlarmSpec.Mode.sleepGoal(goalPercent: 85, windowMin: 30)
        var s = SmartWakeDecider(occurrence: occ(mode), mode: mode)
        XCTAssertEqual(s.step(now: d(11, 2, 6, 35), evidence: ev(d(11, 2, 6, 35), 0.1), asleepMinutesSoFar: 350, needMinutes: 480), .wait)
        guard case .fireEarly = s.step(now: d(11, 2, 6, 40), evidence: ev(d(11, 2, 6, 40), 0.8),
                                        asleepMinutesSoFar: 410, needMinutes: 480) else { return XCTFail("goal not honoured") }
    }

    func testSleepGoalGraceThenFire() {
        let mode = AlarmSpec.Mode.sleepGoal(goalPercent: 70, windowMin: 30)
        var s = SmartWakeDecider(occurrence: occ(mode), mode: mode)
        XCTAssertEqual(s.step(now: d(11, 2, 6, 31), evidence: ev(d(11, 2, 6, 31), 0.1), asleepMinutesSoFar: 400, needMinutes: 480), .wait)
        guard case .fireEarly = s.step(now: d(11, 2, 6, 41), evidence: ev(d(11, 2, 6, 41), 0.1),
                                        asleepMinutesSoFar: 410, needMinutes: 480) else { return XCTFail("grace not applied") }
    }

    func testExactModeOnlyDeadline() {
        var s = SmartWakeDecider(occurrence: occ(.exact), mode: .exact)
        XCTAssertEqual(s.step(now: d(11, 2, 6, 59), evidence: ev(d(11, 2, 6, 59), 1)), .wait)
        XCTAssertEqual(s.step(now: d(11, 2, 7), evidence: nil), .fireAtDeadline)
    }

    // MARK: evidence + states

    func testWakeEvidenceHeuristic() {
        XCTAssertFalse(WakeEvidence.estimate(at: Date(), moveFraction: nil, hrRatio: nil).usable)
        XCTAssertEqual(WakeEvidence.estimate(at: Date(), moveFraction: 0.4, hrRatio: 1.25).wakeLikelihood, 1, accuracy: 1e-9)
        XCTAssertEqual(WakeEvidence.estimate(at: Date(), moveFraction: 0, hrRatio: 1.0).wakeLikelihood, 0, accuracy: 1e-9)
        XCTAssertEqual(WakeEvidence.estimate(at: Date(), moveFraction: nil, hrRatio: 1.125).wakeLikelihood, 0.5, accuracy: 1e-9)
    }

    func testStateMachineRejectsMisleadingJumps() {
        XCTAssertFalse(AlarmStateMachine.canMove(from: .draft, to: .confirmedOnDevice))      // never "on strap" without sync
        XCTAssertFalse(AlarmStateMachine.canMove(from: .pendingSync, to: .triggered))
        XCTAssertTrue(AlarmStateMachine.canMove(from: .pendingSync, to: .confirmedOnDevice))
        XCTAssertTrue(AlarmStateMachine.canMove(from: .pendingSync, to: .failed))
        XCTAssertTrue(AlarmStateMachine.canMove(from: .triggered, to: .dismissed))
        XCTAssertFalse(AlarmStateMachine.canMove(from: .canceled, to: .triggered))
    }
}
