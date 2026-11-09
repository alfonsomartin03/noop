import SwiftUI
import AppKit
import StrandDesign

/// The five primary destinations (Cmd-1…5 in this order). Everything else is reached from a card (detail view / sheet) or a segment.
enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case trends = "Trends"
    case health = "Health"
    case alarms = "Alarms"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .trends: return "chart.xyaxis.line"
        case .health: return "heart.text.square.fill"
        case .alarms: return "alarm.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Where a card can send the user: a primary tab, or the live-strap sheet (a contextual detail, not a destination).
enum NavTarget { case overview, trends, health, alarms, settings, live }

private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (NavTarget) -> Void = { _ in }
}
extension EnvironmentValues {
    var navigate: (NavTarget) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

// Shell: one persistent content area with a floating pill. It observes no model object, so neither ~1 Hz strap updates
// nor repository refreshes redraw the whole window; each screen and the battery badge subscribe to what they show.
// AppModel loads the repository at launch.
struct RootView: View {
    @State private var selection: NavItem = LaunchMode.fixtureTab.flatMap { NavItem(rawValue: $0.capitalized) } ?? .overview
    @State private var showLive = LaunchMode.fixtureLiveSheet

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
            case .health: selection = .health
            case .alarms: selection = .alarms
            case .settings: selection = .settings
            case .live: showLive = true
            }
        }
        .sheet(isPresented: $showLive) { LiveSheet { showLive = false } }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .overview: TodayView()
        case .trends: TrendsHub()
        case .health: HealthPageView()
        case .alarms: AlarmsView()
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

/// Compact floating pill: five icons, the active one expands to show its name.
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

/// Strap charge at the top of every screen: a battery glyph tinted by level, plus the %. Thresholds, staleness and
/// charging come from `BatteryPresentation`, the same rules as Settings and the menu bar: a stale reading is dimmed and
/// says when it was taken, and the bolt appears only when a verified source reports charging. Its own view so battery
/// updates only re-render this badge.
private struct BatteryBadge: View {
    @EnvironmentObject var live: LiveState
    let open: () -> Void

    var body: some View {
        // Re-evaluated each minute so the badge dims when a reading ages out, not only on the next packet.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let b = BatteryPresentation(live: live, now: context.date)
            Button(action: open) { chip(b) }
                .buttonStyle(.plain)
                .help(b.percent.map { "WHOOP strap battery: \($0)% · \(b.statusText)" } ?? b.statusText)
                .accessibilityLabel(b.accessibilityLabel)
                .accessibilityHint("Opens Settings")
        }
    }

    private func chip(_ b: BatteryPresentation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: b.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(b.tint)
            Text(b.valueText).font(StrandFont.number(13, weight: .bold))
                .foregroundStyle(b.percent == nil || b.stale ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            if b.needsCharge {
                Text("Charge")
                    .font(StrandFont.number(10, weight: .bold))
                    .foregroundStyle(StrandPalette.statusCriticalInk)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(StrandPalette.statusCritical.opacity(0.14), in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(StrandPalette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(b.isCharging ? StrandPalette.statusPositive.opacity(0.6) : StrandPalette.hairline,
                                        lineWidth: b.isCharging ? 1 : 0.5))
        .animation(StrandMotion.respecting(StrandMotion.gentle), value: b.charge)
        .animation(StrandMotion.respecting(StrandMotion.gentle), value: b.needsCharge)
    }
}
