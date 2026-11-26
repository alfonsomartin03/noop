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
        XCTAssertEqual(w.steps, 420, "the reset never subtracts; the 4 read just after it are steps since the reset")
        XCTAssertFalse(w.isComplete, "reset boundary not yet established: shown as at least")
        XCTAssertEqual(w.resets, 1)
        XCTAssertEqual(w.activityOneSeconds, 120)
        XCTAssertEqual(w.activityTwoSeconds, 60)
        XCTAssertEqual(StrainDetailView.stepDetails(w), ["Counter reset detected; steps after it are counted from the strap's new count.", "The strap resets this counter on its own (seen right after alarm wake-ups and once after it was taken off) and its accuracy is unverified, so this may be an incomplete daily count."])
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
        XCTAssertEqual(StrainDetailView.stepDetails(w), ["Counted from the first synced step of the day.", "No synced data for \(DayMath.hm(3_699.0 / 60)); walking and running time there is not counted.", "The strap resets this counter on its own (seen right after alarm wake-ups and once after it was taken off) and its accuracy is unverified, so this may be an incomplete daily count."])
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
        XCTAssertEqual(StrainDetailView.stepDetails(w), ["No synced data for 20m; walking and running time there is not counted.", "The strap resets this counter on its own (seen right after alarm wake-ups and once after it was taken off) and its accuracy is unverified, so this may be an incomplete daily count."])
    }

    /// #83: the Walking & running tile over a stored day: synced seconds only, partial totals as lower bounds.
    func testActivityTileShowsSyncedCoverageAndLowerBound() async throws {
        let (repo, store) = try await repo()
        let r = try XCTUnwrap(DayMath.range("2026-03-10"))
        func s(_ dt: Int, _ c: Int, _ a: Int) -> StepCounterSample { StepCounterSample(ts: r.from + dt, counter: c, activity: a) }
        // Walking 10:00–10:30 with 10:10–10:20 unsynced; synced from midnight to 12:00 then nothing more.
        let t = 10 * 3600
        let rows = [s(-60, 0, 0), s(t, 0, 1), s(t + 1800, 2_000, 0)]
        let synced = Array(-60..<(t + 600)) + Array((t + 1200)..<(12 * 3600))
        _ = try await store.insert(Streams(hr: synced.map { HRSample(ts: r.from + $0, bpm: 80) }, steps: rows), deviceId: device)
        let w = await repo.strapSteps(from: r.from, to: r.to)
        let now = Date(timeIntervalSince1970: TimeInterval(r.from + 13 * 3600))
        let a = try XCTUnwrap(StrainDetailView.activity(w, day: r, now: now))
        XCTAssertEqual(a.walkingSeconds, 1200)
        XCTAssertEqual(a.syncedSeconds, 12 * 3600 - 600)
        XCTAssertEqual(a.gapSeconds, 600)
        XCTAssertEqual(a.awaitingSyncSeconds, 3600)
        XCTAssertEqual(a.value(duration: StrainDetailView.duration), "≥ 20m")
        XCTAssertEqual(a.caption(duration: StrainDetailView.duration), "Over 11h\u{00A0}50m synced of 13h\u{00A0}0m so far")
        XCTAssertEqual(a.details(duration: StrainDetailView.duration),
                       ["Walking 20m", "Not walking or running: 11h\u{00A0}30m.", "No synced data for 10m; activity there is unknown.",
                        "1h\u{00A0}0m not synced yet.", "Totals are at least these: unsynced time is not counted."])
        XCTAssertNil(StrainDetailView.activity(nil, day: r), "no step rows (4.0 strap, older data): no tile")
    }
}
