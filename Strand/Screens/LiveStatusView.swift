import SwiftUI
import StrandDesign

/// Where the live data pipeline currently stands, derived from `LiveState` telemetry. Used so a screen
/// that has no numbers yet can say *why* instead of showing blanks.
// One state describing the whole live pipeline, so screens can explain WHY there is no data instead of showing blanks.
enum LivePhase: Equatable {
    case disconnected          // no link to the strap
    case pairing               // linked, not yet bonded/authenticated
    case waiting               // bonded, nothing received yet
    case strapDataNoHR         // strap frames arriving, but no heart-rate value
    case live                  // heart rate flowing
    case stalled               // heart rate was flowing, but nothing for a while

    var title: String {
        switch self {
        case .disconnected:   return "Not connected"
        case .pairing:        return "Pairing with your strap…"
        case .waiting:        return "Connected — waiting for data…"
        case .strapDataNoHR:  return "Receiving strap data — no heart rate yet"
        case .live:           return "Live"
        case .stalled:        return "Data paused — reconnecting…"
        }
    }

    var isBusy: Bool { self == .pairing || self == .waiting || self == .stalled }
}

extension LiveState {
    // Evaluated top-down: not connected -> not bonded -> live (HR fresh within 15 s) -> stalled -> strap-only data -> waiting.
    var phase: LivePhase {
        guard connected else { return .disconnected }
        guard bonded else { return .pairing }
        let fresh = lastDataAt.map { Date().timeIntervalSince($0) < 15 } ?? false
        if heartRate != nil && fresh { return .live }
        if hrPackets > 0 && !fresh { return .stalled }
        if strapFrames > 0 { return .strapDataNoHR }
        return .waiting
    }
}

/// The pipeline card: four steps with a check, spinner or dash, plus one plain-English explanation.
struct LiveStatusCard: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Re-evaluate "fresh" a few times a second without depending on new data arriving.
        // Re-checks freshness every 2 s even if no new data arrives, so 'stalled' appears on its own.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let phase = live.phase
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if phase.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: phase == .live ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(phase == .live ? StrandPalette.statusPositiveInk : StrandPalette.textTertiary) }
                    Text(phase.title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 9) {
                    step("Bluetooth link", state: live.connected ? .done : .pending(phase == .disconnected))
                    step("Secure pairing", state: live.bonded ? .done : (live.connected ? .active : .pending(false)))
                    step("Heart-rate service",
                         state: live.hrPackets > 0 ? .done : (live.bonded ? .active : .pending(false)),
                         detail: live.hrPackets > 0 ? "\(live.hrPackets) readings"
                               : (live.hrSubscribed ? "subscribed · no readings yet" : (live.bonded ? "subscribing…" : nil)))
                    step("Strap data channel",
                         state: live.strapFrames > 0 ? .done : (live.bonded ? .active : .pending(false)),
                         detail: live.strapFrames > 0 ? "\(live.strapFrames) frames" : nil)
                }
                if live.connected {
                    let supported = live.bonded && live.family != "whoop5"
                    Toggle(isOn: Binding(get: { live.hrBroadcast ?? (live.hrPackets > 0) },
                                         set: { model.setHRBroadcast($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Heart-rate broadcast").font(.system(size: 13))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(live.family == "whoop5"
                                 ? "Not available for WHOOP 5.0 / MG yet. Turn it on in the WHOOP app."
                                 : (live.bonded
                                    ? "Lets NOOP read live heart rate over Bluetooth. While on, other nearby apps can read it too."
                                    : "Available once the strap is paired."))
                                .font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!supported)
                }
                if let note = explanation(phase) {
                    Text(note).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
        }
    }

    private enum StepState { case done, active, pending(Bool) }

    private func step(_ title: String, state: StepState, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done:   Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.statusPositiveInk)
                case .active: ProgressView().controlSize(.mini)
                case .pending: Image(systemName: "circle").foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title).font(.system(size: 13)).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            if let detail { Text(detail).font(.system(size: 12).monospacedDigit()).foregroundStyle(StrandPalette.textSecondary) }
        }
    }

    // WHOOP 5.0 needs different guidance: it only bonds in pairing mode and its sensor data isn't fully decoded.
    private func explanation(_ phase: LivePhase) -> String? {
        let is5 = live.family == "whoop5"
        switch phase {
        case .disconnected:
            return "Keep your strap close and press Connect. If it won't connect, close the WHOOP app on your phone."
        case .pairing:
            return is5 ? "A WHOOP 5.0 only bonds in pairing mode: take it off your wrist and tap the top until the lights flash blue, then connect."
                       : "Finishing the secure pairing with your strap."
        case .waiting:
            return is5 ? "Your WHOOP 5.0 is connected. Waiting for heart-rate readings — the strap only reports them while it's snug against your skin, so make sure you're wearing it."
                       : "Waiting for the strap to start sending data."
        case .strapDataNoHR:
            return is5 ? "The strap is talking to the app, but WHOOP 5.0 sensor data can't be decoded yet, so heart rate only appears if the strap shares it through the standard heart-rate service. It hasn't so far. Heart rate only streams while the strap is worn."
                       : "Strap data is arriving. Heart rate should appear shortly."
        case .stalled:
            return "Nothing received for a few seconds. The app will reconnect automatically."
        case .live:
            return nil
        }
    }
}

/// WHOOP 5.0 stored-data pull (safe mode). Reads what the strap holds without clearing anything.
// WHOOP 5.0 only. 'Safe mode' reads stored records without telling the strap to delete them.
struct StrapHistoryCard: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    var body: some View {
        if live.family == "whoop5" {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.timemachine").foregroundStyle(StrandPalette.lavenderInk)
                    Text("Stored data on your strap").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if live.historyBusy { ProgressView().controlSize(.small) }
                }
                if let range = live.historyRange {
                    row("Strap holds data", range)
                }
                row("Frames captured", "\(live.historyFrames)")
                if let file = live.historyCaptureFile { row("Saved to", file) }
                if let sum = live.historySummary { row("Decoded", sum) }
                                Text(live.historyStatus).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button { model.ble.queryWhoop5DataRange() } label: { Label("Check what's stored", systemImage: "magnifyingglass") }
                        .disabled(!live.bonded || live.historyBusy)
                    if live.historyBusy {
                        Button(role: .cancel) { model.ble.cancelWhoop5History() } label: { Label("Stop", systemImage: "stop.fill") }
                    } else {
                        Button { model.ble.pullWhoop5History() } label: { Label("Pull stored data (safe mode)", systemImage: "arrow.down.circle") }
                            .buttonStyle(.strandPrimary)
                            .disabled(!live.bonded)
                    }
                    Spacer()
                }
                .controlSize(.regular)

                Text("Safe mode only reads. It never tells the strap to clear anything, so your data stays on the strap. Raw frames are saved on this Mac so the 5.0 record format can be decoded.")
                    .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
