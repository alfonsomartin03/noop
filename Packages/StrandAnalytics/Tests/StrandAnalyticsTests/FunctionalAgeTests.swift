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
        XCTAssertTrue(reason.contains("joint model"))
        XCTAssertTrue(reasons.contains { $0.hasPrefix("Chronological age") })
        XCTAssertTrue(reasons.contains { $0.contains("would count them twice") }, "HR-ratio VO₂ refused")
        XCTAssertTrue(reasons.contains { $0.contains("3 of 30 days") }, "sparse steps are coverage, never zero")
        XCTAssertTrue(reasons.contains { $0.contains("Strength training: published effect size not yet verified") })
        XCTAssertTrue(FunctionalAge.inputProblems(inputs[0]).isEmpty)
    }
}
