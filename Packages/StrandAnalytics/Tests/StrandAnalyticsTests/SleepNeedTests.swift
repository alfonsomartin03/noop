import XCTest
@testable import StrandAnalytics

final class SleepNeedTests: XCTestCase {
    // WHOOP-reported need and debt are used as-is.
    func testOfficialValuesWin() {
        let s = SleepNeed.summarize(officialNeed: 500, officialDebt: 75, asleep: 420, recentAsleep: [300])!
        XCTAssertTrue(s.isOfficial)
        XCTAssertEqual(s.needMin, 500); XCTAssertEqual(s.debtMin, 75)
    }
    func testOfficialNeedWithoutDebtDerivesShortfall() {
        let s = SleepNeed.summarize(officialNeed: 480, officialDebt: nil, asleep: 400, recentAsleep: [])!
        XCTAssertEqual(s.debtMin, 80)
    }
    // No official need: use max(7.5 h, recent average).
    func testEstimateUsesFloorAndRecentMean() {
        let low = SleepNeed.summarize(officialNeed: nil, officialDebt: nil, asleep: 400, recentAsleep: [360, 380])!
        XCTAssertFalse(low.isOfficial); XCTAssertEqual(low.needMin, 450); XCTAssertEqual(low.debtMin, 50)
        let high = SleepNeed.summarize(officialNeed: nil, officialDebt: nil, asleep: 500, recentAsleep: [480, 520])!
        XCTAssertEqual(high.needMin, 500); XCTAssertEqual(high.debtMin, 0)
    }
    // No sleep recorded => nothing to summarise.
    func testNoSleepNoSummary() {
        XCTAssertNil(SleepNeed.summarize(officialNeed: 480, officialDebt: 10, asleep: nil, recentAsleep: []))
    }
}
