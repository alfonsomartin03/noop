import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// Issue #16 review (P2): the bundled export fixture's sleep (23:15 → 06:30, UTC+1) belongs to the cycle starting at
/// 06:30 — 7 h 15 min after onset. Through the real importer → store → `SleepPairing.load` path it must pair.
@MainActor
final class SleepPairingImportTests: XCTestCase {
    // Same rows as Packages/StrandImport/Tests/StrandImportTests/Resources (main sleep + a nap on that cycle).
    private let cycles = """
    Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min)
    2024-01-02 06:30:00,2024-01-03 06:29:00,UTC+01:00,72,52,68.4,33.1,96.0,12.5,2450,165,68,2024-01-01 23:15:00,2024-01-02 06:30:00,85,14.2,420,455,210,95,115,35,92.3,88.0,480,60
    """
    private let sleeps = """
    Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min)
    2024-01-02 06:30:00,2024-01-01 23:15:00,2024-01-02 06:30:00,UTC+01:00,false,85,14.2,420,455,210,95,115,35,92.3,88.0,480,60
    2024-01-02 06:30:00,2024-01-02 14:00:00,2024-01-02 14:25:00,UTC+01:00,true,,,25,25,20,5,0,0,,,,
    """

    private func exportDir(cyclesWithoutOnset: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var c = cycles
        if cyclesWithoutOnset { c = c.replacingOccurrences(of: "2024-01-01 23:15:00,2024-01-02 06:30:00,85", with: ",,85") }
        try c.write(to: dir.appendingPathComponent("physiological_cycles.csv"), atomically: true, encoding: .utf8)
        try sleeps.write(to: dir.appendingPathComponent("sleeps.csv"), atomically: true, encoding: .utf8)
        return dir
    }

    private func run(cyclesWithoutOnset: Bool) async throws -> SleepPairing.Result {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "w", mac: nil, name: "WHOOP")
        try await store.upsertDevice(id: "w-noop", mac: nil, name: "NOOP")
        try await WhoopImporter.importExport(url: try exportDir(cyclesWithoutOnset: cyclesWithoutOnset), into: store, deviceId: "w")
        // NOOP recorded the same night: 2024-01-01 22:15Z → 2024-01-02 05:30Z.
        let onset = 1_704_147_300, wake = onset + 26_100
        _ = try await store.upsertSleepSessions([CachedSleepSession(startTs: onset, endTs: wake, efficiency: 92, restingHr: 52,
                                                                    avgHrv: 60, stagesJSON: nil, kind: "primary", sessionId: "n1")],
                                                deviceId: "w-noop")
        _ = try await store.upsertDailyMetrics([DailyMetric(day: AnalyticsEngine.dayString(wake), totalSleepMin: 420, efficiency: 92,
                                                            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 52,
                                                            avgHrv: 60, recovery: nil, strain: nil, exerciseCount: nil)],
                                               deviceId: "w-noop")
        return SleepPairing.pair(try await SleepPairing.load(store: store, rawId: "w", computedId: "w-noop"))
    }

    func testFixtureSleepPairsWithTheCycleThatDeclaresIt() async throws {
        let r = try await run(cyclesWithoutOnset: false)
        XCTAssertEqual(r.pairs.count, 1, "excluded: \(r.excluded)")
        XCTAssertEqual(r.pairs.first?.whoop["sleep_performance"], 85)
        XCTAssertEqual(r.pairs.first.map { $0.cycleStart - $0.whoopSleep.start }, 26_100)   // cycle starts at wake
    }

    /// Cycle row without Sleep/Wake onset: the link comes from sleeps.csv naming that cycle's start.
    func testLinkFallsBackToTheSleepRecordNamingTheCycle() async throws {
        let r = try await run(cyclesWithoutOnset: true)
        XCTAssertEqual(r.pairs.count, 1, "excluded: \(r.excluded)")
    }
}
