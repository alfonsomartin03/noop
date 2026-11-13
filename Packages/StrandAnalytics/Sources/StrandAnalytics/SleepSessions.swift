import Foundation
import WhoopProtocol
import WhoopStore

// SleepSessions.swift — layers C and D of the sleep pipeline: which detected sleep EPISODES belong together, and what
// each resulting SESSION is (primary sleep, interrupted primary sleep, nap, or uncertain).
//
//   A  epochs     SleepStager (stillness minutes, Cole-Kripke epochs, HR dip)          — "is this minute sleep?"
//   B  episodes   SleepStager.detectSleep → [SleepSession]                              — contiguous sleep spans
//   C  sessions   SleepSessionClassifier.group                                          — episodes that form one sleep
//   D  labels     SleepSessionClassifier.classify (+ user corrections)                  — primary / nap / uncertain
//   E  metrics    AnalyticsEngine: recovery uses ONLY the primary session's episodes; naps add to 24-h sleep
//
// Detection never depends on the label: whether a span is sleep is decided in A/B by its own evidence; this file only
// groups and names what was found. Labels are recomputed on every scoring run (late data can change them) except where
// the user corrected them, and episodes are never rewritten — a merged session keeps its awake gaps.
//
// Every number below is a heuristic to validate against annotated nights, not an established threshold.

public enum SleepSessionKind: String, Codable, Sendable, Equatable {
    case primary              // the cycle's main sleep, one episode
    case interruptedPrimary   // the cycle's main sleep, several episodes with awake gaps kept
    case nap
    case uncertain            // too short / weak evidence / still being recorded: not counted until confirmed
}

/// The wearer's habitual sleep timing, learned from their own past primary sleeps (so shift work is handled).
public struct SleepHabit: Codable, Sendable, Equatable {
    /// Local clock minute (0..<1440) of the usual sleep midpoint.
    public var midpointMinute: Int
    /// Usual primary sleep length, minutes.
    public var typicalMinutes: Int
    public var nights: Int
    public init(midpointMinute: Int, typicalMinutes: Int, nights: Int) {
        self.midpointMinute = (midpointMinute % 1440 + 1440) % 1440
        self.typicalMinutes = typicalMinutes
        self.nights = nights
    }
    /// Population default until the wearer has history: midpoint 03:30, 7.5 h.
    public static let fallback = SleepHabit(midpointMinute: 210, typicalMinutes: 450, nights: 0)

    /// Circular mean of past primary-sleep midpoints (local clock) and their median length. Needs ≥ 3 nights.
    public static func learn(primaries: [(start: Int, end: Int)], calendar: Calendar = .current) -> SleepHabit {
        let recent = primaries.sorted { $0.start < $1.start }.suffix(21)
        guard recent.count >= 3 else { return .fallback }
        var sx = 0.0, sy = 0.0
        for p in recent {
            let mid = Date(timeIntervalSince1970: TimeInterval((p.start + p.end) / 2))
            let c = calendar.dateComponents([.hour, .minute], from: mid)
            let a = Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 1440 * 2 * .pi
            sx += cos(a); sy += sin(a)
        }
        var m = atan2(sy, sx) / (2 * .pi) * 1440
        if m < 0 { m += 1440 }
        let lengths = recent.map { ($0.end - $0.start) / 60 }.sorted()
        return SleepHabit(midpointMinute: Int(m.rounded()), typicalMinutes: lengths[lengths.count / 2], nights: recent.count)
    }

    /// Minutes between a local clock minute and the habitual midpoint, on the 24-h circle (0…720).
    func circularDistance(_ minute: Int) -> Int {
        let d = abs(minute - midpointMinute) % 1440
        return min(d, 1440 - d)
    }
}

/// A user correction. Matched to sessions by time overlap (not ids), so it survives regrouping and late data.
public struct SleepCorrection: Codable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case markNap, markPrimary, confirm, reject, merge, split, adjust
    }
    public var id: String
    public var action: Action
    /// The span the user acted on (for merge: the whole span to join).
    public var start: Int
    public var end: Int
    /// split: the cut time. adjust: new start/end.
    public var at: Int?
    public var newStart: Int?
    public var newEnd: Int?
    public var createdAt: Int
    public init(id: String = UUID().uuidString, action: Action, start: Int, end: Int, at: Int? = nil,
                newStart: Int? = nil, newEnd: Int? = nil, createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id; self.action = action; self.start = start; self.end = end
        self.at = at; self.newStart = newStart; self.newEnd = newEnd; self.createdAt = createdAt
    }
}

/// One classified sleep session: one or more episodes, the awake gaps between them kept.
public struct ClassifiedSleepSession: Sendable, Equatable {
    /// Stable for a given first episode start (minute resolution), so late data extending the end keeps the id.
    public let id: String
    public let episodes: [SleepSession]
    public var kind: SleepSessionKind
    /// 0…1: how sure the automatic label is (user-set labels are 1).
    public var confidence: Double
    public var userCorrected: Bool
    /// Why the label was chosen, in plain words (shown in the sleep details).
    public var reason: String
    /// Optional user-adjusted bounds (episodes are never rewritten; metrics clip to these).
    public var startOverride: Int?
    public var endOverride: Int?

    public var start: Int { startOverride ?? episodes.first!.start }
    public var end: Int { endOverride ?? episodes.last!.end }
    public var isPrimary: Bool { kind == .primary || kind == .interruptedPrimary }
    /// Awake gaps between episodes (kept, never erased by grouping).
    public var gaps: [(start: Int, end: Int)] {
        zip(episodes, episodes.dropFirst()).map { ($0.end, $1.start) }
    }
    /// Asleep seconds from the episodes' stages, clipped to any user bounds.
    public var asleepSeconds: Int {
        episodes.reduce(0) { acc, e in
            acc + e.stages.filter { $0.state.isSleep }.reduce(0) { a, s in
                let lo = max(s.start, startOverride ?? s.start), hi = min(s.end, endOverride ?? s.end)
                return a + max(0, hi - lo)
            }
        }
    }
}

public struct SleepSessionPolicy: Sendable, Equatable {
    /// Episodes this close always belong together (bathroom break, phone), any time of day.
    public var alwaysJoinGapMin = 50
    /// Longer awakenings (up to this) still join when both sides fall in the wearer's habitual sleep window —
    /// waking at 5 and sleeping again at 7 is one interrupted night, not a night plus a nap.
    public var habitualJoinGapMin = 150
    /// Half-width of the habitual sleep window around the midpoint, beyond half the typical length.
    public var habitualWindowSlackMin = 150
    /// A primary needs at least this much sleep (or this fraction of the typical night when circadian-aligned).
    public var minPrimaryAsleepMin = 180
    public var minAlignedPrimaryFraction = 0.4
    /// Naps: sessions with less sleep than this stay `uncertain` until confirmed (investigated range 15–20 min).
    public var minNapAsleepMin = 20
    /// Episodes shorter than this are only ever `uncertain` (detection resolution is ~15 min).
    public var confidentEpisodeMin = 30
    public init() {}
}

public enum SleepSessionClassifier {
    /// Part of the scoring algorithm key: bump when grouping or labelling rules change, so stored days re-score.
    public static let version = "sessions-v2"   // v2: low-evidence episodes stay uncertain and never join a group

    // MARK: C — grouping

    /// Group time-sorted episodes into sessions. A gap joins when short, or when both sides sit in the habitual
    /// sleep window and the gap is not too long. Missing data inside a gap never joins by itself (the stager already
    /// refuses to bridge unobserved time inside an episode; here only the timing is judged).
    public static func group(_ episodes: [SleepSession], habit: SleepHabit, policy: SleepSessionPolicy = .init(),
                             calendar: Calendar = .current) -> [[SleepSession]] {
        let sorted = episodes.sorted { $0.start < $1.start }
        var out: [[SleepSession]] = []
        for e in sorted {
            guard var last = out.last, let prev = last.last else { out.append([e]); continue }
            let gapMin = (e.start - prev.end) / 60
            let join: Bool
            // A span without enough heart rate to confirm sleep never attaches itself to real sleep.
            if e.lowEvidence || prev.lowEvidence { join = false }
            else if gapMin <= policy.alwaysJoinGapMin { join = true }
            else if gapMin <= policy.habitualJoinGapMin {
                join = inHabitWindow(prev.end, habit, policy, calendar) && inHabitWindow(e.start, habit, policy, calendar)
            } else { join = false }
            if join { last.append(e); out[out.count - 1] = last } else { out.append([e]) }
        }
        return out
    }

    static func localMinute(_ ts: Int, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func inHabitWindow(_ ts: Int, _ h: SleepHabit, _ p: SleepSessionPolicy, _ calendar: Calendar) -> Bool {
        h.circularDistance(localMinute(ts, calendar)) <= h.typicalMinutes / 2 + p.habitualWindowSlackMin
    }

    /// 1 at the habitual midpoint, falling to 0.5 twelve hours away: a long day sleep still wins for a shift worker,
    /// a short night sleep does not automatically become the primary.
    static func circadianWeight(_ midTs: Int, _ h: SleepHabit, _ calendar: Calendar) -> Double {
        let d = Double(h.circularDistance(localMinute(midTs, calendar)))
        return 0.75 + 0.25 * cos(d / 720 * .pi)
    }

    // MARK: D — labels

    /// Classify the sessions of one wake-day window. At most one session is primary; the rest are naps or uncertain.
    /// `isFinalized` = false while the recording may still be extending the last session.
    /// `wakeDay` names the cycle a session belongs to (by its end); one primary is chosen per cycle, so a window
    /// holding two nights keeps both as primaries.
    public static func classify(_ episodes: [SleepSession], habit: SleepHabit, corrections: [SleepCorrection] = [],
                                policy: SleepSessionPolicy = .init(), calendar: Calendar = .current,
                                wakeDay: ((Int) -> String)? = nil) -> [ClassifiedSleepSession] {
        let dayOf: (Int) -> String = wakeDay ?? { ts in
            let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return "\(c.year!)-\(c.month!)-\(c.day!)"
        }
        let applied = applyStructural(corrections, to: episodes)
        var groups = group(applied, habit: habit, policy: policy, calendar: calendar)
        groups = applyMergeSplit(corrections, groups)
        var sessions = groups.map { eps -> ClassifiedSleepSession in
            ClassifiedSleepSession(id: "sleep-\(eps.first!.start / 60)", episodes: eps, kind: .uncertain,
                                   confidence: 0, userCorrected: false, reason: "")
        }
        // Primary candidates: enough sleep, scored by sleep × circadian alignment.
        func score(_ s: ClassifiedSleepSession) -> Double {
            Double(s.asleepSeconds) / 3600 * circadianWeight((s.start + s.end) / 2, habit, calendar)
        }
        func unconfirmed(_ s: ClassifiedSleepSession) -> Bool { s.episodes.allSatisfy(\.lowEvidence) }
        func qualifiesPrimary(_ s: ClassifiedSleepSession) -> Bool {
            if unconfirmed(s) { return false }
            let asleepMin = s.asleepSeconds / 60
            if asleepMin >= policy.minPrimaryAsleepMin { return true }
            let aligned = inHabitWindow((s.start + s.end) / 2, habit, policy, calendar)
            return aligned && Double(asleepMin) >= policy.minAlignedPrimaryFraction * Double(habit.typicalMinutes)
        }
        var primaries = Set<Int>()
        for idxs in Dictionary(grouping: sessions.indices, by: { dayOf(sessions[$0].end) }).values {
            if let best = idxs.filter({ qualifiesPrimary(sessions[$0]) }).max(by: { score(sessions[$0]) < score(sessions[$1]) }) {
                primaries.insert(best)
            }
        }
        for i in sessions.indices {
            let s = sessions[i]
            let asleepMin = s.asleepSeconds / 60
            let longestEpisodeMin = s.episodes.map { ($0.end - $0.start) / 60 }.max() ?? 0
            if primaries.contains(i) {
                sessions[i].kind = s.episodes.count > 1 ? .interruptedPrimary : .primary
                let aligned = inHabitWindow((s.start + s.end) / 2, habit, policy, calendar)
                sessions[i].confidence = aligned ? 0.9 : 0.7
                sessions[i].reason = s.episodes.count > 1
                    ? "Main sleep, \(s.episodes.count) parts with \(s.gaps.count) awake gap(s) kept"
                    : (aligned ? "Main sleep at your usual time" : "Main sleep (longest sleep, outside your usual hours)")
            } else if unconfirmed(s) {
                sessions[i].kind = .uncertain
                sessions[i].confidence = 0.2
                sessions[i].reason = lowEvidenceReason
            } else if asleepMin >= policy.minNapAsleepMin && longestEpisodeMin >= policy.confidentEpisodeMin {
                sessions[i].kind = .nap
                sessions[i].confidence = longestEpisodeMin >= 45 ? 0.8 : 0.6
                sessions[i].reason = "Shorter sleep outside the main sleep"
            } else {
                sessions[i].kind = .uncertain
                sessions[i].confidence = 0.3
                sessions[i].reason = "Brief or weak sleep signal: confirm or reject it"
            }
            if s.episodes.contains(where: \.isProvisional) && sessions[i].kind != .uncertain {
                sessions[i].confidence = min(sessions[i].confidence, 0.5)
                sessions[i].reason += " (still being recorded)"
            }
        }
        return applyLabels(corrections, sessions, dayOf: dayOf)
    }

    public static let lowEvidenceReason = "Still, but too little heart-rate data to tell sleep from an off-wrist strap: confirm or reject it"

    // MARK: corrections

    /// True when the wearer has said this span was sleep (confirm / nap / main sleep / adjusted bounds) and has not
    /// rejected it. Used for spans the detector cannot confirm by itself (`SleepSession.lowEvidence`).
    public static func userConfirmsSleep(_ cs: [SleepCorrection], start: Int, end: Int) -> Bool {
        let touching = cs.filter { overlaps($0, start, end) }
        let confirming: Set<SleepCorrection.Action> = [.confirm, .markNap, .markPrimary, .adjust]
        return touching.contains { confirming.contains($0.action) } && !touching.contains { $0.action == .reject }
    }

    static func overlaps(_ c: SleepCorrection, _ s: Int, _ e: Int) -> Bool {
        let lo = max(c.start, s), hi = min(c.end, e)
        guard hi > lo else { return false }
        // Most of the session (or most of the corrected span) must overlap, so a nap next to a night isn't caught.
        return Double(hi - lo) >= 0.5 * Double(min(e - s, c.end - c.start))
    }

    /// Reject removes episodes (quiet rest the user says was not sleep). Episodes are not deleted from storage.
    static func applyStructural(_ cs: [SleepCorrection], to episodes: [SleepSession]) -> [SleepSession] {
        let rejects = cs.filter { $0.action == .reject }
        return episodes.filter { e in !rejects.contains { overlaps($0, e.start, e.end) } }
    }

    /// Merge joins every group touching the span; split cuts a group between episodes at `at`.
    static func applyMergeSplit(_ cs: [SleepCorrection], _ groups: [[SleepSession]]) -> [[SleepSession]] {
        var g = groups
        for c in cs.sorted(by: { $0.createdAt < $1.createdAt }) {
            switch c.action {
            case .merge:
                let hit = g.indices.filter { i in g[i].first!.start < c.end && g[i].last!.end > c.start }
                guard hit.count > 1, let first = hit.first else { continue }
                let joined = hit.flatMap { g[$0] }.sorted { $0.start < $1.start }
                for i in hit.reversed() { g.remove(at: i) }
                g.insert(joined, at: first)
            case .split:
                guard let at = c.at, let i = g.firstIndex(where: { $0.first!.start < at && $0.last!.end > at }) else { continue }
                let left = g[i].filter { $0.end <= at }, right = g[i].filter { $0.start >= at }
                guard !left.isEmpty, !right.isEmpty else { continue }   // only between episodes; never cuts raw data
                g.replaceSubrange(i...i, with: [left, right])
            default: continue
            }
        }
        return g
    }

    /// Label corrections. The newest correction touching a session wins; a user label is never overridden automatically.
    static func applyLabels(_ cs: [SleepCorrection], _ sessions: [ClassifiedSleepSession],
                            dayOf: (Int) -> String) -> [ClassifiedSleepSession] {
        var out = sessions
        for c in cs.sorted(by: { $0.createdAt < $1.createdAt }) {
            for i in out.indices where overlaps(c, out[i].start, out[i].end) {
                switch c.action {
                case .markNap:
                    out[i].kind = .nap
                case .markPrimary:
                    // Only one primary per wake day: demote any other on the same day.
                    for j in out.indices where j != i && out[j].isPrimary && dayOf(out[j].end) == dayOf(out[i].end) {
                        out[j].kind = .nap; out[j].reason = "Demoted: you chose another main sleep"
                    }
                    out[i].kind = out[i].episodes.count > 1 ? .interruptedPrimary : .primary
                case .confirm:
                    if out[i].kind == .uncertain { out[i].kind = .nap }
                case .adjust:
                    out[i].startOverride = c.newStart
                    out[i].endOverride = c.newEnd
                default:
                    continue
                }
                out[i].confidence = 1
                out[i].userCorrected = true
                out[i].reason = "Set by you"
            }
        }
        return out
    }
}

/// Glue between stored rows and the classifier.
public enum SleepCorrections {
    public static func model(_ r: SleepCorrectionRow) -> SleepCorrection {
        SleepCorrection(id: r.id, action: SleepCorrection.Action(rawValue: r.action) ?? .confirm, start: r.startTs,
                        end: r.endTs, at: r.atTs, newStart: r.newStartTs, newEnd: r.newEndTs, createdAt: r.createdAt)
    }
    public static func row(_ c: SleepCorrection) -> SleepCorrectionRow {
        SleepCorrectionRow(id: c.id, action: c.action.rawValue, startTs: c.start, endTs: c.end, atTs: c.at,
                           newStartTs: c.newStart, newEndTs: c.newEnd, createdAt: c.createdAt)
    }
    /// Stored main-sleep rows are per episode; join the parts of one night (gaps ≤ 3 h) before learning the habit.
    public static func mergeEpisodes(_ spans: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        var out: [(start: Int, end: Int)] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let l = out.last, s.start - l.end <= 3 * 3600 { out[out.count - 1].end = max(l.end, s.end) } else { out.append(s) }
        }
        return out
    }
}
