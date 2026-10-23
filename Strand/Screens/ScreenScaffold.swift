import SwiftUI
import StrandDesign

/// Set by the Trends / Settings hubs when a screen is shown inside a segment: the hub owns the title, so the
/// embedded screen drops its own large heading instead of stacking two.
private struct ScreenEmbeddedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var screenEmbedded: Bool {
        get { self[ScreenEmbeddedKey.self] }
        set { self[ScreenEmbeddedKey.self] = newValue }
    }
}

/// Standard scrollable screen container: large title + quiet subtitle + a centered, width-limited
/// content column on the grouped background.
// Every screen uses this wrapper so titles, padding and max content width are identical.
struct ScreenScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.screenEmbedded) private var embedded

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold)).tracking(-0.4)
                .foregroundStyle(StrandPalette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !embedded { header }
                content()
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.top, embedded ? 6 : 20)
            .padding(.bottom, 44)
            .frame(maxWidth: NoopMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StrandPalette.surfaceBase)
    }
}

/// Placeholder body for screens still being built.
struct ComingSoon: View {
    let what: String
    var body: some View {
        StrandNotice(symbol: "hourglass", title: "Coming together", message: what, tint: StrandPalette.textSecondary)
    }
}
