import SwiftUI
import StrandDesign

/// Recent WHOOP cycles. A cycle runs from one wake-up to the next, so it rarely matches a calendar
/// day; times are shown in the timezone the cycle was recorded in. Needs a WHOOP export import
/// done after cycle times were added to the importer.
struct RecentCyclesCard: View {
    @EnvironmentObject var repo: Repository

    private struct Row: Identifiable {
        let id: String
        let start: Date, end: Date?, tzMin: Int
        let recovery: Double?, strain: Double?, sleepMin: Double?
    }
    @State private var rows: [Row] = []

    var body: some View {
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Recent cycles", trailing: "WHOOP")
                    NoopCard {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(rows) { r in line(r) }
                        }
                    }
                }
            }
        }
        .task(id: repo.today?.day) { rows = await load() }
    }

    private func line(_ r: Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(window(r)).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(stats(r)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // Formats times in the timezone the cycle was recorded in, not the current one.
    private func window(_ r: Row) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: r.tzMin * 60) ?? .gmt
        let day = DateFormatter(); day.calendar = cal; day.timeZone = cal.timeZone; day.dateFormat = "EEE d MMM"
        let time = DateFormatter(); time.calendar = cal; time.timeZone = cal.timeZone; time.dateFormat = "HH:mm"
        let from = "\(day.string(from: r.start)) \(time.string(from: r.start))"
        guard let end = r.end else { return "\(from) → now" }
        let h = end.timeIntervalSince(r.start) / 3600
        return "\(from) → \(time.string(from: end)) · \(String(format: "%.1f", h)) h"
    }

    private func stats(_ r: Row) -> String {
        var parts: [String] = []
        if let v = r.recovery { parts.append("Recovery \(Int(v.rounded()))%") }
        if let v = r.strain { parts.append("Strain \(String(format: "%.1f", v))") }
        if let v = r.sleepMin { let t = Int(v.rounded()); parts.append("Slept \(t / 60)h \(t % 60)m") }
        return parts.isEmpty ? "No scores" : parts.joined(separator: " · ")
    }

    // Reads the stored cycle start/end/timezone series and joins them by day; shows the latest 5, newest first.
    private func load() async -> [Row] {
        let src = repo.deviceId
        let starts = await repo.series(key: "cycle_start_ts", source: src, days: 14)
        guard !starts.isEmpty else { return [] }
        func map(_ key: String) async -> [String: Double] {
            Dictionary(await repo.series(key: key, source: src, days: 14).map { ($0.day, $0.value) },
                       uniquingKeysWith: { _, b in b })
        }
        let ends = await map("cycle_end_ts"), tz = await map("cycle_tz_min")
        let rec = await map("recovery"), str = await map("strain"), slp = await map("sleep_total_min")
        return starts.suffix(5).reversed().map { p in
            Row(id: p.day, start: Date(timeIntervalSince1970: p.value),
                end: ends[p.day].map { Date(timeIntervalSince1970: $0) },
                tzMin: Int(tz[p.day] ?? 0), recovery: rec[p.day], strain: str[p.day], sleepMin: slp[p.day])
        }
    }
}
