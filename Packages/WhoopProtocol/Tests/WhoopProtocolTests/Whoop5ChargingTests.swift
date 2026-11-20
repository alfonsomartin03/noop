import XCTest
@testable import WhoopProtocol

final class Whoop5ChargingTests: XCTestCase {
    func testChargingEventsAreRecognised() {
        for n in [7, 8, 21, 22] { XCTAssertTrue(Whoop5Charging.isChargingEvent(Whoop5EventKind(n)), "\(n)") }
        // Battery level and every other event say nothing about charging.
        XCTAssertFalse(Whoop5Charging.isChargingEvent(Whoop5EventKind(3)))
        XCTAssertFalse(Whoop5Charging.isChargingEvent(Whoop5EventKind(29)))
        XCTAssertEqual(Whoop5EventKind(21).name, "BATTERY_PACK_CONNECTED")
    }

    /// The real E02 reply frame (captures/E02-readonly-matrix.jsonl, seq 210) does not prove detachment.
    func testCapturedUnavailableReply() throws {
        let hex = "aa01280001002de1245697d200010000000000000000000000000000000000000000000000000000000000008caeb213"
        var bytes: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let r = try XCTUnwrap(Whoop5CommandResponse.decode(bytes))
        XCTAssertEqual(r.command, 151)
        XCTAssertEqual(r.body.count, 31)
        XCTAssertEqual(Whoop5Charging.packInfo(r), .unavailable)
    }

    func testPackInfoShapes() {
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .failure, body: [1] + Array(repeating: 0, count: 30)), .unavailable)
        // SUCCESS is not proof of attachment: its layout was never captured.
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: [1, 42, 0, 7]), .answeredUndecoded)
        // Malformed / other shapes are unrecognized, never "detached".
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .failure, body: [1] + Array(repeating: 0, count: 10)), .unrecognized)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .failure, body: [1, 9] + Array(repeating: 0, count: 29)), .unrecognized)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .pending, body: []), .unrecognized)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .unsupported, body: []), .unrecognized)
        XCTAssertNil(Whoop5Charging.packInfo(command: 26, result: .success, body: [55]))
    }

    /// Synthetic body in the C06b layout: revision, presence, 6-byte id, 16-byte serial, raw charge u16 LE, 2 opaque
    /// bytes, 3 alignment zeros (31 decoded bytes). Id and serial are made up; the real ones stay private.
    static func packBody(presence: UInt8 = 1, raw: Int = 760, padding: [UInt8] = [0, 0, 0]) -> [UInt8] {
        let id: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]
        let serial = Array("TESTPACK0001".utf8) + [UInt8](repeating: 0, count: 4)
        return [1, presence] + id + serial + [UInt8(raw & 0xFF), UInt8(raw >> 8)] + [0x0C, 0x01] + padding
    }

    func testPackInfoPayloadIsRevisionOne() {
        XCTAssertEqual(Whoop5Charging.packInfoPayload, [1])
    }

    func testPackInfoSuccessLayout() {
        XCTAssertEqual(Self.packBody().count, 31)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: Self.packBody(raw: 760)), .present(rawCharge: 760))
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: Self.packBody(raw: 418)), .present(rawCharge: 418))
        // Pack off (C06a, and C06b 3 min after removal): revision + 30 zeros, SUCCESS.
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: [1] + Array(repeating: 0, count: 30)), .absent)
        // Shapes never captured stay undecoded, never attached/detached.
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: Self.packBody(padding: [0, 7, 0])), .answeredUndecoded)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: Self.packBody(presence: 2)), .answeredUndecoded)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: [1, 0, 5] + Array(repeating: 0, count: 28)), .answeredUndecoded)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: [2] + Array(Self.packBody().dropFirst())), .answeredUndecoded)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: Array(Self.packBody().prefix(28))), .answeredUndecoded)
    }

    /// The real C06b read 3 frame (pack removed 3 min earlier; no identity bytes in it) decodes end to end as absent,
    /// and a SUCCESS response carrying the attached layout decodes as present.
    func testPackInfoFramesDecode() throws {
        let hex = "aa01280001002de1243b97c90101000000000000000000000000000000000000000000000000000000000000cce27cfa"
        var bytes: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let off = try XCTUnwrap(Whoop5CommandResponse.decode(bytes))
        XCTAssertEqual(off.command, 151)
        XCTAssertEqual(off.result, .success)
        XCTAssertEqual(Whoop5Charging.packInfo(off), .absent)
        let on = Whoop5CommandResponse(command: 151, appSeq: 201, strapSeq: 159, result: .success, body: Self.packBody(raw: 0x02F8))
        XCTAssertEqual(Whoop5Charging.packInfo(on), .present(rawCharge: 760))
    }

    func testChargerStage() {
        func ev(_ n: Int, _ body: [UInt8]) -> Whoop5Event { Whoop5Event(number: n, kind: Whoop5EventKind(n), unix: 0, subseconds: 0, body: body) }
        XCTAssertEqual(Whoop5Charging.chargerStage(ev(117, [1, 4, 0, 0])), 4)
        XCTAssertEqual(Whoop5Charging.chargerStage(ev(117, [1, 2, 0, 0])), 2)
        XCTAssertNil(Whoop5Charging.chargerStage(ev(117, [1])))
        XCTAssertNil(Whoop5Charging.chargerStage(ev(110, [1, 4, 0, 0])))
    }
}

final class ChargingModelTests: XCTestCase {
    let c = UUID()
    let t0 = Date(timeIntervalSince1970: 1_793_700_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testAttachmentIsNotCharging() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        XCTAssertEqual(m.attached(now: at(1)), .yes)
        XCTAssertEqual(m.charging(now: at(1)), .unknown)
        m.applyEvent(kind: .chargingOn, eventAt: at(5), receivedAt: at(5), connection: c)
        XCTAssertEqual(m.charging(now: at(6)), .yes)
    }

    func testFreshPercentagesDoNotRefreshAnOldChargingClaim() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        for k in 1...300 { m.applyPercent(40 + k / 10, at: at(Double(k) * 60), connection: c) }
        XCTAssertEqual(m.charging(now: at(ChargingModel.factMaxAge + 1)), .unknown)   // expired despite fresh readings
    }

    /// A pack-info reply requested before a removal event but received after it must not resurrect "attached"/override.
    func testLateReplyDoesNotOverrideNewerRemoval() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .batteryPackRemoved, eventAt: at(10), receivedAt: at(10), connection: c)
        m.applyPackInfo(.answeredUndecoded, requestedAt: at(5), receivedAt: at(12), connection: c)
        XCTAssertEqual(m.attached(now: at(13)), .no)
        // An older event delivered late is ignored too.
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(8), receivedAt: at(14), connection: c)
        XCTAssertEqual(m.attached(now: at(15)), .no)
        XCTAssertEqual(m.charging(now: at(15)), .no)
    }

    /// Explicit removal changes state; failed polls must not impersonate this event.
    func testRemovalEventAndReattachment() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .batteryPackRemoved, eventAt: at(60), receivedAt: at(60.1), connection: c)
        XCTAssertEqual(m.attached(now: at(61)), .no)
        XCTAssertEqual(m.charging(now: at(61)), .no)
        m.applyPackInfo(.unrecognized, requestedAt: at(120), receivedAt: at(120), connection: c)
        XCTAssertEqual(m.attached(now: at(121)), .no)   // malformed reply changes nothing
        // Re-attached: "not charging" inferred from detachment no longer holds; a real CHARGING_OFF does.
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(200), receivedAt: at(200), connection: c)
        XCTAssertEqual(m.charging(now: at(201)), .unknown)
        m.applyEvent(kind: .chargingOff, eventAt: at(210), receivedAt: at(210), connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(220), receivedAt: at(220), connection: c)
        XCTAssertEqual(m.charging(now: at(221)), .no)
    }

    func testFailedPollsPreserveChargingWhileBatteryRises() throws {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        let reply = try XCTUnwrap(Whoop5Charging.packInfo(command: 151, result: .failure,
                                                       body: [1] + Array(repeating: 0, count: 30)))
        for minute in 1...30 {
            let time = at(Double(minute) * 60)
            m.applyPackInfo(reply, requestedAt: time, receivedAt: time, connection: c)
            m.applyPercent(40 + minute, at: time, connection: c)
            XCTAssertEqual(m.attached(now: time), .yes)
            XCTAssertEqual(m.charging(now: time), .yes)
        }
        XCTAssertEqual(m.attachmentEvidence(now: at(1800))?.receivedAt, at(0))
        XCTAssertEqual(m.chargingEvidence(now: at(1800))?.receivedAt, at(0))
        m.applyEvent(kind: .batteryPackRemoved, eventAt: at(1801), receivedAt: at(1801), connection: c)
        XCTAssertEqual(m.attached(now: at(1802)), .no)
        XCTAssertEqual(m.charging(now: at(1802)), .no)
    }

    func testFailedPollWithoutEventsLeavesStateUnknownAndAllowsLikely() {
        var m = ChargingModel(connection: c)
        for (k, pct) in [40, 41, 42, 43].enumerated() {
            let time = at(Double(k) * 240)
            m.applyPackInfo(.unavailable, requestedAt: time, receivedAt: time, connection: c)
            m.applyPercent(pct, at: time, connection: c)
        }
        XCTAssertEqual(m.attached(now: at(721)), .unknown)
        XCTAssertEqual(m.charging(now: at(721)), .unknown)
        XCTAssertTrue(m.chargingLikely(now: at(721)))
    }

    func testReconnectDoesNotResurrectState() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        let c2 = UUID()
        m.reset(connection: c2)
        XCTAssertEqual(m.charging(now: at(1)), .unknown)
        m.applyEvent(kind: .chargingOn, eventAt: at(2), receivedAt: at(2), connection: c)   // a late callback from the old link
        XCTAssertEqual(m.charging(now: at(3)), .unknown)
    }

    /// The 5.0 battery event's flag re-establishes charging on a new connection (CHARGING_ON is sent only once),
    /// a later flag of 0 ends it, and it never claims pack attachment.
    func testBatteryEventFlagRestoresChargingAfterReconnect() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        let c2 = UUID()
        m.reset(connection: c2)
        XCTAssertEqual(m.charging(now: at(10)), .unknown)
        m.applyBattery5Flag(true, eventAt: at(30), receivedAt: at(30), connection: c2)
        XCTAssertEqual(m.charging(now: at(31)), .yes)
        XCTAssertEqual(m.chargingEvidence(now: at(31))?.source, .batteryEvent5)
        XCTAssertEqual(m.attached(now: at(31)), .unknown)
        m.applyBattery5Flag(true, eventAt: at(20), receivedAt: at(40), connection: c2)   // older event: ignored, not newer
        m.applyBattery5Flag(false, eventAt: at(60), receivedAt: at(60), connection: c2)
        XCTAssertEqual(m.charging(now: at(61)), .no)
        m.applyBattery5Flag(true, eventAt: at(90), receivedAt: at(90), connection: c)       // old link: ignored
        XCTAssertEqual(m.charging(now: at(91)), .no)
    }

    /// Every report replaces the fact (each one holds until the next).
    func testEveryBatteryFlagReportIsApplied() {
        var m = ChargingModel(connection: c)
        m.applyBattery5Flag(true, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyBattery5Flag(true, eventAt: at(30), receivedAt: at(30), connection: c)
        XCTAssertEqual(m.chargingEvidence(now: at(31))?.eventAt, at(30))
        m.applyBattery5Flag(false, eventAt: at(60), receivedAt: at(60), connection: c)
        XCTAssertEqual(m.charging(now: at(61)), .no)
    }

    /// Across a reconnect the last known facts are held until the next report. Held "charging" lapses if the strap's
    /// ~30 s reports don't resume; held "not charging" holds until a report; held facts never count as confirmed.
    func testReconnectHoldsLastKnownStateUntilNextReport() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        let c1 = UUID(), c2 = UUID()
        m.reset(connection: c1, hold: .untilReconnect, now: at(50))                       // disconnected
        XCTAssertEqual(m.charging(now: at(99)), .yes)
        m.reset(connection: c2, hold: .untilNextReport, now: at(100))                     // reconnected
        XCTAssertEqual(m.charging(now: at(101)), .yes)
        XCTAssertEqual(m.attached(now: at(101)), .yes)
        XCTAssertTrue(m.chargingEvidence(now: at(101))?.isHeld ?? false)
        XCTAssertEqual(m.confirmedCharging(now: at(101)), .unknown)
        let lapse = at(101 + ChargingModel.chargingReportWindow)
        XCTAssertEqual(m.charging(now: lapse), .unknown)                                  // no report resumed
        XCTAssertEqual(m.attached(now: lapse), .unknown)
        // A report replaces the held fact.
        m.applyBattery5Flag(true, eventAt: at(130), receivedAt: at(130), connection: c2)
        XCTAssertFalse(m.chargingEvidence(now: at(131))?.isHeld ?? true)
        XCTAssertEqual(m.confirmedCharging(now: at(131)), .yes)
        // Held "not charging" waits for the next report, however long (within the fact age limit).
        var off = ChargingModel(connection: c)
        off.applyBattery5Flag(false, eventAt: at(0), receivedAt: at(0), connection: c)
        off.reset(connection: c2, hold: .untilNextReport, now: at(100))
        XCTAssertEqual(off.charging(now: at(3600)), .no)
        // Facts already past their age limit are not carried.
        var old = ChargingModel(connection: c)
        old.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        old.reset(connection: c2, hold: .untilNextReport, now: at(ChargingModel.factMaxAge + 1))
        XCTAssertNil(old.activity)
    }

    func testRisingPercentageIsOnlyLikelyAndNeedsASustainedRise() {
        var m = ChargingModel(connection: c)
        m.applyPercent(40, at: at(0), connection: c)
        m.applyPercent(41, at: at(60), connection: c)
        XCTAssertFalse(m.chargingLikely(now: at(61)))           // a single step is not enough
        m.applyPercent(42, at: at(300), connection: c)
        m.applyPercent(43, at: at(660), connection: c)
        XCTAssertTrue(m.chargingLikely(now: at(661)))
        XCTAssertEqual(m.charging(now: at(661)), .unknown)       // never a confirmed claim
        XCTAssertFalse(m.chargingLikely(now: at(660 + ChargingModel.likelyExpiry + 1)))
        m.applyPercent(41, at: at(700), connection: c)           // a drop breaks the run
        XCTAssertFalse(m.chargingLikely(now: at(701)))
        // A confirmed contrary fact wins.
        var n = m
        n.applyPercent(42, at: at(800), connection: c)
        n.applyEvent(kind: .batteryPackRemoved, eventAt: at(801), receivedAt: at(801), connection: c)
        XCTAssertFalse(n.chargingLikely(now: at(802)))
    }

    // MARK: conflicting, delayed and stale evidence

    private func rising(_ m: inout ChargingModel, from start: TimeInterval) {
        for (k, pct) in [40, 41, 42, 43].enumerated() { m.applyPercent(pct, at: at(start + Double(k) * 240), connection: c) }
    }

    func testOlderNotChargingIsContradictedByALaterRiseButNotConfirmed() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .chargingOff, eventAt: at(0), receivedAt: at(0), connection: c)
        rising(&m, from: 600)                                     // rise begins after the report
        let now = at(600 + 3 * 240 + 1)
        XCTAssertEqual(m.charging(now: now), .no, "the strap's report is kept as reported")
        XCTAssertTrue(m.chargingLikely(now: now))
        XCTAssertEqual(m.likelyContradicts(now: now)?.source, .chargingEvent, "the conflict is surfaced, not hidden")
    }

    func testContraryFactAfterTheRiseBeganWins() {
        var m = ChargingModel(connection: c)
        rising(&m, from: 0)
        m.applyEvent(kind: .chargingOff, eventAt: at(300), receivedAt: at(300), connection: c)
        XCTAssertFalse(m.chargingLikely(now: at(3 * 240 + 1)))
        XCTAssertNil(m.likelyContradicts(now: at(3 * 240 + 1)))
    }

    func testConfirmedChargingIsNotAlsoLikely() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        rising(&m, from: 60)
        XCTAssertEqual(m.charging(now: at(800)), .yes)
        XCTAssertFalse(m.chargingLikely(now: at(800)))
    }

    func testStaleFactsExpireToUnknown() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        let later = at(ChargingModel.factMaxAge + 1)
        XCTAssertEqual(m.attached(now: later), .unknown)
        XCTAssertEqual(m.charging(now: later), .unknown)
    }

    // MARK: events before the strap clock is known

    private func event(_ kind: Whoop5EventKind, unix: Int) -> Whoop5Event {
        Whoop5Event(number: 0, kind: kind, unix: unix, subseconds: 0, body: [])
    }

    func testHeldEventIsJudgedAgainstStrapTimeAtReceipt() {
        // Strap clock is 100 s behind the Mac. The event was stamped just before it arrived: live.
        let offset = 100.0
        var p = PendingChargingEvents()
        let rx = at(10)
        p.hold(event(.batteryPackConnected, unix: Int(rx.timeIntervalSince1970 - offset) - 2), receivedAt: rx)
        p.hold(event(.chargingOn, unix: Int(rx.timeIntervalSince1970 - offset) - 3600), receivedAt: rx)   // a replay
        p.hold(event(.hapticsFired, unix: Int(rx.timeIntervalSince1970 - offset)), receivedAt: rx)          // not a charging event
        XCTAssertEqual(p.items.count, 2)
        let live = p.drain(now: at(30), deviceTime: { $0 - offset }, hostTime: { $0 + offset })
        XCTAssertEqual(live.map(\.kind), [.batteryPackConnected])
        XCTAssertEqual(live.first!.eventAt.timeIntervalSince1970, rx.timeIntervalSince1970 - 2, accuracy: 0.01)
        XCTAssertTrue(p.items.isEmpty)
    }

    func testHeldEventsExpireAndAreBounded() {
        var p = PendingChargingEvents()
        for k in 0..<20 { p.hold(event(.chargingOn, unix: Int(t0.timeIntervalSince1970) + k), receivedAt: at(Double(k))) }
        XCTAssertEqual(p.items.count, PendingChargingEvents.maxCount)
        let late = p.drain(now: at(19 + PendingChargingEvents.maxHold + 1), deviceTime: { $0 }, hostTime: { $0 })
        XCTAssertTrue(late.isEmpty, "a clock that arrives too late can't vouch for old events")
    }
}


/// #41: decoded pack-info replies and the charger's "full" stage in the model — ordering, staleness, failures.
final class PackInfoModelTests: XCTestCase {
    let c = UUID()
    let t0 = Date(timeIntervalSince1970: 1_795_186_800)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testPresentAndAbsentSetAttachment() {
        var m = ChargingModel(connection: c)
        m.applyPackInfo(.present(rawCharge: 760), requestedAt: at(0), receivedAt: at(5), connection: c)
        XCTAssertEqual(m.attached(now: at(6)), .yes)
        XCTAssertEqual(m.attachmentEvidence(now: at(6))?.source, .packInfo)
        XCTAssertEqual(m.attachmentEvidence(now: at(6))?.eventAt, at(0), "a reply describes the moment it was requested")
        XCTAssertEqual(m.charging(now: at(6)), .unknown, "presence is not charging")
        m.applyPackInfo(.absent, requestedAt: at(900), receivedAt: at(905), connection: c)
        XCTAssertEqual(m.attached(now: at(906)), .no)
        XCTAssertEqual(m.charging(now: at(906)), .no, "no pack, no charger")
    }

    func testPresentClearsOnlyAPackDerivedNotCharging() {
        var m = ChargingModel(connection: c)
        m.applyPackInfo(.absent, requestedAt: at(0), receivedAt: at(1), connection: c)
        XCTAssertEqual(m.charging(now: at(2)), .no)
        m.applyPackInfo(.present(rawCharge: 700), requestedAt: at(300), receivedAt: at(301), connection: c)
        XCTAssertEqual(m.charging(now: at(302)), .unknown)
        // A strap-reported CHARGING_OFF is kept: the pack being on doesn't mean current flows.
        m.applyEvent(kind: .chargingOff, eventAt: at(400), receivedAt: at(400), connection: c)
        m.applyPackInfo(.present(rawCharge: 690), requestedAt: at(600), receivedAt: at(601), connection: c)
        XCTAssertEqual(m.charging(now: at(602)), .no)
    }

    /// Stale: a reply to a request sent BEFORE a newer removal event arrives late; it must not re-attach the pack.
    func testLateReplyNeverOverridesNewerEvent() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackRemoved, eventAt: at(100), receivedAt: at(100), connection: c)
        m.applyPackInfo(.present(rawCharge: 418), requestedAt: at(95), receivedAt: at(105), connection: c)
        XCTAssertEqual(m.attached(now: at(106)), .no)
        XCTAssertEqual(m.attachmentEvidence(now: at(106))?.source, .packEvent)
        XCTAssertEqual(m.charging(now: at(106)), .no)
        // Out of order the other way: an old "absent" can't detach a newer attach.
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(200), receivedAt: at(200), connection: c)
        m.applyPackInfo(.absent, requestedAt: at(150), receivedAt: at(210), connection: c)
        XCTAssertEqual(m.attached(now: at(211)), .yes)
    }

    /// The reply is cached accessory state: right after a pack event it may still say the old thing.
    func testReplyRightAfterAnEventCannotContradictIt() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyPackInfo(.absent, requestedAt: at(30), receivedAt: at(35), connection: c)
        XCTAssertEqual(m.attached(now: at(36)), .yes, "within the grace a disagreeing reply is ignored")
        m.applyPackInfo(.absent, requestedAt: at(ChargingModel.packInfoEventGrace + 1), receivedAt: at(70), connection: c)
        XCTAssertEqual(m.attached(now: at(71)), .no, "after the grace the reply is the newer evidence")
        XCTAssertEqual(m.attachmentEvidence(now: at(71))?.source, .packInfo)
    }

    /// Failed / unknown replies never change attachment, charging or full.
    func testFailedRepliesChangeNothing() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyChargerStage(4, eventAt: at(10), receivedAt: at(10), connection: c)
        let before = m
        for r in [PackInfoReply.unavailable, .answeredUndecoded, .unrecognized] {
            m.applyPackInfo(r, requestedAt: at(600), receivedAt: at(601), connection: c)
        }
        XCTAssertEqual(m, before)
        // A reply from another connection is ignored too.
        m.applyPackInfo(.absent, requestedAt: at(700), receivedAt: at(701), connection: UUID())
        XCTAssertEqual(m, before)
    }

    func testChargerFullStage() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyChargerStage(2, eventAt: at(1), receivedAt: at(1), connection: c)
        XCTAssertFalse(m.chargerFull(now: at(2)))
        // C02b: stage 0 is a pause (93 %), not full.
        m.applyChargerStage(0, eventAt: at(1300), receivedAt: at(1300), connection: c)
        XCTAssertFalse(m.chargerFull(now: at(1301)))
        // Full arrives with CHARGING_OFF.
        m.applyEvent(kind: .chargingOff, eventAt: at(2670), receivedAt: at(2670), connection: c)
        m.applyChargerStage(4, eventAt: at(2670), receivedAt: at(2670), connection: c)
        XCTAssertTrue(m.chargerFull(now: at(2671)))
        XCTAssertEqual(m.charging(now: at(2671)), .no)
        // An older stage arriving late doesn't undo it.
        m.applyChargerStage(3, eventAt: at(2600), receivedAt: at(2700), connection: c)
        XCTAssertTrue(m.chargerFull(now: at(2701)))
        // Removal ends it; so does an absent reply.
        m.applyEvent(kind: .batteryPackRemoved, eventAt: at(3800), receivedAt: at(3800), connection: c)
        XCTAssertFalse(m.chargerFull(now: at(3801)))
        var n = ChargingModel(connection: c)
        n.applyChargerStage(4, eventAt: at(0), receivedAt: at(0), connection: c)
        XCTAssertTrue(n.chargerFull(now: at(1)))
        n.applyPackInfo(.absent, requestedAt: at(120), receivedAt: at(121), connection: c)
        XCTAssertFalse(n.chargerFull(now: at(122)))
    }

    /// After a reconnect a held "full" is not shown as current: the strap must say it again.
    func testHeldFullIsNotCurrent() {
        var m = ChargingModel(connection: c)
        m.applyChargerStage(4, eventAt: at(0), receivedAt: at(0), connection: c)
        m.reset(connection: UUID(), hold: .untilNextReport, now: at(10))
        XCTAssertFalse(m.chargerFull(now: at(11)))
    }
}
