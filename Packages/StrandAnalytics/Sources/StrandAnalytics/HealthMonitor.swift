import Foundation

// HealthMonitor.swift — Health page analytics (issue #14): personal-range vital monitoring, the biological-age model
// gate, and a heart-rate activation timeline. Display only; nothing here feeds a score. Method notes and research live
// in docs/HEALTH_MODELS.md. Unit tests here are logic checks, not clinical validation.
//
// Personal range rules:
// - One source per metric (NOOP's own nightly values, or imported WHOOP values). Imported values never enter a NOOP
//   baseline and vice versa.
// - The latest value is the newest day ≤ today with a plausible value. It is stale when older than `staleAfterDays`.
// - The baseline uses only days strictly BEFORE the latest value's day (causal), within `lookbackDays` of it.
// - It needs at least `minBaselineDays` values; else "building baseline".
// - Outliers: values more than 4 scaled MADs from the median are dropped once, then the band is
//   median ± max(2 scaled MADs, the metric's minimum half-width). A scaled MAD is 1.4826 × MAD (≈ SD for normal data).
// - Day keys are local calendar days ("YYYY-MM-DD"), so DST never changes a day's length here.
// - Missing is never zero, normal or healthy; a missing or stale metric never counts toward an all-clear.

public enum HealthMetric: String, CaseIterable, Sendable {
    case respiratoryRate, spo2, restingHR, hrv, skinTemp

    public var title: String {
        switch self {
        case .respiratoryRate: return "Respiratory rate"
        case .spo2: return "Blood oxygen"
        case .restingHR: return "Resting heart rate"
        case .hrv: return "Heart-rate variability"
        case .skinTemp: return "Skin temperature"
        }
    }
    public var unit: String {
        switch self {
        case .respiratoryRate: return "breaths/min"
        case .spo2: return "%"
        case .restingHR: return "bpm"
        case .hrv: return "ms"
        case .skinTemp: return "°C vs baseline"
        }
    }
    public var decimals: Int {
        switch self {
        case .respiratoryRate, .skinTemp: return 1
        default: return 0
        }
    }
    public var symbol: String {
        switch self {
        case .respiratoryRate: return "lungs.fill"
        case .spo2: return "drop.fill"
        case .restingHR: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .skinTemp: return "thermometer.medium"
        }
    }
    /// Plausible stored values; anything else is invalid, not an extreme.
    var plausible: ClosedRange<Double> {
        switch self {
        case .respiratoryRate: return 4...40
        case .spo2: return 70...100
        case .restingHR: return 25...200
        case .hrv: return 1...300
        case .skinTemp: return -5...5
        }
    }
    /// Narrowest half-width a personal range may have, so a very steady history doesn't flag tiny changes.
    var minHalfWidth: Double {
        switch self {
        case .respiratoryRate: return 0.6
        case .spo2: return 1.0
        case .restingHR: return 3
        case .hrv: return 6
        case .skinTemp: return 0.3
        }
    }
    public var explanation: String {
        switch self {
        case .respiratoryRate: return "Breaths per minute averaged during sleep."
        case .spo2: return "Average blood-oxygen saturation measured at the wrist during sleep. Wrist readings are less precise than a fingertip oximeter."
        case .restingHR: return "Lowest sustained heart rate during sleep."
        case .hrv: return "Heart-rate variability (RMSSD) during sleep, from beat-to-beat intervals."
        case .skinTemp: return "Change in skin temperature at the wrist during sleep relative to your baseline. Skin temperature is not core body temperature and is not a fever reading."
        }
    }
}

public struct HealthPoint: Equatable, Sendable {
    public let day: String
    public let value: Double
    public init(day: String, value: Double) { self.day = day; self.value = value }
}

public struct PersonalBaseline: Equatable, Sendable {
    public let median: Double
    public let low: Double
    public let high: Double
    /// Values used after outlier removal, and how many were dropped.
    public let count: Int
    public let outliers: Int
    public let firstDay: String
    public let lastDay: String
    /// Robust SD (1.4826 × MAD) of the kept nights; the range is median ± max(2 × this, the metric's floor).
    public var robustSD: Double = 0
}

public enum HealthMetricStatus: Equatable, Sendable {
    case within, above, below
    case buildingBaseline(have: Int, need: Int)
    case stale(daysOld: Int)
    case noData

    public var isUsable: Bool { self == .within || self == .above || self == .below }
    public var isDeviation: Bool { self == .above || self == .below }
    public var label: String {
        switch self {
        case .within: return "Within your range"
        case .above: return "Above your range"
        case .below: return "Below your range"
        case let .buildingBaseline(have, need): return "Building baseline (\(have) of \(need) nights)"
        case let .stale(d): return "Last reading \(d) days ago"
        case .noData: return "No data"
        }
    }
    public var symbol: String {
        switch self {
        case .within: return "checkmark.circle"
        case .above: return "arrow.up.circle"
        case .below: return "arrow.down.circle"
        case .buildingBaseline: return "hourglass"
        case .stale: return "clock.badge.exclamationmark"
        case .noData: return "minus.circle"
        }
    }
}

public struct HealthMetricReading: Equatable, Sendable {
    public let metric: HealthMetric
    /// "NOOP" or "WHOOP import" — which source the value and the baseline both come from.
    public let source: String
    public let latest: HealthPoint?
    public let baseline: PersonalBaseline?
    public let status: HealthMetricStatus
    /// Every clean point in the source, oldest first (for the detail chart).
    public let history: [HealthPoint]
    /// Where the latest value sits relative to the personal median (nil unless the status is usable).
    public var position: PersonalRangePosition? {
        guard status.isUsable, let v = latest?.value, let b = baseline else { return nil }
        return PersonalRangePosition.assess(v, baseline: b, metric: metric)
    }
}

public struct HealthMonitorSummary: Equatable, Sendable {
    public let readings: [HealthMetricReading]
    public var usable: Int { readings.filter { $0.status.isUsable }.count }
    public var deviations: [HealthMetricReading] { readings.filter { $0.status.isDeviation } }
    public var unavailable: Int { readings.count - usable }
    /// Never an all-clear while any metric is missing, stale or still building.
    public var headline: String {
        if usable == 0 { return "No metrics can be compared with a personal range yet" }
        let dev = deviations.count
        let base = dev == 0 ? "\(usable) of \(readings.count) metrics within your range" : "\(dev) of \(usable) usable metrics outside your range"
        return unavailable > 0 ? "\(base) · \(unavailable) not available" : base
    }
}

public enum HealthMonitor {
    public static let lookbackDays = 30
    public static let minBaselineDays = 14
    public static let staleAfterDays = 2
    static let madScale = 1.4826

    public static func evaluate(_ metric: HealthMetric, points: [HealthPoint], source: String, today: String) -> HealthMetricReading {
        var byDay: [String: Double] = [:]
        for p in points where p.value.isFinite && metric.plausible.contains(p.value) && p.day <= today && HighlightCalendar.date(p.day) != nil {
            byDay[p.day] = p.value
        }
        let history = byDay.map { HealthPoint(day: $0.key, value: $0.value) }.sorted { $0.day < $1.day }
        guard let latest = history.last else {
            return HealthMetricReading(metric: metric, source: source, latest: nil, baseline: nil, status: .noData, history: [])
        }
        let age = daysBetween(latest.day, today) ?? 0
        let from = HighlightCalendar.addDays(latest.day, -lookbackDays) ?? latest.day
        let prior = history.filter { $0.day >= from && $0.day < latest.day }
        let baseline = self.baseline(prior, metric: metric)
        let status: HealthMetricStatus
        if age > staleAfterDays {
            status = .stale(daysOld: age)
        } else if let b = baseline {
            status = latest.value > b.high ? .above : latest.value < b.low ? .below : .within
        } else {
            status = .buildingBaseline(have: prior.count, need: minBaselineDays)
        }
        return HealthMetricReading(metric: metric, source: source, latest: latest, baseline: baseline, status: status, history: history)
    }

    public static func baseline(_ prior: [HealthPoint], metric: HealthMetric) -> PersonalBaseline? {
        guard prior.count >= minBaselineDays else { return nil }
        let v = prior.map(\.value)
        let m0 = median(v), s0 = madScale * median(v.map { abs($0 - m0) })
        let kept = s0 > 0 ? prior.filter { abs($0.value - m0) <= 4 * s0 } : prior
        guard kept.count >= minBaselineDays else { return nil }
        let k = kept.map(\.value)
        let m = median(k), s = madScale * median(k.map { abs($0 - m) })
        let half = max(2 * s, metric.minHalfWidth)
        return PersonalBaseline(median: m, low: m - half, high: m + half, count: kept.count, outliers: prior.count - kept.count,
                                firstDay: kept.first!.day, lastDay: kept.last!.day, robustSD: s)
    }

    /// Prefer NOOP's own values when they are fresh; else imported values when fresher; else whichever has data.
    /// The returned reading's value and baseline come from one source only.
    public static func reading(_ metric: HealthMetric, noop: [HealthPoint], imported: [HealthPoint], today: String) -> HealthMetricReading {
        let n = evaluate(metric, points: noop, source: "NOOP", today: today)
        let w = evaluate(metric, points: imported, source: "WHOOP import", today: today)
        guard let nl = n.latest else { return w.latest == nil ? n : w }
        guard let wl = w.latest else { return n }
        if case .stale = n.status, wl.day > nl.day { return w }
        return n
    }

    public static func summary(noop: [HealthMetric: [HealthPoint]], imported: [HealthMetric: [HealthPoint]], today: String) -> HealthMonitorSummary {
        HealthMonitorSummary(readings: HealthMetric.allCases.map {
            reading($0, noop: noop[$0] ?? [], imported: imported[$0] ?? [], today: today)
        })
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let x = HighlightCalendar.date(a), let y = HighlightCalendar.date(b) else { return nil }
        return Int((y.timeIntervalSince(x) / 86_400).rounded())
    }
}

// MARK: - Biological age

/// The biological-age model gate. No published model NOOP could defend runs on the inputs NOOP has (see
/// docs/HEALTH_MODELS.md), so the estimate is unavailable and says why. A future model registers here with its version,
/// inputs and population limits; until then nothing numerical is shown.
public enum BiologicalAgeModel {
    public static let version: String? = nil

    public enum Availability: Equatable, Sendable {
        case unavailable(reason: String, missingInputs: [String])
    }

    public static func availability(hasAge: Bool, hasSex: Bool) -> Availability {
        var missing = ["validated model for wrist-worn data", "fasting blood biomarkers (e.g. albumin, creatinine, glucose, CRP)",
                       "measured cardiorespiratory fitness (VO₂max test) or waist circumference"]
        if !hasAge { missing.insert("chronological age", at: 0) }
        if !hasSex { missing.insert("sex", at: 0) }
        return .unavailable(reason: "Published biological-age models need blood biomarkers or measured fitness that NOOP doesn't collect, and no wearable-only model has public validation NOOP could reproduce. NOOP won't show a number it can't stand behind.",
                            missingInputs: missing)
    }
}

// MARK: - Heart-rate activation timeline

/// Awake heart rate relative to the wearer's resting heart rate and heart-rate reserve, in fixed bins. This describes
/// physiological activation only: it is not a stress score and says nothing about emotions or mental health. Sleep and
/// recorded workouts get their own categories; bins without enough readings are "no data".
public enum HRActivation {
    public enum Level: String, CaseIterable, Sendable {
        case noData, sleep, exercise, low, moderate, high
        public var label: String {
            switch self {
            case .noData: return "No data"
            case .sleep: return "Asleep"
            case .exercise: return "Workout"
            case .low: return "Low activation"
            case .moderate: return "Moderate activation"
            case .high: return "High activation"
            }
        }
    }

    public struct Bin: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let level: Level
        public let meanHR: Double?
    }

    /// %HRR cut-offs for awake, non-workout bins.
    public static let moderateHRR = 0.20
    public static let highHRR = 0.40
    public static let binSeconds = 15 * 60
    /// A bin needs readings spanning at least this share of it.
    public static let minCoverage = 0.5

    public static func timeline(samples: [(ts: Int, bpm: Int)], from: Int, to: Int, restingHR: Double, maxHR: Double,
                                sleep: [(Int, Int)], workouts: [(Int, Int)], binSeconds: Int = binSeconds) -> [Bin] {
        guard to > from, maxHR > restingHR else { return [] }
        let sorted = samples.filter { $0.ts >= from && $0.ts < to && $0.bpm >= 30 && $0.bpm <= 230 }.sorted { $0.ts < $1.ts }
        var bins: [Bin] = []
        var i = 0
        var start = from
        while start < to {
            let end = min(start + binSeconds, to)
            var sum = 0.0, n = 0, covered = 0, prev: Int?
            while i < sorted.count && sorted[i].ts < end {
                let s = sorted[i]
                sum += Double(s.bpm); n += 1
                if let p = prev { covered += min(s.ts - p, 5) } else { covered += 1 }
                prev = s.ts
                i += 1
            }
            let mid = start + (end - start) / 2
            let overlaps = { (spans: [(Int, Int)]) in spans.contains { $0.0 <= mid && $0.1 > mid } }
            let mean = n > 0 ? sum / Double(n) : nil
            let level: Level
            if overlaps(sleep) { level = .sleep }
            else if overlaps(workouts) { level = .exercise }
            else if Double(covered) < minCoverage * Double(end - start) || mean == nil { level = .noData }
            else {
                let hrr = (mean! - restingHR) / (maxHR - restingHR)
                level = hrr >= highHRR ? .high : hrr >= moderateHRR ? .moderate : .low
            }
            bins.append(Bin(start: start, end: end, level: level, meanHR: mean))
            start = end
        }
        return bins
    }

    /// Seconds per level.
    public static func totals(_ bins: [Bin]) -> [Level: Int] {
        var t: [Level: Int] = [:]
        for b in bins { t[b.level, default: 0] += b.end - b.start }
        return t
    }
}
