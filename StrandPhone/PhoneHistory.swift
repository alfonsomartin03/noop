import SwiftUI
import WhoopStore
import StrandSync
import StrandDesign

/// #80: every score the Mac has sent, browsable offline, as static daily summaries: an average per range (days without
/// a value are left out, never counted as 0) and the list of days. No charts or raw readings (owner rule, 2026-11-27).
struct PhoneHistoryView: View {
    let scores: [DailySummary]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Range: String, CaseIterable, Hashable { case month = "1M", quarter = "3M", all = "All" }
    @State private var range: Range = .month

    private var newest: String { scores.map(\.day).max() ?? ScoreHistory.day(Date()) }
    private var rangeDays: [String] {
        switch range {
        case .month: return ScoreHistory.lastDays(30, through: newest)
        case .quarter: return ScoreHistory.lastDays(91, through: newest)
        case .all:
            guard let oldest = scores.map(\.day).min(), let o = ScoreHistory.noon(oldest), let n = ScoreHistory.noon(newest)
            else { return [] }
            let span = Calendar.current.dateComponents([.day], from: o, to: n).day ?? 0
            return ScoreHistory.lastDays(span + 1, through: newest)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SegmentedPillControl(Range.allCases, selection: $range, title: "Range") { $0.rawValue }
                        .frame(maxWidth: .infinity)
                    let days = rangeDays
                    trendCard("Recovery", symbol: "circle.dotted.circle", key: "recovery", days: days,
                              tint: StrandPalette.recovery078) { "\(Int($0.rounded()))%" }
                    trendCard("Sleep", symbol: "bed.double.fill", key: "totalSleepMin", days: days,
                              tint: StrandPalette.sleepLight) { PhoneHomeView.hm($0) }
                    trendCard("Strain", symbol: "flame.fill", key: "strain", days: days,
                              tint: StrandPalette.scoreInk(StrandPalette.strain050)) { String(format: "%.1f", $0) }
                    ForEach(ScoreHistory.months(scores.filter { days.contains($0.day) }), id: \.month) { m in
                        monthSection(m.month, m.days)
                    }
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func trendCard(_ title: String, symbol: String, key: String, days: [String], tint: Color,
                           format: @escaping (Double) -> String) -> some View {
        let series = ScoreHistory.series(key, days: days, in: scores)
        let avg = ScoreHistory.average(series)
        return StrandWidget(title, symbol: symbol, tint: tint,
                            trailing: avg.map { "\($0.daysWithValue) of \($0.daysAsked) days" }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(avg.map { format($0.value) } ?? "—")
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundStyle(avg == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("average").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func monthSection(_ month: String, _ days: [DailySummary]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.monthTitle(month)).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary).padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(days, id: \.day) { s in
                    Button { open(s.day) } label: { row(s) }.buttonStyle(.plain)
                    if s.day != days.last?.day { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
                }
            }
            .padding(.horizontal, 14)
            .strandSurface()
        }
    }

    private func row(_ s: DailySummary) -> some View {
        let rec = s.values["recovery"]
        return HStack(spacing: 10) {
            Circle().fill(rec.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.scoreMissing).frame(width: 8, height: 8)
            Text(ScoreHistory.noon(s.day).map { $0.formatted(.dateTime.weekday(.abbreviated).day()) } ?? s.day)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 70, alignment: .leading)
            value(rec.map { "\(Int($0.rounded()))%" })
            value(s.values["totalSleepMin"].map(PhoneHomeView.hm))
            value(s.values["strain"].map { String(format: "%.1f", $0) })
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String?) -> some View {
        Text(text ?? "—").font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(text == nil ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    static func monthTitle(_ month: String) -> String {
        ScoreHistory.noon(month + "-01").map { $0.formatted(.dateTime.month(.wide).year()) }?.uppercased() ?? month
    }
}
