import AppKit
import Foundation
import Combine
import UserNotifications
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - Interfaces (BLE, notifications, history) so the controller runs against doubles in tests

/// The alarm commands NOOP may send (verified forms only; BLEManager builds the payloads).
enum AlarmStrapCommand: Equatable { case set(strapSeconds: UInt32), get, run, disableAll }

/// What AlarmController needs from the strap link. BLEManager conforms.
@MainActor
protocol AlarmStrapLink: AnyObject {
    /// A bonded WHOOP 5.0 link that can take alarm commands now.
    var alarmLinkReady: Bool { get }
    var alarmClock: ClockEstimate? { get }
    /// Sends one command; returns its app sequence number (replies echo it), nil when not sent.
    func sendAlarmCommand(_ c: AlarmStrapCommand) -> UInt8?
    /// Realtime HR stream ownership: the stream stays on while any owner holds it.
    func acquireRealtime(owner: String)
    func releaseRealtime(owner: String)
}

enum AlarmNotificationOutcome: Equatable {
    case submitted(critical: Bool)
    case notAuthorized(String)
    case failed(String)
    var historyValue: String {
        switch self {
        case .submitted(let c): return c ? "submitted-critical" : "submitted"
        case .notAuthorized(let s): return "not-authorized:\(s)"
        case .failed(let e): return "failed:\(e)"
        }
    }
}

@MainActor
protocol AlarmNotifying {
    func postWake(title: String, body: String) async -> AlarmNotificationOutcome
}

/// macOS notifications. Checks authorization first and reports submission errors; critical sound only when the system
/// says critical alerts are enabled for NOOP (they normally are not), otherwise the default sound.
struct SystemAlarmNotifier: AlarmNotifying {
    func postWake(title: String, body: String) async -> AlarmNotificationOutcome {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: break
        case .denied: return .notAuthorized("denied")
        case .notDetermined: return .notAuthorized("not determined")
        default: return .notAuthorized("status \(settings.authorizationStatus.rawValue)")
        }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let critical = settings.criticalAlertSetting == .enabled
        c.sound = critical ? .defaultCritical : .default
        c.interruptionLevel = .timeSensitive
        do {
            try await center.add(UNNotificationRequest(identifier: "noop.alarm.\(UUID().uuidString)", content: c, trigger: nil))
            return .submitted(critical: critical)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Durable alarm history. WhoopStore conforms (AlarmHistoryStore.swift).
protocol AlarmHistorySink: Sendable {
    func appendAlarmEvents(_ rows: [AlarmEventRow]) async throws -> Int
    func alarmEvents(since: Double, limit: Int) async throws -> [AlarmEventRow]
    func setAlarmAnnotation(_ a: AlarmAnnotationRow) async throws
    func alarmAnnotations() async throws -> [AlarmAnnotationRow]
}
extension WhoopStore: AlarmHistorySink {}

// MARK: - Controller

/// Runs NOOP's wake alarms on this Mac.
///
/// Decision and delivery are separate. The decider (SmartWake.swift) says WHEN; an `AlarmDeliveryTransaction` makes the
/// strap ring and is only "strap reported vibration" when the strap's own events say so. The latest-time fallback is
/// kept until the occurrence is dismissed or its deadline has passed: an early buzz that fails, goes unconfirmed or
/// expires without dismissal re-arms the deadline on the strap's single slot (RUN consumes it) and the Mac notification
/// sounds again at the deadline. Every step is appended to the alarm history (WhoopStore v16).
///
/// The deadline is followed up: after it rings, NOOP checks back every `followUpInterval` and buzzes again (up to
/// `maxFollowUps`, within `followUpHorizon`) until the wearer dismisses it on the strap or taps "I'm awake". When the
/// strap's own stored alarm is expected to ring, a backup buzz goes out if the strap doesn't report ringing. A deadline
/// noticed more than `maxLateRing` late (Mac asleep, NOOP not running) is recorded as missed rather than rung hours late.
/// Mac sleep/wake and live-HR evidence around the window are recorded too, as diagnostics (not proof anyone woke).
///
/// Host-driven: the Mac must be awake and NOOP running for early wakes. During a wake window NOOP holds an idle-sleep
/// assertion and owns the realtime HR stream (released on decision, cancellation, deletion and errors).
@MainActor
final class AlarmController: ObservableObject {
    @Published private(set) var alarms: [AlarmSpec] = []
    @Published private(set) var capabilities = AlarmCapabilities()
    @Published private(set) var states: [String: AlarmState] = [:]
    @Published private(set) var next: AlarmOccurrence?
    /// Plain-language status for the UI.
    @Published private(set) var status: String?
    /// Newest-first alarm history (persisted rows plus any not yet saved).
    @Published private(set) var history: [AlarmEventRow] = []
    @Published private(set) var annotations: [String: String] = [:]
    /// Set when history could not be saved; alarms still ring.
    @Published private(set) var historyWarning: String?
    /// The early wake for `next` already happened and its deadline fallback is still armed (can be dismissed in-app).
    @Published private(set) var fallbackPending = false
    /// The deadline rang and NOOP will buzz again unless dismissed (can be dismissed in-app).
    @Published private(set) var followUpPending = false

    let policy: SmartWakePolicy
    private let defaults: UserDefaults
    private let now: () -> Date
    private let notifier: AlarmNotifying
    private var historySink: () async -> AlarmHistorySink?
    private weak var link: AlarmStrapLink?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var decider: SmartWakeDecider?
    private var buffer = WakeEvidenceBuffer()
    private var activity: NSObjectProtocol?
    private var holdsRealtime = false
    static let realtimeOwner = "alarm"

    /// Occurrences that are finished (dismissed, or their deadline passed): never scheduled again. Key `alarm.fired`.
    private var completed: Set<String>
    /// Occurrences whose early wake was attempted: never decided early again (survives restart).
    private var earlyAttempted: Set<String>
    private var delivery: AlarmDeliveryTransaction?
    /// Arm of the strap's single slot in flight: SET, then GET read-back, bound to one occurrence.
    private struct PendingArm { let key: String; let alarmId: String; let target: UInt32; let sentAt: Date; var setSeq: UInt8; var getSeq: UInt8? }
    private var pendingArm: PendingArm?
    /// The occurrence the strap slot is verified to hold.
    private var armedKey: String?
    /// Strap seconds each recent occurrence was stored for (to attribute STRAP_DRIVEN_ALARM_EXECUTED exactly).
    private var armedTargets: [String: UInt32]
    /// Do not touch the slot before this (the stored deadline may be ringing right now).
    private var slotHoldUntil: Date?
    /// Last strap-driven ring matched to an occurrence (for dismissal attribution).
    private var lastStrapRing: (key: String, at: Date)?
    private var pendingRows: [AlarmEventRow] = []
    private var flushing = false

    /// After a deadline: check back, and buzz again unless dismissed. Persisted (`alarm.followUp`) so a relaunch keeps it.
    private struct FollowUp: Codable, Equatable { let key: String; let deadline: Date; var attempts: Int; var nextCheck: Date }
    private var followUp: FollowUp? { didSet { followUpPending = followUp != nil } }
    /// Last tick time, to tell "NOOP wasn't ticking" (Mac asleep / app not running) in missed or late-deadline records.
    private var lastTickAt: Date?
    private var lastEvidenceSummaryAt: Date?
    private var hostObservers: [NSObjectProtocol] = []

    static let followUpInterval: TimeInterval = 180
    static let maxFollowUps = 3
    static let followUpHorizon: TimeInterval = 20 * 60
    /// The strap's stored alarm should report ringing by then; otherwise a backup buzz goes out.
    static let storedAlarmGrace: TimeInterval = 120
    /// A deadline first seen later than this is recorded as missed, not rung.
    static let maxLateRing: TimeInterval = 30 * 60
    static let evidenceSummaryInterval: TimeInterval = 300

    /// Sleeping-HR baseline for smart wake (with provenance), set by AppModel.
    var baseline: () -> WakeBaseline? = { nil }
    /// Tonight's sleep so far (synced, with freshness), set by AppModel.
    var sleepProgress: () -> SleepGoalProgress? = { nil }

    private static let ownsStrapAlarmKey = "alarm.ownsStrapAlarm"
    private static let alarmsKey = "alarm.specs", capsKey = "alarm.capabilities", firedKey = "alarm.fired"
    private static let earlyKey = "alarm.earlyAttempted", armedTargetsKey = "alarm.armedTargets", followUpKey = "alarm.followUp"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, notifier: AlarmNotifying? = nil,
         policy: SmartWakePolicy = .current, history: @escaping () async -> AlarmHistorySink? = { nil }) {
        self.defaults = defaults
        self.now = now
        self.notifier = notifier ?? SystemAlarmNotifier()
        self.policy = policy
        self.historySink = history
        alarms = (defaults.data(forKey: Self.alarmsKey)).flatMap { try? JSONDecoder().decode([AlarmSpec].self, from: $0) } ?? []
        capabilities = (defaults.data(forKey: Self.capsKey)).flatMap { try? JSONDecoder().decode(AlarmCapabilities.self, from: $0) }
            ?? AlarmCapabilities()
        completed = Set(defaults.stringArray(forKey: Self.firedKey) ?? [])
        earlyAttempted = Set(defaults.stringArray(forKey: Self.earlyKey) ?? [])
        armedTargets = (defaults.dictionary(forKey: Self.armedTargetsKey) as? [String: Int] ?? [:]).mapValues { UInt32(clamping: $0) }
        for a in alarms { states[a.id] = a.enabled ? .active : .canceled }
        followUp = defaults.data(forKey: Self.followUpKey).flatMap { try? JSONDecoder().decode(FollowUp.self, from: $0) }
        followUpPending = followUp != nil
        recordMissedFallbacks()
    }

    /// Early wakes whose deadline passed while NOOP wasn't running: the fallback never rang. Recorded, then finished.
    private func recordMissedFallbacks() {
        let t = now()
        for key in earlyAttempted.sorted() {
            guard let unix = key.split(separator: "@").last.flatMap({ Double($0) }), t.timeIntervalSince1970 > unix + 60 else { continue }
            record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": "missed",
                   "detail": "The latest-time alarm passed while NOOP wasn't running"], dedupe: "missed:\(key)")
            earlyAttempted.remove(key)
            completed.insert(key)
        }
        persist()
    }

    /// Capabilities verified live per firmware (docs/reverse-engineering/ALARM_CAPABILITIES.md). Anything else: unverified.
    static func verified(firmware: String?) -> AlarmCapabilities {
        var c = AlarmCapabilities()
        c.firmware = firmware
        if firmware == "50.43.1.0" {
            c.immediateVibration = .confirmed   // H02b/H07: SUCCESSFUL_PLAY + HAPTICS_FIRED, wearer dismissed by double tap
            c.alarmReadback = .confirmed        // H02b: GET returned the stored time
            c.onDeviceAlarm = Self.onDeviceAlarmVerified ? .confirmed : .unverified
        }
        return c
    }
    /// Set to true only once H04 shows a stored alarm firing with nothing connected.
    static let onDeviceAlarmVerified = true   // H04 (2026-11-02): STRAP_DRIVEN_ALARM_EXECUTED at the stored time with nothing connected

    /// Wire to the live strap. Capabilities follow the firmware Device Information reports, including when it is
    /// discovered or changes after attachment (a reconnect to a different firmware).
    func attach(live: LiveState, ble: BLEManager) {
        attach(link: ble)
        live.$deviceInfo.map { $0?.firmware }.removeDuplicates().sink { [weak self] fw in
            guard let self else { return }
            let c = Self.verified(firmware: fw)
            if c != self.capabilities { self.capabilities = c; self.persist(); self.syncDeviceAlarm() }
        }.store(in: &cancellables)
        ble.onAlarmEvent = { [weak self] e, isLive in self?.handle(event: e, live: isLive) }
        ble.onAlarmResponse = { [weak self] r in self?.handle(response: r) }
        ble.onRealtimeHR = { [weak self] o in self?.ingest(o) }
        ble.onLinkDropped = { [weak self] in self?.linkDropped() }
        // Mac sleep/wake around an alarm explains a late or missed ring (history only).
        let nc = NSWorkspace.shared.notificationCenter
        hostObservers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.hostPowerChanged(asleep: true) } },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.hostPowerChanged(asleep: false) } },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.tick(now: self.now()) }
        }
    }

    /// Link-only attach (tests).
    func attach(link: AlarmStrapLink) {
        self.link = link
        reschedule()
        loadHistory()
    }

    // MARK: editing

    func save(_ a: AlarmSpec) {
        if let i = alarms.firstIndex(where: { $0.id == a.id }) { alarms[i] = a } else { alarms.append(a) }
        // Host-driven alarms are "active" as soon as saved; "confirmed on device" is reserved for a verified strap alarm.
        states[a.id] = a.enabled ? .active : .canceled
        persist()
        cancelInFlight(for: a.id, reason: "edited")
        reschedule()
        BatteryMonitor.requestAuthorization()
    }

    func delete(_ id: String) {
        alarms.removeAll { $0.id == id }
        states[id] = nil
        persist()
        cancelInFlight(for: id, reason: "deleted")
        reschedule()
    }

    /// The wearer is up: finish the current occurrence's pending fallback or deadline follow-up (an in-app dismissal).
    func dismissPendingFallback() {
        if let f = followUp {
            record(AlarmHistoryKind.dismissal, f.key, ["source": "app"])
            if let d = delivery, d.occurrenceId == f.key { var c = d; let a = c.cancel(); delivery = c; apply(a, for: c); delivery = nil }
            followUp = nil
            persist()
            return
        }
        guard let o = next, fallbackPending else { return }
        let key = Self.key(o)
        record(AlarmHistoryKind.dismissal, key, ["source": "app"])
        _ = delivery?.cancel(); delivery = nil
        complete(o, key: key)
    }

    /// The wearer's own note on an occurrence ("felt it", …), stored apart from device evidence.
    func annotate(_ occurrenceId: String, label: String) {
        annotations[occurrenceId] = label
        let row = AlarmAnnotationRow(occurrenceId: occurrenceId, label: label, createdAt: now().timeIntervalSince1970)
        Task { @MainActor in
            do { try await self.historySink()?.setAlarmAnnotation(row) }
            catch { self.historyWarning = "Couldn't save your note (\(error.localizedDescription))." }
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(alarms) { defaults.set(d, forKey: Self.alarmsKey) }
        if let d = try? JSONEncoder().encode(capabilities) { defaults.set(d, forKey: Self.capsKey) }
        defaults.set(Array(completed.sorted().suffix(80)), forKey: Self.firedKey)
        defaults.set(Array(earlyAttempted.sorted().suffix(80)), forKey: Self.earlyKey)
        defaults.set(Dictionary(armedTargets.sorted { $0.key < $1.key }.suffix(20).map { ($0.key, Int($0.value)) }, uniquingKeysWith: { a, _ in a }),
                     forKey: Self.armedTargetsKey)
        if let f = followUp, let d = try? JSONEncoder().encode(f) { defaults.set(d, forKey: Self.followUpKey) }
        else { defaults.removeObject(forKey: Self.followUpKey) }
    }

    private func reschedule() {
        let n = upcoming(after: now())
        if n != next { decider = nil; buffer.reset(); endWindow() }
        next = n
        fallbackPending = n.map { earlyAttempted.contains(Self.key($0)) } ?? false
        syncDeviceAlarm()
    }

    /// The earliest occurrence that is not finished. After an early wake the same deadline is still ahead and still
    /// scheduled (its fallback), but a finished occurrence is skipped so the strap is never re-armed for it.
    private func upcoming(after t: Date) -> AlarmOccurrence? {
        alarms.compactMap { a -> AlarmOccurrence? in
            // Start from just before the window so an occurrence whose window is open (or whose fallback is pending) is kept.
            var o = AlarmPlanner.next(a, after: t)
            while let x = o, completed.contains(Self.key(x)) { o = AlarmPlanner.next(a, after: x.deadline) }
            return o
        }.min { $0.deadline < $1.deadline }
    }

    static func key(_ o: AlarmOccurrence) -> String { "\(o.alarmId)@\(Int(o.deadline.timeIntervalSince1970))" }

    // MARK: strap slot (deadline) — only when on-strap firing is verified

    /// Store the next deadline on the strap: SET, then (after SET's answer) GET to read it back. Never claims "on strap"
    /// without the read-back. Never while a delivery is using the slot, or while the stored deadline may be ringing.
    func syncDeviceAlarm() {
        guard capabilities.onDeviceAlarm == .confirmed, let link, link.alarmLinkReady else { return }
        if let d = delivery, d.isOpen, d.outcome == nil { return }   // a delivery is still using the slot
        if let h = slotHoldUntil, now() < h { return }
        guard let n = next else {
            // Only clear an alarm NOOP itself stored; never touch one set by another app.
            if defaults.bool(forKey: Self.ownsStrapAlarmKey), link.sendAlarmCommand(.disableAll) != nil {
                defaults.set(false, forKey: Self.ownsStrapAlarmKey)
                armedKey = nil
                record(AlarmHistoryKind.slot, nil, ["action": "cleared"])
            }
            return
        }
        // Too close to the deadline to arm safely: the Mac fallback covers it.
        guard n.deadline.timeIntervalSince(now()) > 20, let c = link.alarmClock else {
            if link.alarmClock == nil { states[n.alarmId] = .unknown }
            return
        }
        let key = Self.key(n)
        if pendingArm?.key == key { return }
        let target = UInt32(clamping: Int(c.deviceTime(fromHost: n.deadline.timeIntervalSince1970).rounded()))
        guard let seq = link.sendAlarmCommand(.set(strapSeconds: target)) else { states[n.alarmId] = .unknown; return }
        defaults.set(true, forKey: Self.ownsStrapAlarmKey)
        armedKey = nil
        armedTargets[key] = target
        pendingArm = PendingArm(key: key, alarmId: n.alarmId, target: target, sentAt: now(), setSeq: seq, getSeq: nil)
        states[n.alarmId] = .pendingSync
        record(AlarmHistoryKind.commandRequested, key, ["command": "set", "purpose": "deadline", "seq": Int(seq), "strapTime": Int(target)])
        persist()
    }

    // MARK: strap answers and events

    func handle(response r: Whoop5CommandResponse) {
        let at = now()
        let answer: AlarmCommandAnswer = !r.isFinal ? .pending
            : r.result == .success ? .success
            : .rejected(Whoop5Alarm.status(r).map { "\($0)" } ?? "\(r.result)")
        let kind: AlarmCommandKind? = switch r.command { case 66: .set; case 67: .get; case 68: .run; case 69: .disable; default: nil }
        guard let kind else { return }

        // The deadline arm (SET → GET), matched by sequence number.
        if var p = pendingArm {
            if kind == .set, r.appSeq == p.setSeq {
                switch answer {
                case .pending: return
                case .success:
                    record(AlarmHistoryKind.commandAcknowledged, p.key, ["command": "set", "seq": Int(r.appSeq)])
                    if let g = link?.sendAlarmCommand(.get) { p.getSeq = g; pendingArm = p }
                    else { pendingArm = nil; states[p.alarmId] = .unknown }
                    return
                case .rejected(let why):
                    record(AlarmHistoryKind.commandFailed, p.key, ["command": "set", "detail": why])
                    pendingArm = nil
                    states[p.alarmId] = .failed
                    status = "The strap refused the alarm (\(why)). It will ring on this Mac."
                    return
                }
            }
            if kind == .get, r.appSeq == p.getSeq, r.isFinal {
                let stored = Whoop5Alarm.storedTime(r)
                let ok = stored == p.target
                record(ok ? AlarmHistoryKind.commandAcknowledged : AlarmHistoryKind.commandFailed, p.key,
                       ["command": "get", "stored": stored.map { Int($0) } ?? 0, "expected": Int(p.target)])
                pendingArm = nil
                if next.map(Self.key) == p.key {
                    states[p.alarmId] = ok ? .confirmedOnDevice : .failed
                    armedKey = ok ? p.key : nil
                }
                return
            }
        }
        // The delivery transaction (SET → RUN), matched by command and sequence number.
        if var d = delivery {
            let actions = d.handle(command: kind, seq: r.appSeq, answer: answer, at: at)
            delivery = d
            apply(actions, for: d)
        }
    }

    /// Strap alarm / haptics events. Live ones may update the current delivery; history replays only enrich history at
    /// their original time. Anything not attributable stays unmatched.
    func handle(event e: Whoop5Event, live: Bool) {
        let received = now()
        let clock = link?.alarmClock
        let mapped = clock.map { Date(timeIntervalSince1970: $0.hostTime(fromDevice: Double(e.unix) + Double(e.subseconds) / 32768)) }
        let signal: AlarmStrapSignal? = switch e.kind {
        case .appAlarmExecuted: .appAlarmExecuted
        case .strapAlarmExecuted: .strapAlarmExecuted
        case .hapticsFired: .hapticsFired
        case .hapticsTerminated: .hapticsTerminated(reason: e.body.count >= 2 ? Int(e.body[1]) : nil)
        case .doubleTap: .doubleTap
        default: nil
        }
        var occurrence: String?
        var follow: [AlarmDeliveryTransaction.Action] = []
        // Exact attribution of the strap's own alarm firing: its time equals a time NOOP stored (±2 s).
        if e.kind == .strapAlarmExecuted, let k = armedTargets.first(where: { abs(Int($0.value) - e.unix) <= 2 })?.key { occurrence = k }
        if live, let signal, let t = mapped {
            if var d = delivery, let actions = d.handle(signal: signal, at: t) {
                delivery = d
                occurrence = d.occurrenceId
                follow = actions
            } else if signal == .strapAlarmExecuted, let k = occurrence {
                lastStrapRing = (k, t)
                if next.map(Self.key) == k || completed.contains(k) { slotHoldUntil = nil }
            } else if case .hapticsTerminated(let reason) = signal, let r = lastStrapRing, t.timeIntervalSince(r.at) < 600, t >= r.at {
                occurrence = r.key
                if reason == 2 {
                    record(AlarmHistoryKind.dismissal, r.key, ["source": "strap"], at: t)
                    if followUp?.key == r.key { followUp = nil; persist() }
                }
                lastStrapRing = nil
            } else if signal == .doubleTap, let r = lastStrapRing, t.timeIntervalSince(r.at) < 600, t >= r.at {
                occurrence = r.key
            }
        }
        let row = AlarmEventRow(
            occurrenceId: occurrence, kind: AlarmHistoryKind.strapEvent, recordedAt: received.timeIntervalSince1970,
            deviceTs: e.unix, mappedHostTs: mapped?.timeIntervalSince1970, receivedAt: received.timeIntervalSince1970,
            provenance: live ? AlarmEventRow.Provenance.live : AlarmEventRow.Provenance.history,
            dedupeKey: "strap:\(e.number):\(e.unix):\(e.subseconds)",
            payload: AlarmHistory.payload(["event": e.kind.name, "number": e.number, "matched": occurrence != nil]))
        append(row)
        if let d = delivery { apply(follow.filter { if case .strapSignal = $0 { return false }; return true }, for: d) }
        if live, e.kind == .strapAlarmExecuted {
            status = "The strap's own alarm rang at \((mapped ?? received).formatted(date: .omitted, time: .shortened))"
        }
    }

    func linkDropped() {
        if var d = delivery { let a = d.linkDropped(); delivery = d; apply(a, for: d) }
        if let p = pendingArm {
            record(AlarmHistoryKind.commandFailed, p.key, ["command": p.getSeq == nil ? "set" : "get", "detail": "disconnected"])
            pendingArm = nil
            states[p.alarmId] = .unknown
        }
        armedKey = nil
    }

    // MARK: evidence

    func ingest(_ o: HRObservation) {
        guard let n = next, now() >= n.windowStart.addingTimeInterval(-600) else { return }
        buffer.ingest(o, now: now())
    }

    // MARK: running

    func tick(now t: Date) {
        if !pendingRows.isEmpty { flush() }   // retry history that couldn't be saved
        // Timeouts first.
        if var d = delivery { let a = d.tick(now: t); delivery = d; apply(a, for: d) }
        if let p = pendingArm, t.timeIntervalSince(p.sentAt) > AlarmDeliveryTransaction.responseTimeout {
            record(AlarmHistoryKind.commandTimedOut, p.key, ["command": p.getSeq == nil ? "set" : "get"])
            pendingArm = nil
            states[p.alarmId] = .unknown
        }
        // Follow-up first: when a stored alarm's hold ends unreported, the backup buzz takes the slot before re-arming.
        followUpTick(t)
        if let h = slotHoldUntil, t >= h { slotHoldUntil = nil; syncDeviceAlarm() }
        let previousTick = lastTickAt
        lastTickAt = t

        guard let o = next, let spec = alarms.first(where: { $0.id == o.alarmId }) else { endWindow(); return }
        let key = Self.key(o)
        if completed.contains(key) { reschedule(); return }
        // First noticed long after the deadline (Mac asleep, NOOP not running): a missed alarm, not a ring hours late.
        if t.timeIntervalSince(o.deadline) > Self.maxLateRing { missed(o, at: t, previousTick: previousTick); return }
        if t >= o.windowStart.addingTimeInterval(-600) { beginWindow(o, spec: spec); summarizeEvidence(o, now: t) }
        if decider == nil { decider = SmartWakeDecider(occurrence: o, mode: spec.mode, policy: policy) }
        let windows = buffer.windows(from: o.windowStart.addingTimeInterval(-policy.windowSeconds), endingBy: t,
                                     length: policy.windowSeconds, minSamples: policy.minSamplesPerWindow)
        if earlyAttempted.contains(key) {
            // Early wake already happened: only the deadline fallback remains.
            if t >= o.deadline {
                decide(o, spec: spec, record: WakeDecisionRecord(
                    trigger: .deadline, decidedAt: t, policyVersion: policy.version, threshold: nil, score: nil,
                    sustainedSeconds: nil, evidenceFrom: nil, evidenceTo: nil, baselineBPM: nil, baselineSource: nil,
                    baselineAgeHours: nil, evidenceQuality: "fallback", reason: "Latest wake time (fallback after early wake)"), early: false)
            }
            return
        }
        switch decider!.step(now: t, windows: windows, baseline: baseline(), sleepGoal: sleepProgress()) {
        case .wait:
            if t >= o.windowStart, spec.mode != .exact {
                status = "Wake window open — watching heart rate (\(decider!.quality.lowercased())); latest \(o.deadline.formatted(date: .omitted, time: .shortened))"
            }
        case .fireEarly(let rec): decide(o, spec: spec, record: rec, early: true)
        case .fireAtDeadline(let rec): decide(o, spec: spec, record: rec, early: false)
        }
    }

    private func beginWindow(_ o: AlarmOccurrence, spec: AlarmSpec) {
        let key = Self.key(o)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                            reason: "NOOP wake alarm window")
            record(AlarmHistoryKind.scheduled, key, scheduledPayload(o, spec: spec), dedupe: "scheduled:\(key)")
        }
        if spec.mode != .exact, !holdsRealtime, !earlyAttempted.contains(key), let link {
            link.acquireRealtime(owner: Self.realtimeOwner)
            holdsRealtime = true
        }
    }

    private func releaseRealtime() {
        guard holdsRealtime else { return }
        link?.releaseRealtime(owner: Self.realtimeOwner)
        holdsRealtime = false
    }

    private func endWindow() {
        releaseRealtime()
        lastEvidenceSummaryAt = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    /// The decider fired: record why, notify the Mac, and start strap delivery where verified. Not a delivery claim.
    private func decide(_ o: AlarmOccurrence, spec: AlarmSpec, record rec: WakeDecisionRecord, early: Bool) {
        let key = Self.key(o)
        let enc = (try? JSONEncoder().encode(rec)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        record(AlarmHistoryKind.scheduled, key, scheduledPayload(o, spec: spec), dedupe: "scheduled:\(key)")
        record(AlarmHistoryKind.decision, key, enc, dedupe: "decision:\(key):\(early ? "early" : "deadline")")
        releaseRealtime()
        states[o.alarmId] = .triggered
        let time = now().formatted(date: .omitted, time: .shortened)

        // The strap's verified stored alarm rings by itself at the deadline: don't buzz on top of it, and hold the slot
        // until it reports ringing (or two minutes pass) so arming the next alarm can't overwrite it mid-ring.
        let strapRingsItself = !early && armedKey == key
        var requested = false
        if strapRingsItself {
            slotHoldUntil = now().addingTimeInterval(Self.storedAlarmGrace)
            record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": "strapStoredAlarm", "detail": "Stored alarm expected to ring at the deadline"])
        } else {
            requested = ringNow(key: key, early: early)
        }
        let late = now().timeIntervalSince(o.deadline)
        if !early, late > 60 {
            record(AlarmHistoryKind.host, key, ["event": "lateDeadline", "lateSeconds": Int(late),
                   "lastTickAt": lastTickAt?.timeIntervalSince1970 ?? 0])
        }
        if !early {
            // Keep after it until dismissed: a stored alarm that doesn't report ringing gets a backup buzz sooner.
            followUp = FollowUp(key: key, deadline: o.deadline, attempts: 0,
                                nextCheck: now().addingTimeInterval(strapRingsItself ? Self.storedAlarmGrace : Self.followUpInterval))
        }
        if !strapRingsItself, !requested {
            record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": "macOnly", "detail": "Strap not reachable for a buzz"])
        }
        status = "Rang at \(time)\(early ? " (early: \(rec.reason))" : "")"
            + (strapRingsItself ? " — strap alarm" : requested ? " — strap buzz requested" : " — on this Mac only (strap not connected)")

        let body = early ? "\(rec.reason). Your latest wake time is \(o.deadline.formatted(date: .omitted, time: .shortened))."
                         : "It's your wake-up time."
        Task { @MainActor in
            let outcome = await self.notifier.postWake(title: "Time to wake up", body: body)
            self.record(AlarmHistoryKind.notification, key, ["outcome": outcome.historyValue])
            if case .submitted = outcome {} else { self.status = (self.status ?? "") + " · Mac notification not shown (\(outcome.historyValue))" }
        }

        if early {
            earlyAttempted.insert(key)
            fallbackPending = true
            persist()
            if !requested { syncDeviceAlarm() }   // nothing touched the slot: keep (or restore) the deadline there
        } else {
            complete(o, key: key)
        }
    }

    /// Start a ring-now delivery (SET now+60 → RUN) where immediate vibration is verified. False when it couldn't go out.
    @discardableResult
    private func ringNow(key: String, early: Bool, purpose: String = "ring-now") -> Bool {
        guard capabilities.immediateVibration == .confirmed, let link, link.alarmLinkReady, let c = link.alarmClock else { return false }
        if var d = delivery { _ = d.cancel(); delivery = nil }
        let strapNow = c.deviceTime(fromHost: now().timeIntervalSince1970)
        let target = UInt32(clamping: Int(strapNow.rounded()) + 60)
        guard let seq = link.sendAlarmCommand(.set(strapSeconds: target)) else { return false }
        delivery = AlarmDeliveryTransaction(occurrenceId: key, early: early, setSeq: seq, setSentAt: now())
        armedKey = nil
        record(AlarmHistoryKind.commandRequested, key, ["command": "set", "purpose": purpose, "seq": Int(seq), "strapTime": Int(target)])
        return true
    }

    /// Deadline follow-up: re-buzz until dismissed, within limits. Waits while something is still ringing.
    private func followUpTick(_ t: Date) {
        guard var f = followUp, t >= f.nextCheck else { return }
        if f.attempts >= Self.maxFollowUps || t.timeIntervalSince(f.deadline) > Self.followUpHorizon {
            record(AlarmHistoryKind.followUp, f.key, ["action": "stopped", "attempts": f.attempts,
                   "detail": "No dismissal after \(f.attempts) extra buzz(es)"])
            followUp = nil; persist(); return
        }
        if let d = delivery, d.isOpen,
           d.outcome == nil || (d.step == .strapReported && t.timeIntervalSince(d.hapticsAt ?? d.runSentAt ?? d.setSentAt) < Self.followUpInterval) {
            f.nextCheck = t.addingTimeInterval(30); followUp = f; return   // still delivering or ringing
        }
        if pendingArm != nil { f.nextCheck = t.addingTimeInterval(15); followUp = f; return }   // let the slot arm settle
        if let r = lastStrapRing, r.key == f.key, t.timeIntervalSince(r.at) < Self.followUpInterval {
            f.nextCheck = r.at.addingTimeInterval(Self.followUpInterval); followUp = f; return   // strap's own alarm is ringing
        }
        f.attempts += 1
        f.nextCheck = t.addingTimeInterval(Self.followUpInterval)
        followUp = f
        persist()
        let storedRang = lastStrapRing?.key == f.key || history.contains {
            $0.occurrenceId == f.key && $0.kind == AlarmHistoryKind.strapEvent
                && AlarmHistory.fields($0.payload)["event"] as? String == "STRAP_DRIVEN_ALARM_EXECUTED"
        }
        let requested = ringNow(key: f.key, early: false, purpose: "follow-up")
        record(AlarmHistoryKind.followUp, f.key, ["action": "buzz", "attempt": f.attempts, "requested": requested,
               "detail": requested ? "Not dismissed yet: buzzing again" : "Not dismissed yet; strap not reachable",
               "storedAlarmReported": storedRang])
        let key = f.key
        Task { @MainActor in
            let outcome = await self.notifier.postWake(title: "Time to wake up", body: "Your alarm hasn't been dismissed yet.")
            self.record(AlarmHistoryKind.notification, key, ["outcome": outcome.historyValue, "followUp": f.attempts])
        }
    }

    /// The deadline passed unseen: record it as missed (with what NOOP knows about why) and finish the occurrence.
    private func missed(_ o: AlarmOccurrence, at t: Date, previousTick: Date?) {
        let key = Self.key(o)
        let gap = previousTick.map { Int(t.timeIntervalSince($0)) }
        let strapHeld = armedKey == key || armedTargets[key] != nil && states[o.alarmId] == .confirmedOnDevice
        record(AlarmHistoryKind.deliveryOutcome, key, [
            "outcome": "missed",
            "detail": "NOOP first saw this alarm \(Int(t.timeIntervalSince(o.deadline) / 60)) min after its latest time"
                + (gap.map { $0 > 120 ? " (no activity for \($0 / 60) min: Mac asleep or NOOP not running)" : "" } ?? " (NOOP had just started)"),
            "strapAlarmStored": strapHeld], dedupe: "missed:\(key)")
        status = "Missed the \(o.deadline.formatted(date: .omitted, time: .shortened)) alarm"
            + (strapHeld ? " on this Mac — the strap's own alarm was set" : " — this Mac wasn't running NOOP at the time")
        complete(o, key: key)
    }

    /// Mac sleep/wake, recorded against the next alarm when it is within 12 h (diagnostics only).
    func hostPowerChanged(asleep: Bool) {
        guard let o = next, abs(o.deadline.timeIntervalSince(now())) < 12 * 3600 else { return }
        record(AlarmHistoryKind.host, Self.key(o), ["event": asleep ? "macSleep" : "macWake"])
        if !asleep { tick(now: now()) }
    }

    /// Every few minutes around the window: how much live HR actually arrived (sync history is never live evidence).
    private func summarizeEvidence(_ o: AlarmOccurrence, now t: Date) {
        if let last = lastEvidenceSummaryAt, t.timeIntervalSince(last) < Self.evidenceSummaryInterval { return }
        lastEvidenceSummaryAt = t
        let recent = buffer.samples.filter { t.timeIntervalSince($0.at) <= Self.evidenceSummaryInterval }
        record(AlarmHistoryKind.evidence, Self.key(o), [
            "liveSamples": recent.count,
            "newestAgeSeconds": recent.last.map { Int(t.timeIntervalSince($0.at)) } ?? -1,
            "linkReady": link?.alarmLinkReady ?? false,
            "streamHeld": holdsRealtime,
            "rejected": buffer.rejections.values.reduce(0, +)])
    }

    /// Act on delivery transaction actions: history rows, RUN after SET, and slot reconciliation once settled.
    private func apply(_ actions: [AlarmDeliveryTransaction.Action], for d: AlarmDeliveryTransaction) {
        let key = d.occurrenceId
        for a in actions {
            switch a {
            case .sendRun:
                if let seq = link?.sendAlarmCommand(.run) {
                    delivery?.runSent(seq: seq, at: now())
                    record(AlarmHistoryKind.commandRequested, key, ["command": "run", "seq": Int(seq)])
                } else if var t = delivery {
                    let more = t.linkDropped(); delivery = t; apply(more, for: t)
                }
            case .acknowledged(let k):
                record(AlarmHistoryKind.commandAcknowledged, key, ["command": k.rawValue])
            case .rejected(let k, let why):
                record(AlarmHistoryKind.commandFailed, key, ["command": k.rawValue, "detail": why])
            case .timedOut(let k):
                record(AlarmHistoryKind.commandTimedOut, key, ["command": k.rawValue])
            case .strapSignal:
                break   // the strap event row itself is recorded by handle(event:)
            case .dismissed(let source, let at):
                record(AlarmHistoryKind.dismissal, key, ["source": source], at: at)
                if followUp?.key == key { followUp = nil; persist() }
                if let o = next, Self.key(o) == key, !completed.contains(key) { complete(o, key: key) }
            case .terminated(let reason, let at):
                record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": "terminated", "detail": "Haptics ended (reason \(reason.map(String.init) ?? "?")) without a dismissal"], at: at)
                syncDeviceAlarm()   // not dismissed: put the deadline fallback back on the strap
            case .settled(let outcome):
                switch outcome {
                case .strapReported:
                    record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": "strapReported"])
                    status = (status ?? "").replacingOccurrences(of: " — strap buzz requested", with: " — strap reported vibration")
                case .unconfirmed(let why), .failed(let why):
                    let isFail: Bool = { if case .failed = outcome { return true }; return false }()
                    record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": isFail ? "failed" : "unconfirmed", "detail": why])
                    status = (status ?? "") + " · \(why); the latest-time alarm stays set"
                    syncDeviceAlarm()   // RUN may have consumed (or SET overwritten) the slot: restore the deadline
                case .canceled:
                    record(AlarmHistoryKind.deliveryOutcome, key, ["outcome": "canceled"])
                }
            }
        }
        if let t = delivery, !t.isOpen { delivery = nil; syncDeviceAlarm() }
    }

    /// The occurrence is finished: never scheduled again; one-off alarms switch off.
    private func complete(_ o: AlarmOccurrence, key: String) {
        completed.insert(key)
        earlyAttempted.remove(key)
        fallbackPending = false
        endWindow()
        if let i = alarms.firstIndex(where: { $0.id == o.alarmId }), alarms[i].weekdays.isEmpty {
            alarms[i].enabled = false
            states[o.alarmId] = .canceled
        } else if states[o.alarmId] != .canceled {
            states[o.alarmId] = .active
        }
        persist()
        reschedule()
    }

    /// An edited / deleted alarm: cancel its delivery and release the stream (history keeps what happened).
    private func cancelInFlight(for alarmId: String, reason: String) {
        if var d = delivery, d.occurrenceId.hasPrefix(alarmId + "@") {
            let a = d.cancel(); delivery = d; apply(a, for: d); delivery = nil
        }
        if let p = pendingArm, p.alarmId == alarmId { pendingArm = nil }
        if next?.alarmId == alarmId { endWindow(); decider = nil; buffer.reset() }
    }

    private func scheduledPayload(_ o: AlarmOccurrence, spec: AlarmSpec) -> [String: Any] {
        ["alarmId": spec.id, "hour": spec.hour, "minute": spec.minute, "weekdays": spec.weekdays.sorted(),
         "mode": AlarmsTextFormat.mode(spec.mode), "windowStart": o.windowStart.timeIntervalSince1970,
         "deadline": o.deadline.timeIntervalSince1970, "timeZone": TimeZone.current.identifier, "policyVersion": policy.version]
    }

    // MARK: history persistence

    private func record(_ kind: String, _ occurrence: String?, _ payload: [String: Any], at: Date? = nil, dedupe: String? = nil) {
        let t = now().timeIntervalSince1970
        append(AlarmEventRow(occurrenceId: occurrence, kind: kind, recordedAt: t, mappedHostTs: at?.timeIntervalSince1970,
                             receivedAt: t, provenance: AlarmEventRow.Provenance.host, dedupeKey: dedupe,
                             payload: AlarmHistory.payload(payload)))
    }

    /// Show at once, persist in the background. A failure is surfaced and retried with the next write; it never blocks
    /// or delays delivery.
    private func append(_ row: AlarmEventRow) {
        if let k = row.dedupeKey, history.contains(where: { $0.dedupeKey == k }) || pendingRows.contains(where: { $0.dedupeKey == k }) { return }
        history.insert(row, at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        pendingRows.append(row)
        if pendingRows.count > 1000 { pendingRows.removeFirst(pendingRows.count - 1000) }
        flush()
    }

    private func flush() {
        guard !flushing, !pendingRows.isEmpty else { return }
        flushing = true
        let rows = pendingRows
        Task { @MainActor in
            defer { self.flushing = false }
            guard let sink = await self.historySink() else {
                self.historyWarning = "Alarm history isn't being saved (no local store). Alarms still ring."
                return
            }
            do {
                _ = try await sink.appendAlarmEvents(rows)
                self.pendingRows.removeFirst(min(rows.count, self.pendingRows.count))
                self.historyWarning = nil
                if !self.pendingRows.isEmpty { self.flush() }
            } catch {
                self.historyWarning = "Alarm history couldn't be saved (\(error.localizedDescription)). Alarms still ring; NOOP will retry."
            }
        }
    }

    func loadHistory() {
        Task { @MainActor in
            guard let sink = await self.historySink() else { return }
            do {
                let stored = try await sink.alarmEvents(since: self.now().timeIntervalSince1970 - 60 * 86_400, limit: 1000)
                let keys = Set(stored.compactMap(\.dedupeKey))
                let unsaved = self.pendingRows.filter { $0.dedupeKey.map { !keys.contains($0) } ?? true }
                self.history = (unsaved + stored).sorted { $0.recordedAt > $1.recordedAt }
                self.annotations = Dictionary(try await sink.alarmAnnotations().map { ($0.occurrenceId, $0.label) }, uniquingKeysWith: { _, b in b })
            } catch {
                self.historyWarning = "Couldn't read alarm history (\(error.localizedDescription))."
            }
        }
    }

    /// Warnings to show next to an active alarm. Never a reassurance the alarm will work.
    func warnings(battery: Int?, connected: Bool) -> [String] {
        guard alarms.contains(where: \.enabled) else { return [] }
        var w: [String] = []
        if capabilities.onDeviceAlarm != .confirmed {
            w.append(capabilities.immediateVibration == .confirmed
                ? "The strap buzzes when NOOP tells it to, but an alarm stored on the strap is not yet verified to ring by itself. Keep this Mac awake, plugged in, lid open, with NOOP running and the strap connected. Keep a conventional alarm as backup."
                : "The strap can't be made to vibrate on this firmware yet. The alarm sounds on this Mac: keep it awake with NOOP running, and keep a conventional alarm as backup.")
        }
        if let b = battery, b < 20 { w.append("Strap battery is \(b)%: charge it before sleeping so smart wake has heart-rate data.") }
        if !connected { w.append("Strap not connected: smart wake can't see your heart rate and will ring at the latest time.") }
        if let h = historyWarning { w.append(h) }
        return w
    }
}

/// Shared alarm wording (history snapshots and the Alarms tab).
enum AlarmsTextFormat {
    static func mode(_ m: AlarmSpec.Mode) -> String {
        switch m {
        case .exact: return "Exact time"
        case .smart(let w): return "Smart wake, \(w)-min window"
        case .sleepGoal(let p, let w): return "Sleep goal \(p)%, \(w)-min window"
        }
    }
}
