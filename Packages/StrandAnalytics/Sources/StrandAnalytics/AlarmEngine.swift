import Foundation

// AlarmEngine.swift — the pure core of NOOP's wake alarm: when an alarm is next due (time zones, DST, weekdays),
// whether a smart-wake or sleep-goal window should fire early, and the alarm's state. No BLE, no timers: the app's
// AlarmController feeds it a clock and sleep estimates and executes what it decides, so all of it is testable.
//
// Capability honesty: what NOOP can actually do on the strap is recorded in `AlarmCapabilities`, set only from live
// experiments (docs/reverse-engineering/ALARM_CAPABILITIES.md). Nothing here assumes the strap can vibrate.

public struct AlarmSpec: Codable, Sendable, Equatable, Identifiable {
    public enum Mode: Codable, Sendable, Equatable {
        case exact
        /// Wake in the `windowMin` before the latest time when the wearer looks awake or lightly asleep.
        case smart(windowMin: Int)
        /// Wake in the window once `goalPercent` of the sleep need has been slept.
        case sleepGoal(goalPercent: Int, windowMin: Int)
        public var windowMin: Int {
            switch self { case .exact: return 0; case .smart(let w), .sleepGoal(_, let w): return w }
        }
    }
    public var id: String
    /// Latest wake time, local wall clock.
    public var hour: Int
    public var minute: Int
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty = one-off (next occurrence only).
    public var weekdays: Set<Int>
    public var mode: Mode
    public var enabled: Bool
    public init(id: String = UUID().uuidString, hour: Int, minute: Int, weekdays: Set<Int> = [], mode: Mode = .exact,
                enabled: Bool = true) {
        self.id = id; self.hour = hour; self.minute = minute; self.weekdays = weekdays; self.mode = mode
        self.enabled = enabled
    }
    public static let windowRange = 15...60
    public static let defaultWindowMin = 30
}

/// What the hardware has been SHOWN to do on this strap. Each flag flips only after a supervised experiment.
public struct AlarmCapabilities: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case unverified, confirmed, unsupported }
    /// The strap vibrates on a command from NOOP right now.
    public var immediateVibration: Status = .unverified
    /// The strap stores an alarm and fires it with NOOP disconnected.
    public var onDeviceAlarm: Status = .unverified
    /// The strap reports the stored alarm back (GET_ALARM_TIME).
    public var alarmReadback: Status = .unverified
    public var firmware: String?
    public init() {}
}

public enum AlarmState: String, Codable, Sendable {
    case draft, pendingSync, confirmedOnDevice, active, triggered, dismissed, canceled, failed, unknown
}

/// The next ring of one alarm, with its smart window.
public struct AlarmOccurrence: Equatable, Sendable {
    public let alarmId: String
    /// Latest wake time (the deadline). Always fires by then.
    public let deadline: Date
    /// Start of the early window (== deadline for exact alarms).
    public let windowStart: Date
}

public enum AlarmPlanner {
    /// Next occurrence strictly after `after`, in the calendar's zone. A wall time skipped by a DST spring-forward
    /// rings at the first valid minute after it; a repeated fall-back hour rings once (the first time).
    public static func next(_ a: AlarmSpec, after: Date, calendar: Calendar = .current) -> AlarmOccurrence? {
        guard a.enabled else { return nil }
        var best: Date?
        let days = a.weekdays.isEmpty ? [nil] : a.weekdays.sorted().map { Optional($0) }
        for wd in days {
            var c = DateComponents(hour: a.hour, minute: a.minute, second: 0)
            c.weekday = wd
            if let d = calendar.nextDate(after: after, matching: c, matchingPolicy: .nextTime,
                                         repeatedTimePolicy: .first, direction: .forward),
               best.map({ d < $0 }) ?? true {
                best = d
            }
        }
        guard let deadline = best else { return nil }
        return AlarmOccurrence(alarmId: a.id, deadline: deadline,
                               windowStart: deadline.addingTimeInterval(-Double(a.mode.windowMin) * 60))
    }

    /// The earliest occurrence across alarms (several alarms may be set).
    public static func nextAcross(_ alarms: [AlarmSpec], after: Date, calendar: Calendar = .current) -> AlarmOccurrence? {
        alarms.compactMap { next($0, after: after, calendar: calendar) }.min { $0.deadline < $1.deadline }
    }
}

/// A 0…1 heuristic about the wearer (legacy single-value form; SmartWake.swift builds it per evidence window), built from data NOOP actually has (stored HR, R-R and gravity, or the
/// realtime HR stream). `wakeLikelihood` is a heuristic 0…1, NOT an EEG stage.
public struct WakeEvidence: Equatable, Sendable {
    public let at: Date
    /// 0…1: how awake / lightly asleep the wearer looks (movement, HR above their sleeping level).
    public let wakeLikelihood: Double
    /// False when the minute had too little data to judge (missing samples, off-wrist suspicion).
    public let usable: Bool
    public init(at: Date, wakeLikelihood: Double, usable: Bool) {
        self.at = at; self.wakeLikelihood = wakeLikelihood; self.usable = usable
    }

    /// Heuristic from one minute's movement and HR. `moveFraction` = share of samples with a gravity change above the
    /// stillness threshold; `hrRatio` = HR ÷ the wearer's sleeping HR.
    public static func estimate(at: Date, moveFraction: Double?, hrRatio: Double?) -> WakeEvidence {
        let move = moveFraction.map { min(1, max(0, $0 * 2.5)) }                 // ≥ 40 % moving → 1
        let hr = hrRatio.map { min(1, max(0, ($0 - 1.0) / 0.25)) }               // +25 % over sleeping HR → 1
        switch (move, hr) {
        case let (m?, h?): return WakeEvidence(at: at, wakeLikelihood: 0.6 * m + 0.4 * h, usable: true)
        case let (m?, nil): return WakeEvidence(at: at, wakeLikelihood: m, usable: true)
        case let (nil, h?): return WakeEvidence(at: at, wakeLikelihood: h, usable: true)
        default: return WakeEvidence(at: at, wakeLikelihood: 0, usable: false)
        }
    }
}

// The smart-wake decision (timestamped evidence windows, policy, decision records) lives in SmartWake.swift.

/// Allowed alarm state transitions. Anything else is a bug and is rejected (the caller logs it).
public enum AlarmStateMachine {
    public static func canMove(from: AlarmState, to: AlarmState) -> Bool {
        switch (from, to) {
        case (.draft, .pendingSync), (.draft, .active), (.draft, .canceled):              return true
        case (.pendingSync, .confirmedOnDevice), (.pendingSync, .failed), (.pendingSync, .unknown),
             (.pendingSync, .canceled):                                                   return true
        case (.confirmedOnDevice, .active), (.confirmedOnDevice, .triggered), (.confirmedOnDevice, .canceled),
             (.confirmedOnDevice, .unknown):                                              return true
        case (.active, .triggered), (.active, .canceled), (.active, .failed):             return true
        case (.triggered, .dismissed), (.triggered, .failed):                             return true
        case (.failed, .pendingSync), (.failed, .active), (.failed, .canceled),
             (.unknown, .pendingSync), (.unknown, .canceled), (.unknown, .confirmedOnDevice): return true
        case (.dismissed, .active), (.canceled, .draft):                                  return true   // next occurrence / re-enable
        default:                                                                          return false
        }
    }
}
