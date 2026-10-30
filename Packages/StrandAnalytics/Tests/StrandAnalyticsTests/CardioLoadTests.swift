import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Accounting and arithmetic invariants of the load pipeline. These check bookkeeping against hand-worked values; they
/// say nothing about whether any number reflects true physiological strain.
final class SupportedHRTests: XCTestCase {
    private let t = 1_700_000_000

    private func run(_ start: Int, _ n: Int, _ bpm: Int, step: Int = 1) -> [HRSample] {
        stride(from: 0, to: n, by: step).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testConstantHRGivesAnalyticalLoad() {
        // 10 min in Z3 of HRmax 200 (150 bpm): 10 × 0.347 fitted, 10 × 3 Edwards.
        let s = LoadSummary(SupportedHR(raw: run(t, 600, 150)), requestedS: 600, hrMax: 200)
        XCTAssertEqual(s.zoneLoad, 3.47, accuracy: 1e-9)
        XCTAssertEqual(s.edwardsLoad, 30, accuracy: 1e-9)
        XCTAssertEqual(s.meanHR!, 150, accuracy: 1e-9)
        XCTAssertEqual(s.coverage, 1, accuracy: 1e-12)
    }

    func testSamplingRatesWithinTheHoldAgree() {
        // 1 Hz, 0.5 Hz and 0.2 Hz describe the same constant signal while the spacing stays inside the bounded hold.
        let load = { (step: Int) in LoadSummary(SupportedHR(raw: self.run(self.t, 600, 150, step: step)), requestedS: 600, hrMax: 200).zoneLoad }
        XCTAssertEqual(load(1), load(2), accuracy: 0.01)
        XCTAssertEqual(load(1), load(5), accuracy: 0.03)
    }

    func testSamplingBeyondTheHoldStaysUnobserved() {
        // One reading a minute: each supports 5 s, so 55 s of every minute is unknown, however constant the HR looks.
        let s = LoadSummary(SupportedHR(raw: run(t, 600, 150, step: 60)), requestedS: 600, hrMax: 200)
        XCTAssertEqual(s.observedS, 9 * 5 + 1)
        XCTAssertEqual(s.heldS, 9 * 4)
        XCTAssertEqual(s.unknownS, 600 - 46)
    }

    func testIrregularFirstGapDoesNotScaleEveryRow() {
        // Previously every row inherited the first gap: a single late reading more than doubled strain.
        var hr = run(t, 600, 170)
        let regular = LoadSummary(SupportedHR(raw: hr), requestedS: 660, hrMax: 190).zoneLoad
        hr[0] = HRSample(ts: t - 59, bpm: 170)
        let irregular = LoadSummary(SupportedHR(raw: hr), requestedS: 660, hrMax: 190).zoneLoad
        XCTAssertEqual(irregular, regular, accuracy: 0.1)
    }

    func testOrderAndRepeatedIngestionDoNotChangeTheResult() {
        let hr = run(t, 900, 150) + run(t + 1200, 900, 165)
        let once = SupportedHR(raw: hr)
        XCTAssertEqual(SupportedHR(raw: hr.reversed()), once)
        XCTAssertEqual(SupportedHR(raw: hr + hr + hr.shuffled()), once)
    }

    func testConflictingReadingsResolveByRuleNotArrivalOrder() {
        let a = HRSample(ts: t, bpm: 150), b = HRSample(ts: t, bpm: 90), bad = HRSample(ts: t, bpm: 300)
        XCTAssertEqual(HRQuality.clean([a, b]), HRQuality.clean([b, a]))
        XCTAssertEqual(HRQuality.clean([a, b]).first?.bpm, 90)
        XCTAssertEqual(HRQuality.clean([bad, a]).first?.bpm, 150, "an out-of-range reading never wins a timestamp")
        XCTAssertEqual(HRQuality.cleanWithReport([bad, a, b]).report.duplicates, 1)
    }

    func testGapsDoNotBecomeObservedTime() {
        let support = SupportedHR(raw: [HRSample(ts: t, bpm: 160), HRSample(ts: t + 3600, bpm: 160)])
        let s = LoadSummary(support, requestedS: 3601, hrMax: 190)
        XCTAssertEqual(s.observedS, 6)
        XCTAssertEqual(s.measuredS, 2)
        XCTAssertEqual(s.heldS, 4)
        XCTAssertEqual(s.unknownS, 3595)
        XCTAssertEqual(SupportedHR(raw: [HRSample(ts: t, bpm: 160)]).observedSeconds, 1, "last reading: its own second, no hold")
    }

    func testClippingAtMidnightAssignsEachSecondOnce() {
        // A hold crossing midnight (two readings 5 s apart) splits by elapsed time: 2 s before, 3 s after.
        let midnight = t + 2
        let support = SupportedHR(raw: [HRSample(ts: t, bpm: 150), HRSample(ts: t + 5, bpm: 150)])
        let before = support.clipped(to: TimeSpan(midnight - 86_400, midnight))
        let after = support.clipped(to: TimeSpan(midnight, midnight + 86_400))
        XCTAssertEqual(before.observedSeconds, 2)
        XCTAssertEqual(after.observedSeconds, 4, "3 s of the hold plus the second reading's own second")
        XCTAssertEqual(before.observedSeconds + after.observedSeconds, support.observedSeconds)
    }

    func testExclusionIsSubtractedExactly() {
        // Previously only samples STARTING in the exclusion were removed, so a held span kept running through it.
        let support = SupportedHR(raw: run(t, 100, 150))
        XCTAssertEqual(support.clipped(to: TimeSpan(t, t + 100), excluding: [TimeSpan(t + 10, t + 40)]).observedSeconds, 70)
        XCTAssertEqual(support.clipped(to: TimeSpan(t, t + 100), excluding: [TimeSpan(t + 10, t + 40), TimeSpan(t + 30, t + 50)]).observedSeconds, 60)
        // An exclusion inside a single held interval cuts it.
        let held = SupportedHR(raw: [HRSample(ts: t, bpm: 150), HRSample(ts: t + 5, bpm: 150)])
        XCTAssertEqual(held.clipped(to: TimeSpan(t, t + 5), excluding: [TimeSpan(t + 2, t + 3)]).observedSeconds, 4)
    }

    func testZeroAndInvertedWindowsAreEmpty() {
        let support = SupportedHR(raw: run(t, 60, 150))
        XCTAssertEqual(support.clipped(to: TimeSpan(t, t)).observedSeconds, 0)
        XCTAssertEqual(support.clipped(to: TimeSpan(t + 10, t)).observedSeconds, 0)
        let s = LoadSummary(SupportedHR(cleaned: []), requestedS: 0, hrMax: 190)
        XCTAssertEqual(s.coverage, 0)
        XCTAssertNil(s.meanHR)
        XCTAssertEqual(s.zoneLoad, 0)
    }

    func testMeanHRIsTimeWeighted() {
        // 10 min at 100 at 1 Hz, then 10 min at 180 sampled every 5 s: equal time, so the mean is 140, not the row mean.
        let hr = run(t, 600, 100) + run(t + 600, 600, 180, step: 5)
        XCTAssertEqual(LoadSummary(SupportedHR(raw: hr), requestedS: 1200, hrMax: 200).meanHR!, 140, accuracy: 0.5)
    }

    func testTimeInZoneCountsOnlySupportedSeconds() {
        // Previously two readings 5 h apart reported 5 h in the zone.
        let z = HRZones.timeInZone([HRSample(ts: t, bpm: 150), HRSample(ts: t + 18_000, bpm: 150)], zoneSet: HRZones.zones(maxHR: 190))
        XCTAssertEqual(z.total, 6, accuracy: 1e-9)
    }
}

final class LoadMethodTests: XCTestCase {
    private let t = 1_700_000_000
    private func hr(_ segs: [(Int, Int)]) -> SupportedHR {
        var out: [HRSample] = [], ts = t
        for (n, bpm) in segs { for _ in 0..<n { out.append(HRSample(ts: ts, bpm: bpm)); ts += 1 } }
        return SupportedHR(raw: out)
    }

    func testEdwardsTenMinutesInEachBandIs150() {
        // HRmax 200: 110, 130, 150, 170, 190 sit in bands 1…5.
        let s = LoadSummary(hr([(600, 110), (600, 130), (600, 150), (600, 170), (600, 190)]), requestedS: 3000, hrMax: 200)
        XCTAssertEqual(s.edwardsLoad, 150, accuracy: 1e-9)
    }

    func testEdwardsBandEdges() {
        let edge = { (bpm: Int) -> Double in LoadSummary(self.hr([(60, bpm)]), requestedS: 60, hrMax: 200).edwardsLoad }
        XCTAssertEqual(edge(99), 0)    // below 50 %
        XCTAssertEqual(edge(100), 1)   // 50 % belongs to band 1
        XCTAssertEqual(edge(119), 1)
        XCTAssertEqual(edge(120), 2)
        XCTAssertEqual(edge(140), 3)
        XCTAssertEqual(edge(160), 4)
        XCTAssertEqual(edge(180), 5)
        XCTAssertEqual(edge(200), 5)   // 100 % is inclusive
    }

    func testHRAboveMaxScoresInTopBandAndIsFlagged() {
        let s = LoadSummary(hr([(60, 205)]), requestedS: 60, hrMax: 200)
        XCTAssertEqual(s.edwardsLoad, 5)
        XCTAssertEqual(s.aboveMaxS, 60)
    }

    func testHRmaxAndHRRAreDifferentZoneSystems() {
        // 120 bpm, rest 60, max 180: 66.7 % HRmax (band 2) but 50 % HRR (band 1).
        let cal = HRCalibration(hrMax: 180, hrMaxSource: .declared, restingHR: 60, restingSource: .declared)
        let support = hr([(60, 120)])
        XCTAssertEqual(LoadSummary(support, requestedS: 60, hrMax: 180).edwardsLoad, 2)
        XCTAssertEqual(CardioLoad.edwardsHRRVariant(support, calibration: cal), 1)
    }

    func testBanisterCoefficientPairsAndAggregations() {
        // x = (150 − 60) / (180 − 60) = 0.75 for 30 min: 30 × 0.75 × a × e^(b × 0.75).
        let cal = HRCalibration(hrMax: 180, hrMaxSource: .declared, restingHR: 60, restingSource: .declared)
        let male = 30 * 0.75 * 0.64 * exp(1.92 * 0.75), female = 30 * 0.75 * 0.86 * exp(1.67 * 0.75)
        let steady = hr([(1800, 150)])
        XCTAssertEqual(CardioLoad.banisterIntegrated(steady, calibration: cal, coefficients: .historicalMaleFormulation)!, male, accuracy: 1e-6)
        XCTAssertEqual(CardioLoad.banisterIntegrated(steady, calibration: cal, coefficients: .historicalFemaleFormulation)!, female, accuracy: 1e-6)
        XCTAssertEqual(CardioLoad.banisterSessionMean(steady, calibration: cal, coefficients: .historicalMaleFormulation)!, male, accuracy: 1e-6)

        // Variable intensity: x of 0.25 and 1.0 for 15 min each. The exponential makes the integrated form the larger.
        let mixed = hr([(900, 90), (900, 180)])
        let c = BanisterCoefficients.historicalMaleFormulation
        let integrated = 15 * 0.25 * c.a * exp(c.b * 0.25) + 15 * 1.0 * c.a * exp(c.b)
        let sessionMean = 30 * 0.625 * c.a * exp(c.b * 0.625)
        XCTAssertEqual(CardioLoad.banisterIntegrated(mixed, calibration: cal, coefficients: c)!, integrated, accuracy: 1e-6)
        XCTAssertEqual(CardioLoad.banisterSessionMean(mixed, calibration: cal, coefficients: c)!, sessionMean, accuracy: 1e-6)
        XCTAssertGreaterThan(integrated, sessionMean)
    }

    func testBanisterClipsOutOfRangeAndNeedsAValidReserve() {
        let cal = HRCalibration(hrMax: 180, hrMaxSource: .declared, restingHR: 60, restingSource: .declared)
        let c = BanisterCoefficients.historicalMaleFormulation
        XCTAssertEqual(CardioLoad.banisterIntegrated(hr([(60, 50)]), calibration: cal, coefficients: c), 0)
        XCTAssertEqual(CardioLoad.banisterIntegrated(hr([(60, 220)]), calibration: cal, coefficients: c)!, c.a * exp(c.b), accuracy: 1e-9)
        for bad in [HRCalibration(hrMax: 60, hrMaxSource: .declared, restingHR: 60, restingSource: .declared),
                    HRCalibration(hrMax: 50, hrMaxSource: .declared, restingHR: 60, restingSource: .declared),
                    HRCalibration(hrMax: 180, hrMaxSource: .declared, restingHR: nil, restingSource: .unavailable)] {
            XCTAssertNil(CardioLoad.banisterIntegrated(hr([(60, 150)]), calibration: bad, coefficients: c))
            XCTAssertNil(CardioLoad.banisterSessionMean(hr([(60, 150)]), calibration: bad, coefficients: c))
            XCTAssertNil(CardioLoad.edwardsHRRVariant(hr([(60, 150)]), calibration: bad))
            XCTAssertNil(CardioLoad.meanPercentHRR(hr([(60, 150)]), calibration: bad))
        }
    }

    func testRegistryMarksOnlyAdditiveMethodsAdditiveAndNamesMissingInputs() {
        XCTAssertTrue(LoadMethod.banisterIntegrated.descriptor.additive)
        XCTAssertFalse(LoadMethod.banisterSessionMean.descriptor.additive)
        XCTAssertNil(LoadMethod.edwards.descriptor.missingInput)
        XCTAssertNotNil(LoadMethod.sessionRPE.descriptor.missingInput)
        XCTAssertNotNil(LoadMethod.powerTSS.descriptor.missingInput)
    }

    func testStoredEffortReadsBackAsTheSameLoadAndOnlyOnItsOwnScale() {
        let rpe = SessionRPE(rpe: 7, sessionMinutes: 45, collectedAt: t)!
        let row = rpe.row(workoutStartTs: 100, workoutEndTs: 2800)
        XCTAssertEqual(row.scale, "CR10")
        XCTAssertEqual(row.provenance, TrainingLogProvenance.userEntered)
        XCTAssertEqual(SessionRPE(row: row), rpe)
        XCTAssertEqual(SessionRPE(row: row)?.load, 315)
        let borg = SessionEffortRow(workoutStartTs: 100, workoutEndTs: 2800, scale: "Borg6-20", rpe: 7, sessionMinutes: 45, collectedAt: t)
        XCTAssertNil(SessionRPE(row: borg), "a load is only computed from the scale it's defined on")
    }

    func testTypedSetsNeverTurnAmbiguousInputIntoBodyweight() {
        XCTAssertEqual(StrengthSet(exercise: " Squat ", reps: "5", kg: "62,5", rir: " 2 "),
                       StrengthSet(exercise: "Squat", reps: 5, externalKg: 62.5, rir: 2))
        let bodyweight = StrengthSet(exercise: "Pull-up", reps: "10", kg: " ", rir: "")
        XCTAssertEqual(bodyweight, StrengthSet(exercise: "Pull-up", reps: 10, externalKg: nil))
        XCTAssertEqual(StrengthSet(exercise: "Sled", reps: "8", kg: "0", rir: "")?.externalKg, 0, "typed zero is not blank")
        XCTAssertNil(StrengthSet(exercise: "Squat", reps: "5", kg: "abc", rir: ""), "a typo is not bodyweight")
        XCTAssertNil(StrengthSet(exercise: "Squat", reps: "5", kg: "-20", rir: ""))
        XCTAssertNil(StrengthSet(exercise: "Squat", reps: "5", kg: "nan", rir: ""))
        XCTAssertNil(StrengthSet(exercise: "Squat", reps: "5", kg: "100", rir: "x"))
        XCTAssertNil(StrengthSet(exercise: "Squat", reps: "0", kg: "100", rir: ""))
        XCTAssertNil(StrengthSet(exercise: "  ", reps: "5", kg: "100", rir: ""))
    }

    func testExerciseSummariesStayPerExerciseAndAddNoBodyMass() {
        let s = StrengthVolume.summaries([StrengthSet(exercise: "squat", reps: 5, externalKg: 100),
                                          StrengthSet(exercise: "pull-up", reps: 10, externalKg: nil),
                                          StrengthSet(exercise: "squat", reps: 5, externalKg: 80)])
        XCTAssertEqual(s, [.init(exercise: "squat", sets: 2, reps: 10, volumeKg: 900),
                           .init(exercise: "pull-up", sets: 1, reps: 10, volumeKg: nil)])
    }

    func testSessionRPEAndStrengthVolumeAreOnlyWhatWasReported() {
        XCTAssertEqual(SessionRPE(rpe: 7, sessionMinutes: 45, collectedAt: t)?.load, 315)
        XCTAssertNil(SessionRPE(rpe: 11, sessionMinutes: 45, collectedAt: t))
        XCTAssertNil(SessionRPE(rpe: 7, sessionMinutes: 0, collectedAt: t))
        let v = StrengthVolume.byExercise([StrengthSet(exercise: "squat", reps: 5, externalKg: 100),
                                           StrengthSet(exercise: "squat", reps: 5, externalKg: 100, rir: 2),
                                           StrengthSet(exercise: "pull-up", reps: 10, externalKg: nil)])
        XCTAssertEqual(v, ["squat": 1000], "bodyweight work has no entry rather than a guessed mass")
    }
}

final class HRCalibrationTests: XCTestCase {
    func testDeclaredMaxMayBeBelowThePopulationEstimate() {
        let c = HRCalibration.resolve(declaredMax: 170, age: 30)
        XCTAssertEqual(c.hrMax, 170)
        XCTAssertEqual(c.hrMaxSource, .declared)
        XCTAssertFalse(c.hrMaxIsEstimate)
    }

    func testTanakaIsALabelledEstimateAndNothingIsInventedWithoutAge() {
        let c = HRCalibration.resolve(declaredMax: nil, age: 30)
        XCTAssertEqual(c.hrMax, 187)
        XCTAssertTrue(c.hrMaxIsEstimate)
        let none = HRCalibration.resolve(declaredMax: nil, age: nil)
        XCTAssertNil(none.hrMax)
        XCTAssertEqual(none.hrMaxSource, .unavailable)
        XCTAssertNil(none.restingHR, "no hidden 60 bpm")
    }

    func testRestingPrefersTonightThenTheCausalReference() {
        XCTAssertEqual(HRCalibration.resolve(declaredMax: 190, age: nil, sleepResting: 50, causalResting: 55).restingSource, .sameDaySleep)
        XCTAssertEqual(HRCalibration.resolve(declaredMax: 190, age: nil, causalResting: 55).restingSource, .causalSleepReference)
        XCTAssertNil(HRCalibration.resolve(declaredMax: 100, age: nil, sleepResting: 120).restingHR, "rest ≥ max is unusable")
    }

    func testAnImplausibleDeclaredValueDoesNotBecomeTheCalibration() {
        XCTAssertEqual(HRCalibration.resolve(declaredMax: 2000, age: 30).hrMaxSource, .tanaka)
        XCTAssertEqual(HRCalibration.resolve(declaredMax: .nan, age: nil).hrMaxSource, .unavailable)
    }

    func testSnapshotRoundTripsThroughStorage() throws {
        let c = HRCalibration.resolve(day: "2026-01-01", declaredMax: 200, age: 30, sleepResting: 50)
        XCTAssertEqual(try JSONDecoder().decode(HRCalibration.self, from: JSONEncoder().encode(c)), c)
    }
}

final class DayLoadTests: XCTestCase {
    private let from = 1_700_000_000
    private let profile = UserProfile(age: 30)

    private func run(_ start: Int, _ n: Int, _ bpm: Int) -> [HRSample] { (0..<n).map { HRSample(ts: start + $0, bpm: bpm) } }

    private func analyze(_ hr: [HRSample], maxHR: Double? = 190, calibration: HRCalibration? = nil,
                         known: [TimeSpan] = [], profile: UserProfile? = nil, length: Int = 86_400) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: "2026-01-01", hr: hr, profile: profile ?? self.profile, maxHROverride: maxHR,
                                   dayRange: (from, from + length), calibration: calibration, knownSessions: known)
    }

    /// Hard day: a full day of observed HR with a 40-min effort and 90 min of incidental Zone 1.
    private func fullDay() -> [HRSample] {
        run(from, 20_000, 60) + run(from + 20_000, 2400, 165) + run(from + 22_400, 5400, 100) + run(from + 27_800, 58_600, 60)
    }

    func testDailyLoadIsIndependentOfHowSessionsAreGrouped() {
        // Same seconds of HR; only the attribution of the effort to sessions differs.
        let hr = fullDay()
        let none = analyze(hr, known: []).load!
        let one = analyze(hr, known: [TimeSpan(from + 20_000, from + 22_400)]).load!
        let split = analyze(hr, known: [TimeSpan(from + 20_000, from + 21_000), TimeSpan(from + 21_000, from + 22_400)]).load!
        XCTAssertEqual(none.summary!.zoneLoad, one.summary!.zoneLoad, accuracy: 1e-9)
        XCTAssertEqual(one.summary!.zoneLoad, split.summary!.zoneLoad, accuracy: 1e-9)
        XCTAssertEqual(one.strainIndex, split.strainIndex)
        XCTAssertEqual(one.exerciseLoad!, split.exerciseLoad!, accuracy: 1e-9)
    }

    func testDuplicatedSessionRecordsDoNotDoubleCount() {
        let hr = fullDay()
        let s = TimeSpan(from + 20_000, from + 22_400)
        let once = analyze(hr, known: [s]).load!
        let twice = analyze(hr, known: [s, s, TimeSpan(s.start + 100, s.end - 100)]).load!
        XCTAssertEqual(once.exerciseLoad!, twice.exerciseLoad!, accuracy: 1e-9)
        XCTAssertEqual(once.summary!.zoneLoad, twice.summary!.zoneLoad, accuracy: 1e-9)
    }

    func testLoadPartitionsIntoExerciseAndIncidental() {
        let l = analyze(fullDay()).load!
        XCTAssertEqual(l.exerciseLoad! + l.incidentalLoad!, l.summary!.zoneLoad, accuracy: 1e-9)
        XCTAssertGreaterThan(l.incidentalLoad!, 0, "elevated HR outside a session is load, not a workout")
    }

    func testIncidentalHRIsNotAWorkoutButStillCounts() {
        // 10 minutes in Z4: too short for an episode, but the seconds are real.
        let hr = run(from, 30_000, 60) + run(from + 30_000, 600, 160) + run(from + 30_600, 55_800, 60)
        let r = analyze(hr)
        XCTAssertEqual(r.workouts.count, 0)
        XCTAssertEqual(r.load!.summary!.zoneLoad, 7.49, accuracy: 1e-9)
    }

    func testMissingDiffersFromMeasuredZero() {
        let none = analyze([]).load!
        XCTAssertNil(none.strainIndex)
        XCTAssertEqual(none.status, .insufficient)
        XCTAssertEqual(none.reasons, [LoadReason.noHeartRate])

        let rest = analyze(run(from, 86_400, 60)).load!
        XCTAssertEqual(rest.strainIndex, 0)
        XCTAssertEqual(rest.status, .complete)
    }

    func testIncompleteDayIsPartialAndNeverExtrapolated() {
        let l = analyze(run(from, 21_600, 60) + run(from + 21_600, 1800, 165)).load!
        XCTAssertEqual(l.status, .partial)
        XCTAssertTrue(l.reasons.contains(LoadReason.partialDay))
        XCTAssertEqual(l.summary!.coverage, 23_400.0 / 86_400.0, accuracy: 1e-9)
        XCTAssertEqual(l.summary!.zoneLoad, 30 * 0.749, accuracy: 1e-6, "the observed load, not scaled to a full day")
    }

    func testObservedTimeNotRowCountDecidesSufficiency() {
        // Former rule: 600 rows. 700 rows spread over a dropout-free 700 s scores; 599 s does not.
        XCTAssertNil(analyze(run(from, 599, 60)).load!.strainIndex)
        XCTAssertNotNil(analyze(run(from, 600, 60)).load!.strainIndex)
    }

    func testCoverageFollowsTheDeclaredDayLength() {
        // A 23-hour DST day: the same observed time is a larger share.
        let hr = run(from, 82_800, 60)
        XCTAssertEqual(analyze(hr, length: 82_800).load!.summary!.coverage, 1, accuracy: 1e-12)
        XCTAssertEqual(analyze(hr, length: 86_400).load!.summary!.coverage, 82_800.0 / 86_400.0, accuracy: 1e-12)
    }

    func testNoUsableHRmaxWithholdsLoadWithAReason() {
        let l = analyze(fullDay(), maxHR: nil, profile: UserProfile(age: 0)).load!
        XCTAssertEqual(l.status, .calibrationUnavailable)
        XCTAssertNil(l.strainIndex)
        XCTAssertNil(l.summary)
        XCTAssertTrue(l.reasons.contains(LoadReason.hrMaxUnavailable))
        XCTAssertTrue(analyze(fullDay(), maxHR: nil, profile: UserProfile(age: 0)).workouts.isEmpty)
    }

    func testFlagsAreRecordedNotHidden() {
        let hr = run(from, 86_400, 60).enumerated().map { $0.offset < 120 ? HRSample(ts: $0.element.ts, bpm: 200) : $0.element }
        let l = analyze(hr).load!
        XCTAssertTrue(l.reasons.contains(LoadReason.hrAboveConfiguredMax))
        XCTAssertTrue(analyze(hr, maxHR: nil).load!.reasons.contains(LoadReason.hrMaxIsEstimate))
    }

    func testFutureObservationsDoNotAlterAnEarlierResultUnderFrozenCalibration() {
        let hr = fullDay()
        let first = analyze(hr, maxHR: 190).load!
        // A later hard day arrives and the profile's HRmax changes. The frozen day is scored exactly as before.
        let later = run(from + 86_400, 3600, 195)
        let again = analyze(hr + later, maxHR: 170, calibration: first.calibration).load!
        XCTAssertEqual(again, first)
    }

    func testFrozenSnapshotDrivesDetectionLoadAndZonesAlike() {
        // Without the freeze a new HRmax moves the zone floor and every band. With it, nothing moves.
        let hr = fullDay()
        let cal = HRCalibration(hrMax: 190, hrMaxSource: .declared, restingHR: 55, restingSource: .declared)
        let a = analyze(hr, maxHR: 210, calibration: cal), b = analyze(hr, maxHR: 150, calibration: cal)
        XCTAssertEqual(a.load, b.load)
        XCTAssertEqual(a.workouts, b.workouts)
        XCTAssertEqual(a.workouts.first?.load.calibration, cal)
    }

    func testDetectorEngineAndRecordAgreeOnOneSession() {
        // Canonical path: what the session reports is what the day attributes; there is no second calculation to drift.
        let r = analyze(fullDay())
        let w = try! XCTUnwrap(r.workouts.first)
        XCTAssertEqual(r.workouts.count, 1)
        XCTAssertEqual(w.load.summary.zoneLoad, r.load!.exerciseLoad!, accuracy: 1e-9)
        XCTAssertEqual(w.strain, StrainScorer.activityIndex(load: w.load.summary.zoneLoad))
        XCTAssertEqual(w.avgHR, w.load.summary.meanHR)
        XCTAssertEqual(w.zoneTimePct, w.load.summary.zonePercent)
        XCTAssertEqual(r.strain, r.load?.strainIndex)
        XCTAssertEqual(r.daily.strain, r.load?.strainIndex)
    }

    func testLoadRecordRoundTripsThroughStorage() throws {
        let l = analyze(fullDay()).load!
        XCTAssertEqual(try JSONDecoder().decode(DayLoadRecord.self, from: JSONEncoder().encode(l)), l)
        let w = analyze(fullDay()).workouts[0].load
        XCTAssertEqual(try JSONDecoder().decode(SessionLoadRecord.self, from: JSONEncoder().encode(w)), w)
    }

    func testProvenanceCarriesCoverageVersionAndReasons() {
        let p = ProvenanceKey.records(forLoad: analyze(run(from, 21_600, 60)).load!, scoringVersion: 4)
        let strain = p.first { $0.key == ProvenanceKey.strain }!
        XCTAssertEqual(strain.algorithmVersion, StrainScorer.indexVersion)
        XCTAssertEqual(strain.coverage!, 0.25, accuracy: 1e-9)
        XCTAssertTrue(strain.exclusionReasons.contains(LoadReason.partialDay))
        XCTAssertNotNil(MetricIdentity(record: strain))
        XCTAssertEqual(ProvenanceKey.records(forLoad: analyze([]).load!, scoringVersion: 4)
            .first { $0.key == ProvenanceKey.strain }?.exclusionReasons, ["unavailable", LoadReason.noHeartRate])
    }
}

final class EpisodeDetectionTests: XCTestCase {
    private let t = 1_700_000_000
    private func run(_ start: Int, _ n: Int, _ bpm: Int) -> [HRSample] { (0..<n).map { HRSample(ts: start + $0, bpm: bpm) } }
    private func detect(_ hr: [HRSample], gravity: [GravitySample] = []) -> [ExerciseSession] {
        WorkoutDetector.detect(hr: hr, gravity: gravity, restingHR: 55, maxHR: 190)
    }

    func testTwoHighPointsAnHourApartAreNotAWorkout() {
        XCTAssertTrue(detect([HRSample(ts: t, bpm: 170), HRSample(ts: t + 3600, bpm: 170)]).isEmpty)
    }

    func testTwoShortBurstsAroundAnHourHoleAreNotAWorkout() {
        // Previously a 65-minute session with strain 6.83 from 10 minutes of data.
        XCTAssertTrue(detect(run(t, 300, 150) + run(t + 3600, 300, 150)).isEmpty)
    }

    func testEffortsEitherSideOfALongHoleStayApart() {
        // Previously one 100-minute session.
        let w = detect(run(t, 1200, 150) + run(t + 4800, 1200, 150))
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w.map(\.load.unknownS), [0, 0])
    }

    func testWallSpanAloneDoesNotReachTheMinimum() {
        // 8 min + 2-min hole + 8 min spans 18 min of wall clock but holds 16 of active time; 6 + 3 + 6 holds 12.
        XCTAssertEqual(detect(run(t, 480, 150) + run(t + 600, 480, 150)).count, 1)
        XCTAssertTrue(detect(run(t, 360, 150) + run(t + 540, 360, 150)).isEmpty)
    }

    func testShortSensorGapStaysInsideTheEpisodeAsUnknown() {
        let w = detect(run(t, 1200, 150) + run(t + 1320, 1200, 150))
        XCTAssertEqual(w.count, 1)
        // The last reading's own second sits inside its hold, so a hold of 5 s covers 4 s of the 120 s hole.
        XCTAssertEqual(w[0].load.unknownS, 120 - (SupportedHR.maxHoldS - 1))
        XCTAssertEqual(w[0].load.summary.observedS, 2400 + SupportedHR.maxHoldS - 1)
    }

    func testPauseAndGapAreDifferentThingsAndPartitionElapsedTime() {
        // Observed rest inside a session is a pause; the same stretch unobserved is unknown.
        let w = detect(run(t, 1500, 150) + run(t + 1500, 200, 80) + run(t + 1700, 100, 80) + run(t + 1800, 1500, 150))
        let e = try! XCTUnwrap(w.first)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(e.load.unknownS, 0)
        XCTAssertGreaterThan(e.load.pausedS, 0)
        XCTAssertEqual(e.load.activeS + e.load.pausedS + e.load.unknownS, e.end - e.start)
    }

    func testObservedLongStopBridgesButTheSameHoleDoesNot() {
        let observed = run(t, 1800, 150) + run(t + 1800, 900, 62) + run(t + 2700, 1800, 150)
        XCTAssertEqual(detect(observed).count, 1)
        let hole = run(t, 1800, 150) + run(t + 2700, 1800, 150)
        XCTAssertEqual(detect(hole).count, 2)
    }

    func testMostlyUnknownEpisodeIsRejected() {
        // Bursts bridged across 5-minute holes: 18 active minutes in 33 elapsed is under the coverage bar.
        let hr = run(t, 360, 150) + run(t + 660, 360, 150) + run(t + 1320, 360, 150) + run(t + 1980, 0, 150)
        let w = detect(hr)
        XCTAssertTrue(w.isEmpty, "got \(w.map(\.durationS))")
    }

    func testRepeatedIngestionAndOrderGiveTheSameSessions() {
        let hr = run(t, 1800, 58) + run(t + 1800, 2400, 150) + run(t + 4200, 1800, 58)
        XCTAssertEqual(detect(hr + hr), detect(hr))
        XCTAssertEqual(detect(hr.shuffled()), detect(hr))
    }

    func testDetectionIsIndependentOfTheDaysHRDistribution() {
        // HRmax used to come from the day's own 99.5th percentile, so an unrelated spike moved the zone floor.
        let hr = run(t, 1800, 58) + run(t + 1800, 1800, 110) + run(t + 3600, 1800, 58)
        let spiky = hr + run(t + 6000, 60, 195)
        XCTAssertEqual(WorkoutDetector.detect(hr: hr, gravity: [], age: 30).first?.hrmax,
                       WorkoutDetector.detect(hr: spiky, gravity: [], age: 30).first?.hrmax)
    }

    // MARK: Motion is evidence

    private func gravity(_ start: Int, _ n: Int, moving: Bool) -> [GravitySample] {
        (0..<n).map { GravitySample(ts: start + $0, x: moving ? Double($0 % 2) * 0.5 : 0, y: 0, z: 1) }
    }

    func testStillWristIsReportedNotRejected() {
        let hr = run(t, 2400, 150)
        XCTAssertEqual(detect(hr, gravity: gravity(t, 2400, moving: false)).first?.load.evidence, .heartRateStillWrist)
        XCTAssertEqual(detect(hr, gravity: gravity(t, 2400, moving: true)).first?.load.evidence, .heartRateAndMotion)
        XCTAssertEqual(detect(hr).first?.load.evidence, .heartRateNoMotionData)
        XCTAssertNil(detect(hr).first?.load.movingFraction, "no motion data is not zero motion")
    }

    func testMotionNeverChangesWhatIsDetected() {
        let hr = run(t, 1800, 58) + run(t + 1800, 2400, 150) + run(t + 4200, 1800, 58)
        XCTAssertEqual(detect(hr).map(\.start), detect(hr, gravity: gravity(t, 6000, moving: false)).map(\.start))
        XCTAssertEqual(detect(hr).map(\.end), detect(hr, gravity: gravity(t, 6000, moving: true)).map(\.end))
    }

    func testMotionChangeAcrossAGapIsNotAPerSecondChange() {
        let s = WorkoutDetector.activitySeries([GravitySample(ts: 0, x: 0, y: 0, z: 1), GravitySample(ts: 3600, x: 1, y: 0, z: 0)])
        XCTAssertEqual(s[1].intensity, 0)
    }
}

final class WorkoutReconciliationTests: XCTestCase {
    private func row(_ s: Int, _ e: Int) -> WorkoutRow {
        WorkoutRow(startTs: s, endTs: e, sport: "Activity", source: "noop", durationS: Double(e - s), energyKcal: nil,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testOverlapAloneDoesNotDiscardADistinctActivity() {
        // Previously the longer row silently replaced the other. 20 % of the shorter overlaps: two activities.
        let rows = [row(0, 3600), row(3000, 6000)]
        XCTAssertEqual(WorkoutReconciliation.reconcile(rows), rows)
    }

    func testTheSameEventIsKeptOnceDeterministically() {
        let long = row(0, 3600), inner = row(30, 3570)
        XCTAssertEqual(WorkoutReconciliation.reconcile([inner, long]), [long])
        XCTAssertEqual(WorkoutReconciliation.reconcile([long, inner]), [long])
        XCTAssertEqual(WorkoutReconciliation.reconcile([long, long]), [long])
    }

    func testAdjacentRowsAcrossMidnightStaySeparate() {
        let rows = [row(0, 1000), row(1000, 2000)]
        XCTAssertEqual(WorkoutReconciliation.reconcile(rows), rows)
    }
}

final class DetectionEvaluationTests: XCTestCase {
    private func rec(_ ref: [(Int, Int, String?)], _ pred: [(Int, Int)], days: Double = 1, who: String = "a") -> DetectionEvaluation.Recording {
        .init(participant: who, recordingId: "r", observedDays: days,
              reference: ref.map { .init(span: TimeSpan($0.0, $0.1), label: $0.2) }, predicted: pred.map { TimeSpan($0.0, $0.1) })
    }

    func testPerfectAndEmpty() {
        let r = DetectionEvaluation.evaluate([rec([(0, 1000, "run")], [(0, 1000)])])
        XCTAssertEqual(r.f1, 1)
        XCTAssertEqual(r.recallByLabel, ["run": 1])
        let empty = DetectionEvaluation.evaluate([])
        XCTAssertNil(empty.precision)
        XCTAssertNil(empty.f1)
        XCTAssertNil(empty.falsePositivesPerObservedDay)
    }

    func testMatchingIsOneToOneAtTheBestOverlap() {
        // Two predictions overlap one reference: only the better one matches, the other is a false positive.
        let r = DetectionEvaluation.evaluate([rec([(0, 1000, nil)], [(0, 900), (950, 1100)])])
        XCTAssertEqual(r.truePositives, 1)
        XCTAssertEqual(r.falsePositives, 1)
        XCTAssertEqual(r.fragmented, 1)
        XCTAssertEqual(r.onsetErrorS, 0)
        XCTAssertEqual(r.offsetErrorS, 100)
    }

    func testOverlapBelowTheCriterionIsNotAMatch() {
        let r = DetectionEvaluation.evaluate([rec([(0, 1000, nil)], [(800, 1800)])])
        XCTAssertEqual(r.truePositives, 0)
        XCTAssertEqual(r.falsePositives, 1)
        XCTAssertEqual(r.falseNegatives, 1)
    }

    func testMergingIsReported() {
        let r = DetectionEvaluation.evaluate([rec([(0, 1000, nil), (1200, 2200, nil)], [(0, 2200)])])
        XCTAssertEqual(r.merged, 1)
        XCTAssertEqual(r.truePositives, 0)
    }

    func testNegativeDaysAreTheDenominatorOfFalsePositives() {
        let r = DetectionEvaluation.evaluate([rec([], [(0, 900), (5000, 6000)], days: 8), rec([], [], days: 2, who: "b")])
        XCTAssertEqual(r.falsePositivesPerObservedDay, 0.2)
        XCTAssertEqual(r.participants, 2)
    }
}

final class AwakeLoadTests: XCTestCase {
    private let t = 1_700_000_000
    private var day: TimeSpan { TimeSpan(t, t + 86_400) }
    private let cal = HRCalibration(hrMax: 200, hrMaxSource: .declared, restingHR: 50, restingSource: .declared)

    private func run(_ start: Int, _ n: Int, _ bpm: Int) -> [HRSample] { (0..<n).map { HRSample(ts: start + $0, bpm: bpm) } }
    private func record(_ hr: [HRSample], sleep: [TimeSpan] = [], sessions: [TimeSpan] = [], reasons: [String] = []) -> DayLoadRecord {
        DayLoadRecord.compute(day: "d", span: day, support: SupportedHR(raw: hr), awake: AwakeWindow(sleep: sleep, reasons: reasons),
                              sessions: sessions, calibration: cal, quality: .init())
    }
    private func session(_ stages: [StageSegment], provisional: Bool = false) -> SleepSession {
        SleepSession(start: stages.first!.start, end: stages.last!.end, efficiency: 0.9, stages: stages, restingHR: nil,
                     avgHRV: nil, isProvisional: provisional)
    }

    func testSleepOnlyHRLeavesAwakeStrainAndZonesUnchanged() {
        // Even implausibly high sleep HR: its seconds are not awake time.
        let awake = run(t + 40_000, 3600, 150) + run(t + 50_000, 3600, 90)
        let sleep = TimeSpan(t, t + 28_800)
        let a = record(awake, sleep: [sleep])
        let b = record(awake + run(t, 28_800, 52), sleep: [sleep])
        let c = record(awake + run(t, 28_800, 130), sleep: [sleep])
        XCTAssertEqual(a.summary, b.summary)
        XCTAssertEqual(a.summary, c.summary)
        XCTAssertEqual(a.strainIndex, c.strainIndex)
        // A sleep reading's hold past the end of sleep stays in the full-day count and never reaches awake time.
        XCTAssertEqual(b.dayObservedS, a.dayObservedS + 28_800 + (SupportedHR.maxHoldS - 1), "the full-day count still has it")
        XCTAssertEqual(b.sleepExcludedLoad!, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(c.sleepExcludedLoad!, 0)
    }

    func testAnIntervalStraddlingASleepEdgeIsCutNotDropped() {
        // Readings 5 s apart: the held span crosses the sleep start, and only its awake part stays.
        let hr = [HRSample(ts: t + 1000, bpm: 150), HRSample(ts: t + 1005, bpm: 150)]
        let r = record(hr, sleep: [TimeSpan(t + 1003, t + 2000)])
        XCTAssertEqual(r.summary!.observedS, 3)
        XCTAssertEqual(r.sleepHRS, 3)
    }

    func testAwakeReadingHeldIntoSleepIsCutAtTheEdge() {
        let hr = [HRSample(ts: t + 1000, bpm: 150), HRSample(ts: t + 1100, bpm: 150)]
        XCTAssertEqual(record(hr, sleep: [TimeSpan(t + 1002, t + 1050)]).summary!.observedS, 2 + 1, "own second, 1 s of hold, later reading")
    }

    func testNapsAreExcludedLikeNights() {
        let hr = run(t, 86_400, 110)
        let r = record(hr, sleep: [TimeSpan(t, t + 25_200), TimeSpan(t + 50_000, t + 53_600)])
        XCTAssertEqual(r.summary!.observedS, 86_400 - 25_200 - 3600)
        XCTAssertEqual(r.sleepExcludedS, 25_200 + 3600)
    }

    func testZoneZeroShowsButAddsNoLoad() {
        let r = record(run(t, 86_400, 80))
        XCTAssertEqual(r.summary!.zoneSeconds[0], 86_400)
        XCTAssertEqual(r.summary!.zoneLoad, 0)
        XCTAssertEqual(r.strainIndex, 0, "a long awake day below Zone 1 gets no baseline")
    }

    func testIncidentalAwakeLoadCountsWithoutAWorkout() {
        let r = record(run(t, 86_400, 60).filter { $0.ts < t + 30_000 } + run(t + 30_000, 600, 170) + run(t + 30_600, 55_800, 60))
        XCTAssertEqual(r.exerciseLoad, 0)
        XCTAssertGreaterThan(r.incidentalLoad!, 0)
        XCTAssertEqual(r.incidentalLoad!, r.summary!.zoneLoad, accuracy: 1e-9)
    }

    func testSplitOrMergedSessionsPreserveAwakeLoadAroundSleep() {
        let hr = run(t, 3600, 60) + run(t + 3600, 3600, 150) + run(t + 7200, 79_200, 60)
        let sleep = [TimeSpan(t + 5000, t + 6000)]   // a nap inside the effort
        let merged = record(hr, sleep: sleep, sessions: [TimeSpan(t + 3600, t + 7200)])
        let split = record(hr, sleep: sleep, sessions: [TimeSpan(t + 3600, t + 5500), TimeSpan(t + 5500, t + 7200)])
        XCTAssertEqual(merged.summary, split.summary)
        XCTAssertEqual(merged.exerciseLoad!, split.exerciseLoad!, accuracy: 1e-9)
        XCTAssertEqual(merged.exerciseLoad! + merged.incidentalLoad!, merged.summary!.zoneLoad, accuracy: 1e-9)
    }

    func testAwakeCoverageIgnoresSleepAndCountsOnlySupportedSeconds() {
        // 8 h asleep, 16 h awake with HR for 12 of them: 75 % of awake time, however much of the night was recorded.
        let sleep = [TimeSpan(t, t + 28_800)]
        let r = record(run(t + 28_800, 43_200, 70), sleep: sleep)
        XCTAssertEqual(r.summary!.requestedS, 57_600)
        XCTAssertEqual(r.summary!.observedS, 43_200)
        XCTAssertEqual(r.summary!.coverage, 0.75, accuracy: 1e-9)
        XCTAssertEqual(r.status, .partial)
        XCTAssertTrue(r.provisional)
    }

    func testWakeEpochsInsideASessionStayAwakeAndUnknownEpochsStayIn() {
        let s = session([StageSegment(start: t, end: t + 3600, stage: "deep"),
                         StageSegment(start: t + 3600, end: t + 3900, stage: "wake"),
                         StageSegment(start: t + 3900, end: t + 5400, stage: "unknown", reason: SleepStateReason.noMotionData),
                         StageSegment(start: t + 5400, end: t + 9000, stage: "light")])
        let w = AwakeWindow.classify([s], span: day, laterDataChecked: true, lastObservedTs: t + 80_000)
        XCTAssertEqual(w.sleep, [TimeSpan(t, t + 3600), TimeSpan(t + 5400, t + 9000)])
        XCTAssertEqual(w.uncertain, [TimeSpan(t + 3900, t + 5400)])
        XCTAssertTrue(w.reasons.contains(LoadReason.sleepStateUnknown))

        let r = DayLoadRecord.compute(day: "d", span: day, support: SupportedHR(raw: run(t, 86_400, 60)), awake: w,
                                      sessions: [], calibration: cal, quality: .init())
        XCTAssertEqual(r.uncertainStateS, 1500)
        XCTAssertEqual(r.summary!.observedS, 86_400 - 7200, "unknown state is counted, not assumed asleep")
        XCTAssertTrue(r.provisional)
    }

    func testMissingSleepIsNotProofOfWakeButIsNotInventedEither() {
        let w = AwakeWindow.classify([], span: day, laterDataChecked: true, lastObservedTs: t + 86_400)
        XCTAssertTrue(w.sleep.isEmpty)
        XCTAssertEqual(w.reasons, [LoadReason.noSleepClassified])
        let r = DayLoadRecord.compute(day: "d", span: day, support: SupportedHR(raw: run(t, 86_400, 60)), awake: w,
                                      sessions: [], calibration: cal, quality: .init())
        XCTAssertEqual(r.status, .complete)
        XCTAssertTrue(r.provisional, "complete coverage, but the sleep/wake split is unconfirmed")
    }

    func testANightCrossingMidnightIsClippedExactly() {
        let night = session([StageSegment(start: t - 7200, end: t + 3600, stage: "light")])
        let previous = TimeSpan(t - 86_400, t), today = day
        XCTAssertEqual(AwakeWindow.classify([night], span: previous, laterDataChecked: true, lastObservedTs: t).sleep,
                       [TimeSpan(t - 7200, t)])
        XCTAssertEqual(AwakeWindow.classify([night], span: today, laterDataChecked: true, lastObservedTs: t + 80_000).sleep,
                       [TimeSpan(t, t + 3600)])
    }

    func testProvisionalAndUncheckedDayEndAreReported() {
        let s = session([StageSegment(start: t, end: t + 3600, stage: "light")], provisional: true)
        XCTAssertTrue(AwakeWindow.classify([s], span: day, laterDataChecked: true, lastObservedTs: t + 3600)
            .reasons.contains(LoadReason.sleepProvisional))
        let quiet = session([StageSegment(start: t, end: t + 3600, stage: "light")])
        XCTAssertEqual(AwakeWindow.classify([quiet], span: day, laterDataChecked: false, lastObservedTs: day.end).reasons,
                       [LoadReason.dayEndUnclassified])
        XCTAssertEqual(AwakeWindow.classify([quiet], span: day, laterDataChecked: true, lastObservedTs: day.end).reasons, [])
        XCTAssertEqual(AwakeWindow.classify([], span: day, laterDataChecked: false, lastObservedTs: nil).reasons, [],
                       "no HR at all is already 'no_heart_rate'")
    }

    func testOverlappingSessionsDoNotCallKnownSleepUncertain() {
        let a = session([StageSegment(start: t, end: t + 3600, stage: "unknown")])
        let b = session([StageSegment(start: t, end: t + 1800, stage: "deep")])
        let w = AwakeWindow.classify([a, b], span: day, laterDataChecked: true, lastObservedTs: t + 80_000)
        XCTAssertEqual(w.sleep, [TimeSpan(t, t + 1800)])
        XCTAssertEqual(w.uncertain, [TimeSpan(t + 1800, t + 3600)])
    }

    func testASessionDuringSleepCannotReportMoreThanTheAwakeDay() {
        let hr = run(t, 3600, 150)
        let w = WorkoutDetector.detect(cleaned: HRQuality.clean(hr), support: SupportedHR(raw: hr), gravity: [],
                                       calibration: cal, sleep: [TimeSpan(t + 1000, t + 2000)])
        XCTAssertEqual(w.first?.load.summary.observedS, 2600)
        XCTAssertEqual(w.first?.load.summary.requestedS, 2600)
    }

    func testCaloriesKeepSleepAndUseTheSameSupportedSeconds() {
        let profile = UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "male")
        let awake = run(t + 28_800, 57_600, 80), asleep = run(t, 28_800, 50)
        let awakeOnly = Calories.estimateDayCalories(awake, profile: profile, hrmax: 190, restingHR: 50)
        let fullDay = Calories.estimateDayCalories(asleep + awake, profile: profile, hrmax: 190, restingHR: 50)
        XCTAssertEqual(fullDay, awakeOnly * 86_400 / 57_600, accuracy: 0.5, "resting energy stays in the total")
        // A 2-hour hole adds its bounded hold, not 60 s, so energy and "recorded" count the same seconds.
        let gappy = run(t, 3600, 80) + run(t + 10_800, 3600, 80)
        let rate = Calories.estimateDayCalories(run(t, 7200, 80), profile: profile, hrmax: 190, restingHR: 50) / 7200
        let observed = Double(SupportedHR(raw: gappy).observedSeconds)
        XCTAssertEqual(Calories.estimateDayCalories(gappy, profile: profile, hrmax: 190, restingHR: 50), rate * observed, accuracy: 1e-6)
    }
}
