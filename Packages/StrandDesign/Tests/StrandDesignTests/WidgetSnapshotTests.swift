import XCTest
import SwiftUI
@testable import StrandDesign

/// Renders a representative dashboard offscreen (light + dark) so the design can be eyeballed.
/// Output dir comes from STRAND_SNAPSHOT_DIR; skipped when unset.
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    private var sample: some View {
        let hrv = (0..<14).map { 55 + 14 * sin(Double($0) / 2.2) }
        let rec = (0..<14).map { 55 + 30 * sin(Double($0) / 3) }
        return Group {
            VStack(alignment: .leading, spacing: 24) {
                Text("Good evening").font(.system(size: 32, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                WidgetGrid(minColumn: 190) {
                    StrandWidget("Recovery", symbol: "circle.dotted.circle", tint: StrandPalette.recoveryColor(78), size: .large, action: {}) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 20) {
                                ProgressRing(fraction: 0.78, tint: StrandPalette.recoveryColor(78), lineWidth: 14) {
                                    Text("78").font(.system(size: 40, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                                }.frame(width: 132, height: 132)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Primed").font(.system(size: 22, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                                    Text("Recovery is strong and sleep was consistent.").font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            WidgetSpark(rec, tint: StrandPalette.recoveryColor(78)).frame(height: 44)
                        }
                    }
                    StrandWidget("Sleep", symbol: "bed.double.fill", tint: StrandPalette.sleepLight, size: .medium, action: {}) {
                        VStack(alignment: .leading, spacing: 8) {
                            WidgetValue("7h 42m")
                            Spacer(minLength: 0)
                            SleepStageBar(deep: 95, rem: 110, light: 250, awake: 20)
                        }
                    }
                    StrandWidget("Strain", symbol: "flame.fill", tint: StrandPalette.strain033, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue("12.4", unit: "/ 21"); Spacer(minLength: 0); WidgetCaption("Strenuous") }
                    }
                    StrandWidget("Heart rate", symbol: "heart.fill", tint: StrandPalette.metricRose, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue("62", unit: "bpm"); Spacer(minLength: 0); WidgetCaption("Live from your strap") }
                    }
                    StrandWidget("HRV", symbol: "waveform.path.ecg", tint: StrandPalette.metricPurple, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue("64", unit: "ms"); Spacer(minLength: 0); WidgetSpark(hrv, tint: StrandPalette.metricPurple).frame(height: 36) }
                    }
                    StrandWidget("Resting heart rate", symbol: "heart.fill", tint: StrandPalette.metricRose, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue("51", unit: "bpm"); Spacer(minLength: 0); WidgetSpark(hrv, tint: StrandPalette.metricRose).frame(height: 36) }
                    }
                    StrandWidget("Skin temperature", symbol: "thermometer.medium", tint: StrandPalette.metricAmber, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue("+0.3", unit: "°C"); Spacer(minLength: 0); WidgetCaption("Compared with your baseline") }
                    }
                    StrandWidget("Blood oxygen", symbol: "drop.fill", tint: StrandPalette.metricCyan, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue(nil); Spacer(minLength: 0); WidgetCaption("No data yet") }
                    }
                    StrandWidget("Strap battery", symbol: "battery.75percent", tint: StrandPalette.statusPositive, action: {}) {
                        VStack(alignment: .leading, spacing: 6) { WidgetValue("51", unit: "%"); Spacer(minLength: 0); WidgetCaption("Connected") }
                    }
                }
                StrandNotice(symbol: "sparkles", title: "Your scores are building", message: "Recovery, strain and sleep build over your next few nights of wear.")
            }
            .padding(28)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 940, height: 820)
        .background(StrandPalette.surfaceBase)
    }

    func testRenderSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["STRAND_SNAPSHOT_DIR"] else { throw XCTSkip("no dir") }
        for (name, dark) in [("light", false), ("dark", true)] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                let r = ImageRenderer(content: sample.environment(\.colorScheme, dark ? .dark : .light))
                r.scale = 1
                if let cg = r.cgImage { png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
            }
            try XCTUnwrap(png).write(to: URL(fileURLWithPath: "\(dir)/dashboard-\(name).png"))
        }
    }
}
