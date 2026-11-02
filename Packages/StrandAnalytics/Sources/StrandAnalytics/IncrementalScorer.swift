import Foundation
import WhoopProtocol
import WhoopStore

// IncrementalScorer.swift — scores only the days whose inputs changed, oldest first, and reuses everything else.
//
// A stored day may be reused only while everything it was computed from is unchanged:
//   algorithm   every version behind the result (`algorithmKey`), and the explicit re-score generation
//   input       decoded streams are insert-only, so rows past the last run's high-water marks are exactly the new data.
//               Each lands in the windows of the days that read it: -16 h before a day to +12 h after it.
//   dependents  a day's baselines are built from earlier days. They are recomputed during the walk, and a day whose
//               baselines did not actually change is reused, so a late night touches only real dependents.
//   known sessions  imported workouts attribute load, so a change there touches that day.
//   range       the day's boundaries, which a recorded time-zone change can move.
//   config      body profile and declared HRmax, for days still open only (see below).
//
// Causality: a finalized day keeps its calibration and config. A later measurement or profile edit can't silently rewrite
// it; only an algorithm change or the explicit re-score does. A day is finalized once it is over and sleep across its
// end could be checked. Until then it stays open: new data or config recompute it.
//
// Not inputs, on purpose: workout labels, the training log and appearance settings. No calculation reads them.
//
// Results, day states and high-water marks commit in one transaction, so a failed or interrupted run leaves the previous
// state and is retried whole. `maxRecomputedDays` splits a long re-score into such transactions, oldest first; days done
// stay done, so it resumes where it stopped. Days of different algorithm versions can coexist only during that re-score,
// and each carries its version in provenance and state.

public struct ScoringRequest: Sendable {
    public var rawId: String
    public var profile: UserProfile
    public var maxHROverride: Double?
    public var scoringVersion: Int
    public var now: Int
    /// Calendar days back from today that are always considered. Late data for an older stored day is found regardless.
    public var maxDays: Int
    /// Stop after this many recomputed days; nil = no limit.
    public var maxRecomputedDays: Int?

    public init(rawId: String, profile: UserProfile, maxHROverride: Double?, scoringVersion: Int, now: Int,
                maxDays: Int = 21, maxRecomputedDays: Int? = nil) {
        self.rawId = rawId; self.profile = profile; self.maxHROverride = maxHROverride
        self.scoringVersion = scoringVersion; self.now = now; self.maxDays = maxDays
        self.maxRecomputedDays = maxRecomputedDays
    }

    public var computedId: String { rawId + "-noop" }
}

/// Why a stored day can't be reused.
public enum RecomputeReason: String, Sendable {
    case notScored, algorithm, range, input, knownSessions, config, baselines
}

public struct ScoringOutcome: Sendable {
    /// Days recomputed and committed, oldest first, with why.
    public let recomputed: [String]
    public let reasons: [String: RecomputeReason]
    /// Days still needing work after a `maxRecomputedDays` stop.
    public let remaining: Int
}

public enum IncrementalScorer {

    /// Hours a day's score reads before its start and after its end. Both must match what `run` reads.
    static let contextBeforeS = 16 * 3600
    static var contextAfterS: Int { AnalyticsEngine.followingWindowS }

    static func generationCursor(_ computedId: String) -> String { "score.generation." + computedId }
    static func markCursor(_ computedId: String, _ stream: String) -> String { "score.mark.\(computedId).\(stream)" }

    /// Stable within and across launches; not a security hash.
    static func fingerprint(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    public static func algorithmKey(scoringVersion: Int, generation: Int) -> String {
        [String(scoringVersion), String(generation), CardioLoad.loadVersion, CardioLoad.detectorVersion,
         StrainScorer.indexVersion, SupportedHR.policyVersion, HRCalibration.version,
         MetricIdentity.noopVitalsVersion, SleepStager.stagingMethod,
         SleepSessionClassifier.version].joined(separator: "|")
    }

    static func configKey(_ p: UserProfile, maxHROverride: Double?) -> String {
        fingerprint("\(p.weightKg)|\(p.heightCm)|\(p.age)|\(p.sex)|\(maxHROverride.map { String($0) } ?? "-")")
    }

    static func baselineKey(_ b: AnalyticsEngine.ProfileBaselines) -> String {
        fingerprint("\(String(describing: b.hrv))|\(String(describing: b.restingHR))|\(String(describing: b.resp))|"
            + "\(String(describing: b.lnRMSSDReference))|\(String(describing: b.restingHRReference))|\(b.sleepTargetMin)")
    }

    static func knownSessionsKey(_ sessions: [TimeSpan]) -> String {
        fingerprint(sessions.map { "\($0.start)-\($0.end)" }.sorted().joined(separator: ","))
    }

    /// Days whose scoring window contains the hour starting at `hour × 3600`.
    static func days(readingHour hour: Int) -> Set<String> {
        let start = hour * 3600, end = start + 3600
        var out: Set<String> = []
        for offset in stride(from: -contextAfterS - 86_400, through: contextBeforeS + 86_400, by: 6 * 3600) {
            let day = AnalyticsEngine.dayString(start + offset)
            guard let r = ZoneTimeline.shared.dayRange(day) else { continue }
            if start < r.to + contextAfterS, end > r.from - contextBeforeS { out.insert(day) }
        }
        return out
    }

    /// The first reason `state` can't stand, or nil when the day may be reused (baselines are checked later).
    static func reason(state: DayScoreRow?, range: (from: Int, to: Int), algorithmKey: String, configKey: String,
                       knownKey: String, hasNewInput: Bool) -> RecomputeReason? {
        guard let s = state else { return .notScored }
        if s.algorithmKey != algorithmKey { return .algorithm }
        if s.rangeStart != range.from || s.rangeEnd != range.to { return .range }
        if hasNewInput { return .input }
        if s.knownSessionsKey != knownKey { return .knownSessions }
        if !s.finalized, s.configKey != configKey { return .config }
        return nil
    }

    public static func run(store: WhoopStore, request q: ScoringRequest) async throws -> ScoringOutcome {
        let computedId = q.computedId
        ZoneTimeline.shared.refreshFromSystem()

        // Marks first: a row arriving during this run is read now and re-checked next run, never skipped.
        let marks = try await store.streamMarks()
        var since: [String: Int]? = [:]
        for stream in marks.keys {
            if let v = try await store.cursor(markCursor(computedId, stream)) { since?[stream] = v } else { since = nil; break }
        }
        // No saved marks yet: nothing to compare against. Unscored days are found by `notScored` below.
        var changedHours: Set<Int> = []
        if let since { changedHours = try await store.changedHours(deviceId: q.rawId, since: since) }
        let states = try await store.dayScoreStates(deviceId: computedId)

        // Walk back one calendar day at a time from today, on the wearer's own clock: day keys and boundaries come from the
        // zone in force on each date (so DST days and trips are handled), not "now minus k×24 h".
        var ranges: [String: (from: Int, to: Int)] = [:]
        var cursor = q.now
        for _ in 0..<q.maxDays {
            let day = AnalyticsEngine.dayString(cursor)
            guard let r = ZoneTimeline.shared.dayRange(day) else { break }
            cursor = r.from - 1
            ranges[day] = r
        }
        let today = AnalyticsEngine.dayString(q.now)
        var touched: Set<String> = []
        for h in changedHours { touched.formUnion(days(readingHour: h)) }
        for d in Set(states.keys).union(touched).subtracting(ranges.keys) where d <= today {
            if let r = ZoneTimeline.shared.dayRange(d) { ranges[d] = r }
        }

        let generation = try await store.cursor(generationCursor(computedId)) ?? 0
        let algorithm = algorithmKey(scoringVersion: q.scoringVersion, generation: generation)
        let profileConfig = configKey(q.profile, maxHROverride: q.maxHROverride)

        // Sleep context: the wearer's habit (from their stored main sleeps) and their corrections. A correction only
        // re-scores the days it touches (it is part of that day's key). The habit is NOT part of any key: it is learned
        // from rows this scorer writes, so keying on it would re-score unchanged days. Days that re-score anyway (new
        // data) pick up the current habit; finalized days keep the labels they were scored with.
        let corrections = (try await store.sleepCorrections(from: 0, to: Int.max)).map(SleepCorrections.model)
        let pastMains = (try await store.sleepSessions(deviceId: computedId, from: 0, to: Int.max, limit: 4000))
            .filter(\.isMainSleep).map { (start: $0.startTs, end: $0.endTs) }
        let habit = SleepHabit.learn(primaries: SleepCorrections.mergeEpisodes(pastMains))
        let config = profileConfig
        func correctionsKey(_ r: (from: Int, to: Int)) -> String {
            let lo = r.from - contextBeforeS, hi = r.to + contextAfterS
            return corrections.filter { $0.end >= lo && $0.start <= hi }.map { "\($0.id):\($0.action.rawValue)" }.joined(separator: ",")
        }

        let known = (try await store.workouts(deviceId: q.rawId, from: 0, to: Int.max, limit: 5000))
            + (try await store.workouts(deviceId: "apple-health", from: 0, to: Int.max, limit: 5000))
        func knownSessions(_ r: (from: Int, to: Int)) -> [TimeSpan] {
            known.filter { $0.startTs >= r.from && $0.startTs < r.to }.map { TimeSpan($0.startTs, $0.endTs) }
        }

        var reasons: [String: RecomputeReason] = [:]
        for (day, r) in ranges {
            // An old day beyond `maxDays` is only reconsidered when something reached it; a stale version there waits for
            // the re-score, which widens `maxDays` to cover it.
            reasons[day] = reason(state: states[day], range: r, algorithmKey: algorithm, configKey: config,
                                  knownKey: knownSessionsKey(knownSessions(r)) + correctionsKey(r), hasNewInput: touched.contains(day))
        }
        let horizon = ranges.keys.sorted().suffix(q.maxDays).first ?? today
        reasons = reasons.filter { $0.key >= horizon || touched.contains($0.key) }

        guard let earliest = reasons.keys.min() else {
            if since != marks { for (s, v) in marks { try await store.setCursor(markCursor(computedId, s), v) } }
            return ScoringOutcome(recomputed: [], reasons: [:], remaining: 0)
        }

        // Dirty days, plus later days whose baselines may have moved. Walking a reused day costs only its baseline.
        var walk = ranges.keys.filter { $0 >= earliest }.sorted()
        var truncated = false
        if let limit = q.maxRecomputedDays {
            let dirty = walk.filter { reasons[$0] != nil }
            if dirty.count > limit, let last = dirty.dropFirst(limit - 1).first, let i = walk.firstIndex(of: last) {
                walk = Array(walk[...i])
                truncated = true
            }
        }
        let remaining = truncated ? reasons.keys.filter { $0 > walk.last! }.count : 0

        let seed = try await store.dailyMetrics(deviceId: computedId, from: "0000-00-00", to: "9999-99-99")
        let seedProv = try await store.provenance(deviceId: computedId, from: "0000-00-00", to: "9999-99-99")

        // A finished day keeps the calibration it was scored with. Today stays open, since tonight's sleep is not in yet.
        // A stale algorithm or generation is the explicit re-score: its days resolve calibration again.
        var frozen: [String: HRCalibration] = [:]
        for r in try await store.loadRecords(deviceId: computedId, from: walk[0], to: walk[walk.count - 1])
        where r.day != today && states[r.day]?.algorithmKey == algorithm {
            guard let c = DayLoadRecord(row: r)?.calibration, c.version == HRCalibration.version, c.hrMax != nil else { continue }
            frozen[r.day] = c
        }

        var batch = DerivedBatch()
        var detected: [WorkoutRow] = []
        var newStates: [DayScoreRow] = []
        let revision = marks.values.reduce(0, +)

        let output = try await CausalReplay.run(
            days: walk, seed: seed, seedProvenance: seedProv, scoringVersion: q.scoringVersion,
            reuse: { day, baselines in
                if reasons[day] != nil { return false }
                if states[day]?.baselineKey == baselineKey(baselines) { return true }
                reasons[day] = .baselines
                return false
            },
            analyze: { (day: String, baselines: AnalyticsEngine.ProfileBaselines) -> AnalyticsEngine.DayResult? in
                let range = ranges[day]!
                let sessions = knownSessions(range)
                func state(_ res: AnalyticsEngine.DayResult?) -> DayScoreRow {
                    // Over, and sleep across its end could be checked. A day with nothing after it stays open.
                    let closed = day < today && res?.load?.reasons.contains(LoadReason.dayEndUnclassified) != true
                    let calibration = res?.load?.calibration
                    return DayScoreRow(day: day, algorithmKey: algorithm, configKey: config, inputRevision: revision,
                                       calibrationKey: fingerprint(calibration.map { "\($0)" } ?? "-"),
                                       baselineKey: baselineKey(baselines), knownSessionsKey: knownSessionsKey(sessions) + correctionsKey(range),
                                       rangeStart: range.from, rangeEnd: range.to, finalized: closed, hasResult: res != nil)
                }
                // A night ending on this day can begin the previous evening: read from 16 h before the day starts
                // (enough waking context for the HR reference) to the day's end.
                let from = range.from - contextBeforeS, to = range.to
                let hr = try await store.hrSamples(deviceId: q.rawId, from: from, to: to, limit: 200_000)
                guard hr.count >= 200 else { newStates.append(state(nil)); return nil }   // need real raw data
                let rr = try await store.rrIntervals(deviceId: q.rawId, from: from, to: to, limit: 200_000)
                let resp = try await store.respSamples(deviceId: q.rawId, from: from, to: to, limit: 200_000)
                let grav = try await store.gravitySamples(deviceId: q.rawId, from: from, to: to, limit: 200_000)
                // Sleep that began this evening only shows in tomorrow's data. A finished day re-reads it for the
                // awake-time exclusion alone; today has nothing after it yet.
                var following: AnalyticsEngine.FollowingData?
                if day < today {
                    let tail = to + contextAfterS
                    following = .init(hr: try await store.hrSamples(deviceId: q.rawId, from: to, to: tail, limit: 200_000),
                                      rr: try await store.rrIntervals(deviceId: q.rawId, from: to, to: tail, limit: 200_000),
                                      resp: try await store.respSamples(deviceId: q.rawId, from: to, to: tail, limit: 200_000),
                                      gravity: try await store.gravitySamples(deviceId: q.rawId, from: to, to: tail, limit: 200_000))
                }
                let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav, profile: q.profile,
                                                     baselines: baselines, maxHROverride: q.maxHROverride, dayRange: range,
                                                     calibration: frozen[day], knownSessions: sessions, following: following,
                                                     sleepHabit: habit, sleepCorrections: corrections)
                newStates.append(state(res))
                return res
            },
            daily: { $0.daily }, assessment: { $0.assessment }, load: { $0.load })

        batch.provenance = output.provenance
        for (day, res) in output.results {
            batch.dailies.append(res.daily)
            batch.sleepSessions.append(contentsOf: res.cachedSleep)
            batch.series.append(contentsOf: componentPoints(day: day, res: res, scoringVersion: q.scoringVersion))
            detected.append(contentsOf: res.workouts.map(workoutRow))
            batch.loadRecords.append(contentsOf: [res.load?.row].compactMap { $0 } + res.workouts.compactMap { $0.load.row(day: day) })
        }
        batch.workouts = WorkoutReconciliation.reconcile(detected)
        batch.scoreStates = newStates
        if !truncated { batch.cursors = Dictionary(uniqueKeysWithValues: marks.map { (markCursor(computedId, $0.key), $0.value) }) }

        let done = output.processed
        try await store.writeDerived(batch, deviceId: computedId,
                                     scope: .replaceDays(done, ranges: done.map { ranges[$0]!.from...(ranges[$0]!.to - 1) }))
        return ScoringOutcome(recomputed: done, reasons: reasons.filter { done.contains($0.key) }, remaining: remaining)
    }

    /// A detected episode as a stored row, carrying the session's own numbers; never recomputed here.
    static func workoutRow(_ w: ExerciseSession) -> WorkoutRow {
        let zones = Dictionary(uniqueKeysWithValues: (1...5).map { ("z\($0)", w.zoneTimePct[$0] ?? 0) })
        let zjson = (try? JSONSerialization.data(withJSONObject: zones, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) }
        return WorkoutRow(startTs: w.start, endTs: w.end, sport: "Activity", source: "noop", durationS: w.durationS,
                          energyKcal: w.caloriesKcal, avgHr: Int(w.avgHR.rounded()), maxHr: w.peakHR, strain: w.strain,
                          distanceM: nil, zonesJSON: zjson, notes: w.load.evidence.note)
    }

    /// The separate recovery dimensions as long-format points under the "-noop" id (keys prefixed "noop."), so they
    /// persist with the day and can be compared with outcomes later. Not in MetricCatalog, so not yet shown in the UI.
    static func componentPoints(day: String, res: AnalyticsEngine.DayResult, scoringVersion: Int) -> [MetricPoint] {
        guard let a = res.assessment else { return [] }
        var p: [MetricPoint] = [MetricPoint(day: day, key: "noop.scoring_version", value: Double(scoringVersion))]
        func add(_ k: String, _ v: Double?) { if let v, v.isFinite { p.append(MetricPoint(day: day, key: k, value: v)) } }
        add("noop.sleep_24h_min", a.sleep.shortfall.sleepMin)
        add("noop.sleep_target_min", a.sleep.shortfall.targetMin)
        add("noop.sleep_shortfall_min", a.sleep.shortfall.shortfallMin)
        add("noop.ln_rmssd", a.autonomic.lnRMSSD)
        add("noop.ln_rmssd_z", a.autonomic.lnRMSSDz)
        add("noop.resting_hr_z", a.autonomic.restingHRz)
        add("noop.hrv_valid_windows", a.autonomic.quality.map { Double($0.hrvWindows) })
        add("noop.hrv_temporal_coverage", a.autonomic.quality?.hrvTemporalCoverage)
        add("noop.legacy_recovery_withheld", a.legacy.withheldReason == nil ? 0 : 1)
        add("noop.inferred_resp_bpm_experimental", res.daily.respRateBpm)
        if let l = res.load {
            add(ProvenanceKey.cardioLoad, l.summary?.zoneLoad)
            add("noop.cardio_load_exercise", l.exerciseLoad)
            add("noop.cardio_load_incidental", l.incidentalLoad)
            add("noop.edwards_load", l.summary?.edwardsLoad)
            add("noop.sleep_excluded_load", l.sleepExcludedLoad)
            add("noop.hr_observed_min", l.summary.map { Double($0.observedS) / 60 })
            add("noop.hr_coverage", l.summary?.coverage)
        }
        return p
    }

    /// Ask for every day to be recomputed under the current rules. Stale days are then picked up, resumably, by `run`.
    public static func requestFullRescore(store: WhoopStore, computedId: String) async throws {
        let g = try await store.cursor(generationCursor(computedId)) ?? 0
        try await store.setCursor(generationCursor(computedId), g + 1)
    }

    /// Copy the current derived rows aside once per algorithm key, so a resumed re-score can't overwrite the archive with
    /// rows it has already replaced.
    public static func archiveOnce(store: WhoopStore, computedId: String, archiveId: String, scoringVersion: Int) async throws {
        let generation = try await store.cursor(generationCursor(computedId)) ?? 0
        let marker = "score.archived." + fingerprint(algorithmKey(scoringVersion: scoringVersion, generation: generation))
        guard try await store.cursor(marker) == nil else { return }
        try await store.archiveDerived(deviceId: computedId, archiveId: archiveId, marker: marker)
    }
}
