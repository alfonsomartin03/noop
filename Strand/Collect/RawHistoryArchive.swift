import Foundation

/// Append-only archive of WHOOP 5.0 history frames NOOP cannot decode yet (e.g. record version 0x1a).
///
/// Acknowledging a chunk moves the strap's trim pointer, so a record that is neither decoded nor kept would be
/// lost. Frames written here are flushed to disk (`synchronize`) before `append` returns, which is what lets the
/// chunk be acknowledged safely; they can be decoded later from these files. One JSONL file per UTC day under
/// Application Support/OpenWhoop/undecoded-history/. Never pruned automatically.
final class RawHistoryArchive {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    static func standard() throws -> RawHistoryArchive {
        try RawHistoryArchive(directory: supportFolder("OpenWhoop/undecoded-history"))
    }

    /// Full decoded-record frames kept during an explicit research capture (`ResearchCapture`), apart from the
    /// undecoded archive so the two can be told apart and deleted separately.
    static func research() throws -> RawHistoryArchive {
        try RawHistoryArchive(directory: supportFolder("OpenWhoop/research-history"))
    }

    /// Live realtime (type 40) frames from sessions that carried R-R intervals (#39 unit evidence).
    static func liveRR() throws -> RawHistoryArchive {
        try RawHistoryArchive(directory: supportFolder("OpenWhoop/live-rr"))
    }

    private static func supportFolder(_ path: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent(path, isDirectory: true)
    }

    /// Where a frame came from. Written on every line when given, so a later decoder can be scoped to the firmware
    /// that produced the bytes and to the capture that kept them.
    struct Provenance: Equatable {
        /// `undecoded` (always-on archive) or a research capture id.
        var capture: String
        var firmware: String?
        var hardware: String?
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Durably append frames. Throws if anything could not be written and flushed; the caller must then not ack.
    /// `recordTimes[i]` (strap Unix time of frame i, when known) and `provenance` are written when given.
    /// Returns the number of bytes appended.
    @discardableResult
    func append(_ frames: [[UInt8]], receivedAt now: Date = Date(), recordTimes: [Int?] = [],
                provenance: Provenance? = nil) throws -> Int {
        guard !frames.isEmpty else { return 0 }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Self.day.string(from: now)).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var text = ""
        var tail = ""
        if let p = provenance {
            tail += ",\"capture\":\(Self.json(p.capture))"
            if let fw = p.firmware { tail += ",\"fw\":\(Self.json(fw))" }
            if let hw = p.hardware { tail += ",\"hw\":\(Self.json(hw))" }
        }
        for (i, f) in frames.enumerated() {
            let hex = f.map { String(format: "%02x", $0) }.joined()
            let type = f.count > 8 ? Int(f[8]) : -1, version = f.count > 9 ? Int(f[9]) : -1
            let ts = i < recordTimes.count ? recordTimes[i].map { ",\"ts\":\($0)" } ?? "" : ""
            text += "{\"t\":\(now.timeIntervalSince1970),\"type\":\(type),\"version\":\(version),\"len\":\(f.count)\(ts)\(tail),\"hex\":\"\(hex)\"}\n"
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.synchronize()
        return text.utf8.count
    }

    /// Durably append ready-made JSONL lines (undecoded history forwarded by the phone, #77). Same flush guarantee.
    func appendLines(_ lines: [String], now: Date = Date()) throws {
        guard !lines.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Self.day.string(from: now)).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(lines.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined().utf8))
        try h.synchronize()
    }

    private static func json(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}
