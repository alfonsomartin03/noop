import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// Issue #17 review (P2): Recovery resolves HRV and skin temperature per FIELD, mirroring `mergeDaily`, so a day whose
/// imported row lacks a field shows NOOP's value judged against NOOP's own history and labelled as NOOP.
@MainActor
final class FieldProvenanceTests: XCTestCase {
    private let day = "2026-03-21"
    private func row(_ d: String, hrv: Double? = nil, temp: Double? = nil, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: nil, avgHrv: hrv, recovery: recovery, strain: nil, exerciseCount: nil, skinTempDevC: temp)
    }
    /// 20 earlier nights: WHOOP HRV 100 ms (wrist 33.5 °C), NOOP HRV alternating 45/55 ms (deviation ±0.1 °C).
    private func history() -> (imported: [String: DailyMetric], computed: [String: DailyMetric]) {
        var imp: [String: DailyMetric] = [:], comp: [String: DailyMetric] = [:]
        for i in 1...20 {
            let d = HighlightCalendar.addDays(day, -i)!
            imp[d] = row(d, hrv: 100, temp: 33.5, recovery: 70)
            comp[d] = row(d, hrv: i % 2 == 0 ? 45 : 55, temp: i % 2 == 0 ? 0.1 : -0.1)
        }
        return (imp, comp)
    }

    func testPartialImportUsesNOOPHistoryForNOOPValue() throws {
        var (imp, comp) = history()
        imp[day] = row(day, recovery: 60)          // imported recovery, NO imported HRV/temperature
        comp[day] = row(day, hrv: 50, temp: 0.3)
        let hrv = try XCTUnwrap(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.avgHrv })
        XCTAssertEqual(hrv.source, .noop)
        XCTAssertEqual(hrv.value, 50)
        let (pos, b) = try XCTUnwrap(PersonalRangePosition.assess(day: day, value: hrv.value, points: hrv.history, metric: .hrv))
        XCTAssertEqual(b.median, 50)
        XCTAssertEqual(pos, .typical)               // against the imported 100 ms median it would read "Below your range"
        XCTAssertFalse(hrv.history.contains { $0.value == 100 }, "no imported values in a NOOP history")
        let temp = try XCTUnwrap(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.skinTempDevC })
        XCTAssertEqual(temp.source, .noop)          // a change from baseline, never labelled as WHOOP wrist °C
        XCTAssertEqual(temp.value, 0.3)
    }

    func testImportedFieldPresentNOOPOnlyAndMissingBoth() throws {
        var (imp, comp) = history()
        imp[day] = row(day, hrv: 98, temp: 33.6); comp[day] = row(day, hrv: 50, temp: 0.3)
        let both = try XCTUnwrap(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.avgHrv })
        XCTAssertEqual(both.source, .imported); XCTAssertEqual(both.value, 98)
        XCTAssertTrue(both.history.allSatisfy { $0.value >= 98 }, "imported history only")
        XCTAssertEqual(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.skinTempDevC }?.source, .imported)

        imp[day] = nil                              // NOOP-only day
        XCTAssertEqual(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.avgHrv }?.source, .noop)

        comp[day] = row(day)                        // neither source has the field
        XCTAssertNil(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.avgHrv })
        XCTAssertNil(Repository.fieldReading(day: day, imported: imp, computed: comp) { $0.skinTempDevC })
    }
}
