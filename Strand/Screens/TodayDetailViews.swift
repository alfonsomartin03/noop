import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// MARK: - Today detail pages
//
// Tapping Recovery, Sleep or Strain on Today opens one of these in place (the week strip stays above, so the
// picked day can change while reading). Everything is computed from stored data for that day; a number we cannot
// measure shows "—" with a plain note instead of an invented value.

enum TodayDetail: Hashable { case recovery, sleep, strain }

// MARK: Day helpers

enum DayMath {
    /// Unix-second span of a calendar day (yyyy-MM-dd) on the wearer's clock, in the zone in force that date
    /// (the same keying `Repository.dayString` uses; 23/25 h on DST days).
    static func range(_ day: String) -> (from: Int, to: Int)? { ZoneTimeline.shared.dayRange(day) }

    /// Last `count` values of a metric up to and including `day`, oldest first (days are sorted ascending).
    static func series(_ days: [DailyMetric], upTo day: String, count: Int = 14,
                       _ pick: (DailyMetric) -> Double?) -> [Double] {
        Array(days.filter { $0.day <= day }.compactMap(pick).suffix(count))
    }

    /// Mean of the previous `count` recorded values before `day`; nil with fewer than 3 points.
    static func baseline(_ days: [DailyMetric], before day: String, count: Int = 30,
                         _ pick: (DailyMetric) -> Double?) -> Double? {
        let v = Array(days.filter { $0.day < day }.compactMap(pick).suffix(count))
        return v.count >= 3 ? v.reduce(0, +) / Double(v.count) : nil
    }

    static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// Wall-clock time of `ts` in the zone the wearer was in then.
    static func clock(_ ts: Int) -> String { ZoneTimeline.shared.clock(ts) }
    /// Same, but in an explicit zone, so both ends of one night read on one clock.
    static func clock(_ ts: Int, in zone: TimeZone) -> String { ZoneTimeline.shared.clock(ts, in: zone) }
}

// MARK: One day of heart-rate samples, summarised

/// Everything derived from the strap's stored HR samples for one day. Each sample is credited with the time until the
/// next (gaps over a minute count as "strap not recording"), so coverage, zone time and energy are all consistent.
struct DayHRStats {
    let samples: [HRSample]
    let zoneSet: HRZoneSet
    let inZone: TimeInZone
    /// Seconds of the day actually covered by recorded heart rate.
    let coveredS: Double
    /// Time-weighted energy estimate over the recorded time (Keytel), nil when there is no data.
    let kcal: Double?

    @MainActor
    init(hr: [HRSample], profile: ProfileStore, restingHR: Int?) {
        let sorted = hr.sorted { $0.ts < $1.ts }
        samples = sorted
        zoneSet = HRZones.zones(age: Double(profile.age),
                                maxHROverride: profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil)
        inZone = HRZones.timeInZone(sorted, zoneSet: zoneSet)
        var covered = 0.0
        for i in 0..<sorted.count {
            covered += i + 1 < sorted.count ? min(Double(sorted[i + 1].ts - sorted[i].ts), 60) : 1
        }
        coveredS = covered
        if sorted.isEmpty {
            kcal = nil
        } else {
            let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                                 age: Double(profile.age), sex: profile.sex)
            kcal = Calories.estimateDayCalories(sorted, profile: up, hrmax: zoneSet.maxHR, restingHR: restingHR.map(Double.init))
        }
    }

    var isEmpty: Bool { samples.isEmpty }
    var low: HRSample? { samples.min { $0.bpm < $1.bpm } }
    var peak: HRSample? { samples.max { $0.bpm < $1.bpm } }
    var average: Int? { samples.isEmpty ? nil : samples.map(\.bpm).reduce(0, +) / samples.count }
    /// Minutes in Zone 2 or higher (moderate effort and up).
    var activeMin: Double { (2...5).reduce(0.0) { $0 + inZone.seconds(inZone: $1) } / 60 }
    /// Minutes in Zone 3 or higher (aerobic and up).
    var elevatedMin: Double { (3...5).reduce(0.0) { $0 + inZone.seconds(inZone: $1) } / 60 }
}

// MARK: Building blocks

/// Back button + title row at the top of a detail page.
struct DetailHeader: View {
    let title: String
    let tint: Color
    let back: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text("Today").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(StrandPalette.accentInk)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(StrandPalette.accentMuted, in: Capsule())
            }
            .buttonStyle(.plain)
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
            Circle().fill(tint).frame(width: 9, height: 9).shadow(color: tint.opacity(0.8), radius: 5)
            Spacer()
        }
    }
}

/// One metric tile: label, big value, optional comparison line and a small trend.
struct DetailTile: View {
    let title: String
    let value: String?
    var unit: String? = nil
    var caption: String? = nil
    var captionColor: Color = StrandPalette.textSecondary
    var tint: Color
    var spark: [Double]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
            WidgetValue(value, unit: unit, size: 28)
            if let caption {
                Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(captionColor).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let spark, spark.count > 1 { WidgetSpark(spark, tint: tint).frame(height: 26) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .strandSurface(cornerRadius: 18)
        .overlay(alignment: .topTrailing) {
            Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint.opacity(0.8), radius: 4).padding(14)
        }
    }
}

/// Responsive grid of `DetailTile`s.
struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: NoopMetrics.gap)], spacing: NoopMetrics.gap, content: content)
    }
}

/// "▲ 4 vs 30-day avg" style comparison against your own recent baseline.
private func versus(_ value: Double?, _ base: Double?, unit: String, decimals: Int = 0,
                    higherIsBetter: Bool?) -> (String, Color)? {
    guard let value, let base else { return nil }
    let d = value - base
    let tiny = abs(d) < pow(10, -Double(decimals)) / 2
    let text = tiny ? "In line with your 30-day average"
        : String(format: "%@ %.\(decimals)f %@ vs 30-day avg", d > 0 ? "▲" : "▼", abs(d), unit)
    guard let hib = higherIsBetter, !tiny else { return (text, StrandPalette.textSecondary) }
    return (text, (d > 0) == hib ? StrandPalette.statusPositiveInk : StrandPalette.statusWarningInk)
}

private struct HeroCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 28) { content() }
            .padding(NoopMetrics.cardPadding + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
    }
}

// MARK: - Recovery

struct RecoveryDetailView: View {
    let day: DailyMetric?
    let days: [DailyMetric]
    let official: Bool
    let back: () -> Void

    var body: some View {
        let d = day
        let score = d?.recovery
        let tint = score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
        let key = d?.day ?? ""
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            DetailHeader(title: "Recovery", tint: tint, back: back)
            HeroCard {
                ProgressRing(fraction: (score ?? 0) / 100, tint: tint, lineWidth: 16) {
                    VStack(spacing: 0) {
                        Text(score.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 46, weight: .bold).monospacedDigit())
                            .foregroundStyle(score == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        if score != nil { Text("%").font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary) }
                    }
                }
                .frame(width: 168, height: 168)
                VStack(alignment: .leading, spacing: 8) {
                    Text(score.map { StrandPalette.recoveryState($0).capitalized } ?? "No data")
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(tint)
                    Text(summary(d)).font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(official ? "WHOOP score" : "NOOP estimate · weighs HRV ~60%, resting HR ~20%, sleep ~15%, breathing ~5%")
                        .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DetailGrid {
                let hrv = versus(d?.avgHrv, DayMath.baseline(days, before: key) { $0.avgHrv }, unit: "ms", higherIsBetter: true)
                DetailTile(title: "Heart rate variability", value: d?.avgHrv.map { "\(Int($0.rounded()))" }, unit: "ms",
                         caption: hrv?.0, captionColor: hrv?.1 ?? StrandPalette.textSecondary, tint: StrandPalette.metricPurple,
                         spark: DayMath.series(days, upTo: key) { $0.avgHrv })
                let rhr = versus(d?.restingHr.map(Double.init), DayMath.baseline(days, before: key) { $0.restingHr.map(Double.init) },
                                 unit: "bpm", higherIsBetter: false)
                DetailTile(title: "Resting heart rate", value: d?.restingHr.map(String.init), unit: "bpm",
                         caption: rhr?.0, captionColor: rhr?.1 ?? StrandPalette.textSecondary, tint: StrandPalette.metricRose,
                         spark: DayMath.series(days, upTo: key) { $0.restingHr.map(Double.init) })
                let resp = versus(d?.respRateBpm, DayMath.baseline(days, before: key) { $0.respRateBpm }, unit: "br/min",
                                  decimals: 1, higherIsBetter: nil)
                DetailTile(title: "Respiratory rate", value: d?.respRateBpm.map { String(format: "%.1f", $0) }, unit: "br/min",
                         caption: resp?.0, tint: StrandPalette.accent,
                         spark: DayMath.series(days, upTo: key) { $0.respRateBpm })
                DetailTile(title: "Blood oxygen", value: d?.spo2Pct.map { String(format: "%.0f", $0) }, unit: "%",
                         caption: d?.spo2Pct == nil ? "Not reported for this night" : "Average during sleep",
                         tint: StrandPalette.metricCyan, spark: DayMath.series(days, upTo: key) { $0.spo2Pct })
                DetailTile(title: "Skin temperature", value: d?.skinTempDevC.map { String(format: "%+.1f", $0) }, unit: "°C",
                         caption: d?.skinTempDevC == nil ? "Not reported for this night" : "Deviation from your baseline",
                         tint: StrandPalette.metricAmber, spark: DayMath.series(days, upTo: key) { $0.skinTempDevC })
                DetailTile(title: "Sleep", value: d?.totalSleepMin.map { DayMath.hm($0) },
                         caption: d?.efficiency.map { String(format: "%.0f%% efficiency", $0) } ?? "No sleep recorded",
                         tint: StrandPalette.sleepLight, spark: DayMath.series(days, upTo: key) { $0.totalSleepMin })
            }
        }
    }

    private func summary(_ d: DailyMetric?) -> String {
        guard let d, let r = d.recovery else { return "No recovery score for this day yet. Wear the strap overnight or import your WHOOP export." }
        let lead = r >= 67 ? "Your body is well recovered" : r >= 34 ? "Recovery is moderate" : "Recovery is low"
        var tail = ""
        if let h = d.avgHrv, let b = DayMath.baseline(days, before: d.day, { $0.avgHrv }) {
            tail = h >= b ? ", with HRV at or above your norm." : ", with HRV below your norm."
        } else { tail = "." }
        return lead + tail
    }
}

// MARK: - Sleep

struct SleepDetailView: View {
    @EnvironmentObject var repo: Repository
    let day: DailyMetric?
    let days: [DailyMetric]
    let back: () -> Void

    @State private var sessions: [CachedSleepSession] = []
    @State private var need: SleepNeed.Summary?

    private var key: String { day?.day ?? "" }

    /// The longest session ending on this day (the night's main sleep), per recent day.
    private var nights: [CachedSleepSession] {
        var best: [String: CachedSleepSession] = [:]
        for s in sessions {
            let k = Repository.dayString(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            if let cur = best[k], cur.endTs - cur.startTs >= s.endTs - s.startTs { continue }
            best[k] = s
        }
        return best.keys.sorted().map { best[$0]! }
    }
    private var tonight: CachedSleepSession? {
        guard let r = DayMath.range(key) else { return nil }
        return SleepTimeline.pick(sessions, range: r, day: day)
    }
    /// Zone the shown night was slept in; every clock time of that night is read in it.
    private var nightZone: TimeZone {
        tonight.map { ZoneTimeline.shared.zone(forSpan: $0.startTs, $0.endTs) } ?? .autoupdatingCurrent
    }
    /// Real sleep onset / final wake as unix seconds (stage timeline), falling back to the session's bed / wake times.
    private var onsetWake: (onset: Int, wake: Int)? {
        guard let t = tonight else { return nil }
        if let tl = SleepTimeline.intervals(session: t, day: d0), !tl.estimated {
            let asleep = tl.intervals.filter { $0.stage != .awake }
            if let f = asleep.first, let l = asleep.last {
                return (t.startTs + Int(f.start), t.startTs + Int(l.end))
            }
        }
        return (t.startTs, t.endTs)
    }

    var body: some View {
        let d = day
        let asleep = d?.totalSleepMin
        let tint = StrandPalette.sleepLight
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            DetailHeader(title: "Sleep", tint: tint, back: back)
            HeroCard {
                ProgressRing(fraction: need.map { min(1, $0.asleepMin / max($0.needMin, 1)) } ?? 0, tint: tint, lineWidth: 16) {
                    VStack(spacing: 2) {
                        Text(asleep.map { DayMath.hm($0) } ?? "—")
                            .font(.system(size: 30, weight: .bold).monospacedDigit())
                            .foregroundStyle(asleep == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            .minimumScaleFactor(0.6).lineLimit(1)
                        Text("asleep").font(.system(size: 12, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(width: 168, height: 168)
                VStack(alignment: .leading, spacing: 10) {
                    if let n = need {
                        Text("\(Int((n.asleepMin / max(n.needMin, 1) * 100).rounded()))% of your sleep need")
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        Text(n.debtMin < 1 ? "You met your need of \(DayMath.hm(n.needMin))."
                                           : "Short by \(DayMath.hm(n.debtMin)) against a need of \(DayMath.hm(n.needMin)).")
                            .font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                        Text(n.isOfficial ? "WHOOP score" : "NOOP estimate: the larger of 7.5 h and your recent average")
                            .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        Text("No sleep recorded").font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
                    }
                    if d?.totalSleepMin != nil {
                        SleepStageBar(deep: d?.deepMin, rem: d?.remMin, light: d?.lightMin)
                    }
                }
            }
            nightTimeline
            DetailGrid {
                DetailTile(title: "Hours of sleep", value: asleep.map { DayMath.hm($0) },
                         caption: onsetWake.map { "Asleep \(DayMath.clock($0.onset, in: nightZone)) → \(DayMath.clock($0.wake, in: nightZone))" },
                         tint: tint, spark: DayMath.series(days, upTo: key) { $0.totalSleepMin })
                let c = consistency
                DetailTile(title: "Consistency", value: c.map { "\(Int($0.score.rounded()))" }, unit: c == nil ? nil : "%",
                         caption: c.map { "Bed ±\(Int($0.bedSD.rounded())) min · wake ±\(Int($0.wakeSD.rounded())) min" } ?? "Needs 3+ nights",
                         tint: StrandPalette.accent)
                DetailTile(title: "Efficiency", value: d?.efficiency.map { String(format: "%.0f", $0) }, unit: "%",
                         caption: "Time asleep while in bed", tint: StrandPalette.statusPositive,
                         spark: DayMath.series(days, upTo: key) { $0.efficiency })
                let rest = (d?.deepMin ?? 0) + (d?.remMin ?? 0)
                DetailTile(title: "Restorative sleep", value: d?.totalSleepMin == nil ? nil : DayMath.hm(rest),
                         caption: asleep.flatMap { $0 > 0 ? String(format: "%.0f%% of the night (deep + REM)", rest / $0 * 100) : nil },
                         tint: StrandPalette.sleepDeep)
                DetailTile(title: "Deep sleep", value: d?.deepMin.map { DayMath.hm($0) }, tint: StrandPalette.sleepDeep,
                         spark: DayMath.series(days, upTo: key) { $0.deepMin })
                DetailTile(title: "REM sleep", value: d?.remMin.map { DayMath.hm($0) }, tint: StrandPalette.sleepREM,
                         spark: DayMath.series(days, upTo: key) { $0.remMin })
                DetailTile(title: "Light sleep", value: d?.lightMin.map { DayMath.hm($0) }, tint: StrandPalette.sleepLight)
                DetailTile(title: "Disturbances", value: d?.disturbances.map(String.init),
                         caption: d?.disturbances == nil ? nil : "Times you woke during the night",
                         tint: StrandPalette.sleepAwake)
                DetailTile(title: "Resting HR & HRV", value: d?.restingHr.map { "\($0)" }, unit: "bpm",
                         caption: d?.avgHrv.map { "HRV \(Int($0.rounded())) ms during sleep" }, tint: StrandPalette.metricRose)
            }
            Text("Sleep stress isn't shown: it needs a stress model that NOOP doesn't have yet.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
        }
        .task(id: "\(key)-\(repo.dataVersion)") { await load() }
    }

    /// The night as a large stage-over-time graph: hover anywhere to read the stage and clock time, with when you fell
    /// asleep and woke up above it. Imported nights only hold stage totals, so their order is estimated and the
    /// asleep/awake times fall back to the session's bed and wake times.
    @ViewBuilder private var nightTimeline: some View {
        if let tl = SleepTimeline.intervals(session: tonight, day: d0) {
            let ivs = tl.intervals
            let asleepIvs = ivs.filter { $0.stage != .awake }
            let origin = tonight.map { TimeInterval($0.startTs) }
            let fell = tl.estimated ? 0 : asleepIvs.first?.start
            let woke = tl.estimated ? tonight.map { TimeInterval($0.endTs) - TimeInterval($0.startTs) } : asleepIvs.last?.end
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Night timeline").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("Move across the night to see the stage, minute by minute").font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                }
                HStack(spacing: NoopMetrics.gap) {
                    timeStat(tl.estimated ? "Bedtime" : "Fell asleep", clockAt(origin, fell), StrandPalette.sleepLight)
                    timeStat(tl.estimated ? "Wake time" : "Woke up", clockAt(origin, woke), StrandPalette.accent)
                    if let t = tonight { timeStat("Time in bed", DayMath.hm(Double(t.endTs - t.startTs) / 60), StrandPalette.sleepDeep) }
                }
                Hypnogram(intervals: ivs, height: 280, showsStageAxis: true,
                          nightStart: tonight.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) },
                          scrubsByMinute: true, showsTimeAxis: true, timeZone: nightZone)
                if tl.estimated {
                    Text("This night came from an import that only has stage totals, so the order of stages is estimated. Nights scored from your strap show the real timeline.")
                        .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
        }
    }

    private var d0: DailyMetric? { day }

    private func clockAt(_ origin: TimeInterval?, _ offset: TimeInterval?) -> String {
        guard let origin, let offset else { return "—" }
        return DayMath.clock(Int(origin + offset), in: nightZone)
    }

    private func timeStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// How steady bed and wake times are across the last 7 nights: 100% = identical, 0% = 2 h of spread or more.
    private var consistency: (score: Double, bedSD: Double, wakeSD: Double)? {
        let recent = nights.filter { Repository.dayString(Date(timeIntervalSince1970: TimeInterval($0.endTs))) <= key }.suffix(7)
        guard recent.count >= 3 else { return nil }
        func minutesIntoDay(_ ts: Int, shiftNoon: Bool) -> Double {
            let hm = ZoneTimeline.shared.hourMinute(ts)
            var m = Double(hm.hour * 60 + hm.minute)
            if shiftNoon { m = (m + 720).truncatingRemainder(dividingBy: 1440) }   // bedtimes wrap past midnight
            return m
        }
        func sd(_ v: [Double]) -> Double {
            let mean = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        let bed = sd(recent.map { minutesIntoDay($0.startTs, shiftNoon: true) })
        let wake = sd(recent.map { minutesIntoDay($0.endTs, shiftNoon: false) })
        return (max(0, 100 - (bed + wake) / 2 / 1.2), bed, wake)
    }

    private func load() async {
        guard let r = DayMath.range(key) else { return }
        // The merged list (WHOOP import plus the strap's own scored nights), so on-device nights have their real times.
        sessions = repo.sleeps.filter { $0.endTs >= r.from - 8 * 86_400 && $0.startTs <= r.to + 12 * 3_600 }
        let needMin = await repo.series(key: "sleep_need_min", source: repo.deviceId, days: 30).first { $0.day == key }?.value
        let debt = await repo.series(key: "sleep_debt_min", source: repo.deviceId, days: 30).first { $0.day == key }?.value
        let recent = days.filter { $0.day < key }.suffix(14).compactMap(\.totalSleepMin)
        need = SleepNeed.summarize(officialNeed: needMin, officialDebt: debt, asleep: day?.totalSleepMin, recentAsleep: recent)
    }
}

// MARK: - Strain

struct StrainDetailView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    let day: DailyMetric?
    let dayKey: String
    let days: [DailyMetric]
    let back: () -> Void

    @State private var cached: DayHRStats?
    @State private var workouts: [WorkoutRow] = []
    @State private var selectedWorkout: WorkoutSelection?
    @State private var steps: Int?
    @State private var activeKcal: Double?

    private static let strengthWords = ["strength", "weight", "lift", "functional", "crossfit", "gym", "resistance", "hiit"]

    /// Built once per load (it sorts a day of samples), not per render.
    private var stats: DayHRStats { cached ?? DayHRStats(hr: [], profile: profile, restingHR: nil) }
    private var zones: HRZoneSet { stats.zoneSet }
    private var inZone: TimeInZone { stats.inZone }
    private var strengthSeconds: Double {
        workouts.filter { w in Self.strengthWords.contains { w.sport.lowercased().contains($0) } }
            .reduce(0) { $0 + ($1.durationS ?? Double(max($1.endTs - $1.startTs, 0))) }
    }

    var body: some View {
        let v = day?.strain
        let tint = v.map { StrandPalette.strainColor($0) } ?? StrandPalette.strain033
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            DetailHeader(title: "Strain", tint: tint, back: back)
            HeroCard {
                ProgressRing(fraction: (v ?? 0) / 21, tint: tint, lineWidth: 16) {
                    VStack(spacing: 0) {
                        Text(v.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 46, weight: .bold).monospacedDigit())
                            .foregroundStyle(v == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        Text("of 21").font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(width: 168, height: 168)
                VStack(alignment: .leading, spacing: 8) {
                    Text(v.map(word) ?? "No data").font(.system(size: 28, weight: .bold)).foregroundStyle(tint)
                    Text(v == nil ? "No strain recorded for this day yet."
                                  : "Cardiovascular load from your heart rate across the day, on a 0–21 scale.")
                        .font(.system(size: 14)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            zoneCard

            DetailGrid {
                let st = stats
                DetailTile(title: "Active time", value: st.isEmpty ? nil : DayMath.hm(st.activeMin),
                           caption: st.isEmpty ? "No heart-rate data for this day" : "Zone 2 or higher, from your strap",
                           tint: StrandPalette.statusPositive)
                DetailTile(title: "Energy burned", value: st.kcal.map { "\(Int($0.rounded()))" }, unit: "kcal",
                           caption: st.isEmpty ? nil : "Estimated from heart rate over \(DayMath.hm(st.coveredS / 60)) recorded",
                           tint: StrandPalette.metricAmber)
                DetailTile(title: "Average heart rate", value: st.average.map(String.init), unit: "bpm",
                           caption: st.low.map { "Low \($0.bpm) at \(DayMath.clock($0.ts))" }, tint: StrandPalette.metricRose)
                DetailTile(title: "Peak heart rate", value: st.peak.map { "\($0.bpm)" }, unit: "bpm",
                           caption: st.peak.map { "At \(DayMath.clock($0.ts)) · \(Int((Double($0.bpm) / max(zones.maxHR, 1) * 100).rounded()))% of max" },
                           tint: StrandPalette.statusCritical)
                DetailTile(title: "Workouts", value: "\(workouts.count)",
                           caption: workouts.isEmpty ? "None detected or logged" : DayMath.hm(workouts.reduce(0) { $0 + ($1.durationS ?? 0) } / 60) + " total",
                           tint: StrandPalette.strain033)
                if strengthSeconds > 0 {
                    DetailTile(title: "Strength time", value: DayMath.hm(strengthSeconds / 60),
                               caption: "Weights, gym and functional sessions", tint: StrandPalette.strain066)
                }
                if let steps {
                    DetailTile(title: "Steps", value: steps.formatted(), caption: "From Apple Health", tint: StrandPalette.statusPositive)
                }
                if let activeKcal {
                    DetailTile(title: "Active energy (Apple)", value: "\(Int(activeKcal.rounded()))", unit: "kcal",
                               caption: "From Apple Health", tint: StrandPalette.metricAmber)
                }
            }

            if !workouts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workouts").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                    ForEach(Array(workouts.enumerated()), id: \.offset) { _, w in
                        Button { selectedWorkout = WorkoutSelection(row: w) } label: { workoutRow(w).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: "\(dayKey)-\(repo.dataVersion)") { await load() }
        .sheet(item: $selectedWorkout) { WorkoutDetailView(workout: $0.row) }
    }

    private var zoneCard: some View {
        let t = inZone
        let top = max(t.seconds.max() ?? 0, t.belowZone1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Time in heart-rate zones").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(stats.isEmpty ? "No heart-rate data for this day" : "Max HR \(Int(zones.maxHR.rounded())) bpm")
                    .font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
            }
            // Zone 0 is everything below Zone 1 (resting and light movement), so it needs no footnote.
            ForEach((0...5).reversed(), id: \.self) { z in
                let secs = z == 0 ? t.belowZone1 : t.seconds(inZone: z)
                let color = z == 0 ? StrandPalette.textTertiary : StrandPalette.hrZoneColor(z)
                let range = z == 0 ? "<\(Int(zones.zones[0].lower.rounded()))"
                                   : "\(Int(zones.zones[z - 1].lower.rounded()))–\(Int(zones.zones[z - 1].upper.rounded()))"
                HStack(spacing: 12) {
                    Text("Zone \(z)").font(.system(size: 12, weight: .bold)).foregroundStyle(color).frame(width: 52, alignment: .leading)
                    Text(range).font(.system(size: 11).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary).frame(width: 58, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(StrandPalette.surfaceInset)
                            Capsule().fill(color)
                                .frame(width: secs > 0 ? max(8, g.size.width * secs / top) : 0)
                                .shadow(color: color.opacity(z == 0 ? 0 : 0.6), radius: 5)
                        }
                    }
                    .frame(height: 12)
                    Text(DayMath.hm(secs / 60)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary).frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface()
    }

    private func workoutRow(_ w: WorkoutRow) -> some View {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        return HStack(spacing: 14) {
            Image(systemName: "figure.run").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.strainColor(w.strain ?? 8)).frame(width: 30, height: 30)
                .background(StrandPalette.strainColor(w.strain ?? 8).opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(w.sport).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text("\(DayMath.clock(w.startTs)) · \(DayMath.hm(secs / 60))" + (w.avgHr.map { " · avg \($0) bpm" } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            if let s = w.strain {
                Text(String(format: "%.1f", s)).font(.system(size: 18, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.strainColor(s))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface(cornerRadius: 16)
    }

    private func word(_ v: Double) -> String {
        switch v {
        case ..<6:  return "Light load"
        case ..<10: return "Moderate load"
        case ..<14: return "Strenuous"
        default:    return "All out"
        }
    }

    private func load() async {
        guard let r = DayMath.range(dayKey) else { return }
        let samples = await repo.hrSamples(from: r.from, to: r.to, limit: 200_000)
        cached = DayHRStats(hr: samples, profile: profile, restingHR: day?.restingHr)
        workouts = await repo.workoutRows().filter { $0.startTs >= r.from && $0.startTs < r.to }.sorted { $0.startTs < $1.startTs }
        let apple = await repo.appleDailyRows().first { $0.day == dayKey }
        steps = apple?.steps
        activeKcal = apple?.activeKcal
    }
}
