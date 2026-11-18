import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// Strain page "Steps" tile from the 5.0 strap step counter (issue #25; experimental, walks W01–W03).
@MainActor
final class StrapStepsTests: XCTestCase {
    private let device = "test-whoop"

    private func repo() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: device, mac: nil, name: "WHOOP")
        return (Repository(deviceId: device, store: store), store)
    }

    func testDayStepsSpanTheResetAndStopAtTheNewestSyncedSecond() async throws {
        let (repo, store) = try await repo()
        let r = try XCTUnwrap(DayMath.range("2026-03-10"))
        func s(_ dt: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: r.from + dt, counter: c, activity: a) }
        // Yesterday's total 9,000 → reset just after midnight → 120 s walk, 60 s run, then still; data known to +2 h.
        let rows = [s(-600, 9_000, 0), s(90, 4, 0), s(8 * 3600, 4, 1), s(8 * 3600 + 120, 240, 2), s(8 * 3600 + 180, 420, 0)]
        // Synced records (HR every second) from 1 min before midnight until +2 h after the walk.
        let hr = (r.from - 60...(r.from + 8 * 3600 + 7200)).map { HRSample(ts: $0, bpm: 60) }
        _ = try await store.insert(Streams(hr: hr, steps: rows), deviceId: device)
        let day = await repo.strapSteps(from: r.from, to: r.to)
        let w = try XCTUnwrap(day)
        XCTAssertEqual(w.steps, 416, "increases only: the reset never subtracts, the 4 counted at the reset are not guessed")
        XCTAssertEqual(w.resets, 1)
        XCTAssertEqual(w.activityOneSeconds, 120)
        XCTAssertEqual(w.activityTwoSeconds, 60)
        XCTAssertEqual(StrainDetailView.stepDetails(w), ["Walking 2m · Running 1m", "Counter reset detected; steps at the reset are not included.", "Reset timing and accuracy are unverified; this may be an incomplete daily count."])
    }

    func testNoStepRowsMeansNoTileAndMissingReferenceIsSaid() async throws {
        let (repo, store) = try await repo()
        let r = try XCTUnwrap(DayMath.range("2026-03-10"))
        let none = await repo.strapSteps(from: r.from, to: r.to)
        XCTAssertNil(none, "no counter rows (4.0 strap, older data): no tile, never 0")
        _ = try await store.insert(Streams(steps: [StepCounterSample(ts: r.from + 3600, counter: 50, activity: 0),
                                                   StepCounterSample(ts: r.from + 3700, counter: 80, activity: 2)]), deviceId: device)
        let some = await repo.strapSteps(from: r.from, to: r.to)
        let w = try XCTUnwrap(some)
        XCTAssertEqual(w.steps, 30)
        XCTAssertEqual(w.activityTwoSeconds, 1, "without HR, activity stops at the last known step second")
        XCTAssertEqual(StrainDetailView.stepDetails(w), ["Counted from the first synced step of the day.", "No synced data for 1h 1m; walking and running time there is not counted.", "Reset timing and accuracy are unverified; this may be an incomplete daily count."])
        XCTAssertFalse(w.isComplete)
    }

    func testWalkAcrossAnInteriorSyncGapCountsOnlySyncedSeconds() async throws {
        let (repo, store) = try await repo()
        let r = try XCTUnwrap(DayMath.range("2026-03-10"))
        func s(_ dt: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: r.from + dt, counter: c, activity: a) }
        // Walking from 10:00; records 10:05–10:25 never synced; the next change point (still) is at 10:30.
        let t = 10 * 3600
        let rows = [s(t - 60, 1_000, 0), s(t, 1_000, 1), s(t + 1800, 3_400, 0)]
        let synced = Array((t - 60)..<(t + 300)) + Array((t + 1500)..<(t + 3600))
        _ = try await store.insert(Streams(hr: synced.map { HRSample(ts: r.from + $0, bpm: 90) }, steps: rows), deviceId: device)
        let day = await repo.strapSteps(from: r.from + t - 60, to: r.from + t + 3600)
        let w = try XCTUnwrap(day)
        XCTAssertEqual(w.steps, 2_400)
        XCTAssertEqual(w.activityOneSeconds, 300 + 300, "the 20-min gap is not walking time")
        XCTAssertEqual(w.unknownSeconds, 1_200)
        XCTAssertFalse(w.isComplete)
        XCTAssertEqual(StrainDetailView.stepDetails(w), ["Walking 10m", "No synced data for 20m; walking and running time there is not counted.", "Reset timing and accuracy are unverified; this may be an incomplete daily count."])
    }
}
