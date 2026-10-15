import SwiftUI
import StrandDesign

/// Shown when macOS holds a pairing the strap has forgotten. macOS offers no API to unpair a device,
/// so this walks the user through forgetting it in System Settings, then restarts pairing.
struct PairingResetNotice: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    var body: some View {
        if live.pairingStale {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text("Pairing needs a reset")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Your strap no longer recognises this Mac. Forget WHOOP in System Settings ▸ Bluetooth (the ⓘ next to it ▸ Forget This Device), make sure the WHOOP phone app isn't holding the strap, then start pairing again.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { model.openBluetoothSettings() } label: {
                        Label("Open Bluetooth Settings", systemImage: "gearshape").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                    Button { model.restartPairing() } label: {
                        Label("Start pairing again", systemImage: "arrow.clockwise").padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
        }
    }
}
