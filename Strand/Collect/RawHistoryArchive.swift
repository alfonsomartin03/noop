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
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop/undecoded-history", isDirectory: true)
        return RawHistoryArchive(directory: base)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Durably append frames. Throws if anything could not be written and flushed; the caller must then not ack.
    func append(_ frames: [[UInt8]], receivedAt now: Date = Date()) throws {
        guard !frames.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Self.day.string(from: now)).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var text = ""
        for f in frames {
            let hex = f.map { String(format: "%02x", $0) }.joined()
            let type = f.count > 8 ? Int(f[8]) : -1, version = f.count > 9 ? Int(f[9]) : -1
            text += "{\"t\":\(now.timeIntervalSince1970),\"type\":\(type),\"version\":\(version),\"len\":\(f.count),\"hex\":\"\(hex)\"}\n"
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.synchronize()
    }
}
