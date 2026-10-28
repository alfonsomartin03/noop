import Foundation

// CausalReference.swift — personal references that only look backwards.
//
// The score for day t uses ONLY eligible observations from days strictly before t, of the SAME metric identity; the
// day is scored first and only then may it inform later days. Consequences, all tested:
//   • adding or editing a later night never changes an earlier result;
//   • replaying the same observations gives identical output (pure function, deterministic ordering);
//   • time is calendar time: a 10-day hole is 10 days, not "the previous night".
//
// Robust reference (proposed NOOP design, evidence status: engineering choice, not a validated recovery rule):
//   x      = transform(value)           (ln(RMSSD / 1 ms) for HRV; identity for HR)
//   center = median(prior eligible x within `windowDays`)
//   scale  = max(1.4826 × median(|x − center|), noiseFloor)       ← MEDIAN absolute deviation; 1.4826 makes it
//                                                                     consistent with σ for Gaussian data.
//   z      = (x − center) / scale
// The legacy EWMA path (`Baselines`) uses a MEAN absolute deviation with 1.253; the two factors are not
// interchangeable and the two paths are kept apart. `noiseFloor` is in TRANSFORMED units.

public enum CalendarDay {
    /// Days since 1970-01-01 for a "YYYY-MM-DD" label (pure Gregorian arithmetic; no time zone, no DST).
    public static func index(_ day: String) -> Int? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        // Howard Hinnant's days_from_civil.
        let y = p[1] <= 2 ? p[0] - 1 : p[0]
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (p[1] + 9) % 12
        let doy = (153 * mp + 2) / 5 + p[2] - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

public enum ReferenceTransform: String, Codable, Sendable {
    case identity
    /// ln(value / 1 unit); requires value > 0.
    case naturalLog

    func apply(_ v: Double) -> Double? {
        switch self {
        case .identity: return v.isFinite ? v : nil
        case .naturalLog: return v.isFinite && v > 0 ? Foundation.log(v) : nil
        }
    }
}

/// Configuration of one causal reference. Every number is a provisional, configurable NOOP choice.
public struct ReferenceConfig: Equatable, Sendable {
    public var transform: ReferenceTransform
    /// Only observations from the last `windowDays` calendar days before t enter the reference.
    public var windowDays: Int
    /// Fewer prior eligible observations than this → calibrating (no z).
    public var minPrior: Int
    /// At least this many → "established"; between minPrior and this → "provisional".
    public var establishedAfter: Int
    /// Most recent eligible observation older than this many days → stale (no z).
    public var staleAfterDays: Int
    /// Lower bound on `scale`, in transformed units.
    public var noiseFloor: Double
    /// Raw plausibility bounds; values outside are excluded as implausible (corrupt), not treated as physiology.
    public var plausibleRange: ClosedRange<Double>

    public init(transform: ReferenceTransform, windowDays: Int, minPrior: Int, establishedAfter: Int,
                staleAfterDays: Int, noiseFloor: Double, plausibleRange: ClosedRange<Double>) {
        self.transform = transform; self.windowDays = windowDays; self.minPrior = minPrior
        self.establishedAfter = establishedAfter; self.staleAfterDays = staleAfterDays
        self.noiseFloor = noiseFloor; self.plausibleRange = plausibleRange
    }

    /// ln RMSSD. Floor 0.05 ln-units ≈ ±5 % — a placeholder in the right units, not a validated noise level.
    public static let lnRMSSD = ReferenceConfig(transform: .naturalLog, windowDays: 60, minPrior: 5, establishedAfter: 14,
                                                staleAfterDays: 21, noiseFloor: 0.05, plausibleRange: 5...250)
    /// Sleeping resting HR in bpm. Floor 1 bpm.
    public static let restingHR = ReferenceConfig(transform: .identity, windowDays: 60, minPrior: 5, establishedAfter: 14,
                                                  staleAfterDays: 21, noiseFloor: 1.0, plausibleRange: 30...120)
}

public enum ReferenceState: String, Equatable, Sendable {
    case calibrating      // too few prior eligible observations
    case provisional      // usable, small history
    case established
    case stale            // last eligible observation too long ago
}

public struct ReferenceSnapshot: Equatable, Sendable {
    public let center: Double          // transformed units
    public let scale: Double           // transformed units, floored
    public let rawMAD: Double          // unfloored median absolute deviation (transformed units)
    public let count: Int              // prior eligible observations used
    public let daysSinceLast: Int?     // calendar days from the last eligible observation to t
    public let state: ReferenceState
}

public enum ScoreOutcome: String, Equatable, Sendable {
    case scored
    case noReference          // calibrating or stale: see `reference.state`
    case unavailable          // the observation has no value
    case excluded             // value present but ineligible (quality, implausible, wrong identity)
}

public struct ScoredObservation: Equatable, Sendable {
    public let observation: MetricObservation
    public let reference: ReferenceSnapshot?
    /// Transformed value.
    public let x: Double?
    public let z: Double?
    public let outcome: ScoreOutcome
    /// Did this observation enter the reference for LATER days?
    public let updatesReference: Bool
    public let reasons: [String]
}

public enum CausalReference {

    /// Score every observation of `identity` against its strictly-prior eligible history, in calendar order.
    /// Observations of any other identity are returned as `.excluded` ("incompatible identity") and never enter the
    /// reference. Output order: chronological (day, then endTs), stable for ties.
    public static func scoreSequence(_ observations: [MetricObservation], identity: MetricIdentity,
                                     cfg: ReferenceConfig) -> [ScoredObservation] {
        let ordered = observations.enumerated().sorted { a, b in
            let da = CalendarDay.index(a.element.day) ?? Int.min, db = CalendarDay.index(b.element.day) ?? Int.min
            if da != db { return da < db }
            let ta = a.element.endTs ?? Int.min, tb = b.element.endTs ?? Int.min
            if ta != tb { return ta < tb }
            return a.offset < b.offset
        }.map(\.element)

        var history: [(day: Int, x: Double)] = []   // eligible, chronological
        var out: [ScoredObservation] = []
        for o in ordered {
            guard let d = CalendarDay.index(o.day) else {
                out.append(ScoredObservation(observation: o, reference: nil, x: nil, z: nil, outcome: .excluded,
                                             updatesReference: false, reasons: ["unparseable day"]))
                continue
            }
            // Reference from strictly earlier days only (same-day observations never see each other). History is
            // chronological, so the same-day entries are a suffix.
            var end = history.count
            while end > 0 && history[end - 1].day >= d { end -= 1 }
            let ref = snapshot(history[..<end], at: d, cfg: cfg)

            let (x, reasons) = eligibility(o, identity: identity, cfg: cfg)
            let outcome: ScoreOutcome
            var z: Double? = nil
            if o.value == nil { outcome = .unavailable }
            else if !reasons.isEmpty || x == nil { outcome = .excluded }
            else if let r = ref, r.state == .provisional || r.state == .established, let xv = x {
                z = (xv - r.center) / r.scale; outcome = .scored
            } else { outcome = .noReference }

            let updates = (outcome == .scored || outcome == .noReference) && x != nil
            if updates, let xv = x { history.append((d, xv)) }
            out.append(ScoredObservation(observation: o, reference: ref, x: x, z: z, outcome: outcome,
                                         updatesReference: updates, reasons: reasons))
        }
        return out
    }

    /// Transformed value and exclusion reasons. Depends only on the observation itself, never on the history, so
    /// whether a night updates the reference is fixed the moment it is recorded.
    static func eligibility(_ o: MetricObservation, identity: MetricIdentity,
                            cfg: ReferenceConfig) -> (x: Double?, reasons: [String]) {
        var reasons = o.exclusionReasons
        if !o.identity.isBaselineCompatible(with: identity) { reasons.append("incompatible identity") }
        var x: Double? = nil
        if let v = o.value {
            if !cfg.plausibleRange.contains(v) { reasons.append("implausible value") }
            else if let t = cfg.transform.apply(v) { x = t } else { reasons.append("not transformable") }
        }
        return (x, reasons)
    }

    /// Reference for day `d` from prior eligible observations (chronological, already restricted to days < d).
    static func snapshot(_ prior: ArraySlice<(day: Int, x: Double)>, at d: Int, cfg: ReferenceConfig) -> ReferenceSnapshot? {
        guard let last = prior.last else { return nil }
        var window: [Double] = []
        for e in prior.reversed() { if e.day < d - cfg.windowDays { break }; window.append(e.x) }
        let since = d - last.day
        guard !window.isEmpty else {
            return ReferenceSnapshot(center: .nan, scale: .nan, rawMAD: .nan, count: 0, daysSinceLast: since, state: .stale)
        }
        let center = HRVAnalyzer.median(window)
        let mad = HRVAnalyzer.median(window.map { abs($0 - center) })
        let scale = max(1.4826 * mad, cfg.noiseFloor)
        let state: ReferenceState
        if since > cfg.staleAfterDays { state = .stale }
        else if window.count < cfg.minPrior { state = .calibrating }
        else if window.count < cfg.establishedAfter { state = .provisional }
        else { state = .established }
        return ReferenceSnapshot(center: center, scale: scale, rawMAD: mad, count: window.count,
                                 daysSinceLast: since, state: state)
    }

    /// The reference a NEW observation on `day` would be scored against (no observation for `day` needed).
    public static func reference(for day: String, history: [MetricObservation], identity: MetricIdentity,
                                 cfg: ReferenceConfig) -> ReferenceSnapshot? {
        guard let d = CalendarDay.index(day) else { return nil }
        let prior = history.compactMap { o -> (day: Int, x: Double)? in
            guard let od = CalendarDay.index(o.day), od < d, o.value != nil else { return nil }
            let (x, reasons) = eligibility(o, identity: identity, cfg: cfg)
            guard reasons.isEmpty, let x else { return nil }
            return (od, x)
        }.sorted { $0.day < $1.day }
        return snapshot(prior[...], at: d, cfg: cfg)
    }
}

// MARK: - Causal legacy EWMA baselines

extension Baselines {
    /// Legacy Winsorized EWMA state as of the START of `day`: folds eligible observations of `identity` from days
    /// strictly before it, inserting a missing night for every calendar day without one, so staleness counts real
    /// elapsed nights. (The EWMA weights stay per observation — skip-and-hold does not decay — exactly as the legacy
    /// model was fitted; only the leakage and the "sparse rows are consecutive nights" error are removed.)
    public static func causalState(_ observations: [MetricObservation], identity: MetricIdentity,
                                   before day: String, cfg: MetricCfg) -> BaselineState? {
        guard let d = CalendarDay.index(day) else { return nil }
        var byDay: [Int: Double] = [:]
        for o in observations where o.identity.isBaselineCompatible(with: identity) && o.isEligible {
            guard let od = CalendarDay.index(o.day), od < d, let v = o.value else { continue }
            byDay[od] = v                                  // one value per night; last wins deterministically
        }
        guard let first = byDay.keys.min() else { return nil }
        var state: BaselineState? = nil
        for k in first..<d { state = update(state, value: byDay[k], cfg: cfg) }
        return state
    }
}

public enum CausalBaselines {
    /// Legacy-model baselines for scoring `day`: NOOP's own nightly RMSSD / sleeping resting HR from strictly earlier
    /// days of the same identity. Respiration is deliberately absent (inferred, experimental; see RespiratoryRate).
    public static func legacyProfile(rmssd: [MetricObservation], restingHR: [MetricObservation], before day: String,
                                     hardware: String = MetricIdentity.unknownValue) -> AnalyticsEngine.ProfileBaselines {
        AnalyticsEngine.ProfileBaselines(
            hrv: Baselines.causalState(rmssd, identity: .noopNightlyRMSSD(hardware: hardware), before: day, cfg: Baselines.hrvCfg),
            restingHR: Baselines.causalState(restingHR, identity: .noopSleepRestingHR(hardware: hardware), before: day,
                                             cfg: Baselines.restingHRCfg),
            resp: nil,
            lnRMSSDReference: CausalReference.reference(for: day, history: rmssd,
                                                        identity: .noopNightlyRMSSD(hardware: hardware), cfg: .lnRMSSD),
            restingHRReference: CausalReference.reference(for: day, history: restingHR,
                                                          identity: .noopSleepRestingHR(hardware: hardware), cfg: .restingHR))
    }
}
