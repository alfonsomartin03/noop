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

    /// The real E02 reply frame (captures/E02-readonly-matrix.jsonl, seq 210) parses as detached.
    func testCapturedDetachedReply() throws {
        let hex = "aa01280001002de1245697d200010000000000000000000000000000000000000000000000000000000000008caeb213"
        var bytes: [UInt8] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let r = try XCTUnwrap(Whoop5CommandResponse.decode(bytes))
        XCTAssertEqual(r.command, 151)
        XCTAssertEqual(r.body.count, 31)
        XCTAssertEqual(Whoop5Charging.packInfo(r), .detached)
    }

    func testPackInfoShapes() {
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .failure, body: [1] + Array(repeating: 0, count: 30)), .detached)
        // SUCCESS is not proof of attachment: its layout was never captured.
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .success, body: [1, 42, 0, 7]), .answeredUndecoded)
        // Malformed / other shapes are unrecognized, never "detached".
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .failure, body: [1] + Array(repeating: 0, count: 10)), .unrecognized)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .failure, body: [1, 9] + Array(repeating: 0, count: 29)), .unrecognized)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .pending, body: []), .unrecognized)
        XCTAssertEqual(Whoop5Charging.packInfo(command: 151, result: .unsupported, body: []), .unrecognized)
        XCTAssertNil(Whoop5Charging.packInfo(command: 26, result: .success, body: [55]))
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

    /// A missed removal: the pack-info poll (detached shape) corrects a stale "attached".
    func testMissedRemovalCorrectedByPoll() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .batteryPackConnected, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        m.applyPackInfo(.detached, requestedAt: at(60), receivedAt: at(60.1), connection: c)
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

    func testReconnectDoesNotResurrectState() {
        var m = ChargingModel(connection: c)
        m.applyEvent(kind: .chargingOn, eventAt: at(0), receivedAt: at(0), connection: c)
        let c2 = UUID()
        m.reset(connection: c2)
        XCTAssertEqual(m.charging(now: at(1)), .unknown)
        m.applyEvent(kind: .chargingOn, eventAt: at(2), receivedAt: at(2), connection: c)   // a late callback from the old link
        XCTAssertEqual(m.charging(now: at(3)), .unknown)
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
        n.applyPackInfo(.detached, requestedAt: at(801), receivedAt: at(801), connection: c)
        XCTAssertFalse(n.chargingLikely(now: at(802)))
    }
}
