import Foundation

/// Explicit, bounded research capture of complete WHOOP 5.0 history frames (#25).
///
/// Normally a decoded type-47 record keeps only the fields NOOP understands (HR, R-R, gravity, skin temperature,
/// steps); its other bytes are gone once the chunk is acknowledged. While a capture is active, every decoded record's
/// complete frame is also written to `RawHistoryArchive.research()` with firmware identity, strap time and the
/// capture id — and that write must succeed (flushed) before the chunk is acknowledged, exactly like undecoded frames.
///
/// Bounds: the user starts it; it ends by itself after `duration` (≤ 7 days) or once `maxBytes` were written, whichever
/// comes first. Reaching the size cap ends the capture; it never blocks acknowledgement. No strap setting changes.
struct ResearchCapture: Codable, Equatable {
    static let key = "noop.research.fullHistoryCapture"
    static let maxDuration: TimeInterval = 7 * 86_400
    /// ~21 MB/day at one record per second (hex JSONL), so 7 days fit with room to spare.
    static let maxBytes = 400 * 1_024 * 1_024

    let id: String
    let startedAt: Date
    let until: Date
    var bytesWritten: Int = 0
    /// Why it ended early (size cap), if it did.
    var stoppedReason: String?

    static func start(now: Date = Date(), duration: TimeInterval = maxDuration) -> ResearchCapture {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return ResearchCapture(id: "r18-" + f.string(from: now), startedAt: now,
                               until: now.addingTimeInterval(min(max(duration, 60), maxDuration)))
    }

    func isActive(at now: Date = Date()) -> Bool {
        stoppedReason == nil && now >= startedAt && now < until && bytesWritten < Self.maxBytes
    }

    /// True if writing `bytes` more would pass the cap: the caller ends the capture instead of writing.
    func wouldExceed(_ bytes: Int) -> Bool { bytesWritten + bytes > Self.maxBytes }

    /// Rough size of one archived line, used to check the cap before writing.
    static func estimatedBytes(frames: [[UInt8]]) -> Int { frames.reduce(0) { $0 + $1.count * 2 + 200 } }

    // MARK: Storage

    static func load(_ defaults: UserDefaults = .standard) -> ResearchCapture? {
        guard let d = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ResearchCapture.self, from: d)
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.key) }
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
