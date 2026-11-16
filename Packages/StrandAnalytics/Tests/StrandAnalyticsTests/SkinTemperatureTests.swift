import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Nightly skin temperature and its change from a strictly causal personal reference (issue #25).
final class SkinTemperatureTests: XCTestCase {
    private let unit = Whoop5HistoricalRecord.skinTempUnit

    private func samples(_ from: Int, _ to: Int, centi: Int, unit u: String? = nil) -> [SkinTempSample] {
        (from..<to).map { SkinTempSample(ts: $0, raw: centi, unit: u ?? unit) }
    }

    // MARK: night value

    func testNightIsTheMedianOverAsleepStagesOnly() throws {
        let stages = [StageSegment(start: 0, end: 600, stage: "wake"),
                      StageSegment(start: 600, end: 4200, stage: "light"),
                      StageSegment(start: 4200, end: 4800, stage: "unknown"),
                      StageSegment(start: 4800, end: 6600, stage: "deep")]
        // Wake and unknown time read 30 °C; asleep time 35.00 then 35.20 °C.
        let s = samples(0, 600, centi: 3000) + samples(600, 4200, centi: 3500) + samples(4200, 4800, centi: 3000)
            + samples(4800, 6600, centi: 3520)
        let n = SkinTemperature.night(samples: s.shuffled(), stages: stages)
        XCTAssertEqual(n.asleepS, 5400)
        XCTAssertEqual(n.samples, 5400)
        XCTAssertEqual(n.coverage, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(n.valueC), 35.0, accuracy: 1e-9)      // median of 3600 × 35.00 and 1800 × 35.20
        XCTAssertEqual(n.exclusionReasons, [])
    }

    func testFourPointZeroCountsAndDuplicatesAreNeverUsed() {
        let stages = [StageSegment(start: 0, end: 3600, stage: "rem")]
        let adc = samples(0, 3600, centi: 900, unit: "raw_adc")
        XCTAssertNil(SkinTemperature.night(samples: adc, stages: stages).valueC, "4.0 ADC counts have no verified °C")
        let dup = samples(0, 3600, centi: 3400) + samples(0, 3600, centi: 3400)
        XCTAssertEqual(SkinTemperature.night(samples: dup, stages: stages).samples, 3600)
    }

    func testTooFewSamplesOrLowCoverageIsUnavailableNotZero() {
        let long = [StageSegment(start: 0, end: 8 * 3600, stage: "light")]
        let sparse = SkinTemperature.night(samples: samples(0, 1000, centi: 3450), stages: long)
        XCTAssertNil(sparse.valueC)
        XCTAssertTrue(sparse.exclusionReasons.contains("too few samples"))
        XCTAssertTrue(sparse.exclusionReasons.contains("low coverage"))
        let lowCoverage = SkinTemperature.night(samples: samples(0, 3 * 3600, centi: 3450), stages: long)
        XCTAssertNil(lowCoverage.valueC)
        XCTAssertEqual(lowCoverage.exclusionReasons, ["low coverage"])
        XCTAssertEqual(SkinTemperature.night(samples: [], stages: long).exclusionReasons, ["no skin-temperature samples"])
        XCTAssertEqual(SkinTemperature.night(samples: samples(0, 100, centi: 3450),
                                             stages: [StageSegment(start: 0, end: 100, stage: "wake")]).exclusionReasons,
                       ["no asleep time"])
    }

    // MARK: change

    func testChangeNeedsAProvisionalOrEstablishedReference() {
        func ref(_ state: ReferenceState, center: Double = 34.5) -> ReferenceSnapshot {
            ReferenceSnapshot(center: center, scale: 0.2, rawMAD: 0.1, count: 6, daysSinceLast: 1, state: state)
        }
        XCTAssertEqual(try XCTUnwrap(SkinTemperature.change(night: 34.9, reference: ref(.provisional))), 0.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SkinTemperature.change(night: 34.1, reference: ref(.established))), -0.4, accuracy: 1e-9)
        XCTAssertNil(SkinTemperature.change(night: 34.9, reference: ref(.calibrating)))
        XCTAssertNil(SkinTemperature.change(night: 34.9, reference: ref(.stale)))
        XCTAssertNil(SkinTemperature.change(night: 34.9, reference: nil))
        XCTAssertNil(SkinTemperature.change(night: nil, reference: ref(.established)))
        XCTAssertNil(SkinTemperature.change(night: 22.0, reference: ref(.established)), "off-wrist-like night is implausible")
    }

    // MARK: causal reference

    private func prov(_ day: String, identity: MetricIdentity = SkinTemperature.nightIdentity(), reasons: [String] = []) -> [ProvenanceRecord] {
        [identity.record(day: day, key: ProvenanceKey.skinTempNight, exclusionReasons: reasons, scoringVersion: 5)]
    }

    func testReferenceUsesOnlyEarlierNightsOfTheCurrentIdentity() throws {
        var nights: [String: Double] = [:]
        var provenance: [String: [ProvenanceRecord]] = [:]
        for d in 1...6 {
            let day = String(format: "2026-11-%02d", d)
            nights[day] = 34.0; provenance[day] = prov(day)
        }
        // An older-version night, an excluded night and a same-day value never count.
        nights["2026-10-31"] = 30.0
        provenance["2026-10-31"] = prov("2026-10-31", identity: MetricIdentity(definition: .skinTemperature, unit: "°C",
                                                                               source: .noopComputed, algorithmVersion: "skin-temp-night-v0",
                                                                               context: .sleep, aggregation: .medianOverAsleep))
        nights["2026-10-30"] = 30.0; provenance["2026-10-30"] = prov("2026-10-30", reasons: ["low coverage"])
        nights["2026-11-07"] = 40.0; provenance["2026-11-07"] = prov("2026-11-07")
        let r = try XCTUnwrap(CausalBaselines.skinTempReference(nights: nights, provenance: provenance, before: "2026-11-07"))
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(r.center, 34.0, accuracy: 1e-9)
        XCTAssertEqual(r.state, .provisional)
        XCTAssertEqual(r.scale, 0.1, accuracy: 1e-9, "noise floor")
        // A night without provenance (unknown identity) never joins.
        XCTAssertEqual(CausalBaselines.skinTempReference(nights: ["2026-11-01": 34], provenance: [:], before: "2026-11-02")?.count, nil)
    }

    // MARK: replay through CausalReplay

    private struct FakeResult { let daily: DailyMetric; let night: SkinTemperature.Night }

    /// Night values per day; the analyzed change is computed against the baselines CausalReplay hands in.
    private func replay(days: [String], values: [String: Double], seed: [DailyMetric] = [], seedProv: [ProvenanceRecord] = [],
                        seedSkin: [String: Double] = [:]) async -> CausalReplay.Output<FakeResult> {
        await CausalReplay.run(
            days: days, seed: seed, seedProvenance: seedProv, scoringVersion: 5,
            analyze: { day, baselines in
                let v = values[day]
                let n = SkinTemperature.Night(valueC: v, samples: v == nil ? 0 : 20_000, asleepS: 25_000,
                                              coverage: v == nil ? 0 : 0.8, exclusionReasons: v == nil ? ["no skin-temperature samples"] : [])
                let change = SkinTemperature.change(night: v, reference: baselines.skinTempReference)
                return FakeResult(daily: DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil, skinTempDevC: change), night: n)
            },
            daily: { $0.daily }, assessment: { _ in nil }, seedSkinNights: seedSkin, skinNight: { $0.night })
    }

    func testChangeAppearsAfterFiveNightsAndAppliesToLaterNightsOnly() async throws {
        let days = (1...8).map { String(format: "2026-11-%02d", $0) }
        var values: [String: Double] = [:]
        for d in days.prefix(5) { values[d] = 34.2 }
        values["2026-11-06"] = 34.8
        values["2026-11-08"] = 33.9                      // 11-07 has no value: missing, not zero
        let out = await replay(days: days, values: values)
        let change = Dictionary(uniqueKeysWithValues: out.results.map { ($0.day, $0.result.daily.skinTempDevC) })
        for d in days.prefix(5) { XCTAssertNil(change[d] ?? nil, "\(d): reference still calibrating") }
        XCTAssertEqual(try XCTUnwrap(change["2026-11-06"] ?? nil), 0.6, accuracy: 1e-9)
        XCTAssertNil(change["2026-11-07"] ?? nil)
        // Median of 34.2 ×5 and 34.8 → 34.2.
        XCTAssertEqual(try XCTUnwrap(change["2026-11-08"] ?? nil), -0.3, accuracy: 1e-9)
        let skinProv = out.provenance.filter { $0.key == ProvenanceKey.skinTempNight }
        XCTAssertEqual(skinProv.count, 8)
        XCTAssertEqual(skinProv.first { $0.day == "2026-11-07" }?.exclusionReasons.contains("no skin-temperature samples"), true)
    }

    func testSuffixReplaySeededFromStoredNightsMatchesFullReplay() async throws {
        let days = (1...10).map { String(format: "2026-11-%02d", $0) }
        var values: [String: Double] = [:]
        for (i, d) in days.enumerated() { values[d] = 34.0 + Double(i % 3) * 0.1 }
        let full = await replay(days: days, values: values)
        // Persist what the first 6 days stored (rows, provenance, night values), then replay only the rest.
        let head = full.results.filter { $0.day <= "2026-11-06" }
        let seed = head.map(\.result.daily)
        let seedProv = full.provenance.filter { $0.day <= "2026-11-06" }
        let seedSkin = Dictionary(uniqueKeysWithValues: head.compactMap { r in r.result.night.valueC.map { (r.day, $0) } })
        let tail = await replay(days: Array(days.suffix(4)), values: values, seed: seed, seedProv: seedProv, seedSkin: seedSkin)
        let a = full.results.filter { $0.day > "2026-11-06" }.map { $0.result.daily.skinTempDevC }
        let b = tail.results.map { $0.result.daily.skinTempDevC }
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0 != nil })
        // Without the stored nights the suffix would have no reference.
        let unseeded = await replay(days: Array(days.suffix(4)), values: values, seed: seed, seedProv: seedProv)
        XCTAssertTrue(unseeded.results.prefix(1).allSatisfy { $0.result.daily.skinTempDevC == nil })
    }

    // MARK: analyzeDay

    func testAnalyzeDayReportsTheNightAndItsChange() throws {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC"); fmt.dateFormat = "yyyy-MM-dd"
        let day = "2021-06-15"
        let end = Int(fmt.date(from: day)!.timeIntervalSince1970) + 6 * 3600, start = end - 7 * 3600
        let hr = (start..<end).map { HRSample(ts: $0, bpm: 50) }
        let grav = (start..<end).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        var rr: [RRInterval] = []
        var toggle = false
        for t in stride(from: start, to: end, by: 2) { rr.append(RRInterval(ts: t, rrMs: toggle ? 1205 : 1195)); toggle.toggle() }
        let skin = samples(start, end, centi: 3480)
        let reference = ReferenceSnapshot(center: 34.5, scale: 0.2, rawMAD: 0.1, count: 10, daysSinceLast: 1, state: .provisional)
        let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: grav, skinTemp: skin, profile: UserProfile(age: 30),
                                             baselines: AnalyticsEngine.ProfileBaselines(skinTempReference: reference))
        XCTAssertEqual(res.sleepSessions.count, 1)
        XCTAssertEqual(try XCTUnwrap(res.skinTempNight?.valueC), 34.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(res.daily.skinTempDevC), 0.3, accuracy: 1e-9)
        // No reference yet: the night is still measured, the change is missing.
        let cold = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: grav, skinTemp: skin, profile: UserProfile(age: 30))
        XCTAssertNotNil(cold.skinTempNight?.valueC)
        XCTAssertNil(cold.daily.skinTempDevC)
        // No samples: unavailable, never 0.
        let none = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: grav, profile: UserProfile(age: 30),
                                              baselines: AnalyticsEngine.ProfileBaselines(skinTempReference: reference))
        XCTAssertNil(none.daily.skinTempDevC)
    }

    func testVersionIsPartOfTheAlgorithmKey() {
        XCTAssertTrue(IncrementalScorer.algorithmKey(scoringVersion: 5, generation: 0).contains(SkinTemperature.version))
    }
}
