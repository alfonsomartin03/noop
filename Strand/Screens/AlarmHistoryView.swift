import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Alarms ▸ History: one row per occurrence from the append-only alarm history, with what the evidence actually shows
/// ("Buzz requested" is not "Strap reported vibration"). Selecting one opens its event trail and the sleep timeline
/// around it (NOOP's own timestamped stage estimates only).
struct AlarmHistorySection: View {
    @ObservedObject var alarms: AlarmController
    @State private var selected: AlarmOccurrenceSummary?

    var body: some View {
        let items = Array(AlarmHistory.summarize(alarms.history).prefix(14))
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("History").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                .padding(.top, 8)
            if items.isEmpty {
                NoopCard {
                    Text("Nothing yet. Each alarm's decision, what was sent to the strap and what the strap reported will appear here.")
                        .font(.system(size: 13, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { s in
                        Button { selected = s } label: { AlarmHistoryRow(summary: s, note: alarms.annotations[s.id]) }
                            .buttonStyle(.plain)
                        if s.id != items.last?.id { Divider().padding(.leading, NoopMetrics.cardPadding) }
                    }
                }
                .strandSurface()
            }
        }
        .onChange(of: alarms.history.count) { _ in
            if LaunchMode.fixtureAlarmDetail, selected == nil { selected = AlarmHistory.summarize(alarms.history).first }
        }
        .sheet(item: $selected) { s in
            AlarmOccurrenceDetail(summary: s, rows: alarms.history.filter { $0.occurrenceId == s.id }, alarms: alarms)
        }
    }
}

extension AlarmOccurrenceSummary.Status {
    var tint: Color {
        switch self {
        case .strapReportedVibration, .strapAlarmRang, .dismissedOnStrap, .dismissedInApp: return StrandPalette.statusPositive
        case .buzzRequested, .ringingOnMac, .scheduled: return StrandPalette.accent
        case .deliveryUnconfirmed: return StrandPalette.statusWarning
        case .failed, .missed: return StrandPalette.statusCritical
        }
    }
}

struct AlarmHistoryRow: View {
    let summary: AlarmOccurrenceSummary
    var note: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.anchor.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                Text(timeLine).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                if let r = summary.decisionReason {
                    Text(r).font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let note { Text(AlarmAnnotation.label(note)).font(.system(size: 11, design: .rounded)).foregroundStyle(StrandPalette.textTertiary) }
            Text(summary.status.label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.ink(summary.status.tint))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(summary.status.tint.opacity(0.14), in: Capsule())
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.cardPadding).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var timeLine: String {
        let d = summary.decisionAt.map { "Decided \($0.formatted(date: .omitted, time: .shortened))" }
        let l = summary.deadline.map { "latest \($0.formatted(date: .omitted, time: .shortened))" }
        return [d, l].compactMap { $0 }.joined(separator: " · ")
    }
}

enum AlarmAnnotation {
    static let options: [(id: String, label: String)] = [("feltIt", "Felt it"), ("sleptThrough", "Slept through it"), ("alreadyAwake", "Already awake")]
    static func label(_ id: String) -> String { options.first { $0.id == id }?.label ?? id }
}

/// One occurrence: status, the event trail with sources and times, and the sleep timeline around it.
struct AlarmOccurrenceDetail: View {
    let summary: AlarmOccurrenceSummary
    let rows: [AlarmEventRow]
    @ObservedObject var alarms: AlarmController
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [CachedSleepSession]?

    private var span: (from: Int, to: Int) {
        let anchor = Int((summary.decisionAt ?? summary.deadline ?? Date()).timeIntervalSince1970)
        return (anchor - 90 * 60, anchor + 30 * 60)
    }
    private var stageSource: String { "NOOP estimate · scoring v\(IntelligenceEngine.scoringVersion)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(summary.anchor.formatted(date: .complete, time: .omitted)).font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Text(summary.status.label).font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.ink(summary.status.tint))
                    .padding(.horizontal, 9).padding(.vertical, 4).background(summary.status.tint.opacity(0.14), in: Capsule())
            }
            facts
            timeline
            trail
            HStack(spacing: 8) {
                Text("Your note:").font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
                ForEach(AlarmAnnotation.options, id: \.id) { o in
                    Button(o.label) { alarms.annotate(summary.id, label: o.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(alarms.annotations[summary.id] == o.id ? StrandPalette.accent : nil)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Notes are yours and kept apart from what the strap reported.")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(20)
        .frame(width: 560)
        .task { episodes = await repo.noopSleepEpisodes(from: span.from, to: span.to) }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let m = summary.modeText { fact("Alarm", m + (summary.deadline.map { " · latest \($0.formatted(date: .omitted, time: .shortened))" } ?? "")) }
            if let r = summary.decisionReason { fact("Decision", r + (summary.decisionAt.map { " (\($0.formatted(date: .omitted, time: .standard)))" } ?? "")) }
            if let q = summary.evidenceQuality { fact("Evidence", q) }
            if let b = summary.baselineSource { fact("Baseline", b) }
            if let p = summary.policyVersion { fact("Policy", p) }
            if let v = summary.vibrationReportedAt { fact("Strap reported", "vibration at \(v.formatted(date: .omitted, time: .standard))") }
            if let n = summary.notificationOutcome { fact("Mac notification", n) }
            if let d = summary.deliveryNote { fact("Delivery", d) }
            if summary.followUpBuzzes > 0 { fact("Follow-up", "\(summary.followUpBuzzes) extra buzz\(summary.followUpBuzzes == 1 ? "" : "es") (not dismissed yet)") }
            if let n = summary.liveSamples { fact("Live heart rate", "\(n) readings in the last 5 min of the window") }
            if !summary.hostNotes.isEmpty { fact("This Mac", summary.hostNotes.map(Self.hostNote).joined(separator: ", ")) }
            if let at = summary.decisionAt { fact("Stage at decision", stageText(at)) }
            if let at = summary.vibrationReportedAt { fact("Stage at vibration", stageText(at)) }
        }
    }

    private func stageText(_ t: Date) -> String {
        guard let episodes else { return "…" }
        switch AlarmStageLookup.stage(at: Int(t.timeIntervalSince1970), episodes: episodes, source: stageSource) {
        case .estimated(let stage, let source): return "\(stage.capitalized) (estimated · \(source))"
        case .unavailable(let why): return why
        }
    }


    static func hostNote(_ e: String) -> String {
        switch e { case "macSleep": return "went to sleep"; case "macWake": return "woke"; case "lateDeadline": return "handled the latest time late"; default: return e }
    }

    private func fact(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textSecondary).frame(width: 120, alignment: .leading)
            Text(v).font(.system(size: 12, design: .rounded)).foregroundStyle(StrandPalette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 90 min before to 30 min after, genuine stage segments only; separate markers for the decision and the reported
    /// vibration. Missing estimates are left empty, never filled in.
    @ViewBuilder private var timeline: some View {
        let segs = AlarmStageLookup.timeline(from: span.from, to: span.to, episodes: episodes ?? [])
        VStack(alignment: .leading, spacing: 6) {
            Text("Sleep around this alarm").font(.system(size: 13, weight: .semibold, design: .rounded))
            GeometryReader { g in
                let x = { (t: Int) -> CGFloat in CGFloat(Double(t - span.from) / Double(span.to - span.from)) * g.size.width }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(StrandPalette.surfaceInset).frame(height: 34).offset(y: 14)
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        Rectangle().fill(color(s.stage)).frame(width: max(1, x(s.end) - x(s.start)), height: 34)
                            .offset(x: x(s.start), y: 14)
                    }
                    if let d = summary.decisionAt { marker(x(Int(d.timeIntervalSince1970)), "Decision", StrandPalette.accent) }
                    if let v = summary.vibrationReportedAt { marker(x(Int(v.timeIntervalSince1970)), "Vibration", StrandPalette.statusPositive, below: true) }
                }
            }
            .frame(height: 66)
            HStack(spacing: 12) {
                ForEach(["wake", "light", "deep", "rem"], id: \.self) { st in
                    HStack(spacing: 4) { Circle().fill(color(st)).frame(width: 7, height: 7); Text(st.capitalized) }
                }
                Spacer()
                Text(segs.isEmpty ? "Stage unavailable for this time" : "Stages estimated · \(stageSource)")
            }
            .font(.system(size: 10, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func marker(_ x: CGFloat, _ label: String, _ tint: Color, below: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(tint).frame(width: 2, height: 44).offset(x: x - 1, y: 9)
            Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(StrandPalette.ink(tint))
                .fixedSize().offset(x: x + 3, y: below ? 52 : -2)
        }
    }

    private func color(_ stage: String) -> Color {
        switch stage {
        case "wake": return StrandPalette.sleepAwake
        case "light": return StrandPalette.sleepLight
        case "deep": return StrandPalette.sleepDeep
        case "rem": return StrandPalette.sleepREM
        default: return .clear
        }
    }

    private var trail: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("What happened").font(.system(size: 13, weight: .semibold, design: .rounded))
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows.sorted { $0.recordedAt < $1.recordedAt }, id: \.trailID) { r in
                        Text(Self.describe(r)).font(.system(size: 11, design: .monospaced)).foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    static func describe(_ r: AlarmEventRow) -> String {
        let t = Date(timeIntervalSince1970: r.mappedHostTs ?? r.recordedAt).formatted(date: .omitted, time: .standard)
        let f = AlarmHistory.fields(r.payload)
        let detail: String = {
            switch r.kind {
            case AlarmHistoryKind.strapEvent:
                let strap = r.deviceTs.map { " (strap \($0))" } ?? ""
                return "\(f["event"] as? String ?? "event") · \(r.provenance)\(strap)"
            case AlarmHistoryKind.commandRequested, AlarmHistoryKind.commandAcknowledged, AlarmHistoryKind.commandFailed, AlarmHistoryKind.commandTimedOut:
                return [f["command"] as? String, f["purpose"] as? String, f["detail"] as? String].compactMap { $0 }.joined(separator: " · ")
            case AlarmHistoryKind.decision: return (f["trigger"] as? String ?? "") + " · " + (f["reason"] as? String ?? "")
            case AlarmHistoryKind.notification: return f["outcome"] as? String ?? ""
            case AlarmHistoryKind.dismissal: return "by \(f["source"] as? String ?? "?")"
            case AlarmHistoryKind.deliveryOutcome: return [f["outcome"] as? String, f["detail"] as? String].compactMap { $0 }.joined(separator: " · ")
            default: return ""
            }
        }()
        return "\(t)  \(r.kind)  \(detail)"
    }
}

private extension AlarmEventRow {
    var trailID: String { "\(id ?? -1)-\(kind)-\(recordedAt)-\(dedupeKey ?? "")" }
}
