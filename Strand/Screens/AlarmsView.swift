import SwiftUI
import StrandAnalytics
import StrandDesign

/// The Alarms tab: the next wake-up, how it will reach you, and every alarm with its switch. Only verified
/// capabilities are offered — there is no vibration-pattern picker because no pattern is verified on WHOOP 5.0.
struct AlarmsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { AlarmsContent(alarms: model.alarms) }
}

private struct AlarmsContent: View {
    @EnvironmentObject var live: LiveState
    @ObservedObject var alarms: AlarmController
    @State private var editing: AlarmSpec?

    var body: some View {
        ScreenScaffold(title: "Alarms", subtitle: "Wake up on your strap, ideally at a lighter moment.") {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                nextCard
                ForEach(alarms.warnings(battery: live.battery?.percent, connected: live.connected), id: \.self) { w in
                    StrandNotice(symbol: "exclamationmark.triangle.fill", title: "Before you sleep", message: w, tint: StrandPalette.statusWarning)
                }
                HStack {
                    Text("Your alarms").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button { editing = Self.newAlarm } label: { Label("Add alarm", systemImage: "plus") }
                        .buttonStyle(.strandPrimary)
                }
                .padding(.top, 8)
                if alarms.alarms.isEmpty {
                    emptyCard
                } else {
                    ForEach(alarms.alarms) { a in row(a) }
                }
                AlarmHistorySection(alarms: alarms)
                howItRings
            }
        }
        .sheet(item: $editing) { a in AlarmEditor(alarm: a, isNew: !alarms.alarms.contains { $0.id == a.id }) { alarms.save($0) } }
    }

    private static var newAlarm: AlarmSpec {
        AlarmSpec(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], mode: .smart(windowMin: AlarmSpec.defaultWindowMin))
    }

    // MARK: Next alarm

    private var nextCard: some View {
        NoopCard {
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: alarms.next == nil ? "alarm" : "alarm.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(StrandPalette.ink(StrandPalette.lavender))
                    .frame(width: 60, height: 60)
                    .background(StrandPalette.lavender.opacity(0.16), in: Circle())
                if let n = alarms.next {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next alarm").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(n.deadline.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(StrandPalette.textPrimary)
                            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                                Text("\(n.deadline.formatted(.dateTime.weekday(.wide))) · in \(Self.countdown(to: n.deadline, from: ctx.date))")
                                    .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        if n.windowStart < n.deadline {
                            Text("May ring from \(n.windowStart.formatted(date: .omitted, time: .shortened)) if you look lightly asleep")
                                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                        }
                        delivery(n).padding(.top, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No alarm on").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                        Text(alarms.alarms.isEmpty ? "Add one below to wake up on your strap." : "Switch an alarm on below.")
                            .font(.system(size: 13, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let s = alarms.status {
                Text(s).font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                    .padding(.top, 10)
            }
            if alarms.followUpPending {
                HStack(spacing: 10) {
                    Text("Your alarm rang and hasn't been dismissed. NOOP will buzz again in a few minutes unless you dismiss it on the strap or here.")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("I'm awake") { alarms.dismissPendingFallback() }.buttonStyle(.strandPrimary)
                }
                .padding(.top, 8)
            } else if alarms.fallbackPending, let n = alarms.next {
                HStack(spacing: 10) {
                    Text("Woke early. The latest-time alarm (\(n.deadline.formatted(date: .omitted, time: .shortened))) stays set until you dismiss it.")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("I'm awake") { alarms.dismissPendingFallback() }.buttonStyle(.strandPrimary)
                }
                .padding(.top, 8)
            } else if let n = alarms.next {
                // Already up before the alarm: skip just this occurrence; the schedule stays as it is.
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if alarms.canSkipNext(at: ctx.date) {
                        HStack(spacing: 10) {
                            Text("Already up? Skip the \(n.deadline.formatted(date: .omitted, time: .shortened)) alarm. "
                                 + "Your next alarms stay on.")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Button("I'm awake — skip") { alarms.skipNextAsAwake() }
                                .buttonStyle(.strandSecondary)
                                .accessibilityHint("Skips only this occurrence; the alarm stays scheduled for its next day")
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    /// Where the next ring will come from, as far as NOOP has verified.
    private func delivery(_ n: AlarmOccurrence) -> some View {
        let (symbol, text, tint): (String, String, Color) = {
            switch alarms.states[n.alarmId] {
            case .confirmedOnDevice: return ("checkmark.circle.fill", "Stored on your strap — it rings by itself, plus a Mac notification", StrandPalette.statusPositive)
            case .pendingSync: return ("arrow.triangle.2.circlepath", "Sending to your strap…", StrandPalette.accent)
            case .failed: return ("exclamationmark.circle.fill", "The strap didn't take it — rings on this Mac", StrandPalette.statusWarning)
            default:
                return alarms.capabilities.immediateVibration == .confirmed
                    ? ("applewatch.radiowaves.left.and.right", "Rings on this Mac and buzzes the strap while connected", StrandPalette.accent)
                    : ("desktopcomputer", "Rings on this Mac", StrandPalette.textSecondary)
            }
        }()
        return Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(StrandPalette.ink(tint))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private static func countdown(to date: Date, from now: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        let h = mins / 60, m = mins % 60
        if h >= 24 { return "\(h / 24) d \(h % 24) h" }
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    // MARK: Rows

    private func row(_ a: AlarmSpec) -> some View {
        let isNext = alarms.next?.alarmId == a.id
        return Button { editing = a } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "%02d:%02d", a.hour, a.minute))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(a.enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    Text("\(Self.daysText(a.weekdays)) · \(Self.modeText(a.mode))")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                }
                if isNext {
                    Text("Next").font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(StrandPalette.ink(StrandPalette.lavender))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(StrandPalette.lavender.opacity(0.16), in: Capsule())
                }
                Spacer()
                Toggle("", isOn: Binding(get: { a.enabled }, set: { on in var b = a; b.enabled = on; alarms.save(b) }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Alarm \(String(format: "%02d:%02d", a.hour, a.minute)) on")
                Menu {
                    Button("Edit…") { editing = a }
                    Button("Delete", role: .destructive) { alarms.delete(a.id) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, NoopMetrics.cardPadding).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .strandSurface()
        }
        .buttonStyle(.plain)
        .help("Edit alarm")
    }

    private var emptyCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("No alarms yet").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                Text("Pick a latest wake time and days. Smart wake can ring up to an hour earlier when your heart rate stays above its sleeping level (an estimate, not a measured sleep stage).")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var howItRings: some View {
        let strap = alarms.capabilities.onDeviceAlarm == .confirmed
        return VStack(alignment: .leading, spacing: 6) {
            Text("How alarms reach you").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
            Text((strap
                  ? "Your strap's firmware can store the next alarm and ring by itself, even with this Mac asleep. "
                  : "This strap's firmware isn't verified to ring by itself, so alarms rely on this Mac being awake with NOOP open. ")
                 + "Smart wake and sleep-goal alarms need NOOP running and the strap connected to ring early; otherwise they ring at the latest time. "
                 + "During the wake window NOOP keeps the Mac from idle-sleeping, streams live heart rate and pauses background syncs, but closing the lid still puts it to sleep. "
                 + "If the alarm isn't dismissed, NOOP buzzes again a few times over the next 20 minutes while it can reach the strap. A Mac notification always sounds too.")
                .font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    static func modeText(_ m: AlarmSpec.Mode) -> String { AlarmsTextFormat.mode(m) }
    static func daysText(_ d: Set<Int>) -> String {
        if d.isEmpty { return "Once" }
        if d == [2, 3, 4, 5, 6] { return "Weekdays" }
        if d == [1, 7] { return "Weekends" }
        if d.count == 7 { return "Every day" }
        let names = Calendar.current.shortWeekdaySymbols
        return d.sorted().map { names[$0 - 1] }.joined(separator: " ")
    }
}

/// A one-line pointer to the Alarms tab: the next alarm, or a prompt to set one. For Overview and the Sleep screen.
struct NextAlarmLink: View {
    @EnvironmentObject var model: AppModel
    var body: some View { NextAlarmLinkContent(alarms: model.alarms) }
}

private struct NextAlarmLinkContent: View {
    @ObservedObject var alarms: AlarmController
    @Environment(\.navigate) private var navigate

    var body: some View {
        Button { navigate(.alarms) } label: {
            HStack(spacing: 10) {
                Image(systemName: alarms.next == nil ? "alarm" : "alarm.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.ink(StrandPalette.lavender))
                    .frame(width: 28, height: 28)
                    .background(StrandPalette.lavender.opacity(0.16), in: Circle())
                if let n = alarms.next {
                    Text("Alarm \(n.deadline.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                } else {
                    Text("No alarm set").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Text(alarms.next == nil ? "Set an alarm" : "Manage")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.accentInk)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
            .strandSurface(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Alarms")
    }
}

struct AlarmEditor: View {
    @State var alarm: AlarmSpec
    var isNew = false
    let save: (AlarmSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var kind = 1
    @State private var window = AlarmSpec.defaultWindowMin
    @State private var goal = 85

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New alarm" : "Edit alarm").font(.system(size: 17, weight: .semibold, design: .rounded))
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
            Text(alarm.weekdays.isEmpty ? "No days picked: rings once, then switches itself off." : "Repeats on the days picked.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
            Text(kind == 0 ? "Rings at the time you set."
                 : "Rings earlier inside the window only after your heart rate has stayed above your sleeping level for about a minute; otherwise at the latest time. A heart-rate rise is not a measured sleep stage. After an early wake the latest-time alarm stays set until you dismiss it.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    alarm.hour = c.hour ?? 7; alarm.minute = c.minute ?? 0
                    alarm.mode = kind == 0 ? .exact : kind == 1 ? .smart(windowMin: window) : .sleepGoal(goalPercent: goal, windowMin: window)
                    save(alarm); dismiss()
                }
                .buttonStyle(.strandPrimary).keyboardShortcut(.defaultAction)
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
