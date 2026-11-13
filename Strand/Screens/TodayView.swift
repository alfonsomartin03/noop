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
    /// Newest stored HR anywhere (how far synced data reaches), for the coverage caption.
    @State private var syncedThrough: Int?
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
                NextAlarmLink()
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
                    CheckInCard()
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
            HeartRateDayCard(day: activeDay, metric: d, days: repo.days, stats: dayStats, syncedThrough: syncedThrough,
                             importedSummary: repo.isOfficial(activeDay)) { navigate(.live) }
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
                    if let tl = SleepTimeline.intervals(session: night) {
                        // The same stage-over-the-night staircase as the Sleep tab (genuine timestamped stages only).
                        Hypnogram(intervals: tl, height: 84, showsStageAxis: false,
                                  nightStart: night.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) },
                                  timeZone: night.map { ZoneTimeline.shared.zone(forSpan: $0.startTs, $0.endTs) } ?? .autoupdatingCurrent)
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
            syncedThrough = await repo.latestHRTimestamp()
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
struct ConnectionStrip: View {
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

/// Sync status while the strap offloads stored data, then while NOOP processes it: one quiet line and a hairline bar.
/// Progress is measured in strap time (how much of the strap's unsent history is saved), never in bytes or rows,
/// and reaches 100 % only after the strap confirmed the transfer complete.
private struct SyncProgressStrip: View {
    @EnvironmentObject var live: LiveState

    var body: some View {
        Group {
            if live.historyBusy {
                downloading
            } else if let status = live.processingStatus {
                row(title: "Processing", detail: status, trailing: nil, fraction: nil)
            } else if let outcome = live.lastSyncOutcome {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                    Text("Sync incomplete").font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(outcome).font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1).truncationMode(.tail).help(outcome)
                    Spacer(minLength: 8)
                    Button("Dismiss") { live.lastSyncOutcome = nil }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .strandSurface(cornerRadius: NoopMetrics.controlRadius)
            }
        }
        .animation(StrandMotion.respecting(StrandMotion.gentle), value: live.historyBusy)
    }

    @ViewBuilder private var downloading: some View {
        if let s = live.syncSession, s.target > s.strapFrom {
            let total = s.target - s.strapFrom
            row(title: "Syncing",
                detail: "\(SyncFormat.duration(s.remainingSeconds)) left of \(SyncFormat.duration(total))",
                trailing: "\(Int((s.fraction * 100).rounded(.down)))%",
                fraction: s.fraction)
        } else {
            // Before the strap reports its range (or if it never does) there is no honest percentage.
            row(title: "Syncing", detail: live.historyStatus,
                trailing: live.syncSavedRows > 0 ? "\(live.syncSavedRows.formatted()) saved" : nil, fraction: nil)
        }
    }

    /// Title · detail ……… trailing, over a 3 pt bar (determinate when `fraction` is known).
    private func row(title: String, detail: String, trailing: String?, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            ThinProgressBar(fraction: fraction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .strandSurface(cornerRadius: NoopMetrics.controlRadius)
        .accessibilityElement(children: .combine)
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "In progress")
    }
}

/// A 3 pt capsule bar. With a fraction it fills to that value; without one a short segment drifts across
/// (a static partial fill under Reduce Motion).
private struct ThinProgressBar: View {
    var fraction: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                if let fraction {
                    Capsule().fill(StrandPalette.accent)
                        .frame(width: max(3, w * min(1, max(0, fraction))))
                        .animation(StrandMotion.respecting(.easeOut(duration: 0.4)), value: fraction)
                } else {
                    let seg = w * 0.28
                    Capsule().fill(StrandPalette.accent.opacity(0.85))
                        .frame(width: seg)
                        .offset(x: StrandMotion.reduceMotion ? 0 : (sweep ? w - seg : 0))
                        .onAppear {
                            guard !StrandMotion.reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
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

/// Heart rate for the picked day: a primary number (live or the day's average), Low/Average/Peak, a few quieter
/// insights, and the day's curve with its activation strip on one shared time axis (issue #26).
struct HeartRateDayCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    let day: String
    let metric: DailyMetric?
    let days: [DailyMetric]
    let stats: DayHRStats?
    var syncedThrough: Int? = nil
    var importedSummary = false
    let openLive: () -> Void
    /// Render fixtures only: a fixed clock and activation instead of the live clock and a store load.
    var fixtureNow: Date? = nil
    var fixtureActivation: ActivationAvailability? = nil

    @State private var activation: ActivationAvailability = .loading

    private var isToday: Bool { day == Repository.dayString(fixtureNow ?? Date()) }

    var body: some View {
        StrandWidget("Heart rate", symbol: "heart.fill", tint: StrandPalette.metricRose, trailing: isToday ? "Live" : nil, action: openLive) {
            // Re-evaluated each minute so "recorded so far", the now line and upcoming time follow the clock on today.
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let now = fixtureNow ?? ctx.date
                let cov = coverage(now: now)
                SummaryChartLayout {
                    summary(cov)
                    chartColumn(now: now, cov: cov)
                }
            }
        }
        .task(id: "\(day)-\(repo.dataVersion)-\(profile.hrMax)") {
            if let fixtureActivation { activation = fixtureActivation; return }
            activation = .loading
            if let l = await ActivationLoad.load(repo: repo, maxHR: profile.hrMax, day: day) {
                activation = .ready(l.bins)
            } else {
                activation = .unavailable
            }
        }
    }

    /// Coverage of the picked day: its real length (DST included) clipped to now, against the supported intervals.
    private func coverage(now: Date) -> DayCoverage? {
        guard let r = DayMath.range(day) else { return nil }
        return DayCoverage.compute(dayStart: r.from, dayEnd: r.to, now: Int(now.timeIntervalSince1970),
                                   intervals: stats?.supportedIntervals ?? [], syncedThrough: syncedThrough,
                                   hasImportedSummary: importedSummary && (stats?.isEmpty ?? true))
    }

    // MARK: Chart column

    @ViewBuilder private func chartColumn(now: Date, cov: DayCoverage?) -> some View {
        if let r = DayMath.range(day) {
            let axis = DayTimeAxis(start: r.from, end: r.to, now: Int(now.timeIntervalSince1970))
            let runs = axis.hrRuns((stats?.samples ?? []).map { (ts: $0.ts, bpm: $0.bpm) })
            VStack(alignment: .leading, spacing: 10) {
                HeartRateDayTimeline(axis: axis, runs: runs, activation: activation,
                                     dayName: isToday ? "today" : HighlightsContent.long(day))
                activationKey(axis)
            }
        }
    }

    /// Latest state and the legend for every colour in the strip. What activation is (not a stress score) is on the
    /// legend's hover help and VoiceOver hint, and in full on the Health page.
    private func activationKey(_ axis: DayTimeAxis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Activation").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                if case .ready(let bins) = activation, let last = HRActivation.latest(bins) {
                    let kind = DayTimeAxis.SpanKind.observed(last.level)
                    Text("·").foregroundStyle(StrandPalette.textTertiary)
                    Text("Latest \(last.level.label.lowercased()), \(ZoneTimeline.shared.clock(last.start))–\(ZoneTimeline.shared.clock(last.end))")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityLabel("Latest activation: \(last.level.label), \(ActivationStyle.interval(DayTimeAxis.Span(start: last.start, end: last.end, kind: kind)))")
                }
                Spacer(minLength: 0)
            }
            if case .unavailable = activation {
                Text("Activation appears once NOOP has scored a night and knows your resting heart rate.")
                    .font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                ActivationLegend(showsUpcoming: axis.hasUpcoming)
                    .help(Self.activationCaveat)
                    .accessibilityHint(Self.activationCaveat)
            }
        }
    }

    static let activationCaveat = "Heart rate against your resting and max, in 15-min blocks. Movement, heat, caffeine and illness raise it too, so high activation isn't proof of stress — not a stress score."

    // MARK: Summary

    private func summary(_ cov: DayCoverage?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if isToday {
                LiveHeadline(average: stats?.average)
            } else {
                Headline(label: "Average", value: stats?.average, tint: StrandPalette.textPrimary)
            }
            metricGroup
            let items = insights(cov)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items) { ins in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: ins.icon).font(.system(size: 10, weight: .bold))
                                .foregroundStyle(ins.tint)
                                .frame(width: 22, height: 22)
                                .background(ins.tint.opacity(0.16), in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                (Text(ins.lead).foregroundColor(StrandPalette.textSecondary)
                                 + Text(ins.value).foregroundColor(ins.tint).fontWeight(.semibold)
                                 + Text(ins.tail).foregroundColor(StrandPalette.textSecondary))
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let d = ins.detail {
                                    Text(d).font(.system(size: 10.5)).foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 3)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The primary number: a small explicit label, then the value with its unit on the same baseline.
    private struct Headline: View {
        let label: String
        let value: Int?
        let tint: Color
        var live = false
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if live { Circle().fill(StrandPalette.metricRose).frame(width: 6, height: 6) }
                    Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(live ? StrandPalette.metricRose : StrandPalette.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value.map(String.init) ?? "—").font(StrandFont.number(48, weight: .bold))
                        .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                    if value != nil {
                        Text("bpm").font(.system(size: 15, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.map { "\(label) heart rate, \($0) beats per minute" } ?? "\(label) heart rate unavailable")
        }
    }

    /// Today's headline: the live number while one is streaming, else the day's average. The only part of the card that
    /// follows the live feed, so a new beat redraws this text and not the chart or insights.
    private struct LiveHeadline: View {
        @EnvironmentObject var heart: LiveHeartRate
        let average: Int?
        var body: some View {
            if let bpm = heart.bpm {
                Headline(label: "Live", value: bpm, tint: StrandPalette.metricRose, live: true)
            } else {
                Headline(label: "Average so far", value: average, tint: StrandPalette.textPrimary)
            }
        }
    }

    /// Low / Average / Peak as one quiet row: label above, value with unit, time below where there is one.
    @ViewBuilder private var metricGroup: some View {
        if let s = stats, !s.isEmpty, let lo = s.low, let hi = s.peak {
            HStack(alignment: .top, spacing: 0) {
                metric("Low", lo.bpm, at: lo.ts, tint: StrandPalette.metricCyan)
                Rectangle().fill(StrandPalette.hairline).frame(width: 1).padding(.vertical, 2)
                metric("Average", s.average, at: nil, tint: StrandPalette.textPrimary)
                Rectangle().fill(StrandPalette.hairline).frame(width: 1).padding(.vertical, 2)
                metric("Peak", hi.bpm, at: hi.ts, tint: StrandPalette.statusCriticalInk)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ label: String, _ value: Int?, at ts: Int?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(String.init) ?? "—").font(StrandFont.number(18, weight: .semibold)).foregroundStyle(tint)
                Text("bpm").font(.system(size: 10, weight: .medium)).foregroundStyle(StrandPalette.textTertiary)
            }
            Text(ts.map { DayMath.clock($0) } ?? " ").font(.system(size: 10).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, label == "Low" ? 0 : 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value.map { "\($0) beats per minute" } ?? "unavailable")\(ts.map { ", at \(DayMath.clock($0))" } ?? "")")
    }

    // MARK: Insights

    /// One supporting line: a tinted badge, then text whose key number carries the same tint.
    private struct Insight: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        var lead = ""
        let value: String
        var tail = ""
        var detail: String? = nil
    }

    private func insights(_ cov: DayCoverage?) -> [Insight] {
        var out: [Insight] = []
        if let rhr = metric?.restingHr {
            if let base = DayMath.baseline(days, before: day, { $0.restingHr.map(Double.init) }) {
                let d = Double(rhr) - base
                let rel = abs(d) < 1 ? ", in line with your 30-day average"
                    : ", \(Int(abs(d).rounded())) bpm \(d < 0 ? "below" : "above") your 30-day average"
                out.append(Insight(icon: "moon.zzz.fill", tint: StrandPalette.lavenderInk, lead: "Resting ", value: "\(rhr) bpm", tail: rel + "."))
            } else {
                out.append(Insight(icon: "moon.zzz.fill", tint: StrandPalette.lavenderInk, lead: "Resting ", value: "\(rhr) bpm", tail: "."))
            }
        }
        if let s = stats, !s.isEmpty {
            if let hi = s.peak {
                let pct = Int((Double(hi.bpm) / max(s.zoneSet.maxHR, 1) * 100).rounded())
                out.append(Insight(icon: "bolt.heart.fill", tint: StrandPalette.statusCriticalInk,
                                   lead: "Peak reached ", value: "\(pct) %", tail: " of your max (\(Int(s.zoneSet.maxHR.rounded())) bpm) at \(DayMath.clock(hi.ts))."))
            }
            out.append(s.elevatedMin >= 1
                ? Insight(icon: "flame.fill", tint: StrandPalette.statusWarningInk, lead: "", value: DayMath.hm(s.elevatedMin), tail: " in Zone 3 or higher.")
                : Insight(icon: "flame.fill", tint: StrandPalette.statusWarningInk, lead: "", value: "No time", tail: " in Zone 3 or higher."))
        }
        if case .ready(let bins) = activation, let high = HRActivation.totals(bins)[.high], high >= 15 * 60 {
            out.append(Insight(icon: "waveform.path.ecg", tint: StrandPalette.statusCriticalInk,
                               lead: "High activation for ", value: DayMath.hm(Double(high) / 60), tail: " outside workouts."))
        }
        if let s = stats, let kcal = s.kcal, kcal >= 1 {
            out.append(Insight(icon: "bolt.fill", tint: StrandPalette.accentInk,
                               lead: "About ", value: "\(Int(kcal.rounded()).formatted()) kcal", tail: " burned over recorded time (heart-rate estimate)."))
        }
        // Coverage: neutral wording; a warning only for meaningful missing elapsed time (not the normal sync delay).
        if let cov, !cov.isFuture {
            let warn = cov.warrantsWarning
            let details = cov.details(clock: DayMath.clock)
            out.append(Insight(icon: warn ? "exclamationmark.circle.fill" : "clock.fill",
                               tint: warn ? StrandPalette.statusWarningInk : StrandPalette.textSecondary,
                               value: cov.caption(), detail: details.isEmpty ? nil : details.joined(separator: " ")))
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
