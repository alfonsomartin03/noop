import SwiftUI
import StrandDesign
import WhoopStore
import StrandSync

/// Settings ▸ General: a strap hero (status, battery, actions), then labelled groups of rows — connection, battery
/// alerts, profile, data, check-ins and about — in one reading column.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Settings read best as one calm column; wider windows leave the rest as margin.
    static let columnWidth: CGFloat = 780

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your strap, profile and data — all stored on this Mac.") {
            VStack(alignment: .leading, spacing: 32) {
                PairingResetNotice()
                strapHero
                connectionSection
                batteryAlertsSection
                ProfileCard(profile: profile)
                dataSection
                IPhoneSyncSection(sync: model.sync)
                checkInSection
                aboutSection
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
        }
    }

    // MARK: - Strap hero

    private var strapName: String {
        if let m = live.deviceInfo?.model { return "WHOOP \(m)" }
        return "Your strap"
    }

    private var strapHero: some View {
        StrandCard(padding: 24) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strapName)
                            .font(.system(size: 22, weight: .semibold)).tracking(-0.2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(strapStatusDetail)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    StatePill(strapStatusTitle, tone: strapTone, pulsing: live.connected)
                }
                StrapBatteryPanel()
                HStack(spacing: 10) {
                    Button {
                        model.scan()
                    } label: {
                        Label(live.bonded ? "Reconnect" : "Scan for strap", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.strandPrimary)
                    .disabled(live.bluetoothChoice == .declined)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.strandSecondary)
                    .disabled(!live.connected && !live.bonded)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var strapStatusTitle: String {
        if live.bonded && live.connected { return "Connected" }
        if live.connected { return "Pairing" }
        if live.bonded { return "Paired · idle" }
        return "Disconnected"
    }

    private var strapTone: StrandTone {
        if live.connected { return .positive }
        if live.bonded { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        if live.bonded && live.connected { return "Paired and sending data over Bluetooth — no WHOOP app, no cloud." }
        if live.connected { return "Connected. Finishing the secure pairing handshake…" }
        if live.bonded { return "Paired before but not connected right now." }
        return "Put your WHOOP nearby and scan to pair."
    }

    // MARK: - Connection

    private var connectionSection: some View {
        SettingsSection(icon: "antenna.radiowaves.left.and.right", title: "Connection") {
            SettingsRow(title: "Use Bluetooth", detail: bluetoothDetail) {
                Toggle("Use Bluetooth", isOn: Binding(get: { live.bluetoothChoice != .declined },
                                                      set: { model.setBluetoothAllowed($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if live.bluetoothChoice != .declined, live.bluetoothDeniedBySystem {
                SettingsDivider()
                SettingsRow(title: "macOS is blocking Bluetooth", detail: "Allow NOOP in Privacy & Security.",
                            detailTone: StrandPalette.statusWarningInk) {
                    Button("Open Settings") { model.openBluetoothPrivacySettings() }
                        .buttonStyle(.strandSecondary)
                }
            }
            if let info = live.deviceInfo, info.firmware != nil || info.hardware != nil {
                SettingsDivider()
                SettingsRow(title: "Firmware", detail: info.hardware.map { "Hardware \($0)" }) {
                    SettingsValue(info.firmware ?? "Unknown")
                }
            }
            if let c = live.clock {
                SettingsDivider()
                SettingsRow(title: "Strap clock", detail: "Stored times use the strap clock.") {
                    SettingsValue(String(format: "%.0f s %@", abs(c.offset), c.offset >= 0 ? "behind" : "ahead"))
                }
            }
        }
    }

    private var bluetoothDetail: String? {
        if live.bluetoothChoice == .declined { return "Off for NOOP — stays off after relaunch until you turn it on." }
        if !live.bluetoothDeniedBySystem, let next = live.nextReconnectAt, !live.connected {
            return "Retrying every 15 minutes while open · next at \(next.formatted(date: .omitted, time: .shortened))"
        }
        return nil
    }

    // MARK: - Battery alerts

    @AppStorage(BatteryMonitor.lowEnabledKey) private var notifyLow = true
    @AppStorage(BatteryMonitor.fullEnabledKey) private var notifyFull = true

    private var batteryAlertsSection: some View {
        SettingsSection(
            icon: "bell.badge",
            title: "Battery alerts",
            footer: "Charging is what the strap reports: its charging events and, on WHOOP 5.0, whether the pack is attached. A rising percentage alone shows as “likely”, never as charging."
        ) {
            SettingsRow(title: "Low battery", detail: "When the strap drops below 20%") {
                Toggle("Low battery alert", isOn: $notifyLow)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: notifyLow) { on in if on { BatteryMonitor.requestAuthorization() } }
            }
            SettingsDivider()
            SettingsRow(title: "Fully charged", detail: "When the strap reports charging at 100%") {
                Toggle("Fully charged alert", isOn: $notifyFull)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: notifyFull) { on in if on { BatteryMonitor.requestAuthorization() } }
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection(icon: "externaldrive", title: "Data") {
            if LaunchMode.diagnostics {
                ResearchCaptureRow()
                SettingsDivider()
            }
            SettingsRow(title: "Recalculate scores", detail: "Re-score every stored day with the current methods") {
                Button(model.intelligence.computing ? "Recalculating…" : "Recalculate") {
                    Task { await model.intelligence.recomputeAll() }
                }
                .buttonStyle(.strandSecondary)
                .disabled(model.intelligence.computing)
            }
        }
    }

    // MARK: - Check-ins

    private var checkInSection: some View {
        SettingsSection(
            icon: "checklist",
            title: "Check-ins",
            subtitle: "Optional morning and evening questions about things the strap can't see. Answers never change your scores.",
            footer: CheckInSettingsForm.intro
        ) {
            CheckInSettingsForm(grouped: true)
        }
    }

    // MARK: - About

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    private var aboutSection: some View {
        SettingsSection(icon: "info.circle", title: "About") {
            SettingsRow(title: "NOOP", detail: "A standalone Mac companion for your WHOOP. Your history, live stream and numbers stay on this Mac; nothing is uploaded.") {
                SettingsValue("Version \(appVersion)")
            }
            SettingsDivider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cross.case")
                    .font(.system(size: 13))
                    .foregroundStyle(StrandPalette.statusWarningInk)
                    .accessibilityHidden(true)
                Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 14)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Built on open-source BLE reverse-engineering work — thank you.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                attribution(repo: "johnmiddleton12/my-whoop", note: "WHOOP 4.0 protocol")
                attribution(repo: "b-nnett/goose", note: "WHOOP 5.0 protocol")
            }
            .padding(.vertical, 14)
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(note)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section, rows

/// A settings group: a small title (and optional subtitle) above a card of rows, with an optional footnote below —
/// the inset-grouped pattern, so each card holds only controls and short labels.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: icon).foregroundStyle(StrandPalette.accentInk)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strandSurface(cornerRadius: 18)
            if let footer {
                Text(footer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One settings row: title (and a short detail under it) on the left, the control on the right.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var detailTone: Color? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(StrandFont.caption)
                        .foregroundStyle(detailTone ?? StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }
}

/// A read-only value on the right of a row.
private struct SettingsValue: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(StrandPalette.textSecondary)
            .multilineTextAlignment(.trailing)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1)
    }
}

// MARK: - iPhone sync (#79)

/// Receiver switch, pairing and paired phones. The pairing sheet shows the code the phone must also show.
private struct IPhoneSyncSection: View {
    @ObservedObject var sync: MacSyncService
    @State private var addresses: [String] = []

    var body: some View {
        SettingsSection(icon: "iphone", title: "iPhone sync",
                        subtitle: "A paired iPhone can collect from your strap and hand the data to this Mac, which keeps it and scores it. Works on your local network only.",
                        footer: "Data from the iPhone travels encrypted and only to phones you paired here. While the receiver is on, this Mac still collects from the strap itself.") {
            SettingsRow(title: "Receive from iPhone", detail: detail) {
                Toggle("", isOn: Binding(get: { sync.receiving }, set: { on in Task { await sync.setReceiving(on) } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if sync.receiving {
                SettingsDivider()
                SettingsRow(title: "Pair an iPhone", detail: pairingDetail) {
                    Button(sync.pairingOpenUntil == nil ? "Pair iPhone" : "Waiting…") { sync.openPairing() }
                        .buttonStyle(.strandSecondary)
                        .disabled(sync.pairingOpenUntil != nil)
                }
            }
            SettingsDivider()
            SettingsRow(title: "Let the iPhone collect (companion mode)",
                        detail: sync.companionMode
                            ? "This Mac no longer talks to the strap: no scanning, reconnects, clock or alarm commands. Strap alarms can't be set from here. Turn off to collect on this Mac again (the strap must be re-paired to it)."
                            : "Turn on before pairing the strap with your iPhone. History and scores stay on this Mac.",
                        detailTone: sync.companionMode ? StrandPalette.statusWarningInk : nil) {
                Toggle("", isOn: Binding(get: { sync.companionMode }, set: { sync.setCompanionMode($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            ForEach(sync.phones, id: \.publicKey) { phone in
                SettingsDivider()
                SettingsRow(title: phone.name,
                            detail: "Paired \(Date(timeIntervalSince1970: TimeInterval(phone.pairedAt)).formatted(date: .abbreviated, time: .omitted)) · key \(DeviceIdentity.fingerprint(phone.publicKey))") {
                    Button("Forget") { sync.forget(phone) }.buttonStyle(.strandSecondary)
                }
            }
        }
        .onAppear { addresses = MacSyncService.localAddresses() }
        .sheet(isPresented: Binding(get: { sync.pairingCode != nil }, set: { if !$0 { sync.answerPairing(false) } })) {
            PairingCodeSheet(code: sync.pairingCode ?? "", answer: sync.answerPairing)
        }
    }

    private var detail: String {
        guard sync.receiving, let port = sync.port else { return sync.status }
        let where_ = addresses.isEmpty ? "this Mac" : addresses.joined(separator: " or ")
        var s = "On the iPhone, enter \(where_), port \(port)."
        if let last = sync.lastUpload { s += " Last upload \(last.formatted(date: .omitted, time: .shortened))." }
        return s
    }

    private var pairingDetail: String {
        if let until = sync.pairingOpenUntil, until > Date() {
            return "Open on the iPhone now and tap Pair. Open until \(until.formatted(date: .omitted, time: .shortened))."
        }
        return "Opens for two minutes, for one iPhone."
    }
}

private struct PairingCodeSheet: View {
    let code: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair this iPhone?").font(.system(size: 17, weight: .semibold))
            Text("Check that the iPhone shows the same code.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(code.isEmpty ? "------" : "\(code.prefix(3)) \(code.suffix(3))")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            HStack(spacing: 12) {
                Button("Codes don't match") { answer(false) }.buttonStyle(.strandSecondary)
                Button("Codes match") { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 360)
    }
}

// MARK: - Profile

/// Settings ▸ General ▸ Profile: two groups (body numbers that drive zones/calories/baselines; the optional Health-age
/// inputs), every row label-left / control-right with notes under the label, values and steppers in one column.
/// Internal so the render harness can host it with a throwaway `ProfileStore`.
struct ProfileCard: View {
    @ObservedObject var profile: ProfileStore

    var body: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            subtitle: "These power heart-rate zones, calorie estimates and recovery baselines."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                groupHeader("Body")
                    .padding(.top, 14)
                ageRow
                rowDivider
                ProfileRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Sex")
                }
                rowDivider
                ProfileRow(label: "Weight") {
                    stepperValue(String(format: "%.1f", profile.weightKg), unit: "kg") {
                        Stepper("Weight in kilograms", value: $profile.weightKg, in: 30...250, step: 0.5)
                    }
                }
                rowDivider
                ProfileRow(label: "Height") {
                    stepperValue(String(format: "%.0f", profile.heightCm), unit: "cm") {
                        Stepper("Height in centimetres", value: $profile.heightCm, in: 120...230, step: 1)
                    }
                }
                rowDivider
                hrMaxRow

                groupHeader("Health age · optional")
                    .padding(.top, 20)
                Text("For the functional-age estimate on the Health page. A VO₂max test counts for 2 years.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                birthDateRow
                rowDivider
                vo2Rows
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private var ageRow: some View {
        if profile.birthDate != nil {
            ProfileRow(label: "Age", note: "From your birth date") {
                stepperValue("\(profile.age)", unit: "years") { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    .accessibilityElement(children: .combine)
            }
        } else {
            ProfileRow(label: "Age") {
                stepperValue("\(profile.age)", unit: "years") {
                    Stepper("Age", value: $profile.age, in: 13...100)
                        .accessibilityLabel("Age, \(profile.age) years")
                }
            }
        }
    }

    private var hrMaxRow: some View {
        ProfileRow(label: "Max heart rate",
                   note: profile.hrMaxOverride > 0 ? "Set by you" : "Estimated from age (Tanaka)",
                   action: profile.hrMaxOverride > 0 ? ("Use estimate", { profile.hrMaxOverride = 0 }) : nil) {
            stepperValue("\(profile.hrMax)", unit: "bpm", dimmed: profile.hrMaxOverride == 0) {
                Stepper("Max heart rate", value: Binding(get: { profile.hrMax },
                                                         set: { profile.hrMaxOverride = $0 }),
                        in: 100...230, step: 1)
                    .accessibilityLabel("Max heart rate, \(profile.hrMax) bpm, \(profile.hrMaxOverride > 0 ? "set by you" : "estimated")")
            }
        }
    }

    @ViewBuilder private var birthDateRow: some View {
        if let b = profile.birthDate {
            ProfileRow(label: "Birth date", action: ("Remove", { profile.birthDate = nil })) {
                DatePicker("Birth date", selection: Binding(get: { b }, set: { profile.birthDate = $0 }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("Birth date")
            }
        } else {
            ProfileRow(label: "Birth date", note: "Keeps your age up to date") {
                addButton("Add birth date") {
                    profile.birthDate = Calendar.current.date(byAdding: .year, value: -profile.age, to: Date())
                }
            }
        }
    }

    @ViewBuilder private var vo2Rows: some View {
        if let v = profile.measuredVO2 {
            ProfileRow(label: "Measured VO₂max", action: ("Remove", { profile.measuredVO2 = nil })) {
                stepperValue(String(format: "%.1f", v), unit: "ml/kg/min") {
                    Stepper("Measured VO₂max in millilitres per kilogram per minute",
                            value: Binding(get: { v }, set: { profile.measuredVO2 = $0 }), in: 10...90, step: 0.5)
                }
            }
            rowDivider
            ProfileRow(label: "Test") {
                HStack(spacing: 8) {
                    Picker("Test", selection: $profile.measuredVO2Method) {
                        ForEach(["Lab test (CPET)", "Field test", "Other measured test"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("VO₂max test method")
                    DatePicker("Test date", selection: $profile.measuredVO2Date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("VO₂max test date")
                }
            }
        } else {
            ProfileRow(label: "Measured VO₂max", note: "From a fitness test, not a watch estimate") {
                addButton("Add test result") { profile.measuredVO2 = 40; profile.measuredVO2Date = Date() }
            }
        }
    }

    // MARK: Pieces

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// Tabular value + unit in a fixed-width column, then the stepper (or nothing), so every stepper lines up.
    private func stepperValue<S: View>(_ value: String, unit: String, dimmed: Bool = false,
                                       @ViewBuilder stepper: () -> S) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(dimmed ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            stepper()
                .labelsHidden()
                .frame(width: 20, alignment: .trailing)
        }
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .controlSize(.small)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
    }
}

/// Profile row: label (with an optional note and inline action under it) on the left, control on the right.
private struct ProfileRow<Control: View>: View {
    let label: String
    var note: String? = nil
    var action: (String, () -> Void)? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if note != nil || action != nil {
                    HStack(spacing: 6) {
                        if let note {
                            Text(note)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let action {
                            Button(action.0, action: action.1)
                                .buttonStyle(.plain)
                                .font(StrandFont.footnote.weight(.medium))
                                .foregroundStyle(StrandPalette.accentInk)
                                .accessibilityLabel("\(action.0) \(label.lowercased())")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        .frame(width: 720, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif

/// Settings ▸ General ▸ Data: start/stop the bounded full-frame research capture (`ResearchCapture`, #25).
/// For up to 7 days every history record's complete bytes are kept with firmware and strap time, on this Mac only
/// (Application Support/OpenWhoop/research-history, about 20 MB a day); nothing is changed on the strap.
private struct ResearchCaptureRow: View {
    @State private var capture = ResearchCapture.load()
    @State private var now = Date()

    var body: some View {
        SettingsRow(title: "Research capture",
                    detail: "Keep complete history records for 7 days so undecoded fields can be studied (about 20 MB a day, this Mac only). " + status) {
            if let c = capture, c.isActive(at: now) {
                Button("Stop") { var s = c; s.stoppedReason = "stopped by you"; s.save(); refresh() }
                    .buttonStyle(.strandSecondary)
            } else {
                Button("Start") { ResearchCapture.start().save(); refresh() }
                    .buttonStyle(.strandSecondary)
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() { capture = ResearchCapture.load(); now = Date() }

    private var status: String {
        guard let c = capture else { return "Off." }
        let size = ByteCountFormatter.string(fromByteCount: Int64(c.bytesWritten), countStyle: .file)
        let end = c.until.formatted(date: .abbreviated, time: .shortened)
        if c.isActive(at: now) { return "On until \(end) · \(size) kept. Applies from the next sync." }
        return "Off (\(c.stoppedReason ?? "ended \(end)")) · \(size) kept."
    }
}
