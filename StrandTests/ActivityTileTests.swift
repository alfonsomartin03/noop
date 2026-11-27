import XCTest
import SwiftUI
import StrandAnalytics
import WhoopProtocol
@testable import NOOP

// #86: the Strain-detail Walking & running and Steps tiles (#83) in their complete, partial, today and no-data states.
// Spoken-label tests always run (they check the text VoiceOver is given; VoiceOver itself is a manual check). Renders at 1180/760/420 pt in light and dark run only with
// `NOOP_RENDER_ACTIVITY=1` (xcodebuild: `TEST_RUNNER_NOOP_RENDER_ACTIVITY=1`; optional `NOOP_RENDER_DIR`).
@MainActor
final class ActivityTileTests: XCTestCase {
    private let d0 = 1_793_592_000, day = 86_400

    private func s(_ dt: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: d0 + dt, counter: c, activity: a) }
    private func known(_ ranges: Range<Int>...) -> [Range<Int>] {
        StepCounterSample.knownRuns(ranges.flatMap { r in r.map { d0 + $0 } })
    }
    private func state(_ rows: [StepCounterSample], until: Int, known k: [Range<Int>], now: Int? = nil)
        -> (ActivityCoverage, StepCounterSample.Window) {
        let w = StepCounterSample.window(rows, from: d0, to: d0 + day, until: d0 + until, known: k)
        let now = Date(timeIntervalSince1970: TimeInterval(d0 + (now ?? 2 * day)))
        return (StrainDetailView.activity(w, day: (d0, d0 + day), now: now)!, w)
    }

    /// Past day, fully synced: exact totals, no "at least".
    private var complete: (ActivityCoverage, StepCounterSample.Window) {
        state([s(-60, 500, 0), s(3600, 500, 1), s(4800, 2_000, 2), s(5400, 3_000, 0)], until: day + 60, known: known(-60..<(day + 60)))
    }
    /// Past day with a 6 h unsynced morning and an alarm-linked reset: lower bounds.
    private var partial: (ActivityCoverage, StepCounterSample.Window) {
        state([s(-7200, 9_000, 1), s(6 * 3600, 3, 1), s(6 * 3600 + 600, 900, 0)], until: day, known: known((6 * 3600)..<day))
    }
    /// Today 09:00, synced through 08:40, no walking yet.
    private var today: (ActivityCoverage, StepCounterSample.Window) {
        state([s(-60, 0, 0), s(3600, 40, 0)], until: 8 * 3600 + 2400, known: known(-60..<(8 * 3600 + 2400)), now: 9 * 3600)
    }

    func testSpokenLabelsSayAtLeastAndNeverUseUnitAbbreviations() throws {
        let p = partial
        let a = try XCTUnwrap(StrainDetailView.activityTile(p.0).spokenLabel)
        XCTAssertTrue(a.hasPrefix("Walking & running, at least 10 minutes, Over 18 hours synced of 24 hours, experimental"), a)
        XCTAssertTrue(a.contains("No synced data for 6 hours; activity there is unknown."), a)
        XCTAssertTrue(a.contains("Totals are at least these"), a)
        let st = try XCTUnwrap(StrainDetailView.stepsTile(p.1).spokenLabel)
        XCTAssertTrue(st.hasPrefix("Steps, at least 897 steps, Recorded strap increases"), st)
        XCTAssertTrue(st.contains("No synced data for 6 hours"), st)
        for label in [a, st, StrainDetailView.activityTile(complete.0).spokenLabel!, StrainDetailView.activityTile(today.0).spokenLabel!] {
            XCTAssertFalse(label.contains("≥"), label)
            XCTAssertNil(label.range(of: #"\d+[hm]\b"#, options: .regularExpression), "abbreviated duration in: \(label)")
        }
        let full = try XCTUnwrap(StrainDetailView.activityTile(complete.0).spokenLabel)
        XCTAssertTrue(full.hasPrefix("Walking & running, 30 minutes, Over 24 hours synced of 24 hours, experimental, Walking 20 minutes, Running 10 minutes"), full)
        let t = try XCTUnwrap(StrainDetailView.activityTile(today.0).spokenLabel)
        XCTAssertTrue(t.contains("so far") && t.contains("No walking or running recorded.") && !t.contains("at least"), t)
    }

    func testRenderStates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOOP_RENDER_ACTIVITY"] == "1", "set NOOP_RENDER_ACTIVITY=1 to render")
        let out = ProcessInfo.processInfo.environment["NOOP_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-activity", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("ACTIVITY_RENDER_DIR \(out.path)")
        for (name, st) in [("complete", complete), ("partial", partial), ("today", today)] {
            for (width, scheme) in [(1180.0, ColorScheme.light), (760, .dark), (420, .light), (420, .dark)] {
                let view = DetailGrid { StrainDetailView.activityTile(st.0); StrainDetailView.stepsTile(st.1) }
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
    }
}
