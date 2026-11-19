import Foundation
import WhoopProtocol

/// #46: one JSON file per local day in `OpenWhoop/ops-counters` (`yyyy-MM-dd.json`), rewritten atomically. Counts only
/// (commands by label, link/pull events, connected seconds, app version, firmware), never health data or identifiers.
/// Read by `Tools/whoop_re/ops_metrics.py --counters`. Never pruned (a few hundred bytes a day).
struct OpsCounterStore {
    let directory: URL

    static func standard() throws -> OpsCounterStore {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop/ops-counters", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return OpsCounterStore(directory: dir)
    }

    /// Version, build and the executable's build time: the version rarely changes between local rebuilds, and
    /// comparisons across app changes need to tell them apart.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let built = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        return "\(v) (\(b)) built \(built)"
    }

    func url(for day: String) -> URL { directory.appendingPathComponent("\(day).json") }

    func load(day: String) -> OpsDay? {
        guard let data = try? Data(contentsOf: url(for: day)) else { return nil }
        return try? JSONDecoder().decode(OpsDay.self, from: data)
    }

    func write(_ days: [OpsDay]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        for d in days { try enc.encode(d).write(to: url(for: d.day), options: .atomic) }
    }
}
