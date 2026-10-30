import Foundation

// SleepAccounting.swift — sleep quantities with explicit denominators and explicit missingness.
//
// Definitions (mathematical/accounting conventions; none of them makes a classified epoch correct):
//   TST             union of time in any sleep state (asleep-unstaged included), elapsed seconds
//   24-h sleep      union of sleep across ALL episodes (nights, naps, overlapping imports) clipped to a window,
//                   so overlap is never double counted and a nap across midnight is split by elapsed time
//   efficiency      100 × TST / TIB, ONLY when an in-bed interval comes from a real boundary source; NOOP's
//                   motion-inferred sleep period is not TIB, so `efficiencyTIB` is nil without one
//   SOL             onset − attempt-to-sleep time; nil when no attempt time is known (never 0)
//   WASO            OBSERVED wake between first sleep onset and final awakening; unknown time in that span is
//                   reported beside it (`unknownInSleepPeriodS`), never added to it
//   stage fractions of ALL sleep and of CLASSIFIED sleep are separate fields
//   missingness     with S observed sleep and U unknown, TST ∈ [S, S + U]. These are bounds from missing data,
//                   NOT a confidence interval and no protection against classifier error.
//   wake bouts      maximal runs of observed wake inside the sleep period ≥ `minBoutS`, runs separated by less than
//                   `mergeGapS` of sleep merged. These are NOT EEG arousals.
//   implicit gaps   time inside an episode that no segment covers is UNKNOWN (`normalized`), never observed time,
//                   wake or sleep; overlapping segments are trimmed so no second is counted twice.

public struct TimeSpan: Equatable, Sendable { public let start: Int; public let end: Int
    public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }
    public var duration: Int { max(0, end - start) }
}

public enum SleepAccounting {

    // MARK: - Interval algebra

    /// Union of intervals as sorted, non-overlapping intervals.
    public static func union(_ intervals: [TimeSpan]) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for i in intervals.filter({ $0.end > $0.start }).sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1] = TimeSpan(last.start, max(last.end, i.end))
            } else { out.append(i) }
        }
        return out
    }

    public static func totalSeconds(_ intervals: [TimeSpan], clippedTo window: TimeSpan? = nil) -> Int {
        union(intervals).reduce(0) { acc, i in
            guard let w = window else { return acc + i.duration }
            return acc + max(0, min(i.end, w.end) - max(i.start, w.start))
        }
    }

    /// Intervals of every segment whose state satisfies `keep`.
    public static func intervals(_ segs: [StageSegment], where keep: (SleepState) -> Bool) -> [TimeSpan] {
        segs.filter { keep($0.state) }.map { TimeSpan($0.start, $0.end) }
    }

    /// Segments clipped to `period`, overlaps trimmed (the earlier-starting segment keeps the shared time; ties keep
    /// input order) and every uncovered stretch filled with an explicit `unknown` segment (`SleepStateReason.noSegment`).
    /// The result tiles `period` exactly.
    public static func normalized(_ segs: [StageSegment], period: TimeSpan) -> [StageSegment] {
        let ordered = segs.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        var out: [StageSegment] = []
        var cursor = period.start
        for s in ordered {
            let a = max(s.start, cursor, period.start), b = min(s.end, period.end)
            guard b > a else { continue }
            if a > cursor {
                out.append(StageSegment(start: cursor, end: a, stage: SleepState.unknown.rawValue, reason: SleepStateReason.noSegment))
            }
            out.append(StageSegment(start: a, end: b, stage: s.stage, reason: s.reason))
            cursor = b
        }
        if cursor < period.end {
            out.append(StageSegment(start: cursor, end: period.end, stage: SleepState.unknown.rawValue, reason: SleepStateReason.noSegment))
        }
        return out
    }

    // MARK: - Per-episode summary

    public struct EpisodeSummary: Equatable, Sendable {
        public let periodS: Int                  // episode span (inferred sleep period unless TIB was given)
        public let tstS: Int                     // observed sleep, union
        public let unknownS: Int
        public let observedWakeS: Int
        /// [S, S+U] — missingness bounds for TST, not a confidence interval.
        public let tstBoundsS: ClosedRange<Int>
        public let stagedS: Int
        public let unstagedS: Int
        public let deepS: Int, remS: Int, lightS: Int
        /// Share of sleep that carries a stage estimate (0…1), nil without sleep.
        public let stagedCoverage: Double?
        /// Stage ÷ CLASSIFIED sleep (sums to 1 over light/deep/rem), nil without classified sleep.
        public let classifiedFractions: (light: Double, deep: Double, rem: Double)?
        /// Stage ÷ ALL sleep (sums to stagedCoverage, not 1, when part of sleep is unstaged).
        public let wholeSleepFractions: (light: Double, deep: Double, rem: Double)?
        public let firstOnset: Int?
        public let finalAwakening: Int?
        public let wasoS: Int?                   // observed wake between onset and final awakening
        public let unknownInSleepPeriodS: Int?   // unknown time in that same span (missingness of WASO)
        public let solS: Int?                    // nil unless an attempt time was supplied
        public let efficiencyTIB: Double?        // percent; nil unless an in-bed interval was supplied
        /// Efficiency bounds from missingness over the in-bed interval, percent.
        public let efficiencyTIBBounds: ClosedRange<Double>?
        public let wakeBouts: [TimeSpan]

        public static func == (a: Self, b: Self) -> Bool {
            a.periodS == b.periodS && a.tstS == b.tstS && a.unknownS == b.unknownS && a.wasoS == b.wasoS
                && a.solS == b.solS && a.efficiencyTIB == b.efficiencyTIB && a.wakeBouts == b.wakeBouts
                && a.stagedS == b.stagedS && a.tstBoundsS == b.tstBoundsS
        }
    }

    /// Summarise one episode. `inBed` must come from a real boundary source (a bed sensor, a user log, an import that
    /// states TIB); `attemptTs` from a user "going to sleep" action or equivalent. Without them the corresponding
    /// metrics are nil rather than computed from the inferred period.
    public static func summarize(_ segs: [StageSegment], period: TimeSpan,
                                 inBed: TimeSpan? = nil, attemptTs: Int? = nil,
                                 minBoutS: Int = 60, mergeGapS: Int = 0) -> EpisodeSummary {
        let clip = normalized(segs, period: period)
        func secs(_ keep: (SleepState) -> Bool) -> Int { totalSeconds(intervals(clip, where: keep)) }
        let tst = secs { $0.isSleep }, unknown = secs { !$0.isKnown }, wake = secs { $0 == .wake }
        let deep = secs { $0 == .deep }, rem = secs { $0 == .rem }, light = secs { $0 == .light }
        let unstaged = secs { $0 == .asleep }
        let staged = deep + rem + light

        let sleepSegs = clip.filter { $0.state.isSleep }
        let onset = sleepSegs.first?.start, final = sleepSegs.map(\.end).max()
        var waso: Int? = nil, unkIn: Int? = nil
        var bouts: [TimeSpan] = []
        if let o = onset, let f = final {
            let span = TimeSpan(o, f)
            waso = totalSeconds(intervals(clip, where: { $0 == .wake }), clippedTo: span)
            unkIn = totalSeconds(intervals(clip, where: { !$0.isKnown }), clippedTo: span)
            bouts = wakeBouts(clip, within: span, minBoutS: minBoutS, mergeGapS: mergeGapS)
        }
        var eff: Double? = nil, effB: ClosedRange<Double>? = nil
        if let ib = inBed, ib.duration > 0 {
            let s = totalSeconds(intervals(clip, where: { $0.isSleep }), clippedTo: ib)
            let u = totalSeconds(intervals(clip, where: { !$0.isKnown }), clippedTo: ib)
            eff = 100.0 * Double(s) / Double(ib.duration)
            effB = eff!...(100.0 * Double(s + u) / Double(ib.duration))
        }
        let sol: Int? = {
            guard let a = attemptTs, let o = onset else { return nil }
            return max(0, o - a)
        }()
        func fr(_ x: Int, _ d: Int) -> Double { Double(x) / Double(d) }
        return EpisodeSummary(
            periodS: period.duration, tstS: tst, unknownS: unknown, observedWakeS: wake,
            tstBoundsS: tst...(tst + unknown), stagedS: staged, unstagedS: unstaged,
            deepS: deep, remS: rem, lightS: light,
            stagedCoverage: tst > 0 ? fr(staged, tst) : nil,
            classifiedFractions: staged > 0 ? (fr(light, staged), fr(deep, staged), fr(rem, staged)) : nil,
            wholeSleepFractions: tst > 0 ? (fr(light, tst), fr(deep, tst), fr(rem, tst)) : nil,
            firstOnset: onset, finalAwakening: final, wasoS: waso, unknownInSleepPeriodS: unkIn,
            solS: sol, efficiencyTIB: eff, efficiencyTIBBounds: effB, wakeBouts: bouts)
    }

    /// Observed-wake bouts inside `span`. Unknown time BREAKS a bout (it is not wake) and is never merged across.
    public static func wakeBouts(_ segs: [StageSegment], within span: TimeSpan,
                                 minBoutS: Int, mergeGapS: Int) -> [TimeSpan] {
        let wake = union(intervals(segs, where: { $0 == .wake }).map {
            TimeSpan(max($0.start, span.start), min($0.end, span.end)) })
        let unknown = union(intervals(segs, where: { !$0.isKnown }))
        var merged: [TimeSpan] = []
        for w in wake {
            if let last = merged.last, w.start - last.end < mergeGapS,
               !unknown.contains(where: { $0.start < w.start && $0.end > last.end }) {
                merged[merged.count - 1] = TimeSpan(last.start, w.end)
            } else { merged.append(w) }
        }
        return merged.filter { $0.duration >= minBoutS }
    }

    // MARK: - 24-hour sleep (nights + naps + imports)

    /// Sleep seconds inside `window` from any number of episodes/sources, counted once. Each input is a list of stage
    /// segments; only sleep states count. Episodes that overlap (a WHOOP import and NOOP's own detection of the same
    /// night) are unioned, not added.
    public static func sleepSeconds(_ episodes: [[StageSegment]], window: TimeSpan) -> Int {
        totalSeconds(episodes.flatMap { intervals($0, where: { $0.isSleep }) }, clippedTo: window)
    }

    /// Exactly 24 h of elapsed time ending at `anchorEnd` (the day's final awakening): (anchorEnd − 86 400, anchorEnd].
    public static func window24h(endingAt anchorEnd: Int) -> TimeSpan { TimeSpan(anchorEnd - 86_400, anchorEnd) }

    /// Sleep in the 24 h ending at `anchorEnd`, from ALL episodes (yesterday's afternoon nap included, an episode that
    /// straddles the window start clipped to it, anything older excluded). Overlaps count once.
    public static func sleep24h(_ episodes: [[StageSegment]], endingAt anchorEnd: Int) -> Int {
        sleepSeconds(episodes, window: window24h(endingAt: anchorEnd))
    }

    // MARK: - Sleep Regularity Index (Phillips et al. 2017)

    public struct SRIResult: Equatable, Sendable {
        /// 200 × p_same − 100, in [−100, 100]; never clipped. nil when too few valid pairs.
        public let sri: Double?
        public let validPairs: Int
        public let possiblePairs: Int
        public var validPairFraction: Double { possiblePairs > 0 ? Double(validPairs) / Double(possiblePairs) : 0 }
    }

    /// SRI over a CONTINUOUS epoch grid (`states[i]` covers `[gridStart + i·epochS, +epochS)`), comparing each epoch with
    /// the one exactly 24 h (86 400 s of elapsed time) later. Only pairs where BOTH states are known count; sleep states
    /// collapse to "asleep". The grid must carry observed wake from daytime wear — callers must NOT fill unobserved time
    /// with wake. `minValidPairFraction` is a provisional quality gate.
    public static func sleepRegularityIndex(states: [SleepState], epochS: Int,
                                            minValidPairFraction: Double = 0.5) -> SRIResult {
        guard epochS > 0, 86_400 % epochS == 0 else { return SRIResult(sri: nil, validPairs: 0, possiblePairs: 0) }
        let lag = 86_400 / epochS
        let possible = max(0, states.count - lag)
        var same = 0, valid = 0
        for i in 0..<possible {
            let a = states[i], b = states[i + lag]
            guard a.isKnown, b.isKnown else { continue }
            valid += 1
            if a.isSleep == b.isSleep { same += 1 }
        }
        guard valid > 0, possible > 0, Double(valid) / Double(possible) >= minValidPairFraction else {
            return SRIResult(sri: nil, validPairs: valid, possiblePairs: possible)
        }
        return SRIResult(sri: 200.0 * Double(same) / Double(valid) - 100.0, validPairs: valid, possiblePairs: possible)
    }

    /// Build an SRI grid over `[from, to)`. `covered` = intervals with sensor wear (sleep/wake observable); time covered
    /// and outside every sleep segment is observed WAKE; time inside a segment takes its state; everything else unknown.
    public static func stateGrid(episodes: [[StageSegment]], covered: [TimeSpan],
                                 from: Int, to: Int, epochS: Int) -> [SleepState] {
        let cov = union(covered)
        // Inside an episode, time no segment covers is unknown — not "worn, so awake".
        let segs = episodes.flatMap { ep -> [StageSegment] in
            guard let a = ep.map(\.start).min(), let b = ep.map(\.end).max() else { return [] }
            return normalized(ep, period: TimeSpan(a, b))
        }.sorted { $0.start < $1.start }
        var out: [SleepState] = []
        var t = from
        while t + epochS <= to {
            let mid = t + epochS / 2
            if let s = segs.last(where: { $0.start <= mid && mid < $0.end }) { out.append(s.state.isSleep ? .asleep : s.state) }
            else if cov.contains(where: { $0.start <= mid && mid < $0.end }) { out.append(.wake) }
            else { out.append(.unknown) }
            t += epochS
        }
        return out
    }

    // MARK: - Clock-time timing (circular statistics)

    public struct CircularClock: Equatable, Sendable {
        /// Circular mean local clock time, minutes after midnight in [0, 1440).
        public let meanMinute: Double
        /// Mean resultant length R in [0, 1] (1 = identical times).
        public let resultantLength: Double
        /// Circular SD in minutes: sqrt(−2 ln R) × 1440 / 2π.
        public let circularSDMin: Double
        public let count: Int
    }

    /// Circular mean/dispersion of local clock times (bedtimes, wake times, midpoints). `zone(ts)` gives the zone in
    /// force at each instant (ZoneTimeline), so travel and DST shift the clock, not the arithmetic.
    public static func circularClock(_ timestamps: [Int], zone: (Int) -> TimeZone) -> CircularClock? {
        guard !timestamps.isEmpty else { return nil }
        var sx = 0.0, sy = 0.0
        for ts in timestamps {
            let local = ts + zone(ts).secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
            let minute = Double(((local % 86_400) + 86_400) % 86_400) / 60.0
            let a = minute / 1440.0 * 2 * Double.pi
            sx += cos(a); sy += sin(a)
        }
        let n = Double(timestamps.count)
        let r = min(1.0, (sx * sx + sy * sy).squareRoot() / n)
        var mean = atan2(sy, sx) / (2 * Double.pi) * 1440.0
        if mean < 0 { mean += 1440 }
        if mean >= 1440 - 1e-9 { mean = 0 }
        let sd = r > 0 ? (-2 * Foundation.log(r)).squareRoot() * 1440.0 / (2 * Double.pi) : .infinity
        return CircularClock(meanMinute: mean, resultantLength: r, circularSDMin: sd, count: timestamps.count)
    }

    // MARK: - Duration adequacy vs a declared target

    public struct Shortfall: Equatable, Sendable {
        public let targetMin: Double
        /// Sleep in the 24-h window (min), nil when the day is not observed.
        public let sleepMin: Double?
        /// max(0, target − sleep); nil when sleep is unknown.
        public let shortfallMin: Double?
        /// sleep ≥ target. nil when unknown. Efficiency never enters this.
        public let meetsTarget: Bool?
        /// Share of the 24-h window covered by the data the day was scored from (1 = all of it). Below 1, sleep in the
        /// unread part is not seen, so `sleepMin` is a lower bound there.
        public var observedWindowFraction: Double = 1
    }

    /// Observed shortfall against a TRANSPARENT target the user can see and change. The default 7 h follows the
    /// AASM/SRS adult consensus "at least 7 hours" for healthy adults (Watson 2015); it is population guidance,
    /// not an estimate of this person's need, and is never lowered toward habitual (possibly curtailed) sleep.
    public static let defaultAdultTargetMin = 420.0

    public static func shortfall(sleepMin: Double?, targetMin: Double = defaultAdultTargetMin) -> Shortfall {
        guard let s = sleepMin, s.isFinite, s >= 0 else {
            return Shortfall(targetMin: targetMin, sleepMin: nil, shortfallMin: nil, meetsTarget: nil)
        }
        return Shortfall(targetMin: targetMin, sleepMin: s, shortfallMin: max(0, targetMin - s), meetsTarget: s >= targetMin)
    }

    public struct WindowShortfall: Equatable, Sendable {
        public let days: Int
        public let observedDays: Int
        /// Sum of shortfall over OBSERVED days only; missing days are unknown, not zero.
        public let observedShortfallMin: Double
        public var completeness: Double { days > 0 ? Double(observedDays) / Double(days) : 0 }
    }

    /// Sum shortfalls over a window of daily totals (nil = day not observed). No decay or repayment model is applied:
    /// those rates are hypotheses, not settled constants.
    public static func windowShortfall(_ daily: [Double?], targetMin: Double = defaultAdultTargetMin) -> WindowShortfall {
        let obs = daily.compactMap { $0 }
        return WindowShortfall(days: daily.count, observedDays: obs.count,
                               observedShortfallMin: obs.reduce(0) { $0 + max(0, targetMin - $1) })
    }
}
