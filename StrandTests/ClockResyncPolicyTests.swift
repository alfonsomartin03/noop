import XCTest
@testable import NOOP

/// K01 daily strap-clock re-sync decision (pure). Offsets are Mac − strap seconds.
final class ClockResyncPolicyTests: XCTestCase {
    let now = 1_795_030_000.0
    let day = 86_400.0

    private func due(_ offset: Double, unc: Double = 0.5, age: Double = 30, last: Double? = nil) -> Bool {
        ClockResyncPolicy.shouldResync(offset: offset, uncertainty: unc, measuredAt: now - age,
                                       lastAttemptAt: last, now: now)
    }

    func testDailyDriftIsCorrectedOncePerDay() {
        XCTAssertTrue(due(1.4), "first time, ~one day of drift")
        XCTAssertFalse(due(1.4, last: now - day + 60), "less than a day since the last attempt")
        XCTAssertTrue(due(1.4, last: now - day), "a day later")
        XCTAssertTrue(due(-1.2), "a strap running ahead is corrected too")
    }

    func testSmallOrUntrustedOffsetsAreLeftAlone() {
        XCTAssertFalse(due(0.07), "the state right after K01")
        XCTAssertFalse(due(0.99))
        XCTAssertFalse(due(5, unc: 1.5), "estimate too uncertain")
        XCTAssertFalse(due(5, age: 21 * 60), "estimate too old")
        XCTAssertFalse(due(5, age: -10), "estimate from the future")
        XCTAssertFalse(due(.nan))
    }

    func testLargeOffsetRetriesHourly() {
        XCTAssertTrue(due(40.5, last: now - 3_600), "strap lost time: an hour is enough")
        XCTAssertFalse(due(40.5, last: now - 3_000))
        XCTAssertFalse(due(5, last: now - 3_600), "ordinary drift still waits a day")
        XCTAssertTrue(due(5, last: now + 600), "a last attempt in the future (Mac clock moved back) does not block")
    }

    func testEnabledByDefaultAndSwitchable() {
        let d = UserDefaults(suiteName: "ClockResyncPolicyTests")!
        d.removePersistentDomain(forName: "ClockResyncPolicyTests")
        XCTAssertTrue(ClockResyncPolicy.isEnabled(d))
        d.set(false, forKey: ClockResyncPolicy.enabledKey)
        XCTAssertFalse(ClockResyncPolicy.isEnabled(d))
        d.removePersistentDomain(forName: "ClockResyncPolicyTests")
    }
}
