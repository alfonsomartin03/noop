import XCTest
import SwiftUI
@testable import NOOP

// Settings ▸ Profile card visual harness: empty optional fields and everything filled in, at 760/420 pt, light and
// dark. Hosted in an NSHostingView (ImageRenderer can't draw AppKit steppers/pickers). Uses a throwaway defaults
// suite, never the app's. Skipped unless `NOOP_RENDER_SETTINGS=1` (xcodebuild: `TEST_RUNNER_NOOP_RENDER_SETTINGS=1`).
@MainActor
final class ProfileCardRenderTests: XCTestCase {
    private var out: URL!
    private let suite = "noop.render.profileCard"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOOP_RENDER_SETTINGS"] == "1", "set NOOP_RENDER_SETTINGS=1 to render")
        out = FileManager.default.temporaryDirectory.appendingPathComponent("noop-profile-card", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        print("SETTINGS_RENDER_DIR \(out.path)")
    }

    override func tearDown() async throws { UserDefaults().removePersistentDomain(forName: suite) }

    private func render(_ name: String, _ profile: ProfileStore) throws {
        for (width, dark) in [(760.0, false), (760, true), (420, false)] {
            let view = ProfileCard(profile: profile)
                .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 10))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.display()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("\(name)-\(Int(width))-\(dark ? "dark" : "light").png"))
        }
    }

    func testRenderStates() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let empty = ProfileStore(defaults: d)
        try render("empty", empty)
        let full = ProfileStore(defaults: d)
        full.age = 38
        full.birthDate = Calendar.current.date(from: DateComponents(year: 1988, month: 4, day: 12))
        full.measuredVO2 = 46.5
        full.measuredVO2Date = Calendar.current.date(byAdding: .month, value: -3, to: Date())!
        full.hrMaxOverride = 186
        try render("filled", full)
    }
}

/// Age follows the birth date when one is set (throwaway defaults suite).
@MainActor
final class ProfileStoreAgeTests: XCTestCase {
    func testAgeFollowsBirthDate() throws {
        let suite = "noop.test.profileAge"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let p = ProfileStore(defaults: d)
        p.age = 30
        let cal = Calendar.current
        p.birthDate = cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: .year, value: -41, to: Date())!)
        XCTAssertEqual(p.age, 41)
        // The day before the next birthday it is still 41; on it, 42.
        let next = cal.date(byAdding: .year, value: 42, to: p.birthDate!)!
        p.syncAgeFromBirthDate(now: cal.date(byAdding: .hour, value: -1, to: next)!)
        XCTAssertEqual(p.age, 41)
        p.syncAgeFromBirthDate(now: cal.date(byAdding: .hour, value: 1, to: next)!)
        XCTAssertEqual(p.age, 42)
        // A fresh store (a relaunch today) re-derives the age from the stored date.
        XCTAssertEqual(ProfileStore(defaults: d).age, 41)
        // Removing the birth date keeps the last age.
        p.birthDate = nil
        XCTAssertEqual(p.age, 42)
        // An implausible date (age outside 13–100) leaves the age alone.
        p.birthDate = cal.date(byAdding: .year, value: -5, to: Date())
        XCTAssertEqual(p.age, 42)
    }
}
