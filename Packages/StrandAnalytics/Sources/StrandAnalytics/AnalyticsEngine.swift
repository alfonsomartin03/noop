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

    /// Baselines passed in by the caller (built from prior nights via Baselines).
    public struct ProfileBaselines: Sendable {
        public let hrv: BaselineState?
        public let restingHR: BaselineState?
        public let resp: BaselineState?
        public init(hrv: BaselineState? = nil, restingHR: BaselineState? = nil,
                    resp: BaselineState? = nil) {
            self.hrv = hrv; self.restingHR = restingHR; self.resp = resp
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
        /// Day strain [0,21] or nil (insufficient HR samples / invalid HRR).
        public let strain: Double?

        public init(daily: DailyMetric, sleepSessions: [SleepSession],
                    cachedSleep: [CachedSleepSession], workouts: [ExerciseSession],
                    recovery: Double?, strain: Double?) {
            self.daily = daily; self.sleepSessions = sleepSessions
            self.cachedSleep = cachedSleep; self.workouts = workouts
            self.recovery = recovery; self.strain = strain
        }
    }

    /// Minimum asleep time (seconds) in the day's sleep sessions before a recovery score is produced.
    static let minRecoverySleepS = 3.0 * 3600.0

    /// Format a unix-seconds timestamp as a YYYY-MM-DD day string on the wearer's clock, in the time zone that was
    /// in force at that instant (see `ZoneTimeline`), so a night slept abroad keeps its own day.
    public static func dayString(_ ts: Int) -> String { ZoneTimeline.shared.dayString(ts) }

    /// JSON-encode stage segments to the verbatim array shape CachedSleepSession stores.
    static func encodeStages(_ stages: [StageSegment]) -> String? {
        guard let data = try? JSONEncoder().encode(stages) else { return nil }
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
    ///   - maxHROverride: explicit HRmax (bpm) to use for strain/zones; nil →
    ///     Tanaka from profile.age.
    // Order matters: sleep first (gives resting HR + HRV), then recovery (needs those), then workouts and strain.
    public static func analyzeDay(day: String,
                                  hr rawHR: [HRSample] = [],
                                  rr: [RRInterval] = [],
                                  resp: [RespSample] = [],
                                  gravity: [GravitySample] = [],
                                  profile: UserProfile,
                                  baselines: ProfileBaselines = ProfileBaselines(),
                                  maxHROverride: Double? = nil,
                                  dayRange: (from: Int, to: Int)? = nil) -> DayResult {

        // Validated HR for every downstream score: de-duplicated, in range, isolated optical spikes removed.
        let hr = HRQuality.clean(rawHR)

        // ── Sleep detection + staging ─────────────────────────────────────────
        let allSessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: resp, gravity: gravity,
                                                    sleepHRHint: (baselines.restingHR?.usable == true ? baselines.restingHR?.baseline : nil))
        // Sessions attributed to `day` = those whose end falls on `day` (UTC).
        // Only night sleep feeds the daily totals / recovery / cache; naps (and sedentary rest, which the
        // stager rejects) must not inflate the night. Naps stay available in `napSessions`.
        let matched = allSessions.filter { dayString($0.end) == day && $0.kind == .main }
        let napSessions = allSessions.filter { dayString($0.end) == day && $0.kind == .nap }

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

        let sleepStart = matched.map { $0.start }.min()
        let sleepEnd = matched.map { $0.end }.max()

        // ── Recovery ──────────────────────────────────────────────────────────
        var recovery: Double? = nil
        // Recovery needs HRV, resting HR and an HRV baseline; otherwise stay nil instead of guessing.
        // A real night is required: a nap or a still afternoon on the couch must not produce a recovery score.
        // A provisional night (recording ends right after the wake) still scores so recovery shows on waking; every
        // sync recomputes the whole day, so it is revised if the wearer goes back to sleep (see DayResult.sleepProvisional).
        let hadMainSleep = tstS >= minRecoverySleepS
        if hadMainSleep, let hrvVal = avgHRVDaily, let rhrVal = restingHRDaily, let hrvBase = baselines.hrv {
            // Sleep-performance proxy = in-bed-weighted efficiency (0..1).
            let sleepPerf = matched.isEmpty ? nil : efficiency
            recovery = RecoveryScorer.recovery(
                hrv: hrvVal,
                rhr: Double(rhrVal),
                resp: nil,                 // raw resp not aggregated to a nightly scalar here
                hrvBaseline: hrvBase,
                rhrBaseline: baselines.restingHR,
                respBaseline: baselines.resp,
                sleepPerf: sleepPerf)
        }

        // ── Workouts ──────────────────────────────────────────────────────────
        // User override wins; otherwise Tanaka from age.
        let effMaxHR: Double? = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        // Day resting HR from sleep is the best baseline for 'elevated' HR, so pass it through.
        let hrDay = dayRange.map { r in hr.filter { $0.ts >= r.from && $0.ts < r.to } } ?? hr
        let gravityDay = dayRange.map { r in gravity.filter { $0.ts >= r.from && $0.ts < r.to } } ?? gravity
        let workouts = WorkoutDetector.detect(
            hr: hrDay, gravity: gravityDay,
            restingHR: restingHRDaily.map(Double.init),
            maxHR: maxHROverride,
            age: profile.age > 0 ? profile.age : nil,
            profile: profile)

        // ── Strain: fitted WHOOP model = log of the workouts' weighted zone load plus a rest-day floor ──
        // Day strain = log of summed zone load of workouts + a rest-day floor (see StrainScorer).
        let strain: Double?
        if hrDay.count < StrainScorer.minReadings {
            strain = nil
        } else {
            // Workout segments can be shorter than minReadings (min bout is 5 min), so use the raw zone
            // load rather than whoopLoad (which returned nil and silently dropped them).
            let maxForLoad = effMaxHR ?? Double(StrainScorer.defaultMaxHR())
            var loads: [Double] = workouts.map { w in
                let seg = hrDay.filter { $0.ts >= w.start && $0.ts <= w.end }
                return StrainScorer.whoopZoneLoadTimed(seg, maxHR: w.hrmax ?? maxForLoad)
            }
            // Plus sustained high-HR effort the motion gate missed (e.g. a still wrist while cycling).
            // Catches long hard efforts that workout detection did not claim, without double counting.
            loads.append(StrainScorer.highEffortLoad(hrDay, maxHR: maxForLoad,
                                                     excluding: workouts.map { ($0.start, $0.end) }))
            // Rest-day baseline accrues with recorded WAKING time (sleep excluded): ~0 on waking, full at the end of a ~16 h day.
            let asleep = allSessions.map { (start: $0.start, end: $0.end) }
            let coverage = dayRange.map { StrainScorer.coveredSeconds(hr, from: $0.from, to: $0.to, excluding: asleep) / StrainScorer.awakeDaySeconds } ?? 1.0
            strain = StrainScorer.dayStrain(workoutLoads: loads, coverage: coverage)
        }

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
            respRateBpm: nil)
        _ = sleepStart; _ = sleepEnd  // available for callers wiring sleep_start/end columns

        // ── Cache rows ────────────────────────────────────────────────────────
        // Rows in the shape the cache table stores, so callers can persist them directly.
        let cachedSleep = matched.map { s in
            CachedSleepSession(
                startTs: s.start, endTs: s.end,
                efficiency: s.efficiency,
                restingHr: s.restingHR,
                avgHrv: s.avgHRV,
                stagesJSON: encodeStages(s.stages))
        }

        _ = napSessions
        return DayResult(daily: daily, sleepSessions: matched, cachedSleep: cachedSleep,
                         workouts: workouts, recovery: recovery, strain: strain)
    }
}
