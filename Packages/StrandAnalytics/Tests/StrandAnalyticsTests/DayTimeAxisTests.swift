import XCTest
@testable import StrandAnalytics

/// Issue #26: one time domain for the Overview HR curve and activation strip.
final class DayTimeAxisTests: XCTestCase {
    private let ny = TimeZone(identifier: "America/New_York")!

    private func midnight(_ y: Int, _ m: Int, _ d: Int, zone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return Int(cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970)
    }

    private func bins(from: Int, to: Int, restingHR: Double = 60, hr: [(Int, Int)], sleep: [(Int, Int)] = [], workouts: [(Int, Int)] = []) -> [HRActivation.Bin] {
        HRActivation.timeline(samples: hr.map { (ts: $0.0, bpm: $0.1) }, from: from, to: to, restingHR: restingHR, maxHR: 190,
                              sleep: sleep, workouts: workouts)
    }

    /// 1 Hz readings over [a, b).
    private func readings(_ a: Int, _ b: Int, bpm: Int) -> [(Int, Int)] { stride(from: a, to: b, by: 1).map { ($0, bpm) } }

    func testPartialDayHRPointAndBinShareTheirPosition() {
        let day = 1_700_000_000 - 1_700_000_000 % 86_400
        let tenAM = day + 10 * 3600
        let axis = DayTimeAxis(start: day, end: day + 86_400, now: tenAM)
        // Readings 9:00–10:00 only (data starts late).
        let hr = readings(day + 9 * 3600, tenAM, bpm: 120)
        let runs = axis.hrRuns(hr.map { (ts: $0.0, bpm: $0.1) })
        let spans = axis.activationSpans(bins(from: day, to: tenAM, hr: hr))
        let probe = day + 9 * 3600 + 1800
        let point = DayTimeAxis.nearest(probe, in: runs)!
        let span = DayTimeAxis.span(at: point.ts, in: spans)!
        XCTAssertEqual(span.kind, .observed(.high))
        // Same timestamp → same x, independent of how much of the day has data or how many samples exist.
        XCTAssertEqual(axis.fraction(point.ts), Double(point.ts - day) / 86_400, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(axis.fraction(span.start), axis.fraction(point.ts))
        XCTAssertGreaterThan(axis.fraction(span.end), axis.fraction(point.ts))
        // 10 am sits at 10/24 of the width, not at the right edge.
        XCTAssertEqual(axis.fraction(tenAM), 10.0 / 24.0, accuracy: 1e-12)
        XCTAssertEqual(runs.last!.last!.ts < tenAM, true)
    }

    func testFutureIsUpcomingAndMissingPastIsMissing() {
        let day = 1_700_000_000 - 1_700_000_000 % 86_400
        let now = day + 10 * 3600
        let axis = DayTimeAxis(start: day, end: day + 86_400, now: now)
        // Bins computed at an earlier load (until 9:00), readings 8:00–9:00 only.
        let b = bins(from: day, to: day + 9 * 3600, hr: readings(day + 8 * 3600, day + 9 * 3600, bpm: 62))
        let spans = axis.activationSpans(b)
        XCTAssertEqual(spans.first, DayTimeAxis.Span(start: day, end: day + 8 * 3600, kind: .missing))
        XCTAssertEqual(spans[1], DayTimeAxis.Span(start: day + 8 * 3600, end: day + 9 * 3600, kind: .observed(.low)))
        // Elapsed time after the last loaded bin is missing, not calm or upcoming.
        XCTAssertEqual(spans[2], DayTimeAxis.Span(start: day + 9 * 3600, end: now, kind: .missing))
        XCTAssertEqual(spans.last, DayTimeAxis.Span(start: now, end: day + 86_400, kind: .upcoming))
        // Contiguous cover of the whole day, no level for empty time.
        for (a, c) in zip(spans, spans.dropFirst()) { XCTAssertEqual(a.end, c.start) }
        XCTAssertFalse(spans.contains { $0.kind == .observed(.sleep) })
    }

    func testGapsBreakTheCurveAndOrderDoesNotMatter() {
        let day = 0
        let axis = DayTimeAxis(start: day, end: 86_400, now: 86_400)
        var hr = readings(3600, 7200, bpm: 70) + readings(7200 + 600, 10_800, bpm: 80)   // 10-min gap
        let ordered = axis.hrRuns(hr.map { (ts: $0.0, bpm: $0.1) })
        hr.reverse(); hr.append((5000, 70))                                                // out of order + duplicate second
        let shuffled = axis.hrRuns(hr.map { (ts: $0.0, bpm: $0.1) })
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered, shuffled)
        XCTAssertLessThan(ordered[0].last!.ts, 7200)
        XCTAssertGreaterThanOrEqual(ordered[1].first!.ts, 7800)
        // Nothing is drawn inside the gap.
        XCTAssertNil(DayTimeAxis.nearest(7500, in: ordered))
        // ≤ one point per bucket.
        XCTAssertLessThanOrEqual(ordered[0].count, 3600 / DayTimeAxis.hrBucketSeconds + 1)
    }

    func testLateSyncFillsInWithoutMovingExistingPoints() {
        let axis = DayTimeAxis(start: 0, end: 86_400, now: 50_000)
        let early = readings(30_000, 31_000, bpm: 75)
        let before = axis.hrRuns(early.map { (ts: $0.0, bpm: $0.1) })
        let after = axis.hrRuns((early + readings(10_000, 11_000, bpm: 60)).map { (ts: $0.0, bpm: $0.1) })
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[1], before[0])
        XCTAssertEqual(axis.fraction(after[1][0].ts), axis.fraction(before[0][0].ts))
    }

    func testReadingsOutsideTheElapsedDayAreDropped() {
        let axis = DayTimeAxis(start: 1000, end: 2000, now: 1500)
        let runs = axis.hrRuns([(ts: 900, bpm: 70), (ts: 1200, bpm: 70), (ts: 1600, bpm: 70), (ts: 2100, bpm: 70)])
        XCTAssertEqual(runs.flatMap { $0 }.map(\.ts), [1200])
    }

    func testDSTDaysMapBinsAndTicksToTheirTrueTimes() {
        // 2026-03-08 (23 h) and 2026-11-01 (25 h) in New York.
        for (y, m, d, hours) in [(2026, 3, 8, 23), (2026, 11, 1, 25)] {
            let start = midnight(y, m, d, zone: ny)
            let end = midnight(y, m, d + 1, zone: ny)
            XCTAssertEqual(end - start, hours * 3600)
            let axis = DayTimeAxis(start: start, end: end, now: end + 10)
            let b = bins(from: start, to: end, hr: readings(start, end, bpm: 62))
            XCTAssertEqual(b.count, hours * 4)
            let spans = axis.activationSpans(b)
            XCTAssertEqual(spans, [DayTimeAxis.Span(start: start, end: end, kind: .observed(.low))])
            // Local noon tick sits at its elapsed seconds, not at 12/24 of the width.
            var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
            let noon = Int(cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: TimeInterval(start)))!.timeIntervalSince1970)
            let ticks = axis.ticks(zone: ny)
            let shift = hours == 23 ? -3600 : 3600   // the hour lost/gained at 2 am
            XCTAssertEqual(noon, start + 12 * 3600 + shift)
            XCTAssertEqual(ticks, [start, start + 6 * 3600 + shift, noon, noon + 6 * 3600, end])
            XCTAssertEqual(axis.fraction(noon), Double(noon - start) / Double(hours * 3600), accuracy: 1e-12)
            XCTAssertNotEqual(axis.fraction(noon), 0.5, accuracy: 1e-6)
        }
    }

    func testEmptyAndFutureDays() {
        let empty = DayTimeAxis(start: 0, end: 86_400, now: 40_000)
        XCTAssertTrue(empty.hrRuns([]).isEmpty)
        XCTAssertEqual(empty.activationSpans([]), [DayTimeAxis.Span(start: 0, end: 40_000, kind: .missing),
                                                   DayTimeAxis.Span(start: 40_000, end: 86_400, kind: .upcoming)])
        let future = DayTimeAxis(start: 86_400, end: 172_800, now: 40_000)
        XCTAssertEqual(future.cutoff, 86_400)
        XCTAssertEqual(future.activationSpans([]), [DayTimeAxis.Span(start: 86_400, end: 172_800, kind: .upcoming)])
        let past = DayTimeAxis(start: 0, end: 86_400, now: 500_000)
        XCTAssertFalse(past.hasUpcoming)
        XCTAssertEqual(past.activationSpans([]), [DayTimeAxis.Span(start: 0, end: 86_400, kind: .missing)])
    }

    func testSleepAndWorkoutKeepTheirKindsAndAdjacentBinsMerge() {
        let axis = DayTimeAxis(start: 0, end: 86_400, now: 86_400)
        let hr = readings(0, 86_400, bpm: 62)
        let spans = axis.activationSpans(bins(from: 0, to: 86_400, hr: hr, sleep: [(0, 6 * 3600)], workouts: [(18 * 3600, 19 * 3600)]))
        XCTAssertEqual(spans.map(\.kind), [.observed(.sleep), .observed(.low), .observed(.exercise), .observed(.low)])
        XCTAssertEqual(spans[0].end, 6 * 3600)
        XCTAssertEqual(spans[2].start, 18 * 3600)
    }

    func testActivationLabelsMatchTheLegendWording() {
        XCTAssertEqual(HRActivation.Level.low.label, "Low activation")
        XCTAssertEqual(HRActivation.Level.moderate.label, "Moderate activation")
        XCTAssertEqual(HRActivation.Level.high.label, "High activation")
        XCTAssertEqual(HRActivation.Level.sleep.label, "Asleep")
        XCTAssertEqual(HRActivation.Level.noData.label, "No data")
    }
}
