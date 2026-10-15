import SwiftUI
import StrandDesign

/// Standard scrollable screen container: large title + quiet subtitle + a centered, width-limited
/// content column on the grouped background.
struct ScreenScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
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
                content()
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.top, 20)
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

/// A reusable "what shows now vs what needs an import" note for empty / pending data states.
struct DataPendingNote: View {
    let title: String
    let message: String
    var symbol: String = "sparkles"

    var body: some View {
        StrandNotice(symbol: symbol, title: title, message: message)
    }
}
