import SwiftUI
import StrandDesign

// Every sidebar destination; icon and grouping live here so adding a screen is one case.
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
// Environment hook so any screen can switch tabs (e.g. a widget opening its detail view).
private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (NavItem) -> Void = { _ in }
}
extension EnvironmentValues {
    var navigate: (NavItem) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}

// Sidebar + detail shell. Observes only Repository so ~1 Hz heart-rate updates don't re-render the whole window.
struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream). The live
    // status row is isolated into SidebarStatus so HR/frame ticks don't re-render the whole shell.
    @EnvironmentObject var repo: Repository
    @State private var selection: NavItem? = .today

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("Collected")
                        ForEach(NavItem.collected) { SidebarRow(item: $0, selection: $selection) }
                        sectionLabel("Your data").padding(.top, 14)
                        ForEach(NavItem.data) { SidebarRow(item: $0, selection: $selection) }
                        sectionLabel("App").padding(.top, 14)
                        ForEach(NavItem.footer) { SidebarRow(item: $0, selection: $selection) }
                    }
                    .padding(.horizontal, 10).padding(.top, 14)
                }

                SidebarStatus { selection = .settings }.padding(.horizontal, 12).padding(.vertical, 12)
            }
            .background(StrandPalette.surfaceInset.opacity(0.6))
            .navigationSplitViewColumnWidth(min: 200, ideal: 222, max: 260)
        } detail: {
            detail
                .id(selection)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .animation(StrandMotion.respecting(.easeOut(duration: 0.2)), value: selection)
        }
        .tint(StrandPalette.accentInk)
        .environment(\.navigate) { selection = $0 }
        .task { await repo.refresh() }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, 10).padding(.bottom, 2)
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

/// One sidebar destination: icon + label, pastel capsule when selected, soft hover.
private struct SidebarRow: View {
    let item: NavItem
    @Binding var selection: NavItem?
    @State private var hovering = false
    private var selected: Bool { (selection ?? .today) == item }

    var body: some View {
        Button { selection = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? StrandPalette.accentInk : StrandPalette.textSecondary)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? StrandPalette.accentMuted : (hovering ? StrandPalette.hairline : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(StrandMotion.respecting(.easeOut(duration: 0.15)), value: selected)
        .animation(StrandMotion.respecting(.easeOut(duration: 0.15)), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Isolated live-status row — owns the LiveState observation so the rest of RootView does not
/// re-render on the ~1 Hz HR / frame stream.
// Isolated view: owns the LiveState subscription so only this small row updates on live ticks.
private struct SidebarStatus: View {
    @EnvironmentObject var live: LiveState
    let open: () -> Void
    var body: some View {
        Button(action: open) { content }
            .buttonStyle(.plain)
            .help("Open strap connection settings")
            .accessibilityLabel("WHOOP strap, \(subtitle). Open connection settings")
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.side.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StrandPalette.ink(statusColor))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("WHOOP").font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Circle().fill(statusColor).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
