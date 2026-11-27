import Foundation
import CryptoKit
import Security

// PeerTrust.swift — device identities, pinned peers and code-confirmed pairing (#79).
//
// Pairing (numeric comparison, as in Bluetooth LE Secure Connections): the user opens a short pairing window on the Mac
// and connects from the phone. Both screens show a 6-digit code derived from the session's handshake transcript
// (`SecureSession.pairingCode`); the user confirms on both that the codes match. A device in the middle would hold two
// different sessions with independent codes (the commit-first handshake stops it from steering them), so a match has a
// one-in-a-million chance. Only after both confirmations does each side pin the other's public key. The window closes
// after one attempt. Nothing else is trusted: an unpinned or revoked key is refused at the first message.

public struct DeviceIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }
    public init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }
    public var rawPrivateKey: Data { privateKey.rawRepresentation }

    /// Short, human-comparable fingerprint of a public key (Settings: "this Mac is …").
    public static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(4).map { String(format: "%02X", $0) }.joined(separator: "-")
    }
}

public struct TrustedPeer: Equatable, Codable, Sendable {
    public let publicKey: Data
    public let name: String
    public let pairedAt: Int
}

/// Where pinned peers live. The apps use `KeychainTrustStore`; tests use `InMemoryTrustStore`.
public protocol TrustStore: AnyObject {
    func peers() throws -> [TrustedPeer]
    func pin(_ peer: TrustedPeer) throws
    func revoke(publicKey: Data) throws
}

extension TrustStore {
    public func isTrusted(_ publicKey: Data) -> Bool {
        ((try? peers()) ?? []).contains { $0.publicKey == publicKey }
    }
}

public final class InMemoryTrustStore: TrustStore {
    private var list: [TrustedPeer] = []
    public init() {}
    public func peers() throws -> [TrustedPeer] { list }
    public func pin(_ peer: TrustedPeer) throws { list.removeAll { $0.publicKey == peer.publicKey }; list.append(peer) }
    public func revoke(publicKey: Data) throws { list.removeAll { $0.publicKey == publicKey } }
}

/// Keychain-backed identity and trust list (generic-password items, this device only, never synced to iCloud).
public final class KeychainTrustStore: TrustStore {
    let service: String
    public init(service: String = "com.noopapp.noop.sync") { self.service = service }

    public func identity() throws -> DeviceIdentity {
        if let raw = try read(account: "identity") { return try DeviceIdentity(rawPrivateKey: raw) }
        let id = DeviceIdentity()
        try write(account: "identity", data: id.rawPrivateKey)
        return id
    }

    public func peers() throws -> [TrustedPeer] {
        guard let d = try read(account: "peers") else { return [] }
        return try JSONDecoder().decode([TrustedPeer].self, from: d)
    }

    public func pin(_ peer: TrustedPeer) throws {
        var list = try peers().filter { $0.publicKey != peer.publicKey }
        list.append(peer)
        try write(account: "peers", data: try JSONEncoder().encode(list))
    }

    public func revoke(publicKey: Data) throws {
        try write(account: "peers", data: try JSONEncoder().encode(try peers().filter { $0.publicKey != publicKey }))
    }

    public struct KeychainError: Error { public let status: OSStatus }

    /// Removes this service's items (tests, and "forget all pairings").
    public func deleteAllForTests() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(account: String) throws -> Data? {
        var q = base(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw KeychainError(status: st) }
        return out as? Data
    }

    private func write(account: String, data: Data) throws {
        let st = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecSuccess { return }
        guard st == errSecItemNotFound else { throw KeychainError(status: st) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st2 = SecItemAdd(add as CFDictionary, nil)
        guard st2 == errSecSuccess else { throw KeychainError(status: st2) }
    }
}

/// The Mac's pairing window: open for a short time, for one attempt. While it is open an unknown phone may complete
/// the handshake; it is pinned only after the user confirms on both devices that their codes match.
public final class PairingWindow {
    public let expiresAt: Date
    private(set) var used = false
    private let lock = NSLock()

    public init(lifetime: TimeInterval = 120, now: Date = Date()) { expiresAt = now.addingTimeInterval(lifetime) }

    public func isOpen(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !used && now < expiresAt
    }

    /// Takes the window for one pairing attempt (right or wrong). false if closed or already taken.
    func take(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used, now < expiresAt else { return false }
        used = true
        return true
    }
}
