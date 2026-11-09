import Foundation

// CheckIns.swift — the check-in prompt library and cautious Yes-vs-No comparisons against later outcomes (issue #12).
// Check-in answers never feed recovery, sleep, strain or smart-wake scoring; this file only describes associations.
//
// Outcome windows (recorded for issue #12):
// - Morning prompts ask about the previous evening / last night, on local date D. Their outcome is the night that ended
//   on the morning of D: that day's daily row D (sleep totals, disturbances, recovery, HRV, RHR, respiratory rate).
// - Evening prompts ask about today, on local date D. Their outcome is the following night and the next morning's
//   recovery: daily row D+1 for sleep/recovery measures. Training-load prompts also compare day strain on D itself.
//
// Comparison method:
// - Only "yes" and "no" answers count. "Not sure", skipped and unanswered are excluded, never treated as "no".
// - A day is paired only when the outcome measure exists for it (missing sensor data is not a negative answer).
// - A finding needs at least `minPerGroup` paired days in each group (default 5). Otherwise: not enough data.
// - The result is the difference in group means, with counts and the date range. When that difference is small relative
//   to the pooled spread (|d| < 0.2 SD, a conventional "negligible" effect size) or the groups overlap heavily, it is
//   reported as "no clear difference". Nothing is called a cause, and nothing is ranked good or bad.

public enum CheckInSession: String, CaseIterable, Codable, Sendable {
    case morning, evening
    public var title: String { self == .morning ? "Morning check-in" : "Evening check-in" }
    public var about: String { self == .morning ? "About last night or the previous evening" : "About today" }
}

public enum CheckInAnswer: String, CaseIterable, Codable, Sendable {
    case yes, no, notSure, skipped, unanswered
    public var label: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .notSure: return "Not sure"
        case .skipped: return "Skipped"
        case .unanswered: return "Unanswered"
        }
    }
}

public enum CheckInMeasure: String, CaseIterable, Sendable {
    case sleepDuration, disturbances, recovery, hrv, restingHR, respiratoryRate, dayStrain

    public var title: String {
        switch self {
        case .sleepDuration: return "Sleep duration"
        case .disturbances: return "Sleep disturbances"
        case .recovery: return "Recovery"
        case .hrv: return "HRV"
        case .restingHR: return "Resting heart rate"
        case .respiratoryRate: return "Respiratory rate"
        case .dayStrain: return "Day strain"
        }
    }
    public var unit: String {
        switch self {
        case .sleepDuration: return "min"
        case .disturbances: return ""
        case .recovery: return "%"
        case .hrv: return "ms"
        case .restingHR: return "bpm"
        case .respiratoryRate: return "breaths/min"
        case .dayStrain: return ""
        }
    }
    public var decimals: Int { self == .respiratoryRate || self == .dayStrain ? 1 : 0 }
}

/// One stable prompt. `id` never changes; a wording change that alters the meaning bumps `version`.
public struct CheckInPrompt: Identifiable, Equatable, Sendable {
    public let id: String
    public let version: Int
    public let session: CheckInSession
    public let text: String
    public let topic: String
    /// Measures this prompt is compared against (outcome window per the session rule above).
    public let measures: [CheckInMeasure]
}

public enum CheckInLibrary {
    private static let sleepMeasures: [CheckInMeasure] = [.sleepDuration, .disturbances, .recovery, .hrv, .restingHR, .respiratoryRate]

    /// First library, from the prompt list on issue #12.
    public static let prompts: [CheckInPrompt] = [
        // Morning: about last night or the previous evening.
        .init(id: "alcohol_before_bed", version: 1, session: .morning, text: "Did you have any alcohol before bed?",
              topic: "Alcohol and sleep disruption", measures: sleepMeasures),
        .init(id: "caffeine", version: 1, session: .morning, text: "Did you have caffeine?",
              topic: "Caffeine timing", measures: sleepMeasures),
        .init(id: "late_large_meal", version: 1, session: .morning, text: "Did you eat a large meal within 2 hours of bed?",
              topic: "Late eating", measures: sleepMeasures),
        .init(id: "screen_before_sleep", version: 1, session: .morning, text: "Did you use a screen in the 30 minutes before trying to sleep?",
              topic: "Bedtime routine", measures: sleepMeasures),
        .init(id: "sleep_environment", version: 1, session: .morning, text: "Did noise, light, or room temperature disturb your sleep?",
              topic: "Sleep environment", measures: sleepMeasures),
        .init(id: "unfamiliar_or_unusual_sleep", version: 1, session: .morning, text: "Did you sleep somewhere unfamiliar or at an unusual time?",
              topic: "Travel and schedule disruption", measures: sleepMeasures),
        .init(id: "sick_last_night", version: 1, session: .morning, text: "Did you feel sick or have symptoms last night?",
              topic: "Illness", measures: sleepMeasures),
        .init(id: "sleep_aid_supplement", version: 1, session: .morning, text: "Did you take a sleep aid or a new supplement before bed?",
              topic: "Sleep-related substances", measures: sleepMeasures),
        // Evening: about today.
        .init(id: "hard_workout", version: 1, session: .evening, text: "Did you do a harder-than-usual workout today?",
              topic: "Training load", measures: [.dayStrain] + sleepMeasures),
        .init(id: "strenuous_work", version: 1, session: .evening, text: "Did you do unusually strenuous physical work outside a workout?",
              topic: "Non-training exertion", measures: [.dayStrain] + sleepMeasures),
        .init(id: "late_exercise", version: 1, session: .evening, text: "Did you exercise within 3 hours of bed?",
              topic: "Late exercise", measures: sleepMeasures),
        .init(id: "long_nap", version: 1, session: .evening, text: "Did you nap for more than 30 minutes today?",
              topic: "Sleep timing and pressure", measures: sleepMeasures),
        .init(id: "low_water", version: 1, session: .evening, text: "Did you drink less water than usual today?",
              topic: "Hydration", measures: sleepMeasures),
        .init(id: "low_food", version: 1, session: .evening, text: "Did you skip a meal or eat much less than usual?",
              topic: "Food intake", measures: sleepMeasures),
        .init(id: "stressful_event", version: 1, session: .evening, text: "Did you have a notably stressful event today?",
              topic: "Acute stress", measures: sleepMeasures),
        .init(id: "sick_today", version: 1, session: .evening, text: "Did you feel sick or unusually run-down today?",
              topic: "Illness or fatigue", measures: sleepMeasures),
        .init(id: "recovery_activity", version: 1, session: .evening, text: "Did you do a deliberate recovery activity, such as stretching or breathwork?",
              topic: "Recovery routine", measures: sleepMeasures),
    ]

    public static func prompts(for session: CheckInSession) -> [CheckInPrompt] { prompts.filter { $0.session == session } }
    public static func prompt(_ id: String) -> CheckInPrompt? { prompts.first { $0.id == id } }

    /// Default selection: a short set so the check-in stays around 30 seconds.
    public static let defaultMorning = ["alcohol_before_bed", "caffeine", "screen_before_sleep", "sleep_environment"]
    public static let defaultEvening = ["hard_workout", "late_exercise", "stressful_event", "recovery_activity"]
}

/// One answered prompt on one local date (from storage).
public struct CheckInObservation: Equatable, Sendable {
    public let localDate: String
    public let session: CheckInSession
    public let promptId: String
    public let promptVersion: Int
    public let answer: CheckInAnswer
    public init(localDate: String, session: CheckInSession, promptId: String, promptVersion: Int, answer: CheckInAnswer) {
        self.localDate = localDate; self.session = session; self.promptId = promptId
        self.promptVersion = promptVersion; self.answer = answer
    }
}

/// Outcome values for one day (one source). nil = not measured, never zero.
public struct CheckInOutcomeDay: Equatable, Sendable {
    public let day: String
    public var values: [CheckInMeasure: Double]
    public init(day: String, values: [CheckInMeasure: Double]) { self.day = day; self.values = values }
}

public struct CheckInComparison: Equatable, Sendable {
    public enum Verdict: String, Equatable, Sendable { case notEnoughData, noClearDifference, higherOnYes, lowerOnYes }
    public let promptId: String
    public let measure: CheckInMeasure
    public let yesCount: Int
    public let noCount: Int
    public let yesMean: Double?
    public let noMean: Double?
    public let firstDay: String?
    public let lastDay: String?
    public let verdict: Verdict
    /// yes − no, when both groups qualify.
    public var difference: Double? {
        guard verdict != .notEnoughData, let y = yesMean, let n = noMean else { return nil }
        return y - n
    }

    /// Cautious, association-only sentence.
    public func sentence(topic: String) -> String {
        let m = measure.title.lowercased()
        switch verdict {
        case .notEnoughData:
            return "Not enough data yet: \(yesCount) Yes and \(noCount) No days with \(m) (needs \(CheckInInsights.minPerGroup) of each)."
        case .noClearDifference:
            return "No clear difference in \(m) between days you answered Yes and No."
        case .higherOnYes, .lowerOnYes:
            let d = abs(difference ?? 0)
            let amount = measure.decimals == 0 ? "\(Int(d.rounded()))" : String(format: "%.1f", d)
            let unit = measure.unit.isEmpty ? "" : " \(measure.unit)"
            return "\(measure.title) was typically \(amount)\(unit) \(verdict == .higherOnYes ? "higher" : "lower") after days you answered Yes. This is an association in your data, not proof of cause."
        }
    }
}

public enum CheckInInsights {
    public static let minPerGroup = 5
    /// Below this standardized difference the groups are called "no clear difference".
    public static let negligibleEffect = 0.2

    /// The outcome day an answer is compared with, per the window rule at the top of this file.
    public static func outcomeDay(for o: CheckInObservation, measure: CheckInMeasure) -> String? {
        if o.session == .morning || measure == .dayStrain { return o.localDate }
        return HighlightCalendar.addDays(o.localDate, 1)
    }

    /// Compare outcomes on Yes vs No days for one prompt and measure. Duplicate answers for one date keep the last.
    public static func compare(promptId: String, measure: CheckInMeasure, observations: [CheckInObservation],
                               outcomes: [String: CheckInOutcomeDay], minPerGroup: Int = minPerGroup) -> CheckInComparison {
        var latest: [String: CheckInObservation] = [:]
        for o in observations where o.promptId == promptId { latest[o.localDate] = o }
        var yes: [Double] = [], no: [Double] = [], dates: [String] = []
        for o in latest.values.sorted(by: { $0.localDate < $1.localDate }) {
            guard o.answer == .yes || o.answer == .no,
                  let day = outcomeDay(for: o, measure: measure),
                  let v = outcomes[day]?.values[measure], v.isFinite else { continue }
            if o.answer == .yes { yes.append(v) } else { no.append(v) }
            dates.append(o.localDate)
        }
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        let ym = mean(yes), nm = mean(no)
        let verdict: CheckInComparison.Verdict
        if yes.count < minPerGroup || no.count < minPerGroup {
            verdict = .notEnoughData
        } else {
            let pooled = pooledSD(yes, no)
            let d = ym! - nm!
            if pooled <= 0 ? d == 0 : abs(d) / pooled < negligibleEffect {
                verdict = .noClearDifference
            } else {
                verdict = d > 0 ? .higherOnYes : .lowerOnYes
            }
        }
        return CheckInComparison(promptId: promptId, measure: measure, yesCount: yes.count, noCount: no.count,
                                 yesMean: ym, noMean: nm, firstDay: dates.first, lastDay: dates.last, verdict: verdict)
    }

    static func pooledSD(_ a: [Double], _ b: [Double]) -> Double {
        func ss(_ x: [Double]) -> Double {
            let m = x.reduce(0, +) / Double(x.count)
            return x.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        }
        let df = Double(a.count + b.count - 2)
        guard df > 0 else { return 0 }
        return ((ss(a) + ss(b)) / df).squareRoot()
    }

    /// Every measure for every prompt that has any answers.
    public static func all(observations: [CheckInObservation], outcomes: [String: CheckInOutcomeDay]) -> [CheckInComparison] {
        let ids = Set(observations.map(\.promptId))
        return CheckInLibrary.prompts.filter { ids.contains($0.id) }.flatMap { p in
            p.measures.map { compare(promptId: p.id, measure: $0, observations: observations, outcomes: outcomes) }
        }
    }
}
