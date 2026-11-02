import SwiftUI
import StrandDesign
import WhoopProtocol

/// Live — the connected strap in real time, on the shared widget system.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var heart: LiveHeartRate

    /// The shared smoothed, spike-filtered live HR (see `LiveHeartRate`).
    private var displayHR: Int? { heart.bpm }
    @EnvironmentObject private var profile: ProfileStore
    @State private var logOpen = false
    @AppStorage("noop.live.detailsOpen") private var detailsOpen = false

    // At a glance first: live heart rate and battery, the two things this sheet is opened for. Everything technical
    // (connection controls, link status, sync, packets, log) sits in one collapsed section below.
    var body: some View {
        ScreenScaffold(title: "Live", subtitle: connectionLine) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !live.connected { connectNotice }
                HStack(alignment: .top, spacing: NoopMetrics.gap) {
                    heartRateWidget.frame(maxWidth: .infinity, maxHeight: .infinity)
                    StrandWidget("Battery", symbol: BatteryPresentation(live: live).symbol, tint: BatteryPresentation(live: live).tint, size: .large) {
                        VStack(alignment: .leading, spacing: 0) {
                            Spacer(minLength: 0)
                            StrapBatteryPanel()
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)   // both cards take the taller one's height
                detailsSection
            }
        }
        // The heavy realtime stream runs only while this screen is visible, to save strap battery.
        .onAppear { if live.bonded { model.startRealtimeHR(); model.getBattery() } }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: live.bonded) { bonded in
            if bonded { model.startRealtimeHR(); model.getBattery() }
        }
    }

    private var connectNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textSecondary)
            Text("Keep your WHOOP nearby to see live heart rate and battery.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Connect") { model.scan() }.buttonStyle(.strandPrimary)
        }
        .padding(NoopMetrics.cardPadding)
        .strandSurface()
    }

    // MARK: - Details (collapsed)

    private var detailsSection: some View {
        DisclosureGroup(isExpanded: $detailsOpen) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                controls
                LiveStatusCard()
                StrapHistoryCard()
                WidgetGrid(minColumn: 190) {
                    StrandWidget("Last frame", symbol: "dot.radiowaves.left.and.right", tint: StrandPalette.metricCyan) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.lastFrameType ?? "—").font(StrandFont.headline)
                                .foregroundStyle(live.lastFrameType == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            WidgetCaption("Most recent packet")
                        }
                    }
                    StrandWidget("Last event", symbol: "bolt.fill", tint: StrandPalette.metricAmber) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.lastEvent ?? "—").font(StrandFont.headline)
                                .foregroundStyle(live.lastEvent == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            WidgetCaption("From the strap")
                        }
                    }
                    StrandWidget("R-R intervals", symbol: "waveform.path.ecg", tint: StrandPalette.metricPurple) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.rr.isEmpty ? "—" : live.rr.suffix(4).map(String.init).joined(separator: " · "))
                                .font(StrandFont.number(15, weight: .semibold))
                                .foregroundStyle(live.rr.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            Spacer(minLength: 0)
                            WidgetCaption("Latest beats, ms")
                        }
                    }
                }
                logSection
            }
            .padding(.top, NoopMetrics.gap)
        } label: {
            Text("Connection details").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var connectionLine: String {
        live.bonded ? "Connected to your WHOOP" : live.connected ? "Connecting to your WHOOP…" : "Your WHOOP is not connected"
    }

    // MARK: - Heart rate

    // The shared smoothed bpm (LiveHeartRate), not the raw per-beat value, which swings with HRV.
    private var heartRateWidget: some View {
        StrandWidget("Heart rate", symbol: "heart.fill", tint: StrandPalette.metricRose, size: .large) {
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayHR.map(String.init) ?? "—")
                        .font(.system(size: 88, weight: .semibold).monospacedDigit())
                        .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: displayHR)
                    if displayHR != nil {
                        Text("bpm").font(.system(size: 18, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(heartCaption).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// "Zone 2 · 64% of max" while streaming, else the connection phase.
    private var heartCaption: String {
        guard let hr = displayHR else { return live.phase.title }
        let pct = Int((Double(hr) / Double(max(profile.hrMax, 1)) * 100).rounded())
        return "\(LiveHeartRate.zoneLabel(LiveHeartRate.zone(bpm: hr, maxHR: profile.hrMax))) · \(pct)% of max"
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { model.scan() } label: {
                Label(live.connected ? "Re-scan" : "Connect", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.strandPrimary)

            Button(role: .destructive) { model.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                .buttonStyle(.strandSecondary)
                .disabled(!live.connected)
            Spacer()
        }
        .controlSize(.large)
    }

    // MARK: - Strap log (diagnostics → collapsed)

    // Diagnostics log is collapsed by default and auto-scrolls to the newest line.
    private var logSection: some View {
        DisclosureGroup(isExpanded: $logOpen) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
                            Text(line).font(StrandFont.mono(12))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                }
                .frame(height: 220)
                .onChange(of: live.log.count) { _ in
                    if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text("Connection log").font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("\(live.log.count) lines").font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(NoopMetrics.cardPadding)
        .strandSurface()
    }
}
