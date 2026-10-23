import SwiftUI
import AppKit
import StrandDesign

/// The three primary destinations. Everything else is reached from a card (detail view / sheet) or a segment.
enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case trends = "Trends"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .trends: return "chart.xyaxis.line"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Where a card can send the user: a primary tab, or the live-strap sheet (a contextual detail, not a destination).
enum NavTarget { case overview, trends, settings, live }

private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (NavTarget) -> Void = { _ in }
}
extension EnvironmentValues {
    var navigate: (NavTarget) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

// Shell: one persistent content area with a floating pill. Observes only Repository so ~1 Hz heart-rate updates
// don't re-render the whole window (the battery badge owns its own LiveState subscription).
struct RootView: View {
    @EnvironmentObject var repo: Repository
    @State private var selection: NavItem = .overview
    @State private var showLive = false

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .id(selection)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                // Reserve room under scrolling content so the pill never covers the last card.
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 84) }
                .overlay(alignment: .topTrailing) {
                    BatteryBadge { selection = .settings }.padding(.top, 14).padding(.trailing, 20)
                }
            FloatingNav(selection: $selection)
                .padding(.bottom, 18)
        }
        .animation(StrandMotion.respecting(.easeOut(duration: 0.2)), value: selection)
        .tint(StrandPalette.accentInk)
        .environment(\.navigate) { target in
            switch target {
            case .overview: selection = .overview
            case .trends: selection = .trends
            case .settings: selection = .settings
            case .live: showLive = true
            }
        }
        .sheet(isPresented: $showLive) { LiveSheet { showLive = false } }
        .task { await repo.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .overview: TodayView()
        case .trends: TrendsHub()
        case .settings: SettingsHub()
        }
    }
}

/// The live strap view as a contextual sheet with a single, obvious way back.
private struct LiveSheet: View {
    let close: () -> Void
    var body: some View {
        LiveView()
            .frame(minWidth: 760, minHeight: 640)
            .overlay(alignment: .topTrailing) {
                Button("Done", action: close).buttonStyle(.strandSecondary).keyboardShortcut(.cancelAction).padding(16)
            }
    }
}

/// Compact floating pill: three icons, the active one expands to show its name.
private struct FloatingNav: View {
    @Binding var selection: NavItem
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NavItem.allCases) { item in
                let on = item == selection
                Button { select(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.system(size: 15, weight: .semibold))
                        if on { Text(item.rawValue).font(.system(size: 13, weight: .semibold)).transition(.opacity) }
                    }
                    .foregroundStyle(on ? StrandPalette.accentInk : StrandPalette.textSecondary)
                    .padding(.horizontal, on ? 16 : 14).frame(height: 40)
                    .background {
                        if on { Capsule().fill(StrandPalette.accentMuted).matchedGeometryEffect(id: "active", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(NavItem.allCases.firstIndex(of: item)! + 1))), modifiers: .command)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(item.rawValue)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .animation(StrandMotion.respecting(.spring(response: 0.3, dampingFraction: 0.85)), value: selection)
    }

    private func select(_ item: NavItem) {
        guard item != selection else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        selection = item
    }
}

/// Strap charge at the top of every screen: a battery glyph that fills and changes colour with the level, plus the %.
/// Its own view so the strap's frequent updates only re-render this badge, never the whole window.
private struct BatteryBadge: View {
    @EnvironmentObject var live: LiveState
    let open: () -> Void

    private var pct: Int? { live.connected ? live.batteryPct.map { Int($0.rounded()) } : nil }
    private var tint: Color {
        guard let p = pct else { return StrandPalette.textTertiary }
        return p < 20 ? StrandPalette.statusCritical : p < 50 ? StrandPalette.statusWarning : StrandPalette.statusPositive
    }
    private var symbol: String {
        guard let p = pct else { return "battery.0percent" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    var body: some View {
        Button(action: open) { chip }.buttonStyle(.plain)
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                            Text(pct.map { "\($0)%" } ?? "—").font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(pct == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(StrandPalette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        .help(pct.map { "WHOOP strap battery: \($0)%" } ?? (live.connected ? "Reading strap battery…" : "Strap not connected"))
        .accessibilityLabel(pct.map { "Strap battery \($0) percent" } ?? "Strap battery unknown")
    }
}

