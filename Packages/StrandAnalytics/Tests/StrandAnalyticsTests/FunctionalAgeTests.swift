import XCTest
@testable import StrandAnalytics

/// #49 model core: arithmetic only (synthetic), plus the manifest/gate contract. Not clinical validation.
final class FunctionalAgeTests: XCTestCase {
    private let day = 86_400.0

    func testAgeImpactFromHazardRatio() throws {
        XCTAssertEqual(try XCTUnwrap(FunctionalAge.ageImpactYears(hazardRatio: 1)), 0, accuracy: 1e-12, "neutral")
        XCTAssertEqual(try XCTUnwrap(FunctionalAge.ageImpactYears(hazardRatio: exp(0.1))), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(FunctionalAge.ageImpactYears(hazardRatio: 1.09)), 0.8618, accuracy: 1e-4, "adverse: +10 bpm RHR")
        XCTAssertEqual(try XCTUnwrap(FunctionalAge.ageImpactYears(hazardRatio: 0.87)), -1.3926, accuracy: 1e-4, "beneficial: +1 MET")
        for bad in [0, -1, .nan, .infinity] { XCTAssertNil(FunctionalAge.ageImpactYears(hazardRatio: bad)) }
    }

    /// Research-comment cases for H = 0.5 years, here with real dates (half a mean Gregorian year).
    func testPaceCasesAndChronologicalAgingCountedOnce() throws {
        let from = Date(timeIntervalSince1970: 1_795_000_000)
        let to = from.addingTimeInterval(0.5 * FunctionalAge.secondsPerYear)
        func pace(_ cur: Double, _ proj: Double) throws -> Double {
            try XCTUnwrap(FunctionalAge.pace(currentImpact: cur, projectedImpact: proj, from: from, to: to))
        }
        XCTAssertEqual(try pace(2, 2), 1.0, accuracy: 1e-12, "stable inputs age at exactly 1×")
        XCTAssertEqual(try pace(2, 1.75), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try pace(2, 2.25), 1.5, accuracy: 1e-12)
        XCTAssertEqual(try pace(2, 1.5), 0.0, accuracy: 1e-12)
        XCTAssertEqual(try pace(2, 0.5), -2.0, accuracy: 1e-12, "raw value kept; clamping is a display decision")
        XCTAssertNil(FunctionalAge.pace(currentImpact: 0, projectedImpact: 0, from: to, to: from))
        XCTAssertNil(FunctionalAge.pace(currentImpact: 0, projectedImpact: 0, from: from, to: from))
        XCTAssertNil(FunctionalAge.pace(currentImpact: .nan, projectedImpact: 0, from: from, to: to))
    }

    /// The horizon comes from dates, so a calendar 6 months that spans DST or a leap day changes H, not the formula.
    func testHorizonUsesTrueLengthAcrossDSTAndLeapDays() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let from = try XCTUnwrap(cal.date(from: DateComponents(year: 2027, month: 11, day: 18)))
        let to = try XCTUnwrap(cal.date(byAdding: .month, value: 6, to: from))   // spans Feb 29 2028 and the March DST change
        let h = to.timeIntervalSince(from) / FunctionalAge.secondsPerYear
        XCTAssertEqual(h, (182 * day - 3_600) / FunctionalAge.secondsPerYear, accuracy: 1e-12)
        let p = try XCTUnwrap(FunctionalAge.pace(currentImpact: 1, projectedImpact: 1 + h / 2, from: from, to: to))
        XCTAssertEqual(p, 1.5, accuracy: 1e-12)
    }

    func testChronologicalAgeIsContinuousAcrossBirthdays() throws {
        let birth = Date(timeIntervalSince1970: 0)
        let before = birth.addingTimeInterval(40 * FunctionalAge.secondsPerYear - day)
        let after = birth.addingTimeInterval(40 * FunctionalAge.secondsPerYear + day)
        let a = try XCTUnwrap(FunctionalAge.chronologicalAge(birth: birth, asOf: before))
        let b = try XCTUnwrap(FunctionalAge.chronologicalAge(birth: birth, asOf: after))
        XCTAssertEqual(b - a, 2 * day / FunctionalAge.secondsPerYear, accuracy: 1e-12, "no step at the birthday")
        XCTAssertNil(FunctionalAge.chronologicalAge(birth: after, asOf: before))
    }

    func testManifestEntriesAreCitedAndUnverifiedOnesCarryNoValue() {
        XCTAssertFalse(FunctionalAge.manifest.isEmpty)
        for p in FunctionalAge.manifest {
            switch p.status {
            case .verifiedMarginal:
                XCTAssertNotNil(p.hazardRatio, p.contrast)
                XCTAssertTrue(p.doi.hasPrefix("10."), p.contrast)
                XCTAssertFalse(p.citation.isEmpty)
                if let hr = p.hazardRatio, let ci = p.ci95 { XCTAssertTrue(ci.contains(hr), p.contrast) }
            case .needsVerification:
                XCTAssertNil(p.hazardRatio, "an unverified source never supplies a number: \(p.contributor)")
            }
        }
        let covered = Set(FunctionalAge.manifest.map(\.contributor))
        XCTAssertEqual(covered, Set(FunctionalAge.Contributor.allCases), "every contributor has a manifest entry")
    }

    func testGateNeverReturnsANumberAndListsReasons() {
        XCTAssertFalse(FunctionalAge.numericRelease)
        let inputs = [
            FunctionalAge.Input(contributor: .restingHR, value: 52, source: .noop, coveredDays: 30, requiredDays: 30),
            FunctionalAge.Input(contributor: .vo2max, value: 48, source: .derivedEstimate("HR-ratio VO₂max estimate"),
                                coveredDays: 30, requiredDays: 30),
            FunctionalAge.Input(contributor: .steps, value: nil, source: .noop, coveredDays: 3, requiredDays: 30),
        ]
        guard case .unsupported(let reason, let reasons) = FunctionalAge.evaluate(inputs: inputs, chronologicalAge: nil) else {
            return XCTFail("gated model must not be ready or calibrating")
        }
        XCTAssertTrue(reason.contains("not switched on"))
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Chronological age") })
        XCTAssertTrue(reasons.contains { $0.contains("would count them twice") }, "HR-ratio VO₂ refused")
        XCTAssertTrue(reasons.contains { $0.contains("3 of 30 days") }, "sparse steps are coverage, never zero")
        XCTAssertTrue(FunctionalAge.inputProblems(inputs[0]).isEmpty)
        // Even complete inputs stay gated on the Health page.
        guard case .unsupported = FunctionalAge.evaluate(inputs: complete(), chronologicalAge: 40) else {
            return XCTFail("gated")
        }
    }

    // MARK: v1 one-per-group estimate

    private func input(_ c: FunctionalAge.Contributor, _ v: Double?, _ src: FunctionalAge.InputSource = .noop,
                       days: Int = 30) -> FunctionalAge.Input {
        FunctionalAge.Input(contributor: c, value: v, source: src, coveredDays: days, requiredDays: 30)
    }
    private func complete() -> [FunctionalAge.Input] {
        [input(.restingHR, 60), input(.steps, 3_553), input(.sleepDuration, 7.5)]
    }

    func testCurvesAtReferentsAndCitedPoints() throws {
        func hr(_ c: FunctionalAge.Contributor, _ v: Double) throws -> Double {
            try XCTUnwrap(FunctionalAge.hazardRatio(for: c, value: v)).hr
        }
        XCTAssertEqual(try hr(.restingHR, 60), 1, accuracy: 1e-12)
        XCTAssertEqual(try hr(.restingHR, 70), 1.09, accuracy: 1e-12)
        XCTAssertEqual(try hr(.vo2max, 7.9 * 3.5), 1, accuracy: 1e-12)
        XCTAssertEqual(try hr(.vo2max, 8.9 * 3.5), 0.87, accuracy: 1e-12)
        for (steps, want) in [(3_553.0, 1.0), (5_801, 0.60), (7_842, 0.55), (10_901, 0.47)] {
            XCTAssertEqual(try hr(.steps, steps), want, accuracy: 1e-12, "Paluch quartile median \(steps)")
        }
        let mid = try hr(.steps, (5_801 + 7_842) / 2)
        XCTAssertEqual(mid, sqrt(0.60 * 0.55), accuracy: 1e-12, "log-interpolated halfway")
        XCTAssertEqual(try hr(.sleepDuration, 5.5), 1.12)
        XCTAssertEqual(try hr(.sleepDuration, 7.5), 1.0)
        XCTAssertEqual(try hr(.sleepDuration, 9.5), 1.30)
        XCTAssertNil(FunctionalAge.hazardRatio(for: .strength, value: 45), "not used in v1")
        XCTAssertNil(FunctionalAge.hazardRatio(for: .sleepDuration, value: 0))
    }

    func testClippingIsFlaggedNotExtrapolated() throws {
        let hi = try XCTUnwrap(FunctionalAge.hazardRatio(for: .restingHR, value: 130))
        XCTAssertTrue(hi.clipped)
        XCTAssertEqual(hi.hr, pow(1.09, 4), accuracy: 1e-12, "held at 100 bpm")
        let lots = try XCTUnwrap(FunctionalAge.hazardRatio(for: .steps, value: 25_000))
        XCTAssertEqual(lots.hr, 0.47)
        XCTAssertTrue(lots.clipped, "no benefit claimed past the top quartile median")
        XCTAssertFalse(try XCTUnwrap(FunctionalAge.hazardRatio(for: .steps, value: 6_000)).clipped)
    }

    func testNeutralEstimateEqualsChronologicalAge() throws {
        let (est, reasons) = FunctionalAge.estimate(inputs: complete(), chronologicalAge: 40.25)
        XCTAssertTrue(reasons.isEmpty)
        let e = try XCTUnwrap(est)
        XCTAssertEqual(e.functionalAge, 40.25, accuracy: 1e-12)
        XCTAssertEqual(e.impacts.map(\.group), FunctionalAge.Group.allCases)
        XCTAssertEqual(e.modelVersion, "noop-functional-age-v1-groups")
    }

    func testAdverseAndBeneficialInputsSumOncePerGroup() throws {
        let inputs = [input(.restingHR, 70), input(.steps, 10_901), input(.sleepDuration, 5)]
        let e = try XCTUnwrap(FunctionalAge.estimate(inputs: inputs, chronologicalAge: 50).0)
        let want = (log(1.09) + log(0.47) + log(1.12)) / 0.1
        XCTAssertEqual(e.totalImpact, want, accuracy: 1e-9)
        XCTAssertEqual(e.functionalAge, 50 + want, accuracy: 1e-9)
    }

    func testMeasuredVO2RepresentsActivityAndStepsAreNotAddedToo() throws {
        let inputs = complete() + [input(.vo2max, 10 * 3.5, .manual(method: "treadmill CPET"))]
        let e = try XCTUnwrap(FunctionalAge.estimate(inputs: inputs, chronologicalAge: 40).0)
        let act = try XCTUnwrap(e.impacts.first { $0.group == .activityFitness })
        XCTAssertEqual(act.contributor, .vo2max)
        XCTAssertEqual(e.impacts.filter { $0.group == .activityFitness }.count, 1)
        XCTAssertEqual(act.years, log(pow(0.87, 2.1)) / 0.1, accuracy: 1e-9)
    }

    func testDerivedVO2FallsBackToStepsAndMissingGroupGivesNoNumber() throws {
        let derived = complete() + [input(.vo2max, 60, .derivedEstimate("HR-ratio"))]
        let e = try XCTUnwrap(FunctionalAge.estimate(inputs: derived, chronologicalAge: 40).0)
        XCTAssertEqual(e.impacts.first { $0.group == .activityFitness }?.contributor, .steps)
        let noSleep = [input(.restingHR, 60), input(.steps, 8_000)]
        let (none, reasons) = FunctionalAge.estimate(inputs: noSleep, chronologicalAge: 40)
        XCTAssertNil(none, "no reduced model: a missing group is never treated as neutral")
        XCTAssertEqual(reasons, ["Sleep duration: no usable input yet"])
        let sparse = [input(.restingHR, 60), input(.steps, 8_000, days: 10), input(.sleepDuration, 7)]
        XCTAssertNil(FunctionalAge.estimate(inputs: sparse, chronologicalAge: 40).0, "sparse steps are not used")
        XCTAssertNil(FunctionalAge.estimate(inputs: complete(), chronologicalAge: nil).0)
    }

    func testStableInputsGivePaceOfOne() throws {
        let from = Date(timeIntervalSince1970: 1_795_000_000)
        let to = from.addingTimeInterval(0.5 * FunctionalAge.secondsPerYear)
        let now = try XCTUnwrap(FunctionalAge.estimate(inputs: complete(), chronologicalAge: 40).0)
        let later = try XCTUnwrap(FunctionalAge.estimate(inputs: complete(), chronologicalAge: 40.5).0)
        let p = try XCTUnwrap(FunctionalAge.pace(currentImpact: now.totalImpact, projectedImpact: later.totalImpact,
                                                 from: from, to: to))
        XCTAssertEqual(p, 1.0, accuracy: 1e-12)
    }
}
