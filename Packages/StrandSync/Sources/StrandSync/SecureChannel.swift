import Foundation
import CryptoKit

// SecureChannel.swift — authenticated, encrypted phone ↔ Mac session (#79), independent of the network below it.
//
// Each device has a long-term X25519 key (`DeviceIdentity`). A session handshake exchanges static + fresh ephemeral
// public keys, then derives two ChaChaPoly keys with HKDF from three Diffie–Hellman results (ephemeral–ephemeral and both
// static–ephemeral pairs), salted with the hash of the two hello messages. Only the holders of both static private keys
// can derive them, each session gets fresh keys (forward secrecy), and an explicit "finished" record in each direction
// confirms the keys before any data moves. Records carry a per-direction counter nonce, so a dropped, replayed,
// reordered or altered record fails to decrypt and ends the session. Unknown peers are refused right after their hello,
// unless a pairing window is open (see `PeerTrust.swift`). The phone commits to its ephemeral key before seeing the
// Mac's, so the pairing code derived from the transcript cannot be steered by anyone in the middle.

/// A byte pipe: a TCP connection in the app, an in-memory pipe in tests.
public protocol ByteStream: AnyObject {
    func write(_ data: Data) async throws
    /// Returns exactly `count` bytes or throws (closed, failed).
    func read(_ count: Int) async throws -> Data
    func close()
}

public enum ChannelError: Error, Equatable {
    case badHello
    case unsupportedVersion(UInt8)
    case unknownPeer
    case authenticationFailed
    case recordTooLarge(Int)
    case closed
    case remote(String)
    case pairingRefused
}

enum Frame {
    static let maxRecord = 64 << 20

    static func write(_ data: Data, to s: ByteStream) async throws {
        var len = UInt32(data.count).bigEndian
        try await s.write(Data(bytes: &len, count: 4) + data)
    }

    static func read(from s: ByteStream) async throws -> Data {
        let head = try await s.read(4)
        let n = Int(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard n <= maxRecord else { throw ChannelError.recordTooLarge(n) }
        return n == 0 ? Data() : try await s.read(n)
    }
}

/// Message types inside a session.
enum RecordType: UInt8 {
    case finished = 0x00
    case upload = 0x01
    case pairConfirm = 0x02
    case summaries = 0x03
    case error = 0xFF
}

/// An established session. One request/response at a time.
public final class SecureSession {
    public let peerKey: Data
    /// Hash of the handshake; the pairing code is derived from it.
    let transcript: Data

    /// 6-digit code both screens show while pairing. Equal codes mean both devices saw the same handshake.
    public var pairingCode: String {
        let h = SHA256.hash(data: transcript + Data("noop-sync-v1 pairing code".utf8))
        let n = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06d", n % 1_000_000)
    }
    let stream: ByteStream
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    init(peerKey: Data, transcript: Data, stream: ByteStream, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.peerKey = peerKey; self.transcript = transcript; self.stream = stream
        self.sendKey = sendKey; self.receiveKey = receiveKey
    }

    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var be = n.bigEndian
        return try ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &be, count: 8))
    }

    func send(_ type: RecordType, _ body: Data = Data()) async throws {
        let box = try ChaChaPoly.seal(Data([type.rawValue]) + body, using: sendKey, nonce: Self.nonce(sent))
        sent += 1
        try await Frame.write(box.combined, to: stream)
    }

    func receive() async throws -> (RecordType, Data) {
        let frame = try await Frame.read(from: stream)
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: frame)
            guard box.nonce.withUnsafeBytes({ Data($0) }) == (try Self.nonce(received)).withUnsafeBytes({ Data($0) })
            else { throw ChannelError.authenticationFailed }
            plain = try ChaChaPoly.open(box, using: receiveKey)
        } catch { stream.close(); throw ChannelError.authenticationFailed }
        received += 1
        guard let first = plain.first, let type = RecordType(rawValue: first) else {
            stream.close(); throw ChannelError.authenticationFailed
        }
        let body = plain.dropFirst()
        if type == .error { throw ChannelError.remote(String(decoding: body, as: UTF8.self)) }
        return (type, Data(body))
    }

    public func close() { stream.close() }
}

enum Handshake {
    static let magic = Data("NOOPSYNC".utf8)
    static let version: UInt8 = 1

    // Message 1 (phone): magic ‖ version ‖ phone static key ‖ SHA-256(phone ephemeral)   — a commitment
    // Message 2 (Mac):   magic ‖ version ‖ Mac static key ‖ Mac ephemeral
    // Message 3 (phone): phone ephemeral (must match the commitment)
    // The phone fixes its ephemeral before seeing the Mac's, and the Mac sends its own before seeing the phone's, so
    // neither side (nor a device in the middle) can steer the transcript, and the pairing code derived from it.

    static func header(_ staticKey: Data, _ tail: Data) -> Data { magic + Data([version]) + staticKey + tail }

    static func parse(_ d: Data) throws -> (staticKey: Data, tail: Data) {
        guard d.count == magic.count + 1 + 64, d.prefix(magic.count) == magic else { throw ChannelError.badHello }
        let v = d[d.startIndex + magic.count]
        guard v == version else { throw ChannelError.unsupportedVersion(v) }
        let keys = d.dropFirst(magic.count + 1)
        return (Data(keys.prefix(32)), Data(keys.suffix(32)))
    }

    /// DH results in initiator order (ee, se, es).
    static func keys(ee: SharedSecret, se: SharedSecret, es: SharedSecret, transcript: Data)
        -> (initiatorToResponder: SymmetricKey, responderToInitiator: SymmetricKey) {
        let ikm = [ee, se, es].reduce(Data()) { $0 + $1.withUnsafeBytes { Data($0) } }
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: transcript,
                                         info: Data("noop-sync-v1 keys".utf8), outputByteCount: 64)
        let b = okm.withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: b.prefix(32)), SymmetricKey(data: b.suffix(32)))
    }

    static func transcript(_ m1: Data, _ m2: Data, _ m3: Data) -> Data { Data(SHA256.hash(data: m1 + m2 + m3)) }

    /// Phone side. `accept` decides whether the Mac's static key is acceptable (pinned, or pairing in progress).
    static func initiate(on s: ByteStream, identity: DeviceIdentity,
                         accept: (Data) -> Bool) async throws -> SecureSession {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.rawRepresentation
        let m1 = header(identity.publicKey, Data(SHA256.hash(data: ephPub)))
        try await Frame.write(m1, to: s)
        let m2 = try await Frame.read(from: s)
        if m2.first == RecordType.error.rawValue {
            s.close(); throw ChannelError.unknownPeer      // the Mac refused this phone before any keys existed
        }
        let (rs, re) = try parse(m2)
        guard accept(rs) else { s.close(); throw ChannelError.unknownPeer }
        try await Frame.write(ephPub, to: s)
        let remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rs)
        let remoteEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: re)
        let th = transcript(m1, m2, ephPub)
        let k = keys(ee: try eph.sharedSecretFromKeyAgreement(with: remoteEph),
                     se: try identity.privateKey.sharedSecretFromKeyAgreement(with: remoteEph),
                     es: try eph.sharedSecretFromKeyAgreement(with: remoteStatic), transcript: th)
        let session = SecureSession(peerKey: rs, transcript: th, stream: s,
                                    sendKey: k.initiatorToResponder, receiveKey: k.responderToInitiator)
        try await session.send(.finished)
        let (t, _) = try await session.receive()
        guard t == .finished else { s.close(); throw ChannelError.authenticationFailed }
        return session
    }

    /// Mac side. `accept` is checked on the phone's static key before anything is sent back.
    static func respond(on s: ByteStream, identity: DeviceIdentity,
                        accept: (Data) -> Bool) async throws -> SecureSession {
        let m1 = try await Frame.read(from: s)
        let (rs, commitment) = try parse(m1)
        guard accept(rs) else {
            try? await Frame.write(Data([RecordType.error.rawValue]) + Data("unknown device".utf8), to: s)
            s.close(); throw ChannelError.unknownPeer
        }
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let m2 = header(identity.publicKey, eph.publicKey.rawRepresentation)
        try await Frame.write(m2, to: s)
        let re = try await Frame.read(from: s)
        guard re.count == 32, Data(SHA256.hash(data: re)) == commitment else {
            s.close(); throw ChannelError.authenticationFailed
        }
        let remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rs)
        let remoteEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: re)
        let th = transcript(m1, m2, re)
        let k = keys(ee: try eph.sharedSecretFromKeyAgreement(with: remoteEph),
                     se: try eph.sharedSecretFromKeyAgreement(with: remoteStatic),
                     es: try identity.privateKey.sharedSecretFromKeyAgreement(with: remoteEph), transcript: th)
        let session = SecureSession(peerKey: rs, transcript: th, stream: s,
                                    sendKey: k.responderToInitiator, receiveKey: k.initiatorToResponder)
        let (t, _) = try await session.receive()
        guard t == .finished else { s.close(); throw ChannelError.authenticationFailed }
        try await session.send(.finished)
        return session
    }
}
