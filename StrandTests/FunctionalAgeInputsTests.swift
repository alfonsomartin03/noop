import XCTest
import WhoopStore
import StrandAnalytics
@testable import NOOP

/// #49: Repository hands NOOP and imported rows to the snapshot separately, so sources never mix in a window.
@MainActor
final class FunctionalAgeInputsTests: XCTestCase {
    private func metric(_ day: String, rhr: Int?, sleepMin: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testDaysKeepSourcesApartAndSkipEmptyRows() {
        let repo = Repository(deviceId: "test")
        repo.estimates = ["2026-11-16": metric("2026-11-16", rhr: 55, sleepMin: 450),
                          "2026-11-17": metric("2026-11-17", rhr: nil, sleepMin: nil)]
        repo.official = ["2026-11-16": metric("2026-11-16", rhr: 58, sleepMin: 0)]
        let days = repo.functionalAgeDays().sorted { (a, b) in
            (a.restingHR?.imported ?? false ? 1 : 0) < (b.restingHR?.imported ?? false ? 1 : 0)
        }
        XCTAssertEqual(days.count, 2, "an all-empty NOOP row is dropped")
        XCTAssertEqual(days[0].restingHR, FunctionalAgeSnapshot.Reading(value: 55, imported: false))
        XCTAssertEqual(days[0].sleepHours, FunctionalAgeSnapshot.Reading(value: 7.5, imported: false))
        XCTAssertEqual(days[1].restingHR, FunctionalAgeSnapshot.Reading(value: 58, imported: true))
        XCTAssertNil(days[1].sleepHours, "0 minutes of sleep is missing, not a zero-hour night")
    }
}
