import XCTest
@testable import StrandAnalytics

final class HealthMonitorTests: XCTestCase {
    private func series(from start: String, _ values: [Double?]) -> [HealthPoint] {
        values.enumerated().compactMap { i, v in v.map { HealthPoint(day: HighlightCalendar.addDays(start, i)!, value: $0) } }
    }

    func testBuildingBaselineUntilEnoughPriorNights() {
        let pts = series(from: "2026-10-01", Array(repeating: 55, count: 10))
        let r = HealthMonitor.evaluate(.restingHR, points: pts, source: "NOOP", today: "2026-10-10")
        XCTAssertEqual(r.status, .buildingBaseline(have: 9, need: 14))
        XCTAssertNil(r.baseline)
    }

    func testBaselineIsCausalAndFlagsDeviation() {
        // 20 steady nights, then a high latest value. The latest value must not be in its own baseline.
        var v: [Double?] = (0..<20).map { 55 + Double($0 % 3) }
        v.append(70)
        let pts = series(from: "2026-10-01", v)
        let r = HealthMonitor.evaluate(.restingHR, points: pts, source: "NOOP", today: "2026-10-21")
        XCTAssertEqual(r.latest?.value, 70)
        XCTAssertEqual(r.status, .above)
        XCTAssertEqual(r.baseline?.count, 20)
        XCTAssertEqual(r.baseline?.lastDay, "2026-10-20")
        XCTAssertLessThan(r.baseline!.high, 70)
    }

    func testMinimumHalfWidthAvoidsFlaggingTinyChanges() {
        var v: [Double?] = Array(repeating: 55, count: 20)
        v.append(57)
        let r = HealthMonitor.evaluate(.restingHR, points: series(from: "2026-10-01", v), source: "NOOP", today: "2026-10-21")
        XCTAssertEqual(r.status, .within)   // MAD is 0; the 3 bpm floor keeps 57 inside
    }

    func testOutliersAreDroppedFromBaseline() {
        var v: [Double?] = (0..<20).map { 50 + Double($0 % 4) }
        v[5] = 190   // artefact
        v.append(52)
        let r = HealthMonitor.evaluate(.hrv, points: series(from: "2026-10-01", v), source: "NOOP", today: "2026-10-21")
        XCTAssertEqual(r.baseline?.outliers, 1)
        XCTAssertEqual(r.status, .within)
    }

    func testStaleAndNoData() {
        let pts = series(from: "2026-10-01", Array(repeating: 15, count: 20))
        let r = HealthMonitor.evaluate(.respiratoryRate, points: pts, source: "NOOP", today: "2026-10-25")
        XCTAssertEqual(r.status, .stale(daysOld: 5))
        let none = HealthMonitor.evaluate(.spo2, points: [], source: "NOOP", today: "2026-10-25")
        XCTAssertEqual(none.status, .noData)
    }

    func testInvalidValuesAreNotZeroOrReadings() {
        let pts = [HealthPoint(day: "2026-10-01", value: 0), HealthPoint(day: "2026-10-02", value: .nan),
                   HealthPoint(day: "2026-10-03", value: 101)]
        let r = HealthMonitor.evaluate(.spo2, points: pts, source: "NOOP", today: "2026-10-03")
        XCTAssertEqual(r.status, .noData)
    }

    func testSourceIsolationNeverMixesBaselines() {
        let noop = series(from: "2026-10-01", Array(repeating: 60, count: 21))
        let imported = series(from: "2026-10-01", Array(repeating: 45, count: 21))
        let r = HealthMonitor.reading(.restingHR, noop: noop, imported: imported, today: "2026-10-21")
        XCTAssertEqual(r.source, "NOOP")
        XCTAssertEqual(r.baseline?.median, 60)
        // NOOP stale, import fresher → import, with its own baseline.
        let staleNoop = series(from: "2026-09-01", Array(repeating: 60, count: 21))
        let r2 = HealthMonitor.reading(.restingHR, noop: staleNoop, imported: imported, today: "2026-10-21")
        XCTAssertEqual(r2.source, "WHOOP import")
        XCTAssertEqual(r2.baseline?.median, 45)
    }

    func testSummaryNeverAllClearWithMissingMetrics() {
        let fresh = series(from: "2026-10-01", Array(repeating: 55, count: 21))
        let s = HealthMonitor.summary(noop: [.restingHR: fresh, .hrv: series(from: "2026-10-01", Array(repeating: 60, count: 21))],
                                      imported: [:], today: "2026-10-21")
        XCTAssertEqual(s.usable, 2)
        XCTAssertEqual(s.unavailable, 3)
        XCTAssertTrue(s.headline.contains("not available"))
    }

    func testBaselineUpdatesWhenHistoryChanges() {
        var v: [Double?] = Array(repeating: 55, count: 20); v.append(60)
        let a = HealthMonitor.evaluate(.restingHR, points: series(from: "2026-10-01", v), source: "NOOP", today: "2026-10-21")
        v = Array(repeating: 62, count: 20); v.append(60)
        let b = HealthMonitor.evaluate(.restingHR, points: series(from: "2026-10-01", v), source: "NOOP", today: "2026-10-21")
        XCTAssertEqual(a.status, .above)
        XCTAssertEqual(b.status, .within)
    }

    func testBiologicalAgeIsUnavailableWithReasons() {
        guard case let .unavailable(reason, missing) = BiologicalAgeModel.availability(hasAge: false, hasSex: true) else {
            return XCTFail()
        }
        XCTAssertNil(BiologicalAgeModel.version)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(missing.contains("chronological age"))
    }

    func testActivationTimelineCategories() {
        let from = 1_800_000_000
        var s: [(ts: Int, bpm: Int)] = []
        // bin 0: resting 60 bpm; bin 1: 110 bpm (HRR 0.4 with rest 60/max 185); bin 2: no samples; bin 3: sleep; bin 4: workout
        for t in stride(from: 0, to: 900, by: 2) { s.append((from + t, 60)) }
        for t in stride(from: 900, to: 1800, by: 2) { s.append((from + t, 110)) }
        for t in stride(from: 2700, to: 4500, by: 2) { s.append((from + t, 80)) }
        let bins = HRActivation.timeline(samples: s, from: from, to: from + 4500, restingHR: 60, maxHR: 185,
                                         sleep: [(from + 2700, from + 3600)], workouts: [(from + 3600, from + 4500)])
        XCTAssertEqual(bins.map(\.level), [.low, .high, .noData, .sleep, .exercise])
        XCTAssertEqual(HRActivation.totals(bins)[.noData], 900)
    }
}
