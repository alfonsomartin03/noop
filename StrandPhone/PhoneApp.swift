import SwiftUI
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// NOOP iPhone shell (#76): proves the phone target installs, links the shared packages, can open a local store
/// and can ask for Bluetooth. It does NOT scan, connect or talk to a strap: switching the strap to the phone is an
/// owner-coordinated step (docs/sprints/PHONE_MAC_ARCHIVE.md, package 1).
@main
struct PhoneApp: App {
    var body: some Scene {
        WindowGroup { PhoneHomeView() }
    }
}

struct PhoneHomeView: View {
    @StateObject private var bluetooth = BluetoothProbe()
    @State private var store = "Not opened"

    var body: some View {
        NavigationStack {
            List {
                Section("NOOP collector") {
                    Text("Downloads strap data, keeps it until your Mac has it, then shows the scores your Mac sends back. Not connected to a strap yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Checks") {
                    row("App version", Self.version)
                    row("Protocol schema", WhoopProtocolInfo.schemaResourceURL() == nil ? "Missing" : "Bundled")
                    row("Local store", store)
                    row("Bluetooth", bluetooth.state)
                    Button("Check Bluetooth") { bluetooth.check() }
                }
            }
            .navigationTitle("NOOP")
            .task { store = await PhoneHomeView.openStore() }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Opens (creating if needed) an empty store in Application Support to prove GRDB + migrations run on the phone.
    static func openStore() async -> String {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("OpenWhoop", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try await WhoopStore(path: dir.appendingPathComponent("phone-outbox.sqlite").path)
            return "Open, schema v\(WhoopStoreInfo.schemaVersion)"
        } catch {
            return "Failed: \(error.localizedDescription)"
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
