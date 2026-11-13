import XCTest
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore
@testable import NOOP

// Issue #18: the Trends audit. Two parts:
//  - `TrendWindowTests`: for every range, what is plotted and compared is exactly the stored days in that window —
//    missing days stay missing, comparison periods are adjacent, equal and completed, sparse data widens visibly.
//  - `TrendsRenderTests`: renders every Trends section at every range from SYNTHETIC data (no health records) to PNG
//    files for visual inspection. Skipped unless `NOOP_RENDER_TRENDS=1` (xcodebuild: `TEST_RUNNER_NOOP_RENDER_TRENDS=1`; optional `NOOP_RENDER_DIR`).

enum TrendsFixture {
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static func day(_ back: Int, from anchor: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: anchor.addingTimeInterval(-Double(back) * 86_400))
    }
    /// Yesterday (UTC midnight): every fixture day is a completed day.
    static var anchor: Date { utc.startOfDay(for: Date()).addingTimeInterval(-86_400) }

    /// `count` days ending at the anchor. Days in `missing` (days back) have no row; every 9th row lacks SpO₂/skin
    /// temperature and every 23rd lacks the scores, so "missing field" and "missing day" both occur.
    static func days(_ count: Int, missing: Set<Int> = [], noop: Bool = false) -> [DailyMetric] {
        (0..<count).reversed().compactMap { back -> DailyMetric? in
            if missing.contains(back) { return nil }
            let p = Double(count - back)
            let hole = Int(p) % 23 == 0
            return DailyMetric(day: day(back, from: anchor),
                               totalSleepMin: 430 + 55 * sin(p / 6) , efficiency: 88 + 6 * sin(p / 5),
                               deepMin: 85 + 20 * sin(p / 4), remMin: 100 + 25 * cos(p / 7), lightMin: 230 + 30 * sin(p / 3),
                               disturbances: 4 + Int(p) % 5, restingHr: hole ? nil : Int((52 + 4 * sin(p / 7)).rounded()),
                               avgHrv: hole ? nil : 58 + 16 * sin(p / 9), recovery: hole ? nil : max(2, min(99, 55 + 30 * sin(p / 11))),
                               strain: hole ? nil : max(0, min(21, 10 + 6 * sin(p / 5 + 1.2))), exerciseCount: Int(p) % 3 == 0 ? 1 : 0,
                               spo2Pct: Int(p) % 9 == 0 ? nil : 95.5 + sin(p / 8),
                               skinTempDevC: Int(p) % 9 == 0 ? nil : (noop ? 0.3 * sin(p / 6) : 33.4 + 0.5 * sin(p / 6)),
                               respRateBpm: 14.5 + 0.8 * sin(p / 10))
        }
    }
    /// A 9-day hole two months back plus scattered single days.
    static let gaps: Set<Int> = Set(55...63).union([3, 17, 18, 40, 120, 121, 200, 300])

    static func workouts(_ n: Int) -> [WorkoutRow] {
        let sports = ["Running", "Functional Fitness / High-Intensity Interval Training (Outdoor, Coached)", "Cycling", "Weightlifting", "Activity"]
        return (0..<n).map { i in
            let start = Int(anchor.timeIntervalSince1970) - i * 3 * 86_400 + 17 * 3600
            return WorkoutRow(startTs: start, endTs: start + 2400 + (i % 4) * 900, sport: sports[i % sports.count], source: i % 2 == 0 ? "whoop" : "noop",
                              durationS: Double(2400 + (i % 4) * 900), energyKcal: 320 + Double(i % 7) * 45, avgHr: 128 + i % 20, maxHr: 165 + i % 18,
                              strain: 8 + Double(i % 9), distanceM: i % 5 == 0 ? 6200 : nil, zonesJSON: nil, notes: nil)
        }
    }
    static func apple(_ n: Int) -> [AppleDaily] {
        (0..<n).map { AppleDaily(day: day($0, from: anchor), steps: 6000 + ($0 * 733) % 7000, activeKcal: 380 + Double(($0 * 37) % 300), basalKcal: 1650,
                                 vo2max: nil, avgHr: 68, maxHr: 150, walkingHr: 95, weightKg: nil) }
    }
    /// Real `DayLoadRecord`s from the engine over synthetic heart rate (zone seconds for the Activity zone card).
    static func loads(_ n: Int) -> [DayLoadRecord] {
        (0..<n).compactMap { i in
            let d = day(i, from: anchor)
            guard let r = ZoneTimeline.shared.dayRange(d) else { return nil }
            var hr: [HRSample] = []
            for s in stride(from: 8 * 3600, to: 20 * 3600, by: 5) {
                let bpm = s > 17 * 3600 && s < 18 * 3600 ? 120 + (s / 60 + i * 7) % 60 : 62 + (s / 300 + i) % 25
                hr.append(HRSample(ts: r.from + s, bpm: bpm))
            }
            return AnalyticsEngine.analyzeDay(day: d, hr: hr, profile: UserProfile(age: 30), dayRange: r).load
        }
    }
    static func highlights(days n: Int, performance: Bool) -> HighlightInputs {
        let rows = days(n, missing: gaps)
        func s(_ v: (DailyMetric) -> Double?) -> [(day: String, value: Double)] { rows.compactMap { r in v(r).map { (r.day, $0) } } }
        return HighlightInputs(sleepPerformance: performance ? s { $0.efficiency.map { min(100, $0 + 4) } } : [],
                               recovery: s { $0.recovery.map { ($0 / 5).rounded() * 5 } },      // rounded: ties occur
                               strain: s { $0.strain }, restingHR: s { $0.restingHr.map(Double.init) }, hrv: s { $0.avgHrv })
    }
}

final class TrendWindowTests: XCTestCase {
    private let anchor = TrendsFixture.anchor
    private var days: [DailyMetric] { TrendsFixture.days(420, missing: TrendsFixture.gaps) }

    func testEveryRangePlotsExactlyTheStoredDaysInItsWindow() {
        let all = days
        for range in TrendRange.allCases {
            let s = TrendWindow.series(all, { $0.recovery }, range: range, anchor: anchor)
            let expected = all.filter { d in
                guard d.recovery != nil, let dt = TrendWindow.date(d.day) else { return false }
                guard let n = range.days else { return true }
                return dt >= anchor.addingTimeInterval(-Double(n - 1) * 86_400)
            }
            XCTAssertEqual(s.points.count, expected.count, "\(range.label)")
            XCTAssertEqual(s.points.map(\.value), expected.compactMap(\.recovery), "\(range.label): values are the stored ones, in order")
            XCTAssertFalse(s.widened, range.label)
            XCTAssertEqual(s.effective, range)
            // A missing day is absent, never a zero or a carried value.
            let plotted = Set(s.points.map(\.date))
            for back in TrendsFixture.gaps where range.days.map({ back < $0 }) ?? true {
                XCTAssertFalse(plotted.contains(anchor.addingTimeInterval(-Double(back) * 86_400)), "\(range.label): day −\(back) has no row")
            }
            XCTAssertFalse(s.points.contains { $0.value == 0 })
            XCTAssertTrue(s.caption.contains(range.name), s.caption)
        }
    }

    func testMissingFieldIsMissingForThatMetricOnly() {
        let all = days
        let spo2 = TrendWindow.series(all, { $0.spo2Pct }, range: .quarter, anchor: anchor)
        let resp = TrendWindow.series(all, { $0.respRateBpm }, range: .quarter, anchor: anchor)
        XCTAssertLessThan(spo2.points.count, resp.points.count)
        XCTAssertEqual(resp.points.count, all.filter { TrendWindow.date($0.day)! >= anchor.addingTimeInterval(-89 * 86_400) }.count)
    }

    func testMissingDaysBreakTheLine() {
        let s = TrendWindow.series(days, { $0.totalSleepMin }, range: .quarter, anchor: anchor)
        let runs = TrendChart.runs(s.points, maxGap: TrendWindow.dailyGap)
        XCTAssertEqual(runs.count, s.points.count, "every point belongs to exactly one run")
        XCTAssertGreaterThan(Set(runs).count, 1, "the holes split the line")
        for i in s.points.indices.dropFirst() {
            let step = s.points[i].date.timeIntervalSince(s.points[i - 1].date)
            XCTAssertEqual(runs[i] == runs[i - 1], step <= TrendWindow.dailyGap, "a line joins two points only when no day is missing between them")
        }
    }

    func testComparisonPeriodsAreAdjacentEqualAndCompletedForEveryRange() {
        let all = days
        for range in TrendRange.allCases {
            let s = TrendWindow.series(all, { $0.avgHrv }, range: range, anchor: anchor)
            let c = TrendWindow.change(all, { $0.avgHrv }, series: s, anchor: anchor, unit: "ms", tolerance: 1) { String(format: "%.0f", $0) }
            guard let n = range.days else { XCTAssertNil(c, "all history has nothing to compare with"); continue }
            let cmp = try! XCTUnwrap(c).comparison
            XCTAssertEqual(cmp.days, n)
            XCTAssertEqual(cmp.currentEnd, anchor, "\(range.label): ends at the latest completed day")
            XCTAssertEqual(cmp.currentStart, anchor.addingTimeInterval(-Double(n - 1) * 86_400))
            XCTAssertEqual(cmp.previousEnd, cmp.currentStart.addingTimeInterval(-86_400), "previous period ends the day before")
            XCTAssertEqual(cmp.previousStart, cmp.previousEnd.addingTimeInterval(-Double(n - 1) * 86_400))
            let inCurrent = all.filter { $0.avgHrv != nil && TrendWindow.date($0.day)! >= cmp.currentStart && TrendWindow.date($0.day)! <= cmp.currentEnd }
            XCTAssertEqual(cmp.currentCount, inCurrent.count, "\(range.label): only days with a value are counted")
            if let m = cmp.currentMean { XCTAssertEqual(m, inCurrent.compactMap(\.avgHrv).reduce(0, +) / Double(inCurrent.count), accuracy: 1e-9) }
        }
        // 420 days of history: the 1Y comparison's previous year is mostly absent → insufficient, not a zero baseline.
        let year = TrendWindow.series(all, { $0.avgHrv }, range: .year, anchor: anchor)
        let c = TrendWindow.change(all, { $0.avgHrv }, series: year, anchor: anchor, unit: "ms", tolerance: 1) { "\($0)" }
        XCTAssertEqual(c?.comparison.direction, .insufficient)
        XCTAssertEqual(c?.text, "Not enough data to compare")
    }

    func testInProgressTodayIsLeftOutOfTheComparison() {
        let today = TrendsFixture.utc.startOfDay(for: Date())
        var all = days
        all.append(DailyMetric(day: TrendsFixture.day(0, from: today), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                               disturbances: nil, restingHr: nil, avgHrv: 500, recovery: nil, strain: nil, exerciseCount: nil))
        // `TrendWindow.change` takes "today" from the local calendar; only assert when it is the same date as UTC's.
        try? XCTSkipUnless(AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970)) == TrendsFixture.day(0, from: today))
        let s = TrendWindow.series(all, { $0.avgHrv }, range: .week, anchor: today)
        let c = TrendWindow.change(all, { $0.avgHrv }, series: s, anchor: today, unit: "ms", tolerance: 1) { "\($0)" }
        XCTAssertEqual(c?.comparison.currentEnd, today.addingTimeInterval(-86_400))
        XCTAssertLessThan(c?.comparison.currentMean ?? 999, 100, "today's partial value is not averaged in")
    }

    func testSparseAndEmptyDataWidenOrStayEmpty() {
        let sparse = TrendsFixture.days(200, missing: Set(0..<200).subtracting([40, 41, 90, 150, 199]))
        let last = TrendWindow.date(sparse.last!.day)
        let week = TrendWindow.series(sparse, { $0.totalSleepMin }, range: .week, anchor: last)
        XCTAssertEqual(week.points.count, 2); XCTAssertFalse(week.widened)
        // Anchored at the true latest day, a window with nothing widens and says so.
        let w = TrendWindow.series(sparse, { $0.totalSleepMin }, range: .week, anchor: anchor)
        XCTAssertTrue(w.widened)
        XCTAssertEqual(w.effective, .quarter)
        XCTAssertTrue(w.caption.contains("sparse — widened to 3 months"), w.caption)
        let none = TrendWindow.series([], { $0.totalSleepMin }, range: .month, anchor: nil)
        XCTAssertTrue(none.points.isEmpty); XCTAssertFalse(none.canDraw)
        XCTAssertEqual(none.caption, "No readings stored")
        XCTAssertNil(none.mean, "no data has no average (not 0)")
    }

    func testRangeLabelsAndSpokenNames() {
        XCTAssertEqual(TrendRange.allCases.map(\.label), ["W", "M", "3M", "6M", "1Y", "ALL"])
        XCTAssertEqual(TrendRange.allCases.map(\.subtitle), ["Trailing 7 days", "Trailing 30 days", "Trailing 90 days", "Trailing 180 days", "Trailing 365 days", "All history"])
        XCTAssertEqual(Set(TrendRange.allCases.map(\.name)).count, 6)
    }
}

@MainActor
final class TrendsRenderTests: XCTestCase {
    private var out: URL!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOOP_RENDER_TRENDS"] == "1", "set NOOP_RENDER_TRENDS=1 to render")
        // The sandboxed test host can only write inside its container; an unsandboxed run (CODE_SIGNING_ALLOWED=NO) may
        // name another folder with NOOP_RENDER_DIR.
        out = ProcessInfo.processInfo.environment["NOOP_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-trends-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("TRENDS_RENDER_DIR \(out.path)")
    }

    private func repo(days: [DailyMetric], imported: [DailyMetric] = [], noop: [DailyMetric] = []) async throws -> Repository {
        let r = Repository(deviceId: "fixture", store: try await WhoopStore.inMemory())
        r.days = days; r.loaded = true
        r.official = Dictionary(imported.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        r.estimates = Dictionary(noop.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        r.officialDays = Set(imported.map(\.day))
        return r
    }

    /// Offscreen render, cut into `tile`-point-high PNGs so text stays legible.
    private func render<V: View>(_ name: String, _ view: V, repo: Repository, width: CGFloat = 1180, height: CGFloat = 2200,
                                 dark: Bool = false, reduceMotion: Bool = false, tile: CGFloat = 1100) async throws {
        let root = view.environmentObject(repo).environmentObject(ProfileStore())
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
        guard let cg = rep.cgImage else { return XCTFail("no image") }
        let scale = CGFloat(cg.height) / height
        var y: CGFloat = 0, i = 0
        while y < height {
            let h = min(tile, height - y)
            if let part = cg.cropping(to: CGRect(x: 0, y: y * scale, width: CGFloat(cg.width), height: h * scale)),
               let png = NSBitmapImageRep(cgImage: part).representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("\(name)-\(i).png"))
            }
            y += h; i += 1
        }
        window.contentView = nil
    }

    func testRenderEveryTrendsSectionAndRange() async throws {
        let full = TrendsFixture.days(420, missing: TrendsFixture.gaps)
        let noop = TrendsFixture.days(60, missing: [5, 6], noop: true)
        let r = try await repo(days: full, imported: full, noop: noop)
        let workouts = TrendsFixture.workouts(40), apple = TrendsFixture.apple(60), loads = TrendsFixture.loads(10)
        for range in TrendRange.allCases {
            let tag = range.label
            try await render("scores-\(tag)", TrendsView(initialRange: range), repo: r, height: 2600)
            try await render("sleep-\(tag)", SleepTrendsContent(days: full, loaded: true, initialRange: range), repo: r)
            try await render("vitals-\(tag)", VitalsTrendsContent(days: full, loaded: true, importedDays: full, noopDays: noop, initialRange: range), repo: r, height: 2600)
            try await render("activity-\(tag)", ActivityTrendsContent(days: full, workouts: workouts, apple: apple, loads: loads, loaded: true, initialRange: range), repo: r, height: 2600)
        }
        // Narrow + dark on non-default ranges.
        try await render("scores-6M-narrow-dark", TrendsView(initialRange: .half), repo: r, width: 760, height: 3000, dark: true)
        try await render("sleep-W-narrow-dark", SleepTrendsContent(days: full, loaded: true, initialRange: .week), repo: r, width: 760, height: 2600, dark: true)
        try await render("vitals-1Y-narrow-dark", VitalsTrendsContent(days: full, loaded: true, importedDays: full, noopDays: noop, initialRange: .year), repo: r, width: 760, height: 3200, dark: true)
        try await render("activity-ALL-narrow-dark", ActivityTrendsContent(days: full, workouts: workouts, apple: apple, loads: loads, loaded: true, initialRange: .all), repo: r, width: 760, height: 3200, dark: true)
    }

    /// Nested surfaces the top-of-page renders can't reach (#18 completion guide): Activity ▸ Sessions + a workout detail
    /// with a long label, Vitals ▸ Live, populated Recent cycles, Highlights' supporting-day sheet.
    func testRenderNestedSurfaces() async throws {
        let full = TrendsFixture.days(60)
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "fixture", mac: nil, name: "WHOOP")
        _ = try await store.upsertDailyMetrics(full, deviceId: "fixture")
        var points: [MetricPoint] = []
        for (i, d) in full.suffix(7).enumerated() {
            guard let r = ZoneTimeline.shared.dayRange(d.day) else { continue }
            let start = Double(r.from - 3600)
            points += [MetricPoint(day: d.day, key: "cycle_start_ts", value: start),
                       MetricPoint(day: d.day, key: "cycle_end_ts", value: start + 86_400 + Double(i * 600)),
                       MetricPoint(day: d.day, key: "cycle_tz_min", value: -300)]
            if let v = d.recovery { points.append(MetricPoint(day: d.day, key: "recovery", value: v)) }
            if let v = d.strain { points.append(MetricPoint(day: d.day, key: "strain", value: v)) }
            if let v = d.totalSleepMin { points.append(MetricPoint(day: d.day, key: "sleep_total_min", value: v)) }
        }
        _ = try await store.upsertMetricSeries(points, deviceId: "fixture")
        let r = Repository(deviceId: "fixture", store: store)
        r.days = full; r.loaded = true
        r.official = Dictionary(full.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a }); r.officialDays = Set(full.map(\.day))
        r.sleeps = full.suffix(14).compactMap { d in
            guard let range = ZoneTimeline.shared.dayRange(d.day), let total = d.totalSleepMin else { return nil }
            let stages = "{\"light\":\(Int(total * 0.55)),\"deep\":\(Int(total * 0.2)),\"rem\":\(Int(total * 0.25)),\"awake\":30}"
            return CachedSleepSession(startTs: range.from - 2 * 3600, endTs: range.from - 2 * 3600 + Int(total * 60) + 1800,
                                      efficiency: d.efficiency, restingHr: d.restingHr, avgHrv: d.avgHrv, stagesJSON: stages)
        }
        let workouts = TrendsFixture.workouts(12)
        _ = try await store.upsertWorkouts(workouts.filter { $0.source == "whoop" }, deviceId: "fixture")
        _ = try await store.upsertWorkouts(workouts.filter { $0.source == "noop" }, deviceId: "fixture-noop")
        try await render("nested-activity-sessions", WorkoutsView(previewRows: workouts), repo: r, height: 1800)
        try await render("nested-activity-sessions-760-dark", WorkoutsView(previewRows: workouts), repo: r, width: 760, height: 1800, dark: true)
        if let long = workouts.first(where: { $0.sport.count > 40 && $0.source == "whoop" }) {   // NOOP-detected rows carry no sport
            try await render("nested-workout-detail-long-label", WorkoutDetailView(workout: long), repo: r, width: 760, height: 1600)
        }
        // Sleep ▸ Last night (`SleepView`) embeds `SleepSessionsCard`, which needs the full `AppModel` (BLE + store); it is
        // checked in the fixture app (`NOOP_FIXTURE_STORE`), not here.
        try await render("nested-vitals-live", HealthView().environmentObject(LiveHeartRate()).environmentObject(LiveState()), repo: r, height: 1800)
        try await render("nested-recent-cycles", ScrollView { RecentCyclesCard().padding() }, repo: r, width: 760, height: 900)
        try await render("nested-highlights-supporting-day",
                         SupportingDaySheet(item: SupportingDay(day: full[full.count - 3].day, source: .whoop, title: "Peak recovery")),
                         repo: r, width: 620, height: 900)
    }

    func testRenderSparseAndEmptyStates() async throws {
        let sparse = TrendsFixture.days(200, missing: Set(0..<200).subtracting([0, 1, 40, 41, 90, 150, 199]))
        let rs = try await repo(days: sparse, noop: sparse)
        try await render("sparse-scores-M", TrendsView(initialRange: .month), repo: rs)
        try await render("sparse-sleep-W", SleepTrendsContent(days: sparse, loaded: true, initialRange: .week), repo: rs)
        try await render("sparse-vitals-M", VitalsTrendsContent(days: sparse, loaded: true, noopDays: sparse, initialRange: .month), repo: rs)
        try await render("sparse-activity-M", ActivityTrendsContent(days: sparse, workouts: TrendsFixture.workouts(2), apple: [], loaded: true, initialRange: .month), repo: rs)
        let re = try await repo(days: [])
        try await render("empty-scores", TrendsView(), repo: re, height: 700)
        try await render("empty-sleep", SleepTrendsContent(days: [], loaded: true), repo: re, height: 700)
        try await render("empty-vitals", VitalsTrendsContent(days: [], loaded: true), repo: re, height: 700)
        try await render("empty-activity", ActivityTrendsContent(days: [], workouts: [], apple: [], loaded: true), repo: re, height: 700)
        try await render("empty-highlights", HighlightsContent(inputs: [:], range: .constant(.month1), sourceRaw: .constant("")), repo: re, height: 700)
    }

    func testRenderHighlightsRangesAndSources() async throws {
        let r = try await repo(days: TrendsFixture.days(30))
        let inputs: [HighlightSource: HighlightInputs] = [.whoop: TrendsFixture.highlights(days: 420, performance: true),
                                                          .noop: TrendsFixture.highlights(days: 45, performance: false)]
        for range in HighlightRange.allCases {
            for source in HighlightSource.allCases {
                try await render("highlights-\(range.rawValue.replacingOccurrences(of: " ", with: ""))-\(source.rawValue)",
                                 HighlightsContent(inputs: inputs, range: .constant(range), sourceRaw: .constant(source.rawValue)), repo: r, height: 1800)
            }
        }
        try await render("highlights-3M-noop-narrow-dark", HighlightsContent(inputs: inputs, range: .constant(.month3), sourceRaw: .constant("noop")),
                         repo: r, width: 760, height: 2200, dark: true)
        try await render("highlights-1M-noop-only", HighlightsContent(inputs: [.noop: TrendsFixture.highlights(days: 10, performance: false)],
                                                                      range: .constant(.month3), sourceRaw: .constant("")), repo: r, height: 1800)
    }
}
