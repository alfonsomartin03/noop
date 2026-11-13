import XCTest
@testable import StrandAnalytics

/// Issue #17: values near the personal median read as typical; boundaries; low-variance baselines; nightly max HRV.
final class PersonalRangePositionTests: XCTestCase {
    private func series(from start: String, _ values: [Double]) -> [HealthPoint] {
        values.enumerated().map { HealthPoint(day: HighlightCalendar.addDays(start, $0.offset)!, value: $0.element) }
    }
    /// 20 nights alternating around 50 ms: median 50, MAD 5 → robust SD ≈ 7.4 ms, range ≈ 35.2–64.8.
    private var spread: [HealthPoint] { series(from: "2026-10-01", (0..<20).map { $0 % 2 == 0 ? 45 : 55 }) }

    func testValueNearTheMedianIsTypical() throws {
        let (pos, b) = try XCTUnwrap(PersonalRangePosition.assess(day: "2026-10-21", value: 47, points: spread, metric: .hrv))
        XCTAssertEqual(b.median, 50)
        XCTAssertEqual(b.robustSD, 1.4826 * 5, accuracy: 1e-9)
        XCTAssertEqual(pos, .typical)
        XCTAssertEqual(pos.label, "Typical for you")
    }

    /// The exact fixture table from the issue #17 completion guide (project test cases, not clinical cut-offs).
    func testCompletionGuideFixtureTable() throws {
        let b = try XCTUnwrap(HealthMonitor.baseline(spread, metric: .hrv))
        XCTAssertEqual(b.low, 35.174, accuracy: 0.001); XCTAssertEqual(b.high, 64.826, accuracy: 0.001)
        let t = PersonalRangePosition.typicalHalfWidth(b, metric: .hrv)
        XCTAssertEqual(b.median - t, 42.587, accuracy: 0.001); XCTAssertEqual(b.median + t, 57.413, accuracy: 0.001)
        let expected: [(Double, PersonalRangePosition, String)] = [
            (50, .typical, "Typical for you"), (40, .lowerThanUsual, "Within your range, lower than usual"),
            (60, .higherThanUsual, "Within your range, higher than usual"), (30, .belowRange, "Below your range"),
            (70, .aboveRange, "Above your range"),
        ]
        for (v, pos, label) in expected {
            let (got, _) = try XCTUnwrap(PersonalRangePosition.assess(day: "2026-10-21", value: v, points: spread, metric: .hrv))
            XCTAssertEqual(got, pos, "\(v) ms"); XCTAssertEqual(got.label, label)
        }
        // Flat 60 ms history: floors give range 54–66 and typical 57–63.
        let flat = series(from: "2026-10-01", Array(repeating: 60, count: 20))
        let fb = try XCTUnwrap(HealthMonitor.baseline(flat, metric: .hrv))
        XCTAssertEqual(fb.low, 54, accuracy: 1e-9); XCTAssertEqual(fb.high, 66, accuracy: 1e-9)
        XCTAssertEqual(PersonalRangePosition.typicalHalfWidth(fb, metric: .hrv), 3, accuracy: 1e-9)
        for (v, pos) in [(58.0, PersonalRangePosition.typical), (56, .lowerThanUsual), (53, .belowRange)] {
            XCTAssertEqual(PersonalRangePosition.assess(day: "2026-10-21", value: v, points: flat, metric: .hrv)?.0, pos, "\(v) ms")
        }
    }

    func testBoundaries() throws {
        let b = try XCTUnwrap(HealthMonitor.baseline(spread, metric: .hrv))
        let t = PersonalRangePosition.typicalHalfWidth(b, metric: .hrv)
        XCTAssertEqual(PersonalRangePosition.assess(b.median + t, baseline: b, metric: .hrv), .typical)
        XCTAssertEqual(PersonalRangePosition.assess(b.median - t, baseline: b, metric: .hrv), .typical)
        XCTAssertEqual(PersonalRangePosition.assess(b.median + t + 0.01, baseline: b, metric: .hrv), .higherThanUsual)
        XCTAssertEqual(PersonalRangePosition.assess(b.median - t - 0.01, baseline: b, metric: .hrv), .lowerThanUsual)
        XCTAssertEqual(PersonalRangePosition.assess(b.high, baseline: b, metric: .hrv), .higherThanUsual)
        XCTAssertEqual(PersonalRangePosition.assess(b.high + 0.01, baseline: b, metric: .hrv), .aboveRange)
        XCTAssertEqual(PersonalRangePosition.assess(b.low - 0.01, baseline: b, metric: .hrv), .belowRange)
    }

    func testLowVarianceBaselineUsesTheFloor() throws {
        // Every night 60 ms: robust SD 0 → typical half-width 3 ms (half the 6 ms range floor), range 54–66.
        let flat = series(from: "2026-10-01", Array(repeating: 60, count: 20))
        let b = try XCTUnwrap(HealthMonitor.baseline(flat, metric: .hrv))
        XCTAssertEqual(PersonalRangePosition.typicalHalfWidth(b, metric: .hrv), 3)
        XCTAssertEqual(PersonalRangePosition.assess(58, baseline: b, metric: .hrv), .typical)
        XCTAssertEqual(PersonalRangePosition.assess(56, baseline: b, metric: .hrv), .lowerThanUsual)
        XCTAssertEqual(PersonalRangePosition.assess(53, baseline: b, metric: .hrv), .belowRange)
    }

    func testCausalAndNeedsEnoughNights() {
        // The night itself (a wild value) is never in its own baseline; fewer than 14 prior nights → nil.
        var pts = spread
        pts.append(HealthPoint(day: "2026-10-21", value: 200))
        XCTAssertEqual(PersonalRangePosition.assess(day: "2026-10-21", value: 50, points: pts, metric: .hrv)?.1.median, 50)
        XCTAssertNil(PersonalRangePosition.assess(day: "2026-10-10", value: 50, points: spread, metric: .hrv))
    }

    func testReadingExposesPositionOnlyWhenUsable() {
        var pts = spread; pts.append(HealthPoint(day: "2026-10-21", value: 51))
        XCTAssertEqual(HealthMonitor.evaluate(.hrv, points: pts, source: "NOOP", today: "2026-10-21").position, .typical)
        XCTAssertNil(HealthMonitor.evaluate(.hrv, points: pts, source: "NOOP", today: "2026-10-30").position, "stale is not typical")
    }

    // MARK: nightly max

    private func window(_ i: Int, rmssd: Double?, used: Bool) -> VitalWindow {
        VitalWindow(start: i * 300, end: i * 300 + 300, meanHR: 55, hrSamples: 300, beats: 270, cleanBeats: 265,
                    rmssd: rmssd, beatCoverage: 0.98, wakeFraction: 0, hrRejection: nil, hrvRejection: used ? nil : "awake")
    }
    private func vitals(_ w: [VitalWindow]) -> SleepVitals {
        SleepVitals(windows: w, restingHR: 50, avgSleepHR: 55, minWindowHR: 50, minSampleHR: 48, hrv: nil,
                    onsetHR: nil, wakeHR: nil, hrSamples: 0, rrBeats: 0, rrClean: 0, rejectionCounts: [:])
    }

    func testNightlyMaxUsesOnlyValidWindows() throws {
        var w = (0..<8).map { window($0, rmssd: 40 + Double($0), used: true) }
        w.append(window(8, rmssd: 180, used: false))   // rejected (awake) window is never the max
        let m = try XCTUnwrap(NightlyMaxHRV.from(vitals(w)))
        XCTAssertEqual(m.rmssd, 47)
        XCTAssertEqual(m.windowStart, 7 * 300)
        XCTAssertEqual(m.validWindows, 8)
    }

    func testNightlyMaxUnavailableWithTooFewWindows() {
        let w = (0..<(SleepVitalsCalculator.minValidWindows - 1)).map { window($0, rmssd: 50, used: true) }
        XCTAssertNil(NightlyMaxHRV.from(vitals(w)))
    }
}
