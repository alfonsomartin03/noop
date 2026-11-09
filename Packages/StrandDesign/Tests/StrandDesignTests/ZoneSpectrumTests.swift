import XCTest
@testable import StrandDesign

final class ZoneSpectrumTests: XCTestCase {
    func testFractionsIncludeGapSeparately() {
        let f = ZoneSpectrumLayout.fractions([60, 0, 120, 0, 0], gapSeconds: 60)
        XCTAssertEqual(f.count, 6)
        XCTAssertEqual(f[0], 0.25, accuracy: 1e-9)
        XCTAssertEqual(f[1], 0)
        XCTAssertEqual(f[2], 0.5, accuracy: 1e-9)
        XCTAssertEqual(f.last!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(f.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testEmptyIsAllZero() {
        XCTAssertEqual(ZoneSpectrumLayout.fractions([0, 0, 0]), [0, 0, 0, 0])
        XCTAssertEqual(ZoneSpectrumLayout.widths([0, 0], width: 100, spacing: 2), [0, 0])
    }

    func testNegativeSecondsClampToZero() {
        let f = ZoneSpectrumLayout.fractions([-30, 30])
        XCTAssertEqual(f[0], 0)
        XCTAssertEqual(f[1], 1, accuracy: 1e-9)
    }

    func testWidthsFillRibbonAndKeepSliversVisible() {
        let f = ZoneSpectrumLayout.fractions([1, 999, 0])
        let w = ZoneSpectrumLayout.widths(f, width: 200, spacing: 2, minWidth: 4)
        XCTAssertGreaterThanOrEqual(w[0], 4)
        XCTAssertEqual(w[2], 0)
        XCTAssertEqual(w[3], 0)
        // Two visible slices + one spacing fill the width exactly.
        XCTAssertEqual(w.reduce(0, +) + 2, 200, accuracy: 0.001)
        XCTAssertGreaterThan(w[1], w[0])
    }

    func testTextFormatting() {
        XCTAssertEqual(ZoneSpectrumLayout.percentText(0), "0 %")
        XCTAssertEqual(ZoneSpectrumLayout.percentText(0.004), "<1 %")
        XCTAssertEqual(ZoneSpectrumLayout.percentText(0.426), "43 %")
        XCTAssertEqual(ZoneSpectrumLayout.duration(59), "0 m")
        XCTAssertEqual(ZoneSpectrumLayout.duration(65 * 60), "1 h 05 m")
    }
}
