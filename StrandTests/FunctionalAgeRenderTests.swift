import XCTest
import SwiftUI
import StrandAnalytics
@testable import NOOP

// #49 visual harness: the Health functional-age hero in its states (ready with each sign, calibrating with reasons,
// loading) at 1180/760/420 pt in light and dark, from synthetic summaries (no preferences or store touched). Skipped
// unless `NOOP_RENDER_HEALTH=1` (xcodebuild: `TEST_RUNNER_NOOP_RENDER_HEALTH=1`; optional `NOOP_RENDER_DIR`).
@MainActor
final class FunctionalAgeRenderTests: XCTestCase {
    private var out: URL!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOOP_RENDER_HEALTH"] == "1", "set NOOP_RENDER_HEALTH=1 to render")
        out = ProcessInfo.processInfo.environment["NOOP_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-health-age", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("HEALTH_RENDER_DIR \(out.path)")
    }

    private func summary(rhrOld: Double, rhrRecent: Double, sleep: Double, vo2: Double?) -> FunctionalAgeSnapshot.Summary {
        let cal = Calendar.current, asOf = Date()
        let days = (1...200).map { b -> FunctionalAgeSnapshot.Day in
            let d = cal.date(byAdding: .day, value: -b, to: cal.startOfDay(for: asOf))!
            return FunctionalAgeSnapshot.Day(day: Repository.dayString(d),
                                             restingHR: .init(value: b <= 30 ? rhrRecent : rhrOld, imported: false),
                                             sleepHours: .init(value: sleep, imported: false))
        }
        let birth = cal.date(byAdding: .year, value: -38, to: asOf)!
        return FunctionalAgeSnapshot.summarize(
            days: days, birth: birth, asOf: asOf, calendar: cal,
            measuredVO2: vo2.map { .init(value: $0, method: "Lab test (CPET)", testedAt: cal.date(byAdding: .month, value: -2, to: asOf)!) })
    }

    private func render(_ name: String, _ s: FunctionalAgeSnapshot.Summary?, chronological: Double?) throws {
        for (width, scheme) in [(1180.0, ColorScheme.light), (760, .dark), (420, .light)] {
            let view = FunctionalAgeHeroCard(summary: s, chronological: chronological)
                .padding(20).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            let img = try XCTUnwrap(r.nsImage)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("\(name)-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    func testRenderStates() throws {
        try render("ready-younger", summary(rhrOld: 52, rhrRecent: 50, sleep: 7.5, vo2: 46), chronological: 38)
        try render("ready-older", summary(rhrOld: 78, rhrRecent: 84, sleep: 5.5, vo2: 24), chronological: 38)
        try render("calibrating", summary(rhrOld: 60, rhrRecent: 60, sleep: 7.5, vo2: nil), chronological: 38)
        try render("calibrating-no-birth", FunctionalAgeSnapshot.summarize(days: [], birth: nil, asOf: Date(), calendar: .current),
                   chronological: nil)
        try render("loading", nil, chronological: nil)
    }
}
