import SwiftUI
import StrandDesign
import WhoopProtocol

/// Live — the connected strap in real time, on the shared widget system.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    @State private var logOpen = false

    var body: some View {
        ScreenScaffold(title: "Live", subtitle: connectionLine) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                controls
                LiveStatusCard()
                StrapHistoryCard()
                WidgetGrid(minColumn: 190) {
                    heartRateWidget
                    StrandWidget("Battery", symbol: "battery.75percent", tint: StrandPalette.statusPositive) {
                        VStack(alignment: .leading, spacing: 4) {
                            WidgetValue(live.batteryPct.map { "\(Int($0))" }, unit: "%")
                            Spacer(minLength: 0)
                            WidgetCaption(live.connected ? "Strap battery" : "Not connected")
                        }
                    }
                    StrandWidget("Last frame", symbol: "dot.radiowaves.left.and.right", tint: StrandPalette.metricCyan) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.lastFrameType ?? "—").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(live.lastFrameType == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            WidgetCaption("Most recent packet")
                        }
                    }
                    StrandWidget("Last event", symbol: "bolt.fill", tint: StrandPalette.metricAmber) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.lastEvent ?? "—").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(live.lastEvent == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                                .lineLimit(2).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                            WidgetCaption("From the strap")
                        }
                    }
                }
                logSection
            }
        }
        // The heavy realtime stream runs only while this screen is visible, to save strap battery.
        .onAppear { if live.bonded { model.startRealtimeHR(); model.getBattery() } }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: live.bonded) { bonded in
            if bonded { model.startRealtimeHR(); model.getBattery() }
        }
    }

    private var connectionLine: String {
        live.bonded ? "Connected to your WHOOP" : live.connected ? "Connecting to your WHOOP…" : "Your WHOOP is not connected"
    }

    // MARK: - Heart rate

    // Shows the smoothed bpm from AppModel (median), not the raw per-beat value, which swings with HRV.
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
                if !live.rr.isEmpty {
                    Text("R-R " + live.rr.suffix(4).map(String.init).joined(separator: " · ") + " ms")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    WidgetCaption(live.phase.title)
                }
                Spacer(minLength: 0)
            }
        }
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
