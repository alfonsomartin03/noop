import SwiftUI
import StrandDesign

/// A titled page with a segmented switcher; each segment is an existing screen shown without its own heading.
private struct SegmentedHub<Seg: Hashable & CaseIterable & RawRepresentable, Body: View>: View where Seg.RawValue == String, Seg.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: Seg
    @ViewBuilder var content: (Seg) -> Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.4).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.top, 20)
            Picker(title, selection: $selection) {
                ForEach(Seg.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.top, 12).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            content(selection)
                .environment(\.screenEmbedded, true)
        }
    }
}

/// Trends: all history in one place. Scores (recovery / strain / sleep trends), Sleep nights, Vitals, Activity.
struct TrendsHub: View {
    enum Seg: String, CaseIterable { case scores = "Scores", sleep = "Sleep", vitals = "Vitals", activity = "Activity" }
    @AppStorage("noop.trends.segment") private var raw = Seg.scores.rawValue
    private var sel: Binding<Seg> { Binding(get: { Seg(rawValue: raw) ?? .scores }, set: { raw = $0.rawValue }) }

    var body: some View {
        SegmentedHub(title: "Trends", selection: sel) { seg in
            switch seg {
            case .scores: TrendsView()
            case .sleep: SleepView()
            case .vitals: HealthView()
            case .activity: WorkoutsView()
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
