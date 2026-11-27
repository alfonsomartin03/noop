import SwiftUI
import CoreBluetooth
import WhoopProtocol
import WhoopStore
import StrandSync
import StrandDesign

/// NOOP iPhone app (#76–#79): pairs with the user's Mac, sends whatever the outbox holds, and shows the scores the Mac
/// sends back (cached for offline). It does NOT collect from the strap yet: switching the strap to the phone is an
/// owner-coordinated step (#78), so the outbox stays empty until then.
@main
struct PhoneApp: App {
    @StateObject private var sync = PhoneSyncModel()
    @StateObject private var collector = PhoneCollector()
    var body: some Scene {
        WindowGroup {
            PhoneHomeView().environmentObject(sync).environmentObject(collector)
                .onAppear {
                    collector.onDataSaved = { Task { await sync.load() } }
                    // After each strap download, hand the data to the Mac if one is paired (and reachable).
                    collector.onDownloadFinished = { Task { if !sync.macs.isEmpty { await sync.syncNow() } } }
                }
        }
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
            try await UndecodedForwarder.forward(into: s)
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
        // The same file the strap collector writes (StorePaths); it is this phone's outbox.
        let s = try await WhoopStore(path: try StorePaths.defaultDatabasePath())
        store = s
        return s
    }
}

struct PhoneHomeView: View {
    @EnvironmentObject var sync: PhoneSyncModel
    @EnvironmentObject var collector: PhoneCollector
    @State private var selectedDay: String?
    @State private var showSettings = false
    @State private var confirmCollect = false

    private var byDay: [String: DailySummary] { Dictionary(sync.scores.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a }) }
    private var activeDay: String { selectedDay ?? sync.scores.first?.day ?? PhoneWeekStrip.string(Date()) }
    private var active: DailySummary? { byDay[activeDay] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                syncStrip
                strapStrip
                PhoneWeekStrip(activeDay: activeDay, byDay: byDay) { selectedDay = $0 }
                if sync.scores.isEmpty {
                    StrandNotice(symbol: "sparkles", title: "No scores yet",
                                 message: sync.macs.isEmpty ? "Pair with your Mac to see the scores it calculates."
                                                            : "They appear here after your Mac has scored a day. Pull down to sync.")
                } else {
                    recoveryCard
                    sleepCard
                    strainCard
                    if let a = active {
                        Text("Scored on your Mac \(Date(timeIntervalSince1970: TimeInterval(a.changedAt)).formatted(date: .abbreviated, time: .shortened)). Shown offline too.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .refreshable { if !sync.macs.isEmpty { await sync.syncNow() } }
        .task { await sync.load() }
        .sheet(isPresented: $showSettings) { PhoneSettingsView().environmentObject(sync) }
        .alert("Pair with this Mac?", isPresented: Binding(get: { sync.pairingCode != nil },
                                                          set: { if !$0 { sync.answer(false) } })) {
            Button("Codes match") { sync.answer(true) }
            Button("Don't match", role: .cancel) { sync.answer(false) }
        } message: {
            Text("Check that your Mac shows \(sync.pairingCode ?? "").")
        }
    }

    // MARK: header + sync

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.greeting()).font(.system(size: 30, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 15)).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 38, height: 38).background(StrandPalette.surfaceRaised, in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private var syncStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: sync.macs.isEmpty ? "laptopcomputer.slash" : "laptopcomputer")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.accentInk)
                .frame(width: 32, height: 32).background(StrandPalette.accentMuted, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(sync.macs.first.map { $0.name } ?? "Not paired with a Mac")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                Text(syncDetail).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(sync.macs.isEmpty ? "Pair" : (sync.busy ? "Syncing…" : "Sync")) {
                if sync.macs.isEmpty { showSettings = true } else { Task { await sync.syncNow() } }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(LinearGradient(colors: [StrandPalette.accentHover, StrandPalette.accent], startPoint: .top, endPoint: .bottom),
                        in: Capsule())
            .disabled(sync.busy)
        }
        .padding(14)
        .strandSurface()
    }

    private var strapStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: collector.live.connected ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(collector.live.connected ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                .frame(width: 32, height: 32).background(StrandPalette.surfaceInset, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Strap").font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(collector.statusLine).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(collector.active ? "Stop" : "Collect") {
                if collector.active { collector.stop() } else { confirmCollect = true }
            }
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.accentInk)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(StrandPalette.accentMuted, in: Capsule())
        }
        .padding(14)
        .strandSurface()
        .confirmationDialog("Collect from your strap on this iPhone?", isPresented: $confirmCollect, titleVisibility: .visible) {
            Button("Collect from strap") { collector.start() }
        } message: {
            Text("Turn on companion mode on your Mac first (Settings ▸ iPhone sync), then pair the strap with this iPhone when asked. The strap talks to one device at a time.")
        }
    }

    private var syncDetail: String {
        if let m = sync.message, sync.busy == false, sync.lastSync == nil { return m }
        var parts: [String] = []
        if let last = sync.lastSync { parts.append("Synced \(last.formatted(date: .omitted, time: .shortened))") }
        if sync.pending > 0 { parts.append("\(sync.pending) batch\(sync.pending == 1 ? "" : "es") waiting") }
        if parts.isEmpty { return sync.macs.isEmpty ? "Tap Pair to connect" : "Pull down or tap Sync" }
        return parts.joined(separator: " · ")
    }

    // MARK: score cards (same layout language as the Mac's Overview)

    private var recoveryCard: some View {
        let score = active?.values["recovery"]
        let tint = score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.scoreMissing
        return StrandWidget("Recovery", symbol: "circle.dotted.circle", tint: tint) {
            HStack(spacing: 18) {
                ProgressRing(fraction: (score ?? 0) / 100, tint: tint, lineWidth: 12) {
                    VStack(spacing: 0) {
                        Text(score.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 38, weight: .bold).monospacedDigit())
                            .foregroundStyle(score == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        if score != nil { Text("%").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary) }
                    }
                }
                .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: 8) {
                    Text(score.map { StrandPalette.recoveryState($0).capitalized } ?? "No data")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.scoreInk(tint))
                    chip("HRV", active?.values["avgHrv"].map { "\(Int($0.rounded())) ms" }, StrandPalette.metricPurple)
                    chip("Resting HR", active?.values["restingHr"].map { "\(Int($0.rounded())) bpm" }, StrandPalette.metricRose)
                }
            }
        }
    }

    private var sleepCard: some View {
        let v = active?.values ?? [:]
        let total = v["totalSleepMin"]
        return StrandWidget("Sleep", symbol: "bed.double.fill", tint: StrandPalette.sleepLight) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(total.map(Self.hm) ?? "—")
                        .font(.system(size: 40, weight: .bold).monospacedDigit())
                        .foregroundStyle(total == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    Text(total == nil ? "No sleep recorded for this day" : "asleep")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                }
                if total != nil, v["deepMin"] != nil || v["remMin"] != nil || v["lightMin"] != nil {
                    SleepStageBar(deep: v["deepMin"], rem: v["remMin"], light: v["lightMin"])
                }
                chip("Efficiency", v["efficiency"].map { String(format: "%.0f%%", $0) }, StrandPalette.statusPositive)
                chip("Restorative", total == nil ? nil : Self.hm((v["deepMin"] ?? 0) + (v["remMin"] ?? 0)), StrandPalette.sleepDeep)
            }
        }
    }

    private var strainCard: some View {
        let v = active?.values["strain"]
        let tint = v.map { StrandPalette.strainColor($0) } ?? StrandPalette.scoreMissing
        return StrandWidget("Strain", symbol: "flame.fill", tint: tint) {
            HStack(spacing: 18) {
                ProgressRing(fraction: (v ?? 0) / 21, tint: tint, lineWidth: 12) {
                    VStack(spacing: 0) {
                        Text(v.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 36, weight: .bold).monospacedDigit())
                            .foregroundStyle(v == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        Text("of 21").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: 8) {
                    Text(v.map(Self.strainWord) ?? "No data")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.scoreInk(tint))
                    chip("Workouts", active?.values["exerciseCount"].map { "\(Int($0))" }, StrandPalette.metricAmber)
                }
            }
        }
    }

    /// Full-width rounded label + value pill, as under the Mac's score cards.
    private func chip(_ label: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint.opacity(0.8), radius: 3)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 4)
            Text(value ?? "—").font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(StrandPalette.surfaceInset, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    static func hm(_ minutes: Double) -> String { "\(Int(minutes) / 60)h \(Int(minutes) % 60)m" }

    static func strainWord(_ v: Double) -> String {
        switch v {
        case ..<6:  return "Light load"
        case ..<10: return "Moderate load"
        case ..<14: return "Strenuous"
        default:    return "All out"
        }
    }

    static func greeting(_ now: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// The Mac's week strip, sized for a phone: Monday…Sunday tiles with a recovery dot; the selected day glows.
struct PhoneWeekStrip: View {
    let activeDay: String
    let byDay: [String: DailySummary]
    let pick: (String) -> Void

    private static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }()
    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func date(_ day: String) -> Date? { parser.date(from: day) }
    static func string(_ d: Date) -> String { parser.string(from: d) }

    private var week: [String] {
        guard let d = Self.date(activeDay), let start = Self.cal.dateInterval(of: .weekOfYear, for: d)?.start else { return [] }
        return (0..<7).compactMap { Self.cal.date(byAdding: .day, value: $0, to: start) }.map(Self.string)
    }
    private var today: String { Self.string(Date()) }

    private func shift(_ delta: Int) {
        guard let d = Self.date(activeDay), let moved = Self.cal.date(byAdding: .day, value: 7 * delta, to: d) else { return }
        let t = Self.string(moved)
        pick(t > today ? today : t)
    }

    var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.left") { shift(-1) }
            ForEach(week, id: \.self) { tile($0) }
            arrow("chevron.right") { shift(1) }
                .opacity((week.last ?? "") >= today ? 0.3 : 1).disabled((week.last ?? "") >= today)
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(StrandPalette.accentInk).frame(width: 18, height: 44)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ day: String) -> some View {
        let date = Self.date(day)
        let selected = day == activeDay
        let future = day > today
        let rec = byDay[day]?.values["recovery"]
        let label = date.map { Self.cal.veryShortWeekdaySymbols[Self.cal.component(.weekday, from: $0) - 1] } ?? ""
        let num = date.map { Self.cal.component(.day, from: $0) } ?? 0
        return Button { pick(day) } label: {
            VStack(spacing: 3) {
                Text(label).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : StrandPalette.textTertiary)
                Text("\(num)").font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : StrandPalette.textPrimary)
                Circle().fill(rec.map { StrandPalette.recoveryColor($0) } ?? (byDay[day] != nil ? StrandPalette.textTertiary : .clear))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(LinearGradient(colors: [StrandPalette.accentHover, StrandPalette.accent],
                                                                   startPoint: .top, endPoint: .bottom))
                                   : AnyShapeStyle(StrandPalette.surfaceRaised))
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.25) : StrandPalette.hairline, lineWidth: 0.5))
            .shadow(color: selected ? StrandPalette.accent.opacity(0.5) : .clear, radius: 10, y: 3)
            .opacity(future ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(date.map { $0.formatted(date: .complete, time: .omitted) } ?? day)
        .accessibilityValue(rec.map { "recovery \(Int($0.rounded())) percent" } ?? "no score")
    }
}

/// Pairing, the Mac's address and device checks, out of the way of the scores.
struct PhoneSettingsView: View {
    @EnvironmentObject var sync: PhoneSyncModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bluetooth = BluetoothProbe()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Mac address (e.g. 192.168.1.20)", text: $sync.host)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", value: $sync.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                    if sync.macs.isEmpty {
                        Button("Pair with Mac") { Task { await sync.pair() } }.disabled(sync.busy)
                    }
                    ForEach(sync.macs, id: \.publicKey) { mac in
                        LabeledContent(mac.name, value: "key \(DeviceIdentity.fingerprint(mac.publicKey))")
                            .swipeActions { Button("Forget", role: .destructive) { sync.forget(mac) } }
                    }
                    if let m = sync.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Your Mac")
                } footer: {
                    Text("On the Mac: Settings ▸ iPhone sync ▸ Receive from iPhone, then Pair iPhone. Both devices must be on the same network. Swipe a paired Mac to forget it.")
                }
                Section("This iPhone") {
                    LabeledContent("Waiting for the Mac", value: "\(sync.pending) batch\(sync.pending == 1 ? "" : "es")")
                    LabeledContent("Bluetooth", value: bluetooth.state)
                    Button("Check Bluetooth") { bluetooth.check() }
                    LabeledContent("App version", value: PhoneHomeView.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Pair with this Mac?", isPresented: Binding(get: { sync.pairingCode != nil },
                                                              set: { if !$0 { sync.answer(false) } })) {
                Button("Codes match") { sync.answer(true) }
                Button("Don't match", role: .cancel) { sync.answer(false) }
            } message: {
                Text("Check that your Mac shows \(sync.pairingCode ?? "").")
            }
        }
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
