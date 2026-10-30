import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class StrainScorerTests: XCTestCase {

    /// Build n consecutive 1 Hz HR samples at a constant bpm.
    private func hr(_ bpm: Int, _ n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// Fitted zone load of a constant 1 Hz run, as the canonical path computes it.
    private func load(_ bpm: Int, _ n: Int, maxHR: Double = 190) -> Double {
        LoadSummary(SupportedHR(raw: hr(bpm, n)), requestedS: n, hrMax: maxHR).zoneLoad
    }

    func testTanaka() {
        XCTAssertEqual(StrainScorer.tanakaHRmax(age: 30), 187.0, accuracy: 1e-9)
    }

    // Pins the fitted mapping to known outputs so future tuning is a conscious change.
    func testFittedActivityIndex() {
        // 10 min at 97% HRmax = zone 5: load = 10 * 1.875 = 18.75 → 4.56 * ln(19.75) = 13.6.
        XCTAssertEqual(StrainScorer.activityIndex(load: load(185, 600))!, 13.6, accuracy: 0.01)
        // 10 min at 55% HRmax = zone 1: load = 1.05 → 4.56 * ln(2.05) = 3.28.
        XCTAssertEqual(StrainScorer.activityIndex(load: load(105, 600))!, 3.28, accuracy: 0.01)
        // Below zone 1 contributes nothing.
        XCTAssertEqual(StrainScorer.activityIndex(load: load(80, 600))!, 0, accuracy: 1e-9)
    }

    func testWhoopZoneWeightsRiseSteeply() {
        let z = StrainScorer.whoopZoneWeights
        XCTAssertEqual(z.count, 5)
        XCTAssertTrue(zip(z, z.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(z[4] / z[0], 17.9, accuracy: 0.1)
    }

    // Below the knee the score is untouched; above it, growth slows and never reaches 21.
    func testSoftCeilingShape() {
        XCTAssertEqual(StrainScorer.softCeiling(12), 12, accuracy: 1e-12)
        XCTAssertEqual(StrainScorer.softCeiling(16), 16, accuracy: 1e-12)
        var prev = 16.0
        for raw in stride(from: 17.0, through: 60.0, by: 1.0) {
            let v = StrainScorer.softCeiling(raw)
            XCTAssertGreaterThan(v, prev - 1e-12)        // never decreases
            XCTAssertLessThan(v, 21.0)                   // never reaches 21
            XCTAssertLessThan(v - prev, 1.0)             // slower than the raw curve
            prev = v
        }
    }

    func testDayIndexHasNoFloorAndIsBounded() {
        XCTAssertEqual(StrainScorer.dayIndex(load: 0), 0, "no measured load is 0, not a rest-day constant")
        XCTAssertEqual(StrainScorer.dayIndex(load: 30)!, 4.67 * log(31.0), accuracy: 0.005)
        XCTAssertLessThan(StrainScorer.dayIndex(load: 1e9)!, 21.0)
        XCTAssertEqual(StrainScorer.dayIndex(load: 1e9)!, 20.99, accuracy: 0.001)
    }

    func testIndexRefusesInvalidLoad() {
        XCTAssertNil(StrainScorer.dayIndex(load: .nan))
        XCTAssertNil(StrainScorer.dayIndex(load: .infinity))
        XCTAssertNil(StrainScorer.activityIndex(load: -1))
    }

    // More load must never lower the index, in time or in intensity.
    func testIndexMonotonic() {
        XCTAssertGreaterThan(StrainScorer.activityIndex(load: load(185, 1200))!, StrainScorer.activityIndex(load: load(185, 600))!)
        XCTAssertGreaterThan(StrainScorer.activityIndex(load: load(185, 600))!, StrainScorer.activityIndex(load: load(155, 600))!)
        var prev = -1.0
        for l in stride(from: 0.0, through: 5000.0, by: 7.0) {
            let v = StrainScorer.dayIndex(load: l)!
            XCTAssertGreaterThanOrEqual(v, prev)
            prev = v
        }
    }

    func testPercentileLinearInterp() {
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 50), 25.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 0), 10.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 100), 40.0, accuracy: 1e-9)
    }
}
