import Foundation

// ZoneTimeline.swift — which time zone the wearer was in at any instant.
//
// Strap data is stored as UTC unix seconds. "When did I fall asleep", "which day does this night belong to" and
// bedtime consistency are all questions about the WEARER'S wall clock, which depends on where they were. The Mac's
// time zone follows its location when "Set time zone automatically" is on, so we log every change of the system
// zone with a timestamp and resolve each past night in the zone that was in force when it happened. Formatters
// built once at launch (or `TimeZone.current`, which is cached until the process restarts) would show every night
// in whatever zone the app launched in.

public struct ZoneEntry: Codable, Equatable, Sendable {
    /// First unix second at which `id` applies.
    public let since: Int
    /// IANA identifier, e.g. "America/New_York".
    public let id: String
    public init(since: Int, id: String) { self.since = since; self.id = id }
}

public final class ZoneTimeline: @unchecked Sendable {

    /// App-wide timeline, persisted in UserDefaults.
    public static let shared = ZoneTimeline(defaultsKey: "noop.zoneTimeline")

    private let lock = NSLock()
    private var entries: [ZoneEntry]
    private let defaultsKey: String?
    private var zoneCache: [String: TimeZone] = [:]
    private var observer: NSObjectProtocol?

    /// - Parameter defaultsKey: UserDefaults key to persist under; nil keeps the timeline in memory (tests).
    public init(entries: [ZoneEntry] = [], defaultsKey: String? = nil) {
        self.defaultsKey = defaultsKey
        if entries.isEmpty, let key = defaultsKey,
           let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ZoneEntry].self, from: data) {
            self.entries = saved.sorted { $0.since < $1.since }
        } else {
            self.entries = entries.sorted { $0.since < $1.since }
        }
    }

    // MARK: - Recording

    /// Log `zone` as in force from `ts` on. No-op when it equals the zone already in force.
    public func record(_ zone: TimeZone, at ts: Int = Int(Date().timeIntervalSince1970)) {
        lock.lock(); defer { lock.unlock() }
        if let last = entries.last {
            if last.id == zone.identifier { return }
            // Never rewrite the past: a change is only ever appended at or after the newest entry.
            entries.append(ZoneEntry(since: max(ts, last.since), id: zone.identifier))
        } else {
            // The first sighting stands in for all earlier history (we cannot know better).
            entries.append(ZoneEntry(since: 0, id: zone.identifier))
        }
        persistLocked()
    }

    /// Re-read the system zone (it is cached per process) and log it if it changed.
    public func refreshFromSystem() {
        NSTimeZone.resetSystemTimeZone()
        record(TimeZone.current)
    }

    /// Log the system zone now and keep logging whenever macOS changes it (travel, DST rule updates, manual change).
    public func startTracking() {
        refreshFromSystem()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil
        ) { [weak self] _ in self?.refreshFromSystem() }
    }

    private func persistLocked() {
        guard let key = defaultsKey, let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public var snapshot: [ZoneEntry] { lock.lock(); defer { lock.unlock() }; return entries }

    // MARK: - Resolving

    /// The zone the wearer was in at `ts`. Before any history exists this is the live system zone.
    public func zone(at ts: Int) -> TimeZone {
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { return .autoupdatingCurrent }
        var id = entries[0].id
        for e in entries { if e.since <= ts { id = e.id } else { break } }
        if let z = zoneCache[id] { return z }
        let z = TimeZone(identifier: id) ?? .autoupdatingCurrent
        zoneCache[id] = z
        return z
    }

    /// The zone for a whole span (a night): the one in force at its midpoint, so a bedtime and a wake time
    /// of the same night are always shown on one consistent clock.
    public func zone(forSpan start: Int, _ end: Int) -> TimeZone { zone(at: start + (end - start) / 2) }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// Local calendar day (yyyy-MM-dd) of `ts` in the zone in force then.
    public func dayString(_ ts: Int) -> String {
        let c = calendar(zone(at: ts)).dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Hour (0–23) and minute of `ts` on the wearer's wall clock, in `zone` (default: the zone in force at `ts`).
    public func hourMinute(_ ts: Int, in zone: TimeZone? = nil) -> (hour: Int, minute: Int) {
        let z = zone ?? self.zone(at: ts)
        let c = calendar(z).dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return (c.hour ?? 0, c.minute ?? 0)
    }

    /// "7:42 AM" style clock text in `zone` (default: zone in force at `ts`), honouring the user's 12/24 h locale.
    public func clock(_ ts: Int, in zone: TimeZone? = nil) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = zone ?? self.zone(at: ts)
        f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Unix-second span [start of day, start of next day) for a yyyy-MM-dd key. Handles 23/25 h DST days.
    public func dayRange(_ day: String) -> (from: Int, to: Int)? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        // Use the zone in force around midday of that date to build the day boundaries.
        guard let noonUTC = utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)) else { return nil }
        let cal = calendar(zone(at: Int(noonUTC.timeIntervalSince1970)))
        guard let start = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              let next = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (Int(start.timeIntervalSince1970), Int(next.timeIntervalSince1970))
    }
}
