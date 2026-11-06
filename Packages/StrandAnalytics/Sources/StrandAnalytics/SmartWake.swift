import Foundation

// SmartWake.swift — the early-wake decision for smart / sleep-goal alarms, from TIMESTAMPED evidence.
//
// Evidence is real heart-rate samples stamped with the time they were measured (strap time mapped to the Mac clock),
// not the time a timer happened to look. Samples are aggregated into short fixed windows (median per window), and an
// early wake needs a SUSTAINED run of windows measured over elapsed time — never a count of timer calls, and a sample
// can only ever be counted once. Missing, stale, duplicate, out-of-order or implausible evidence never fires early;
// the latest wake time (deadline) always holds.
//
// What the score means: heart rate above a sleeping-HR baseline. It is an HR-only heuristic for "awake or lightly
// asleep", NOT a measured or validated sleep stage, and nothing here may describe it as confirmed light sleep.

/// One heart-rate sample. `at` = when it was measured (Mac clock), `receivedAt` = when NOOP got it.
public struct HRObservation: Equatable, Sendable {
    public let at: Date
    public let bpm: Int
    public let receivedAt: Date
    public init(at: Date, bpm: Int, receivedAt: Date) { self.at = at; self.bpm = bpm; self.receivedAt = receivedAt }
}

/// One fixed evidence window (aligned to a grid of `length` seconds).
public struct EvidenceWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let sampleCount: Int
    /// Median bpm of the window's samples (robust to single-beat spikes); nil when empty.
    public let medianBPM: Double?
    /// Enough samples to judge the window.
    public let usable: Bool
}

/// Holds recent HR samples and turns them into completed evidence windows. Rejects what must not count.
public struct WakeEvidenceBuffer: Sendable {
    public enum Rejection: String, Sendable, CaseIterable {
        case implausible, duplicate, outOfOrder, stale, future
    }
    /// A sample measured longer ago than this when it arrives is stale (a replay or a stalled link), not evidence.
    public var maxArrivalLag: TimeInterval = 15
    /// A sample stamped further than this ahead of the clock is a mapping error.
    public var maxFutureSkew: TimeInterval = 5
    /// How long samples are kept.
    public var retention: TimeInterval = 15 * 60
    public static let plausibleBPM = 30...220

    public private(set) var samples: [HRObservation] = []
    public private(set) var rejections: [Rejection: Int] = [:]

    public init() {}

    /// Add one sample. Returns why it was rejected, or nil when accepted.
    @discardableResult
    public mutating func ingest(_ o: HRObservation, now: Date) -> Rejection? {
        let why: Rejection? = {
            if !Self.plausibleBPM.contains(o.bpm) { return .implausible }
            if o.at.timeIntervalSince(now) > maxFutureSkew { return .future }
            if o.receivedAt.timeIntervalSince(o.at) > maxArrivalLag || now.timeIntervalSince(o.at) > maxArrivalLag { return .stale }
            if let last = samples.last {
                if Int(o.at.timeIntervalSince1970.rounded(.down)) == Int(last.at.timeIntervalSince1970.rounded(.down)) { return .duplicate }
                if o.at < last.at { return .outOfOrder }
            }
            return nil
        }()
        if let why { rejections[why, default: 0] += 1; return why }
        samples.append(o)
        let cutoff = now.addingTimeInterval(-retention)
        if let i = samples.firstIndex(where: { $0.at >= cutoff }), i > 0 { samples.removeFirst(i) }
        return nil
    }

    public mutating func reset() { samples.removeAll(); rejections.removeAll() }

    /// Completed windows (end ≤ now) from `from`, aligned to multiples of `length` seconds since 1970. Windows with no
    /// samples are returned too (sampleCount 0, unusable), so a gap breaks a sustained run.
    public func windows(from: Date, endingBy now: Date, length: TimeInterval, minSamples: Int) -> [EvidenceWindow] {
        guard length > 0 else { return [] }
        let first = (from.timeIntervalSince1970 / length).rounded(.down) * length
        var out: [EvidenceWindow] = []
        var t = first
        var i = samples.firstIndex { $0.at.timeIntervalSince1970 >= first } ?? samples.count
        while t + length <= now.timeIntervalSince1970 {
            var bpms: [Int] = []
            while i < samples.count, samples[i].at.timeIntervalSince1970 < t + length { bpms.append(samples[i].bpm); i += 1 }
            bpms.sort()
            let median: Double? = bpms.isEmpty ? nil
                : bpms.count % 2 == 1 ? Double(bpms[bpms.count / 2]) : Double(bpms[bpms.count / 2 - 1] + bpms[bpms.count / 2]) / 2
            out.append(EvidenceWindow(start: Date(timeIntervalSince1970: t), end: Date(timeIntervalSince1970: t + length),
                                      sampleCount: bpms.count, medianBPM: median, usable: bpms.count >= minSamples))
            t += length
        }
        return out
    }
}

/// Sleeping-HR reference with where it came from and how old it is.
public struct WakeBaseline: Equatable, Sendable, Codable {
    public let bpm: Double
    /// e.g. "noop-resting-hr 2026-11-04" or "imported-resting-hr 2026-11-03".
    public let source: String
    /// When the reference was measured (the night it comes from).
    public let asOf: Date
    public init(bpm: Double, source: String, asOf: Date) { self.bpm = bpm; self.source = source; self.asOf = asOf }
}

/// Tonight's sleep so far against the need, from synced episodes. Carries its own freshness and session identity.
public struct SleepGoalProgress: Equatable, Sendable {
    public let asleepMin: Double
    public let needMin: Double
    public let sessionId: String?
    /// "primary" / "interruptedPrimary" / nil (legacy main); naps and uncertain sessions do not count.
    public let sessionKind: String?
    /// Newest moment the synced data covers (end of the session's last episode).
    public let dataThrough: Date
    public init(asleepMin: Double, needMin: Double, sessionId: String?, sessionKind: String?, dataThrough: Date) {
        self.asleepMin = asleepMin; self.needMin = needMin; self.sessionId = sessionId; self.sessionKind = sessionKind
        self.dataThrough = dataThrough
    }
}

/// The tunable rules of one policy version. Defaults are an EXPERIMENTAL starting point compared on synthetic traces
/// (SmartWakePolicyTests), not a validated sleep-stage threshold.
public struct SmartWakePolicy: Equatable, Sendable, Codable {
    public var version: String
    /// Evidence window length and the samples a window needs to be judged.
    public var windowSeconds: TimeInterval
    public var minSamplesPerWindow: Int
    /// Elapsed time a run of qualifying windows must cover to fire early.
    public var sustainSeconds: TimeInterval
    /// Score threshold at the window start, relaxing linearly to `thresholdEnd` at the deadline.
    public var thresholdStart: Double
    public var thresholdEnd: Double
    /// HR rise over the baseline that scores 1.0 (score = rise / this, clamped).
    public var fullScoreRise: Double
    /// Older baselines are not used (no early HR trigger).
    public var maxBaselineAge: TimeInterval
    /// The run must end this recently: evidence that stopped arriving is not a reason to fire.
    public var maxEvidenceLag: TimeInterval
    /// Sleep-goal progress older than this (synced data) is not used.
    public var maxGoalDataLag: TimeInterval
    /// After the sleep goal is met, the longest NOOP waits for a qualifying HR run.
    public var goalGraceSeconds: TimeInterval

    /// Policy before 2026-11-05 expressed in these terms, for comparison only: instantaneous HR (one sample per 30-s
    /// tick), threshold 0.6 (≈ +15 % HR), three consecutive ticks (counted calls, ≈ 60–90 s).
    public static let legacyV1 = SmartWakePolicy(
        version: "smart-wake-v1-legacy", windowSeconds: 30, minSamplesPerWindow: 1, sustainSeconds: 90,
        thresholdStart: 0.6, thresholdEnd: 0.6, fullScoreRise: 0.25, maxBaselineAge: .infinity,
        maxEvidenceLag: .infinity, maxGoalDataLag: .infinity, goalGraceSeconds: 600)

    /// Current default: 20-s median windows (≥ 10 samples), 60 s sustained, threshold 0.45 → 0.35 across the window
    /// (≈ +11 % → +9 % HR over the sleeping baseline).
    public static let hrOnlyV2 = SmartWakePolicy(
        version: "smart-wake-v2-hr", windowSeconds: 20, minSamplesPerWindow: 10, sustainSeconds: 60,
        thresholdStart: 0.45, thresholdEnd: 0.35, fullScoreRise: 0.25, maxBaselineAge: 4 * 86_400,
        maxEvidenceLag: 45, maxGoalDataLag: 45 * 60, goalGraceSeconds: 600)

    public static let current = hrOnlyV2

    public func threshold(at t: Date, occurrence o: AlarmOccurrence) -> Double {
        let span = o.deadline.timeIntervalSince(o.windowStart)
        guard span > 0 else { return thresholdStart }
        let f = min(1, max(0, t.timeIntervalSince(o.windowStart) / span))
        return thresholdStart + (thresholdEnd - thresholdStart) * f
    }

    public func score(medianBPM: Double, baseline: Double) -> Double {
        guard baseline > 0, fullScoreRise > 0 else { return 0 }
        return min(1, max(0, (medianBPM / baseline - 1) / fullScoreRise))
    }
}

/// Why and how an alarm fired (or would fire): stored with the alarm history.
public struct WakeDecisionRecord: Equatable, Sendable, Codable {
    public enum Trigger: String, Codable, Sendable { case hrRun, sleepGoal, sleepGoalGrace, deadline }
    public var trigger: Trigger
    public var decidedAt: Date
    public var policyVersion: String
    public var threshold: Double?
    /// Lowest window score in the qualifying run.
    public var score: Double?
    public var sustainedSeconds: Double?
    public var evidenceFrom: Date?
    public var evidenceTo: Date?
    public var baselineBPM: Double?
    public var baselineSource: String?
    public var baselineAgeHours: Double?
    /// Plain description of the evidence quality ("3 windows, 57 samples", "no recent heart rate", …).
    public var evidenceQuality: String
    /// User-facing reason. Never claims a sleep stage.
    public var reason: String

    public init(trigger: Trigger, decidedAt: Date, policyVersion: String, threshold: Double?, score: Double?,
                sustainedSeconds: Double?, evidenceFrom: Date?, evidenceTo: Date?, baselineBPM: Double?, baselineSource: String?,
                baselineAgeHours: Double?, evidenceQuality: String, reason: String) {
        self.trigger = trigger; self.decidedAt = decidedAt; self.policyVersion = policyVersion; self.threshold = threshold
        self.score = score; self.sustainedSeconds = sustainedSeconds; self.evidenceFrom = evidenceFrom; self.evidenceTo = evidenceTo
        self.baselineBPM = baselineBPM; self.baselineSource = baselineSource; self.baselineAgeHours = baselineAgeHours
        self.evidenceQuality = evidenceQuality; self.reason = reason
    }
}

/// Decides when a smart / sleep-goal alarm fires inside its window. Never fires before the window, always by the
/// deadline, and fires early only on a sustained run of fresh, usable evidence windows.
public struct SmartWakeDecider: Sendable {
    public enum Decision: Equatable, Sendable {
        case wait
        case fireEarly(WakeDecisionRecord)
        case fireAtDeadline(WakeDecisionRecord)
    }

    public let occurrence: AlarmOccurrence
    public let mode: AlarmSpec.Mode
    public let policy: SmartWakePolicy
    public private(set) var fired = false
    /// Latest evidence-quality summary, for the UI while waiting.
    public private(set) var quality = "No evidence yet"

    private var lastWindowEnd: Date?
    private var runStart: Date?
    private var runEnd: Date?
    private var runMinScore: Double?
    private var runSamples = 0
    private var runWindows = 0
    private var goalReachedAt: Date?

    public init(occurrence: AlarmOccurrence, mode: AlarmSpec.Mode, policy: SmartWakePolicy = .current) {
        self.occurrence = occurrence; self.mode = mode; self.policy = policy
    }

    /// Feed the completed evidence windows known at `now` (may repeat earlier ones: each window is consumed once).
    public mutating func step(now: Date, windows: [EvidenceWindow], baseline: WakeBaseline?,
                              sleepGoal: SleepGoalProgress? = nil) -> Decision {
        guard !fired else { return .wait }
        let base = usableBaseline(baseline, now: now)
        if now >= occurrence.deadline {
            fired = true
            return .fireAtDeadline(record(.deadline, now: now, baseline: baseline, reason: "Latest wake time"))
        }
        guard now >= occurrence.windowStart, mode != .exact else { return .wait }

        consume(windows, baseline: base)
        let fresh = runEnd.map { now.timeIntervalSince($0) <= policy.maxEvidenceLag } ?? false
        let sustained = (runStart != nil && runEnd != nil) ? runEnd!.timeIntervalSince(runStart!) : 0
        let hrRun = fresh && sustained >= policy.sustainSeconds
        updateQuality(now: now, baseline: baseline, base: base)

        switch mode {
        case .exact:
            return .wait
        case .smart:
            guard hrRun else { return .wait }
            fired = true
            return .fireEarly(record(.hrRun, now: now, baseline: baseline,
                                     reason: "Heart rate stayed above your sleeping level for \(Int(sustained)) s"))
        case .sleepGoal(let pct, _):
            guard let g = sleepGoal, goalUsable(g, now: now), g.asleepMin >= Double(pct) / 100 * g.needMin else { return .wait }
            if goalReachedAt == nil { goalReachedAt = now }
            if hrRun {
                fired = true
                return .fireEarly(record(.sleepGoal, now: now, baseline: baseline,
                                         reason: "Reached \(pct)% of your sleep need; heart rate rose for \(Int(sustained)) s"))
            }
            if now.timeIntervalSince(goalReachedAt!) >= policy.goalGraceSeconds {
                fired = true
                return .fireEarly(record(.sleepGoalGrace, now: now, baseline: baseline,
                                         reason: "Reached \(pct)% of your sleep need"))
            }
            return .wait
        }
    }

    private func usableBaseline(_ b: WakeBaseline?, now: Date) -> Double? {
        guard let b, b.bpm >= 30, b.bpm <= 120, now.timeIntervalSince(b.asOf) <= policy.maxBaselineAge else { return nil }
        return b.bpm
    }

    func goalUsable(_ g: SleepGoalProgress, now: Date) -> Bool {
        let mainKind = g.sessionKind == nil || g.sessionKind == "primary" || g.sessionKind == "interruptedPrimary"
        return mainKind && g.needMin > 0 && g.asleepMin >= 0 && g.dataThrough <= now.addingTimeInterval(60)
            && now.timeIntervalSince(g.dataThrough) <= policy.maxGoalDataLag
    }

    private mutating func consume(_ windows: [EvidenceWindow], baseline: Double?) {
        for w in windows.sorted(by: { $0.end < $1.end }) {
            if let last = lastWindowEnd, w.end <= last { continue }   // already counted
            lastWindowEnd = w.end
            guard w.start >= occurrence.windowStart else { continue }
            let threshold = policy.threshold(at: w.end, occurrence: occurrence)
            let score = (baseline != nil && w.usable) ? w.medianBPM.map { policy.score(medianBPM: $0, baseline: baseline!) } : nil
            if let score, score >= threshold {
                if runEnd != w.start || runStart == nil { runStart = w.start; runMinScore = nil; runSamples = 0; runWindows = 0 }
                runEnd = w.end
                runMinScore = min(runMinScore ?? score, score)
                runSamples += w.sampleCount
                runWindows += 1
            } else {
                runStart = nil; runEnd = nil; runMinScore = nil; runSamples = 0; runWindows = 0
            }
        }
    }

    private mutating func updateQuality(now: Date, baseline: WakeBaseline?, base: Double?) {
        if base == nil {
            quality = baseline == nil ? "No sleeping heart-rate baseline yet" : "Sleeping heart-rate baseline too old"
        } else if let last = lastWindowEnd, now.timeIntervalSince(last) <= policy.windowSeconds * 2 {
            quality = runWindows > 0 ? "\(runWindows) qualifying window\(runWindows == 1 ? "" : "s"), \(runSamples) samples"
                                     : "Heart rate arriving; not above threshold"
        } else {
            quality = "No recent heart rate"
        }
    }

    private func record(_ t: WakeDecisionRecord.Trigger, now: Date, baseline: WakeBaseline?, reason: String) -> WakeDecisionRecord {
        let hr = t == .hrRun || t == .sleepGoal
        return WakeDecisionRecord(
            trigger: t, decidedAt: now, policyVersion: policy.version,
            threshold: mode == .exact ? nil : policy.threshold(at: now, occurrence: occurrence),
            score: hr ? runMinScore : nil,
            sustainedSeconds: hr ? runEnd.flatMap { e in runStart.map { e.timeIntervalSince($0) } } : nil,
            evidenceFrom: hr ? runStart : nil, evidenceTo: hr ? runEnd : nil,
            baselineBPM: baseline?.bpm, baselineSource: baseline?.source,
            baselineAgeHours: baseline.map { now.timeIntervalSince($0.asOf) / 3600 },
            evidenceQuality: quality, reason: reason)
    }
}
