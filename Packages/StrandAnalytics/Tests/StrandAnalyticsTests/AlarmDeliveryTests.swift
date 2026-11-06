import XCTest
@testable import StrandAnalytics

/// The early-delivery transaction: serialized SET → RUN, correlated answers and events, timeouts, disconnects.
final class AlarmDeliveryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_700_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func tx() -> AlarmDeliveryTransaction { AlarmDeliveryTransaction(id: "x", occurrenceId: "a@1", early: true, setSeq: 10, setSentAt: t0) }

    func testRunOnlyAfterSetSucceedsAndStrapReportSettles() {
        var d = tx()
        // RUN is never requested before SET's final answer; a PENDING changes nothing.
        XCTAssertEqual(d.handle(command: .set, seq: 10, answer: .pending, at: at(0.1)), [])
        XCTAssertEqual(d.handle(command: .set, seq: 10, answer: .success, at: at(0.2)), [.acknowledged(.set), .sendRun])
        d.runSent(seq: 11, at: at(0.3))
        XCTAssertEqual(d.handle(command: .run, seq: 11, answer: .success, at: at(0.5)), [.acknowledged(.run)])
        XCTAssertNil(d.outcome)   // an acknowledged command is not a vibration
        let a = d.handle(signal: .hapticsFired, at: at(1))
        XCTAssertEqual(a, [.strapSignal(.hapticsFired, at: at(1)), .settled(.strapReported)])
        // A second copy of the confirmation does not settle twice.
        XCTAssertEqual(d.handle(signal: .appAlarmExecuted, at: at(1.2)), [.strapSignal(.appAlarmExecuted, at: at(1.2))])
        // Dismissed by double tap → user terminated.
        XCTAssertEqual(d.handle(signal: .doubleTap, at: at(15)), [.strapSignal(.doubleTap, at: at(15))])
        XCTAssertEqual(d.handle(signal: .hapticsTerminated(reason: 2), at: at(16)),
                       [.strapSignal(.hapticsTerminated(reason: 2), at: at(16)), .dismissed(source: "strap", at: at(16))])
        XCTAssertFalse(d.isOpen)
    }

    func testAnswersForOtherSequenceNumbersOrCommandsAreIgnored() {
        var d = tx()
        XCTAssertEqual(d.handle(command: .set, seq: 9, answer: .success, at: at(1)), [])     // the deadline arm's SET
        XCTAssertEqual(d.handle(command: .run, seq: 10, answer: .success, at: at(1)), [])
        XCTAssertEqual(d.step, .awaitingSet)
    }

    func testRejectedSetFailsWithoutRun() {
        var d = tx()
        let a = d.handle(command: .set, seq: 10, answer: .rejected("INVALID_ALARM_TIME"), at: at(1))
        XCTAssertEqual(a.last, .settled(.failed("Strap refused the alarm time (INVALID_ALARM_TIME)")))
        XCTAssertFalse(a.contains(.sendRun))
    }

    func testTimeoutsAndDisconnect() {
        var d = tx()
        XCTAssertEqual(d.tick(now: at(5)), [])
        XCTAssertEqual(d.tick(now: at(11)).first, .timedOut(.set))
        var e = tx()
        _ = e.handle(command: .set, seq: 10, answer: .success, at: at(1)); e.runSent(seq: 11, at: at(1))
        if case .settled(.failed)? = e.linkDropped().last {} else { XCTFail("disconnect must fail delivery") }
    }

    /// RUN acknowledged but no haptics event → unconfirmed; a late HAPTICS_FIRED (delayed notification) is still matched
    /// and recorded, without settling a second time.
    func testUnconfirmedThenLateHaptics() {
        var d = tx()
        _ = d.handle(command: .set, seq: 10, answer: .success, at: at(1)); d.runSent(seq: 11, at: at(1))
        _ = d.handle(command: .run, seq: 11, answer: .success, at: at(2))
        guard case .settled(.unconfirmed)? = d.tick(now: at(32)).last else { return XCTFail("expected unconfirmed") }
        XCTAssertEqual(d.handle(signal: .hapticsFired, at: at(35)), [.strapSignal(.hapticsFired, at: at(35))])
    }

    /// Haptics far from the RUN (e.g. an old event, or the strap's own stored alarm) is not this delivery's.
    func testUnrelatedEventsStayUnmatched() {
        var d = tx()
        XCTAssertNil(d.handle(signal: .hapticsFired, at: at(0)))   // RUN not sent yet
        _ = d.handle(command: .set, seq: 10, answer: .success, at: at(1)); d.runSent(seq: 11, at: at(1))
        XCTAssertNil(d.handle(signal: .hapticsFired, at: at(-3600)))
        XCTAssertNil(d.handle(signal: .strapAlarmExecuted, at: at(2)))
        XCTAssertNil(d.handle(signal: .doubleTap, at: at(3)))       // no vibration reported yet: not a dismissal
    }
}
