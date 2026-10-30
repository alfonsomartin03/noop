import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// End-to-end invalidation against a real store. Days are synthetic: a night, a morning and an evening workout. These
/// check what gets recomputed and that cached results equal fresh ones, not that any score is physiologically right.
final class IncrementalScorerTests: XCTestCase {
    private let raw = "strap"
    private var computed: String { raw + "-noop" }
    private let profile = UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "male")

    /// `count` consecutive local days ending today, oldest first, with today partly elapsed at `now`.
    private func calendar(_ count: Int) -> (days: [String], now: Int) {
        var c = Calendar.current; c.timeZone = .current
        let noon = c.date(bySettingHour: 12, minute: 0, second: 0, of: c.date(from: DateComponents(year: 2026, month: 3, day: 20))!)!
        let now = Int(noon.timeIntervalSince1970)
        var days: [String] = [], cursor = now
        for _ in 0..<count {
            let d = AnalyticsEngine.dayString(cursor)
            days.insert(d, at: 0)
            cursor = ZoneTimeline.shared.dayRange(d)!.from - 1
        }
        return (days, now)
    }

    /// One day's streams, one reading per 5 s (inside the hold, so still continuous): asleep to 07:00, resting to 18:00, a
    /// workout to 19:00, resting to the end.
    private func streams(day: String, until: Int? = nil, workoutBPM: Int = 155) -> Streams {
        let r = ZoneTimeline.shared.dayRange(day)!
        var s = Streams()
        for t in stride(from: r.from, to: min(r.to, until ?? r.to), by: 5) {
            let h = Double(t - r.from) / 3600
            let asleep = h < 7, hard = h >= 18 && h < 19
            s.hr.append(HRSample(ts: t, bpm: asleep ? 50 : hard ? workoutBPM : 72))
            s.gravity.append(GravitySample(ts: t, x: asleep ? 0 : Double((t / 5) % 2) * 0.4, y: 0, z: 1))
            if asleep { s.rr.append(RRInterval(ts: t, rrMs: 1200 + (t % 2) * 40)) }
        }
        return s
    }

    private func populated(_ c: (days: [String], now: Int)) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        for d in c.days { _ = try await store.insert(streams(day: d, until: d == c.days.last ? c.now : nil), deviceId: raw) }
        return store
    }

    private func request(_ c: (days: [String], now: Int), maxHR: Double? = 190, version: Int = 5, limit: Int? = nil, now: Int? = nil) -> ScoringRequest {
        ScoringRequest(rawId: raw, profile: profile, maxHROverride: maxHR, scoringVersion: version, now: now ?? c.now,
                       maxDays: c.days.count, maxRecomputedDays: limit)
    }

    private struct Snapshot: Equatable {
        let daily: [DailyMetric], workouts: [WorkoutRow], load: [LoadRecordRow], provenance: [ProvenanceRecord]
    }
    private func snapshot(_ store: WhoopStore) async throws -> Snapshot {
        Snapshot(daily: try await store.dailyMetrics(deviceId: computed, from: "0", to: "9"),
                 workouts: try await store.workouts(deviceId: computed, from: 0, to: Int.max, limit: 100),
                 load: try await store.loadRecords(deviceId: computed, from: "0", to: "9"),
                 provenance: try await store.provenance(deviceId: computed, from: "0", to: "9"))
    }

    func testReopeningUnchangedHistoryRecomputesNothing() async throws {
        let c = calendar(4)
        let store = try await populated(c)
        let first = try await IncrementalScorer.run(store: store, request: request(c))
        XCTAssertEqual(first.recomputed, c.days)
        let before = try await snapshot(store)
        for _ in 0..<3 {
            let again = try await IncrementalScorer.run(store: store, request: request(c))
            XCTAssertEqual(again.recomputed, [])
        }
        let after = try await snapshot(store)
        XCTAssertEqual(after, before)
    }

    func testLateDataRecomputesExactlyTheDaysThatReadIt() async throws {
        // A 10-minute hole at 20:00 on day 1 fills in later. That hour is read by day 1 and by day 2's evening context.
        let c = calendar(5)
        let r = ZoneTimeline.shared.dayRange(c.days[1])!
        let store2 = try await WhoopStore.inMemory()
        for d in c.days {
            var s = streams(day: d, until: d == c.days.last ? c.now : nil)
            if d == c.days[1] { s.hr.removeAll { $0.ts >= r.from + 20 * 3600 && $0.ts < r.from + 20 * 3600 + 600 } }
            _ = try await store2.insert(s, deviceId: raw)
        }
        _ = try await IncrementalScorer.run(store: store2, request: request(c))
        var fill = Streams()
        fill.hr = (0..<600).map { HRSample(ts: r.from + 20 * 3600 + $0, bpm: 72) }
        _ = try await store2.insert(fill, deviceId: raw)
        let out = try await IncrementalScorer.run(store: store2, request: request(c))
        XCTAssertEqual(out.recomputed, [c.days[1], c.days[2]])
        XCTAssertEqual(out.reasons[c.days[1]], .input)
        XCTAssertEqual(out.reasons[c.days[2]], .input)
    }

    func testCachedAndFreshCalculationsAgree() async throws {
        let c = calendar(5)
        let r = ZoneTimeline.shared.dayRange(c.days[2])!
        // Incremental: scored, then a workout's data arrives late.
        let incremental = try await WhoopStore.inMemory()
        for d in c.days {
            var s = streams(day: d, until: d == c.days.last ? c.now : nil)
            if d == c.days[2] {
                let hole = (r.from + 18 * 3600)..<(r.from + 19 * 3600)
                s.hr.removeAll { hole.contains($0.ts) }; s.gravity.removeAll { hole.contains($0.ts) }
            }
            _ = try await incremental.insert(s, deviceId: raw)
        }
        _ = try await IncrementalScorer.run(store: incremental, request: request(c))
        _ = try await incremental.insert(streams(day: c.days[2]), deviceId: raw)
        _ = try await IncrementalScorer.run(store: incremental, request: request(c))
        // Fresh: everything present from the start.
        let fresh = try await populated(c)
        _ = try await IncrementalScorer.run(store: fresh, request: request(c))

        let a = try await snapshot(incremental), b = try await snapshot(fresh)
        XCTAssertEqual(a.daily, b.daily)
        XCTAssertEqual(a.workouts, b.workouts)
        XCTAssertEqual(a.load, b.load)
        XCTAssertEqual(a.provenance, b.provenance)
        XCTAssertNotNil(a.daily.first { $0.day == c.days[2] }?.strain)
    }

    func testLabelsAndTrainingLogInvalidateNothing() async throws {
        let c = calendar(3)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c))
        let w = try await store.workouts(deviceId: computed, from: 0, to: Int.max, limit: 10)[0]
        try await store.setWorkoutLabel(WorkoutLabelRow(workoutStartTs: w.startTs, workoutEndTs: w.endTs, activity: "cycling",
                                                        provenance: LabelProvenance.userSelected.rawValue, updatedAt: 1))
        let out = try await IncrementalScorer.run(store: store, request: request(c))
        XCTAssertEqual(out.recomputed, [])
    }

    func testLabelsSurviveARescoreAndDetectionMovingTheEdges() async throws {
        let c = calendar(3)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c))
        let w = try await store.workouts(deviceId: computed, from: 0, to: Int.max, limit: 10)[0]
        try await store.setWorkoutLabel(WorkoutLabelRow(workoutStartTs: w.startTs, workoutEndTs: w.endTs, activity: "cycling",
                                                        provenance: LabelProvenance.userSelected.rawValue, updatedAt: 1))
        _ = try await IncrementalScorer.run(store: store, request: request(c, version: 6))
        let labels = try await store.workoutLabels()
        XCTAssertEqual(labels.count, 1)
        // Detection moved the session's start and end: the label still covers it.
        let moved = WorkoutRow(startTs: w.startTs + 120, endTs: w.endTs - 60, sport: "Activity", source: "noop", durationS: nil,
                               energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        let label = WorkoutLabels.resolve(moved, labels: labels)
        XCTAssertEqual(label.type, .cycling)
        XCTAssertEqual(label.provenance, .userSelected)
    }

    func testConfigEditReachesOnlyOpenDaysAndNeverRewritesFinalizedOnes() async throws {
        let c = calendar(4)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 190))
        let before = try await snapshot(store)
        let states = try await store.dayScoreStates(deviceId: computed)
        XCTAssertEqual(states[c.days[1]]?.finalized, true)
        XCTAssertEqual(states[c.days.last!]?.finalized, false)

        let out = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 170))
        let open = c.days.filter { states[$0]?.finalized == false }
        XCTAssertEqual(out.recomputed, open)
        XCTAssertEqual(Set(out.reasons.values), [.config])
        let after = try await snapshot(store)
        for d in c.days.filter({ !open.contains($0) }) {
            XCTAssertEqual(after.daily.first { $0.day == d }, before.daily.first { $0.day == d }, "finalized \(d) kept")
        }
    }

    func testLateDataUnderAChangedProfileKeepsTheDaysFrozenCalibration() async throws {
        let c = calendar(4)
        let r = ZoneTimeline.shared.dayRange(c.days[1])!
        let store = try await WhoopStore.inMemory()
        for d in c.days {
            var s = streams(day: d, until: d == c.days.last ? c.now : nil)
            if d == c.days[1] { s.hr.removeAll { $0.ts >= r.from + 10 * 3600 && $0.ts < r.from + 10 * 3600 + 600 } }
            _ = try await store.insert(s, deviceId: raw)
        }
        _ = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 190))
        var fill = Streams(); fill.hr = (0..<600).map { HRSample(ts: r.from + 10 * 3600 + $0, bpm: 72) }
        _ = try await store.insert(fill, deviceId: raw)
        _ = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 170))
        let rows = try await store.loadRecords(deviceId: computed, from: c.days[1], to: c.days[1])
        XCTAssertEqual(rows.compactMap(DayLoadRecord.init(row:)).first?.calibration.hrMax, 190)
    }

    func testImportedSessionTouchesOnlyItsDay() async throws {
        let c = calendar(4)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c))
        let r = ZoneTimeline.shared.dayRange(c.days[1])!
        try await store.upsertWorkouts([WorkoutRow(startTs: r.from + 9 * 3600, endTs: r.from + 10 * 3600, sport: "Yoga", source: "apple",
                                                   durationS: 3600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                                   distanceM: nil, zonesJSON: nil, notes: nil)], deviceId: "apple-health")
        let out = try await IncrementalScorer.run(store: store, request: request(c))
        XCTAssertEqual(out.recomputed, [c.days[1]])
        XCTAssertEqual(out.reasons[c.days[1]], .knownSessions)
    }

    func testCurrentDayUpdatesThenFinalizesWhenItsDataArrives() async throws {
        let c = calendar(3)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c))
        let today = c.days.last!
        // More of today arrives: only today moves.
        let r = ZoneTimeline.shared.dayRange(today)!
        var more = Streams()
        for t in c.now..<(c.now + 1800) { more.hr.append(HRSample(ts: t, bpm: 72)); more.gravity.append(GravitySample(ts: t, x: 0.3, y: 0, z: 1)) }
        _ = try await store.insert(more, deviceId: raw)
        let update = try await IncrementalScorer.run(store: store, request: request(c, now: c.now + 1800))
        XCTAssertEqual(update.recomputed, [today])

        // The day ends and the morning after arrives: it is rescored once more with what follows, and closes.
        var rest = streams(day: today); rest.hr.removeAll { $0.ts < c.now + 1800 }; rest.gravity.removeAll { $0.ts < c.now + 1800 }
        _ = try await store.insert(rest, deviceId: raw)
        let next = AnalyticsEngine.dayString(r.to + 3600)
        _ = try await store.insert(streams(day: next, until: r.to + 2 * 3600), deviceId: raw)
        let later = r.to + 2 * 3600
        _ = try await IncrementalScorer.run(store: store, request: request((c.days + [next], later)))
        let states = try await store.dayScoreStates(deviceId: computed)
        XCTAssertEqual(states[today]?.finalized, true)
        XCTAssertEqual(states[next]?.finalized, false)
    }

    func testAlgorithmChangeResumesAndNeverRepeatsFinishedDays() async throws {
        let c = calendar(5)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c, version: 5))

        let first = try await IncrementalScorer.run(store: store, request: request(c, version: 6, limit: 2))
        XCTAssertEqual(first.recomputed, Array(c.days.prefix(2)))
        XCTAssertEqual(first.remaining, 3)
        XCTAssertEqual(Set(first.reasons.values), [.algorithm])

        // Interrupted here: a fresh run picks up only what's left.
        let second = try await IncrementalScorer.run(store: store, request: request(c, version: 6, limit: 2))
        XCTAssertEqual(second.recomputed, Array(c.days[2...3]))
        let third = try await IncrementalScorer.run(store: store, request: request(c, version: 6, limit: 2))
        XCTAssertEqual(third.recomputed, [c.days[4]])
        XCTAssertEqual(third.remaining, 0)

        let provenance = try await store.provenance(deviceId: computed, from: "0", to: "9")
        XCTAssertEqual(Set(provenance.map(\.scoringVersion)), [6], "no day left on the old version")
        let finished = try await IncrementalScorer.run(store: store, request: request(c, version: 6))
        XCTAssertEqual(finished.recomputed, [])
    }

    func testExplicitRescoreRecomputesEverythingAndResolvesCalibrationAgain() async throws {
        let c = calendar(3)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 190))
        try await IncrementalScorer.requestFullRescore(store: store, computedId: computed)
        let out = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 170))
        XCTAssertEqual(out.recomputed, c.days)
        let rows = try await store.loadRecords(deviceId: computed, from: c.days[0], to: c.days[0])
        XCTAssertEqual(rows.compactMap(DayLoadRecord.init(row:)).first?.calibration.hrMax, 170)
    }

    func testArchiveHappensOncePerRescore() async throws {
        let c = calendar(3)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c, version: 5))
        let before = try await store.dailyMetrics(deviceId: computed, from: "0", to: "9")
        try await IncrementalScorer.archiveOnce(store: store, computedId: computed, archiveId: "archive", scoringVersion: 6)
        _ = try await IncrementalScorer.run(store: store, request: request(c, maxHR: 170, version: 6, limit: 1))
        // A resumed re-score must not overwrite the archive with rows it already replaced.
        try await IncrementalScorer.archiveOnce(store: store, computedId: computed, archiveId: "archive", scoringVersion: 6)
        let archived = try await store.dailyMetrics(deviceId: "archive", from: "0", to: "9")
        XCTAssertEqual(archived, before)
    }

    func testAFailedWriteLeavesEverythingToRetry() async throws {
        let c = calendar(3)
        let store = try await populated(c)
        _ = try await IncrementalScorer.run(store: store, request: request(c))
        let before = try await snapshot(store)
        let marksBefore = try await store.cursor("score.mark.\(computed).hrSample")
        try await store.failDerivedWritesForTest()
        do {
            _ = try await IncrementalScorer.run(store: store, request: request(c, version: 6))
            XCTFail("write should fail")
        } catch {}
        let after = try await snapshot(store)
        XCTAssertEqual(after, before)
        let marksAfter = try await store.cursor("score.mark.\(computed).hrSample")
        XCTAssertEqual(marksAfter, marksBefore)
        try await store.allowDerivedWritesForTest()
        let retry = try await IncrementalScorer.run(store: store, request: request(c, version: 6))
        XCTAssertEqual(retry.recomputed, c.days)
    }

    func testDayWithTooLittleDataIsNotReReadEveryRun() async throws {
        let c = calendar(3)
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(streams(day: c.days[1]), deviceId: raw)
        let first = try await IncrementalScorer.run(store: store, request: request(c))
        XCTAssertEqual(first.recomputed, c.days, "every day gets a state, with or without a result")
        let second = try await IncrementalScorer.run(store: store, request: request(c))
        XCTAssertEqual(second.recomputed, [])
    }

    // MARK: Dependents

    func testBaselineChangeReachesOnlyDaysWhoseBaselinesActuallyMoved() async {
        // Result depends on its baseline, so reuse is safe only if the baseline it would see is the one it saw.
        let days = (1...12).map { String(format: "2026-01-%02d", $0) }
        func row(_ d: String, hrv: Double) -> DailyMetric {
            DailyMetric(day: d, totalSleepMin: 420, efficiency: 90, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                        restingHr: 52, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
        }
        func run(values: [String: Double], seed: [DailyMetric], prov: [ProvenanceRecord], keys: [String: String], dirty: Set<String>)
            async -> (out: CausalReplay.Output<DailyMetric>, keys: [String: String]) {
            var newKeys = keys
            let out = await CausalReplay.run(
                days: days, seed: seed, seedProvenance: prov, scoringVersion: 5,
                reuse: { d, b in !dirty.contains(d) && keys[d] == IncrementalScorer.baselineKey(b) },
                analyze: { d, b in newKeys[d] = IncrementalScorer.baselineKey(b); return row(d, hrv: values[d] ?? 50) },
                daily: { $0 }, assessment: { _ in nil })
            return (out, newKeys)
        }
        var values = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1, 50 + Double($0 % 3)) })
        let first = await run(values: values, seed: [], prov: [], keys: [:], dirty: [])
        XCTAssertEqual(first.out.processed, days)

        let seed = first.out.results.map(\.result)
        let nothing = await run(values: values, seed: seed, prov: first.out.provenance, keys: first.keys, dirty: [])
        XCTAssertEqual(nothing.out.processed, [], "unchanged history walks without analyzing")

        values[days[5]] = 70
        let changed = await run(values: values, seed: seed, prov: first.out.provenance, keys: first.keys, dirty: [days[5]])
        XCTAssertEqual(changed.out.processed.first, days[5])
        XCTAssertFalse(changed.out.processed.contains(days[4]), "earlier days are not dependents")
        XCTAssertGreaterThan(changed.out.processed.count, 1, "later days that use that night do recompute")
    }
}

final class WorkoutLabelTests: XCTestCase {
    private func row(_ s: Int, _ e: Int, sport: String = "Activity", source: String = "noop") -> WorkoutRow {
        WorkoutRow(startTs: s, endTs: e, sport: sport, source: source, durationS: Double(e - s), energyKcal: nil, avgHr: nil,
                   maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }
    private func label(_ s: Int, _ e: Int, _ a: ActivityType) -> WorkoutLabelRow {
        WorkoutLabelRow(workoutStartTs: s, workoutEndTs: e, activity: a.rawValue, provenance: LabelProvenance.userSelected.rawValue, updatedAt: 1)
    }

    func testDetectedSessionWithoutALabelIsUnknownNeverGuessed() {
        let l = WorkoutLabels.resolve(row(0, 3600), labels: [])
        XCTAssertEqual(l.type, .unknown)
        XCTAssertEqual(l.name, "Unknown")
        XCTAssertEqual(l.provenance, .none)
    }

    func testImportedNameIsKeptWithItsProvenance() {
        let l = WorkoutLabels.resolve(row(0, 3600, sport: "Functional Fitness", source: "whoop"), labels: [])
        XCTAssertEqual(l.name, "Functional Fitness")
        XCTAssertEqual(l.provenance, .imported)
        XCTAssertEqual(l.type, .strength)
    }

    func testUserLabelBeatsAnImport() {
        let l = WorkoutLabels.resolve(row(0, 3600, sport: "Running", source: "whoop"), labels: [label(0, 3600, .cycling)])
        XCTAssertEqual(l.type, .cycling)
        XCTAssertEqual(l.provenance, .userSelected)
    }

    func testLabelFollowsTheSessionWhenEdgesMoveButNotToAnotherSession() {
        let labels = [label(1000, 4600, .rowing)]
        XCTAssertEqual(WorkoutLabels.resolve(row(1300, 4300), labels: labels).type, .rowing)
        XCTAssertEqual(WorkoutLabels.resolve(row(4000, 9000), labels: labels).type, .unknown, "barely overlaps")
        XCTAssertEqual(WorkoutLabels.resolve(row(9000, 9900), labels: labels).type, .unknown)
    }

    func testNearestLabelWinsWhenSessionsWereMerged() {
        let labels = [label(0, 1000, .running), label(1100, 4000, .cycling)]
        XCTAssertEqual(WorkoutLabels.resolve(row(0, 4000), labels: labels).type, .cycling)
    }

    func testApplyingChangesOnlyTheShownName() {
        let w = row(0, 3600)
        let out = WorkoutLabels.applying([label(0, 3600, .yoga)], to: [w])
        XCTAssertEqual(out[0].sport, "Yoga")
        XCTAssertEqual(out[0].startTs, w.startTs)
        XCTAssertEqual(out[0].strain, w.strain)
    }

    func testEveryTypeRoundTripsAndNoLoadMethodReadsIt() {
        for t in ActivityType.allCases { XCTAssertEqual(ActivityType(rawValue: t.rawValue), t) }
        XCTAssertTrue(LoadMethod.allCases.allSatisfy { $0.descriptor.missingInput?.contains("activity") != true })
    }

    func testSmoothedHRMatchesASortedWindowExactly() {
        // The histogram median replaced a per-sample sort and must not change a single value.
        var rng = SystemRandomNumberGenerator()
        var t = 0, hr: [HRSample] = []
        for _ in 0..<5000 {
            t += [1, 1, 1, 2, 5, 90].randomElement(using: &rng)!
            hr.append(HRSample(ts: t, bpm: Int.random(in: 40...190, using: &rng)))
        }
        var expected: [Double] = [], lo = 0
        for i in hr.indices {
            while hr[i].ts - hr[lo].ts > 60 { lo += 1 }
            let w = hr[lo...i].map { Double($0.bpm) }.sorted()
            expected.append(w[w.count / 2])
        }
        XCTAssertEqual(WorkoutDetector.smoothedHR(hr, windowS: 60), expected)
    }
}
