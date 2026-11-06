import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class WorkoutDetectorTests: XCTestCase {

    // MARK: - Activity series

    func testActivitySeriesFirstIsZero() {
        let grav = [
            GravitySample(ts: 0, x: 0, y: 0, z: 1),
            GravitySample(ts: 1, x: 0.3, y: 0, z: 1),  // Δ = 0.3
            GravitySample(ts: 2, x: 0.3, y: 0, z: 1),  // Δ = 0
        ]
        let series = WorkoutDetector.activitySeries(grav)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series[0].intensity, 0.0, accuracy: 1e-9)
        XCTAssertEqual(series[1].intensity, 0.3, accuracy: 1e-9)
        XCTAssertEqual(series[2].intensity, 0.0, accuracy: 1e-9)
    }

    func testActivitySeriesEmpty() {
        XCTAssertTrue(WorkoutDetector.activitySeries([]).isEmpty)
    }

    // MARK: - Calories

    func testCaloriesActiveAndRestingMale() {
        // 600 active samples at 150 bpm, male 80 kg 30 y, hrmax 190 → matches Python golden.
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 150) }
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let (kcal, kj) = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 190, restingHR: 60)
        XCTAssertEqual(kcal, 146.972, accuracy: 0.1)
        XCTAssertEqual(kj, kcal * 4.184, accuracy: 1e-6)
    }

    func testCaloriesRestingBelowThreshold() {
        // HR below the 30% HRR active threshold → BMR rate (small per-sample).
        // Threshold = 60 + 0.30*(190-60) = 99. bpm 80 < 99 → resting.
        let hr = (0..<86400).map { HRSample(ts: $0, bpm: 80) }  // a full "day" of resting
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let (kcal, _) = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 190, restingHR: 60)
        // 86400 s at BMR rate ≈ full BMR ≈ 1853.6 kcal/day.
        XCTAssertEqual(kcal, 1853.632, accuracy: 1.0)
    }

    func testCaloriesSexCoefficientsDiffer() {
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 150) }
        let male = Calories.estimateBoutCalories(
            hr, profile: UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "male"),
            hrmax: 190, restingHR: 60).0
        let female = Calories.estimateBoutCalories(
            hr, profile: UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "female"),
            hrmax: 190, restingHR: 60).0
        XCTAssertNotEqual(male, female, accuracy: 0.0)
    }

    // MARK: - Detection

    /// A workout: high HR + sustained motion for `durationS`, embedded in a rest day.
    private func workoutDay(workoutStart: Int, workoutDur: Int) -> (hr: [HRSample], grav: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = workoutStart - 30 * 60
        let dayEnd = workoutStart + workoutDur + 30 * 60
        for t in dayStart..<dayEnd {
            let inWorkout = t >= workoutStart && t < workoutStart + workoutDur
            // Resting periods: HR 55, still gravity. Workout: HR 165, moving gravity.
            hr.append(HRSample(ts: t, bpm: inWorkout ? 165 : 55))
            if inWorkout {
                let phase = Double((t - workoutStart) % 2) * 0.5  // 0.5 g oscillation → moving
                grav.append(GravitySample(ts: t, x: phase, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))  // still
            }
        }
        return (hr, grav)
    }

    func testDetectFindsWorkout() {
        let start = 5_000_000
        let dur = 20 * 60  // 20 min
        let (hr, grav) = workoutDay(workoutStart: start, workoutDur: dur)
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, age: 30)
        XCTAssertEqual(sessions.count, 1)
        let w = sessions[0]
        XCTAssertEqual(w.avgHR, 165, accuracy: 1.0)
        XCTAssertEqual(w.peakHR, 165)
        XCTAssertGreaterThan(w.durationS, Double(15 * 60))
        // Zone breakdown sums to ~100.
        let total = w.zoneTimePct.values.reduce(0, +)
        XCTAssertEqual(total, 100.0, accuracy: 0.5)
        XCTAssertEqual(w.hrmaxSource, "tanaka")  // age supplied, thin observed history
    }

    func testDetectWithProfileEstimatesCalories() {
        let start = 6_000_000
        let dur = 20 * 60
        let (hr, grav) = workoutDay(workoutStart: start, workoutDur: dur)
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, age: 30, profile: profile)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(sessions[0].caloriesKcal)
        XCTAssertGreaterThan(sessions[0].caloriesKcal!, 0)
    }

    func testDetectRejectsShortBout() {
        let start = 7_000_000
        let (hr, grav) = workoutDay(workoutStart: start, workoutDur: 3 * 60)  // 3 min < 5
        XCTAssertTrue(WorkoutDetector.detect(hr: hr, gravity: grav, age: 30).isEmpty)
    }

    func testDetectEmptyStreams() {
        XCTAssertTrue(WorkoutDetector.detect(hr: [], gravity: [], age: 30).isEmpty)
        let grav = [GravitySample(ts: 0, x: 0, y: 0, z: 1)]
        XCTAssertTrue(WorkoutDetector.detect(hr: [], gravity: grav, age: 30).isEmpty)
    }

    func testDetectRejectsLowIntensityBlip() {
        // Moving + slightly elevated HR but dominated by zone 0/1 (HR just over floor).
        // resting derived ~55, floor = 70. HR 75 is above floor but at ~15% HRR (zone 0).
        let start = 8_000_000
        let dur = 20 * 60
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = start - 30 * 60
        let dayEnd = start + dur + 30 * 60
        for t in dayStart..<dayEnd {
            let inBout = t >= start && t < start + dur
            hr.append(HRSample(ts: t, bpm: inBout ? 75 : 55))
            if inBout {
                let phase = Double((t - start) % 2) * 0.5
                grav.append(GravitySample(ts: t, x: phase, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            }
        }
        // age 30 → hrmax 187, zone math available → z2+ fraction ≈ 0 < 0.50 → rejected.
        XCTAssertTrue(WorkoutDetector.detect(hr: hr, gravity: grav, age: 30).isEmpty)
    }
}

final class WorkoutDetectorHROnlyTests: XCTestCase {
    private func series(_ segs: [(secs: Int, bpm: Int)]) -> [HRSample] {
        var t = 1_700_000_000, out: [HRSample] = []
        for s in segs { for _ in 0..<s.secs { out.append(HRSample(ts: t, bpm: s.bpm)); t += 1 } }
        return out
    }

    /// Still wrist (no motion at all) but 40 min at 150 bpm: detected by the HR-only path.
    func testStillWristSustainedEffortDetected() {
        let hr = series([(1800, 58), (2400, 150), (1800, 58)])
        let w = WorkoutDetector.detect(hr: hr, gravity: [], restingHR: 58, maxHR: 190, age: 30)
        XCTAssertEqual(w.count, 1)
        XCTAssertGreaterThan(w.first?.durationS ?? 0, 2000)
    }

    /// A 3-minute spike is not a workout.
    func testShortSpikeIgnored() {
        let hr = series([(1800, 58), (180, 150), (1800, 58)])
        XCTAssertTrue(WorkoutDetector.detect(hr: hr, gravity: [], restingHR: 58, maxHR: 190, age: 30).isEmpty)
    }

    /// A brief dip between sets does not split the effort in two.
    func testRestBetweenSetsBridged() {
        let hr = series([(1200, 58), (900, 140), (120, 90), (900, 140), (1200, 58)])
        XCTAssertEqual(WorkoutDetector.detect(hr: hr, gravity: [], restingHR: 58, maxHR: 190, age: 30).count, 1)
    }

    /// 2h20 steady endurance ride with a 12-min stop in the middle and gentle drift: one session.
    func testLongEnduranceRideWithStopIsOneSession() {
        // rest 55, hrmax 190 → HRR 135. 125 bpm ≈ 52% HRR (zone 1), drifting to 135.
        let hr = series([(1800, 55), (3600, 125), (720, 70), (4200, 135), (1800, 55)])
        let w = WorkoutDetector.detect(hr: hr, gravity: [], restingHR: 55, maxHR: 190, age: 30)
        XCTAssertEqual(w.count, 1)
        XCTAssertGreaterThan(w.first?.durationS ?? 0, 2 * 3600)
    }

    /// Above the Zone 1 floor (95 bpm) for only 10 min is not a workout; 20 min is.
    func testSustainedTimeAboveZone1FloorRequired() {
        let short = series([(1800, 55), (600, 125), (1800, 55)])
        XCTAssertTrue(WorkoutDetector.detect(hr: short, gravity: [], restingHR: 55, maxHR: 190, age: 30).isEmpty)
        let long = series([(1800, 55), (1200, 125), (1800, 55)])
        XCTAssertEqual(WorkoutDetector.detect(hr: long, gravity: [], restingHR: 55, maxHR: 190, age: 30).count, 1)
    }

    /// Wrist motion alone (HR below the Zone 1 floor) never triggers a workout.
    func testMotionAloneDoesNotTrigger() {
        let hr = series([(1800, 55), (1800, 85), (1800, 55)])
        let grav = (0..<5400).map { GravitySample(ts: 1_700_000_000 + $0, x: Double($0 % 2) * 0.5, y: 0, z: 1) }
        XCTAssertTrue(WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 55, maxHR: 190, age: 30).isEmpty)
    }

    /// A 22-min stop (HR back near rest) between two 45-min legs is still one ride.
    func testLongStopWithRecoveredHRStillOneRide() {
        let hr = series([(1800, 55), (2700, 130), (1320, 62), (2700, 130), (1800, 55)])
        XCTAssertEqual(WorkoutDetector.detect(hr: hr, gravity: [], restingHR: 55, maxHR: 190, age: 30).count, 1)
    }

    /// A 60-min gap is two separate workouts.
    func testVeryLongGapStaysTwoWorkouts() {
        let hr = series([(1800, 55), (2700, 130), (3600, 60), (2700, 130), (1800, 55)])
        XCTAssertEqual(WorkoutDetector.detect(hr: hr, gravity: [], restingHR: 55, maxHR: 190, age: 30).count, 2)
    }
}

/// Boundary trim after a session closes. Every fixture states the reference activity interval it was built from.
/// rest 55, HRmax 190 → Zone 1 floor (entry) 95 bpm, exit 90 bpm.
final class WorkoutBoundaryTrimTests: XCTestCase {
    private let t0 = 1_700_000_000
    private struct Case { let name: String; let segs: [(secs: Int, bpm: Int)]; let reference: (Int, Int) }

    private func series(_ segs: [(secs: Int, bpm: Int)], gapAt: Int? = nil, gapS: Int = 0) -> [HRSample] {
        var t = t0, out: [HRSample] = []
        for s in segs { for _ in 0..<s.secs { if gapAt.map({ t >= t0 + $0 && t < t0 + $0 + gapS }) != true { out.append(HRSample(ts: t, bpm: s.bpm)) }; t += 1 } }
        return out
    }
    /// Offset of segment `i`'s start from t0.
    private func at(_ segs: [(secs: Int, bpm: Int)], _ i: Int) -> Int { segs.prefix(i).reduce(0) { $0 + $1.secs } }

    private func detect(_ hr: [HRSample], trim: Bool = true) -> [WorkoutDetector.Episode] {
        let cleaned = HRQuality.clean(hr)
        return WorkoutDetector.episodes(cleaned, support: SupportedHR(cleaned: cleaned), hrMax: 190, trimBoundaries: trim)
    }

    private var cases: [Case] {
        // Warm-up blip (2 min), 4 min standing, then the 30-min effort: the blip and the pause are not the session.
        let blip: [(secs: Int, bpm: Int)] = [(1800, 55), (120, 120), (240, 70), (1800, 150), (1800, 55)]
        // 40-min effort then a 15-min easy walk at 92 bpm, inside the hysteresis band only.
        let cooldown: [(secs: Int, bpm: Int)] = [(1800, 55), (2400, 150), (900, 92), (1800, 55)]
        // Settling before: 10 min at 93 bpm, then the effort.
        let settle: [(secs: Int, bpm: Int)] = [(1800, 55), (600, 93), (1800, 140), (1800, 55)]
        // Continuous effort: nothing to trim.
        let steady: [(secs: Int, bpm: Int)] = [(1800, 55), (2400, 150), (1800, 55)]
        // Intervals with 4-min recoveries at 70: the interior recoveries stay.
        let intervals: [(secs: Int, bpm: Int)] = [(1800, 55), (600, 160), (240, 70), (600, 160), (240, 70), (600, 160), (1800, 55)]
        return [
            Case(name: "warm-up blip", segs: blip, reference: (at(blip, 3), at(blip, 4))),
            Case(name: "cooldown walk", segs: cooldown, reference: (at(cooldown, 1), at(cooldown, 2))),
            Case(name: "settling before", segs: settle, reference: (at(settle, 2), at(settle, 3))),
            Case(name: "steady", segs: steady, reference: (at(steady, 1), at(steady, 2))),
            Case(name: "intervals", segs: intervals, reference: (at(intervals, 1), at(intervals, 6))),
        ]
    }

    func testTrimRemovesUnsupportedEdgesAndKeepsTheRest() {
        var table = ["case | reference | untrimmed | trimmed | edge error before → after (s)"]
        for c in cases {
            let hr = series(c.segs)
            let before = detect(hr, trim: false), after = detect(hr)
            XCTAssertEqual(before.count, 1, c.name); XCTAssertEqual(after.count, 1, c.name)
            guard let b = before.first, let a = after.first else { continue }
            let ref = (t0 + c.reference.0, t0 + c.reference.1)
            let errB = abs(b.start - ref.0) + abs(b.end - ref.1), errA = abs(a.start - ref.0) + abs(a.end - ref.1)
            table.append("\(c.name) | \(c.reference.1 - c.reference.0) s | \(b.end - b.start) s | \(a.end - a.start) s | \(errB) → \(errA)")
            XCTAssertLessThanOrEqual(errA, errB, "\(c.name): trimming never moves an edge away from the activity")
            XCTAssertLessThan(errA, 2 * WorkoutDetector.edgeWindowS, "\(c.name): within a window of the reference")
            XCTAssertLessThan(a.start, a.end, c.name)
            XCTAssertEqual(a.activeS + a.pausedS + a.unknownS, a.end - a.start, "\(c.name): accounting still partitions the span")
        }
        print(table.joined(separator: "\n"))
    }

    func testUnchangedCasesStayUnchanged() {
        for name in ["steady", "intervals"] {
            let c = cases.first { $0.name == name }!
            let hr = series(c.segs)
            XCTAssertEqual(detect(hr), detect(hr, trim: false), "\(name): nothing unsupported at the edges")
        }
        // Interior recoveries are pauses of the session, not trimmed away.
        let c = cases.first { $0.name == "intervals" }!
        let e = detect(series(c.segs)).first!
        XCTAssertGreaterThanOrEqual(e.pausedS, 2 * 240 - 120)
    }

    func testTrimIsDeterministicAndRespectsMinimumActiveTime() {
        let hr = series(cases[0].segs)
        XCTAssertEqual(detect(hr), detect(hr))
        // 14 min of effort padded by 4 min of band time: untrimmed it would pass on wall-clock, trimmed it's too short.
        let short = series([(1800, 55), (240, 93), (840, 140), (240, 93), (1800, 55)])
        for e in detect(short) { XCTAssertGreaterThanOrEqual(Double(e.activeS), WorkoutDetector.hrOnlyMinMin * 60) }
    }

    func testRecordingGapAtTheEdgeIsNotCountedAsWorkout() {
        // The strap stops recording during the cooldown: the session ends at the last supported sample, never inside the gap.
        let segs: [(secs: Int, bpm: Int)] = [(1800, 55), (2400, 150), (900, 92), (1800, 55)]
        let hr = series(segs, gapAt: 1800 + 2400 + 60, gapS: 600)
        let e = detect(hr).first!
        XCTAssertLessThanOrEqual(e.end, t0 + 1800 + 2400 + 60)
        XCTAssertTrue(hr.contains { $0.ts == e.end - 1 }, "edges land on real samples")
    }
}

