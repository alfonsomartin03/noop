import Foundation

/// Central redaction for text that may leave the Mac (exported logs, captures, bug reports).
///
/// Masks Bluetooth addresses, CoreBluetooth peripheral UUIDs, WHOOP device names (they embed part of the
/// serial number) and registered secrets such as the strap's serial number. The strap's firmware console
/// text is the known source of raw addresses (`Address = xx:xx:…`).
public enum Redactor {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var secrets: Set<String> = []

    /// Register a value that must never appear in exported text (e.g. the serial from Device Information).
    public static func register(secret: String) {
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4 else { return }
        lock.lock(); secrets.insert(s); lock.unlock()
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        // 6-octet Bluetooth / MAC addresses, ':' or '-' separated.
        (try! NSRegularExpression(pattern: "\\b[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}\\b"), "<addr>"),
        // CoreBluetooth peripheral identifiers (random per host, but stable — they identify the strap).
        (try! NSRegularExpression(pattern: "\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\b"), "<uuid>"),
        // "WHOOP 4C1234567" style advertised names.
        (try! NSRegularExpression(pattern: "(?i)\\bWHOOP[ _-]?[0-9A-Z]{4,}\\b"), "WHOOP-<id>"),
    ]

    /// GATT UUIDs of services and characteristics are public protocol constants, not identifiers.
    private static let publicUUIDPrefixes = ["fd4b000", "6108000", "11500001"]

    public static func redact(_ text: String) -> String {
        var out = text
        lock.lock(); let known = secrets; lock.unlock()
        for s in known { out = out.replacingOccurrences(of: s, with: "<redacted>") }
        for (re, template) in patterns {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                let found = ns.substring(with: m.range)
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let isPublic = template == "<uuid>" && publicUUIDPrefixes.contains { found.lowercased().hasPrefix($0) }
                result += isPublic ? found : template
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }
}
