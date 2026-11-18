import Foundation

/// NOOP functional age and projected pace of functional aging (#49) — model core and parameter manifest.
///
/// Lane chosen by the owner 2026-11-18: a WEARABLE functional-age estimate in a hazard-equivalent ("effective age")
/// framework, not clinical/lab biological age, not cardiovascular/fitness age, and not WHOOP numerical parity.
///
/// This version is deliberately GATED (`numericRelease == false`): the manifest below holds only MARGINAL associations
/// (each predictor studied mostly on its own), and correlated predictors cannot be summed without a documented joint
/// (dependence) model. Until that exists, `evaluate` never returns a number; it reports what is missing. The arithmetic
/// (risk → years, pace from dated projections, fractional age) is implemented and tested now so the numeric release
/// is a parameter change with its own review, not new math. Method and sources: `docs/HEALTH_MODELS.md`.
public enum FunctionalAge {
    public static let modelVersion = "noop-functional-age-v0-manifest"
    /// No numeric age/pace until joint parameters, input windows and coverage rules are documented and reviewed.
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
        Parameter(contributor: .steps, contrast: "quartile 2 vs quartile 1 of daily steps", hazardRatio: 0.60, ci95: 0.51...0.71,
                  outcome: "all-cause mortality", population: "15 cohorts, device-measured steps",
                  citation: "Paluch AE et al. Lancet Public Health 2022;7(3):e219–e228", doi: "10.1016/S2468-2667(21)00302-9",
                  status: .verifiedMarginal, caveat: "Quartile step ranges not yet confirmed from the full text; plateau differs by age."),
        Parameter(contributor: .steps, contrast: "quartile 3 vs quartile 1 of daily steps", hazardRatio: 0.55, ci95: 0.49...0.62,
                  outcome: "all-cause mortality", population: "15 cohorts, device-measured steps",
                  citation: "Paluch AE et al. Lancet Public Health 2022;7(3):e219–e228", doi: "10.1016/S2468-2667(21)00302-9",
                  status: .verifiedMarginal, caveat: "Quartile step ranges not yet confirmed from the full text."),
        Parameter(contributor: .steps, contrast: "quartile 4 vs quartile 1 of daily steps", hazardRatio: 0.47, ci95: nil,
                  outcome: "all-cause mortality", population: "15 cohorts, device-measured steps",
                  citation: "Paluch AE et al. Lancet Public Health 2022;7(3):e219–e228", doi: "10.1016/S2468-2667(21)00302-9",
                  status: .verifiedMarginal, caveat: "Confidence interval not confirmed; quartile ranges not confirmed."),
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

    /// Current model state for the Health page. Gated: returns `.unsupported` with every reason (unverified
    /// parameters, missing joint model, unusable inputs) and never a number while `numericRelease` is false.
    public static func evaluate(inputs: [Input], chronologicalAge: Double?) -> Availability {
        var reasons: [String] = []
        if chronologicalAge == nil { reasons.append("Chronological age (birth date or age in Profile)") }
        let unverified = Set(manifest.filter { $0.status == .needsVerification }.map(\.contributor))
        for c in Contributor.allCases where unverified.contains(c) {
            reasons.append("\(c.label): published effect size not yet verified")
        }
        for i in inputs { reasons += inputProblems(i) }
        guard numericRelease else {
            return .unsupported(reason: "The joint model that combines correlated contributors (sleep, activity, resting HR, fitness) is not established yet, so NOOP does not add their separate risks together. No number is shown until it is.",
                                reasons: reasons)
        }
        let usable = inputs.filter { inputProblems($0).isEmpty }
        let progress = inputs.isEmpty ? 0 : Double(usable.count) / Double(inputs.count)
        return .calibrating(progress: progress, reasons: reasons)
    }
}
