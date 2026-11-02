import XCTest
@testable import WhoopProtocol

final class DeviceClockTests: XCTestCase {
    func testOffsetFromMidpoint() {
        var e = DeviceClockEstimator()
        // E04-like: strap 18 s behind, 200 ms round trip.
        guard case .accepted(let c) = e.add(ClockSample(hostSent: 1000.0, hostReceived: 1000.2, device: 982.1)) else {
            return XCTFail("rejected")
        }
        XCTAssertEqual(c.offset, 18.0, accuracy: 1e-9)
        XCTAssertEqual(c.uncertainty, 0.6, accuracy: 1e-9)
        XCTAssertEqual(c.hostTime(fromDevice: 2000), 2018)
        XCTAssertEqual(c.deviceTime(fromHost: 2018), 2000)
    }

    func testSlowFirstReplyRejected() {
        var e = DeviceClockEstimator()
        // The first command after attach waited 5.7 s: too vague to trust.
        XCTAssertEqual(e.add(ClockSample(hostSent: 0, hostReceived: 5.7, device: 0)), .rejected(.roundTripTooLong(5.7)))
        XCTAssertNil(e.current)
    }

    func testImplausibleAndNegative() {
        var e = DeviceClockEstimator()
        XCTAssertEqual(e.add(ClockSample(hostSent: 10, hostReceived: 9, device: 0)), .rejected(.negativeRoundTrip))
        guard case .rejected(.implausibleOffset) = e.add(ClockSample(hostSent: 2e9, hostReceived: 2e9, device: 1e9)) else {
            return XCTFail("RTC reset accepted")
        }
    }

    func testJumpDetected() {
        var e = DeviceClockEstimator()
        _ = e.add(ClockSample(hostSent: 0, hostReceived: 0.1, device: -15))
        XCTAssertEqual(e.current?.offset ?? 0, 15.05, accuracy: 1e-9)
        guard case .accepted = e.add(ClockSample(hostSent: 100, hostReceived: 100.1, device: 84)) else { return XCTFail("drift flagged") }
        guard case .jumped = e.add(ClockSample(hostSent: 200, hostReceived: 200.1, device: 200)) else { return XCTFail("jump missed") }
        XCTAssertEqual(e.current?.offset ?? 99, 0.05, accuracy: 1e-9)
    }
}

final class RedactionTests: XCTestCase {
    func testConsoleAddressMasked() {
        let line = "20, 2846850529: Address          = 47:B4:06:30:06:3C"
        XCTAssertEqual(Redactor.redact(line), "20, 2846850529: Address          = <addr>")
    }

    func testPeripheralUUIDMaskedButGATTKept() {
        let s = "peripheral 1E2D3C4B-5A69-7887-96A5-B4C3D2E1F001 char FD4B0003-CCE1-4033-93CE-002D5875F58A"
        XCTAssertEqual(Redactor.redact(s), "peripheral <uuid> char FD4B0003-CCE1-4033-93CE-002D5875F58A")
    }

    func testRegisteredSerialAndDeviceName() {
        Redactor.register(secret: "4C0123456789")
        XCTAssertEqual(Redactor.redact("serial=4C0123456789 name=WHOOP 4C0123456789"), "serial=<redacted> name=WHOOP <redacted>")
        XCTAssertEqual(Redactor.redact("Discovered WHOOP 5A1B2C3D rssi -60"), "Discovered WHOOP-<id> rssi -60")
    }

    func testOrdinaryTextUntouched() {
        let s = "RX 5.0 cmd-response to=34 originSeq=4 result=1 len=84 crc=true; firmware 50.43.1.0"
        XCTAssertEqual(Redactor.redact(s), s)
    }
}

final class SyncSessionTests: XCTestCase {
    func testProgressFollowsSavedFrontier() {
        var s = SyncSession(localFrom: 1000, strapFrom: 1000, target: 4600)   // 1 h to fetch
        s.begin()
        XCTAssertEqual(s.fraction, 0)
        s.chunkSaved(recordTimes: Array(1000..<1900), newRows: 900)
        XCTAssertEqual(s.accountedSeconds, 899)
        XCTAssertEqual(s.fraction, 899.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.remainingSeconds, 3600 - 899)
    }

    func testDuplicateChunkDoesNotRegressOrDoubleCount() {
        var s = SyncSession(localFrom: nil, strapFrom: 0, target: 1000)
        s.chunkSaved(recordTimes: Array(0..<500), newRows: 500)
        let before = s.fraction
        s.chunkSaved(recordTimes: Array(0..<500), newRows: 0)      // strap re-sent an un-acked chunk
        XCTAssertEqual(s.fraction, before)
        XCTAssertEqual(s.savedRecords, 500)
        XCTAssertEqual(s.duplicateRecords, 500)
    }

    func testOutOfOrderChunkNeverMovesFrontierBack() {
        var s = SyncSession(localFrom: nil, strapFrom: 0, target: 1000)
        s.chunkSaved(recordTimes: Array(600..<700), newRows: 100)
        s.chunkSaved(recordTimes: Array(100..<200), newRows: 100)
        XCTAssertEqual(s.accountedSeconds, 699)
    }

    func testNeverHundredPercentBeforeCompletion() {
        var s = SyncSession(localFrom: nil, strapFrom: 0, target: 100)
        s.chunkSaved(recordTimes: Array(0...100), newRows: 101)
        XCTAssertEqual(s.fraction, 0.99)
        s.downloadFinished()
        XCTAssertEqual(s.phase, .processing)
        XCTAssertEqual(s.fraction, 1)
        s.processingFinished()
        XCTAssertEqual(s.phase, .complete)
    }

    func testTargetIsFixedForTheSession() {
        var s = SyncSession(localFrom: nil, strapFrom: 0, target: 100)
        s.chunkSaved(recordTimes: Array(0...150), newRows: 151)    // records newer than the target arrive
        XCTAssertEqual(s.accountedSeconds, 100)
        XCTAssertEqual(s.target, 100)
    }

    func testUnavailableHistoryIsNotCountedAsDownloaded() {
        let s = SyncSession(localFrom: 500, strapFrom: 2000, target: 3000)
        XCTAssertEqual(s.unavailable, SyncSpan(500, 2000))
        XCTAssertEqual(s.required, SyncSpan(2000, 3000))
        XCTAssertEqual(s.fraction, 0)
    }

    func testRecordingGapsAreReportedNotHidden() {
        var s = SyncSession(localFrom: nil, strapFrom: 0, target: 4000)
        s.chunkSaved(recordTimes: Array(0..<1000) + Array(2500..<3000), newRows: 1500)
        XCTAssertEqual(s.recordingGaps(), [SyncSpan(1000, 2500)])
        XCTAssertEqual(s.accountedSeconds, 2999)   // the in-order stream accounted for the gap
    }

    func testEmptyHistoryAndInterruptedTransfer() {
        var empty = SyncSession(localFrom: 100, strapFrom: 100, target: 100)
        empty.downloadFinished()
        XCTAssertEqual(empty.fraction, 1)

        var cut = SyncSession(localFrom: nil, strapFrom: 0, target: 1000)
        cut.chunkSaved(recordTimes: Array(0..<300), newRows: 300)
        cut.end(early: "disconnected")
        XCTAssertEqual(cut.phase, .partial("disconnected"))
        cut.chunkSaved(recordTimes: Array(300..<600), newRows: 300)   // late chunk after end is ignored
        XCTAssertEqual(cut.savedRecords, 300)

        var nothing = SyncSession(localFrom: nil, strapFrom: 0, target: 1000)
        nothing.end(early: "store unavailable")
        XCTAssertEqual(nothing.phase, .failed("store unavailable"))
    }

    func testIntervalMerging() {
        var set = IntervalSet(joinGap: 1)
        set.insert(SyncSpan(0, 10)); set.insert(SyncSpan(11, 20)); set.insert(SyncSpan(5, 8)); set.insert(SyncSpan(40, 50))
        XCTAssertEqual(set.spans, [SyncSpan(0, 20), SyncSpan(40, 50)])
        XCTAssertEqual(set.covered(within: SyncSpan(0, 45)), 25)
    }
}

final class BatteryAlertPolicyTests: XCTestCase {
    let p = BatteryAlertPolicy()
    func r(_ pct: Int, charging: Bool? = nil, at: Double = 0) -> BatteryReading {
        BatteryReading(percent: pct, charging: charging, at: at, source: .standardLevel)
    }
    func eval(_ x: BatteryReading, _ s: inout BatteryAlertState, now: Double = 0, low: Bool = true, full: Bool = true) -> [BatteryAlertPolicy.Alert] {
        p.evaluate(x, now: now, state: &s, lowEnabled: low, fullEnabled: full)
    }

    func testCrossingBelowTwentyAlertsOnce() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(21), &s), [])
        XCTAssertEqual(eval(r(20), &s), [])
        XCTAssertEqual(eval(r(19), &s), [.low(percent: 19)])
        XCTAssertEqual(eval(r(18), &s), [])
        XCTAssertEqual(eval(r(19), &s), [])
    }

    func testFirstObservationBelowThreshold() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(12), &s), [.low(percent: 12)])
    }

    func testReconnectAndRestartWhileLowDoesNotRepeat() throws {
        var s = BatteryAlertState()
        _ = eval(r(15), &s)
        let saved = try JSONEncoder().encode(s)                         // app restart
        var restored = try JSONDecoder().decode(BatteryAlertState.self, from: saved)
        XCTAssertEqual(eval(r(15), &restored), [])
    }

    func testHysteresisRearms() {
        var s = BatteryAlertState()
        _ = eval(r(19), &s)
        XCTAssertEqual(eval(r(22), &s), [])     // not enough recovery
        XCTAssertEqual(eval(r(19), &s), [])
        XCTAssertEqual(eval(r(25), &s), [])     // re-armed
        XCTAssertEqual(eval(r(19), &s), [.low(percent: 19)])
    }

    func testFullOnlyWhenChargingConfirmed() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(100), &s), [])                       // unknown charging
        XCTAssertEqual(eval(r(100, charging: false), &s), [])
        XCTAssertEqual(eval(r(99, charging: true), &s), [])
        XCTAssertEqual(eval(r(100, charging: true), &s), [.full])
        XCTAssertEqual(eval(r(100, charging: true), &s), [])        // repeated 100 %
    }

    func testNewChargingSessionRearmsFull() {
        var s = BatteryAlertState()
        _ = eval(r(100, charging: true), &s)
        _ = eval(r(90, charging: false), &s)
        XCTAssertEqual(eval(r(100, charging: true), &s), [.full])
    }

    func testAlreadyFullWhenFirstConnected() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(100, charging: true), &s), [.full])
    }

    func testDisabledAlertsStillAdvanceState() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(15), &s, low: false), [])
        XCTAssertEqual(eval(r(15), &s, low: true), [])               // enabling later doesn't fire a backlog
    }

    func testStaleReadingIgnored() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(10, at: 0), &s, now: 3600), [])
        XCTAssertFalse(s.lowAlerted)
    }

    func testNoLowAlertWhileConfirmedCharging() {
        var s = BatteryAlertState()
        XCTAssertEqual(eval(r(15, charging: true), &s), [])
    }
}
