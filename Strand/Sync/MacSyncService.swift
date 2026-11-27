import Foundation
import Darwin
import WhoopStore
import StrandSync

/// The Mac end of iPhone sync (#79): an explicit "receive from iPhone" switch, a pairing sheet that shows the
/// 6-digit code, and the paired phones. Uploads land in the same store as Bluetooth data and trigger the same
/// re-scoring. Nothing listens unless the user turned the receiver on.
@MainActor
final class MacSyncService: ObservableObject {
    @Published private(set) var receiving = false
    @Published private(set) var status = "Off"
    @Published private(set) var port: UInt16?
    @Published private(set) var phones: [TrustedPeer] = []
    @Published private(set) var lastUpload: Date?
    /// Set while a phone is pairing: the code to compare with the phone's screen.
    @Published var pairingCode: String?
    @Published private(set) var pairingOpenUntil: Date?
    /// Companion mode (#78): the iPhone collects; this Mac sends nothing to the strap.
    @Published private(set) var companionMode = CompanionMode.isOn
    /// Set by AppModel: switches the strap link off/on.
    var applyCompanionMode: ((Bool) -> Void)?

    static let receivingKey = "noop.sync.receiving"
    /// Fixture launches keep their keys apart from the real app's.
    private let trust = KeychainTrustStore(service: LaunchMode.fixtureStore == nil ? "com.noopapp.noop.sync"
                                                                                    : "com.noopapp.noop.sync.fixture")
    /// Fixture only (`-noop.fixture.syncPair YES`): receiver on, pairing open, codes accepted and printed.
    private var fixtureAutoPair = false
    private let storeProvider: () async -> WhoopStore?
    private let onDataReceived: () -> Void
    private var listener: MacSyncListener?
    private var endpoint: MacSyncEndpoint?
    private var decision: CheckedContinuation<Bool, Never>?

    init(store: @escaping () async -> WhoopStore?, onDataReceived: @escaping () -> Void) {
        storeProvider = store
        self.onDataReceived = onDataReceived
        phones = (try? trust.peers()) ?? []
    }

    /// Restores the user's last choice (never in fixture or test launches).
    func restore() {
        if LaunchMode.fixtureStore != nil {
            #if DEBUG || NOOP_DIAGNOSTICS
            guard LaunchMode.fixtureSyncPair else { return }
            fixtureAutoPair = true
            Task { await setReceiving(true); openPairing(); FileHandle.standardError.write(Data("[sync] receiving on \(port ?? 0), pairing open\n".utf8)) }
            #endif
            return
        }
        guard UserDefaults.standard.bool(forKey: Self.receivingKey) else { return }
        Task { await setReceiving(true) }
    }

    func setReceiving(_ on: Bool) async {
        if LaunchMode.fixtureStore == nil { UserDefaults.standard.set(on, forKey: Self.receivingKey) }
        if !on {
            listener?.stop(); listener = nil; endpoint = nil
            receiving = false; port = nil; status = "Off"; pairingOpenUntil = nil
            answerPairing(false)
            return
        }
        guard listener == nil else { return }
        do {
            guard let store = await storeProvider() else { status = "Store unavailable"; return }
            let archive = try RawHistoryArchive.standard()
            let ingestor = MacArchiveIngestor(store: store) { lines, _ in try archive.appendLines(lines) }
            let ep = MacSyncEndpoint(identity: try trust.identity(), trust: trust, ingestor: ingestor,
                                     macName: Host.current().localizedName ?? "Mac") { [weak self] code in
                await self?.askUser(code) ?? false
            }
            ep.onUpload = { [weak self] _ in
                Task { @MainActor in self?.lastUpload = Date(); self?.onDataReceived() }
            }
            ep.onPaired = { [weak self] _ in
                Task { @MainActor in self?.phones = (try? self?.trust.peers()) ?? []; self?.pairingOpenUntil = nil }
            }
            let l = MacSyncListener(endpoint: ep)
            port = try await l.start()
            listener = l; endpoint = ep
            receiving = true; status = "Receiving"
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            UserDefaults.standard.set(false, forKey: Self.receivingKey)
        }
    }

    /// Lets one new iPhone pair in the next two minutes.
    func openPairing() {
        guard let endpoint else { return }
        let w = endpoint.openPairingWindow(lifetime: fixtureAutoPair ? 3600 : 120)
        pairingOpenUntil = w.expiresAt
    }

    func answerPairing(_ match: Bool) {
        pairingCode = nil
        decision?.resume(returning: match); decision = nil
    }

    func setCompanionMode(_ on: Bool) {
        applyCompanionMode?(on)
        companionMode = CompanionMode.isOn
    }

    func forget(_ peer: TrustedPeer) {
        try? trust.revoke(publicKey: peer.publicKey)
        phones = (try? trust.peers()) ?? []
    }

    var fingerprint: String {
        (try? trust.identity()).map { DeviceIdentity.fingerprint($0.publicKey) } ?? "–"
    }

    private func askUser(_ code: String) async -> Bool {
        #if DEBUG || NOOP_DIAGNOSTICS
        if fixtureAutoPair {
            FileHandle.standardError.write(Data("[sync] pairing code \(code), accepted (fixture)\n".utf8))
            return true
        }
        #endif
        answerPairing(false)                       // a previous unanswered request is declined
        pairingCode = code
        return await withCheckedContinuation { decision = $0 }
    }

    /// This Mac's IPv4 addresses on the local network, for the user to type on the phone.
    static func localAddresses() -> [String] {
        var out: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return [] }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}
