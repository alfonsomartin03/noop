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

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
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
