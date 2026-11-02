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

    private func live(_ pct: Int, charging: Bool?, age: TimeInterval = 0, connected: Bool = true) -> LiveState {
        let l = LiveState()
        l.connected = connected
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

    func testChargingOnlyFromAVerifiedFreshReading() {
        XCTAssertTrue(BatteryPresentation(live: live(48, charging: true), now: now).isCharging)
        // Unknown is not charging, whatever the level does.
        XCTAssertFalse(BatteryPresentation(live: live(48, charging: nil), now: now).isCharging)
        // Stale (older than the alert policy's window) or disconnected: never shown as charging.
        let stale = BatteryPresentation(live: live(48, charging: true, age: BatteryAlertPolicy().staleAfter + 1), now: now)
        XCTAssertTrue(stale.stale)
        XCTAssertFalse(stale.isCharging)
        let gone = BatteryPresentation(live: live(48, charging: true, connected: false), now: now)
        XCTAssertFalse(gone.isCharging)
        XCTAssertTrue(gone.statusText.hasPrefix("Not connected"))
    }

    func testFullNeedsChargingAndOneHundredPercent() {
        XCTAssertTrue(BatteryPresentation(live: live(100, charging: true), now: now).isFull)
        XCTAssertFalse(BatteryPresentation(live: live(100, charging: nil), now: now).isFull)
        XCTAssertEqual(BatteryPresentation(live: live(100, charging: true), now: now).statusText, "Fully charged")
    }

    /// Charging comes from the strap's own report (pack attached, charging events) and reaches every battery surface.
    func testStrapChargingReportDrivesTheBatteryState() {
        let l = live(48, charging: nil)
        XCTAssertFalse(BatteryPresentation(live: l, now: now).isCharging)
        l.updateCharging(true, source: .batteryPack, at: now)
        XCTAssertTrue(BatteryPresentation(live: l, now: now).isCharging)
        // A later level reading (which carries no flag of its own) keeps the reported state.
        l.updateBattery(BatteryReading(percent: 49, charging: nil, at: now.timeIntervalSince1970, source: .standardLevel))
        XCTAssertTrue(BatteryPresentation(live: l, now: now).isCharging)
        XCTAssertEqual(l.battery?.charging, true)
        l.updateCharging(false, source: .batteryPack, at: now)
        XCTAssertEqual(BatteryPresentation(live: l, now: now).charge, .notCharging)
        // Disconnecting forgets it: the next connection has to report again.
        l.updateCharging(true, source: .chargingEvent, at: now)
        l.resetTelemetry()
        XCTAssertNil(l.chargingReport)
    }

    func testMissingReadingIsNotZero() {
        let l = LiveState()
        let b = BatteryPresentation(live: l, now: now)
        XCTAssertNil(b.percent)
        XCTAssertEqual(b.valueText, "—")
        XCTAssertNil(b.level)
    }
}
