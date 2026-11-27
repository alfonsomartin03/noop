import Foundation
import WhoopStore

/// Moves undecoded-history lines (written durably by the shared `RawHistoryArchive` before each ack) into the outbox
/// table so they travel to the Mac. Keeps a per-file byte offset; only whole lines move. A crash between the copy and
/// the offset save can repeat lines, which the Mac's archive tolerates; it never loses one.
enum UndecodedForwarder {
    static let offsetsKey = "noop.sync.undecodedOffsets"

    static func forward(into store: WhoopStore, directory: URL? = nil, defaults: UserDefaults = .standard) async throws {
        guard let dir = directory ?? (try? RawHistoryArchive.standard())?.directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        var offsets = defaults.dictionary(forKey: offsetsKey) as? [String: Int] ?? [:]
        for url in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let start = offsets[name] ?? 0
            try h.seek(toOffset: UInt64(start))
            guard let data = try h.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let whole = data[data.startIndex...lastNewline]
            let lines = String(decoding: whole, as: UTF8.self).split(separator: "\n").map(String.init)
            try await store.appendSyncUndecoded(lines)
            offsets[name] = start + whole.count
            defaults.set(offsets, forKey: offsetsKey)
        }
    }
}
