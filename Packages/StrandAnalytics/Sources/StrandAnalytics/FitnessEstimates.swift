import Foundation
import WhoopStore

// FitnessEstimates.swift — issue #16: a VO₂max estimate and NOOP's own sleep performance. Both are versioned estimates
// with explicit inputs; a missing input gives an unavailable result with the reason, never a zero or a guess.
// Methods, limits and what is NOT validated: docs/HEALTH_MODELS.md.

// MARK: - VO₂max (heart-rate ratio)

/// VO₂max ≈ 15.3 × HRmax / HRrest mL/kg/min (Uth, Sørensen, Overgaard & Pedersen 2004, Eur J Appl Physiol 91:111–115;
/// derived in well-trained men aged 21–51). It needs only a maximal and a resting heart rate, which is all NOOP has —
/// no pace, power, GPS or lab test. Known limits, all shown in the UI: individual error is large in later validations;
/// an age-predicted HRmax adds its own error (an entered measured max is preferred); NOOP's resting HR is sleep-derived,
/// typically lower than the seated/supine resting HR of the original study, which pushes the estimate up.
public enum VO2MaxEstimate {
    public static let version = "vo2-hr-ratio-v1"
    public static let factor = 15.3
    /// Resting HR is the median of NOOP's own recent nights: at least `minNights` within `lookbackNights`.
    public static let lookbackNights = 7
    public static let minNights = 5
    /// The newest night used must be at most this many days before `today`.
    public static let maxAgeDays = 3

    public enum MaxHRSource: String, Sendable { case entered, agePredicted }

    public struct Estimate: Equatable, Sendable {
        public let vo2: Double            // mL/kg/min
        public let restingHR: Double
        public let maxHR: Double
        public let maxHRSource: MaxHRSource
        public let nights: Int
        public let firstDay: String
        public let lastDay: String
        public let version: String
    }

    public enum Result: Equatable, Sendable {
        case estimate(Estimate)
        case unavailable(reason: String, missingInputs: [String])
    }

    /// Tanaka, Monahan & Seals 2001: HRmax ≈ 208 − 0.7 × age.
    public static func predictedMaxHR(age: Int) -> Double { 208 - 0.7 * Double(age) }

    /// - Parameters:
    ///   - restingHR: NOOP's own nightly resting HR by day (imported values are a different measurement; not used).
    ///   - age / enteredMaxHR: from the profile. A measured max wins over the age prediction.
    public static func estimate(restingHR: [HealthPoint], age: Int?, enteredMaxHR: Int?, today: String) -> Result {
        var missing: [String] = []
        let maxHR: Double, source: MaxHRSource
        if let m = enteredMaxHR, (120...230).contains(m) { maxHR = Double(m); source = .entered }
        else if let a = age, (13...100).contains(a) { maxHR = predictedMaxHR(age: a); source = .agePredicted }
        else { maxHR = 0; source = .agePredicted; missing.append("Age or a measured maximum heart rate (Profile)") }

        let from = HighlightCalendar.addDays(today, -lookbackNights) ?? today
        let recent = restingHR.filter { $0.day > from && $0.day <= today && (25...120).contains($0.value) }.sorted { $0.day < $1.day }
        if recent.count < minNights {
            missing.append("Resting heart rate from \(minNights) of the last \(lookbackNights) nights (have \(recent.count))")
        } else if let last = recent.last, (HealthMonitor.daysBetween(last.day, today) ?? 99) > maxAgeDays {
            missing.append("A resting heart rate from the last \(maxAgeDays) nights")
        }
        guard missing.isEmpty else {
            return .unavailable(reason: "Needs " + missing.joined(separator: " and ").lowercased(), missingInputs: missing)
        }
        let rest = HealthMonitor.median(recent.map(\.value))
        guard maxHR > rest else { return .unavailable(reason: "Maximum heart rate is not above resting heart rate", missingInputs: []) }
        return .estimate(Estimate(vo2: factor * maxHR / rest, restingHR: rest, maxHR: maxHR, maxHRSource: source,
                                  nights: recent.count, firstDay: recent.first!.day, lastDay: recent.last!.day, version: version))
    }
}

// MARK: - NOOP sleep performance

/// NOOP's sleep performance: hours asleep as a share of the night's estimated sleep need, capped at 100 %.
///   need = max(7.5 h, mean minutes asleep over up to `needNights` EARLIER NOOP nights)   (`SleepNeed`'s fallback)
///   performance = 100 × min(1, asleep / need)
/// Only NOOP's own rows feed it (never imported WHOOP need or performance). It is the "hours vs need" component that
/// WHOOP describes; WHOOP's score also weighs consistency, efficiency and an unexported sleep-stress term
/// (docs/WHOOP_REVERSE_ENGINEERING.md), so the two are labelled differently and are not expected to match.
public enum SleepPerformance {
    public static let version = "noop-sleep-perf-v1"
    public static let needNights = 14

    public struct Night: Equatable, Sendable {
        public let day: String
        public let performance: Double
        public let asleepMin: Double
        public let needMin: Double
    }

    /// Causal: each night's need uses only nights before it. Days without minutes asleep produce no value.
    public static func nights(_ rows: [DailyMetric]) -> [Night] {
        let sorted = rows.filter { ($0.totalSleepMin ?? 0) > 0 }.sorted { $0.day < $1.day }
        var out: [Night] = []
        for (i, r) in sorted.enumerated() {
            let prior = sorted[max(0, i - needNights)..<i].compactMap(\.totalSleepMin)
            guard let s = SleepNeed.summarize(officialNeed: nil, officialDebt: nil, asleep: r.totalSleepMin, recentAsleep: prior) else { continue }
            out.append(Night(day: r.day, performance: 100 * min(1, s.asleepMin / s.needMin), asleepMin: s.asleepMin, needMin: s.needMin))
        }
        return out
    }

    public static func series(_ rows: [DailyMetric]) -> [(day: String, value: Double)] {
        nights(rows).map { (day: $0.day, value: $0.performance) }
    }

    /// Agreement statistics over paired values (NOOP − reference). Nothing is fitted, so every pair is out-of-sample.
    public struct Agreement: Equatable, Sendable {
        public let n: Int
        /// Mean |NOOP − ref|, median |NOOP − ref| and mean (NOOP − ref), in the compared units.
        public let mae: Double
        public let medianAE: Double
        public let bias: Double

        /// nil when there is nothing to compare.
        public static func of(_ pairs: [(noop: Double, reference: Double)]) -> Agreement? {
            guard !pairs.isEmpty else { return nil }
            let diffs = pairs.map { $0.noop - $0.reference }
            let abs = diffs.map { Swift.abs($0) }.sorted()
            let mid = abs.count / 2
            let median = abs.count % 2 == 1 ? abs[mid] : (abs[mid - 1] + abs[mid]) / 2
            return Agreement(n: pairs.count, mae: abs.reduce(0, +) / Double(abs.count), medianAE: median,
                             bias: diffs.reduce(0, +) / Double(diffs.count))
        }
    }
}

// MARK: - Pairing NOOP nights with imported WHOOP sleeps (issue #16 validation)

/// Pairs NOOP nights with imported WHOOP main sleeps **by sleep interval**, never by date string: the importer keys a
/// cycle's values by its cycle-start date and NOOP by final-wake date, and the two need not fall on the same day.
///
/// A NOOP night (its main sleep's first onset → final wake) matches the imported sleep it overlaps with IoU ≥ `minIoU`.
/// No candidate, several candidates, or an imported sleep claimed by two NOOP nights → excluded with a reason. The WHOOP
/// values come only from the cycle that **declares** that sleep (export Sleep/Wake onset, stored by the importer as
/// `sleep_onset_ts`/`wake_onset_ts`, equal within `linkToleranceS`). Cycle start time is never used to guess the link: in
/// exports it can sit at the sleep's onset or at its wake (the bundled fixture: onset 23:15, cycle start 06:30).
public enum SleepPairing {
    public struct Interval: Equatable, Sendable {
        public let start: Int, end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public func iou(_ o: Interval) -> Double {
            let inter = max(0, min(end, o.end) - max(start, o.start))
            let union = max(end, o.end) - min(start, o.start)
            return union > 0 ? Double(inter) / Double(union) : 0
        }
    }
    /// One imported cycle: its start, the sleep it declares (nil when the export gave none) and the exported fields
    /// (sleep_performance, sleep_total_min, sleep_need_min, …).
    public struct Cycle: Equatable, Sendable {
        public let start: Int
        public let declaredSleep: Interval?
        public let values: [String: Double]
        public init(start: Int, declaredSleep: Interval?, values: [String: Double]) {
            self.start = start; self.declaredSleep = declaredSleep; self.values = values
        }
    }
    public struct Pair: Equatable, Sendable {
        public let night: SleepPerformance.Night
        public let noopSleep: Interval
        public let whoopSleep: Interval
        public let cycleStart: Int
        public let iou: Double
        /// Night's need was built from fewer than `SleepPerformance.needNights` earlier NOOP nights.
        public let warmUp: Bool
        public let whoop: [String: Double]
    }
    public struct Result: Equatable, Sendable {
        public var pairs: [Pair] = []
        /// Excluded NOOP nights by reason ("no NOOP main sleep", "no overlapping WHOOP sleep", "ambiguous", …).
        public var excluded: [String: Int] = [:]
    }

    public static let minIoU = 0.5
    /// Declared sleep ↔ imported sleep record: same onset and wake (export timestamps are minute-resolution).
    public static let linkToleranceS = 60

    /// `noopSleep`: NOOP main sleep per wake day. `priorNights`: earlier valid NOOP nights per night (warm-up flag).
    public static func pair(nights: [SleepPerformance.Night], noopSleep: [String: Interval],
                            whoopSleeps: [Interval], cycles: [Cycle]) -> Result {
        var result = Result()
        var candidates: [(index: Int, night: SleepPerformance.Night, sleep: Interval, match: Interval, iou: Double)] = []
        for (i, n) in nights.enumerated() {
            guard let mine = noopSleep[n.day] else { result.excluded["no NOOP main sleep", default: 0] += 1; continue }
            let hits = whoopSleeps.map { ($0, mine.iou($0)) }.filter { $0.1 >= minIoU }
            guard !hits.isEmpty else { result.excluded["no overlapping WHOOP sleep", default: 0] += 1; continue }
            guard hits.count == 1 else { result.excluded["ambiguous (several WHOOP sleeps)", default: 0] += 1; continue }
            candidates.append((i, n, mine, hits[0].0, hits[0].1))
        }
        let claims = Dictionary(grouping: candidates, by: { "\($0.match.start)-\($0.match.end)" })
        for c in candidates {
            guard claims["\(c.match.start)-\(c.match.end)"]?.count == 1 else {
                result.excluded["WHOOP sleep matched by two NOOP nights", default: 0] += 1; continue
            }
            let linked = cycles.filter { c2 in
                guard let d = c2.declaredSleep else { return false }
                return Swift.abs(d.start - c.match.start) <= linkToleranceS && Swift.abs(d.end - c.match.end) <= linkToleranceS
            }
            guard !linked.isEmpty else { result.excluded["no WHOOP cycle declares that sleep", default: 0] += 1; continue }
            guard linked.count == 1, let cycle = linked.first else { result.excluded["several WHOOP cycles declare that sleep", default: 0] += 1; continue }
            result.pairs.append(Pair(night: c.night, noopSleep: c.sleep, whoopSleep: c.match, cycleStart: cycle.start,
                                     iou: c.iou, warmUp: c.index < SleepPerformance.needNights, whoop: cycle.values))
        }
        return result
    }

    /// Everything `pair` needs, read from a store: NOOP nights and main sleeps (`computedId`), imported main sleeps and
    /// cycles with their declared sleeps (`rawId`). Shared by `perf_probe --sleepperf` and the importer regression test.
    public struct Inputs: Sendable {
        public let nights: [SleepPerformance.Night]
        public let noopSleep: [String: Interval]
        public let whoopSleeps: [Interval]
        public let cycles: [Cycle]
    }

    public static let cycleKeys = ["cycle_start_ts", "sleep_onset_ts", "wake_onset_ts", "sleep_performance", "sleep_total_min",
                                   "sleep_need_min", "hours_vs_needed_pct"]

    public static func load(store: WhoopStore, rawId: String, computedId: String) async throws -> Inputs {
        let nights = SleepPerformance.nights(try await store.dailyMetrics(deviceId: computedId, from: "0", to: "9"))
        let mains = try await store.sleepSessions(deviceId: computedId, from: 0, to: Int.max, limit: 100_000).filter(\.isMainSleep)
        var noopSleep: [String: Interval] = [:]
        for (_, eps) in Dictionary(grouping: mains, by: { $0.sessionId ?? "\($0.startTs)" }) {
            let start = eps.map(\.startTs).min()!, end = eps.map(\.endTs).max()!
            let day = AnalyticsEngine.dayString(end)
            if let old = noopSleep[day], old.end - old.start >= end - start { continue }   // longest main sleep per wake day
            noopSleep[day] = Interval(start: start, end: end)
        }
        let whoopSleeps = try await store.sleepSessions(deviceId: rawId, from: 0, to: Int.max, limit: 100_000)
            .map { Interval(start: $0.startTs, end: $0.endTs) }
        var byDay: [String: [String: Double]] = [:]
        for k in cycleKeys {
            for p in try await store.metricSeries(deviceId: rawId, key: k, from: "0", to: "9") { byDay[p.day, default: [:]][k] = p.value }
        }
        let cycles = byDay.values.compactMap { v -> Cycle? in
            guard let start = v["cycle_start_ts"] else { return nil }
            let declared = v["sleep_onset_ts"].flatMap { on in v["wake_onset_ts"].map { Interval(start: Int(on), end: Int($0)) } }
            return Cycle(start: Int(start), declaredSleep: declared, values: v)
        }
        return Inputs(nights: nights, noopSleep: noopSleep, whoopSleeps: whoopSleeps, cycles: cycles)
    }

    public static func pair(_ i: Inputs) -> Result {
        pair(nights: i.nights, noopSleep: i.noopSleep, whoopSleeps: i.whoopSleeps, cycles: i.cycles)
    }

    /// The four comparisons the issue asks for, each over all pairs and over stable-history (non-warm-up) pairs.
    public struct Report: Equatable, Sendable {
        public struct Row: Equatable, Sendable {
            public let label: String
            public let all: SleepPerformance.Agreement?
            public let stable: SleepPerformance.Agreement?
            /// Pairs dropped because the WHOOP field was missing.
            public let missing: Int
        }
        public let rows: [Row]
    }

    public static func report(_ pairs: [Pair]) -> Report {
        typealias Pick = (Pair) -> (Double, Double)?
        func row(_ label: String, _ pick: Pick) -> Report.Row {
            let all = pairs.compactMap { p in pick(p).map { (p, $0) } }
            func agree(_ xs: [(Pair, (Double, Double))]) -> SleepPerformance.Agreement? {
                .of(xs.map { (noop: $0.1.0, reference: $0.1.1) })
            }
            return .init(label: label, all: agree(all), stable: agree(all.filter { !$0.0.warmUp }),
                         missing: pairs.count - all.count)
        }
        return Report(rows: [
            row("performance vs WHOOP sleep performance (%)") { p in p.whoop["sleep_performance"].map { (p.night.performance, $0) } },
            // Like NOOP's own score: 100 × min(1, asleep / need), from WHOOP's exported asleep and need.
            row("performance vs WHOOP 100·min(1, asleep/need) (%, capped)") { p in
                guard let a = p.whoop["sleep_total_min"], let n = p.whoop["sleep_need_min"], n > 0 else { return nil }
                return (p.night.performance, 100 * min(1, a / n))
            },
            // The importer's hours_vs_needed_pct is NOT capped at 100; shown separately so cap differences are visible.
            row("performance vs WHOOP hours_vs_needed_pct (%, uncapped)") { p in p.whoop["hours_vs_needed_pct"].map { (p.night.performance, $0) } },
            row("asleep vs WHOOP asleep (min)") { p in p.whoop["sleep_total_min"].map { (p.night.asleepMin, $0) } },
            row("need vs WHOOP need (min)") { p in p.whoop["sleep_need_min"].map { (p.night.needMin, $0) } },
        ])
    }
}

// MARK: - Latest activation (Overview)

public extension HRActivation {
    /// The newest bin with a known state (awake level, asleep or workout), ignoring no-data bins.
    static func latest(_ bins: [Bin]) -> Bin? { bins.last { $0.level != .noData } }

    /// Share (0…1) of the bins' time that has readings, sleep or a workout.
    static func coverage(_ bins: [Bin]) -> Double {
        let total = bins.reduce(0) { $0 + $1.end - $1.start }
        guard total > 0 else { return 0 }
        return 1 - Double(totals(bins)[.noData] ?? 0) / Double(total)
    }
}
