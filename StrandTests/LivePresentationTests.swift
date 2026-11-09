import XCTest
import Combine
import WhoopProtocol
@testable import NOOP

@MainActor
final class LiveHeartRateTests: XCTestCase {
    func testMedianOfRecentReadings() {
        let h = LiveHeartRate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        for (i, v) in [60, 64, 61, 90, 62].enumerated() { h.ingest(heartRate: v, rr: [], at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(h.bpm, 62)
    }

    /// Same rule the app always had: an implausible value with no usable R-R is "no reading" and clears the number,
    /// so a stalled stream never leaves a frozen bpm on screen.
    func testImplausibleOrMissingReadingClears() {
        let h = LiveHeartRate()
        h.ingest(heartRate: 60, rr: [], at: Date())
        h.ingest(heartRate: 250, rr: [], at: Date())
        XCTAssertNil(h.bpm)
        h.ingest(heartRate: 61, rr: [], at: Date())
        XCTAssertEqual(h.bpm, 61)
        h.ingest(heartRate: nil, rr: [], at: Date())
        XCTAssertNil(h.bpm)
    }

    func testFallsBackToRRWhenNoReportedHeartRate() {
        let h = LiveHeartRate()
        h.ingest(heartRate: nil, rr: [1000], at: Date())
        XCTAssertEqual(h.bpm, 60)
    }

    func testOldReadingsLeaveTheWindow() {
        let h = LiveHeartRate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        h.ingest(heartRate: 140, rr: [], at: t0)
        h.ingest(heartRate: 70, rr: [], at: t0.addingTimeInterval(11))
        XCTAssertEqual(h.bpm, 70)
    }

    /// The point of the type: a steady heart rate does not republish, so views showing it don't redraw per beat.
    func testPublishesOnlyWhenTheShownValueChanges() {
        let h = LiveHeartRate()
        var changes = 0
        let c = h.objectWillChange.sink { changes += 1 }
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<60 { h.ingest(heartRate: 62, rr: [968], at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(changes, 1)
        c.cancel()
    }

    func testFollowsLiveStateAndAppModelNoLongerPublishesBeats() {
        let live = LiveState()
        let h = LiveHeartRate(following: live)
        var changes = 0
        let c = h.objectWillChange.sink { changes += 1 }
        for _ in 0..<30 { live.heartRate = 58; live.rr = [1034] }
        XCTAssertEqual(h.bpm, 58)
        XCTAssertEqual(changes, 1)
        c.cancel()
    }

    func testZonesUseTheScoringBands() {
        // 50/60/70/80/90 % of max, below 50 % is "below Zone 1" (not Zone 1).
        XCTAssertEqual(LiveHeartRate.zone(bpm: 90, maxHR: 200), 0)
        XCTAssertEqual(LiveHeartRate.zone(bpm: 100, maxHR: 200), 1)
        XCTAssertEqual(LiveHeartRate.zone(bpm: 150, maxHR: 200), 3)
        XCTAssertEqual(LiveHeartRate.zone(bpm: 200, maxHR: 200), 5)
        XCTAssertEqual(LiveHeartRate.zoneLabel(0), "Below Zone 1")
    }
}

@MainActor
final class BatteryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    /// `charging` is what the strap reported (CHARGING_ON/OFF at `now`), not a flag on the reading.
    private func live(_ pct: Int, charging: Bool?, age: TimeInterval = 0, connected: Bool = true) -> LiveState {
        let l = LiveState()
        l.connected = connected
        if let c = charging { l.applyChargingEvent(c ? .chargingOn : .chargingOff, eventAt: now, receivedAt: now) }
        l.battery = BatteryStatus(reading: BatteryReading(percent: pct, charging: charging,
                                                         at: now.timeIntervalSince1970 - age, source: .vendorCommand))
        l.batteryPct = Double(pct)
        return l
    }

    func testLowMatchesTheLowBatteryAlert() {
        let threshold = BatteryAlertPolicy().lowPercent
        XCTAssertEqual(BatteryPresentation(live: live(threshold - 1, charging: nil), now: now).level, .low)
        XCTAssertNotEqual(BatteryPresentation(live: live(threshold, charging: nil), now: now).level, .low)
    }

    func testNeedsChargeOnlyForFreshLowReadingOffCharger() {
        let low = BatteryAlertPolicy().lowPercent - 1
        XCTAssertTrue(BatteryPresentation(live: live(low, charging: nil), now: now).needsCharge)
        XCTAssertTrue(BatteryPresentation(live: live(low, charging: false), now: now).needsCharge)
        XCTAssertFalse(BatteryPresentation(live: live(low + 1, charging: nil), now: now).needsCharge)
        XCTAssertFalse(BatteryPresentation(live: live(low, charging: true), now: now).needsCharge)
        XCTAssertFalse(BatteryPresentation(live: live(low, charging: nil, age: BatteryAlertPolicy().staleAfter + 1), now: now).needsCharge)
        XCTAssertFalse(BatteryPresentation(live: live(low, charging: nil, connected: false), now: now).needsCharge)
        let attached = live(low, charging: nil)
        attached.applyChargingEvent(.batteryPackConnected, eventAt: now, receivedAt: now)
        XCTAssertFalse(BatteryPresentation(live: attached, now: now).needsCharge)
    }

    func testChargingOnlyFromAVerifiedFreshReading() {
        XCTAssertTrue(BatteryPresentation(live: live(48, charging: true), now: now).isCharging)
        // Unknown is not charging, whatever the level does.
        XCTAssertFalse(BatteryPresentation(live: live(48, charging: nil), now: now).isCharging)
        // An old PERCENTAGE is stale, but the strap's charging report keeps its own freshness.
        let stale = BatteryPresentation(live: live(48, charging: true, age: BatteryAlertPolicy().staleAfter + 1), now: now)
        XCTAssertTrue(stale.stale)
        XCTAssertTrue(stale.isCharging)
        XCTAssertFalse(stale.isFull)
        XCTAssertEqual(stale.statusText.prefix(10), "Charging ·")
        // Disconnected: never shown as charging.
        let gone = BatteryPresentation(live: live(48, charging: true, connected: false), now: now)
        XCTAssertFalse(gone.isCharging)
        XCTAssertTrue(gone.statusText.hasPrefix("Not connected"))
    }

    func testFailedPackPollPreservesChargingPresentation() throws {
        let l = live(48, charging: true)
        l.applyChargingEvent(.batteryPackConnected, eventAt: now, receivedAt: now)
        let later = now.addingTimeInterval(60)
        let reply = try XCTUnwrap(Whoop5Charging.packInfo(command: 151, result: .failure,
                                                       body: [1] + Array(repeating: 0, count: 30)))
        l.applyPackInfo(reply, requestedAt: later, connection: l.connectionId, receivedAt: later)
        l.updateBattery(BatteryReading(percent: 49, charging: nil, at: later.timeIntervalSince1970, source: .standardLevel))
        let b = BatteryPresentation(live: l, now: later)
        XCTAssertEqual(b.attachment, .attached)
        XCTAssertEqual(b.charge, .charging)
        XCTAssertEqual(b.illustration, .charging)
        XCTAssertEqual(l.battery?.charging, true)
    }

    func testFullNeedsChargingAndOneHundredPercent() {
        XCTAssertTrue(BatteryPresentation(live: live(100, charging: true), now: now).isFull)
        XCTAssertFalse(BatteryPresentation(live: live(100, charging: nil), now: now).isFull)
        XCTAssertEqual(BatteryPresentation(live: live(100, charging: true), now: now).statusText, "Fully charged")
    }

    /// Attachment and charging are separate; a fresh percentage stamps the CONFIRMED fact only; disconnect forgets both.
    func testChargingModelDrivesEverySurface() {
        let l = live(48, charging: nil)
        XCTAssertEqual(BatteryPresentation(live: l, now: now).illustration, .unknown)
        l.applyChargingEvent(.batteryPackConnected, eventAt: now, receivedAt: now)
        var b = BatteryPresentation(live: l, now: now)
        XCTAssertEqual(b.attachment, .attached)
        XCTAssertFalse(b.isCharging)                                  // attached is not charging
        XCTAssertEqual(b.illustration, .attached)
        XCTAssertEqual(b.statusText, "Charger attached")
        l.applyChargingEvent(.chargingOn, eventAt: now, receivedAt: now)
        l.updateBattery(BatteryReading(percent: 49, charging: nil, at: now.timeIntervalSince1970, source: .standardLevel))
        b = BatteryPresentation(live: l, now: now)
        XCTAssertTrue(b.isCharging)
        XCTAssertEqual(l.battery?.charging, true)                     // the alert sees the same confirmed state
        // Removal: a late pack-info reply requested before it changes nothing.
        l.applyChargingEvent(.batteryPackRemoved, eventAt: now.addingTimeInterval(10), receivedAt: now.addingTimeInterval(10))
        l.applyPackInfo(.answeredUndecoded, requestedAt: now.addingTimeInterval(5), connection: l.connectionId, receivedAt: now.addingTimeInterval(12))
        b = BatteryPresentation(live: l, now: now.addingTimeInterval(13))
        XCTAssertEqual(b.charge, .notCharging)
        XCTAssertEqual(b.illustration, .detached)
        XCTAssertEqual(l.battery?.charging, false)
        // Disconnect: shown as unknown while disconnected; after reconnecting the last known state is held (labelled)
        // until the strap reports again or the hold ends, and it never stamps readings for alerts.
        l.applyChargingEvent(.chargingOn, eventAt: now.addingTimeInterval(20), receivedAt: now.addingTimeInterval(20))
        l.connected = false
        l.resetTelemetry(now: now.addingTimeInterval(21))
        XCTAssertEqual(BatteryPresentation(live: l, now: now.addingTimeInterval(21)).charge, .unknown)
        let back = now.addingTimeInterval(60)
        l.beginConnection(now: back)
        l.connected = true
        b = BatteryPresentation(live: l, now: back.addingTimeInterval(1))
        XCTAssertTrue(b.isCharging)
        XCTAssertTrue(b.chargeHeld)
        XCTAssertTrue(b.statusText.hasPrefix("Charging · last reported"))
        l.updateBattery(BatteryReading(percent: 50, charging: nil, at: back.timeIntervalSince1970 + 2, source: .standardLevel))
        XCTAssertNil(l.battery?.charging)
        let lapsed = back.addingTimeInterval(ChargingModel.chargingReportWindow + 1)
        XCTAssertEqual(BatteryPresentation(live: l, now: lapsed).charge, .unknown)
        // The battery event's flag confirms it again on this connection.
        l.applyCharging5(true, eventAt: back.addingTimeInterval(30), receivedAt: back.addingTimeInterval(30))
        b = BatteryPresentation(live: l, now: back.addingTimeInterval(31))
        XCTAssertTrue(b.isCharging)
        XCTAssertFalse(b.chargeHeld)
        XCTAssertEqual(b.statusText, "Charging")
    }

    /// A rising percentage shows "charging likely", never confirmed charging, and never counts toward the full alert.
    func testRisingPercentageIsLabelledLikelyOnly() {
        let l = LiveState(); l.connected = true
        for (i, p) in [60, 61, 62, 64].enumerated() {
            l.updateBattery(BatteryReading(percent: p, charging: nil, at: now.timeIntervalSince1970 + Double(i) * 300, source: .standardLevel))
        }
        let b = BatteryPresentation(live: l, now: now.addingTimeInterval(901))
        XCTAssertEqual(b.charge, .likely)
        XCTAssertFalse(b.isCharging)
        XCTAssertNil(l.battery?.charging)
        XCTAssertEqual(b.statusText, "Battery increasing — charging likely")
    }

    /// Strap battery, charging pack and charging are always three separate rows with consistent words.
    func testFactsStayDistinctAcrossScenarios() {
        func values(_ b: BatteryPresentation) -> [String] { b.facts.map(\.value) }
        let l = live(62, charging: nil)
        XCTAssertEqual(values(BatteryPresentation(live: l, now: now)), ["62%", "Unknown", "Unknown"])
        l.applyChargingEvent(.batteryPackConnected, eventAt: now, receivedAt: now)
        XCTAssertEqual(values(BatteryPresentation(live: l, now: now)), ["62%", "Attached", "Unknown"], "attached is not charging")
        l.applyChargingEvent(.chargingOn, eventAt: now, receivedAt: now)
        XCTAssertEqual(values(BatteryPresentation(live: l, now: now)), ["62%", "Attached", "Yes"])
        let full = live(100, charging: true)
        full.applyChargingEvent(.batteryPackConnected, eventAt: now, receivedAt: now)
        XCTAssertEqual(values(BatteryPresentation(live: full, now: now)), ["100%", "Attached", "Full"])
        l.applyChargingEvent(.batteryPackRemoved, eventAt: now.addingTimeInterval(5), receivedAt: now.addingTimeInterval(5))
        XCTAssertEqual(values(BatteryPresentation(live: l, now: now.addingTimeInterval(6))), ["62%", "Not attached", "No"])
        // Disconnected or stale: no confident claims.
        let gone = BatteryPresentation(live: live(62, charging: true, connected: false), now: now)
        XCTAssertEqual(values(gone), ["62%", "Unknown", "Unknown"])
        XCTAssertFalse(gone.facts[0].known)
        let old = BatteryPresentation(live: live(62, charging: nil, age: BatteryAlertPolicy().staleAfter + 1), now: now)
        XCTAssertFalse(old.facts[0].known)
        XCTAssertTrue(old.facts[0].detail?.hasPrefix("Last reading") == true)
    }

    /// A rise that began after an older "not charging" report shows as likely, says so, and never confirms charging.
    func testConflictingEvidenceIsShownAsLikelyWithTheConflict() {
        let l = LiveState(); l.connected = true
        l.applyChargingEvent(.chargingOff, eventAt: now, receivedAt: now)
        for (i, p) in [60, 61, 62, 64].enumerated() {
            l.updateBattery(BatteryReading(percent: p, charging: nil, at: now.timeIntervalSince1970 + 600 + Double(i) * 300, source: .standardLevel))
        }
        let b = BatteryPresentation(live: l, now: now.addingTimeInterval(600 + 901))
        XCTAssertEqual(b.charge, .likely)
        XCTAssertFalse(b.isCharging)
        XCTAssertNotNil(b.contradictedReportAt)
        XCTAssertTrue(b.facts[2].detail?.contains("reported otherwise") == true)
        XCTAssertEqual(l.battery?.charging, false, "the alert still sees only the strap's own report")
    }

    func testMissingReadingIsNotZero() {
        let l = LiveState()
        let b = BatteryPresentation(live: l, now: now)
        XCTAssertNil(b.percent)
        XCTAssertEqual(b.valueText, "—")
        XCTAssertNil(b.level)
    }
}
