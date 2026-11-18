import Foundation

// WHOOP 5.0 named configuration reads: GET_DEVICE_CONFIG_VALUE (121) and GET_FF_VALUE (128).
//
// Layout source: ryanbr/noop `docs/PROTOCOL_CONFIGURATION.md` at 2a1de76 (fw 50.42.1.0). CONFIRMED on fw 50.43.1.0 by
// C08 (2026-11-18, EXPERIMENT_LOG): all four reads answered SUCCESS with this exact shape (67-byte body, key echoed).
// Value meanings and the FAILURE/fallback shapes still rest on the reference alone.
// NOOP never sends these; only `ble_probe --c08` does, and only the four fixed reads below.
//
//   request  = [01][key: ≤ 31 ASCII bytes, NUL-padded to 32]                       (33 bytes)
//   response = [01][key echo: 32][value: 32, NUL-terminated decimal text]         (65-byte semantic body)
//
// Transport padding: the strap pads the whole payload to a 4-byte boundary, and the 5-byte response prefix
// ([36][strap seq][cmd][app seq][result]) stays outside the body, so a 65-byte semantic body arrives as
// `Whoop5CommandResponse.body.count == 67` (same arithmetic as pack info 151: 28 semantic → 31 observed).
// Only those alignment bytes are removed, and only when they are zero; the value field is kept as sent.

public enum Whoop5ConfigRead {
    public static let deviceConfigCommand: UInt8 = 121
    public static let featureFlagCommand: UInt8 = 128
    public static let revision: UInt8 = 1
    public static let keyFieldLength = 32
    public static let valueFieldLength = 32
    /// Revision + key + value.
    public static let semanticBodyLength = 1 + keyFieldLength + valueFieldLength   // 65

    /// Zero bytes the transport adds after a semantic body of `n` bytes (response prefix is 5 bytes).
    public static func alignmentPadding(semanticBody n: Int) -> Int { (4 - (5 + n) % 4) % 4 }

    /// One fixed read. The C08 table is the only set the probe may send (no free-form names, no sweeps).
    public struct Key: Equatable, Sendable {
        public let command: UInt8
        public let name: String
        public init(command: UInt8, name: String) { self.command = command; self.name = name }
    }

    /// C08 proposal (CAPABILITY_MATRIX §7): names whose value would change what NOOP does. Not approved, not run.
    public static let c08Keys: [Key] = [
        Key(command: deviceConfigCommand, name: "sigproc_wear_detect"),
        Key(command: deviceConfigCommand, name: "cont_collection_mode"),
        Key(command: deviceConfigCommand, name: "max_collection_backlog"),
        Key(command: featureFlagCommand, name: "disable_pip_r26_packets"),
    ]

    /// The 32-byte key field: ASCII name + NUL padding. nil for an empty name, non-printable/non-ASCII bytes, or
    /// more than 31 bytes (a NUL must terminate it; a full 32-byte name is normalized by the strap, never echoed).
    public static func keyField(_ name: String) -> [UInt8]? {
        let b = Array(name.utf8)
        guard !b.isEmpty, b.count < keyFieldLength, b.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return b + [UInt8](repeating: 0, count: keyFieldLength - b.count)
    }

    /// Command data for a read: `[01] + keyField` (33 bytes). nil for an invalid name or a command other than 121/128.
    public static func requestPayload(command: UInt8, name: String) -> [UInt8]? {
        guard command == deviceConfigCommand || command == featureFlagCommand, let k = keyField(name) else { return nil }
        return [revision] + k
    }

    public static func requestPayload(_ key: Key) -> [UInt8]? { requestPayload(command: key.command, name: key.name) }

    /// How one response is classified. Only `.value` carries a usable setting; every other case is a valid C08
    /// outcome to record. `.unexpected` is the stop condition (no retries, no further reads).
    public enum Outcome: Equatable, Sendable {
        /// SUCCESS, key echoed, value field holds decimal text (`0`, `1`, `2`, an integer, or one fractional digit).
        case value(String)
        /// SUCCESS with an all-zero value field: per the reference a storage-slot read failure returns zeros with
        /// result 1, so this is NOT a reading of zero.
        case zeroFallback
        /// FAILURE, key echoed, all-zero value: unknown key on this firmware, or a value-read/format error.
        case keyUnknownOrUnreadable
        /// FAILURE, revision 1 + 64 zero bytes, no key echo: request revision rejected.
        case revisionRejected
        /// UNSUPPORTED (result 3): the command does not exist on this firmware.
        case unsupported
        /// PENDING: wait for the final answer (not an outcome yet).
        case pending
        case unexpected(String)
    }

    public struct Reply: Equatable, Sendable {
        public let outcome: Outcome
        /// The 65 semantic bytes when the shape matched (padding removed, nothing else touched); empty otherwise.
        public let semanticBody: [UInt8]
        /// The body exactly as received (`Whoop5CommandResponse.body`), kept for the private capture.
        public let rawBody: [UInt8]
    }

    /// Classify a 121/128 response to a request for `name`. The caller has already matched command + app seq.
    public static func classify(_ r: Whoop5CommandResponse, name: String) -> Reply {
        func reply(_ o: Outcome, _ semantic: [UInt8] = []) -> Reply { Reply(outcome: o, semanticBody: semantic, rawBody: r.body) }
        guard r.command == deviceConfigCommand || r.command == featureFlagCommand else {
            return reply(.unexpected("command \(r.command) is not 121/128"))
        }
        switch r.result {
        case .pending: return reply(.pending)
        case .unsupported: return reply(.unsupported)
        case .other(let b): return reply(.unexpected("result \(b)"))
        case .success, .failure: break
        }
        guard let key = keyField(name) else { return reply(.unexpected("invalid requested name")) }

        // Body = 65 semantic bytes + 0 or exactly the alignment padding, and that padding must be zero.
        let n = semanticBodyLength, pad = alignmentPadding(semanticBody: n)
        guard r.body.count == n || r.body.count == n + pad else {
            return reply(.unexpected("body \(r.body.count) bytes, expected \(n) or \(n + pad)"))
        }
        guard r.body[n...].allSatisfy({ $0 == 0 }) else { return reply(.unexpected("non-zero transport padding")) }
        let s = Array(r.body[..<n])
        guard s[0] == revision else { return reply(.unexpected("revision \(s[0])"), s) }
        let echo = Array(s[1...keyFieldLength]), value = Array(s[(1 + keyFieldLength)...])
        let valueIsZero = value.allSatisfy { $0 == 0 }

        if r.result == .failure {
            if echo.allSatisfy({ $0 == 0 }) && valueIsZero { return reply(.revisionRejected, s) }
            guard echo == key else { return reply(.unexpected("key echo differs"), s) }
            return reply(valueIsZero ? .keyUnknownOrUnreadable : .unexpected("FAILURE with a non-zero value"), s)
        }
        guard echo == key else { return reply(.unexpected("key echo differs"), s) }
        if valueIsZero { return reply(.zeroFallback, s) }
        guard let nul = value.firstIndex(of: 0) else { return reply(.unexpected("value not NUL-terminated"), s) }
        guard value[nul...].allSatisfy({ $0 == 0 }) else { return reply(.unexpected("bytes after the value's NUL"), s) }
        let text = String(decoding: value[..<nul], as: UTF8.self)
        guard isDecimalText(text) else { return reply(.unexpected("value is not decimal text"), s) }
        return reply(.value(text), s)
    }

    /// `0`, `1`, `2`, an unsigned integer, or an unsigned decimal with one fractional digit.
    static func isDecimalText(_ t: String) -> Bool {
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        let digits: (Substring) -> Bool = { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
        switch parts.count {
        case 1: return digits(parts[0])
        case 2: return digits(parts[0]) && parts[1].count == 1 && digits(parts[1])
        default: return false
        }
    }
}
