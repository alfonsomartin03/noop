import Foundation

// AlarmDelivery.swift — one attempt to make the strap ring NOW (an early smart wake, or a deadline with no alarm stored
// on the strap), as an explicit, testable transaction. Deciding to wake is not delivery: a decision becomes "buzz
// requested" when commands go out, and "strap reported vibration" only when the strap's own events say so.
//
// Verified sequence on fw 50.43.1.0 (ALARM_CAPABILITIES.md H02b/H06b): SET_ALARM_TIME id 1 → SUCCESS/VALID_PATTERN,
// then RUN_ALARM [2, 1] → SUCCESS/SUCCESSFUL_PLAY, then events 58 APP_DRIVEN_ALARM_EXECUTED + 60 HAPTICS_FIRED; a double
// tap gives 14 + 100 (reason 2, user terminated). RUN consumes the single slot. Commands are serialized here: RUN is sent
// only after SET's final SUCCESS, each answer is matched by command AND app sequence number, and nothing is assumed from
// a command merely having been written.

/// What the strap said, mapped from WHOOP 5.0 events by the app. `at` is the event's own time (Mac clock).
public enum AlarmStrapSignal: Equatable, Sendable {
    case appAlarmExecuted
    case strapAlarmExecuted
    case hapticsFired
    /// 0 expired, 1 error, 2 user terminated; nil unknown.
    case hapticsTerminated(reason: Int?)
    case doubleTap
}

public enum AlarmCommandKind: String, Codable, Sendable { case set, run, get, disable }

public enum AlarmCommandAnswer: Equatable, Sendable {
    case pending
    case success
    case rejected(String)
}

public struct AlarmDeliveryTransaction: Equatable, Sendable {
    public enum Step: String, Codable, Sendable {
        case awaitingSet, awaitingRun, awaitingHaptics, strapReported, closed
    }
    public enum Outcome: Equatable, Sendable {
        /// The strap reported it executed the alarm / fired haptics.
        case strapReported
        /// Commands acknowledged but the strap never reported vibrating.
        case unconfirmed(String)
        case failed(String)
        case canceled
    }
    /// What the caller must do or record.
    public enum Action: Equatable, Sendable {
        case sendRun
        case acknowledged(AlarmCommandKind)
        case rejected(AlarmCommandKind, String)
        case timedOut(AlarmCommandKind)
        case strapSignal(AlarmStrapSignal, at: Date)
        case dismissed(source: String, at: Date)
        case terminated(reason: Int?, at: Date)
        /// Delivery settled (first time only): reconcile the hardware slot from this.
        case settled(Outcome)
    }

    public static let responseTimeout: TimeInterval = 10
    public static let hapticsTimeout: TimeInterval = 30
    /// A dismissal is attributed to this delivery only this long after its haptics fired.
    public static let dismissalWindow: TimeInterval = 10 * 60
    /// Strap events are matched to RUN only from this long before it was sent (clock uncertainty) …
    public static let matchSlack: TimeInterval = 5

    public let id: String
    public let occurrenceId: String
    public let early: Bool
    public private(set) var step: Step = .awaitingSet
    public private(set) var setSeq: UInt8
    public private(set) var setSentAt: Date
    public private(set) var runSeq: UInt8?
    public private(set) var runSentAt: Date?
    public private(set) var hapticsAt: Date?
    public private(set) var outcome: Outcome?

    public init(id: String = UUID().uuidString, occurrenceId: String, early: Bool, setSeq: UInt8, setSentAt: Date) {
        self.id = id; self.occurrenceId = occurrenceId; self.early = early; self.setSeq = setSeq; self.setSentAt = setSentAt
    }

    public var isOpen: Bool { step != .closed }

    /// RUN went out with `seq`.
    public mutating func runSent(seq: UInt8, at: Date) {
        guard step == .awaitingRun else { return }
        runSeq = seq; runSentAt = at
    }

    /// A command answer. Ignored unless command and sequence number match this transaction's outstanding request.
    public mutating func handle(command: AlarmCommandKind, seq: UInt8, answer: AlarmCommandAnswer, at: Date) -> [Action] {
        switch (step, command) {
        case (.awaitingSet, .set) where seq == setSeq:
            switch answer {
            case .pending: return []
            case .success: step = .awaitingRun; return [.acknowledged(.set), .sendRun]
            case .rejected(let why): return [.rejected(.set, why)] + settle(.failed("Strap refused the alarm time (\(why))"))
            }
        case (.awaitingRun, .run) where runSeq != nil && seq == runSeq:
            switch answer {
            case .pending: return []
            case .success: step = .awaitingHaptics; return [.acknowledged(.run)]
            case .rejected(let why): return [.rejected(.run, why)] + settle(.failed("Strap refused to run the alarm (\(why))"))
            }
        default:
            return []
        }
    }

    /// A LIVE strap event. Returns the actions when it belongs to this delivery, nil when it does not (unmatched).
    public mutating func handle(signal: AlarmStrapSignal, at: Date) -> [Action]? {
        switch signal {
        case .appAlarmExecuted, .hapticsFired:
            // Only after RUN was sent, and close to it. A RUN answer may still be in flight (responses can be delayed).
            guard let sent = runSentAt, step == .awaitingRun || step == .awaitingHaptics || step == .strapReported,
                  at >= sent.addingTimeInterval(-Self.matchSlack),
                  at <= sent.addingTimeInterval(Self.hapticsTimeout + Self.responseTimeout) else { return nil }
            var out: [Action] = [.strapSignal(signal, at: at)]
            if signal == .hapticsFired, hapticsAt == nil { hapticsAt = at }
            if step != .strapReported { step = .strapReported; out += settle(.strapReported) }
            return out
        case .doubleTap, .hapticsTerminated:
            guard step == .strapReported, let h = hapticsAt ?? runSentAt, at >= h.addingTimeInterval(-Self.matchSlack),
                  at <= h.addingTimeInterval(Self.dismissalWindow) else { return nil }
            if case .hapticsTerminated(let r) = signal {
                step = .closed
                return r == 2 ? [.strapSignal(signal, at: at), .dismissed(source: "strap", at: at)]
                              : [.strapSignal(signal, at: at), .terminated(reason: r, at: at)]
            }
            return [.strapSignal(signal, at: at)]
        case .strapAlarmExecuted:
            return nil   // the stored alarm firing by itself is matched to the occurrence, not to a RUN
        }
    }

    /// Timeouts.
    public mutating func tick(now: Date) -> [Action] {
        switch step {
        case .awaitingSet where now.timeIntervalSince(setSentAt) > Self.responseTimeout:
            return [.timedOut(.set)] + settle(.failed("No answer from the strap to the alarm time"))
        case .awaitingRun:
            let since = runSentAt ?? setSentAt
            guard now.timeIntervalSince(since) > Self.responseTimeout else { return [] }
            return [.timedOut(.run)] + settle(.failed("No answer from the strap to run the alarm"))
        case .awaitingHaptics where now.timeIntervalSince(runSentAt ?? setSentAt) > Self.hapticsTimeout:
            // Settle as unconfirmed, but keep listening a little longer: a late HAPTICS_FIRED is still recorded.
            if outcome == nil { return settle(.unconfirmed("The strap accepted the alarm but didn't report vibrating")) }
            if now.timeIntervalSince(runSentAt ?? setSentAt) > Self.hapticsTimeout + Self.responseTimeout { step = .closed }
            return []
        case .strapReported where now.timeIntervalSince(hapticsAt ?? runSentAt ?? setSentAt) > Self.dismissalWindow:
            step = .closed
            return []
        default:
            return []
        }
    }

    public mutating func linkDropped() -> [Action] {
        switch step {
        case .awaitingSet, .awaitingRun, .awaitingHaptics: return settle(.failed("Strap disconnected during delivery"))
        case .strapReported: step = .closed; return []
        case .closed: return []
        }
    }

    public mutating func cancel() -> [Action] {
        guard step != .closed else { return [] }
        return settle(.canceled)
    }

    private mutating func settle(_ o: Outcome) -> [Action] {
        switch o {
        case .strapReported, .unconfirmed: break
        default: step = .closed
        }
        guard outcome == nil else { return [] }
        outcome = o
        return [.settled(o)]
    }
}
