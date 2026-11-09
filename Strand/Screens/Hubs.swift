import SwiftUI
import StrandDesign

/// A titled page with a segmented switcher; each segment is an existing screen shown without its own heading.
private struct SegmentedHub<Seg: Hashable & CaseIterable & RawRepresentable, Body: View>: View where Seg.RawValue == String, Seg.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: Seg
    /// Trends uses the app's section tabs (icon + name, one level above its sub-view and range pills); Settings keeps the
    /// system segmented picker.
    var symbol: ((Seg) -> String)? = nil
    @ViewBuilder var content: (Seg) -> Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.4).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.top, 20)
            Group {
                if let symbol {
                    SectionTabBar(Array(Seg.allCases), selection: $selection, title: "\(title) sections", symbol: symbol) { $0.rawValue }
                } else {
                    Picker(title, selection: $selection) {
                        ForEach(Seg.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.top, 12).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            content(selection)
                .environment(\.screenEmbedded, true)
        }
    }
}

/// Trends: all history in one place. Scores, then Sleep, Vitals and Activity, each with its trends and its detail screen.
struct TrendsHub: View {
    enum Seg: String, CaseIterable {
        case scores = "Scores", sleep = "Sleep", vitals = "Vitals", activity = "Activity", highlights = "Highlights"
        var symbol: String {
            switch self {
            case .scores: return "circle.hexagongrid.fill"
            case .sleep: return "moon.zzz.fill"
            case .vitals: return "waveform.path.ecg"
            case .activity: return "flame.fill"
            case .highlights: return "trophy.fill"
            }
        }
    }
    @AppStorage("noop.trends.segment") private var raw = Seg.scores.rawValue
    private var sel: Binding<Seg> { Binding(get: { Seg(rawValue: raw) ?? .scores }, set: { raw = $0.rawValue }) }

    var body: some View {
        SegmentedHub(title: "Trends", selection: sel, symbol: { $0.symbol }) { seg in
            switch seg {
            case .scores: TrendsView()
            case .sleep:
                TrendTabSwitcher(storageKey: "noop.trends.sleep.detail", detailTitle: "Last night") {
                    SleepTrendsView()
                } detail: { SleepView() }
            case .vitals:
                TrendTabSwitcher(storageKey: "noop.trends.vitals.detail", detailTitle: "Live") {
                    VitalsTrendsView()
                } detail: { HealthView() }
            case .activity:
                TrendTabSwitcher(storageKey: "noop.trends.activity.detail", detailTitle: "Sessions") {
                    ActivityTrendsView()
                } detail: { WorkoutsView() }
            case .highlights: HighlightsView()
            }
        }
    }
}

/// Settings: device & profile first; data tools and diagnostics behind their own segments (progressive disclosure).
struct SettingsHub: View {
    enum Seg: String, CaseIterable { case general = "General", data = "Data", advanced = "Advanced" }
    @AppStorage("noop.settings.segment") private var raw = Seg.general.rawValue
    private var sel: Binding<Seg> { Binding(get: { Seg(rawValue: raw) ?? .general }, set: { raw = $0.rawValue }) }
    @Environment(\.navigate) private var navigate

    var body: some View {
        SegmentedHub(title: "Settings", selection: sel) { seg in
            switch seg {
            case .general: SettingsView()
            case .data: DataSourcesView()
            case .advanced: AdvancedSettings()
            }
        }
    }
}

/// Advanced: diagnostics and raw-data tools, one switch away from the everyday settings.
private struct AdvancedSettings: View {
    enum Tool: String, CaseIterable { case recovery = "Recovery diagnostics", explorer = "Data explorer" }
    @State private var tool = Tool.recovery
    @Environment(\.navigate) private var navigate

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Tool", selection: $tool) { ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).fixedSize().labelsHidden()
                Button { navigate(.live) } label: { Label("Live strap", systemImage: "waveform.path.ecg") }
                    .buttonStyle(.strandSecondary)
                Spacer()
            }
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.bottom, 6)
            switch tool {
            case .recovery: RecoveryDiagnosticsView()
            case .explorer: MetricExplorerView()
            }
        }
    }
}
