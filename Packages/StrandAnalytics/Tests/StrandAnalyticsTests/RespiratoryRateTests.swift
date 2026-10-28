import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class RespiratoryRateTests: XCTestCase {

    /// Deterministic noise so the tests never flake.
    private struct LCG { var s: UInt64 = 12345
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 33) / Double(1 << 31) - 0.5 } }

    /// R-R series (ms) with a respiratory modulation of `breathsPerMin` and amplitude `amp` ms on a `base` ms mean.
    private func series(seconds: Double, breathsPerMin: Double, amp: Double, base: Double = 950, noise: Double = 8) -> [Double] {
        var rng = LCG(), out: [Double] = [], t = 0.0
        let f = breathsPerMin / 60
        while t < seconds {
            let rr = base + amp * sin(2 * .pi * f * t) + noise * rng.next()
            out.append(rr.rounded()); t += rr / 1000
        }
        return out
    }

    func testRecoversKnownBreathingRates() {
        for bpm in [10.0, 12.0, 15.0, 18.0, 22.0] {
            let r = RespiratoryRate.estimate(rrMs: series(seconds: 300, breathsPerMin: bpm, amp: 35))
            XCTAssertNotNil(r.breathsPerMin, "\(bpm): \(r.rejection ?? "")")
            XCTAssertEqual(r.breathsPerMin ?? 0, bpm, accuracy: 0.7, "true \(bpm)")
        }
    }

    func testNoiseOnlyGivesNoEstimate() {
        var rng = LCG(); rng.s = 99
        let rr = (0..<330).map { _ in (950 + 60 * rng.next()).rounded() }
        XCTAssertNil(RespiratoryRate.estimate(rrMs: rr).breathsPerMin)
    }

    func testSlowDriftDoesNotMasqueradeAsBreathing() {
        // 3 cycles/min (0.05 Hz) is below the band; with no breathing component there must be no estimate.
        let r = RespiratoryRate.estimate(rrMs: series(seconds: 300, breathsPerMin: 3, amp: 60, noise: 4))
        XCTAssertNil(r.breathsPerMin)
    }

    func testTooShortOrArtifactRidden() {
        XCTAssertNil(RespiratoryRate.estimate(rrMs: series(seconds: 40, breathsPerMin: 15, amp: 35)).breathsPerMin)
        var rr = series(seconds: 300, breathsPerMin: 15, amp: 35)
        for i in stride(from: 0, to: rr.count, by: 3) { rr[i] = 150 }   // a third of the beats implausible
        XCTAssertEqual(RespiratoryRate.estimate(rrMs: rr).rejection, "artifacts")
    }

    func testSurvivesAFewEctopicBeats() {
        var rr = series(seconds: 300, breathsPerMin: 14, amp: 35)
        for i in stride(from: 20, to: rr.count, by: 40) { rr[i] *= 1.6 }
        XCTAssertEqual(RespiratoryRate.estimate(rrMs: rr).breathsPerMin ?? 0, 14, accuracy: 0.8)
    }

    func testSleepVitalsReportsNightlyRespiration() {
        let start = 1_000_000, secs = 3 * 3600
        let rr = series(seconds: Double(secs), breathsPerMin: 14, amp: 35)
        var t = Double(start), rrs: [RRInterval] = []
        for v in rr { rrs.append(RRInterval(ts: Int(t), rrMs: Int(v))); t += v / 1000 }
        let hr = (0..<secs).map { HRSample(ts: start + $0, bpm: 60) }
        let v = SleepVitalsCalculator.compute(start: start, end: start + secs, stages: [], hr: hr, rr: rrs)
        XCTAssertNotNil(v.respRate)
        XCTAssertEqual(v.respRate ?? 0, 14, accuracy: 0.8)
    }
}
