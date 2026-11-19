import Foundation

/// #46 ordinary-use counters for one local calendar day: commands NOOP sent (by label) and link/pull events, plus
/// connected time as the exposure to divide by. Counts only — no health values, identifiers or payload bytes — so a
/// day file can be shared for measurement. The unified log rotates within hours; these survive it.
public struct OpsDay: Codable, Equatable {
    /// Local calendar day, `yyyy-MM-dd`.
    public var day: String
    /// Time zone the day was counted in (a trip changes where midnight falls).
    public var timeZone: String
    /// App versions/builds that counted that day, in order (comparisons across app changes need them; a relaunch
    /// after a rebuild resumes the day and adds its build).
    public var apps: [String]
    /// Strap firmware versions seen that day.
    public var firmware: [String]
    /// Commands sent, keyed by `WhoopCommand.label`.
    public var commands: [String: Int]
    /// `OpsCounter` raw value → count.
    public var counts: [String: Int]
    /// Seconds the strap link was up within this day (split at midnight).
    public var connectedSeconds: Double

    public init(day: String, timeZone: String, app: String) {
        self.day = day; self.timeZone = timeZone; apps = [app]
        firmware = []; commands = [:]; counts = [:]; connectedSeconds = 0
    }

    private enum CodingKeys: String, CodingKey {
        case day, timeZone, apps, app, firmware, commands, counts, connectedSeconds
    }

    /// Also reads the first counter build's single `app` string.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        apps = try c.decodeIfPresent([String].self, forKey: .apps)
            ?? [try c.decodeIfPresent(String.self, forKey: .app)].compactMap { $0 }
        firmware = try c.decodeIfPresent([String].self, forKey: .firmware) ?? []
        commands = try c.decodeIfPresent([String: Int].self, forKey: .commands) ?? [:]
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        connectedSeconds = try c.decodeIfPresent(Double.self, forKey: .connectedSeconds) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(apps, forKey: .apps)
        try c.encode(firmware, forKey: .firmware)
        try c.encode(commands, forKey: .commands)
        try c.encode(counts, forKey: .counts)
        try c.encode(connectedSeconds, forKey: .connectedSeconds)
    }
}

public enum OpsCounter: String, CaseIterable {
    case connect                // link up (didConnect)
    case disconnect             // link down (didDisconnect, or Bluetooth turned off while connected)
    case bluetoothOff           // the Mac's Bluetooth reported poweredOff (an exposure confound, not a NOOP reconnect)
    case setupAttempt           // 5.0 CLIENT_HELLO setup attempts
    case pullStarted
    case pullCompleted          // strap sent HISTORY_COMPLETE
    case pullEndedEarly         // any other end (disconnect, idle, save failure, cancel)
    case historyFrames          // frames received during pulls
    case batteryReadSkipped     // periodic level read skipped: the strap had pushed a level recently
    case batteryCharRead        // standard 0x2A19 read
    case rxBytes                // notification bytes received (all characteristics)
}

/// Accumulates `OpsDay`s. Pure: the caller supplies times and persists `snapshot` output.
public struct OpsCounterBook {
    public private(set) var current: OpsDay?
    /// Days that rolled over and have not been handed out by `snapshot` yet.
    public private(set) var finished: [OpsDay] = []
    private var connectedSince: Date?
    private let calendar: Calendar
    private let app: String
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `resume`: a stored file for the current day (after a relaunch); ignored unless it is for the day of `now`.
    public init(calendar: Calendar = .current, app: String, resume: OpsDay? = nil, now: Date = Date()) {
        self.calendar = calendar
        self.app = app
        if var r = resume, r.day == Self.key(now, calendar) {
            if !r.apps.contains(app) { r.apps.append(app) }
            current = r
        }
    }

    public static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public var isConnected: Bool { connectedSince != nil }

    public mutating func command(_ label: String, at t: Date) {
        accrue(to: t)
        withDay(t) { $0.commands[label, default: 0] += 1 }
    }

    public mutating func count(_ c: OpsCounter, by n: Int = 1, at t: Date) {
        guard n != 0 else { return }
        accrue(to: t)
        withDay(t) { $0.counts[c.rawValue, default: 0] += n }
    }

    public mutating func firmware(_ fw: String, at t: Date) {
        accrue(to: t)
        withDay(t) { if !$0.firmware.contains(fw) { $0.firmware.append(fw) } }
    }

    /// Idempotent: a second `linkUp` keeps the first start.
    public mutating func linkUp(at t: Date) {
        count(.connect, at: t)
        if connectedSince == nil { connectedSince = t }
    }

    /// Counts a disconnect only when the link was up, so a poweredOff after didDisconnect is not counted twice.
    public mutating func linkDown(at t: Date) {
        guard connectedSince != nil else { return }
        accrue(to: t)
        connectedSince = nil
        count(.disconnect, at: t)
    }

    /// Days to write: finished days (handed out once) then the current day, with open connected time accrued to `t`.
    public mutating func snapshot(at t: Date) -> [OpsDay] {
        accrue(to: t)
        if current == nil || current?.day != Self.key(t, calendar) { roll(to: t) }
        let out = finished + (current.map { [$0] } ?? [])
        finished = []
        return out
    }

    /// Adds connected time from `connectedSince` to `t`, split at local midnights. Every count accrues first, so open
    /// connected time always reaches the newest event and days only move forward (a backwards clock step is the
    /// exception; `roll` then reopens the earlier day if it has not been handed out yet).
    private mutating func accrue(to t: Date) {
        guard var from = connectedSince, t > from else { return }
        while let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)), next < t {
            let s = next.timeIntervalSince(from)
            withDay(from) { $0.connectedSeconds += s }
            from = next
        }
        let s = t.timeIntervalSince(from)
        withDay(from) { $0.connectedSeconds += s }
        connectedSince = t
    }

    private mutating func withDay(_ t: Date, _ f: (inout OpsDay) -> Void) {
        if current?.day != Self.key(t, calendar) { roll(to: t) }
        f(&current!)
    }

    private mutating func roll(to t: Date) {
        if let c = current { finished.append(c) }
        let k = Self.key(t, calendar)
        if let i = finished.lastIndex(where: { $0.day == k }) { current = finished.remove(at: i); return }
        current = OpsDay(day: k, timeZone: calendar.timeZone.identifier, app: app)
    }
}
