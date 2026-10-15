import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case live = "Live"
    case sleep = "Sleep"
    case workouts = "Workouts"
    case health = "Vitals"
    case trends = "Trends"
    case explore = "Data Explorer"
    case dataSources = "Import & Export"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: return "square.grid.2x2.fill"
        case .live: return "waveform.path.ecg"
        case .sleep: return "bed.double.fill"
        case .workouts: return "figure.run"
        case .health: return "heart.text.square.fill"
        case .trends: return "chart.xyaxis.line"
        case .explore: return "tablecells"
        case .dataSources: return "externaldrive.fill"
        case .settings: return "gearshape.fill"
        }
    }

    // Sidebar organisation: what the strap records, then the stored data itself, then settings.
    static let collected: [NavItem] = [.today, .live, .sleep, .workouts, .health, .trends]
    static let data: [NavItem] = [.explore, .dataSources]
    static let footer: [NavItem] = [.settings]
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

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Collected") { ForEach(NavItem.collected) { row($0) } }
                    Section("Your data") { ForEach(NavItem.data) { row($0) } }
                    Section { ForEach(NavItem.footer) { row($0) } }
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

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: TodayView()
        case .live: LiveView()
        case .sleep: SleepView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .trends: TrendsView()
        case .explore: MetricExplorerView()
        case .dataSources: DataSourcesView()
        case .settings: SettingsView()
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
