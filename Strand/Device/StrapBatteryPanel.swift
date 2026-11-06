import SwiftUI
import StrandDesign

/// Strap battery detail: the charging illustration plus the percentage and one status line, from the shared
/// `BatteryPresentation`. The illustration moves only on a verified, fresh charging reading; every other state is
/// drawn still, so a telemetry update never replays the entrance (the pack docks only when the phase changes).
struct StrapBatteryPanel: View {
    @EnvironmentObject var live: LiveState
    var compact = false

    var body: some View {
        // Re-evaluated each minute so a reading turns stale on screen without waiting for the next packet.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            StrapBatteryContent(battery: BatteryPresentation(live: live, now: context.date), compact: compact)
        }
    }
}

/// The panel's layout for a given battery state; separate so previews and snapshots can drive it with synthetic state.
struct StrapBatteryContent: View {
    let battery: BatteryPresentation
    var compact = false

    private var phase: ChargingIllustration.Phase {
        switch battery.illustration {
        case .full: return .full
        case .charging: return .charging
        case .attached: return .attached
        case .detached: return .idle
        case .unknown: return .unknown
        }
    }

    /// Where the charging claim comes from: confirmed (strap-reported, with time) vs inferred.
    private var sourceNote: String? {
        switch battery.charge {
        case .charging:
            return "Reported by the strap" + (battery.chargeReportedAt.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .likely: return "Inferred from a rising percentage — not reported by the strap"
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.gap) {
            ChargingIllustration(phase: phase, percent: battery.percent, dimmed: battery.stale || battery.percent == nil,
                                 height: compact ? 72 : 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(battery.valueText)
                    .font(StrandFont.number(compact ? 28 : 34, weight: .bold))
                    .foregroundStyle(battery.percent == nil ? StrandPalette.textTertiary : battery.ink)
                    .contentTransition(.numericText())
                Label {
                    Text(battery.statusText)
                } icon: {
                    Image(systemName: battery.symbol)
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                if !compact, let note = sourceNote {
                    Text(note).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(StrandMotion.respecting(StrandMotion.gentle), value: battery.charge)
        .animation(StrandMotion.respecting(StrandMotion.gentle), value: battery.attachment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(battery.accessibilityLabel)
    }
}

#if DEBUG
#Preview("Strap battery states") {
    let now = Date()
    return VStack(alignment: .leading, spacing: 20) {
        StrapBatteryContent(battery: .init(percent: 64, stale: false, charge: .unknown, connected: true, measuredAt: now))
        StrapBatteryContent(battery: .init(percent: 64, stale: false, charge: .notCharging, attachment: .detached, connected: true, measuredAt: now))
        StrapBatteryContent(battery: .init(percent: 64, stale: false, charge: .unknown, attachment: .attached, connected: true, measuredAt: now))
        StrapBatteryContent(battery: .init(percent: 52, stale: false, charge: .likely, connected: true, measuredAt: now))
        StrapBatteryContent(battery: .init(percent: 48, stale: false, charge: .charging, connected: true, measuredAt: now))
        StrapBatteryContent(battery: .init(percent: 100, stale: false, charge: .charging, connected: true, measuredAt: now))
        StrapBatteryContent(battery: .init(percent: 37, stale: true, charge: .charging, connected: false, measuredAt: now.addingTimeInterval(-1800)))
        StrapBatteryContent(battery: .init(percent: nil, stale: true, charge: .unknown, connected: false, measuredAt: nil))
    }
    .padding(24)
    .frame(width: 520)
    .background(StrandPalette.surfaceBase)
}
#endif
