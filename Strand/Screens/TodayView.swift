import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol
import Foundation

// MARK: - Today — the home dashboard
//
// A week strip plus four squares: Recovery, Sleep, Strain and live Heart rate. Each square shows the basics for the
// picked day; tapping Recovery, Sleep or Strain opens its full breakdown in place (TodayDetailViews.swift).

// Home dashboard: week strip, then the four squares; a tapped square swaps in its detail page under the same strip.
struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @Environment(\.navigate) private var navigate

    /// Day picked in the calendar strip (yyyy-MM-dd); nil follows the newest day with data.
    @State private var selectedDay: String?
    /// Which square is open, or nil for the dashboard.
    @State private var detail: TodayDetail?
    /// Apple Health steps for the picked day, when imported (the strap itself doesn't count steps).
    @State private var steps: Int?
    /// The picked day's strap heart-rate samples, summarised once per load.
    @State private var dayStats: DayHRStats?
    /// The night's main sleep session (longest one ending on the picked day), for the stage graph.
    @State private var night: CachedSleepSession?

    private var byDay: [String: DailyMetric] {
        Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
    }
    private var activeDay: String { selectedDay ?? repo.today?.day ?? Repository.dayString(Date()) }
    /// The metrics for the picked day; every score card below reads this instead of "latest".
    private var shown: DailyMetric? { byDay[activeDay] }

    var body: some View {
        ScreenScaffold(title: greetingWord, subtitle: dateLine, spacing: Self.headerGap) {
            // One uniform gap between the notices, week strip and cards (the scaffold's section gap is too loose here).
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                PairingResetNotice()
                ConnectionStrip()
                SyncProgressStrip()
                WeekStrip(activeDay: activeDay, byDay: byDay) { selectedDay = $0 }
                if let detail {
                    detailPage(detail).transition(.opacity)
                } else {
                    if shown?.recovery == nil {
                        StrandNotice(
                            symbol: "sparkles",
                            title: "Your scores are building",
                            message: "Live heart rate works from the strap right away. Recovery, strain and sleep build over your next few nights of wear. To see your history now, import your WHOOP export in Settings → Data."
                        )
                    }
                    dashboard.transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: detail)
        }
        .task(id: "\(activeDay)-\(repo.dataVersion)") { await loadAll() }
    }

    /// Heading to first content: a little more than the card gap, so the heading reads as the page's own.
    private static let headerGap: CGFloat = 20

    private func open(_ d: TodayDetail) { detail = d }
    private func close() { detail = nil }

    @ViewBuilder
    private func detailPage(_ d: TodayDetail) -> some View {
        switch d {
        case .recovery: RecoveryDetailView(day: shown, days: repo.days, official: repo.isOfficial(activeDay), back: close)
        case .sleep:    SleepDetailView(day: shown, days: repo.days, back: close)
        case .strain:   StrainDetailView(day: shown, dayKey: activeDay, days: repo.days, back: close)
        }
    }

    // MARK: Widgets

    /// Recovery, Sleep and Strain are the page: three large cards. Heart rate sits below as a full-width day view.
    @ViewBuilder
    private var dashboard: some View {
        let d = shown
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // A plain row (not the packing grid) so the gap to the heart-rate card below is exactly one card gap.
            ScoreCardRow(first: { recoveryWidget(d) }, second: { sleepWidget(d) }, third: { strainWidget(d) })
            HeartRateDayCard(day: activeDay, metric: d, days: repo.days, stats: dayStats) { navigate(.live) }
        }
        .redacted(reason: repo.loaded ? [] : .placeholder)
    }

    /// Recovery card: big ring, state word, and the two numbers that drive it most (HRV and resting HR).
    private func recoveryWidget(_ d: DailyMetric?) -> some View {
        let score = d?.recovery
        let tint = score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
        return StrandWidget("Recovery", symbol: "circle.dotted.circle", tint: tint, action: { open(.recovery) }) {
            VStack(spacing: 12) {
                ProgressRing(fraction: (score ?? 0) / 100, tint: tint, lineWidth: 14) {
                    VStack(spacing: 0) {
                        Text(score.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 46, weight: .bold).monospacedDigit())
                            .foregroundStyle(score == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        if score != nil { Text("%").font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary) }
                    }
                }
                .frame(width: 150, height: 150)
                Text(score.map { StrandPalette.recoveryState($0).capitalized } ?? "No data").font(.system(size: 24, weight: .bold)).foregroundStyle(StrandPalette.scoreInk(tint))
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    chip("HRV", d?.avgHrv.map { "\(Int($0.rounded())) ms" }, StrandPalette.metricPurple)
                    chip("Resting HR", d?.restingHr.map { "\($0) bpm" }, StrandPalette.metricRose)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Sleep card: hours asleep as the headline, efficiency, the stage split and sleep need.
    private func sleepWidget(_ d: DailyMetric?) -> some View {
        let tint = StrandPalette.sleepLight
        return StrandWidget("Sleep", symbol: "bed.double.fill", tint: tint, action: { open(.sleep) }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(d?.totalSleepMin == nil ? "—" : sleepValue(d))
                    .font(.system(size: 46, weight: .bold).monospacedDigit())
                    .foregroundStyle(d?.totalSleepMin == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(d?.totalSleepMin == nil ? "No sleep recorded for this day" : "asleep")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                if d?.totalSleepMin != nil {
                    if let tl = SleepTimeline.intervals(session: night, day: d) {
                        // The same stage-over-the-night staircase as the Sleep tab.
                        Hypnogram(intervals: tl.intervals, height: 84, showsStageAxis: false,
                                  nightStart: night.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) },
                                  timeZone: night.map { ZoneTimeline.shared.zone(forSpan: $0.startTs, $0.endTs) } ?? .autoupdatingCurrent)
                        if tl.estimated {
                            Text("Stage order estimated from totals").font(.system(size: 10))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    } else {
                        SleepStageBar(deep: d?.deepMin, rem: d?.remMin, light: d?.lightMin)
                    }
                }
                VStack(spacing: 6) {
                    chip("Efficiency", d?.efficiency.map { String(format: "%.0f%%", $0) }, StrandPalette.statusPositive)
                    chip("Restorative", d?.totalSleepMin == nil ? nil : DayMath.hm((d?.deepMin ?? 0) + (d?.remMin ?? 0)), StrandPalette.sleepDeep)
                }
            }
        }
    }

    /// Strain card: ring out of 21, then what the strap measured that day (active time, energy, steps if imported).
    private func strainWidget(_ d: DailyMetric?) -> some View {
        let v = d?.strain
        let tint = v.map { StrandPalette.strainColor($0) } ?? StrandPalette.scoreMissing
        return StrandWidget("Strain", symbol: "flame.fill", tint: tint, action: { open(.strain) }) {
            VStack(spacing: 12) {
                ProgressRing(fraction: (v ?? 0) / 21, tint: tint, lineWidth: 14) {
                    VStack(spacing: 0) {
                        Text(v.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 44, weight: .bold).monospacedDigit())
                            .foregroundStyle(v == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        Text("of 21").font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(width: 150, height: 150)
                Text(v.map { strainWord($0) } ?? "No data").font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.scoreInk(tint))
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    chip("Active", dayStats.flatMap { $0.isEmpty ? nil : DayMath.hm($0.activeMin) }, StrandPalette.statusPositive)
                    chip("Energy", dayStats?.kcal.map { "\(Int($0.rounded())) kcal" }, StrandPalette.metricAmber)
                    if let steps { chip("Steps", steps.formatted(), StrandPalette.accent) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Full-width rounded label + value pill used under a card's headline.
    private func chip(_ label: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint.opacity(0.8), radius: 3)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 4)
            Text(value ?? "—").font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(StrandPalette.surfaceInset, in: Capsule())
    }

    private func strainWord(_ v: Double) -> String {
        switch v {
        case ..<6:  return "Light load"
        case ..<10: return "Moderate load"
        case ..<14: return "Strenuous"
        default:    return "All out"
        }
    }

    // MARK: - Loading

    // Per picked day: the strap's stored heart-rate samples (summarised once) and Apple Health steps if imported.
    private func loadAll() async {
        let key = activeDay
        if let r = DayMath.range(key) {
            let samples = await repo.hrSamples(from: r.from, to: r.to, limit: 200_000)
            let scoredMax = await repo.dayLoad(key)?.calibration.hrMax
            dayStats = await DayHRStats.build(hr: samples, profile: profile, restingHR: byDay[key]?.restingHr, maxHR: scoredMax)
            night = SleepTimeline.pick(repo.sleeps, range: r, day: byDay[key])
        }
        let apple = await repo.appleDailyRows().first { $0.day == key }
        steps = apple?.steps
    }

    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    private var greetingWord: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        if let date = WeekStrip.date(activeDay) { return f.string(from: date) }
        return f.string(from: Date())
    }


    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }
}


// MARK: - Week calendar strip

/// Seven day tiles (Monday first) for the week containing the picked day. The picked tile glows blue; a dot under each
/// day shows its recovery colour, or stays empty when the strap recorded nothing. Arrows page by week.
private struct WeekStrip: View {
    let activeDay: String
    let byDay: [String: DailyMetric]
    let pick: (String) -> Void

    private static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; return c }()
    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func date(_ day: String) -> Date? { parser.date(from: day) }
    static func string(_ d: Date) -> String { parser.string(from: d) }

    /// The seven yyyy-MM-dd strings of the week (Mon…Sun) that contains `day`.
    static func days(inWeekOf day: String) -> [String] {
        guard let d = date(day), let start = cal.dateInterval(of: .weekOfYear, for: d)?.start else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.map(string)
    }

    private var week: [String] { Self.days(inWeekOf: activeDay) }
    private var todayString: String { Self.string(Date()) }

    private func shiftWeek(_ delta: Int) {
        guard let d = Self.date(activeDay), let moved = Self.cal.date(byAdding: .day, value: 7 * delta, to: d) else { return }
        let target = Self.string(moved)
        pick(target > todayString ? todayString : target)
    }

    var body: some View {
        HStack(spacing: NoopMetrics.gap / 2) {
            arrow("chevron.left") { shiftWeek(-1) }
            ForEach(week, id: \.self) { day in tile(day) }
            arrow("chevron.right") { shiftWeek(1) }
                .opacity((week.last ?? "") >= todayString ? 0.3 : 1)
                .disabled((week.last ?? "") >= todayString)
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                .foregroundStyle(StrandPalette.accentInk).frame(width: 26, height: 44)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ day: String) -> some View {
        let date = Self.date(day)
        let selected = day == activeDay
        let isFuture = day > todayString
        let rec = byDay[day]?.recovery
        let label = date.map { Self.cal.shortWeekdaySymbols[Self.cal.component(.weekday, from: $0) - 1].uppercased() } ?? ""
        let num = date.map { Self.cal.component(.day, from: $0) } ?? 0
        return Button { pick(day) } label: {
            VStack(spacing: 4) {
                Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : StrandPalette.textTertiary)
                Text("\(num)").font(.system(size: 20, weight: .bold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : StrandPalette.textPrimary)
                Circle()
                    .fill(rec.map { StrandPalette.recoveryColor($0) } ?? (byDay[day] != nil ? StrandPalette.textTertiary : Color.clear))
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [StrandPalette.accentHover, StrandPalette.accent],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(StrandPalette.surfaceRaised))
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.25) : StrandPalette.hairline, lineWidth: 0.5))
            .shadow(color: selected ? StrandPalette.accent.opacity(0.55) : .clear, radius: 14, y: 4)
            .opacity(isFuture ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }
}

// MARK: - Live widgets (isolated so the ~1 Hz stream only re-renders these small views)

/// Shown only when the strap is not connected: a single quiet line with a Connect action.
// The live views below are separate structs so the ~1 Hz heart-rate stream only re-renders these small pieces.
private struct ConnectionStrip: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel
    var body: some View {
        if !live.connected {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WHOOP not connected").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Keep your strap nearby and connect to see live heart rate.")
                        .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button("Connect") { model.scan() }.buttonStyle(.strandPrimary)
            }
            .padding(NoopMetrics.cardPadding)
            .strandSurface()
        }
    }
}

/// Sync status while the strap offloads stored data, then while NOOP processes it.
/// Progress is measured in strap time (how much of the strap's unsent history is saved), never in bytes or rows,
/// and reaches 100 % only after the strap confirmed the transfer complete.
private struct SyncProgressStrip: View {
    @EnvironmentObject var live: LiveState

    var body: some View {
        if live.historyBusy {
            strip(icon: "arrow.triangle.2.circlepath", title: "Syncing WHOOP data") { downloading }
        } else if let status = live.processingStatus {
            strip(icon: "gearshape.2", title: "Processing your data") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        } else if let outcome = live.lastSyncOutcome {
            strip(icon: "exclamationmark.triangle", title: "Sync incomplete") {
                HStack {
                    Text(outcome).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { live.lastSyncOutcome = nil }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var downloading: some View {
        if let s = live.syncSession, s.target > s.strapFrom {
            let total = s.target - s.strapFrom
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(SyncFormat.duration(s.accountedSeconds)) of \(SyncFormat.duration(total)) synchronized")
                        .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("\(Int((s.fraction * 100).rounded(.down)))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
                ProgressView(value: s.fraction).animation(.easeOut(duration: 0.4), value: s.fraction)
                Text("\(SyncFormat.duration(s.remainingSeconds)) of recorded history left to download · \(live.syncSavedRows.formatted()) new readings saved")
                    .font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            // Before the strap reports its range (or if it never does) there is no honest percentage.
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text(live.historyStatus + (live.syncSavedRows > 0 ? " · \(live.syncSavedRows.formatted()) new readings saved" : ""))
                    .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func strip<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                content()
            }
        }
        .padding(NoopMetrics.cardPadding)
        .strandSurface()
    }
}

/// "2h 11m", "49 min", "35 s" — durations of recorded history, not download time.
enum SyncFormat {
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 48 { return "\(h / 24) d \(h % 24) h" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

/// Heart rate for the picked day: the day's curve from the strap, the live reading when the day is today, and a few
/// plain-language insights computed from the same samples.
private struct HeartRateDayCard: View {
    let day: String
    let metric: DailyMetric?
    let days: [DailyMetric]
    let stats: DayHRStats?
    let openLive: () -> Void

    private var isToday: Bool { day == Repository.dayString(Date()) }

    var body: some View {
        StrandWidget("Heart rate", symbol: "heart.fill", tint: StrandPalette.metricRose, trailing: isToday ? "Live" : nil, action: openLive) {
            SummaryChartLayout {
                summary
                chart
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            ForEach(insights.prefix(5)) { ins in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ins.icon).font(.system(size: 11, weight: .bold)).foregroundStyle(ins.tint).frame(width: 16)
                    Text(ins.text).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Headline numbers

    @ViewBuilder private var headline: some View {
        if isToday {
            LiveHeadline(average: stats?.average)
        } else if let avg = stats?.average {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(avg)").font(.system(size: 52, weight: .bold).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                Text("bpm average").font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
            }
        } else {
            Text("—").font(.system(size: 52, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
        }
        if let s = stats, !s.isEmpty, let lo = s.low, let hi = s.peak {
            HStack(spacing: 8) {
                stat("Low", "\(lo.bpm)", StrandPalette.metricCyan)
                stat("Avg", s.average.map(String.init) ?? "—", StrandPalette.textPrimary)
                stat("Peak", "\(hi.bpm)", StrandPalette.statusCritical)
            }
        }
    }

    /// Today's headline: the live number while one is streaming, else the day's average. The only part of the card that
    /// follows the live feed, so a new beat redraws this text and not the chart or insights.
    private struct LiveHeadline: View {
        @EnvironmentObject var heart: LiveHeartRate
        let average: Int?
        var body: some View {
            if let bpm = heart.bpm {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(bpm)").font(StrandFont.number(52, weight: .bold)).foregroundStyle(StrandPalette.metricRose)
                    Text("bpm now").font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else if let average {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(average)").font(StrandFont.number(52, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    Text("bpm average").font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("—").font(.system(size: 52, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityLabel("No heart rate")
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Chart

    private static let gradient = Gradient(colors: [StrandPalette.metricCyan, StrandPalette.metricRose, StrandPalette.statusCritical])

    @ViewBuilder private var chart: some View {
        if let s = stats, s.samples.count > 1 {
            let pts = Self.downsample(s.samples, to: 320)
            VStack(alignment: .leading, spacing: 6) {
                Sparkline(values: pts.map { Double($0.bpm) }, gradient: Self.gradient, lineWidth: 2.5, showsArea: true,
                          showsHead: false, showsHover: true,
                          valueFormat: { "\(Int($0.rounded())) bpm" },
                          indexLabel: { i in pts.indices.contains(i) ? DayMath.clock(pts[i].ts) : "" })
                HStack {
                    Text(DayMath.clock(pts.first!.ts)); Spacer(); Text(DayMath.clock(pts.last!.ts))
                }
                .font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "heart.slash").font(.system(size: 22)).foregroundStyle(StrandPalette.textTertiary)
                Text("No heart-rate samples stored for this day").font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                Text("They arrive when the strap syncs.").font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func downsample(_ s: [HRSample], to n: Int) -> [HRSample] {
        guard s.count > n else { return s }
        let step = Double(s.count) / Double(n)
        return (0..<n).map { s[Int(Double($0) * step)] }
    }

    // MARK: Insights

    private struct Insight: Identifiable { let id = UUID(); let icon: String; let text: String; let tint: Color }

    private var insights: [Insight] {
        var out: [Insight] = []
        if let rhr = metric?.restingHr {
            let base = DayMath.baseline(days, before: day) { $0.restingHr.map(Double.init) }
            if let base {
                let d = Double(rhr) - base
                let rel = abs(d) < 1 ? "in line with your 30-day average"
                    : "\(Int(abs(d).rounded())) bpm \(d < 0 ? "below" : "above") your 30-day average"
                out.append(Insight(icon: d <= 0.5 ? "arrow.down.heart.fill" : "arrow.up.heart.fill",
                                   text: "Resting HR \(rhr) bpm, \(rel).",
                                   tint: d <= 0.5 ? StrandPalette.statusPositive : StrandPalette.statusWarning))
            } else {
                out.append(Insight(icon: "heart.fill", text: "Resting HR \(rhr) bpm.", tint: StrandPalette.metricRose))
            }
        }
        if let s = stats, !s.isEmpty {
            if let hi = s.peak {
                let pct = Int((Double(hi.bpm) / max(s.zoneSet.maxHR, 1) * 100).rounded())
                out.append(Insight(icon: "bolt.heart.fill", text: "Peaked at \(hi.bpm) bpm at \(DayMath.clock(hi.ts)), \(pct)% of your max.",
                                   tint: StrandPalette.statusCritical))
            }
            if let lo = s.low {
                out.append(Insight(icon: "moon.zzz.fill", text: "Lowest was \(lo.bpm) bpm at \(DayMath.clock(lo.ts)).", tint: StrandPalette.metricCyan))
            }
            out.append(Insight(icon: "flame.fill",
                               text: s.elevatedMin >= 1 ? "Elevated (Zone 3+) for \(DayMath.hm(s.elevatedMin))."
                                                        : "No time in Zone 3 or higher, a calm day for your heart.",
                               tint: StrandPalette.metricAmber))
            let hours = s.coveredS / 3600
            out.append(Insight(icon: hours >= 20 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                               text: hours >= 20 ? String(format: "Heart rate recorded for %.0f h of the day.", hours)
                                                 : String(format: "Only %.1f h recorded. Gaps mean the strap was off or hasn't synced yet.", hours),
                               tint: hours >= 20 ? StrandPalette.statusPositive : StrandPalette.statusWarning))
        }
        return out
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Control Center") {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    var sample: [DailyMetric] = []
    for i in stride(from: 39, through: 0, by: -1) {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        let day = Repository.dayString(date)
        let phase = Double(i)
        let rec = 48 + 34 * sin(phase / 5.0) + Double((i * 7) % 11)
        let strain = 8 + 7 * abs(sin(phase / 4.0))
        let total = 380 + 70 * sin(phase / 6.0)
        sample.append(DailyMetric(
            day: day, totalSleepMin: total, efficiency: 88 + 6 * sin(phase / 3.0),
            deepMin: 95, remMin: 110, lightMin: total - 200, disturbances: 4,
            restingHr: 50 + (i % 6), avgHrv: 58 + 16 * sin(phase / 4.0),
            recovery: min(max(rec, 8), 99), strain: strain, exerciseCount: i % 3,
            spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6
        ))
    }
    repo.days = sample
    repo.loaded = true

    return TodayView()
        .environmentObject(repo)
        .environmentObject(ProfileStore())
        .environmentObject(LiveHeartRate())
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif
