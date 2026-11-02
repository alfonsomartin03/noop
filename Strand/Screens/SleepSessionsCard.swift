import SwiftUI
import WhoopStore
import StrandAnalytics
import StrandDesign

/// Recent sleep sessions with their automatic label and lightweight corrections (nap / main sleep / not sleep /
/// confirm / merge / split / adjust). Lives on the Sleep screen; no separate page.
struct SleepSessionsCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var model: AppModel
    @State private var adjusting: SessionRow?

    struct SessionRow: Identifiable, Equatable {
        let id: String
        let episodes: [CachedSleepSession]
        var start: Int { episodes.first!.startTs }
        var end: Int { episodes.last!.endTs }
        var kind: String { episodes.first?.kind ?? "primary" }
        var reason: String { episodes.first?.reason ?? "" }
        var gaps: Int { episodes.count - 1 }
    }

    private var rows: [SessionRow] {
        let grouped = Dictionary(grouping: repo.recentSleepEpisodes) { $0.sessionId ?? "s\($0.startTs)" }
        return grouped.map { SessionRow(id: $0.key, episodes: $0.value.sorted { $0.startTs < $1.startTs }) }
            .sorted { $0.start > $1.start }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Sleep sessions", overline: "Last 3 days")
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        row(r, previous: i + 1 < rows.count ? rows[i + 1] : nil)
                        if i < rows.count - 1 { Divider() }
                    }
                }
                .padding(NoopMetrics.cardPadding)
                .strandSurface()
                Text("Only the main sleep feeds recovery. Naps add to your 24-hour sleep; unconfirmed sessions count nowhere until you confirm them. Your corrections are kept through future syncs.")
                    .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sheet(item: $adjusting) { r in AdjustSleepSheet(row: r) { s, e in
                model.correctSleep(SleepCorrection(action: .adjust, start: r.start, end: r.end, newStart: s, newEnd: e))
            } }
        }
    }

    private func row(_ r: SessionRow, previous: SessionRow?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label(r.kind))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint(r.kind).opacity(0.15), in: Capsule())
                .foregroundStyle(tint(r.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(time(r.start)) – \(time(r.end)) · \(duration(r.end - r.start))"
                     + (r.gaps > 0 ? " · \(r.gaps) awake gap\(r.gaps == 1 ? "" : "s")" : ""))
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                if !r.reason.isEmpty {
                    Text(r.reason).font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer()
            Menu {
                if r.kind != "nap" { Button("Mark as nap") { act(.markNap, r) } }
                if r.kind != "primary" && r.kind != "interruptedPrimary" { Button("Mark as main sleep") { act(.markPrimary, r) } }
                if r.kind == "uncertain" { Button("Confirm sleep") { act(.confirm, r) } }
                Button("Not sleep (quiet rest)") { act(.reject, r) }
                if let p = previous {
                    Button("Merge with previous session") {
                        model.correctSleep(SleepCorrection(action: .merge, start: p.start, end: r.end))
                    }
                }
                if r.gaps > 0 {
                    Button("Split at first awake gap") {
                        let cut = (r.episodes[0].endTs + r.episodes[1].startTs) / 2
                        model.correctSleep(SleepCorrection(action: .split, start: r.start, end: r.end, at: cut))
                    }
                }
                Button("Adjust times…") { adjusting = r }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(StrandPalette.textSecondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, 8)
    }

    private func act(_ a: SleepCorrection.Action, _ r: SessionRow) {
        model.correctSleep(SleepCorrection(action: a, start: r.start, end: r.end))
    }

    private func label(_ k: String) -> String {
        switch k {
        case "primary": return "Main sleep"
        case "interruptedPrimary": return "Main sleep · interrupted"
        case "nap": return "Nap"
        default: return "Unconfirmed"
        }
    }
    private func tint(_ k: String) -> Color {
        switch k {
        case "primary", "interruptedPrimary": return StrandPalette.lavenderInk
        case "nap": return StrandPalette.statusPositive
        default: return StrandPalette.statusWarning
        }
    }
    private func time(_ t: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(t)).formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    private func duration(_ s: Int) -> String { s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 60)m" }
}

/// Pick new sleep / wake times for one session. Episodes are not rewritten; metrics are clipped to these bounds.
private struct AdjustSleepSheet: View {
    let row: SleepSessionsCard.SessionRow
    let save: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust sleep times").font(.system(size: 15, weight: .semibold))
            DatePicker("Fell asleep", selection: $start)
            DatePicker("Woke up", selection: $end)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
                    dismiss()
                }
                .buttonStyle(.strandPrimary)
                .disabled(end <= start)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            start = Date(timeIntervalSince1970: TimeInterval(row.start))
            end = Date(timeIntervalSince1970: TimeInterval(row.end))
        }
    }
}
