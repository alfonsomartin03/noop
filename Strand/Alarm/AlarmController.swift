import Foundation
import Combine
import UserNotifications
import StrandAnalytics
import WhoopProtocol

/// Runs NOOP's wake alarms on this Mac.
///
/// What actually wakes the user is decided by verified capabilities only (`AlarmCapabilities`):
/// - strap vibration from NOOP: used only once confirmed on this strap (not yet — see ALARM_CAPABILITIES.md);
/// - always: a sounding macOS notification at the decided time, so the alarm never depends on the strap alone.
/// It is host-driven: the Mac must be awake and NOOP running. During a wake window NOOP holds an idle-sleep
/// assertion and turns on the strap's realtime heart rate to judge how awake the wearer looks.
@MainActor
final class AlarmController: ObservableObject {
    @Published private(set) var alarms: [AlarmSpec] = []
    @Published private(set) var capabilities = AlarmCapabilities()
    @Published private(set) var states: [String: AlarmState] = [:]
    @Published private(set) var next: AlarmOccurrence?
    /// Plain-language status for the UI ("Window open, waiting for a lighter moment", "Rang at 06:42 (early)").
    @Published private(set) var status: String?

    private let defaults: UserDefaults
    private var timer: Timer?
    private var decider: SmartWakeDecider?
    private var activity: NSObjectProtocol?
    private var firedOccurrences: Set<String>
    private weak var live: LiveState?
    private weak var ble: BLEManager?
    /// Sleeping-HR reference for the wake heuristic (recent resting HR), set by AppModel.
    var sleepingHR: () -> Double? = { nil }
    /// Minutes asleep so far tonight and the sleep need (for sleep-goal alarms), set by AppModel.
    var sleepProgress: () -> (asleep: Double, need: Double)? = { nil }

    /// True while the strap's alarm slot holds an alarm NOOP stored (so NOOP may clear it).
    private static let ownsStrapAlarmKey = "alarm.ownsStrapAlarm"
    private static let alarmsKey = "alarm.specs", capsKey = "alarm.capabilities", firedKey = "alarm.fired"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alarms = (defaults.data(forKey: Self.alarmsKey)).flatMap { try? JSONDecoder().decode([AlarmSpec].self, from: $0) } ?? []
        capabilities = (defaults.data(forKey: Self.capsKey)).flatMap { try? JSONDecoder().decode(AlarmCapabilities.self, from: $0) }
            ?? AlarmCapabilities()
        firedOccurrences = Set(defaults.stringArray(forKey: Self.firedKey) ?? [])
        for a in alarms { states[a.id] = a.enabled ? .active : .canceled }
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

    func attach(live: LiveState, ble: BLEManager) {
        self.live = live
        self.ble = ble
        capabilities = Self.verified(firmware: live.deviceInfo?.firmware)
        ble.onAlarmEvent = { [weak self] e in self?.handle(event: e) }
        ble.onAlarmResponse = { [weak self] r in self?.handle(response: r) }
        reschedule()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(now: Date()) }
        }
    }

    // MARK: editing

    func save(_ a: AlarmSpec) {
        if let i = alarms.firstIndex(where: { $0.id == a.id }) { alarms[i] = a } else { alarms.append(a) }
        // Host-driven alarms are "active" as soon as saved; "confirmed on device" is reserved for a verified strap alarm.
        states[a.id] = a.enabled ? .active : .canceled
        persist()
        reschedule()
        BatteryMonitor.requestAuthorization()
    }

    func delete(_ id: String) {
        alarms.removeAll { $0.id == id }
        states[id] = nil
        persist()
        reschedule()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(alarms) { defaults.set(d, forKey: Self.alarmsKey) }
        if let d = try? JSONEncoder().encode(capabilities) { defaults.set(d, forKey: Self.capsKey) }
        defaults.set(Array(firedOccurrences.suffix(50)), forKey: Self.firedKey)
    }

    private func reschedule() {
        next = AlarmPlanner.nextAcross(alarms, after: Date())
        decider = nil
        syncDeviceAlarm()
    }

    // MARK: strap alarm (deadline) sync — only when on-strap firing is verified

    private var pendingDeviceTarget: UInt32?

    /// Store the next deadline on the strap and verify it by read-back. Never claims "on strap" without the read-back.
    func syncDeviceAlarm() {
        guard capabilities.onDeviceAlarm == .confirmed, let ble, let live, live.bonded else { return }
        guard let n = next else {
            // Only clear an alarm NOOP itself stored; never touch one set by another app.
            if defaults.bool(forKey: Self.ownsStrapAlarmKey) { ble.clearStrapAlarms(); defaults.set(false, forKey: Self.ownsStrapAlarmKey) }
            return
        }
        guard let c = live.clock, ble.armWhoop5Alarm(at: n.deadline) else { states[n.alarmId] = .unknown; return }
        defaults.set(true, forKey: Self.ownsStrapAlarmKey)
        pendingDeviceTarget = UInt32(clamping: Int(c.deviceTime(fromHost: n.deadline.timeIntervalSince1970).rounded()))
        states[n.alarmId] = .pendingSync
        ble.readStrapAlarm()
    }

    private func handle(response r: Whoop5CommandResponse) {
        guard r.isFinal, let n = next else { return }
        switch r.command {
        case 67 where pendingDeviceTarget != nil:
            let stored = Whoop5Alarm.storedTime(r)
            states[n.alarmId] = stored == pendingDeviceTarget ? .confirmedOnDevice : .failed
            pendingDeviceTarget = nil
        case 66 where r.result != .success:
            states[n.alarmId] = .failed
            status = "The strap refused the alarm (\(Whoop5Alarm.status(r).map { "\($0)" } ?? "\(r.result)")). It will ring on this Mac."
        default: break
        }
    }

    private func handle(event e: Whoop5Event) {
        switch e.kind {
        case .hapticsFired:
            if let s = status, s.hasPrefix("Rang") { status = s.replacingOccurrences(of: " — strap buzz requested", with: " — strap buzzed (reported by the strap)") }
        case .doubleTap, .hapticsTerminated where e.body.count >= 2 && e.body[1] == 2:
            for (id, st) in states where st == .triggered { states[id] = .dismissed }
            status = (status ?? "") + " · dismissed on the strap"
        case .strapAlarmExecuted:
            status = "The strap's own alarm rang at \(Date().formatted(date: .omitted, time: .shortened))"
        default: break
        }
    }

    // MARK: running

    private func occurrenceKey(_ o: AlarmOccurrence) -> String { "\(o.alarmId)@\(Int(o.deadline.timeIntervalSince1970))" }

    func tick(now: Date) {
        guard let o = next, let spec = alarms.first(where: { $0.id == o.alarmId }) else { endWindow(); return }
        if firedOccurrences.contains(occurrenceKey(o)) {   // already rang (e.g. before a restart): never twice
            reschedule(); return
        }
        // Hold the Mac awake from 10 minutes before the window (idle sleep only; a closed lid still sleeps).
        if now >= o.windowStart.addingTimeInterval(-600) { beginWindow(o) }
        if decider == nil { decider = SmartWakeDecider(occurrence: o, mode: spec.mode) }
        let ev = currentEvidence(now)
        let progress = sleepProgress()
        switch decider!.step(now: now, evidence: ev, asleepMinutesSoFar: progress?.asleep, needMinutes: progress?.need) {
        case .wait:
            if now >= o.windowStart, spec.mode != .exact { status = "Wake window open — waiting for a lighter moment (latest \(o.deadline.formatted(date: .omitted, time: .shortened)))" }
        case .fireEarly(let reason):
            ring(o, early: true, reason: reason)
        case .fireAtDeadline:
            ring(o, early: false, reason: "Latest wake time")
        }
    }

    /// Wake evidence from the realtime HR stream (strap-confirmed 1 Hz HR; no realtime R-R or motion exists).
    private func currentEvidence(_ now: Date) -> WakeEvidence? {
        guard let live, live.realtimeStreaming, let hr = live.heartRate, let ref = sleepingHR(), ref > 0 else {
            return WakeEvidence(at: now, wakeLikelihood: 0, usable: false)
        }
        return WakeEvidence.estimate(at: now, moveFraction: nil, hrRatio: Double(hr) / ref)
    }

    private func beginWindow(_ o: AlarmOccurrence) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                        reason: "NOOP wake alarm window")
        if let spec = alarms.first(where: { $0.id == o.alarmId }), spec.mode != .exact { ble?.startRealtime() }
    }

    private func endWindow() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    private func ring(_ o: AlarmOccurrence, early: Bool, reason: String) {
        firedOccurrences.insert(occurrenceKey(o))
        states[o.alarmId] = .triggered
        persist()
        let time = Date().formatted(date: .omitted, time: .shortened)
        var vibrated = false
        // A confirmed on-strap alarm rings by itself at the deadline; only an early wake (or no strap alarm) runs it now.
        let strapRingsItself = !early && states[o.alarmId] == .confirmedOnDevice
        if !strapRingsItself, capabilities.immediateVibration == .confirmed, let ble { vibrated = ble.vibrateStrapForAlarm() }
        postWakeNotification(early: early, reason: reason)
        status = "Rang at \(time)\(early ? " (early: \(reason))" : "")"
            + (strapRingsItself ? " — strap alarm" : vibrated ? " — strap buzz requested" : " — on this Mac only (strap not connected)")
        if alarms.first(where: { $0.id == o.alarmId })?.mode != .exact { ble?.stopRealtime() }
        endWindow()
        states[o.alarmId] = .active
        reschedule()
    }

    private func postWakeNotification(early: Bool, reason: String) {
        let c = UNMutableNotificationContent()
        c.title = "Time to wake up"
        c.body = early ? "\(reason). Your latest wake time was close." : "It's your wake-up time."
        c.sound = .defaultCritical
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "noop.alarm.\(UUID().uuidString)", content: c, trigger: nil))
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
        return w
    }
}
