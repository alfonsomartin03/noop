import Foundation
import WhoopStore

// AlarmHistory.swift — reading the append-only alarm history (WhoopStore `alarmEvent`) back into one summary per
// occurrence, and looking up what NOOP's own sleep staging estimated around an alarm. Pure; the UI only formats.

/// Row kinds written by AlarmController. Strings are stored, so never rename one.
public enum AlarmHistoryKind {
    public static let scheduled = "scheduled"
    public static let decision = "decision"
    public static let commandRequested = "commandRequested"
    public static let commandAcknowledged = "commandAcknowledged"
    public static let commandFailed = "commandFailed"
    public static let commandTimedOut = "commandTimedOut"
    public static let strapEvent = "strapEvent"
    public static let notification = "notification"
    public static let dismissal = "dismissal"
    public static let deliveryOutcome = "deliveryOutcome"
    public static let slot = "slot"
    /// Deadline follow-up: an extra buzz because the alarm wasn't dismissed, or the follow-up stopping.
    public static let followUp = "followUp"
    /// The Mac's own state around an alarm: sleep / wake, a deadline handled late.
    public static let host = "host"
    /// Periodic summary of live HR evidence during the wake window (diagnostic; not proof of a stage or of waking).
    public static let evidence = "evidence"
}

/// One occurrence as the history tells it.
public struct AlarmOccurrenceSummary: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case scheduled, ringingOnMac, buzzRequested, strapReportedVibration, strapAlarmRang, dismissedOnStrap,
             dismissedInApp, deliveryUnconfirmed, failed, missed
        public var label: String {
            switch self {
            case .scheduled: return "Scheduled"
            case .ringingOnMac: return "Rang on this Mac"
            case .buzzRequested: return "Buzz requested"
            case .strapReportedVibration: return "Strap reported vibration"
            case .strapAlarmRang: return "Strap alarm rang"
            case .dismissedOnStrap: return "Dismissed on strap"
            case .dismissedInApp: return "Dismissed in NOOP"
            case .deliveryUnconfirmed: return "Delivery unconfirmed"
            case .failed: return "Delivery failed"
            case .missed: return "Missed (NOOP not running)"
            }
        }
    }
    public let id: String
    public var alarmId: String?
    public var deadline: Date?
    public var windowStart: Date?
    public var timeZone: String?
    public var policyVersion: String?
    public var modeText: String?
    public var decisionAt: Date?
    public var decisionTrigger: String?
    public var decisionReason: String?
    public var evidenceQuality: String?
    public var baselineSource: String?
    public var buzzRequestedAt: Date?
    public var vibrationReportedAt: Date?
    public var dismissedAt: Date?
    public var dismissalSource: String?
    public var notificationOutcome: String?
    public var deliveryNote: String?
    /// Extra buzzes after the deadline because it wasn't dismissed.
    public var followUpBuzzes = 0
    /// Mac sleep/wake and late-deadline notes, in order.
    public var hostNotes: [String] = []
    /// Newest live-HR summary in the window: samples in the last 5 min (nil = none recorded).
    public var liveSamples: Int?
    public var status: Status = .scheduled
    /// The time the summary is sorted and shown by.
    public var anchor: Date { decisionAt ?? deadline ?? .distantPast }
}

public enum AlarmHistory {
    /// JSON payload helpers (writers use `payload(_:)`, readers `fields(_:)`).
    public static func payload(_ dict: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public static func fields(_ payload: String?) -> [String: Any] {
        guard let d = payload?.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// Group rows by occurrence (unattributed rows are left out) and derive each status. Newest first.
    public static func summarize(_ rows: [AlarmEventRow]) -> [AlarmOccurrenceSummary] {
        var by: [String: [AlarmEventRow]] = [:]
        for r in rows { if let o = r.occurrenceId { by[o, default: []].append(r) } }
        return by.map { id, rs in summarize(id: id, rows: rs.sorted { ($0.recordedAt, $0.id ?? 0) < ($1.recordedAt, $1.id ?? 0) }) }
            .sorted { $0.anchor > $1.anchor }
    }

    static func summarize(id: String, rows: [AlarmEventRow]) -> AlarmOccurrenceSummary {
        var s = AlarmOccurrenceSummary(id: id)
        var outcome: String?
        var strapRang = false
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        for r in rows {
            let f = fields(r.payload)
            let t = Date(timeIntervalSince1970: r.mappedHostTs ?? r.recordedAt)
            switch r.kind {
            case AlarmHistoryKind.scheduled:
                s.alarmId = f["alarmId"] as? String
                s.deadline = date(f["deadline"]); s.windowStart = date(f["windowStart"])
                s.timeZone = f["timeZone"] as? String; s.policyVersion = f["policyVersion"] as? String
                s.modeText = f["mode"] as? String
            case AlarmHistoryKind.decision:
                if s.decisionAt == nil {
                    s.decisionAt = t
                    s.decisionTrigger = f["trigger"] as? String
                    s.decisionReason = f["reason"] as? String
                    s.evidenceQuality = f["evidenceQuality"] as? String
                    s.baselineSource = f["baselineSource"] as? String
                    if let v = f["policyVersion"] as? String { s.policyVersion = v }
                }
            case AlarmHistoryKind.commandRequested:
                if f["command"] as? String == AlarmCommandKind.run.rawValue, s.buzzRequestedAt == nil { s.buzzRequestedAt = t }
            case AlarmHistoryKind.strapEvent:
                switch f["event"] as? String {
                case "HAPTICS_FIRED", "APP_DRIVEN_ALARM_EXECUTED": if s.vibrationReportedAt == nil { s.vibrationReportedAt = t }
                case "STRAP_DRIVEN_ALARM_EXECUTED": strapRang = true; if s.vibrationReportedAt == nil { s.vibrationReportedAt = t }
                default: break
                }
            case AlarmHistoryKind.notification:
                s.notificationOutcome = f["outcome"] as? String
            case AlarmHistoryKind.dismissal:
                if s.dismissedAt == nil { s.dismissedAt = t; s.dismissalSource = f["source"] as? String }
            case AlarmHistoryKind.deliveryOutcome:
                outcome = f["outcome"] as? String
                s.deliveryNote = f["detail"] as? String ?? s.deliveryNote
            case AlarmHistoryKind.followUp:
                if f["action"] as? String == "buzz" { s.followUpBuzzes += 1 }
            case AlarmHistoryKind.host:
                if let e = f["event"] as? String { s.hostNotes.append(e) }
            case AlarmHistoryKind.evidence:
                s.liveSamples = (f["liveSamples"] as? NSNumber)?.intValue
            default: break
            }
        }
        if s.dismissedAt != nil {
            s.status = s.dismissalSource == "strap" ? .dismissedOnStrap : .dismissedInApp
        } else if outcome == "missed" {
            s.status = .missed
        } else if strapRang {
            s.status = .strapAlarmRang
        } else if s.vibrationReportedAt != nil {
            s.status = .strapReportedVibration
        } else if outcome == "failed" {
            s.status = .failed
        } else if outcome == "unconfirmed" {
            s.status = .deliveryUnconfirmed
        } else if s.buzzRequestedAt != nil {
            s.status = .buzzRequested
        } else if s.decisionAt != nil {
            s.status = outcome == "macOnly" ? .ringingOnMac : .deliveryUnconfirmed
        }
        return s
    }
}

/// What NOOP's own staging estimated around a time. Only genuine, timestamped stage segments count: imported stage
/// TOTALS, synthetic orderings, "unknown"/"asleep" segments and gaps between episodes are never evidence of a stage.
public enum AlarmStageLookup {
    public enum Result: Equatable, Sendable {
        /// `stage` is a SleepState raw value (light, deep, rem, wake); always an estimate.
        case estimated(stage: String, source: String)
        case unavailable(String)
    }

    static let stageLabels: Set<String> = ["wake", "light", "deep", "rem"]

    /// Genuine segments from raw (not recombined) NOOP episode rows. Rows whose JSON is a totals dict yield nothing.
    public static func segments(_ episodes: [CachedSleepSession]) -> [StageSegment] {
        let dec = JSONDecoder()
        return episodes.flatMap { e -> [StageSegment] in
            guard let d = e.stagesJSON?.data(using: .utf8), let segs = try? dec.decode([StageSegment].self, from: d) else { return [] }
            // A segment must lie inside its own episode; anything else is not this episode's estimate.
            return segs.filter { $0.end > $0.start && $0.start >= e.startTs && $0.end <= e.endTs }
        }.sorted { $0.start < $1.start }
    }

    public static func stage(at t: Int, episodes: [CachedSleepSession], source: String) -> Result {
        let segs = segments(episodes)
        if segs.isEmpty {
            let totalsOnly = episodes.contains { $0.stagesJSON?.trimmingCharacters(in: .whitespaces).hasPrefix("{") == true }
            return .unavailable(totalsOnly ? "Stage unavailable (stage totals only)" : "Stage unavailable")
        }
        guard let s = segs.last(where: { $0.start <= t && t < $0.end }) else { return .unavailable("Stage unavailable (no estimate at this time)") }
        guard stageLabels.contains(s.stage) else { return .unavailable("Stage unavailable (\(s.stage == "asleep" ? "asleep, stage not estimated" : "unknown"))") }
        return .estimated(stage: s.stage, source: source)
    }

    /// Genuine segments clipped to [from, to), for drawing a timeline around an alarm.
    public static func timeline(from: Int, to: Int, episodes: [CachedSleepSession]) -> [StageSegment] {
        segments(episodes).compactMap { s in
            let a = max(s.start, from), b = min(s.end, to)
            return b > a ? StageSegment(start: a, end: b, stage: s.stage, reason: s.reason) : nil
        }
    }
}
