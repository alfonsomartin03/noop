import XCTest
@testable import StrandAnalytics

/// Smart-wake decisions on synthetic, timestamped HR traces with an injected clock. These traces compare policies; they
/// say nothing about real wake effectiveness (that needs overnight observations).
final class SmartWakeTests: XCTestCase {
    let base = WakeBaseline(bpm: 55, source: "noop-resting-hr test", asOf: Date(timeIntervalSince1970: 1_793_600_000))
    /// Deadline 07:00 local-agnostic: windowStart = deadline − 30 min.
    let deadline = Date(timeIntervalSince1970: 1_793_700_000)
    var occ: AlarmOccurrence { AlarmOccurrence(alarmId: "a", deadline: deadline, windowStart: deadline.addingTimeInterval(-1800)) }
    func t(_ minutesBeforeDeadline: Double) -> Date { deadline.addingTimeInterval(-minutesBeforeDeadline * 60) }

    /// Runs one policy over a trace: per-second samples from `bpm(t)` (nil = no sample), ticks at `ticks`.
    /// Returns the decision and the tick time it happened at.
    func run(_ policy: SmartWakePolicy, mode: AlarmSpec.Mode = .smart(windowMin: 30), baseline: WakeBaseline?,
             ticks: [Date], arrivalLag: TimeInterval = 1, goal: ((Date) -> SleepGoalProgress?)? = nil,
             bpm: (Date) -> Int?) -> (SmartWakeDecider.Decision, Date)? {
        var buf = WakeEvidenceBuffer()
        var dec = SmartWakeDecider(occurrence: occ, mode: mode, policy: policy)
        var s = t(40)
        for tick in ticks {
            while s.addingTimeInterval(arrivalLag) <= tick {
                if let b = bpm(s) { buf.ingest(HRObservation(at: s, bpm: b, receivedAt: s.addingTimeInterval(arrivalLag)), now: s.addingTimeInterval(arrivalLag)) }
                s = s.addingTimeInterval(1)
            }
            let w = buf.windows(from: occ.windowStart.addingTimeInterval(-60), endingBy: tick, length: policy.windowSeconds,
                                minSamples: policy.minSamplesPerWindow)
            let d = dec.step(now: tick, windows: w, baseline: baseline, sleepGoal: goal?(tick))
            if d != .wait { return (d, tick) }
        }
        return nil
    }

    /// The pre-2026-11-05 behaviour: instantaneous HR at each 30-s tick, threshold 0.6, three consecutive calls.
    func runLegacy(ticks: [Date], bpm: (Date) -> Int?) -> Date? {
        var runCount = 0
        for tick in ticks where tick >= occ.windowStart {
            if tick >= deadline { return nil }
            if let b = bpm(tick), (Double(b) / base.bpm - 1) / 0.25 >= 0.6 { runCount += 1 } else { runCount = 0 }
            if runCount >= 3 { return tick }
        }
        return nil
    }

    var everyThirty: [Date] { stride(from: -40.0 * 60, through: 60, by: 30).map { deadline.addingTimeInterval($0) } }
    func noise(_ d: Date) -> Int { Int(d.timeIntervalSince1970) % 5 - 2 }

    func isEarly(_ r: (SmartWakeDecider.Decision, Date)?) -> Date? {
        if case .fireEarly? = r?.0 { return r?.1 }
        return nil
    }

    // MARK: policy comparison (synthetic traces)

    func testPolicyComparisonOnSyntheticTraces() {
        struct Trace { let name: String; let bpm: (Date) -> Int?; let v2Early: Bool; let legacyEarly: Bool }
        let rise = t(20)
        let traces: [Trace] = [
            Trace(name: "flat sleep", bpm: { 55 + self.noise($0) }, v2Early: false, legacyEarly: false),
            Trace(name: "10 s spike", bpm: { d in d >= self.t(15) && d < self.t(15).addingTimeInterval(10) ? 95 : 55 + self.noise(d) },
                  v2Early: false, legacyEarly: false),
            Trace(name: "sustained +11 %", bpm: { d in d >= rise ? 61 + self.noise(d) / 2 : 55 + self.noise(d) }, v2Early: true, legacyEarly: false),
            Trace(name: "sustained +20 %", bpm: { d in d >= rise ? 66 + self.noise(d) : 55 + self.noise(d) }, v2Early: true, legacyEarly: true),
            Trace(name: "alternating 20 s", bpm: { d in Int(d.timeIntervalSince1970 / 20) % 2 == 0 ? 70 : 54 }, v2Early: false, legacyEarly: false),
            Trace(name: "no data", bpm: { _ in nil }, v2Early: false, legacyEarly: false),
        ]
        var table = ["trace | legacy v1 | v2"]
        for tr in traces {
            let v2 = isEarly(run(.hrOnlyV2, baseline: base, ticks: everyThirty, bpm: tr.bpm))
            let legacy = runLegacy(ticks: everyThirty, bpm: tr.bpm)
            func fmt(_ d: Date?) -> String { d.map { String(format: "early −%.1f min", deadline.timeIntervalSince($0) / 60) } ?? "deadline" }
            table.append("\(tr.name) | \(fmt(legacy)) | \(fmt(v2))")
            XCTAssertEqual(v2 != nil, tr.v2Early, "v2 on \(tr.name)")
            XCTAssertEqual(legacy != nil, tr.legacyEarly, "legacy on \(tr.name)")
        }
        print("Smart-wake synthetic comparison\n" + table.joined(separator: "\n"))
    }

    func testSustainedRiseFiresAfterAboutSixtySecondsOfEvidence() throws {
        let rise = t(20)
        let ticks = stride(from: -40.0 * 60, through: 60, by: 5).map { deadline.addingTimeInterval($0) }
        let r = try XCTUnwrap(run(.hrOnlyV2, baseline: base, ticks: ticks) { $0 >= rise ? 64 : 55 })
        guard case .fireEarly(let rec) = r.0 else { return XCTFail("expected early") }
        let delay = r.1.timeIntervalSince(rise)
        XCTAssertGreaterThanOrEqual(delay, 60)
        XCTAssertLessThanOrEqual(delay, 60 + 20 + 5 + 1)   // one window alignment + one tick
        XCTAssertEqual(rec.policyVersion, "smart-wake-v2-hr")
        XCTAssertEqual(rec.trigger, .hrRun)
        XCTAssertEqual(rec.baselineSource, "noop-resting-hr test")
        XCTAssertNotNil(rec.baselineAgeHours)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rec.sustainedSeconds), 60)
        XCTAssertFalse(rec.reason.lowercased().contains("light sleep"))
    }

    func testIrregularTicksStillFireOnDurationNotCallCount() {
        let rise = t(20)
        var ticks: [Date] = []; var x = t(40); var k = 0
        let gaps: [TimeInterval] = [7, 83, 12, 45, 3, 61, 29, 90, 4]
        while x < deadline.addingTimeInterval(30) { ticks.append(x); x = x.addingTimeInterval(gaps[k % gaps.count]); k += 1 }
        let r = run(.hrOnlyV2, baseline: base, ticks: ticks) { $0 >= rise ? 64 : 55 }
        let at = isEarly(r)
        XCTAssertNotNil(at)
        XCTAssertGreaterThanOrEqual(at!.timeIntervalSince(rise), 60)
    }

    /// A short burst followed by silence: repeated ticks see the same samples, but each window counts once and the gap
    /// breaks the run, so it never adds up to 60 s.
    func testRepeatedTicksCannotRecountTheSameSamples() {
        let burst = t(20)
        let ticks = stride(from: -40.0 * 60, through: 60, by: 1).map { deadline.addingTimeInterval($0) }
        let r = run(.hrOnlyV2, baseline: base, ticks: ticks) { d in d >= burst && d < burst.addingTimeInterval(45) ? 70 : nil }
        guard case .fireAtDeadline? = r?.0 else { return XCTFail("expected deadline, got \(String(describing: r))") }
    }

    func testStaleEvidenceIsRejected() {
        var buf = WakeEvidenceBuffer()
        let now = t(10)
        XCTAssertEqual(buf.ingest(HRObservation(at: now.addingTimeInterval(-60), bpm: 70, receivedAt: now), now: now), .stale)
        XCTAssertEqual(buf.ingest(HRObservation(at: now.addingTimeInterval(30), bpm: 70, receivedAt: now), now: now), .future)
        XCTAssertEqual(buf.ingest(HRObservation(at: now, bpm: 250, receivedAt: now), now: now), .implausible)
        XCTAssertNil(buf.ingest(HRObservation(at: now, bpm: 70, receivedAt: now), now: now))
        XCTAssertEqual(buf.ingest(HRObservation(at: now.addingTimeInterval(0.4), bpm: 71, receivedAt: now), now: now), .duplicate)
        XCTAssertEqual(buf.ingest(HRObservation(at: now.addingTimeInterval(-3), bpm: 71, receivedAt: now), now: now), .outOfOrder)
        // Delivered late (a stalled link replaying a minute of HR): none of it is evidence.
        let r = run(.hrOnlyV2, baseline: base, ticks: everyThirty, arrivalLag: 40) { $0 >= self.t(20) ? 70 : 55 }
        guard case .fireAtDeadline? = r?.0 else { return XCTFail("stale evidence fired early") }
    }

    func testMissingOrOldBaselineNeverFiresEarly() {
        let high: (Date) -> Int? = { _ in 75 }
        guard case .fireAtDeadline? = run(.hrOnlyV2, baseline: nil, ticks: everyThirty, bpm: high)?.0 else { return XCTFail("no baseline") }
        let old = WakeBaseline(bpm: 55, source: "old", asOf: deadline.addingTimeInterval(-10 * 86_400))
        guard case .fireAtDeadline(let rec)? = run(.hrOnlyV2, baseline: old, ticks: everyThirty, bpm: high)?.0 else { return XCTFail("old baseline") }
        XCTAssertEqual(rec.baselineSource, "old")   // provenance recorded even when unusable
    }

    func testNeverBeforeWindowAndDeadlineAlwaysHolds() {
        var dec = SmartWakeDecider(occurrence: occ, mode: .smart(windowMin: 30))
        let w = [EvidenceWindow(start: t(45), end: t(44), sampleCount: 20, medianBPM: 90, usable: true)]
        XCTAssertEqual(dec.step(now: t(40), windows: w, baseline: base), .wait)
        guard case .fireAtDeadline = dec.step(now: deadline.addingTimeInterval(120), windows: [], baseline: base) else { return XCTFail() }
        XCTAssertEqual(dec.step(now: deadline.addingTimeInterval(150), windows: [], baseline: base), .wait)   // once
    }

    func testThresholdRelaxesAcrossTheWindow() {
        let p = SmartWakePolicy.hrOnlyV2
        XCTAssertEqual(p.threshold(at: occ.windowStart, occurrence: occ), 0.45, accuracy: 1e-9)
        XCTAssertEqual(p.threshold(at: t(15), occurrence: occ), 0.40, accuracy: 1e-9)
        XCTAssertEqual(p.threshold(at: deadline, occurrence: occ), 0.35, accuracy: 1e-9)
    }

    func testExactModeOnlyDeadline() {
        let r = run(.hrOnlyV2, mode: .exact, baseline: base, ticks: everyThirty) { _ in 80 }
        guard case .fireAtDeadline? = r?.0 else { return XCTFail() }
    }

    // MARK: sleep goal

    func testSleepGoalNeedsFreshMainSessionProgress() {
        let mode = AlarmSpec.Mode.sleepGoal(goalPercent: 85, windowMin: 30)
        let fresh: (Date) -> SleepGoalProgress? = { now in
            SleepGoalProgress(asleepMin: 430, needMin: 480, sessionId: "s1", sessionKind: "primary", dataThrough: now.addingTimeInterval(-600))
        }
        let flat: (Date) -> Int? = { _ in 55 }
        guard case .fireEarly(let rec)? = run(.hrOnlyV2, mode: mode, baseline: base, ticks: everyThirty, goal: fresh, bpm: flat)?.0
        else { return XCTFail("fresh goal should fire after grace") }
        XCTAssertEqual(rec.trigger, .sleepGoalGrace)

        let stale: (Date) -> SleepGoalProgress? = { now in
            SleepGoalProgress(asleepMin: 430, needMin: 480, sessionId: "s1", sessionKind: "primary", dataThrough: now.addingTimeInterval(-7200))
        }
        guard case .fireAtDeadline? = run(.hrOnlyV2, mode: mode, baseline: base, ticks: everyThirty, goal: stale, bpm: flat)?.0
        else { return XCTFail("stale progress must not fire early") }

        let nap: (Date) -> SleepGoalProgress? = { now in
            SleepGoalProgress(asleepMin: 430, needMin: 480, sessionId: "n", sessionKind: "nap", dataThrough: now)
        }
        guard case .fireAtDeadline? = run(.hrOnlyV2, mode: mode, baseline: base, ticks: everyThirty, goal: nap, bpm: flat)?.0
        else { return XCTFail("a nap is not tonight's sleep") }
    }

    func testSleepGoalFiresOnHRRunBeforeGrace() {
        let mode = AlarmSpec.Mode.sleepGoal(goalPercent: 70, windowMin: 30)
        let goal: (Date) -> SleepGoalProgress? = { now in
            SleepGoalProgress(asleepMin: 400, needMin: 480, sessionId: "s1", sessionKind: nil, dataThrough: now.addingTimeInterval(-300))
        }
        let ticks = stride(from: -40.0 * 60, through: 60, by: 10).map { deadline.addingTimeInterval($0) }
        let r = run(.hrOnlyV2, mode: mode, baseline: base, ticks: ticks, goal: goal) { $0 >= self.t(29) ? 66 : 55 }
        guard case .fireEarly(let rec)? = r?.0 else { return XCTFail() }
        XCTAssertEqual(rec.trigger, .sleepGoal)
    }
}
