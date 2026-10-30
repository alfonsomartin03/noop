import XCTest
import SwiftUI
@testable import StrandDesign

final class StrandDesignTests: XCTestCase {

    func testVersion() {
        XCTAssertEqual(StrandDesign.version, "0.1.0")
    }

    func testHexParsing() {
        let c = Color(hex: "#0B0D12").rgbaComponents
        XCTAssertEqual(c.r, 0x0B / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.g, 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.b, 0x12 / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testRecoveryGradientStops() {
        XCTAssertEqual(StrandPalette.recoveryStops.count, 3)
        XCTAssertEqual(StrandPalette.recoveryStops.first?.location, 0.0)
        XCTAssertEqual(StrandPalette.recoveryStops.last?.location, 1.0)
    }

    func testRecoveryColorEndpoints() {
        // Score 0 should equal the red start; 100 the green end.
        let low = StrandPalette.recoveryColor(0).rgbaComponents
        let indigo = StrandPalette.recovery000.rgbaComponents
        XCTAssertEqual(low.r, indigo.r, accuracy: 0.02)
        XCTAssertEqual(low.g, indigo.g, accuracy: 0.02)
        XCTAssertEqual(low.b, indigo.b, accuracy: 0.02)

        let high = StrandPalette.recoveryColor(100).rgbaComponents
        let mint = StrandPalette.recovery100.rgbaComponents
        XCTAssertEqual(high.r, mint.r, accuracy: 0.02)
        XCTAssertEqual(high.g, mint.g, accuracy: 0.02)
        XCTAssertEqual(high.b, mint.b, accuracy: 0.02)
    }

    func testRecoveryColorClamps() {
        // Out of range clamps to endpoints rather than crashing.
        let below = StrandPalette.recoveryColor(-50).rgbaComponents
        let zero = StrandPalette.recoveryColor(0).rgbaComponents
        XCTAssertEqual(below.r, zero.r, accuracy: 0.001)
        let above = StrandPalette.recoveryColor(150).rgbaComponents
        let hundred = StrandPalette.recoveryColor(100).rgbaComponents
        XCTAssertEqual(above.b, hundred.b, accuracy: 0.001)
    }

    func testRecoveryStateWords() {
        XCTAssertEqual(StrandPalette.recoveryState(10), "DEPLETED")
        XCTAssertEqual(StrandPalette.recoveryState(40), "LOW")
        XCTAssertEqual(StrandPalette.recoveryState(60), "MODERATE")
        XCTAssertEqual(StrandPalette.recoveryState(80), "PRIMED")
        XCTAssertEqual(StrandPalette.recoveryState(95), "PEAK")
    }

    func testStrainColorScaleAndEndpoints() {
        // Strain samples the 0...21 ramp; endpoints match its green and red.
        let ember = StrandPalette.strainColor(0).rgbaComponents
        let start = StrandPalette.strain000.rgbaComponents
        XCTAssertEqual(ember.r, start.r, accuracy: 0.02)
        let magenta = StrandPalette.strainColor(21).rgbaComponents
        let end = StrandPalette.strain100.rgbaComponents
        XCTAssertEqual(magenta.b, end.b, accuracy: 0.02)
    }

    private func assertHue(_ c: Color, red: Bool, green: Bool, _ note: String) {
        let v = c.rgbaComponents
        XCTAssertEqual(v.r > 0.8, red, note)
        XCTAssertEqual(v.g > 0.8, green, note)
    }

    func testRecoveryRunsRedYellowGreen() {
        assertHue(StrandPalette.recoveryColor(0), red: true, green: false, "low recovery is red")
        assertHue(StrandPalette.recoveryColor(50), red: true, green: true, "middle recovery is yellow")
        assertHue(StrandPalette.recoveryColor(100), red: false, green: true, "high recovery is green")
    }

    func testStrainRunsGreenYellowRed() {
        assertHue(StrandPalette.strainColor(0), red: false, green: true, "low strain is green")
        assertHue(StrandPalette.strainColor(10.5), red: true, green: true, "middle strain is yellow")
        assertHue(StrandPalette.strainColor(21), red: true, green: false, "high strain is red")
    }

    func testScalesAreOppositeEverywhere() {
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let r = StrandPalette.recoveryColor(p * 100).rgbaComponents, s = StrandPalette.strainColor((1 - p) * 21).rgbaComponents
            XCTAssertEqual(r.r, s.r, accuracy: 0.01); XCTAssertEqual(r.g, s.g, accuracy: 0.01); XCTAssertEqual(r.b, s.b, accuracy: 0.01)
        }
    }

    func testColorsInterpolateSmoothly() {
        // No visible jump between neighbouring whole scores.
        var prev = StrandPalette.recoveryColor(0).rgbaComponents
        for score in 1...100 {
            let c = StrandPalette.recoveryColor(Double(score)).rgbaComponents
            XCTAssertLessThan(abs(c.r - prev.r) + abs(c.g - prev.g) + abs(c.b - prev.b), 0.06, "step at \(score)")
            prev = c
        }
    }

    func testScoreTextReachesAAInBothAppearances() {
        // WCAG contrast of score text. Surfaces are written out: the adaptive tokens resolve to one appearance per test run.
        func lum(_ v: (r: Double, g: Double, b: Double)) -> Double {
            func f(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(v.r) + 0.7152 * f(v.g) + 0.0722 * f(v.b)
        }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        func surface(_ hex: String) -> Double { let c = Color(hex: hex).rgbaComponents; return lum((c.r, c.g, c.b)) }
        let dark = ["#050608", "#0F1117", "#181B23"].map(surface), light = ["#F1F3F8", "#FFFFFF"].map(surface)
        for score in stride(from: 0.0, through: 100.0, by: 2.5) {
            for c in [StrandPalette.recoveryColor(score), StrandPalette.strainColor(score * 0.21)] {
                let v = c.rgbaComponents, k = StrandPalette.scoreInkAmount
                for s in dark { XCTAssertGreaterThan(contrast(lum((v.r, v.g, v.b)), s), 4.5, "dark \(score)") }
                for s in light { XCTAssertGreaterThan(contrast(lum((v.r * k, v.g * k, v.b * k)), s), 4.5, "light \(score)") }
            }
        }
    }

    func testMissingScoreIsNotAPointOnEitherScale() {
        let m = StrandPalette.scoreMissing.rgbaComponents
        XCTAssertLessThan(max(m.r, m.g, m.b) - min(m.r, m.g, m.b), 0.15, "neutral, not a hue from the scales")
    }

    func testHRZoneColor() {
        XCTAssertEqual(StrandPalette.hrZoneColor(1).rgbaComponents.b,
                       StrandPalette.zone1.rgbaComponents.b, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.hrZoneColor(5).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
        // Clamps out-of-range.
        XCTAssertEqual(StrandPalette.hrZoneColor(99).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
    }

    func testSleepStageColorMapping() {
        XCTAssertEqual(StrandPalette.sleepStageColor(.rem).rgbaComponents.g,
                       StrandPalette.sleepREM.rgbaComponents.g, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.sleepStageColor(.awake).rgbaComponents.r,
                       StrandPalette.sleepAwake.rgbaComponents.r, accuracy: 0.001)
    }

    func testSleepStageBandRankOrdering() {
        XCTAssertEqual(SleepStage.awake.bandRank, 0)
        XCTAssertEqual(SleepStage.deep.bandRank, 3)
        XCTAssertLessThan(SleepStage.awake.bandRank, SleepStage.deep.bandRank)
    }

    func testSampleMidpointInterpolatesBetweenStops() {
        // Halfway between two black/white stops is mid-grey.
        let stops: [Gradient.Stop] = [
            .init(color: Color(hex: "#000000"), location: 0),
            .init(color: Color(hex: "#FFFFFF"), location: 1),
        ]
        let mid = StrandPalette.sample(stops: stops, at: 0.5).rgbaComponents
        XCTAssertEqual(mid.r, 0.5, accuracy: 0.03)
        XCTAssertEqual(mid.g, 0.5, accuracy: 0.03)
        XCTAssertEqual(mid.b, 0.5, accuracy: 0.03)
    }

    func testSleepIntervalDuration() {
        let i = SleepInterval(stage: .deep, start: 100, end: 460)
        XCTAssertEqual(i.duration, 360, accuracy: 0.001)
    }

    // MARK: - Chart hover toolkit

    func testNearestIndexEvenlySpaced() {
        // 5 samples across width 100 → stride 25. Cursor near each step.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 0, count: 5, width: 100), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 26, count: 5, width: 100), 1)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 60, count: 5, width: 100), 2)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 100, count: 5, width: 100), 4)
        // Out of range clamps to the ends.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: -50, count: 5, width: 100), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 999, count: 5, width: 100), 4)
    }

    func testNearestIndexEdgeCases() {
        XCTAssertNil(ChartHoverMath.nearestIndex(toX: 10, count: 0, width: 100))
        // Single sample always resolves to index 0.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 80, count: 1, width: 100), 0)
    }

    func testNearestIndexArbitraryXs() {
        let xs: [CGFloat] = [0, 30, 90, 200]
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 5, xs: xs), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 35, xs: xs), 1)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 100, xs: xs), 2)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 195, xs: xs), 3)
        XCTAssertNil(ChartHoverMath.nearestIndex(toX: 10, xs: []))
    }

    func testTooltipPlacementStaysInBounds() {
        let container = CGSize(width: 200, height: 120)
        let size = CGSize(width: 80, height: 36)
        // Anchor in the top-left corner: tooltip must clamp fully inside.
        let topLeft = ChartTooltipPlacement.position(anchor: CGPoint(x: 0, y: 0),
                                                     tooltipSize: size, in: container)
        XCTAssertGreaterThanOrEqual(topLeft.x - size.width / 2, -0.001)
        XCTAssertGreaterThanOrEqual(topLeft.y - size.height / 2, -0.001)
        XCTAssertLessThanOrEqual(topLeft.x + size.width / 2, container.width + 0.001)
        XCTAssertLessThanOrEqual(topLeft.y + size.height / 2, container.height + 0.001)

        // Anchor in the bottom-right corner: still inside.
        let bottomRight = ChartTooltipPlacement.position(anchor: CGPoint(x: 200, y: 120),
                                                         tooltipSize: size, in: container)
        XCTAssertLessThanOrEqual(bottomRight.x + size.width / 2, container.width + 0.001)
        XCTAssertLessThanOrEqual(bottomRight.y + size.height / 2, container.height + 0.001)
    }

    func testTooltipPlacementFlipsBelowWhenNoRoomAbove() {
        let container = CGSize(width: 300, height: 200)
        let size = CGSize(width: 60, height: 40)
        // Anchor near the top: with gap 12 there's no room above, so it drops below.
        let pos = ChartTooltipPlacement.position(anchor: CGPoint(x: 150, y: 5),
                                                 tooltipSize: size, in: container, gap: 12)
        XCTAssertGreaterThan(pos.y, 5)
    }

    func testTrendChartDefaultDateStringNonEmpty() {
        let s = TrendChart.defaultDateString(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(s.isEmpty)
    }

    func testSparklineDefaultValueString() {
        XCTAssertEqual(Sparkline.defaultValueString(64), "64")
        XCTAssertEqual(Sparkline.defaultValueString(64.5), "64.5")
    }
}
