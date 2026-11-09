import SwiftUI
import StrandDesign
import WhoopStore

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
// Settings: profile (feeds zones/calories/baselines), strap connection, keep-data-on-strap, and About.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your numbers, your strap, and how NOOP works. All on this Mac.") {
            PairingResetNotice()
            profileCard
            strapCard
            keepDataCard
            checkInCard
            aboutCard
        }
    }

    // MARK: - Profile

    private var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power heart-rate zones, calorie estimates and recovery baselines."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Age") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Stepper("Age", value: $profile.age, in: 13...100)
                            .labelsHidden()
                            .accessibilityLabel("Age, \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
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
                FormRow(label: "Weight") {
                    measureField(value: $profile.weightKg, unit: "kg",
                                 range: 30...250, step: 0.5, format: "%.1f",
                                 accessibility: "Weight in kilograms")
                }
                rowDivider
                FormRow(label: "Height") {
                    measureField(value: $profile.heightCm, unit: "cm",
                                 range: 120...230, step: 1, format: "%.0f",
                                 accessibility: "Height in centimetres")
                }
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            hrMaxField
                            Text("bpm")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accentInk
                                             : StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    // Blank/0 = estimate from age (Tanaka); typing a value overrides it.
    private var hrMaxField: some View {
        HStack(spacing: 10) {
            Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(profile.hrMaxOverride > 0
                                 ? StrandPalette.textPrimary
                                 : StrandPalette.textTertiary)
                .frame(minWidth: 44, alignment: .trailing)
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
    }

    // MARK: - Strap

    /// Remembered Bluetooth choice, the system's own answer when it blocks NOOP, and the next periodic reconnect.
    @ViewBuilder private var bluetoothAccess: some View {
        FormRow(label: "Use Bluetooth") {
            Toggle("Use Bluetooth", isOn: Binding(get: { live.bluetoothChoice != .declined },
                                                  set: { model.setBluetoothAllowed($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        if live.bluetoothChoice == .declined {
            Text("Bluetooth is off for NOOP, and stays off after relaunch until you turn it on here.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        } else if live.bluetoothDeniedBySystem {
            HStack(spacing: 12) {
                Text("macOS is blocking Bluetooth for NOOP.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningInk)
                Button("Open Privacy Settings") { model.openBluetoothPrivacySettings() }
                    .buttonStyle(.strandSecondary)
            }
        } else if let next = live.nextReconnectAt, !live.connected {
            Text("Connection lost — NOOP retries every 15 minutes while open. Next attempt \(next.formatted(date: .omitted, time: .shortened)).")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatePill(strapStatusTitle, tone: strapTone, pulsing: live.connected)
                    Spacer(minLength: 0)
                }
                bluetoothAccess
                StrapBatteryPanel()
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 12) {
                    Button {
                        model.scan()
                    } label: {
                        Label("Re-scan", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.strandPrimary)
                    .disabled(live.bluetoothChoice == .declined)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.strandSecondary)
                    .disabled(!live.connected && !live.bonded)

                    Button {
                        Task { await model.intelligence.recomputeAll() }
                    } label: {
                        Label(model.intelligence.computing ? "Recalculating…" : "Recalculate all scores",
                              systemImage: "function")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.strandSecondary)
                    .disabled(model.intelligence.computing)
                }
                if let info = live.deviceInfo {
                    // From the strap's standard Device Information service (read once per connection).
                    Text([info.model.map { "WHOOP \($0)" }, info.firmware.map { "firmware \($0)" }, info.hardware.map { "hardware \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                if let c = live.clock {
                    Text(String(format: "Strap clock: %.0f s %@ this Mac (stored times use the strap clock)",
                                abs(c.offset), c.offset >= 0 ? "behind" : "ahead of"))
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                Divider()
                Toggle("Notify when the battery drops below 20%", isOn: $notifyLow)
                    .toggleStyle(.switch)
                    .onChange(of: notifyLow) { on in if on { BatteryMonitor.requestAuthorization() } }
                Toggle("Notify when charging reaches 100%", isOn: $notifyFull)
                    .toggleStyle(.switch)
                    .onChange(of: notifyFull) { on in if on { BatteryMonitor.requestAuthorization() } }
                Text("Charging is what the strap reports: its charging events, or whether the charging pack is attached (NOOP asks a WHOOP 5.0 each time it reads the battery). The full-charge alert fires when the strap reports charging at 100%.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @AppStorage(BatteryMonitor.lowEnabledKey) private var notifyLow = true
    @AppStorage(BatteryMonitor.fullEnabledKey) private var notifyFull = true

    // MARK: - Keep data on strap

    @AppStorage(BLEManager.keepDataOnStrapKey) private var keepDataOnStrap = false

    // When ON, data is stored but never acknowledged, so the strap keeps its copy for another app (the trade-off: the strap stops after ~50 records per sync).
    private var keepDataCard: some View {
        SettingsSection(
            icon: "externaldrive.badge.checkmark",
            title: "Keep data on strap",
            blurb: "Each time NOOP confirms a batch of history, the strap moves its trim pointer past it (seen in the strap's own log); whether the WHOOP app can still read a trimmed batch is not known. With this on, NOOP saves everything it reads but never confirms."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Never delete data from the strap", isOn: $keepDataOnStrap)
                    .toggleStyle(.switch)
                Text("Limitation: the strap normally waits for a confirmation before sending the next batch, so with this on each sync may only reach the first batch of history. Sync with NOOP first, then let the WHOOP app clear the strap.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var strapStatusTitle: String {
        if live.bonded && live.connected { return "Bonded · streaming" }
        if live.connected { return "Connected" }
        if live.bonded { return "Bonded · idle" }
        return "Disconnected"
    }

    private var strapTone: StrandTone {
        if live.connected { return .positive }
        if live.bonded { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        if live.bonded && live.connected {
            return "Your strap is paired and sending data. Open Live for a real-time heart rate."
        }
        if live.connected { return "Connected. Finishing the secure pairing handshake…" }
        if live.bonded { return "Previously paired but not currently connected. Re-scan to reconnect." }
        return "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
    }

    // MARK: - Check-ins

    private var checkInCard: some View {
        SettingsSection(
            icon: "checklist",
            title: "Check-ins",
            blurb: "Optional morning and evening questions about things the strap can't see. Answers never change your scores."
        ) {
            CheckInSettingsForm()
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP — all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    StatePill("v0.1.0", tone: .neutral, showsDot: false)
                }

                Text("A standalone macOS companion for your WHOOP. Everything stays on this Mac — your history, your live stream, your numbers. Nothing is uploaded.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarningInk)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
                )

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: "WHOOP 4.0 protocol")
                    attribution(repo: "b-nnett/goose", note: "WHOOP 5.0 protocol")
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.accentInk)
                .accessibilityHidden(true)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - Section card

/// A grouped settings card: icon + title header, an explanatory blurb, then content.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: String
    let blurb: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(StrandPalette.accentInk)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .frame(minHeight: 32)
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
