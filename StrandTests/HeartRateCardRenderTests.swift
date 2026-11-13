import XCTest
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

// Issue #26 visual harness: renders the Overview heart-rate card from synthetic days (partial day with gaps and every
// activation state, a full past day, a 25-hour DST day, unavailable activation, an empty day) at 1180/760 pt in light and
// dark. Skipped unless `NOOP_RENDER_OVERVIEW=1` (xcodebuild: `TEST_RUNNER_NOOP_RENDER_OVERVIEW=1`; optional
// `NOOP_RENDER_DIR`). PNGs are for inspection, not assertions.
@MainActor
final class HeartRateCardRenderTests: XCTestCase {
    private var out: URL!
    private let resting = 55.0, maxHR = 190.0

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOOP_RENDER_OVERVIEW"] == "1", "set NOOP_RENDER_OVERVIEW=1 to render")
        out = ProcessInfo.processInfo.environment["NOOP_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-overview-hr", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("OVERVIEW_RENDER_DIR \(out.path)")
    }

    /// A day's 1 Hz readings from (startHour, endHour, bpm, wobble) pieces; hours are offsets from the day start.
    private func readings(_ dayStart: Int, _ pieces: [(Double, Double, Int, Int)]) -> [HRSample] {
        var out: [HRSample] = []
        for (a, b, bpm, wobble) in pieces {
            let s = dayStart + Int(a * 3600), e = dayStart + Int(b * 3600)
            for t in stride(from: s, to: e, by: 1) {
                let w = wobble == 0 ? 0 : Int((sin(Double(t) / 400) * Double(wobble)).rounded())
                out.append(HRSample(ts: t, bpm: bpm + w))
            }
        }
        return out
    }

    /// Sleep 0–6.5 h, gap, calm morning, workout, raised stretch, calm, then (full days) an evening.
    private func busyDay(_ start: Int, until: Double) -> (hr: [HRSample], sleep: [(Int, Int)], workouts: [(Int, Int)]) {
        let all: [(Double, Double, Int, Int)] = [(0, 6.5, 52, 3), (7.2, 8, 72, 4), (8, 8.75, 150, 12), (8.75, 9.2, 128, 4),
                                                 (9.2, 9.7, 88, 4), (11, 13, 68, 5), (14, 15.5, 95, 8), (16, 21, 70, 6), (21, 23.5, 62, 3)]
        let clipped = all.compactMap { p -> (Double, Double, Int, Int)? in p.0 < until ? (p.0, min(p.1, until), p.2, p.3) : nil }
        return (readings(start, clipped), [(start, start + Int(6.5 * 3600))], [(start + 8 * 3600, start + Int(8.75 * 3600))])
    }

    private func bins(_ d: (hr: [HRSample], sleep: [(Int, Int)], workouts: [(Int, Int)]), from: Int, to: Int) -> [HRActivation.Bin] {
        HRActivation.timeline(samples: d.hr.map { (ts: $0.ts, bpm: $0.bpm) }, from: from, to: to, restingHR: resting, maxHR: maxHR,
                              sleep: d.sleep, workouts: d.workouts)
    }

    private func day(_ d: Date) -> String { Repository.dayString(d) }

    private func card(day: String, hr: [HRSample], now: Date, activation: ActivationAvailability, syncedThrough: Int?) -> some View {
        let profile = ProfileStore()
        let stats = DayHRStats(hr: hr, inputs: DayHRStats.Inputs(profile), restingHR: Int(resting), maxHR: maxHR)
        let metric = DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                                 disturbances: nil, restingHr: Int(resting), avgHrv: nil, recovery: nil, strain: nil,
                                 exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
        return HeartRateDayCard(day: day, metric: metric, days: [], stats: hr.isEmpty ? nil : stats, syncedThrough: syncedThrough,
                                openLive: {}, fixtureNow: now, fixtureActivation: activation)
    }

    private func render<V: View>(_ name: String, _ view: V, width: CGFloat, dark: Bool, height: CGFloat = 760) async throws {
        let repo = Repository(deviceId: "fixture", store: try await WhoopStore.inMemory())
        let root = VStack { view; Spacer(minLength: 0) }.padding(24)
            .environmentObject(repo).environmentObject(ProfileStore()).environmentObject(LiveHeartRate())
            .frame(width: width, height: height).background(StrandPalette.surfaceBase)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 150_000_000) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }

    private func both(_ name: String, _ view: some View) async throws {
        try await render("\(name)-1180-light", view, width: 1180, dark: false)
        try await render("\(name)-760-dark", view, width: 760, dark: true, height: 900)
    }

    func testRenderHeartRateCard() async throws {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let ts0 = Int(todayStart.timeIntervalSince1970)
        let tenAM = todayStart.addingTimeInterval(10 * 3600)

        // Partial day at 10 am: data starts after a gap at midnight-adjacent sleep, gap 6:30–7:12, synced to 9:42,
        // activation last loaded at 9:45.
        let partial = busyDay(ts0, until: 9.7)
        let partialBins = bins(partial, from: ts0, to: ts0 + Int(9.75 * 3600))
        let partialCard = card(day: day(todayStart), hr: partial.hr, now: tenAM, activation: .ready(partialBins), syncedThrough: ts0 + Int(9.7 * 3600))
        try await both("partial-10am", partialCard)
        try await render("partial-10am-1180-dark", partialCard, width: 1180, dark: true)
        try await render("partial-10am-760-light", partialCard, width: 760, dark: false, height: 900)

        // Full previous day.
        let yStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let y0 = Int(yStart.timeIntervalSince1970), y1 = Int(todayStart.timeIntervalSince1970)
        let full = busyDay(y0, until: 24)
        try await both("full-day", card(day: day(yStart), hr: full.hr, now: tenAM, activation: .ready(bins(full, from: y0, to: y1)), syncedThrough: ts0))

        // 25-hour day (2026-11-01, New York when the host is there; otherwise whatever the host zone does that date).
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 1
        let dst = cal.date(from: c)!, d0 = Int(dst.timeIntervalSince1970)
        let dEnd = Int(cal.date(byAdding: .day, value: 1, to: dst)!.timeIntervalSince1970)
        let dstDay = busyDay(d0, until: 24)
        try await both("dst-2026-11-01", card(day: day(dst), hr: dstDay.hr, now: tenAM, activation: .ready(bins(dstDay, from: d0, to: dEnd)), syncedThrough: ts0))

        // Activation unavailable (no resting HR yet) and an empty day.
        try await both("unavailable", card(day: day(todayStart), hr: partial.hr, now: tenAM, activation: .unavailable, syncedThrough: ts0 + Int(9.7 * 3600)))
        try await both("empty", card(day: day(todayStart), hr: [], now: tenAM, activation: .ready([]), syncedThrough: nil))
    }
}
