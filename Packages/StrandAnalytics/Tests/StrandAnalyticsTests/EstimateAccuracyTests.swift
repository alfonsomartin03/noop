import XCTest
@testable import StrandAnalytics

final class EstimateAccuracyTests: XCTestCase {
    // Days present in only one series are ignored.
    func testOnlyOverlappingDaysCompared() {
        let r = EstimateAccuracy.compare(
            official: ["d1": 60, "d2": 80, "d3": 50],
            estimate: ["d1": 66, "d2": 74, "d9": 10])
        XCTAssertEqual(r?.days, 2)
        XCTAssertEqual(r?.meanAbsError ?? -1, 6, accuracy: 1e-9)
        XCTAssertEqual(r?.bias ?? -1, 0, accuracy: 1e-9)
    }

    func testNoOverlapIsNil() {
        XCTAssertNil(EstimateAccuracy.compare(official: ["a": 1], estimate: ["b": 2]))
    }

    // Fewer than minDays shared days => result flagged unreliable (cold start).
    func testReliabilityThreshold() {
        let o = Dictionary(uniqueKeysWithValues: (0..<6).map { ("d\($0)", 50.0) })
        XCTAssertFalse(EstimateAccuracy.compare(official: o, estimate: o)!.isReliable)
    }
}
