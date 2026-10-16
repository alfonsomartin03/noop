import SwiftUI
import StrandDesign
import StrandAnalytics

/// Sleep need — one glance: how much you slept vs how much the night asked for.
/// Uses WHOOP's reported need/debt when imported; otherwise a labelled NOOP estimate.
struct SleepNeedCard: View {
    @EnvironmentObject var repo: Repository
    @State private var summary: SleepNeed.Summary?

    var body: some View {
        Group {
            if let s = summary {
                NoopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sleep need").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(s.isOfficial ? "WHOOP score" : "NOOP estimate")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text("\(hm(s.asleepMin)) of \(hm(s.needMin))")
                            .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                        ProgressView(value: min(1, s.asleepMin / s.needMin))
                            .tint(StrandPalette.accent)
                        Text(caption(s)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        // Reloads only when the 'today' day changes, not on every refresh.
        .task(id: repo.today?.day) { summary = await load() }
    }

    private func caption(_ s: SleepNeed.Summary) -> String {
        if s.debtMin < 1 { return s.isOfficial ? "No sleep debt." : "You met your estimated need." }
        return s.isOfficial ? "Sleep debt: \(hm(s.debtMin))"
                            : "Short by \(hm(s.debtMin)) last night, against your recent average."
    }

    // Needs come from the WHOOP import when present; the last 14 nights feed the fallback estimate.
    private func load() async -> SleepNeed.Summary? {
        guard let today = repo.today else { return nil }
        let need = await repo.series(key: "sleep_need_min", source: repo.deviceId, days: 30)
            .first { $0.day == today.day }?.value
        let debt = await repo.series(key: "sleep_debt_min", source: repo.deviceId, days: 30)
            .first { $0.day == today.day }?.value
        let recent = repo.days.suffix(14).compactMap(\.totalSleepMin)
        return SleepNeed.summarize(officialNeed: need, officialDebt: debt,
                                   asleep: today.totalSleepMin, recentAsleep: recent)
    }

    private func hm(_ m: Double) -> String {
        let t = Int(m.rounded()); return "\(t / 60)h \(t % 60)m"
    }
}
