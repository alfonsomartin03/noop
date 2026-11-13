import Foundation
import WhoopProtocol
@preconcurrency import WhoopStore

// AnalyticsEngine.swift — orchestrator producing DailyMetric + sleep-session results.
//
// Mirrors the role of server/ingest/app/analysis/daily.py + sleep.daily_sleep_summary:
// given a day's raw streams + a user profile + personal baselines, it runs the
// individual analyzers and assembles a `DailyMetric` (WhoopStore shape) plus the
// detected `SleepSession`s (and their `CachedSleepSession` cache shapes).
//
// This is a PURE function over its inputs — it does NOT touch the database
// (persistence is wired elsewhere). All derived values are APPROXIMATE.

public enum AnalyticsEngine {

    /// Personal references passed in by the caller. They must be built from nights STRICTLY BEFORE the day being
    /// analysed and from the same metric identity (see `CausalBaselines.legacyProfile`); this function cannot check that.
    public struct ProfileBaselines: Sendable {
        /// Legacy EWMA states for the legacy recovery model.
        public let hrv: BaselineState?
        public let restingHR: BaselineState?
        public let resp: BaselineState?
        /// Robust causal references for the autonomic component (ln RMSSD; resting HR in bpm).
        public let lnRMSSDReference: ReferenceSnapshot?
        public let restingHRReference: ReferenceSnapshot?
        /// Declared 24-h sleep target (minutes) for sleep sufficiency.
        public let sleepTargetMin: Double
        public init(hrv: BaselineState? = nil, restingHR: BaselineState? = nil,
                    resp: BaselineState? = nil, lnRMSSDReference: ReferenceSnapshot? = nil,
                    restingHRReference: ReferenceSnapshot? = nil,
                    sleepTargetMin: Double = SleepAccounting.defaultAdultTargetMin) {
            self.hrv = hrv; self.restingHR = restingHR; self.resp = resp
            self.lnRMSSDReference = lnRMSSDReference; self.restingHRReference = restingHRReference
            self.sleepTargetMin = sleepTargetMin
        }
    }

    /// The full analysis result for one day.
    ///
    /// NOTE: not `Sendable` — it embeds `DailyMetric` / `CachedSleepSession` from
    /// WhoopStore, which are not `Sendable` (and that package is out of scope to
    /// modify here). The individual analyzer result types in this package ARE
    /// `Sendable`.
    public struct DayResult {
        /// DailyMetric in the WhoopStore cache shape (recovery/strain/sleep rolled up).
        public let daily: DailyMetric
        /// Detected sleep sessions (rich, with stage segments).
        public let sleepSessions: [SleepSession]
        /// True while a night's final wake is not yet trustworthy; its times and recovery may still change.
        public var sleepProvisional: Bool { sleepSessions.contains { $0.isProvisional } }
        /// CachedSleepSession cache rows (one per detected session).
        public let cachedSleep: [CachedSleepSession]
        /// Detected workout/exercise sessions.
        public let workouts: [ExerciseSession]
        /// Recovery score [0,100] or nil (cold-start / no HRV baseline).
        public let recovery: Double?
        /// Day strain index [0,21], or nil with the reason in `load`. Measured over observed time only.
        public let strain: Double?
        /// The separate recovery dimensions (legacy score, sleep sufficiency, autonomic deviation, unusual values).
        public let assessment: RecoveryAssessment?
        /// Naps attributed to this day (not in the night totals; counted in 24-h sleep).
        public let napSessions: [SleepSession]
        /// The day's load with its coverage, calibration and reasons. Nil only with no day range and no HR at all.
        public let load: DayLoadRecord?
        /// Every sleep session ending on this day with its label (primary / nap / uncertain), episodes and gaps kept.
        public var classifiedSleep: [ClassifiedSleepSession] = []

        public init(daily: DailyMetric, sleepSessions: [SleepSession],
                    cachedSleep: [CachedSleepSession], workouts: [ExerciseSession],
                    recovery: Double?, strain: Double?, assessment: RecoveryAssessment? = nil,
                    napSessions: [SleepSession] = [], load: DayLoadRecord? = nil) {
            self.daily = daily; self.sleepSessions = sleepSessions
            self.cachedSleep = cachedSleep; self.workouts = workouts
            self.recovery = recovery; self.strain = strain
            self.assessment = assessment; self.napSessions = napSessions; self.load = load
        }
    }

    /// Streams from just after the day, used ONLY to see sleep that began before midnight, which the day's own data cannot
    /// show. It never reaches sleep totals, recovery or detection. Nil for a day still in progress.
    public struct FollowingData: Sendable {
        public let hr: [HRSample]
        public let rr: [RRInterval]
        public let resp: [RespSample]
        public let gravity: [GravitySample]
        public init(hr: [HRSample], rr: [RRInterval] = [], resp: [RespSample] = [], gravity: [GravitySample]) {
            self.hr = hr; self.rr = rr; self.resp = resp; self.gravity = gravity
        }
    }

    /// How much of the day's evening is re-read with `FollowingData`: enough to contain a night's start.
    static let eveningContextS = 12 * 3600
    /// How far past the day to read for `FollowingData`.
    public static let followingWindowS = 12 * 3600

    /// Minimum asleep time (seconds) in the day's sleep sessions before a recovery score is produced.
    static let minRecoverySleepS = 3.0 * 3600.0

    /// Format a unix-seconds timestamp as a YYYY-MM-DD day string on the wearer's clock, in the time zone that was
    /// in force at that instant (see `ZoneTimeline`), so a night slept abroad keeps its own day.
    public static func dayString(_ ts: Int) -> String { ZoneTimeline.shared.dayString(ts) }

    /// JSON-encode stage segments to the verbatim array shape CachedSleepSession stores.
    static func encodeStages(_ stages: [StageSegment]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys   // the same night always stores the same bytes
        guard let data = try? encoder.encode(stages) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Analyze one day's streams into a `DayResult`.
    ///
    /// - Parameters:
    ///   - day: the calendar day (UTC) this metric is for; a sleep session is
    ///     attributed to the day its `end` falls on (a night ending that morning).
    ///   - hr/rr/resp/gravity: the day's raw streams (the wider window around the
    ///     night may be passed; sleep detection finds the in-bed span itself).
    ///   - dayRange: the day's own [from, to) in unix seconds. Sleep needs the wider window around the night, but
    ///     workouts and strain must only see this day's data, not the previous evening's.
    ///   - profile: user profile (age/sex/weight/height) for HRmax + calories.
    ///   - baselines: personal baselines for recovery normalization.
    ///   - maxHROverride: declared HRmax (bpm); nil → labelled Tanaka estimate from profile.age.
    ///   - calibration: frozen snapshot of an earlier scoring of this day. It replaces every other HR reference, so a
    ///     past day keeps its values; nil resolves one for this run.
    ///   - knownSessions: imported or logged sessions. They only attribute load, they can't change the day's total.
    ///   - following: data after the day; see `FollowingData`. A result without it may be provisional at its end.
    ///   - observedUntil: the scoring clock ("now"). The load's requested time stops here, so the rest of an unfinished
    ///     day is neither recorded nor missing. nil = the whole day has passed.
    // Order matters: sleep first (gives resting HR + HRV), then recovery (needs those), then workouts and strain.
    public static func analyzeDay(day: String,
                                  hr rawHR: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
                                  gravity: [GravitySample] = [],
                                  profile: UserProfile,
                                  baselines: ProfileBaselines = ProfileBaselines(),
                                  maxHROverride: Double? = nil,
                                  dayRange: (from: Int, to: Int)? = nil,
                                  calibration frozen: HRCalibration? = nil,
                                  knownSessions: [TimeSpan] = [],
                                  following: FollowingData? = nil,
                                  observedUntil: Int? = nil,
                                  sleepHabit: SleepHabit = .fallback,
                                  sleepCorrections: [SleepCorrection] = []) -> DayResult {

        // Validated HR for every downstream score: de-duplicated, in range, isolated optical spikes removed.
        let (hr, hrQuality) = HRQuality.cleanWithReport(rawHR)

        // ── Sleep detection + staging ─────────────────────────────────────────
        let allSessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                    sleepHRHint: (baselines.restingHR?.usable == true ? baselines.restingHR?.baseline : nil))
        // Layers C/D: group episodes into sessions and label them with context (habit, corrections). Exactly one
        // primary session per wake day; its episodes — and only those — feed recovery, HRV, resting HR and the
        // night's totals. Naps add to 24-h sleep; uncertain sessions count nowhere until the user confirms them.
        let classified = SleepSessionClassifier.classify(allSessions, habit: sleepHabit, corrections: sleepCorrections,
                                                         wakeDay: { dayString($0) })
        let dayClassified = classified.filter { dayString($0.end) == day }
        let primary = dayClassified.first { $0.isPrimary }
        let matched = primary?.episodes ?? []
        let napSessions = dayClassified.filter { $0.kind == .nap }.flatMap(\.episodes)
        let countedEpisodes = classified.filter { $0.kind != .uncertain }.flatMap(\.episodes)

        // ── Daily sleep aggregates (AASM, in-bed weighted) ────────────────────
        var deepS = 0.0, remS = 0.0, lightS = 0.0, tstS = 0.0
        var inBedS = 0.0, effWeighted = 0.0
        var disturbances = 0
        for s in matched {
            let m = SleepStager.hypnogramMetrics(s)
            let inBed = Double(s.end - s.start)
            inBedS += inBed
            effWeighted += s.efficiency * inBed
            deepS += m.deepMin * 60.0
            remS += m.remMin * 60.0
            lightS += m.lightMin * 60.0
            tstS += m.tstS
            disturbances += m.disturbances
        }
        // Efficiency is weighted by time in bed so a short nap doesn't drag down a full night.
        let efficiency = inBedS > 0 ? effWeighted / inBedS : 0.0

        // Daily resting HR = lowest per-session resting HR across matched sessions.
        let restingHRDaily = matched.compactMap { $0.restingHR }.min()
        // Daily avg HRV = in-bed-weighted mean of per-session avg HRV.
        // Same in-bed weighting for HRV across multiple sleep sessions.
        let avgHRVDaily: Double? = {
            let pairs = matched.compactMap { s -> (Double, Double)? in
                s.avgHRV.map { ($0, Double(s.end - s.start)) }
            }
            guard !pairs.isEmpty else { return nil }
            let total = pairs.reduce(0.0) { $0 + $1.0 * $1.1 }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? total / weight : nil
        }()

        // Daily respiration = in-bed-weighted mean of per-session breaths/min inferred from R-R.
        let respDaily: Double? = {
            let pairs = matched.compactMap { s -> (Double, Double)? in
                s.avgResp.map { ($0, Double(s.end - s.start)) }
            }
            let weight = pairs.reduce(0.0) { $0 + $1.1 }
            return weight > 0 ? pairs.reduce(0.0) { $0 + $1.0 * $1.1 } / weight : nil
        }()

        let sleepStart = matched.map { $0.start }.min()
        let sleepEnd = matched.map { $0.end }.max()

        // ── Recovery ──────────────────────────────────────────────────────────
        // Legacy score needs a real night (≥ 3 h asleep), HRV, resting HR and a usable HRV baseline; otherwise nil.
        // A provisional night (recording ends right after the wake) still scores so recovery shows on waking; every
        // sync recomputes the whole day, so it is revised if the wearer goes back to sleep (see DayResult.sleepProvisional).
        // 24-h sleep = sleep in exactly the 24 h of elapsed time ending at this day's final awakening (its main sleep,
        // else its last nap), from EVERY detected session (yesterday afternoon's nap included), overlaps counted once.
        // The part of that window before the data read for this day is unobserved and reported as such.
        let anchor = matched.map(\.end).max() ?? napSessions.map(\.end).max()
        let sleep24hMin: Double? = anchor.map { Double(SleepAccounting.sleep24h(countedEpisodes.map(\.stages), endingAt: $0)) / 60.0 }
        let dataStart = [rawHR.map(\.ts).min(), gravity.map(\.ts).min()].compactMap { $0 }.min()
        let observedFraction: Double = {
            guard let a = anchor, let d = dataStart else { return 1 }
            return Double(a - max(d, a - 86_400)) / 86_400
        }()
        // Quality of the night's vitals: the longest night's (where the daily HRV mostly comes from).
        let quality = matched.max(by: { $0.end - $0.start < $1.end - $1.start })?.vitalsQuality
        let assessment = RecoveryAssessor.assess(
            sleep24hMin: sleep24hMin, mainSleepS: tstS, efficiency: matched.isEmpty ? nil : efficiency,
            hrv: avgHRVDaily, restingHR: restingHRDaily, quality: quality, baselines: baselines,
            minMainSleepS: minRecoverySleepS, observedWindowFraction: observedFraction)
        let recovery = assessment.legacy.score

        // ── Calibration: one snapshot for detection, load and zones ───────────
        // Day resting HR from sleep is the best reference; the causal reference covers a day with no night.
        let calibration = frozen ?? HRCalibration.resolve(
            day: day, declaredMax: maxHROverride, age: profile.age,
            sleepResting: restingHRDaily.map(Double.init),
            causalResting: baselines.restingHR?.usable == true ? baselines.restingHR?.baseline : nil)

        // ── Workouts ──────────────────────────────────────────────────────────
        // Supported intervals of the whole buffer, clipped exactly to this day, so a hold crossing midnight is split.
        let span: TimeSpan? = dayRange.map { TimeSpan($0.from, $0.to) }
            ?? hr.first.flatMap { f in hr.last.map { TimeSpan(f.ts, $0.ts + SupportedHR.nominalS) } }
        let daySupport = span.map { SupportedHR(cleaned: hr).clipped(to: $0) } ?? SupportedHR(cleaned: [])
        let hrDay = dayRange.map { r in hr.filter { $0.ts >= r.from && $0.ts < r.to } } ?? hr
        let gravityDay = dayRange.map { r in gravity.filter { $0.ts >= r.from && $0.ts < r.to } } ?? gravity

        // ── Awake time: the day minus confidently identified sleep, naps included ──
        // Sessions ending after this day are found by a separate pass, so `allSessions`, which feeds sleep and recovery,
        // is untouched. Without later data, sleep starting late in the day stays unseen and the result says so.
        // A low-evidence span (still, but no heart rate to confirm sleep) is not confident sleep: its time stays in the
        // day's load unless the wearer confirmed it.
        let confident = { (e: SleepSession) in
            !e.lowEvidence || SleepSessionClassifier.userConfirmsSleep(sleepCorrections, start: e.start, end: e.end)
        }
        var sleepEpisodes = allSessions.filter(confident)
        var laterChecked = false
        if let f = following, let r = dayRange, let lastLater = f.gravity.map(\.ts).max(),
           lastLater - r.to >= SleepStager.provisionalWindowMin * 60 {
            let from = r.to - eveningContextS
            let later = SleepStager.detectSleep(hr: hr.filter { $0.ts >= from } + HRQuality.clean(f.hr),
                                                rr: rr.filter { $0.ts >= from } + f.rr,
                                                resp: resp.filter { $0.ts >= from } + f.resp,
                                                gravity: gravity.filter { $0.ts >= from } + f.gravity,
                                                sleepHRHint: baselines.restingHR?.usable == true ? baselines.restingHR?.baseline : nil)
            sleepEpisodes += later.filter { $0.end > r.to && confident($0) }
            laterChecked = true
        }
        let awake = span.map {
            AwakeWindow.classify(sleepEpisodes, span: $0, laterDataChecked: laterChecked,
                                 lastObservedTs: daySupport.intervals.last?.end)
        } ?? AwakeWindow()

        let workouts = WorkoutDetector.detect(cleaned: hrDay, support: daySupport, gravity: gravityDay,
                                              calibration: calibration, profile: profile, sleep: awake.sleep)

        // ── Load: integrated over the day's unique awake supported seconds, then attributed to sessions ──
        // Independent of how episodes were grouped. Time that wasn't observed stays unknown: it is never filled in.
        // Today's requested time ends at the scoring clock: hours that haven't happened yet are not unrecorded time.
        let load = span.map { full -> DayLoadRecord in
            let end = observedUntil.map { max(full.start, min(full.end, $0)) } ?? full.end
            return DayLoadRecord.compute(day: day, span: TimeSpan(full.start, end), support: daySupport, awake: awake,
                                  sessions: workouts.map { TimeSpan($0.start, $0.end) } + knownSessions,
                                  calibration: calibration, quality: hrQuality)
        }
        let strain = load?.strainIndex

        // ── Assemble DailyMetric ──────────────────────────────────────────────
        let daily = DailyMetric(
            day: day,
            totalSleepMin: matched.isEmpty ? nil : tstS / 60.0,
            // DailyMetric stores efficiency as a percent (as the WHOOP import does); `efficiency` here is 0..1.
            efficiency: matched.isEmpty ? nil : efficiency * 100.0,
            deepMin: matched.isEmpty ? nil : deepS / 60.0,
            remMin: matched.isEmpty ? nil : remS / 60.0,
            lightMin: matched.isEmpty ? nil : lightS / 60.0,
            disturbances: matched.isEmpty ? nil : disturbances,
            restingHr: restingHRDaily,
            avgHrv: avgHRVDaily,
            recovery: recovery,
            strain: strain,
            exerciseCount: workouts.count,
            spo2Pct: nil,
            skinTempDevC: nil,
            respRateBpm: respDaily)
        _ = sleepStart; _ = sleepEnd  // available for callers wiring sleep_start/end columns

        // ── Cache rows ────────────────────────────────────────────────────────
        // Rows in the shape the cache table stores, so callers can persist them directly.
        // One row per EPISODE of every session ending today, tagged with its session and label, so the sleep screen
        // can show naps and interrupted nights and the user can correct them. Recovery still reads only the primary.
        let cachedSleep = dayClassified.flatMap { c in
            c.episodes.map { s in
                CachedSleepSession(
                    startTs: s.start, endTs: s.end,
                    efficiency: s.efficiency,
                    restingHr: s.restingHR,
                    avgHrv: s.avgHRV,
                    stagesJSON: encodeStages(s.stages),
                    kind: c.kind.rawValue, sessionId: c.id, reason: c.reason, confidence: c.confidence)
            }
        }

        var result = DayResult(daily: daily, sleepSessions: matched, cachedSleep: cachedSleep,
                               workouts: workouts, recovery: recovery, strain: strain, assessment: assessment,
                               napSessions: napSessions, load: load)
        result.classifiedSleep = dayClassified
        return result
    }
}
