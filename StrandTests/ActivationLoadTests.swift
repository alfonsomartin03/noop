import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// Issue #16 review: uncertain sleep episodes must not be drawn as Asleep or counted as covered time.
final class ActivationLoadTests: XCTestCase {
    private func episode(_ from: Int, _ to: Int, kind: String?) -> CachedSleepSession {
        CachedSleepSession(startTs: from, endTs: to, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil, kind: kind)
    }

    func testOnlyConfirmedSessionsBecomeSleepIntervals() {
        let rows = [episode(0, 100, kind: "primary"), episode(200, 300, kind: "interruptedPrimary"),
                    episode(400, 500, kind: "nap"), episode(600, 700, kind: "uncertain"), episode(800, 900, kind: nil)]
        XCTAssertEqual(ActivationLoad.sleepIntervals(rows).map { $0.0 }, [0, 200, 400, 800])
    }

    func testUncertainEpisodeIsNeitherAsleepNorCoverage() {
        // Two hours: an uncertain episode over the first hour with no heart rate, then an hour of readings.
        let from = 1_000_000, to = from + 7200
        let uncertain = [episode(from, from + 3600, kind: "uncertain")]
        let samples = stride(from: from + 3600, to: to, by: 2).map { (ts: $0, bpm: 62) }
        let bins = HRActivation.timeline(samples: samples, from: from, to: to, restingHR: 50, maxHR: 190,
                                         sleep: ActivationLoad.sleepIntervals(uncertain), workouts: [])
        XCTAssertFalse(bins.contains { $0.level == .sleep })
        XCTAssertEqual(bins.prefix(4).map(\.level), [.noData, .noData, .noData, .noData])
        XCTAssertEqual(HRActivation.coverage(bins), 0.5, accuracy: 0.001)

        // The same span as a confirmed nap is Asleep and does count.
        let nap = HRActivation.timeline(samples: samples, from: from, to: to, restingHR: 50, maxHR: 190,
                                        sleep: ActivationLoad.sleepIntervals([episode(from, from + 3600, kind: "nap")]), workouts: [])
        XCTAssertEqual(nap.prefix(4).map(\.level), [.sleep, .sleep, .sleep, .sleep])
        XCTAssertEqual(HRActivation.coverage(nap), 1.0, accuracy: 0.001)
    }

    func testUncertainEpisodeWithReadingsShowsActivationNotSleep() {
        let from = 2_000_000, to = from + 1800
        let samples = stride(from: from, to: to, by: 2).map { (ts: $0, bpm: 120) }
        let bins = HRActivation.timeline(samples: samples, from: from, to: to, restingHR: 50, maxHR: 190,
                                         sleep: ActivationLoad.sleepIntervals([episode(from, to, kind: "uncertain")]), workouts: [])
        XCTAssertEqual(bins.map(\.level), [.high, .high])
    }
}
