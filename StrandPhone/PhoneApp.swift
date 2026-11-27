import SwiftUI
import CoreBluetooth
import WhoopProtocol
import WhoopStore
import StrandSync

/// NOOP iPhone app (#76–#79): pairs with the user's Mac, sends whatever the outbox holds, and shows the scores the Mac
/// sends back (cached for offline). It does NOT collect from the strap yet: switching the strap to the phone is an
/// owner-coordinated step (#78), so the outbox stays empty until then.
@main
struct PhoneApp: App {
    @StateObject private var sync = PhoneSyncModel()
    var body: some Scene {
        WindowGroup { PhoneHomeView().environmentObject(sync) }
    }
}

@MainActor
final class PhoneSyncModel: ObservableObject {
    @AppStorage("noop.sync.macHost") var host = ""
    @AppStorage("noop.sync.macPort") var port = Int(MacSyncListener.defaultPort)
    @Published var macs: [TrustedPeer] = []
    @Published var busy = false
    @Published var message: String?
    @Published var scores: [DailySummary] = []
    @Published var pending = 0
    @Published var lastSync: Date?
    /// Set while pairing: the code to compare with the Mac's screen.
    @Published var pairingCode: String?
    private var decision: CheckedContinuation<Bool, Never>?

    let trust = KeychainTrustStore()
    private var store: WhoopStore?
    private var client: PhoneSyncClient?

    init() { macs = (try? trust.peers()) ?? [] }

    func load() async {
        do {
            let s = try await openStore()
            scores = try await s.cachedSummaries().reversed()
            pending = try await s.pendingOutboxBatches().count
        } catch { message = "Could not open local storage: \(error.localizedDescription)" }
    }

    func pair() async {
        guard let c = makeClient() else { return }
        busy = true; defer { busy = false }
        do {
            let mac = try await c.pair(phoneName: UIDevice.current.name) { code in await self.ask(code) }
            macs = (try? trust.peers()) ?? []
            message = "Paired with \(mac.name)."
        } catch {
            message = "Pairing didn't finish. Turn on “Pair iPhone” on the Mac and try again."
        }
        pairingCode = nil
    }

    func syncNow() async {
        guard let c = makeClient() else { return }
        busy = true; defer { busy = false }
        do {
            let s = try await openStore()
            let r = try await PhoneOutbox(store: s).sync(over: c)
            let changed = try await c.refreshScores(into: s)
            lastSync = Date()
            message = r.stoppedAt == nil ? "Up to date. \(changed) day\(changed == 1 ? "" : "s") updated."
                                         : "Couldn't send everything; it stays on this iPhone until the next try."
        } catch {
            message = "Couldn't reach your Mac. Is NOOP open with “Receive from iPhone” on?"
        }
        c.disconnect()
        await load()
    }

    func forget(_ mac: TrustedPeer) {
        try? trust.revoke(publicKey: mac.publicKey)
        macs = (try? trust.peers()) ?? []
    }

    func answer(_ match: Bool) { pairingCode = nil; decision?.resume(returning: match); decision = nil }

    private func ask(_ code: String) async -> Bool {
        pairingCode = code
        return await withCheckedContinuation { decision = $0 }
    }

    private func makeClient() -> PhoneSyncClient? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, let p = UInt16(exactly: port) else { message = "Enter your Mac's address first."; return nil }
        do {
            let id = try trust.identity()
            return PhoneSyncClient(identity: id, trust: trust) { try await NWByteStream.connect(host: h, port: p) }
        } catch { message = "Keychain unavailable: \(error.localizedDescription)"; return nil }
    }

    private func openStore() async throws -> WhoopStore {
        if let store { return store }
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try await WhoopStore(path: dir.appendingPathComponent("phone-outbox.sqlite").path)
        store = s
        return s
    }
}

struct PhoneHomeView: View {
    @EnvironmentObject var sync: PhoneSyncModel
    @StateObject private var bluetooth = BluetoothProbe()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Collects from your strap, keeps the data until your Mac has it, then shows the scores your Mac sends back. Not collecting from the strap yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                macSection
                scoresSection
                Section("Checks") {
                    LabeledContent("App version", value: Self.version)
                    LabeledContent("Waiting for the Mac", value: "\(sync.pending) batch\(sync.pending == 1 ? "" : "es")")
                    LabeledContent("Bluetooth", value: bluetooth.state)
                    Button("Check Bluetooth") { bluetooth.check() }
                }
            }
            .navigationTitle("NOOP")
            .task { await sync.load() }
            .refreshable { if !sync.macs.isEmpty { await sync.syncNow() } }
            .alert("Pair with this Mac?", isPresented: Binding(get: { sync.pairingCode != nil },
                                                              set: { if !$0 { sync.answer(false) } })) {
                Button("Codes match") { sync.answer(true) }
                Button("Don't match", role: .cancel) { sync.answer(false) }
            } message: {
                Text("Check that your Mac shows \(sync.pairingCode ?? "").")
            }
        }
    }

    @ViewBuilder private var macSection: some View {
        Section {
            TextField("Mac address (e.g. 192.168.1.20)", text: $sync.host)
                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Port", value: $sync.port, format: .number.grouping(.never)).keyboardType(.numberPad)
            if sync.macs.isEmpty {
                Button("Pair with Mac") { Task { await sync.pair() } }.disabled(sync.busy)
            } else {
                ForEach(sync.macs, id: \.publicKey) { mac in
                    LabeledContent(mac.name, value: "key \(DeviceIdentity.fingerprint(mac.publicKey))")
                        .swipeActions { Button("Forget", role: .destructive) { sync.forget(mac) } }
                }
                Button(sync.busy ? "Syncing…" : "Sync now") { Task { await sync.syncNow() } }.disabled(sync.busy)
            }
            if let m = sync.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Your Mac")
        } footer: {
            Text("On the Mac: Settings ▸ iPhone sync ▸ Receive from iPhone. Both devices must be on the same network.")
        }
    }

    @ViewBuilder private var scoresSection: some View {
        Section {
            if sync.scores.isEmpty {
                Text("No scores yet. They appear after your Mac has scored a day.").foregroundStyle(.secondary)
            }
            ForEach(sync.scores.prefix(30), id: \.day) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.day).font(.headline)
                    HStack(spacing: 14) {
                        metric("Recovery", s.values["recovery"].map { "\(Int($0.rounded()))%" })
                        metric("Strain", s.values["strain"].map { String(format: "%.1f", $0) })
                        metric("Sleep", s.values["totalSleepMin"].map { "\(Int($0) / 60)h \(Int($0) % 60)m" })
                    }
                    Text("Scored on your Mac \(Date(timeIntervalSince1970: TimeInterval(s.changedAt)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Scores from your Mac")
        } footer: {
            if let last = sync.lastSync { Text("Last sync \(last.formatted(date: .omitted, time: .shortened)). Shown offline too.") }
        }
    }

    private func metric(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.subheadline.monospacedDigit())
                .accessibilityLabel(value == nil ? "not available" : value!)
        }
    }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Creates a central only when asked, so the permission prompt appears on a tap, never at launch. Never scans.
@MainActor
final class BluetoothProbe: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var state = "Not checked"
    private var central: CBCentralManager?

    func check() {
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) } else { update() }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in self.update() }
    }

    private func update() {
        switch central?.state {
        case .poweredOn: state = "Ready"
        case .poweredOff: state = "Off"
        case .unauthorized: state = "Not allowed"
        case .unsupported: state = "Unsupported"
        case .resetting: state = "Resetting"
        default: state = "Unknown"
        }
    }
}
