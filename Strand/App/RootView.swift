import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case intelligence = "Intelligence"
    case coach = "Coach"
    case live = "Live"
    case breathe = "Breathe"
    case intervals = "Intervals"
    case explore = "Explore"
    case compare = "Compare"
    case insights = "Insights"
    case sleep = "Sleep"
    case trends = "Trends"
    case workouts = "Workouts"
    case health = "Health"
    case stress = "Stress"
    case appleHealth = "Apple Health"
    case dataSources = "Data Sources"
    case notifications = "Notifications"
    case automation = "Automations"
    case settings = "Settings"
    case support = "Support"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "square.grid.2x2.fill"
        case .intelligence: return "brain.head.profile"
        case .coach: return "sparkles"
        case .live: return "waveform.path.ecg"
        case .breathe: return "lungs.fill"
        case .intervals: return "timer"
        case .explore: return "magnifyingglass"
        case .compare: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.fill"
        case .sleep: return "bed.double.fill"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .health: return "heart.text.square.fill"
        case .stress: return "gauge.with.dots.needle.50percent"
        case .appleHealth: return "heart.fill"
        case .dataSources: return "square.and.arrow.down.fill"
        case .notifications: return "bell.badge.fill"
        case .automation: return "wand.and.stars"
        case .settings: return "gearshape.fill"
        case .support: return "lifepreserver.fill"
        }
    }

    // Sidebar organisation: a short primary list, then collapsible groups for everything else.
    static let primary: [NavItem] = [.today, .sleep, .workouts, .trends, .health, .live]
    static let insightsGroup: [NavItem] = [.intelligence, .insights, .stress, .compare, .explore, .coach]
    static let toolsGroup: [NavItem] = [.breathe, .intervals, .automation]
    static let dataGroup: [NavItem] = [.appleHealth, .dataSources, .notifications]
    static let footer: [NavItem] = [.settings, .support]
}

/// Lets any screen jump to another destination (e.g. a widget opening its detail view).
private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (NavItem) -> Void = { _ in }
}
extension EnvironmentValues {
    var navigate: (NavItem) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream). The live
    // status row is isolated into SidebarStatus so HR/frame ticks don't re-render the whole shell.
    @EnvironmentObject var repo: Repository
    @State private var selection: NavItem? = .today
    @State private var insightsOpen = false
    @State private var toolsOpen = false
    @State private var dataOpen = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(NavItem.primary) { row($0) }

                    DisclosureGroup(isExpanded: expansion($insightsOpen, NavItem.insightsGroup)) {
                        ForEach(NavItem.insightsGroup) { row($0) }
                    } label: { groupLabel("Insights", "sparkle.magnifyingglass") }

                    DisclosureGroup(isExpanded: expansion($toolsOpen, NavItem.toolsGroup)) {
                        ForEach(NavItem.toolsGroup) { row($0) }
                    } label: { groupLabel("Tools", "slider.horizontal.3") }

                    DisclosureGroup(isExpanded: expansion($dataOpen, NavItem.dataGroup)) {
                        ForEach(NavItem.dataGroup) { row($0) }
                    } label: { groupLabel("Data", "externaldrive.fill") }

                    Section {
                        ForEach(NavItem.footer) { row($0) }
                    }
                }
                .listStyle(.sidebar)

                SidebarStatus().padding(.horizontal, 12).padding(.vertical, 12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 222, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .environment(\.navigate) { selection = $0 }
        .task { await repo.refresh() }
    }

    private func row(_ item: NavItem) -> some View {
        Label(item.rawValue, systemImage: item.icon)
            .font(.system(size: 13))
            .tag(item)
    }

    private func groupLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13))
            .foregroundStyle(StrandPalette.textSecondary)
    }

    /// A group is open when toggled, or whenever the current selection lives inside it.
    private func expansion(_ flag: Binding<Bool>, _ items: [NavItem]) -> Binding<Bool> {
        Binding(get: { flag.wrappedValue || (selection.map(items.contains) ?? false) },
                set: { flag.wrappedValue = $0 })
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: TodayView()
        case .intelligence: IntelligenceView()
        case .coach: CoachView()
        case .live: LiveView()
        case .breathe: BreathingView()
        case .intervals: IntervalTimerView()
        case .explore: MetricExplorerView()
        case .compare: CompareView()
        case .insights: InsightsView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .stress: StressView()
        case .appleHealth: AppleHealthView()
        case .dataSources: DataSourcesView()
        case .notifications: NotificationSettingsView()
        case .automation: AutomationsView()
        case .settings: SettingsView()
        case .support: SupportView()
        }
    }
}

/// Isolated live-status row — owns the LiveState observation so the rest of RootView does not
/// re-render on the ~1 Hz HR / frame stream.
private struct SidebarStatus: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.side.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("WHOOP").font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Circle().fill(statusColor).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
    }

    private var statusColor: Color {
        live.bonded ? StrandPalette.statusPositive
            : live.connected ? StrandPalette.statusWarning
            : StrandPalette.textTertiary
    }
    private var subtitle: String {
        let base = live.bonded ? "Connected" : live.connected ? "Connecting…" : "Not connected"
        if let pct = live.batteryPct, live.connected { return "\(base) · \(Int(pct))%" }
        return base
    }
}
