import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// Morning / evening check-ins (issue #12): a light Overview card for today, plus a sheet for past entries, insights and
// prompt settings. Answers are stored as given (Yes / No / Not sure / skipped / unanswered) and never feed a score.

// MARK: - Overview card

struct CheckInCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var settings: CheckInSettings
    @AppStorage("checkin.inviteDismissed") private var inviteDismissed = false
    @State private var entries: [String: CheckInEntryRow] = [:]
    @State private var sheet: CheckInSheet.Tab?
    @State private var editing: Set<CheckInSession> = []

    private var today: String { Repository.dayString(Date()) }

    var body: some View {
        Group {
            if settings.anyEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Check-ins", systemImage: "checklist").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button("History & insights") { sheet = .entries }.buttonStyle(.strandSecondary).controlSize(.small)
                    }
                    ForEach(CheckInSession.allCases.filter(settings.enabled), id: \.self) { s in
                        sessionBlock(s)
                    }
                }
                .padding(NoopMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .strandSurface()
            } else if !inviteDismissed {
                HStack(spacing: 12) {
                    Image(systemName: "checklist").font(.system(size: 15, weight: .semibold)).foregroundStyle(StrandPalette.accentInk)
                    Text("Optional check-ins: a few quick taps about things the strap can't see, like late caffeine or a hard day.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Button("Set up") { sheet = .settings }.buttonStyle(.strandSecondary).controlSize(.small)
                    Button { inviteDismissed = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityLabel("Hide check-in suggestion").help("Hide. Check-ins stay available in Settings.")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
            }
        }
        .task(id: "\(repo.checkInVersion)-\(today)") { await load() }
        .sheet(item: $sheet) { CheckInSheet(initial: $0).environmentObject(repo).environmentObject(settings) }
    }

    @ViewBuilder private func sessionBlock(_ s: CheckInSession) -> some View {
        let entry = entries["\(today)|\(s.rawValue)"]
        if let entry, !editing.contains(s) {
            CheckInSummaryRow(session: s, entry: entry) { editing.insert(s) }
        } else {
            CheckInForm(date: today, session: s, prompts: formPrompts(s, entry: entry), existing: entry, compact: true) { saved in
                editing.remove(s)
                if let saved { entries["\(today)|\(s.rawValue)"] = saved; CheckInReminders.shared.withdraw(session: s, date: today) }
            }
        }
    }

    private func formPrompts(_ s: CheckInSession, entry: CheckInEntryRow?) -> [CheckInPrompt] {
        guard let entry, !entry.answers.isEmpty else { return settings.prompts(s) }
        return entry.answers.compactMap { CheckInLibrary.prompt($0.promptId) }
    }

    private func load() async {
        let rows = await repo.checkIns(from: today, to: "9999-12-31")
        entries = Dictionary(rows.filter { $0.localDate == today }.map { ("\($0.localDate)|\($0.session)", $0) }, uniquingKeysWith: { _, b in b })
        // Keep the next week's reminders in step with what's done (saved or skipped anywhere).
        await CheckInReminders.shared.reschedule(settings: settings, done: Set(rows.map { "\($0.localDate)|\($0.session)" }))
    }
}

/// A finished or skipped session, folded to one line with an edit button.
private struct CheckInSummaryRow: View {
    let session: CheckInSession
    let entry: CheckInEntryRow
    let edit: () -> Void

    var body: some View {
        let yes = entry.answers.filter { $0.answer == CheckInAnswer.yes.rawValue }.count
        let answered = entry.answers.filter { [CheckInAnswer.yes.rawValue, CheckInAnswer.no.rawValue, CheckInAnswer.notSure.rawValue].contains($0.answer) }.count
        HStack(spacing: 10) {
            Image(systemName: entry.status == "skipped" ? "forward.end.circle" : "checkmark.circle.fill")
                .foregroundStyle(entry.status == "skipped" ? StrandPalette.textTertiary : StrandPalette.statusPositiveInk)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(entry.status == "skipped" ? "Skipped today" : "\(answered) of \(entry.answers.count) answered · \(yes) yes")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button("Edit", action: edit).buttonStyle(.strandSecondary).controlSize(.small)
                .accessibilityLabel("Edit \(session.title.lowercased())")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Form

/// Answer the prompts of one session for one local date. Untouched prompts are saved as "unanswered"; a prompt can be
/// skipped on its own; "Skip today" records the whole session as skipped.
struct CheckInForm: View {
    let date: String
    let session: CheckInSession
    let prompts: [CheckInPrompt]
    let existing: CheckInEntryRow?
    var compact = false
    let done: (CheckInEntryRow?) -> Void
    @EnvironmentObject var repo: Repository
    @State private var answers: [String: CheckInAnswer] = [:]
    @State private var note = ""
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(session.about).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
            }
            if prompts.isEmpty {
                Text("No prompts chosen for this check-in. Pick some in History & insights ▸ Settings.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(prompts) { p in promptRow(p) }
            if !compact || existing?.note != nil {
                TextField("Optional note", text: $note, axis: .vertical).lineLimit(1...3)
                    .textFieldStyle(.roundedBorder).font(StrandFont.caption)
            }
            HStack(spacing: 8) {
                Button(existing == nil ? "Save" : "Save changes") { Task { await save(status: "completed") } }
                    .buttonStyle(.strandPrimary).disabled(saving || prompts.isEmpty)
                Button("Skip today") { Task { await save(status: "skipped") } }
                    .buttonStyle(.strandSecondary).disabled(saving)
                if existing != nil { Button("Cancel") { done(nil) }.buttonStyle(.strandSecondary) }
                if failed { Text("Couldn't save. Try again.").font(StrandFont.caption).foregroundStyle(StrandPalette.statusCriticalInk) }
                Spacer()
            }
        }
        .onAppear(perform: prefill)
    }

    private func promptRow(_ p: CheckInPrompt) -> some View {
        HStack(spacing: 10) {
            Text(p.text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                ForEach([CheckInAnswer.yes, .no, .notSure], id: \.self) { a in answerButton(p, a) }
                answerButton(p, .skipped, label: "Skip")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(p.text)
    }

    private func answerButton(_ p: CheckInPrompt, _ a: CheckInAnswer, label: String? = nil) -> some View {
        let on = answers[p.id] == a
        let tint: Color = a == .yes ? StrandPalette.accent : a == .no ? StrandPalette.lavender : StrandPalette.textTertiary
        return Button {
            answers[p.id] = on ? nil : a
        } label: {
            Text(label ?? a.label)
                .font(.system(size: 12, weight: on ? .bold : .medium, design: .rounded))
                .foregroundStyle(on ? StrandPalette.textPrimary : (a == .skipped ? StrandPalette.textTertiary : StrandPalette.textSecondary))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(on ? tint.opacity(0.28) : StrandPalette.surfaceInset))
                .overlay(Capsule(style: .continuous).strokeBorder(on ? tint.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label ?? a.label)")
        .accessibilityHint(p.text)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func prefill() {
        guard let existing else { return }
        note = existing.note ?? ""
        for a in existing.answers {
            if let v = CheckInAnswer(rawValue: a.answer), v != .unanswered { answers[a.promptId] = v }
        }
    }

    private func save(status: String) async {
        saving = true; failed = false
        defer { saving = false }
        let now = Date().timeIntervalSince1970
        let versions = Dictionary((existing?.answers ?? []).map { ($0.promptId, $0.promptVersion) }, uniquingKeysWith: { a, _ in a })
        let rows = prompts.enumerated().map { i, p in
            CheckInAnswerRow(promptId: p.id, promptVersion: versions[p.id] ?? p.version,
                             answer: status == "skipped" ? (answers[p.id] ?? .skipped).rawValue : (answers[p.id] ?? .unanswered).rawValue,
                             position: i)
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CheckInEntryRow(localDate: date, session: session.rawValue, status: status, note: trimmed.isEmpty ? nil : trimmed,
                                    timeZone: TimeZone.current.identifier, createdAt: now, updatedAt: now, answers: rows)
        if await repo.saveCheckIn(entry) { done(entry) } else { failed = true }
    }
}

// MARK: - Sheet: entries, insights, settings

struct CheckInSheet: View {
    enum Tab: String, CaseIterable, Identifiable { case entries = "Entries", insights = "Insights", settings = "Settings"; var id: String { rawValue } }
    let initial: Tab
    @State private var tab: Tab = .entries
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Check-ins").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.strandSecondary).keyboardShortcut(.cancelAction)
            }
            SegmentedPillControl(Tab.allCases, selection: $tab, title: "Check-in sections") { $0.rawValue }
            ScrollView {
                Group {
                    switch tab {
                    case .entries: CheckInEntriesList()
                    case .insights: CheckInInsightsList()
                    case .settings: CheckInSettingsForm()
                    }
                }
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 620)
        .background(StrandPalette.surfaceBase)
        .onAppear { tab = initial }
    }
}

/// The last 30 local dates, each session viewable and editable. The date an entry belongs to never changes on edit.
private struct CheckInEntriesList: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var settings: CheckInSettings
    @State private var entries: [String: CheckInEntryRow] = [:]
    @State private var open: String?

    private var dates: [String] {
        (0..<30).compactMap { HighlightCalendar.addDays(Repository.dayString(Date()), -$0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a date to add or change its answers. Entries stay on the date they were made for.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            ForEach(dates, id: \.self) { d in
                ForEach(CheckInSession.allCases, id: \.self) { s in
                    let key = "\(d)|\(s.rawValue)"
                    let e = entries[key]
                    if e != nil || settings.enabled(s) { row(d, s, e, key) }
                }
            }
        }
        .task(id: repo.checkInVersion) {
            let rows = await repo.checkIns(from: dates.last ?? "0000-01-01", to: dates.first ?? "9999-12-31")
            entries = Dictionary(rows.map { ("\($0.localDate)|\($0.session)", $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    @ViewBuilder private func row(_ d: String, _ s: CheckInSession, _ e: CheckInEntryRow?, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open = open == key ? nil : key } label: {
                HStack {
                    Text(HighlightsContent.long(d)).font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 120, alignment: .leading)
                    Text(s == .morning ? "Morning" : "Evening").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    Text(status(e)).font(StrandFont.caption).foregroundStyle(e == nil ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                    Spacer()
                    Image(systemName: open == key ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(HighlightsContent.long(d)), \(s.title): \(status(e))")
            if open == key {
                CheckInForm(date: d, session: s,
                            prompts: (e?.answers.isEmpty == false ? e!.answers.compactMap { CheckInLibrary.prompt($0.promptId) } : settings.prompts(s)),
                            existing: e) { saved in
                    if let saved { entries[key] = saved }
                    open = nil
                }
                if e != nil {
                    Button("Clear this entry", role: .destructive) {
                        Task { if await repo.deleteCheckIn(localDate: d, session: s) { entries[key] = nil; open = nil } }
                    }
                    .buttonStyle(.plain).font(StrandFont.caption).foregroundStyle(StrandPalette.statusCriticalInk)
                }
            }
        }
        .padding(12)
        .strandSurface(cornerRadius: 14)
    }

    private func status(_ e: CheckInEntryRow?) -> String {
        guard let e else { return "No entry" }
        if e.status == "skipped" { return "Skipped" }
        let counts = Dictionary(grouping: e.answers, by: \.answer).mapValues(\.count)
        return CheckInAnswer.allCases.compactMap { a in counts[a.rawValue].map { "\($0) \(a.label.lowercased())" } }.joined(separator: " · ")
    }
}

/// Yes-vs-No comparisons per prompt, with counts and dates, from one outcome source at a time.
private struct CheckInInsightsList: View {
    @EnvironmentObject var repo: Repository
    @State private var comparisons: [CheckInComparison]?
    @State private var source: HighlightSource = .noop

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compares outcomes after days you answered Yes with days you answered No. Not sure, skipped and unanswered are left out, and days without a measurement aren't counted. Each finding needs at least \(CheckInInsights.minPerGroup) Yes and \(CheckInInsights.minPerGroup) No days. These are associations in your own data, not causes or advice, and they never change your scores.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let comparisons {
                Text("Outcomes from \(source.label) scores. Morning answers are compared with that morning's sleep and recovery; evening answers with the following night and next morning (training answers also with that day's strain).")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
                let byPrompt = Dictionary(grouping: comparisons, by: \.promptId)
                if byPrompt.isEmpty {
                    StrandNotice(symbol: "chart.bar.xaxis", title: "No answers yet", message: "Insights appear after a few weeks of check-ins.",
                                 tint: StrandPalette.textSecondary)
                }
                ForEach(CheckInLibrary.prompts.filter { byPrompt[$0.id] != nil }) { p in card(p, byPrompt[p.id] ?? []) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: repo.checkInVersion &+ repo.dataVersion) { await load() }
    }

    private func card(_ p: CheckInPrompt, _ cs: [CheckInComparison]) -> some View {
        let ready = cs.filter { $0.verdict != .notEnoughData }
        let first = cs.first
        return VStack(alignment: .leading, spacing: 6) {
            Text(p.topic).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
            Text(p.text).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            if ready.isEmpty, let first {
                Text("Not enough data yet: \(first.yesCount) Yes and \(first.noCount) No days with outcomes (needs \(CheckInInsights.minPerGroup) of each).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(ready, id: \.measure) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.sentence(topic: p.topic)).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Yes \(c.yesCount) days · No \(c.noCount) days · \(c.firstDay.map(HighlightsContent.long) ?? "") – \(c.lastDay.map(HighlightsContent.long) ?? "")")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface(cornerRadius: 16)
    }

    private func load() async {
        let rows = await repo.checkIns()
        let obs = rows.filter { $0.status == "completed" }.flatMap { e in
            e.answers.compactMap { a -> CheckInObservation? in
                guard let s = CheckInSession(rawValue: e.session), let v = CheckInAnswer(rawValue: a.answer) else { return nil }
                return CheckInObservation(localDate: e.localDate, session: s, promptId: a.promptId, promptVersion: a.promptVersion, answer: v)
            }
        }
        let noop = await repo.checkInOutcomes(source: .noop)
        let whoop = await repo.checkInOutcomes(source: .whoop)
        // One source for every comparison: whichever covers more answered dates (or their next mornings).
        let dates = Set(obs.map(\.localDate))
        func cover(_ o: [String: CheckInOutcomeDay]) -> Int { dates.filter { o[$0] != nil || o[HighlightCalendar.addDays($0, 1) ?? ""] != nil }.count }
        source = cover(whoop) > cover(noop) ? .whoop : .noop
        let outcomes = source == .whoop ? whoop : noop
        comparisons = await Task.detached(priority: .userInitiated) { CheckInInsights.all(observations: obs, outcomes: outcomes) }.value
    }
}

/// Turn sessions on or off, choose and order their prompts, and set reminders. Past entries are never touched.
struct CheckInSettingsForm: View {
    @EnvironmentObject var settings: CheckInSettings
    @EnvironmentObject var repo: Repository
    @State private var notificationsDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check-ins are optional and stay on this Mac. Turning one off or removing a prompt keeps every past answer.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            ForEach(CheckInSession.allCases, id: \.self) { s in section(s) }
            if notificationsDenied {
                Label("Notifications are off for NOOP in System Settings, so reminders can't appear. The Overview card still shows what's left today.",
                      systemImage: "bell.slash").font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarningInk)
            }
        }
        .task { notificationsDenied = await CheckInReminders.authorizationStatus() == .denied }
        .onChange(of: settings.morningReminder) { _ in Task { await reschedule() } }
        .onChange(of: settings.eveningReminder) { _ in Task { await reschedule() } }
        .onChange(of: settings.morningEnabled) { _ in Task { await reschedule() } }
        .onChange(of: settings.eveningEnabled) { _ in Task { await reschedule() } }
    }

    private func reschedule() async {
        let done = Set(await repo.checkIns(from: Repository.dayString(Date()), to: "9999-12-31").map { "\($0.localDate)|\($0.session)" })
        await CheckInReminders.shared.reschedule(settings: settings, done: done)
        notificationsDenied = await CheckInReminders.authorizationStatus() == .denied
    }

    private func section(_ s: CheckInSession) -> some View {
        let ids = settings.promptIds(s)
        let available = CheckInLibrary.prompts(for: s).filter { !ids.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { settings.enabled(s) }, set: { settings.setEnabled(s, $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(s.about).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .toggleStyle(.switch)
            if settings.enabled(s) {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    HStack(spacing: 8) {
                        Text(CheckInLibrary.prompt(id)?.text ?? id).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button { move(s, i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                            .accessibilityLabel("Move up")
                        Button { move(s, i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == ids.count - 1)
                            .accessibilityLabel("Move down")
                        Button { settings.setPromptIds(s, ids.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove prompt")
                    }
                    .buttonStyle(.borderless)
                }
                if !available.isEmpty {
                    Menu("Add a prompt") {
                        ForEach(available) { p in Button("\(p.topic): \(p.text)") { settings.setPromptIds(s, ids + [p.id]) } }
                    }
                    .fixedSize()
                }
                reminderRow(s)
            }
        }
        .padding(16)
        .strandSurface(cornerRadius: 16)
    }

    private func move(_ s: CheckInSession, _ i: Int, _ step: Int) {
        var ids = settings.promptIds(s)
        let j = i + step
        guard ids.indices.contains(j) else { return }
        ids.swapAt(i, j)
        settings.setPromptIds(s, ids)
    }

    private func reminderRow(_ s: CheckInSession) -> some View {
        let r = settings.reminder(s)
        let time = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                settings.setReminder(s, .init(enabled: r.enabled, hour: c.hour ?? r.hour, minute: c.minute ?? 0))
            })
        return HStack(spacing: 10) {
            Toggle("Reminder", isOn: Binding(get: { r.enabled }, set: { on in
                settings.setReminder(s, .init(enabled: on, hour: r.hour, minute: r.minute))
                if on { Task { _ = await CheckInReminders.requestAuthorization(); await reschedule() } }
            }))
            .toggleStyle(.checkbox)
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).labelsHidden().disabled(!r.enabled)
            Text("Stops once that day's check-in is saved or skipped.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}
