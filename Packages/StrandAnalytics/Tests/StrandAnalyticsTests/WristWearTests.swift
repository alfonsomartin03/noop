import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Strap-reported off-wrist intervals (events 10 → 9) and where NOOP uses them (issue #25, C02a).
final class WristWearTests: XCTestCase {
    private func ev(_ ts: Int, _ n: Int, kind: String? = nil, asDouble: Bool = false) -> WhoopEvent {
        WhoopEvent(ts: ts, kind: kind ?? Whoop5EventKind(n).name,
                   payload: ["event": asDouble ? .double(Double(n)) : .int(n), "body": .string("")])
    }

    func testPairsOffWithTheNextOnAndReadsOldUnnamedRows() {
        // Stored before the events were named (EVENT_10/EVENT_9), plus noise events.
        let events = [ev(100, 10, kind: "EVENT_10"), ev(150, 29), ev(220, 9, kind: "EVENT_9"),
                      ev(1_000, 10), ev(1_060, 10), ev(1_300, 9, asDouble: true), ev(2_000, 9)]
        let iv = WristWear.offIntervals(events, until: 5_000)
        XCTAssertEqual(iv, [.init(start: 100, end: 220, openEnded: false),
                            .init(start: 1_000, end: 1_300, openEnded: false)])   // repeated off keeps the earliest; stray on ignored
    }

    func testOpenIntervalEndsAtKnownDataOrIsDropped() {
        let events = [ev(500, 10), ev(100, 9)]   // any order
        XCTAssertEqual(WristWear.offIntervals(events, until: 900), [.init(start: 500, end: 900, openEnded: true)])
        XCTAssertEqual(WristWear.offIntervals(events, until: nil), [], "nothing claimed past what is known")
        XCTAssertEqual(WristWear.offIntervals(events, until: 400), [])
    }

    func testSameSecondOffBeforeOn() {
        XCTAssertEqual(WristWear.offIntervals([ev(300, 9), ev(300, 10), ev(360, 9)], until: nil),
                       [.init(start: 300, end: 360, openEnded: false)])
    }

    func testSecondsClipAndCountOverlapsOnce() {
        let iv: [WristWear.OffInterval] = [.init(start: 0, end: 100, openEnded: false), .init(start: 50, end: 200, openEnded: false),
                                           .init(start: 500, end: 600, openEnded: true)]
        XCTAssertEqual(WristWear.seconds(iv, from: 20, to: 550), 180 + 50)
        XCTAssertTrue(WristWear.contains(iv, 520))
        XCTAssertFalse(WristWear.contains(iv, 600))
    }

    // MARK: uses

    func testSkinTemperatureIgnoresOffWristSamples() throws {
        let stages = [StageSegment(start: 0, end: 7_200, stage: "light")]
        // Off the wrist for the second hour, reading room temperature (28 °C) — inside the 5–45 °C decode gate.
        let samples = (0..<7_200).map { SkinTempSample(ts: $0, raw: $0 < 3_600 ? 3_450 : 2_800, unit: Whoop5HistoricalRecord.skinTempUnit) }
        let off = [WristWear.OffInterval(start: 3_600, end: 7_200, openEnded: false)]
        let with = SkinTemperature.night(samples: samples, stages: stages, offWrist: off)
        XCTAssertEqual(with.samples, 3_600)
        XCTAssertEqual(try XCTUnwrap(with.valueC), 34.5, accuracy: 1e-9)
        XCTAssertEqual(with.coverage, 0.5, accuracy: 1e-9)
        let without = SkinTemperature.night(samples: samples, stages: stages)
        XCTAssertNotEqual(without.valueC, with.valueC, "the off-wrist hour would have pulled the median down")
        XCTAssertEqual(SkinTemperature.version, "skin-temp-night-v2")
    }

    func testCoverageExplainsStrapReportedOffWristTime() {
        let d = 1_793_592_000
        // Recorded 00:00–06:00 and 09:00–12:00; now 12:00, synced; the strap reported off 06:00–08:30.
        let intervals = [(d, d + 6 * 3600), (d + 9 * 3600, d + 12 * 3600)]
        let off = [WristWear.OffInterval(start: d + 6 * 3600, end: d + 8 * 3600 + 1800, openEnded: false)]
        let plain = DayCoverage.compute(dayStart: d, dayEnd: d + 86_400, now: d + 12 * 3600, intervals: intervals,
                                        syncedThrough: d + 12 * 3600)
        XCTAssertTrue(plain.warrantsWarning, "3 h missing of 12 h warrants a warning without an explanation")
        XCTAssertFalse(plain.details(clock: { String($0) }).contains { $0.contains("off the wrist") }, "never claimed without the strap")
        let c = DayCoverage.compute(dayStart: d, dayEnd: d + 86_400, now: d + 12 * 3600, intervals: intervals,
                                    syncedThrough: d + 12 * 3600, offWrist: off)
        XCTAssertEqual(c.offWristSeconds, 2 * 3600 + 1800)
        XCTAssertEqual(c.unexplainedGapSeconds, 1800)
        XCTAssertFalse(c.warrantsWarning, "only 30 min unexplained")
        XCTAssertTrue(c.details(clock: { String($0) }).contains("Strap reported off the wrist for 2 h 30 min."))
        XCTAssertEqual(c.recordedSeconds, plain.recordedSeconds, "never adds recorded time")
        // Off-wrist time after now is not counted.
        let future = DayCoverage.compute(dayStart: d, dayEnd: d + 86_400, now: d + 3600, intervals: [(d, d + 3600)], syncedThrough: d + 3600,
                                         offWrist: [.init(start: d + 2 * 3600, end: d + 3 * 3600, openEnded: false)])
        XCTAssertEqual(future.offWristSeconds, 0)
    }

    func testVersionIsPartOfTheAlgorithmKey() {
        XCTAssertTrue(IncrementalScorer.algorithmKey(scoringVersion: 5, generation: 0).contains(WristWear.version))
    }
}
