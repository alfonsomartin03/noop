import SwiftUI
import StrandDesign

/// Shown when macOS holds a pairing the strap has forgotten. macOS offers no API to unpair a device,
/// and the stale LE bond isn't listed in System Settings either, so this walks the user through the
/// workarounds (toggle Bluetooth / restart bluetoothd), then restarts pairing.
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
                Text("Your strap no longer recognises this Mac. macOS keeps this pairing out of sight — it won't appear in the Bluetooth list — so it can't be forgotten there. To clear it: (1) turn the WHOOP phone app's Bluetooth off so the strap is free, (2) switch Bluetooth off and on again on this Mac, (3) if it still fails, run  sudo pkill bluetoothd  in Terminal (or restart the Mac), then start pairing again.")
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
