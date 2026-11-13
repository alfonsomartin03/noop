import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// Trends ▸ Highlights: personal records, longest streaks and notable extremes over 1M / 3M / All Time, one source at a
// time. Aggregation lives in `DataHighlights` (StrandAnalytics); this file only loads, picks a source and draws.

struct HighlightsView: View {
    @EnvironmentObject var repo: Repository
    @State private var inputs: [HighlightSource: HighlightInputs]?
    @AppStorage("noop.highlights.range") private var rangeRaw = HighlightRange.month1.rawValue
    @AppStorage("noop.highlights.source") private var sourceRaw = ""

    /// Changes whenever stored daily rows could have: sync, scoring, imports, corrections.
    private var reloadKey: String {
        let sum = repo.estimates.values.reduce(0.0) { $0 + ($1.recovery ?? 0) + ($1.strain ?? 0) + ($1.avgHrv ?? 0) }
        return "\(repo.dataVersion)-\(repo.official.count)-\(repo.estimates.count)-\(Int(sum * 10))"
    }

    var body: some View {
        HighlightsContent(inputs: inputs, range: Binding(get: { HighlightRange(rawValue: rangeRaw) ?? .month1 }, set: { rangeRaw = $0.rawValue }),
                          sourceRaw: $sourceRaw)
            .task(id: reloadKey) {
                let loaded = await repo.highlightInputs()
                inputs = loaded
            }
    }
}

struct HighlightsContent: View {
    let inputs: [HighlightSource: HighlightInputs]?
    @Binding var range: HighlightRange
    @Binding var sourceRaw: String
    @State private var result: DataHighlights?
    @State private var supporting: SupportingDay?

    private var available: [HighlightSource] {
        HighlightSource.allCases.filter { !(inputs?[$0]?.isEmpty ?? true) }
    }
    /// The user's pick when it has data, else WHOOP import when present (it carries sleep performance), else NOOP.
    private var source: HighlightSource {
        if let s = HighlightSource(rawValue: sourceRaw), available.contains(s) { return s }
        return available.first ?? .noop
    }

    private var computeKey: String {
        "\(range.rawValue)-\(source.rawValue)-\(inputs.map { i in i.values.map { $0.recovery.count + $0.strain.count + $0.hrv.count + $0.sleepPerformance.count } } ?? [])-\(Repository.dayString(Date()))-\(inputs == nil)"
    }

    var body: some View {
        ScreenScaffold(title: "Highlights", spacing: 24) {
            if inputs == nil {
                ComingSoon(what: "Loading your history…")
            } else if available.isEmpty {
                StrandNotice(symbol: "trophy", title: "No highlights yet",
                             message: "Records and streaks appear once NOOP has scored some completed days from your strap, or after you import a WHOOP export in Settings → Data.",
                             tint: StrandPalette.textSecondary)
            } else {
                controls
                if let h = result {
                    captions(h)
                    if h.eligibleDays == 0 {
                        StrandNotice(symbol: "calendar.badge.exclamationmark", title: "Nothing in this range",
                                     message: "No completed \(source.label) days fall in \(rangeText(h)). Try a longer range.",
                                     tint: StrandPalette.textSecondary)
                    } else {
                        records(h)
                        streaks(h)
                        notable(h)
                        methodNote(h)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: computeKey) {
            guard let inputs else { result = nil; return }
            let i = inputs[source] ?? HighlightInputs(), s = source, r = range, today = Repository.dayString(Date())
            // Off the main thread: all-time history can be years of rows.
            let h = await Task.detached(priority: .userInitiated) { DataHighlights.compute(i, source: s, range: r, today: today) }.value
            withAnimation(StrandMotion.respecting(StrandMotion.gentle)) { result = h }
        }
        .sheet(item: $supporting) { SupportingDaySheet(item: $0) }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            SegmentedPillControl(HighlightRange.allCases, selection: $range, title: "Highlights range", appearance: .quiet,
                                 spokenLabel: { $0 == .allTime ? "All time" : $0 == .month1 ? "1 month" : "3 months" }) { $0.rawValue }
            Spacer(minLength: 12)
            if available.count > 1 {
                SegmentedPillControl(available, selection: Binding(get: { source }, set: { sourceRaw = $0.rawValue }),
                                     title: "Source", controlSize: .small) { $0.label }
                    .help("Records and streaks never mix sources: imported WHOOP scores and NOOP's own scores are shown separately.")
            } else {
                SourceBadge(source.label, tint: source == .whoop ? StrandPalette.lavender : StrandPalette.accent)
            }
        }
    }

    private func captions(_ h: DataHighlights) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(rangeText(h)) · completed days only · \(h.eligibleDays) day\(h.eligibleDays == 1 ? "" : "s") with data")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(source == .whoop ? "Showing scores imported from your WHOOP export." : "Showing scores NOOP computed from your strap.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            if h.isPartialHistory, let first = h.historyStartDay {
                Label("Your \(source.label) history starts \(Self.long(first)), so this range is only partly covered.", systemImage: "calendar.badge.clock")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningInk)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rangeText(_ h: DataHighlights) -> String {
        guard let s = h.startDay else { return "Through \(Self.long(h.endDay))" }
        return "\(Self.long(s)) – \(Self.long(h.endDay))"
    }

    // MARK: Records

    private func records(_ h: DataHighlights) -> some View {
        EqualRowLayout(minWidth: 220, fallbackColumns: 1, spacing: NoopMetrics.gap) {
            RecordOrb(title: "Best sleep", symbol: "moon.stars.fill", record: h.bestSleep, scale: 100,
                      format: { "\(Int($0.rounded()))" }, unit: "%", color: { _ in StrandPalette.sleepLight },
                      definition: source == .whoop ? "Highest WHOOP sleep performance: sleep you got as a share of the sleep WHOOP estimated you needed."
                                                    : "Highest sleep performance.",
                      unavailable: source == .noop ? "NOOP doesn't compute a sleep-performance score. Import a WHOOP export to see this record." : "No sleep performance in this range.",
                      inspect: { inspect($0, "Best sleep") })
            RecordOrb(title: "Peak recovery", symbol: "heart.circle.fill", record: h.peakRecovery, scale: 100,
                      format: { "\(Int($0.rounded()))" }, unit: "%", color: StrandPalette.recoveryColor,
                      definition: "Highest \(source.label) recovery score (0–100 %).",
                      unavailable: "No recovery scores in this range.", inspect: { inspect($0, "Peak recovery") })
            RecordOrb(title: "Max strain", symbol: "flame.fill", record: h.maxStrain, scale: 21,
                      format: { String(format: "%.1f", $0) }, unit: "/ 21", color: StrandPalette.strainColor,
                      definition: "Highest \(source.label) day strain on the 0–21 scale. A high value is a description, not a target.",
                      unavailable: "No day strain in this range.", inspect: { inspect($0, "Max strain") })
        }
    }

    private func inspect(_ r: HighlightRecord, _ title: String) { supporting = SupportingDay(day: r.day, source: source, title: title) }

    // MARK: Streaks

    private func streaks(_ h: DataHighlights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Longest streaks").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            EqualRowLayout(minWidth: 200, fallbackColumns: 1, spacing: 12) {
                StreakBadge(title: "Sleep", symbol: "moon.fill", tint: StrandPalette.sleepLight, streak: h.sleepStreak,
                            rule: h.thresholds.sleepLabel,
                            unavailable: source == .noop ? "Needs WHOOP sleep performance" : "No qualifying nights")
                StreakBadge(title: "Green recovery", symbol: "heart.fill", tint: StrandPalette.statusPositive, streak: h.greenStreak,
                            rule: h.thresholds.recoveryLabel, unavailable: "No qualifying days")
                StreakBadge(title: "Strain", symbol: "flame.fill", tint: StrandPalette.zone4, streak: h.strainStreak,
                            rule: h.thresholds.strainLabel, unavailable: "No qualifying days")
            }
            Text("A streak counts consecutive days that each meet the rule. A day with no score ends a streak without counting as a miss.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Notable stats

    private func notable(_ h: DataHighlights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notable stats").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            VStack(spacing: 0) {
                statRow("Lowest resting heart rate", "heart", h.lowestRHR, unit: "bpm", decimals: 0)
                Divider().overlay(StrandPalette.hairline)
                statRow("Highest resting heart rate", "heart.fill", h.highestRHR, unit: "bpm", decimals: 0)
                Divider().overlay(StrandPalette.hairline)
                statRow("Lowest heart-rate variability", "waveform.path.ecg", h.lowestHRV, unit: "ms", decimals: 0)
                Divider().overlay(StrandPalette.hairline)
                statRow("Highest heart-rate variability", "waveform.path.ecg.rectangle", h.highestHRV, unit: "ms", decimals: 0)
            }
            .padding(.horizontal, NoopMetrics.cardPadding).padding(.vertical, 4)
            .strandSurface()
            Text("Extremes are descriptive: a low HRV or a high resting heart rate on one day isn't a goal or a diagnosis. Resting heart rate and HRV are measured during sleep.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func statRow(_ title: String, _ symbol: String, _ r: HighlightRecord?, unit: String, decimals: Int) -> some View {
        Button { if let r { inspect(r, title) } } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.metricRose)
                    .frame(width: 30, height: 30).background(StrandPalette.metricRose.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(r.map { Self.dateLine($0) } ?? "No \(source.label) readings in this range")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                if let r {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.\(decimals)f", r.value)).font(StrandFont.number(20, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("—").font(StrandFont.number(20, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(r == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(r.map { "\(title): \(String(format: "%.\(decimals)f", $0.value)) \(unit), \(Self.dateLine($0))" } ?? "\(title): no readings in this range")
        .accessibilityHint(r == nil ? "" : "Shows that day's stored values")
    }

    private func methodNote(_ h: DataHighlights) -> some View {
        Text("Highlights use completed days from one source at a time; today is left out until it ends. Missing days are skipped, never counted as zero. When several days share a record, the most recent is shown with the number of tied days.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Formatting

    static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC"); f.dateStyle = .medium; f.timeStyle = .none
        return f
    }()
    static func long(_ day: String) -> String { HighlightCalendar.date(day).map(longFormatter.string) ?? day }
    static func dateLine(_ r: HighlightRecord) -> String {
        long(r.day) + (r.tieCount > 1 ? " · tied on \(r.tieCount) days, latest shown" : "")
    }
}

// MARK: - Record orb

private struct RecordOrb: View {
    let title: String
    let symbol: String
    let record: HighlightRecord?
    let scale: Double
    let format: (Double) -> String
    let unit: String
    let color: (Double) -> Color
    let definition: String
    let unavailable: String
    let inspect: (HighlightRecord) -> Void
    @State private var drawn = false
    @State private var hovering = false

    var body: some View {
        let tint = record.map { color($0.value) } ?? StrandPalette.scoreMissing
        VStack(spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(StrandPalette.textSecondary)
            ZStack {
                Circle().stroke(StrandPalette.surfaceInset, lineWidth: 10)
                if let r = record {
                    Circle().trim(from: 0, to: drawn ? min(1, max(0.02, r.value / scale)) : 0)
                        .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: tint.opacity(0.35), radius: 6)
                }
                VStack(spacing: 0) {
                    Text(record.map { format($0.value) } ?? "—").font(StrandFont.number(34, weight: .bold))
                        .foregroundStyle(record == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    Text(record == nil ? " " : unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: 128, height: 128)
            if let r = record {
                Text(HighlightsContent.dateLine(r)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Button("View day") { inspect(r) }.buttonStyle(.strandSecondary).controlSize(.small)
            } else {
                Text(unavailable).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(definition).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity)
        .strandSurface(cornerRadius: 26)
        .scaleEffect(hovering && !StrandMotion.reduceMotion ? 1.01 : 1)
        .onHover { hovering = $0 }
        .animation(StrandMotion.respecting(StrandMotion.interactive), value: hovering)
        .onAppear {
            if StrandMotion.reduceMotion { drawn = true } else { withAnimation(StrandMotion.drawIn) { drawn = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(record.map { "\(title): \(format($0.value)) \(unit), \(HighlightsContent.dateLine($0))" } ?? "\(title): \(unavailable)")
    }
}

// MARK: - Streak badge

private struct StreakBadge: View {
    let title: String
    let symbol: String
    let tint: Color
    let streak: HighlightStreak?
    let rule: String
    let unavailable: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(streak == nil ? 0.08 : 0.2))
                Image(systemName: symbol).font(.system(size: 17, weight: .bold))
                    .foregroundStyle(streak == nil ? StrandPalette.textTertiary : StrandPalette.ink(tint))
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                if let s = streak {
                    Text("\(s.days) day\(s.days == 1 ? "" : "s")").font(StrandFont.number(22, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(s.days == 1 ? HighlightsContent.long(s.startDay) : "\(HighlightsContent.long(s.startDay)) – \(HighlightsContent.long(s.endDay))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    if s.clippedAtStart {
                        Text("Began at or before the range start").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                } else {
                    Text("—").font(StrandFont.number(22, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
                    Text(unavailable).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Text(rule).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface(cornerRadius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(streak.map { "\(title) streak: \($0.days) days, \(HighlightsContent.long($0.startDay)) to \(HighlightsContent.long($0.endDay)). Rule: \(rule)" }
                            ?? "\(title) streak: \(unavailable). Rule: \(rule)")
    }
}

// MARK: - Supporting day

struct SupportingDay: Identifiable {
    let day: String
    let source: HighlightSource
    let title: String
    var id: String { "\(source.rawValue)-\(day)-\(title)" }
}

struct SupportingDaySheet: View {
    let item: SupportingDay
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var row: DailyMetric?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text("\(HighlightsContent.long(item.day)) · \(item.source.label)").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.strandSecondary).keyboardShortcut(.cancelAction)
            }
            if let r = row {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    line("Recovery", r.recovery.map { "\(Int($0.rounded())) %" })
                    line("Day strain", r.strain.map { String(format: "%.1f / 21", $0) })
                    line("Asleep", r.totalSleepMin.map { DayMath.hm($0) })
                    line("Sleep efficiency", r.efficiency.map { "\(Int($0.rounded())) %" })
                    line("Resting heart rate", r.restingHr.map { "\($0) bpm" })
                    line("Heart-rate variability", r.avgHrv.map { "\(Int($0.rounded())) ms" })
                    line("Respiratory rate", r.respRateBpm.map { String(format: "%.1f breaths/min", $0) })
                }
                Text("Stored values for this day from \(item.source.label) only. A dash means nothing was stored, not zero.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else if loaded {
                Text("No stored row for this day.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 360)
        .background(StrandPalette.surfaceBase)
        .task { row = await repo.dailyMetric(item.day, source: item.source); loaded = true }
    }

    private func line(_ title: String, _ value: String?) -> some View {
        GridRow {
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text(value ?? "—").font(StrandFont.bodyNumber).foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}
