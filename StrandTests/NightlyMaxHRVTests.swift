import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// Issue #17 review: the nightly maximum is taken over the whole selected NOOP main sleep (every fragment, resolved by
/// its final wake date), is NOOP-only, and reflects data that arrives or changes later.
@MainActor
final class NightlyMaxHRVTests: XCTestCase {
    private let device = "test-whoop"
    private let day = "2026-03-10"
    private var midnight: Int { ZoneTimeline.shared.dayRange(day)!.from }

    private func repo() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: device, mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: device + "-noop", mac: nil, name: "NOOP")
        return (Repository(deviceId: device, store: store), store)
    }

    /// Steady sleep-like streams: 1 Hz HR and an alternating RR series whose RMSSD is 2 × swing.
    private func streams(from: Int, to: Int, swing: Double) -> Streams {
        var rr: [RRInterval] = []
        var t = Double(from), flip = 1.0
        while t < Double(to) {
            let v = 1150 + flip * swing
            rr.append(RRInterval(ts: Int(t), rrMs: Int(v.rounded())))
            t += v / 1000; flip = -flip
        }
        return Streams(hr: (from..<to).map { HRSample(ts: $0, bpm: 52) }, rr: rr)
    }

    private func episode(_ from: Int, _ to: Int, kind: String, session: String) -> CachedSleepSession {
        CachedSleepSession(startTs: from, endTs: to, efficiency: 95, restingHr: 52, avgHrv: 50, stagesJSON: nil, kind: kind, sessionId: session)
    }

    // MARK: session selection (pure)

    func testSelectionTakesTheWholeSessionByItsFinalWakeDate() {
        let m = midnight
        let dayOf = ZoneTimeline.shared.dayString
        let rows = [
            episode(m - 5400, m - 600, kind: "interruptedPrimary", session: "night"),     // ends before midnight
            episode(m + 1800, m + 23_400, kind: "interruptedPrimary", session: "night"),  // final wake on `day`
            episode(m + 50_000, m + 52_000, kind: "nap", session: "nap"),
            episode(m + 60_000, m + 63_000, kind: "uncertain", session: "maybe"),
            episode(m - 90_000, m - 70_000, kind: "primary", session: "previous"),        // the night before
        ]
        let picked = Repository.mainSleepEpisodes(rows, wakingOn: day, dayOf: dayOf)
        XCTAssertEqual(picked.map(\.startTs), [m - 5400, m + 1800])
        // The pre-midnight fragment is not a night of its own on the previous date.
        let previous = Repository.mainSleepEpisodes(rows, wakingOn: ZoneTimeline.shared.dayString(m - 3600), dayOf: dayOf)
        XCTAssertEqual(previous.map(\.startTs), [m - 90_000])
        XCTAssertTrue(Repository.mainSleepEpisodes(rows.filter { $0.kind == "nap" || $0.kind == "uncertain" }, wakingOn: day, dayOf: dayOf).isEmpty)
    }

    // MARK: caption (issue #17 recheck: context must not be truncated into a 2-line caption)

    func testCaptionDetailsAreSeparateShortLines() {
        let lines = MaxHRVCaption.details(windowStart: "3:42 AM", sleep: "11:08 PM–6:51 AM in 3 parts", validWindows: 61)
        XCTAssertEqual(lines, ["Highest 5-min RMSSD at 3:42 AM", "Main sleep 11:08 PM–6:51 AM in 3 parts", "61 clean windows"])
        XCTAssertEqual(MaxHRVCaption.details(windowStart: "1:00 AM", sleep: "x", validWindows: 1).last, "1 clean window")
    }

    // MARK: repository

    func testMaximumInThePreMidnightFragmentIsFound() async throws {
        let (repo, store) = try await repo()
        let m = midnight
        let a = (m - 5400, m - 600), b = (m + 1800, m + 23_400)
        try await store.insert(streams(from: a.0, to: a.1, swing: 60), deviceId: device)    // RMSSD ≈ 120
        try await store.insert(streams(from: b.0, to: b.1, swing: 25), deviceId: device)    // RMSSD ≈ 50
        _ = try await store.upsertSleepSessions([episode(a.0, a.1, kind: "interruptedPrimary", session: "n"),
                                                 episode(b.0, b.1, kind: "interruptedPrimary", session: "n")], deviceId: device + "-noop")
        guard case .value(let n) = await repo.nightlyMaxHRV(day: day) else { return XCTFail("expected a maximum") }
        XCTAssertEqual(n.max.rmssd, 120, accuracy: 3)
        XCTAssertLessThan(n.max.windowEnd, m + 1, "the maximum lies in the fragment before midnight")
        XCTAssertEqual(n.sleepStart, a.0)
        XCTAssertEqual(n.sleepEnd, b.1)
        XCTAssertEqual(n.fragments, 2)
    }

    func testPreMidnightFragmentCountsTowardCoverage() async throws {
        let (repo, store) = try await repo()
        let m = midnight
        let a = (m - 6000, m - 600), b = (m + 600, m + 1800)                                 // 90 min, then only 20 min
        try await store.insert(streams(from: a.0, to: a.1, swing: 30), deviceId: device)
        try await store.insert(streams(from: b.0, to: b.1, swing: 30), deviceId: device)
        // The post-midnight fragment alone is too short for a maximum…
        _ = try await store.upsertSleepSessions([episode(b.0, b.1, kind: "primary", session: "short")], deviceId: device + "-noop")
        guard case .unavailable(let why) = await repo.nightlyMaxHRV(day: day) else { return XCTFail("20 minutes cannot give a maximum") }
        XCTAssertTrue(why.contains("Too few"))
        // …but as part of the interrupted night it belongs to, the night has enough clean windows.
        _ = try await store.upsertSleepSessions([episode(a.0, a.1, kind: "interruptedPrimary", session: "n"),
                                                 episode(b.0, b.1, kind: "interruptedPrimary", session: "n")], deviceId: device + "-noop")
        guard case .value(let n) = await repo.nightlyMaxHRV(day: day) else { return XCTFail("expected a maximum over both fragments") }
        XCTAssertGreaterThanOrEqual(n.max.validWindows, SleepVitalsCalculator.minValidWindows)
        XCTAssertEqual(n.fragments, 2)
    }

    func testImportedOnlyNightHasNoMaximum() async throws {
        let (repo, store) = try await repo()
        // The WHOOP import supplies a nightly HRV average for this day; NOOP recorded nothing.
        _ = try await store.upsertDailyMetrics([DailyMetric(day: day, totalSleepMin: 440, efficiency: 92, deepMin: 90, remMin: 100, lightMin: 250,
                                                            disturbances: 3, restingHr: 52, avgHrv: 64, recovery: 70, strain: 10, exerciseCount: 0)],
                                               deviceId: device)
        guard case .unavailable(let why) = await repo.nightlyMaxHRV(day: day, showingImport: true) else { return XCTFail("nothing may be borrowed from the import") }
        XCTAssertTrue(why.contains("WHOOP import has no beat-to-beat data"))
        // An uncertain NOOP episode with data is still not a main sleep.
        let m = midnight
        try await store.insert(streams(from: m + 1800, to: m + 9000, swing: 30), deviceId: device)
        _ = try await store.upsertSleepSessions([episode(m + 1800, m + 9000, kind: "uncertain", session: "u")], deviceId: device + "-noop")
        guard case .unavailable = await repo.nightlyMaxHRV(day: day, showingImport: true) else { return XCTFail("uncertain sleep is not eligible") }
    }

    func testLateSyncAndCorrectedSleepChangeTheResult() async throws {
        let (repo, store) = try await repo()
        let m = midnight
        let b = (m + 1800, m + 23_400)
        _ = try await store.upsertSleepSessions([episode(b.0, b.1, kind: "primary", session: "n")], deviceId: device + "-noop")
        guard case .unavailable(let why) = await repo.nightlyMaxHRV(day: day) else { return XCTFail("no beat-to-beat data yet") }
        XCTAssertTrue(why.contains("No beat-to-beat data"))
        // Beat-to-beat data syncs later: the next lookup has a value.
        try await store.insert(streams(from: b.0, to: b.1, swing: 25), deviceId: device)
        guard case .value(let first) = await repo.nightlyMaxHRV(day: day) else { return XCTFail("expected a maximum after the sync") }
        XCTAssertEqual(first.max.rmssd, 50, accuracy: 3)
        // The sleep is then corrected to a nap: no main sleep, no maximum.
        _ = try await store.upsertSleepSessions([episode(b.0, b.1, kind: "nap", session: "n")], deviceId: device + "-noop")
        guard case .unavailable = await repo.nightlyMaxHRV(day: day) else { return XCTFail("a nap has no nightly maximum") }
    }

    func testRequestIdentityChangesWithDataAndSource() {
        let base = Repository.NightlyMaxHRVRequest(day: day, dataVersion: 3, showingImport: false)
        XCTAssertEqual(base, Repository.NightlyMaxHRVRequest(day: day, dataVersion: 3, showingImport: false))
        XCTAssertNotEqual(base, Repository.NightlyMaxHRVRequest(day: day, dataVersion: 4, showingImport: false))
        XCTAssertNotEqual(base, Repository.NightlyMaxHRVRequest(day: day, dataVersion: 3, showingImport: true))
        XCTAssertNotEqual(base, Repository.NightlyMaxHRVRequest(day: "2026-03-11", dataVersion: 3, showingImport: false))
    }
}
