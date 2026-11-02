import SwiftUI
import StrandAnalytics
import StrandDesign

/// Wake alarm on the Sleep screen: time, days, mode, window, next ring and honest status. Only verified capabilities
/// are offered — there is no vibration-pattern picker because no pattern is verified on WHOOP 5.0.
struct AlarmCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @ObservedObject var alarms: AlarmController
    @State private var editing: AlarmSpec?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Wake alarm", overline: "Sleep", trailing: nil)
            VStack(alignment: .leading, spacing: 10) {
                if alarms.alarms.isEmpty {
                    Text("No alarm set.").font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(alarms.alarms) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%02d:%02d", a.hour, a.minute))
                                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                                .foregroundStyle(a.enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            Text("\(modeText(a.mode)) · \(daysText(a.weekdays))")
                                .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { a.enabled }, set: { on in var b = a; b.enabled = on; alarms.save(b) }))
                            .toggleStyle(.switch).labelsHidden()
                        Menu {
                            Button("Edit…") { editing = a }
                            Button("Delete", role: .destructive) { alarms.delete(a.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                if let n = alarms.next {
                    Text("Next: \(n.deadline.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                         + (n.windowStart < n.deadline ? " (window from \(n.windowStart.formatted(date: .omitted, time: .shortened)))" : ""))
                        .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                }
                if let s = alarms.status {
                    Text(s).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(alarms.warnings(battery: live.battery?.percent, connected: live.connected), id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { editing = AlarmSpec(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], mode: .smart(windowMin: AlarmSpec.defaultWindowMin)) } label: {
                    Label("Add alarm", systemImage: "plus")
                }
                .buttonStyle(.strandSecondary)
            }
            .padding(NoopMetrics.cardPadding)
            .strandSurface()
        }
        .sheet(item: $editing) { a in AlarmEditor(alarm: a) { alarms.save($0) } }
    }

    private func modeText(_ m: AlarmSpec.Mode) -> String {
        switch m {
        case .exact: return "Exact time"
        case .smart(let w): return "Smart wake, \(w)-min window"
        case .sleepGoal(let p, let w): return "Sleep goal \(p)%, \(w)-min window"
        }
    }
    private func daysText(_ d: Set<Int>) -> String {
        if d.isEmpty { return "Once" }
        if d == [2, 3, 4, 5, 6] { return "Weekdays" }
        if d.count == 7 { return "Every day" }
        let names = Calendar.current.shortWeekdaySymbols
        return d.sorted().map { names[$0 - 1] }.joined(separator: " ")
    }
}

private struct AlarmEditor: View {
    @State var alarm: AlarmSpec
    let save: (AlarmSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var kind = 1
    @State private var window = AlarmSpec.defaultWindowMin
    @State private var goal = 85

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wake alarm").font(.system(size: 15, weight: .semibold))
            DatePicker("Latest wake time", selection: $time, displayedComponents: .hourAndMinute)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { d in
                    let on = alarm.weekdays.contains(d)
                    Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                        if on { alarm.weekdays.remove(d) } else { alarm.weekdays.insert(d) }
                    }
                    .buttonStyle(.plain).frame(width: 28, height: 28)
                    .background(on ? StrandPalette.lavenderInk.opacity(0.2) : Color.clear, in: Circle())
                }
            }
            Picker("Mode", selection: $kind) {
                Text("Exact").tag(0); Text("Smart wake").tag(1); Text("Sleep goal").tag(2)
            }
            .pickerStyle(.segmented)
            if kind > 0 {
                Stepper("Window: \(window) min", value: $window, in: AlarmSpec.windowRange, step: 5)
            }
            if kind == 2 {
                Picker("Goal", selection: $goal) { Text("70%").tag(70); Text("85%").tag(85); Text("100%").tag(100) }
                    .pickerStyle(.segmented)
                Text("A product option, not a recovery guarantee. The alarm still rings at the latest time.")
                    .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
            }
            Text(kind == 0 ? "Rings at the time you set."
                 : "Rings earlier inside the window only after several minutes in a row look awake or lightly asleep (from your heart rate); otherwise at the latest time. This estimate is not a measured sleep stage.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    alarm.hour = c.hour ?? 7; alarm.minute = c.minute ?? 0
                    alarm.mode = kind == 0 ? .exact : kind == 1 ? .smart(windowMin: window) : .sleepGoal(goalPercent: goal, windowMin: window)
                    save(alarm); dismiss()
                }
                .buttonStyle(.strandPrimary)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear {
            time = Calendar.current.date(from: DateComponents(hour: alarm.hour, minute: alarm.minute)) ?? Date()
            switch alarm.mode {
            case .exact: kind = 0
            case .smart(let w): kind = 1; window = w
            case .sleepGoal(let g, let w): kind = 2; window = w; goal = g
            }
        }
    }
}

/// Reads the alarm controller from the app model so screens can drop the card in without plumbing.
struct AlarmSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View { AlarmCard(alarms: model.alarms) }
}
