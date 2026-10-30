import XCTest
import GRDB
@testable import WhoopStore

/// User-entered effort and sets: the schema, the round trip, and that no derived write can reach them.
final class TrainingLogStoreTests: XCTestCase {
    private func effort(start: Int = 1200, end: Int = 1300, rpe: Double = 7, collectedAt: Int = 1400) -> SessionEffortRow {
        SessionEffortRow(workoutStartTs: start, workoutEndTs: end, scale: "CR10", rpe: rpe, sessionMinutes: 45, collectedAt: collectedAt)
    }
    private func set(start: Int = 1200, end: Int = 1300, _ exercise: String = "squat", reps: Int = 5,
                     kg: Double? = 100, rir: Int? = 2) -> StrengthSetRow {
        StrengthSetRow(workoutStartTs: start, workoutEndTs: end, exercise: exercise, reps: reps, externalKg: kg, rir: rir, collectedAt: 1400)
    }
    private func workout(start: Int = 1200, end: Int = 1300) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: "Activity", source: "noop", durationS: Double(end - start),
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: 9, distanceM: nil, zonesJSON: nil, notes: nil)
    }
    private func expectRejected(_ what: String, _ write: () async throws -> Void) async {
        do { try await write(); XCTFail("\(what) should be rejected") } catch {}
    }

    // MARK: Migration

    func testV13UpgradesAV12DatabaseWithoutTouchingExistingRows() throws {
        let q = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(q, upTo: "v12")
        try q.write { db in
            XCTAssertFalse(try db.tableExists("sessionEffort"))
            try db.execute(sql: """
                INSERT INTO workout (deviceId, startTs, endTs, sport, source, strain) VALUES ('d-noop', 1200, 1300, 'Activity', 'noop', 9)
                """)
        }
        try migrator.migrate(q)
        try q.read { db in
            XCTAssertEqual(try db.primaryKey("sessionEffort").columns, ["workoutStartTs"])
            XCTAssertEqual(try db.primaryKey("strengthSet").columns, ["workoutStartTs", "setIndex"])
            for t in ["sessionEffort", "strengthSet"] {
                let cols = try db.columns(in: t).map(\.name)
                XCTAssertFalse(cols.contains("deviceId"), "\(t) must stay out of reach of derived writes keyed by deviceId")
                XCTAssertTrue(cols.contains("collectedAt")); XCTAssertTrue(cols.contains("provenance"))
            }
            XCTAssertTrue(try db.columns(in: "sessionEffort").map(\.name).contains("scale"))
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT strain FROM workout"), 9)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessionEffort"), 0)
        }
        // RPE needs a real response, so the column can't quietly default to zero.
        let rpe = try q.read { try $0.columns(in: "sessionEffort").first { $0.name == "rpe" } }
        XCTAssertEqual(rpe?.isNotNull, true); XCTAssertNil(rpe?.defaultValueSQL)
    }

    func testTrainingTablesAreNotDerived() {
        XCTAssertTrue(Set(WhoopStore.derivedTables).isDisjoint(with: WhoopStore.trainingLogTables))
    }

    func testSchemaRejectsValuesOffTheScaleOrNonsensicalSets() async throws {
        let store = try await WhoopStore.inMemory()
        await expectRejected("RPE 11") { try await store.upsertSessionEffort(self.effort(rpe: 11)) }
        await expectRejected("RPE -1") { try await store.upsertSessionEffort(self.effort(rpe: -1)) }
        await expectRejected("0 reps") { try await store.addStrengthSet(self.set(reps: 0)) }
        await expectRejected("negative load") { try await store.addStrengthSet(self.set(kg: -5)) }
        await expectRejected("negative RIR") { try await store.addStrengthSet(self.set(rir: -1)) }
        await expectRejected("blank exercise") { try await store.addStrengthSet(self.set("  ")) }
        let entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertNil(entry)
    }

    // MARK: Round trip

    func testEffortRoundTripsWithScaleCollectionTimeAndProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSessionEffort(effort())
        let entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(entry?.effort, effort())
        XCTAssertEqual(entry?.effort?.scale, "CR10")
        XCTAssertEqual(entry?.effort?.collectedAt, 1400)
        XCTAssertEqual(entry?.effort?.provenance, TrainingLogProvenance.userEntered)
        XCTAssertEqual(entry?.sets, [])
    }

    func testAnsweringAgainReplacesTheResponse() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSessionEffort(effort())
        try await store.upsertSessionEffort(effort(rpe: 4, collectedAt: 9000))
        let entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(entry?.effort, effort(rpe: 4, collectedAt: 9000))
    }

    func testZeroIsAResponseAndWithdrawingOneLeavesItMissing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSessionEffort(effort(rpe: 0))
        var entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(entry?.effort?.rpe, 0, "CR10 0 is a real answer")
        try await store.addStrengthSet(set())
        try await store.deleteSessionEffort(workoutStartTs: 1200)
        entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertNil(entry?.effort, "no response is no row, not zero")
        XCTAssertEqual(entry?.sets.count, 1, "sets don't depend on an effort response")
    }

    func testSetsKeepLoggedOrderAndABodyweightSetKeepsNoLoad() async throws {
        let store = try await WhoopStore.inMemory()
        let a = try await store.addStrengthSet(set("squat"))
        let b = try await store.addStrengthSet(set("pull-up", reps: 10, kg: nil, rir: nil))
        let c = try await store.addStrengthSet(set("squat", reps: 3, kg: 120))
        XCTAssertEqual([a.setIndex, b.setIndex, c.setIndex], [0, 1, 2])
        let entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(entry?.sets, [a, b, c])
        XCTAssertNil(entry?.sets[1].externalKg); XCTAssertNil(entry?.sets[1].rir)
        XCTAssertEqual(entry?.sets[0].rir, 2)
        XCTAssertNil(entry?.effort, "sets alone leave RPE missing")

        try await store.deleteStrengthSet(workoutStartTs: 1200, setIndex: 1)
        let d = try await store.addStrengthSet(set("lunge"))
        let after = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(after?.sets.map(\.exercise), ["squat", "squat", "lunge"])
        XCTAssertEqual(d.setIndex, 3)
    }

    func testAWorkoutWithNothingLoggedHasNoEntry() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSessionEffort(effort())
        let later = try await store.trainingLog(workoutStartTs: 5000, workoutEndTs: 6000)
        XCTAssertNil(later)
        let adjacent = try await store.trainingLog(workoutStartTs: 1300, workoutEndTs: 1400)
        XCTAssertNil(adjacent, "touching spans don't overlap")
    }

    func testFileBackedEntrySurvivesReopen() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        try await WhoopStore(path: path).upsertSessionEffort(effort())
        let reopened = try await WhoopStore(path: path)
        let entry = try await reopened.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(entry?.effort, effort())
    }

    // MARK: Re-scores

    private func seed(_ store: WhoopStore) async throws {
        try await store.writeDerived(DerivedBatch(workouts: [workout()]), deviceId: "d-noop",
                                     scope: .replaceDays(["2026-10-02"], ranges: [1000...1999]))
        try await store.upsertSessionEffort(effort())
        try await store.addStrengthSet(set())
    }

    func testFullRescorePreservesUserEntries() async throws {
        let store = try await WhoopStore.inMemory()
        try await seed(store)
        // The re-score replaces everything from the epoch on and this time finds no workout at all.
        try await store.writeDerived(DerivedBatch(), deviceId: "d-noop",
                                     scope: .rescore(archiveId: "d-noop-v3", fromDay: "1970-01-01", fromTs: 0))
        let workouts = try await store.workouts(deviceId: "d-noop", from: 0, to: 5000, limit: 10)
        XCTAssertTrue(workouts.isEmpty, "the derived row really was replaced")
        let archived = try await store.workouts(deviceId: "d-noop-v3", from: 0, to: 5000, limit: 10)
        XCTAssertEqual(archived.count, 1)
        let entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertEqual(entry?.effort, effort())
        XCTAssertEqual(entry?.sets.map(\.exercise), ["squat"])
    }

    func testPartialReplayAndDeleteDerivedPreserveUserEntries() async throws {
        let store = try await WhoopStore.inMemory()
        try await seed(store)
        try await store.writeDerived(DerivedBatch(), deviceId: "d-noop", scope: .replaceDays(["2026-10-02"], ranges: [1000...1999]))
        try await store.deleteDerived(deviceId: "d-noop")
        let entry = try await store.trainingLog(workoutStartTs: 1200, workoutEndTs: 1300)
        XCTAssertNotNil(entry?.effort)
        XCTAssertEqual(entry?.sets.count, 1)
    }

    func testAnEntryFollowsAWorkoutARescoreMoved() async throws {
        let store = try await WhoopStore.inMemory()
        try await seed(store)
        try await store.writeDerived(DerivedBatch(workouts: [workout(start: 1230, end: 1340)]), deviceId: "d-noop",
                                     scope: .rescore(archiveId: "d-noop-v3", fromDay: "1970-01-01", fromTs: 0))
        let entry = try await store.trainingLog(workoutStartTs: 1230, workoutEndTs: 1340)
        XCTAssertEqual(entry?.workoutStartTs, 1200, "keeps the key it was logged under, so later edits don't fork it")
        XCTAssertEqual(entry?.workoutEndTs, 1300)
        XCTAssertEqual(entry?.effort, effort())
    }

    func testExactStartBeatsALargerOverlapAndOtherwiseTheLargestOverlapWins() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertSessionEffort(effort(start: 1000, end: 1900))
        try await store.upsertSessionEffort(effort(start: 1500, end: 1520))
        try await store.addStrengthSet(set(start: 2000, end: 2100))
        let exact = try await store.trainingLog(workoutStartTs: 1500, workoutEndTs: 2000)
        XCTAssertEqual(exact?.workoutStartTs, 1500)
        let largest = try await store.trainingLog(workoutStartTs: 1400, workoutEndTs: 2050)
        XCTAssertEqual(largest?.workoutStartTs, 1000)
    }
}
