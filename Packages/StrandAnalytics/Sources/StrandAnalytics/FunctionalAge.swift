import Foundation

/// NOOP functional age and projected pace of functional aging (#49) — model core and parameter manifest.
///
/// Lane chosen by the owner 2026-11-18: a WEARABLE functional-age estimate in a hazard-equivalent ("effective age")
/// framework, not clinical/lab biological age, not cardiovascular/fitness age, and not WHOOP numerical parity.
///
/// Combination (v1, owner decision 2026-11-18 after a search found no published joint model for these wearable
/// inputs): ONE contributor per correlated group — activity/fitness (measured VO₂max, else steps), resting heart
/// rate, sleep duration — each mapped through its cited marginal curve and summed. This is a NOOP simplification:
/// residual overlap between groups is not removed. `estimate` computes it deterministically; `evaluate` (what the
/// Health page reads) stays GATED (`numericRelease == false`) until input windows, a birth date and the UI exist.
/// Method and sources: `docs/HEALTH_MODELS.md`.
public enum FunctionalAge {
    public static let modelVersion = "noop-functional-age-v1-groups"
    /// No numeric age/pace on screen until input windows, coverage rules, a birth date and the UI are in place.
    public static let numericRelease = false

    // MARK: Risk → years

    /// Years of "effective age" per unit of ln(hazard ratio): age impact = ln(HR) / 0.1, i.e. one year per ~10.5 %
    /// higher all-cause hazard. Source: WHOOP 2025 Healthspan white paper (printed p. 12), restating the
    /// hazard-equivalent-age idea (Spiegelhalter 2016, BMC Med Inform Decis Mak, doi:10.1186/s12911-016-0342-z).
    /// The 0.1/year log-hazard slope is a population approximation, not a fitted NOOP parameter.
    public static let logHazardPerYear = 0.1

    /// Years added (positive) or removed (negative) by a hazard ratio. nil for non-positive / non-finite ratios.
    public static func ageImpactYears(hazardRatio: Double) -> Double? {
        guard hazardRatio.isFinite, hazardRatio > 0 else { return nil }
        return log(hazardRatio) / logHazardPerYear
    }

    // MARK: Pace

    /// Mean Gregorian year in seconds; horizons come from real dates, so a "6-month" horizon is its true length.
    static let secondsPerYear = 365.2425 * 86_400

    /// Projected pace of functional aging, in years of functional age per calendar year:
    ///   A_now  = C_now + D_current,   A_proj = C_now + H + D_projected
    ///   pace   = (A_proj − A_now) / H = 1 + (D_projected − D_current) / H
    /// Chronological aging enters exactly once (the "1"). `H` = `to − from` in years. Returned RAW (no display clamp):
    /// a stable input profile gives exactly 1.0. nil when the horizon is not positive or an input is not finite.
    public static func pace(currentImpact: Double, projectedImpact: Double, from: Date, to: Date) -> Double? {
        let h = to.timeIntervalSince(from) / secondsPerYear
        guard h > 0, currentImpact.isFinite, projectedImpact.isFinite else { return nil }
        return 1 + (projectedImpact - currentImpact) / h
    }

    /// Continuous chronological age at `asOf` from a birth date (no step on birthdays).
    public static func chronologicalAge(birth: Date, asOf: Date) -> Double? {
        let years = asOf.timeIntervalSince(birth) / secondsPerYear
        return years >= 0 ? years : nil
    }

    // MARK: Contributors and parameters

    public enum Contributor: String, CaseIterable, Sendable {
        case sleepDuration, sleepRegularity, steps, moderateActivity, vigorousActivity, strength, restingHR, vo2max,
             leanMass

        public var label: String {
            switch self {
            case .sleepDuration: return "Sleep duration"
            case .sleepRegularity: return "Sleep regularity"
            case .steps: return "Daily steps"
            case .moderateActivity: return "Moderate activity (HR zones 1–3)"
            case .vigorousActivity: return "Vigorous activity (HR zones 4–5)"
            case .strength: return "Strength training"
            case .restingHR: return "Resting heart rate"
            case .vo2max: return "VO₂max (measured)"
            case .leanMass: return "Lean mass (optional)"
            }
        }
    }

    public enum ParameterStatus: Equatable, Sendable {
        /// Effect size read from the cited paper's abstract/full text; still a MARGINAL association.
        case verifiedMarginal
        /// Source identified but the number could not be confirmed from the paper itself: carries no value.
        case needsVerification
    }

    public struct Parameter: Equatable, Sendable {
        public let contributor: Contributor
        /// Exposure contrast the ratio refers to, e.g. "+10 bpm" or "quartile 2 vs quartile 1".
        public let contrast: String
        public let hazardRatio: Double?
        public let ci95: ClosedRange<Double>?
        public let outcome: String
        public let population: String
        public let citation: String
        public let doi: String
        public let status: ParameterStatus
        public let caveat: String
    }

    /// Parameter manifest v0 (sources checked 2026-11-18). Marginal associations only; none is a causal effect, and
    /// none may be summed with another without the joint model.
    public static let manifest: [Parameter] = [
        Parameter(contributor: .restingHR, contrast: "+10 bpm resting heart rate", hazardRatio: 1.09, ci95: 1.07...1.12,
                  outcome: "all-cause mortality", population: "40 prospective cohorts, 1.25 M participants, general population",
                  citation: "Zhang D, Shen X, Qi X. CMAJ 2016;188(3):E53–E63", doi: "10.1503/cmaj.150535",
                  status: .verifiedMarginal, caveat: "Substantial heterogeneity and publication bias reported; office/clinic RHR, not nightly wearable RHR."),
        Parameter(contributor: .vo2max, contrast: "+1 MET cardiorespiratory fitness (3.5 ml/kg/min)", hazardRatio: 0.87,
                  ci95: 0.84...0.90, outcome: "all-cause mortality", population: "33 studies, 102,980 healthy adults",
                  citation: "Kodama S et al. JAMA 2009;301(19):2024–2035", doi: "10.1001/jama.2009.681",
                  status: .verifiedMarginal, caveat: "Measured (exercise-test) fitness. NOOP's HR-ratio estimate is a function of age and RHR and is NOT an accepted input."),
        Parameter(contributor: .sleepDuration, contrast: "short sleep vs reference (study-specific definitions)", hazardRatio: 1.12,
                  ci95: 1.06...1.18, outcome: "all-cause mortality", population: "16 cohorts, ~1.38 M participants, self-reported sleep",
                  citation: "Cappuccio FP et al. Sleep 2010;33(5):585–592", doi: "10.1093/sleep/33.5.585",
                  status: .verifiedMarginal, caveat: "Categorical, self-reported, varying cut-offs; not a dose-response curve for measured sleep."),
        Parameter(contributor: .sleepDuration, contrast: "long sleep vs reference (study-specific definitions)", hazardRatio: 1.30,
                  ci95: 1.22...1.38, outcome: "all-cause mortality", population: "16 cohorts, ~1.38 M participants, self-reported sleep",
                  citation: "Cappuccio FP et al. Sleep 2010;33(5):585–592", doi: "10.1093/sleep/33.5.585",
                  status: .verifiedMarginal, caveat: "Long sleep likely reflects illness (reverse causation); categorical cut-offs."),
        Parameter(contributor: .steps, contrast: "quartile 2 (median 5,801/day) vs quartile 1 (median 3,553/day)", hazardRatio: 0.60, ci95: 0.51...0.71,
                  outcome: "all-cause mortality", population: "15 cohorts, device-measured steps",
                  citation: "Paluch AE et al. Lancet Public Health 2022;7(3):e219–e228", doi: "10.1016/S2468-2667(21)00302-9",
                  status: .verifiedMarginal, caveat: "Plateau differs by age (6–8k ≥ 60 y, 8–10k < 60 y)."),
        Parameter(contributor: .steps, contrast: "quartile 3 (median 7,842/day) vs quartile 1", hazardRatio: 0.55, ci95: 0.49...0.62,
                  outcome: "all-cause mortality", population: "15 cohorts, device-measured steps",
                  citation: "Paluch AE et al. Lancet Public Health 2022;7(3):e219–e228", doi: "10.1016/S2468-2667(21)00302-9",
                  status: .verifiedMarginal, caveat: "Categorical; NOOP interpolates between medians (engineering choice)."),
        Parameter(contributor: .steps, contrast: "quartile 4 (median 10,901/day) vs quartile 1", hazardRatio: 0.47, ci95: nil,
                  outcome: "all-cause mortality", population: "15 cohorts, device-measured steps",
                  citation: "Paluch AE et al. Lancet Public Health 2022;7(3):e219–e228", doi: "10.1016/S2468-2667(21)00302-9",
                  status: .verifiedMarginal, caveat: "Confidence interval not confirmed; no extrapolation beyond the top median."),
        Parameter(contributor: .sleepRegularity, contrast: "top four vs bottom quintile of Sleep Regularity Index", hazardRatio: nil, ci95: nil,
                  outcome: "all-cause mortality", population: "~61,000 UK Biobank, accelerometer SRI",
                  citation: "Windred DP et al. Sleep 2024;47(1):zsad253", doi: "10.1093/sleep/zsad253",
                  status: .needsVerification, caveat: "Only the 20–48 % lower-risk range was confirmed; per-quintile hazard ratios needed."),
        Parameter(contributor: .strength, contrast: "30–60 min/week muscle-strengthening vs none", hazardRatio: nil, ci95: nil,
                  outcome: "all-cause mortality", population: "16 prospective cohorts",
                  citation: "Momma H et al. Br J Sports Med 2022;56(13):755–763", doi: "10.1136/bjsports-2021-105061",
                  status: .needsVerification, caveat: "Only a 10–20 % lower-risk range was confirmed; J-shaped; very-low certainty for some outcomes."),
        Parameter(contributor: .moderateActivity, contrast: "source not chosen", hazardRatio: nil, ci95: nil,
                  outcome: "all-cause mortality", population: "-", citation: "-", doi: "-",
                  status: .needsVerification, caveat: "Needs an HRR-zone-compatible dose-response source; NOOP zones are %HRmax today."),
        Parameter(contributor: .vigorousActivity, contrast: "source not chosen", hazardRatio: nil, ci95: nil,
                  outcome: "all-cause mortality", population: "-", citation: "-", doi: "-",
                  status: .needsVerification, caveat: "As above; must not double-count steps and moderate minutes."),
        Parameter(contributor: .leanMass, contrast: "source not chosen", hazardRatio: nil, ci95: nil,
                  outcome: "all-cause mortality", population: "-", citation: "-", doi: "-",
                  status: .needsVerification, caveat: "Optional; needs a dated, method-labelled body-composition input."),
    ]

    // MARK: Inputs and evaluation

    /// Where an input value came from. Derived estimates that are functions of other contributors are refused.
    public enum InputSource: Equatable, Sendable {
        case noop, imported, manual(method: String), derivedEstimate(String)
    }

    public struct Input: Equatable, Sendable {
        public let contributor: Contributor
        public let value: Double?
        public let source: InputSource
        public let coveredDays: Int
        public let requiredDays: Int
        public init(contributor: Contributor, value: Double?, source: InputSource, coveredDays: Int, requiredDays: Int) {
            self.contributor = contributor; self.value = value; self.source = source
            self.coveredDays = coveredDays; self.requiredDays = requiredDays
        }
    }

    // MARK: v1 combination — one contributor per group

    public enum Group: String, CaseIterable, Sendable {
        case activityFitness, restingHR, sleep
        public var label: String {
            switch self {
            case .activityFitness: return "Activity or fitness (measured VO₂max, or daily steps)"
            case .restingHR: return "Resting heart rate"
            case .sleep: return "Sleep duration"
            }
        }
    }

    /// Per-contributor mapping from a measured value to a hazard ratio vs the referent. `clipped` = the value was
    /// outside the supported range and was held at its edge (no extrapolation). nil = not used in v1.
    public static func hazardRatio(for c: Contributor, value v: Double) -> (hr: Double, clipped: Bool)? {
        guard v.isFinite else { return nil }
        switch c {
        case .restingHR:
            // Zhang 2016: 1.09 per +10 bpm (log-linear). Referent 60 bpm, range 40–100: NOOP choices.
            let x = min(max(v, 40), 100)
            return (pow(1.09, (x - 60) / 10), x != v)
        case .vo2max:
            // Kodama 2009: 0.87 per +1 MET (3.5 ml/kg/min). Referent 7.9 METs (the paper's suggested minimum),
            // range 4–16 METs: NOOP choices. Input in ml/kg/min.
            let mets = v / 3.5, x = min(max(mets, 4), 16)
            return (pow(0.87, x - 7.9), x != mets)
        case .steps:
            // Paluch 2022 quartile medians → HR vs Q1, log-interpolated between medians (NOOP choice); flat
            // outside [Q1, Q4] medians (below Q1 = referent; above Q4 = plateau, no extrapolation).
            let knots: [(Double, Double)] = [(3_553, 1.0), (5_801, 0.60), (7_842, 0.55), (10_901, 0.47)]
            if v <= knots[0].0 { return (1.0, v < knots[0].0) }
            if v >= knots[3].0 { return (knots[3].1, v > knots[3].0) }
            for (a, b) in zip(knots, knots.dropFirst()) where v <= b.0 {
                let f = (v - a.0) / (b.0 - a.0)
                return (exp(log(a.1) + f * (log(b.1) - log(a.1))), false)
            }
            return nil
        case .sleepDuration:
            // Cappuccio 2010 categories (study-specific cut-offs; NOOP uses < 6 h short, > 9 h long). Hours/night.
            guard v > 0, v < 24 else { return nil }
            return (v < 6 ? 1.12 : v > 9 ? 1.30 : 1.0, false)
        case .sleepRegularity, .moderateActivity, .vigorousActivity, .strength, .leanMass:
            return nil
        }
    }

    public static func group(of c: Contributor) -> Group? {
        switch c {
        case .vo2max, .steps: return .activityFitness
        case .restingHR: return .restingHR
        case .sleepDuration: return .sleep
        default: return nil
        }
    }

    public struct ContributorImpact: Equatable, Sendable {
        public let group: Group
        public let contributor: Contributor
        public let value: Double
        public let hazardRatio: Double
        public let years: Double
        public let clipped: Bool
    }

    public struct Estimate: Equatable, Sendable {
        public let modelVersion: String
        public let chronologicalAge: Double
        public let impacts: [ContributorImpact]
        public var totalImpact: Double { impacts.reduce(0) { $0 + $1.years } }
        public var functionalAge: Double { chronologicalAge + totalImpact }
    }

    /// Deterministic v1 estimate, or nil with the reasons when a required group has no usable input. Measured VO₂max
    /// (manual source) represents activity/fitness when present, else steps; never both.
    public static func estimate(inputs: [Input], chronologicalAge: Double?) -> (Estimate?, [String]) {
        var reasons: [String] = []
        guard let age = chronologicalAge, age.isFinite, age >= 0 else {
            return (nil, ["Chronological age (birth date or age in Profile)"])
        }
        let usable = inputs.filter { inputProblems($0).isEmpty && hazardRatio(for: $0.contributor, value: $0.value ?? .nan) != nil }
        func pick(_ g: Group) -> Input? {
            let cands = usable.filter { group(of: $0.contributor) == g }
            if g == .activityFitness, let v = cands.first(where: { $0.contributor == .vo2max }) { return v }
            return cands.first
        }
        var impacts: [ContributorImpact] = []
        for g in Group.allCases {
            guard let i = pick(g), let v = i.value, let m = hazardRatio(for: i.contributor, value: v),
                  let y = ageImpactYears(hazardRatio: m.hr) else {
                reasons.append("\(g.label): no usable input yet")
                continue
            }
            impacts.append(ContributorImpact(group: g, contributor: i.contributor, value: v, hazardRatio: m.hr,
                                             years: y, clipped: m.clipped))
        }
        guard reasons.isEmpty else { return (nil, reasons) }
        return (Estimate(modelVersion: modelVersion, chronologicalAge: age, impacts: impacts), [])
    }

    public enum Availability: Equatable, Sendable {
        /// Never returned while `numericRelease` is false.
        case ready(ageImpactYears: Double)
        case calibrating(progress: Double, reasons: [String])
        case unsupported(reason: String, reasons: [String])
    }

    /// Why an input cannot be used (empty = usable for its contributor).
    public static func inputProblems(_ i: Input) -> [String] {
        var out: [String] = []
        if case .derivedEstimate(let what) = i.source {
            out.append("\(i.contributor.label): \(what) is derived from other inputs (e.g. age and resting HR) and would count them twice")
        }
        if i.value == nil { out.append("\(i.contributor.label): no value") }
        if i.coveredDays < i.requiredDays {
            out.append("\(i.contributor.label): \(i.coveredDays) of \(i.requiredDays) days with complete data")
        }
        return out
    }

    /// Current model state for the Health page. Gated: while `numericRelease` is false it returns `.unsupported` with
    /// every reason and never a number, even when `estimate` could compute one.
    public static func evaluate(inputs: [Input], chronologicalAge: Double?) -> Availability {
        var reasons: [String] = []
        for i in inputs { reasons += inputProblems(i) }
        let (est, missing) = estimate(inputs: inputs, chronologicalAge: chronologicalAge)
        reasons += missing
        guard numericRelease else {
            return .unsupported(reason: "The age model is defined but not switched on: NOOP still needs a birth date, measured input windows and the Health page view before it shows a number.",
                                reasons: reasons)
        }
        if let est { return .ready(ageImpactYears: est.totalImpact) }
        let required = Double(Group.allCases.count)
        return .calibrating(progress: (required - Double(missing.count)) / required, reasons: reasons)
    }
}
