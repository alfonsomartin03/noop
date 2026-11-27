import Foundation
import WhoopStore

/// "Send me the daily summaries that changed after revision `since`." Replies are pages of at most `pageSize`.
struct SummaryRequest: Codable { let since: Int64 }

// SyncEndpoints.swift — the two ends of a phone ↔ Mac session (#79), over any `ByteStream`.

/// Mac side: serves one connection at a time per call. Pinned phones may upload; an unknown phone gets in only while a
/// pairing window is open, and is pinned only after both users confirm matching codes.
public final class MacSyncEndpoint {
    let identity: DeviceIdentity
    let trust: TrustStore
    let ingestor: MacArchiveIngestor
    let macName: String
    /// NOOP's derived identity whose daily scores are sent back (`<strap>-noop`).
    let summaryDeviceId: String
    /// Shows the code on the Mac and returns the user's answer.
    let confirmPairing: (String) async -> Bool
    private var window: PairingWindow?
    private let lock = NSLock()

    public static let pageSize = 400

    public init(identity: DeviceIdentity, trust: TrustStore, ingestor: MacArchiveIngestor, macName: String,
                summaryDeviceId: String = "my-whoop-noop", confirmPairing: @escaping (String) async -> Bool) {
        self.identity = identity; self.trust = trust; self.ingestor = ingestor; self.macName = macName
        self.summaryDeviceId = summaryDeviceId
        self.confirmPairing = confirmPairing
    }

    /// Lets one new phone pair within `lifetime` seconds.
    @discardableResult
    public func openPairingWindow(lifetime: TimeInterval = 120) -> PairingWindow {
        let w = PairingWindow(lifetime: lifetime)
        lock.lock(); window = w; lock.unlock()
        return w
    }

    private var openWindow: PairingWindow? {
        lock.lock(); defer { lock.unlock() }
        return window?.isOpen() == true ? window : nil
    }

    /// Handles one connection until it closes. Never throws: failures end the connection.
    public func serve(_ stream: ByteStream) async {
        let pairingWindow = openWindow
        guard let session = try? await Handshake.respond(on: stream, identity: identity, accept: { key in
            self.trust.isTrusted(key) || pairingWindow != nil
        }) else { return }
        defer { session.close() }
        if !trust.isTrusted(session.peerKey) {
            guard let w = pairingWindow, w.take(), await pair(session) else { return }
        }
        while let (type, body) = try? await session.receive() {
            guard trust.isTrusted(session.peerKey) else {   // revoked mid-session
                try? await session.send(.error, Data("not paired".utf8)); return
            }
            switch type {
            case .upload:
                do {
                    let receipt = try await ingestor.ingest(body)
                    try await session.send(.upload, try JSONEncoder().encode(receipt))
                } catch {
                    try? await session.send(.error, Data("upload refused: \(error)".utf8))
                }
            case .summaries:
                do {
                    let req = try JSONDecoder().decode(SummaryRequest.self, from: body)
                    let page = try await ingestor.store.dailySummaries(deviceId: summaryDeviceId, since: req.since,
                                                                       limit: Self.pageSize)
                    try await session.send(.summaries, try JSONEncoder().encode(page))
                } catch {
                    try? await session.send(.error, Data("summaries unavailable: \(error)".utf8))
                }
            default:
                try? await session.send(.error, Data("unexpected message".utf8)); return
            }
        }
    }

    private func pair(_ session: SecureSession) async -> Bool {
        guard await confirmPairing(session.pairingCode) else {
            try? await session.send(.error, Data("pairing declined on the Mac".utf8)); return false
        }
        guard let (type, body) = try? await session.receive(), type == .pairConfirm else { return false }
        let name = String(decoding: body, as: UTF8.self)
        do {
            try trust.pin(TrustedPeer(publicKey: session.peerKey, name: name.isEmpty ? "iPhone" : name,
                                      pairedAt: Int(Date().timeIntervalSince1970)))
            try await session.send(.pairConfirm, Data(macName.utf8))
            return true
        } catch {
            try? trust.revoke(publicKey: session.peerKey)
            return false
        }
    }
}

/// Phone side: pairs once, then uploads sealed envelopes over an authenticated session to the pinned Mac.
public final class PhoneSyncClient: SyncTransport {
    let identity: DeviceIdentity
    let trust: TrustStore
    let connect: () async throws -> ByteStream
    private var session: SecureSession?

    public init(identity: DeviceIdentity, trust: TrustStore, connect: @escaping () async throws -> ByteStream) {
        self.identity = identity; self.trust = trust; self.connect = connect
    }

    /// Pairs with the Mac at the other end of `connect`. `confirm` shows the code on the phone and returns the user's
    /// answer; the Mac's user must confirm the same code. Returns the pinned Mac.
    public func pair(phoneName: String, confirm: (String) async -> Bool) async throws -> TrustedPeer {
        let s = try await Handshake.initiate(on: try await connect(), identity: identity, accept: { _ in true })
        defer { s.close() }
        guard await confirm(s.pairingCode) else { throw ChannelError.pairingRefused }
        try await s.send(.pairConfirm, Data(phoneName.utf8))
        let (type, body) = try await s.receive()
        guard type == .pairConfirm else { throw ChannelError.pairingRefused }
        let mac = TrustedPeer(publicKey: s.peerKey, name: String(decoding: body, as: UTF8.self),
                              pairedAt: Int(Date().timeIntervalSince1970))
        try trust.pin(mac)
        return mac
    }

    public func send(_ envelope: Data) async throws -> Data { try await request(.upload, envelope) }

    /// Asks the Mac for every daily summary newer than what `store` has cached and caches it. Returns days changed.
    /// The Mac scores on its own schedule; a day uploaded just now may appear on a later call.
    @discardableResult
    public func refreshScores(into store: WhoopStore) async throws -> Int {
        var changed = 0
        while true {
            let since = try await store.cachedSummaryRevision()
            let page = try await request(.summaries, try JSONEncoder().encode(SummaryRequest(since: since)))
            let summaries = try JSONDecoder().decode([DailySummary].self, from: page)
            changed += try await store.cacheSummaries(summaries)
            if summaries.count < MacSyncEndpoint.pageSize { return changed }
        }
    }

    private func request(_ type: RecordType, _ body: Data) async throws -> Data {
        do {
            let s = try await currentSession()
            try await s.send(type, body)
            let (reply, data) = try await s.receive()
            guard reply == type else { throw ChannelError.authenticationFailed }
            return data
        } catch {
            session?.close(); session = nil
            throw error
        }
    }

    public func disconnect() { session?.close(); session = nil }

    private func currentSession() async throws -> SecureSession {
        if let session { return session }
        let s = try await Handshake.initiate(on: try await connect(), identity: identity,
                                             accept: { self.trust.isTrusted($0) })
        session = s
        return s
    }
}
