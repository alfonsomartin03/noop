import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol
import Foundation

// MARK: - Today — the home dashboard
//
// A calm grid of widgets: recovery (hero), sleep, strain, live heart rate, then the supporting
// vitals. Each widget shows one primary number; tapping opens the detailed screen. Everything
// else (workouts, other sources) sits below or behind a disclosure. Data loading is unchanged.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @Environment(\.navigate) private var navigate

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State private var sparks: [String: [Double]] = [:]
    @State private var workouts: [WorkoutRow] = []

    var body: some View {
        ScreenScaffold(title: greetingWord, subtitle: dateLine) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                PairingResetNotice()
                ConnectionStrip()
                if repo.today?.recovery == nil {
                    StrandNotice(
                        symbol: "sparkles",
                        title: "Your scores are building",
                        message: "Live heart rate works from the strap right away. Recovery, strain and sleep build over your next few nights of wear. To see your history now, import your WHOOP export under Import & Export."
                    )
                }
                dashboard
                activitySection
            }
        }
        .task(id: "\(repo.today?.day ?? "")-\(repo.dataVersion)") { await loadAll() }
    }

    // MARK: Widgets

    @ViewBuilder
    private var dashboard: some View {
        let d = repo.today
        WidgetGrid(minColumn: 190) {
            recoveryWidget(d)
            sleepWidget(d)

            StrandWidget("Strain", symbol: "flame.fill", tint: StrandPalette.strain033,
                         action: { navigate(.workouts) }) {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetValue(d?.strain.map { String(format: "%.1f", $0) }, unit: "/ 21")
                    Spacer(minLength: 0)
                    meter(d?.strain.map { $0 / 21 } ?? 0, tint: d?.strain.map { StrandPalette.strainColor($0) } ?? StrandPalette.strain033)
                    WidgetCaption(d?.strain.map { strainWord($0) } ?? "No data yet")
                }
            }

            LiveHeartRateWidget(version: repo.dataVersion) { navigate(.live) }

            metricWidget("HRV", "waveform.path.ecg", StrandPalette.metricPurple,
                         value: d?.avgHrv.map { "\(Int($0.rounded()))" }, unit: "ms",
                         series: sparks["hrv"], to: .health)
            metricWidget("Resting heart rate", "heart.fill", StrandPalette.metricRose,
                         value: d?.restingHr.map { "\($0)" }, unit: "bpm",
                         series: sparks["rhr"], to: .health)
            metricWidget("Respiratory rate", "lungs.fill", StrandPalette.accent,
                         value: d?.respRateBpm.map { String(format: "%.1f", $0) } ?? latestOptional("resp_rate", decimals: 1),
                         unit: "br/min", series: sparks["resp_rate"], to: .health)
            metricWidget("Blood oxygen", "drop.fill", StrandPalette.metricCyan,
                         value: d?.spo2Pct.map { String(format: "%.0f", $0) }, unit: "%",
                         series: sparks["spo2"], to: .health)

            StrandWidget("Skin temperature", symbol: "thermometer.medium", tint: StrandPalette.metricAmber,
                         action: { navigate(.health) }) {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetValue(d?.skinTempDevC.map { String(format: "%+.1f", $0) }, unit: "°C")
                    Spacer(minLength: 0)
                    WidgetCaption(d?.skinTempDevC == nil ? "No data yet" : "Compared with your baseline")
                }
            }

            BatteryWidget { navigate(.live) }

        }
        .redacted(reason: repo.loaded ? [] : .placeholder)
    }

    private func recoveryWidget(_ d: DailyMetric?) -> some View {
        let score = d?.recovery
        let tint = score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
        return StrandWidget("Recovery", symbol: "circle.dotted.circle", tint: tint, size: .large,
                            action: { navigate(.trends) }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 20) {
                    ProgressRing(fraction: (score ?? 0) / 100, tint: tint, lineWidth: 14) {
                        VStack(spacing: 0) {
                            Text(score.map { "\(Int($0.rounded()))" } ?? "—")
                                .font(.system(size: 40, weight: .semibold).monospacedDigit())
                                .foregroundStyle(score == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            if score != nil {
                                Text("%").font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                    .frame(width: 132, height: 132)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(synthesisWord(score))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(synthesisDetail(d))
                            .font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                WidgetSpark(sparks["recovery"] ?? [], tint: tint).frame(height: 44)
                Text(scoreSourceLine(d)).font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// One plain line saying where today's scores come from.
    private func scoreSourceLine(_ d: DailyMetric?) -> String {
        guard let d else { return "Last 14 days" }
        return repo.isOfficial(d.day) ? "WHOOP score · last 14 days" : "NOOP estimate · last 14 days"
    }

    private func sleepWidget(_ d: DailyMetric?) -> some View {
        StrandWidget("Sleep", symbol: "bed.double.fill", tint: StrandPalette.sleepLight, size: .medium,
                     action: { navigate(.sleep) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetValue(d?.totalSleepMin == nil ? nil : sleepValue(d))
                    Spacer()
                    if let eff = d?.efficiency {
                        Text(String(format: "%.0f%% efficiency", eff))
                            .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if d?.totalSleepMin != nil {
                    SleepStageBar(deep: d?.deepMin, rem: d?.remMin, light: d?.lightMin)
                } else {
                    WidgetCaption("No sleep recorded yet")
                }
            }
        }
    }

    private func metricWidget(_ title: String, _ symbol: String, _ tint: Color, value: String?, unit: String?,
                              series: [Double]?, to destination: NavItem) -> some View {
        StrandWidget(title, symbol: symbol, tint: tint, action: { navigate(destination) }) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetValue(value, unit: unit)
                Spacer(minLength: 0)
                if value == nil { WidgetCaption("No data yet") }
                else { WidgetSpark(series ?? [], tint: tint).frame(height: 36) }
            }
        }
    }

    private func meter(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.16))
                Capsule().fill(tint).frame(width: max(6, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }

    private func strainWord(_ v: Double) -> String {
        switch v {
        case ..<6:  return "Light load"
        case ..<10: return "Moderate load"
        case ..<14: return "Strenuous"
        default:    return "All out"
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activitySection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Activity", trailing: workouts.isEmpty ? nil : "\(workouts.count) workouts")
                WidgetGrid(minColumn: 190) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StrandWidget(w.sport, symbol: "figure.run", tint: StrandPalette.strainColor(w.strain ?? 8),
                                     action: { navigate(.workouts) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                WidgetValue(workoutDuration(w))
                                Spacer(minLength: 0)
                                WidgetCaption(workoutCaption(w))
                                if let kcal = w.energyKcal { WidgetCaption("\(Int(kcal.rounded())) kcal") }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Latest value of a loaded series as a display string, or nil when there is none.
    private func latestOptional(_ key: String, decimals: Int) -> String? {
        guard let last = sparks[key]?.last else { return nil }
        return decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
    }

    // MARK: - Loading

    private func loadAll() async {
        // 14-day sparklines — Whoop.
        sparks["recovery"]        = await sparkValues("recovery", source: "my-whoop", window: 14)
        sparks["strain"]          = await sparkValues("strain", source: "my-whoop", window: 14)
        sparks["sleep_total_min"] = await sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        sparks["hrv"]             = await sparkValues("hrv", source: "my-whoop", window: 14)
        sparks["rhr"]             = await sparkValues("rhr", source: "my-whoop", window: 14)
        sparks["spo2"]            = await sparkValues("spo2", source: "my-whoop", window: 14)

        sparks["resp_rate"] = await sparkValues("resp_rate", source: "my-whoop", window: 14)

        workouts = await repo.workoutRows()
    }

    /// Trailing-window values for a metric, with the sparse-data fallback:
    /// if the trailing window has <2 points, fall back to ALL history so sparse
    /// series (weight) still render a value + line instead of an empty state.
    private func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        let all = await repo.series(key: key, source: source)   // full history, asc
        guard !all.isEmpty else { return [] }
        let windowed = trailingWindow(all, days: window)
        let chosen = windowed.count >= 2 ? windowed : all
        return chosen.map { $0.value }
    }

    /// Keep only points within `days` of the most recent point (parsing yyyy-MM-dd in UTC).
    private func trailingWindow(_ points: [(day: String, value: Double)], days: Int) -> [(day: String, value: Double)] {
        guard let lastDay = points.last?.day, let lastDate = Self.dayParser.date(from: lastDay) else { return points }
        let cutoff = lastDate.addingTimeInterval(-Double(days) * 86_400)
        return points.filter { p in
            guard let dt = Self.dayParser.date(from: p.day) else { return false }
            return dt >= cutoff
        }
    }

    /// Latest value of a loaded sparkline series, formatted — for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    private func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
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
        if let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return f.string(from: date)
        }
        return f.string(from: Date())
    }

    /// A short recovery state word for the synthesis hero.
    private func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return "No Data" }
        switch s {
        case ..<25:  return "Depleted"
        case ..<50:  return "Low"
        case ..<70:  return "Steady"
        case ..<88:  return "Primed"
        default:     return "Peak"
        }
    }

    /// Plain-English synthesis of recovery + sleep.
    private func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return "No metrics yet. Import your Whoop export or wear the strap to begin."
        }
        let recPart: String
        switch rec {
        case ..<50:  recPart = "Recovery is low"
        case ..<70:  recPart = "Recovery is steady"
        default:     recPart = "Recovery is strong"
        }
        let sleepPart: String
        if let mins = d.totalSleepMin {
            let h = mins / 60.0
            sleepPart = h >= 7 ? " and sleep was consistent" : " but sleep ran short"
        } else {
            sleepPart = ""
        }
        return recPart + sleepPart + "."
    }

    private func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "— ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return "HRV \(hrv) · RHR \(rhr)"
    }

    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }


    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    private func workoutCaption(_ w: WorkoutRow) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        let date = f.string(from: Date(timeIntervalSince1970: TimeInterval(w.startTs)))
        if let hr = w.avgHr { return "\(date) · \(hr) bpm" }
        return date
    }

    /// Thousands-grouped integer string (steps / calories).
    private func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }

    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, UTC)

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Live widgets (isolated so the ~1 Hz stream only re-renders these small views)

/// Shown only when the strap is not connected: a single quiet line with a Connect action.
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

private struct LiveHeartRateWidget: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    let version: Int
    let open: () -> Void
    @State private var today: [HRSample] = []

    private var latest: HRSample? { today.last }
    var body: some View {
        StrandWidget("Heart rate", symbol: "heart.fill", tint: StrandPalette.metricRose, size: .medium, action: open) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetValue((model.bpm ?? latest?.bpm).map(String.init), unit: "bpm")
                Spacer(minLength: 0)
                WidgetSpark(today.map { Double($0.bpm) }, tint: StrandPalette.metricRose).frame(height: 36)
                WidgetCaption(caption)
            }
        }
        .task(id: version) { today = Self.downsample(await repo.todayHeartRate(), to: 240) }
    }

    private var caption: String {
        if model.bpm != nil { return "Live from your strap" }
        guard let latest, !today.isEmpty else { return live.phase.title }
        let bpms = today.map(\.bpm)
        let t = Date(timeIntervalSince1970: TimeInterval(latest.ts)).formatted(date: .omitted, time: .shortened)
        return "Today \(bpms.min()!)–\(bpms.max()!) · avg \(bpms.reduce(0, +) / bpms.count) · last \(t)"
    }

    private static func downsample(_ s: [HRSample], to n: Int) -> [HRSample] {
        guard s.count > n else { return s }
        let step = Double(s.count) / Double(n)
        return (0..<n).map { s[Int(Double($0) * step)] }
    }
}

private struct BatteryWidget: View {
    @EnvironmentObject var live: LiveState
    let open: () -> Void
    private var pct: Int? { live.batteryPct.map { Int($0.rounded()) } }
    private var symbol: String {
        guard let p = pct else { return "battery.0percent" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }
    private var tint: Color { (pct ?? 100) < 20 ? StrandPalette.statusCritical : StrandPalette.statusPositive }
    var body: some View {
        StrandWidget("Strap battery", symbol: symbol, tint: tint, action: open) {
            VStack(alignment: .leading, spacing: 4) {
                WidgetValue(pct.map(String.init), unit: "%")
                Spacer(minLength: 0)
                WidgetCaption(live.connected ? (live.bonded ? "Connected" : "Connecting…") : "Not connected")
            }
        }
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
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif
