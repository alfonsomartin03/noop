import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class StrainScorerTests: XCTestCase {

    /// Build n consecutive 1 Hz HR samples at a constant bpm.
    private func hr(_ bpm: Int, _ n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testTanakaAndDefaultMax() {
        XCTAssertEqual(StrainScorer.tanakaHRmax(age: 30), 187.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.defaultMaxHR(age: 30), 190)
    }

    // The theoretical daily maximum maps to exactly 21.
    func testTrimpToStrainCeilingMapsTo21() {
        // Edwards 24 h ceiling TRIMP = 7200 → strain exactly 21.0 with D = 7201.
        XCTAssertEqual(StrainScorer.trimpToStrain(7200), 21.0, accuracy: 1e-9)
    }

    func testTrimpToStrainKnownValues() {
        XCTAssertEqual(StrainScorer.trimpToStrain(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(-5), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(100), 10.91, accuracy: 1e-9)
    }

    func testStrainGoldenEdwardsZone5() {
        // 600 z5 samples at 1 Hz, resting 60, max 190. TRIMP = 600*5*(1/60)=50.
        // strain = 21*ln(51)/ln(7201) = 9.3.
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60, method: .edwards)
        XCTAssertEqual(s!, 9.3, accuracy: 1e-2)
    }

    // Pins the WHOOP-fitted model to known outputs so future tuning is a conscious change.
    func testWhoopFittedActivityStrain() {
        // 10 min at 97% HRmax = zone 5: load = 10 * 1.875 = 18.75 → 4.56 * ln(19.75) = 13.6.
        XCTAssertEqual(StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!, 13.6, accuracy: 0.01)
        // 10 min at 55% HRmax = zone 1: load = 1.05 → 4.56 * ln(2.05) = 3.28.
        XCTAssertEqual(StrainScorer.strain(hr(105, 600), maxHR: 190, restingHR: 60)!, 3.28, accuracy: 0.01)
        // Below zone 1 contributes nothing.
        XCTAssertEqual(StrainScorer.strain(hr(80, 600), maxHR: 190, restingHR: 60)!, 0, accuracy: 1e-9)
    }

    func testWhoopZoneWeightsRiseSteeply() {
        let z = StrainScorer.whoopZoneWeights
        XCTAssertEqual(z.count, 5)
        XCTAssertTrue(zip(z, z.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertEqual(z[4] / z[0], 17.9, accuracy: 0.1)
    }

    func testDayStrainFloorAndCeiling() {
        // No workouts: 4.67 * ln(2.66) = 4.57 (WHOOP rest days sit near 4.3).
        XCTAssertEqual(StrainScorer.dayStrain(workoutLoads: []), 4.57, accuracy: 0.01)
        // Loads add up before the log.
        XCTAssertEqual(StrainScorer.dayStrain(workoutLoads: [10, 20]),
                       StrainScorer.dayStrain(workoutLoads: [30]), accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.dayStrain(workoutLoads: [1e9]), 21.0, accuracy: 1e-9)
    }

    func testStrainReturnsNilTooFewReadings() {
        XCTAssertNil(StrainScorer.strain(hr(150, 599), maxHR: 190, restingHR: 60))
    }

    func testStrainReturnsNilInvalidHRR() {
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 60, restingHR: 60))
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 50, restingHR: 60))
    }

    // More time in a zone must never lower strain.
    func testStrainMonotonicInZoneTime() {
        // More time at high intensity → higher strain. Compare 600 vs 1200 z5 samples.
        let short = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!
        let long = StrainScorer.strain(hr(185, 1200), maxHR: 190, restingHR: 60)!
        XCTAssertGreaterThan(long, short)
    }

    func testStrainMonotonicInIntensity() {
        // Same duration, higher zone → higher strain.
        let z3 = StrainScorer.strain(hr(155, 600), maxHR: 190, restingHR: 60)!  // ~73% HRR → w3
        let z5 = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!  // ~96% HRR → w5
        XCTAssertGreaterThan(z5, z3)
    }

    func testStrainBanisterAlsoBounded() {
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60, method: .banister)!
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 21.0)
    }

    // Observed peak is trusted only when it exceeds the age formula.
    func testEstimateHRmaxObservedVsTanaka() {
        // Thin history but known age → tanaka.
        let (v1, src1) = StrainScorer.estimateHRmax([150, 160, 170], age: 30)
        XCTAssertEqual(v1, 187.0, accuracy: 1e-9)
        XCTAssertEqual(src1, "tanaka")

        // No age, no history → unknown.
        let (v2, src2) = StrainScorer.estimateHRmax([150], age: nil)
        XCTAssertEqual(v2, 0.0)
        XCTAssertEqual(src2, "unknown")

        // Dense history with a sustained high tail above tanaka → observed.
        // The 99.5th percentile must exceed 187, so the top ~0.5% must be high:
        // 700 samples, top 10 (>0.5%) at 195 → p99.5 lands in the high tail.
        var hist = Array(repeating: 120.0, count: 690)
        hist.append(contentsOf: Array(repeating: 195.0, count: 10))
        let (v3, src3) = StrainScorer.estimateHRmax(hist, age: 30)
        XCTAssertEqual(src3, "observed")
        XCTAssertGreaterThan(v3, 187.0)
    }

    func testPercentileLinearInterp() {
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 50), 25.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 0), 10.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 100), 40.0, accuracy: 1e-9)
    }

    func testFitStrainDenominator() throws {
        // Pairs generated from a known D should recover that D.
        let knownD = 5000.0
        func strainFor(_ t: Double) -> Double { 21 * log(t + 1) / log(knownD) }
        let pairs = [(100.0, strainFor(100)), (1000.0, strainFor(1000)), (50.0, strainFor(50))]
        let fitted = try StrainScorer.fitStrainDenominator(pairs)
        XCTAssertEqual(fitted, knownD, accuracy: 1.0)
    }

    func testFitStrainDenominatorThrowsTooFew() {
        XCTAssertThrowsError(try StrainScorer.fitStrainDenominator([(100, 10)]))
    }
}
