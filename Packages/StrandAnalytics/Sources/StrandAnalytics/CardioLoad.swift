import Foundation
import WhoopProtocol
import WhoopStore

// CardioLoad.swift — named load methods over supported HR intervals, and the records stored with each result.
//
// Separate things stay separate: this file measures cardiovascular load from heart rate. That is not muscular strain,
// calories, tissue damage or recovery time, and a low value during lifting does not mean an easy session. Detecting an
// episode (WorkoutDetector), logging effort or strength work (TrainingLog) and predicting recovery are different tasks
// with their own evidence (see docs/WORKOUT_STRAIN_RESEARCH_2026-10-30.md).
//
// Daily load means accumulated AWAKE-TIME load: it is integrated over the day's unique supported seconds outside
// confidently identified sleep (naps included) and only then attributed to sessions, so splitting or merging episodes
// cannot change it. Sessions never add load, and the 0–21 index is applied once, to the summed load. Being awake is not
// exercising: awake seconds score by their zone weight, Zone 0 weighs nothing, and no baseline is added. Sleep is cut
// out of load only; full-day HR, its statistics and total-day calories still include it.

/// Every method NOOP names. A method is a definition, not a score: each carries its own unit and inputs.
public enum LoadMethod: String, CaseIterable, Codable, Sendable {
    case fittedZoneLoad, edwards, edwardsHRR, banisterIntegrated, banisterSessionMean
    case sessionRPE, strengthVolume, mechanicalWork, powerTSS

    public struct Descriptor: Equatable, Sendable {
        public let name: String
        public let unit: String
        /// True when values may be summed across intervals, so the result does not depend on how time is split.
        public let additive: Bool
        /// Inputs NOOP does not collect yet, if any. Such a method stays unavailable rather than being approximated.
        public let missingInput: String?
        public let reference: String
    }

    public var descriptor: Descriptor {
        switch self {
        case .fittedZoneLoad:
            return Descriptor(name: "Fitted zone load", unit: "AU", additive: true, missingInput: nil,
                              reference: "Weights fitted to one person's WHOOP export (docs/WHOOP_REVERSE_ENGINEERING.md); compatibility fit, not validation")
        case .edwards:
            return Descriptor(name: "Edwards zone load (%HRmax)", unit: "AU", additive: true, missingInput: nil,
                              reference: "https://pmc.ncbi.nlm.nih.gov/articles/PMC7240108/")
        case .edwardsHRR:
            return Descriptor(name: "Edwards-style zone load on %HRR (variant)", unit: "AU", additive: true, missingInput: nil,
                              reference: "NOOP variant of Edwards with Karvonen %HRR bands; not the published zones")
        case .banisterIntegrated:
            return Descriptor(name: "Banister-style TRIMP, time-integrated", unit: "AU", additive: true,
                              missingInput: "explicit coefficient choice", reference: "https://pmc.ncbi.nlm.nih.gov/articles/PMC10944953/")
        case .banisterSessionMean:
            return Descriptor(name: "Banister TRIMP, session mean", unit: "AU", additive: false,
                              missingInput: "explicit coefficient choice", reference: "https://pmc.ncbi.nlm.nih.gov/articles/PMC10944953/")
        case .sessionRPE:
            return Descriptor(name: "Session RPE load", unit: "AU", additive: true, missingInput: "user-reported RPE",
                              reference: "https://pubmed.ncbi.nlm.nih.gov/11708692/")
        case .strengthVolume:
            return Descriptor(name: "External volume load", unit: "kg", additive: true, missingInput: "exercise log",
                              reference: "https://pmc.ncbi.nlm.nih.gov/articles/PMC7706636/")
        case .mechanicalWork:
            return Descriptor(name: "Mechanical work", unit: "kJ", additive: true, missingInput: "measured power",
                              reference: "sum(watts × seconds) / 1000")
        case .powerTSS:
            return Descriptor(name: "Power-based TSS", unit: "AU", additive: false, missingInput: "measured power and FTP",
                              reference: "https://www.trainingpeaks.com/learn/articles/estimating-training-stress-score-tss/")
        }
    }
}

/// Banister coefficients, always chosen explicitly. They are population conventions from the historical male and female
/// formulations, not individualized curves, so NOOP never infers them from a profile's gender.
public struct BanisterCoefficients: Equatable, Codable, Sendable {
    public let a: Double
    public let b: Double
    public init(a: Double, b: Double) { self.a = a; self.b = b }
    public static let historicalMaleFormulation = BanisterCoefficients(a: 0.64, b: 1.92)
    public static let historicalFemaleFormulation = BanisterCoefficients(a: 0.86, b: 1.67)
}

/// What one span of time contains: elapsed, observed and zone time, plus the additive zone loads.
public struct LoadSummary: Codable, Equatable, Sendable {
    public let requestedS: Int
    public let observedS: Int
    /// Parts of `observedS`: direct readings, and bounded holds across dropouts (estimated).
    public let measuredS: Int
    public let heldS: Int
    /// Time-weighted mean over supported seconds.
    public let meanHR: Double?
    public let peakHR: Int?
    /// Seconds below Zone 1, then in Zones 1…5 of the %HRmax system `HRZones` defines.
    public let zoneSeconds: [Int]
    /// Seconds above the configured HRmax. Scored in Zone 5, reported rather than silently raising HRmax mid-session.
    public let aboveMaxS: Int
    /// Fitted zone load, AU.
    public let zoneLoad: Double
    /// Edwards zone load, AU: weights 1…5 on the %HRmax bands, zero below 50 %.
    public let edwardsLoad: Double

    public var unknownS: Int { max(0, requestedS - observedS) }
    public var coverage: Double { requestedS > 0 ? Double(observedS) / Double(requestedS) : 0 }

    public init(_ support: SupportedHR, requestedS: Int, hrMax: Double) {
        let zones = HRZones.zones(maxHR: hrMax)
        var zoneS = [Int](repeating: 0, count: 6)
        var measured = 0, held = 0, above = 0, peak: Int?
        var weighted = 0.0
        for x in support.intervals {
            let dt = x.seconds
            if x.support == .measured { measured += dt } else { held += dt }
            zoneS[zones.zoneNumber(forBPM: Double(x.bpm))] += dt
            if Double(x.bpm) > hrMax { above += dt }
            peak = max(peak ?? x.bpm, x.bpm)
            weighted += Double(x.bpm) * Double(dt)
        }
        let observed = measured + held
        self.requestedS = requestedS; observedS = observed; measuredS = measured; heldS = held
        meanHR = observed > 0 ? weighted / Double(observed) : nil
        peakHR = peak; zoneSeconds = zoneS; aboveMaxS = above
        zoneLoad = (1...5).reduce(0.0) { $0 + StrainScorer.whoopZoneWeights[$1 - 1] * Double(zoneS[$1]) / 60 }
        edwardsLoad = (1...5).reduce(0.0) { $0 + Double($1) * Double(zoneS[$1]) / 60 }
    }

    /// Share of observed time per zone (0…5) in percent, 1 dp. Empty when nothing was observed.
    public var zonePercent: [Int: Double] {
        guard observedS > 0 else { return [:] }
        var out: [Int: Double] = [:]
        for (z, s) in zoneSeconds.enumerated() { out[z] = (Double(s) / Double(observedS) * 1000).rounded() / 10 }
        return out
    }
}

public enum CardioLoad {

    /// Below this much supported time a window gets no score (10 min, the former 600-row rule stated as time).
    public static let minObservedS = 600
    /// Below this share of the day, the day is reported as partial. An engineering choice.
    public static let completeDayCoverage = 0.9

    /// Versions stored with every result. Bump the one whose definition changed.
    public static let loadVersion = "cardio-load-awake-2026.10"
    public static let detectorVersion = "episode-detector-2026.11-trim"

    /// Mean %HRR over supported seconds, clamped per interval to [0, 100]. Nil when reserve is unknown or invalid.
    public static func meanPercentHRR(_ support: SupportedHR, calibration: HRCalibration) -> Double? {
        guard let reserve = calibration.hrReserve, let rest = calibration.restingHR else { return nil }
        let seconds = support.observedSeconds
        guard seconds > 0 else { return nil }
        let total = support.intervals.reduce(0.0) { acc, x in
            acc + min(100, max(0, (Double(x.bpm) - rest) / reserve * 100)) * Double(x.seconds)
        }
        return total / Double(seconds)
    }

    /// Edwards-style weights on %HRR bands: the variant formerly mislabelled "Edwards". AU, or nil without a valid reserve.
    public static func edwardsHRRVariant(_ support: SupportedHR, calibration: HRCalibration) -> Double? {
        guard let reserve = calibration.hrReserve, let rest = calibration.restingHR else { return nil }
        let weightedSeconds = support.intervals.reduce(0) { acc, x in
            let pct = (Double(x.bpm) - rest) / reserve * 100
            let weight = pct >= 90 ? 5 : pct >= 80 ? 4 : pct >= 70 ? 3 : pct >= 60 ? 2 : pct >= 50 ? 1 : 0
            return acc + weight * x.seconds
        }
        return Double(weightedSeconds) / 60
    }

    /// `x` clipped to [0, 1]: HR at or below rest adds nothing, HR above HRmax scores as HRmax (see `aboveMaxS`).
    private static func reserveFraction(_ bpm: Double, rest: Double, reserve: Double) -> Double {
        min(1, max(0, (bpm - rest) / reserve))
    }

    /// Time-integrated TRIMP: sum(dt_minutes · x · a · exp(b · x)). Additive across intervals.
    public static func banisterIntegrated(_ support: SupportedHR, calibration: HRCalibration,
                                          coefficients c: BanisterCoefficients) -> Double? {
        guard let reserve = calibration.hrReserve, let rest = calibration.restingHR else { return nil }
        return support.intervals.reduce(0.0) { acc, i in
            let x = reserveFraction(Double(i.bpm), rest: rest, reserve: reserve)
            return acc + Double(i.seconds) / 60 * x * c.a * exp(c.b * x)
        }
    }

    /// Conventional session-mean TRIMP: T · x̄ · a · exp(b · x̄). The exponential of a mean is not the mean of the
    /// exponential, so this is not additive: sessions must not be summed into a daily load with it.
    public static func banisterSessionMean(_ support: SupportedHR, calibration: HRCalibration,
                                           coefficients c: BanisterCoefficients) -> Double? {
        guard let reserve = calibration.hrReserve, let rest = calibration.restingHR else { return nil }
        let seconds = support.observedSeconds
        guard seconds > 0 else { return nil }
        let meanHR = support.intervals.reduce(0.0) { $0 + Double($1.bpm) * Double($1.seconds) } / Double(seconds)
        let x = reserveFraction(meanHR, rest: rest, reserve: reserve)
        return Double(seconds) / 60 * x * c.a * exp(c.b * x)
    }
}

/// One rule for when two NOOP-detected rows are the same event. Overlap alone proves nothing: a row is dropped only when
/// nearly all of the shorter one lies inside the other. Distinct overlapping rows both stay, and since load comes from
/// unique intervals rather than from rows, keeping both can't double-count anything.
public enum WorkoutReconciliation {
    /// Share of the shorter row that must overlap for the two to be one event.
    public static let sameEventOverlap = 0.8

    public static func reconcile(_ rows: [WorkoutRow]) -> [WorkoutRow] {
        var kept: [WorkoutRow] = []
        for w in rows.sorted(by: { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }) {
            let i = kept.lastIndex { k in
                let overlap = min(k.endTs, w.endTs) - max(k.startTs, w.startTs)
                let shorter = min(k.endTs - k.startTs, w.endTs - w.startTs)
                return overlap > 0 && Double(overlap) >= sameEventOverlap * Double(shorter)
            }
            if let i {
                if w.endTs - w.startTs > kept[i].endTs - kept[i].startTs { kept[i] = w }
            } else { kept.append(w) }
        }
        return kept
    }
}

// MARK: - Stored records

public enum DayLoadStatus: String, Codable, Sendable {
    case complete                // enough of the day observed
    case partial                 // scored on what was observed; the rest of the day is unknown, not low
    case insufficient            // too little supported time to score
    case calibrationUnavailable  // no usable HRmax
}

/// Why a value is missing or qualified. Stored as strings so a later build can still read them.
public enum LoadReason {
    public static let noHeartRate = "no_heart_rate"
    public static let insufficientObservedTime = "insufficient_observed_time"
    public static let hrMaxUnavailable = "hrmax_unavailable"
    public static let partialDay = "partial_day"
    public static let hrAboveConfiguredMax = "hr_above_configured_max"
    public static let hrMaxIsEstimate = "hrmax_population_estimate"
    public static let noSleepClassified = "no_sleep_classified"
    public static let sleepProvisional = "sleep_provisional"
    public static let sleepStateUnknown = "sleep_state_unknown"
    public static let dayEndUnclassified = "day_end_unclassified"
    /// Reasons that say the sleep/wake split itself is unsure.
    public static let sleepUncertainty = [noSleepClassified, sleepProvisional, sleepStateUnknown, dayEndUnclassified]
}

/// Which seconds of a day are confidently sleep, from the canonical stages (`SleepState.isSleep`), and what stays unsure.
/// Only identified sleep is removed. Everything else stays in, because a missing sleep record does not prove someone was
/// awake and no boundary is invented to settle it: the doubt is reported, and the result is provisional.
public struct AwakeWindow: Equatable, Sendable {
    /// Unknown-state time inside sleep periods below this is ordinary epoch noise, not a reason to doubt a day.
    static let minUncertainS = 300

    /// Confident sleep, union clipped to the day.
    public let sleep: [TimeSpan]
    /// Sleep periods whose state was not observed. Not excluded, since they aren't known to be sleep.
    public let uncertain: [TimeSpan]
    public let reasons: [String]

    public init(sleep: [TimeSpan] = [], uncertain: [TimeSpan] = [], reasons: [String] = []) {
        self.sleep = sleep; self.uncertain = uncertain; self.reasons = reasons
    }

    /// - Parameter laterDataChecked: data after the day was available, so sleep starting before midnight could be seen.
    public static func classify(_ sessions: [SleepSession], span: TimeSpan, laterDataChecked: Bool,
                                lastObservedTs: Int?) -> AwakeWindow {
        let overlapping = sessions.filter { $0.start < span.end && span.start < $0.end }
        func clipped(_ spans: [TimeSpan]) -> [TimeSpan] {
            SleepAccounting.union(spans.map { TimeSpan(max($0.start, span.start), min($0.end, span.end)) })
        }
        let tiles = overlapping.flatMap { SleepAccounting.normalized($0.stages, period: TimeSpan($0.start, $0.end)) }
        let sleep = clipped(tiles.filter { $0.state.isSleep }.map { TimeSpan($0.start, $0.end) })
        let unknown = clipped(tiles.filter { !$0.state.isKnown }.map { TimeSpan($0.start, $0.end) })
        // Overlapping sessions can disagree: a second that is sleep in one is not uncertain because of the other.
        let uncertain = unknown.flatMap { u -> [TimeSpan] in
            var from = u.start, out: [TimeSpan] = []
            for s in sleep where s.end > from && s.start < u.end {
                if s.start > from { out.append(TimeSpan(from, s.start)) }
                from = max(from, s.end)
            }
            if u.end > from { out.append(TimeSpan(from, u.end)) }
            return out
        }
        var reasons: [String] = []
        if lastObservedTs != nil {
            if overlapping.isEmpty { reasons.append(LoadReason.noSleepClassified) }
            if overlapping.contains(where: \.isProvisional) { reasons.append(LoadReason.sleepProvisional) }
            if SleepAccounting.totalSeconds(uncertain) >= minUncertainS { reasons.append(LoadReason.sleepStateUnknown) }
            if !laterDataChecked, let last = lastObservedTs, last >= span.end - SleepStager.provisionalWindowMin * 60 {
                reasons.append(LoadReason.dayEndUnclassified)
            }
        }
        return AwakeWindow(sleep: sleep, uncertain: uncertain, reasons: reasons)
    }
}

/// A day's cardiovascular load and everything needed to reproduce or question it.
public struct DayLoadRecord: Codable, Equatable, Sendable {
    public let day: String
    public let rangeStart: Int
    public let rangeEnd: Int
    public let status: DayLoadStatus
    public let reasons: [String]
    public let calibration: HRCalibration
    /// Awake-time accounting behind both the index and the displayed zones: requested time is the day minus confident
    /// sleep. Nil only when HRmax is unavailable, since zones need it.
    public let summary: LoadSummary?
    /// True when coverage or sleep classification may still change this result; `reasons` says why.
    public let provisional: Bool
    /// Seconds of the day removed as confident sleep, and the HR seconds and load they held. The load is reported to
    /// show what the exclusion changed; it is not part of any score.
    public let sleepExcludedS: Int
    public let sleepHRS: Int
    public let sleepExcludedLoad: Double?
    /// Awake HR seconds inside sleep periods of unknown state: counted, but not known to be awake.
    public let uncertainStateS: Int
    /// All supported seconds of the day, sleep included.
    public let dayObservedS: Int
    /// Parts of `summary.zoneLoad`: inside known or detected sessions, and everything else. They sum to the day's load.
    public let exerciseLoad: Double?
    public let incidentalLoad: Double?
    /// Display index, or nil with `reasons` saying why. Missing is never zero.
    public let strainIndex: Double?
    public let observedFirstTs: Int?
    public let observedLastTs: Int?
    public let quality: HRQuality.Report
    public let inputStream: String
    public let supportPolicy: String
    public let loadVersion: String
    public let indexVersion: String
    public let detectorVersion: String

    static func compute(day: String, span: TimeSpan, support dayHR: SupportedHR, awake window: AwakeWindow = AwakeWindow(),
                        sessions: [TimeSpan], calibration: HRCalibration, quality: HRQuality.Report) -> DayLoadRecord {
        var reasons: [String] = []
        let support = dayHR.clipped(to: span, excluding: window.sleep)
        let sleepS = SleepAccounting.totalSeconds(window.sleep)
        let summary = calibration.hrMax.map { LoadSummary(support, requestedS: span.duration - sleepS, hrMax: $0) }
        let status: DayLoadStatus
        if summary == nil {
            status = .calibrationUnavailable
            reasons.append(LoadReason.hrMaxUnavailable)
        } else if support.observedSeconds < CardioLoad.minObservedS {
            status = .insufficient
            reasons.append(dayHR.intervals.isEmpty ? LoadReason.noHeartRate : LoadReason.insufficientObservedTime)
        } else if summary!.coverage < CardioLoad.completeDayCoverage {
            status = .partial
            reasons.append(LoadReason.partialDay)
        } else {
            status = .complete
        }
        if calibration.hrMaxIsEstimate { reasons.append(LoadReason.hrMaxIsEstimate) }
        if (summary?.aboveMaxS ?? 0) > 0 { reasons.append(LoadReason.hrAboveConfiguredMax) }
        reasons += window.reasons

        var exercise: Double?, incidental: Double?
        if let summary, let hrMax = calibration.hrMax {
            let inSessions = SleepAccounting.union(sessions).reduce(0.0) { acc, s in
                acc + LoadSummary(support.clipped(to: s), requestedS: s.duration, hrMax: hrMax).zoneLoad
            }
            exercise = inSessions
            incidental = max(0, summary.zoneLoad - inSessions)
        }
        let scored = status == .complete || status == .partial
        let sleepLoad = summary.flatMap { s in
            calibration.hrMax.map { max(0, LoadSummary(dayHR, requestedS: span.duration, hrMax: $0).zoneLoad - s.zoneLoad) }
        }
        return DayLoadRecord(day: day, rangeStart: span.start, rangeEnd: span.end, status: status, reasons: reasons,
                             calibration: calibration, summary: summary,
                             provisional: status == .partial || !window.reasons.isEmpty, sleepExcludedS: sleepS,
                             sleepHRS: dayHR.observedSeconds - support.observedSeconds, sleepExcludedLoad: sleepLoad,
                             uncertainStateS: window.uncertain.reduce(0) { $0 + support.observedSeconds(in: $1) },
                             dayObservedS: dayHR.observedSeconds, exerciseLoad: exercise, incidentalLoad: incidental,
                             strainIndex: scored ? summary.flatMap { StrainScorer.dayIndex(load: $0.zoneLoad) } : nil,
                             observedFirstTs: support.intervals.first?.start, observedLastTs: support.intervals.last?.end,
                             quality: quality, inputStream: "hrSample", supportPolicy: SupportedHR.policyVersion,
                             loadVersion: CardioLoad.loadVersion, indexVersion: StrainScorer.indexVersion,
                             detectorVersion: CardioLoad.detectorVersion)
    }
}

/// Sorted keys: the same record always stores the same bytes, so cached and fresh rows can be compared directly.
private let stableEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return e
}()

extension DayLoadRecord {
    /// As stored; nil only if encoding fails, which leaves the day without a frozen snapshot rather than a bad one.
    public var row: LoadRecordRow? {
        guard let data = try? stableEncoder.encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        return LoadRecordRow(day: day, scope: LoadRecordRow.dayScope, startTs: 0, algorithmVersion: loadVersion, payload: json)
    }

    /// Decoded from storage. Nil for another scope or a shape this build can't read: never treated as compatible.
    public init?(row: LoadRecordRow) {
        guard row.scope == LoadRecordRow.dayScope, let data = row.payload.data(using: .utf8),
              let r = try? JSONDecoder().decode(DayLoadRecord.self, from: data) else { return nil }
        self = r
    }
}

extension SessionLoadRecord {
    public func row(day: String) -> LoadRecordRow? {
        guard let data = try? stableEncoder.encode(self), let json = String(data: data, encoding: .utf8) else { return nil }
        return LoadRecordRow(day: day, scope: LoadRecordRow.sessionScope, startTs: start, algorithmVersion: loadVersion, payload: json)
    }

    public init?(row: LoadRecordRow) {
        guard row.scope == LoadRecordRow.sessionScope, let data = row.payload.data(using: .utf8),
              let r = try? JSONDecoder().decode(SessionLoadRecord.self, from: data) else { return nil }
        self = r
    }
}

/// The accounting behind one detected session.
public struct SessionLoadRecord: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let activeS: Int
    public let pausedS: Int
    public let unknownS: Int
    public let summary: LoadSummary
    public let evidence: ActivityEvidence
    public let movingFraction: Double?
    public let calibration: HRCalibration
    public let loadVersion: String
    public let detectorVersion: String
}
