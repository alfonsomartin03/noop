import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol
import Foundation

// MARK: - Sleep stages for the Today card

/// Turns a night into hypnogram intervals. The on-device scorer stores a real per-epoch timeline (a JSON array of
/// {start,end,stage}). WHOOP imports only hold stage totals, so for those the same plausible stage order the Sleep tab
/// uses is drawn and flagged `estimated`.
enum SleepTimeline {
    private struct Segment: Decodable { let start: Int; let end: Int; let stage: String }

    /// The session that belongs to a day. Imports key a day by the cycle that started on it (the night often ends the
    /// next morning), the strap's own scoring keys it by the morning the night ended, so look in both places and take the
    /// candidate whose length best matches the day's recorded sleep.
    static func pick(_ sessions: [CachedSleepSession], range r: (from: Int, to: Int), day: DailyMetric?) -> CachedSleepSession? {
        let cands = sessions.filter { $0.endTs >= r.from && $0.endTs < r.to + 14 * 3600 && $0.startTs >= r.from - 14 * 3600 }
        guard !cands.isEmpty else { return nil }
        let target = day?.totalSleepMin
        return cands.min { a, b in
            func score(_ s: CachedSleepSession) -> Double {
                let mins = Double(s.endTs - s.startTs) / 60
                let endsOnDay = s.endTs >= r.from && s.endTs < r.to
                return abs(mins - (target ?? 480)) - (endsOnDay ? 30 : 0)
            }
            return score(a) < score(b)
        }
    }

    static func intervals(session: CachedSleepSession?, day: DailyMetric?) -> (intervals: [SleepInterval], estimated: Bool)? {
        if let session, let data = session.stagesJSON?.data(using: .utf8),
           let segs = try? JSONDecoder().decode([Segment].self, from: data), !segs.isEmpty {
            let origin = TimeInterval(session.startTs)
            let out: [SleepInterval] = segs.sorted { $0.start < $1.start }.compactMap { s in
                let stage: SleepStage
                switch s.stage {
                case "wake": stage = .awake
                case "light": stage = .light
                case "deep": stage = .deep
                case "rem": stage = .rem
                default: return nil
                }
                return SleepInterval(stage: stage, start: TimeInterval(s.start) - origin, end: TimeInterval(s.end) - origin)
            }
            if !out.isEmpty { return (out, false) }
        }
        // Stage totals in minutes: the session's JSON dict if present, else the day's columns.
        var light = day?.lightMin ?? 0, deep = day?.deepMin ?? 0, rem = day?.remMin ?? 0, awake = 0.0
        if let data = session?.stagesJSON?.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            func v(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
            if v("light") + v("deep") + v("rem") > 0 { light = v("light"); deep = v("deep"); rem = v("rem"); awake = v("awake") }
        }
        guard light + deep + rem > 0 else { return nil }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            out.append(SleepInterval(stage: stage, start: t, end: t + minutes * 60)); t += minutes * 60
        }
        add(.light, light * 0.4); add(.deep, deep); add(.light, light * 0.3)
        add(.rem, rem); add(.light, light * 0.3); add(.awake, awake)
        return (out, true)
    }
}

// MARK: - Workout detail

/// A tapped workout opened as a sheet. WorkoutRow has no id, so the start time stands in for one.
struct WorkoutSelection: Identifiable {
    let row: WorkoutRow
    var id: Int { row.startTs }
}

/// One workout: elapsed time, summary numbers and the heart-rate curve across it. Hovering the curve reads out the
/// bpm and the elapsed time (plus wall-clock time) at that point.
struct WorkoutDetailView: View {
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let workout: WorkoutRow

    @State private var samples: [HRSample] = []
    @State private var loaded = false

    private static let gradient = Gradient(colors: [StrandPalette.metricCyan, StrandPalette.metricRose, StrandPalette.statusCritical])

    private var durationS: Double { workout.durationS ?? Double(max(workout.endTs - workout.startTs, 0)) }
    private var avg: Int? { samples.isEmpty ? workout.avgHr : samples.map(\.bpm).reduce(0, +) / samples.count }
    private var peak: Int? { samples.map(\.bpm).max() ?? workout.maxHr }

    /// At most ~600 points so a multi-hour session stays smooth; each point is the mean of its slice.
    private var points: [(ts: Int, bpm: Double)] {
        let n = 600
        guard samples.count > n else { return samples.map { ($0.ts, Double($0.bpm)) } }
        let step = Double(samples.count) / Double(n)
        return (0..<n).map { i in
            let lo = Int(Double(i) * step), hi = max(lo + 1, min(samples.count, Int(Double(i + 1) * step)))
            let slice = samples[lo..<hi]
            return (slice[slice.startIndex + slice.count / 2].ts, Double(slice.map(\.bpm).reduce(0, +)) / Double(slice.count))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.sport).font(.system(size: 22, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    Text("\(Self.dateText(workout.startTs)) · \(DayMath.clock(workout.startTs)) – \(DayMath.clock(workout.endTs))")
                        .font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.strandPrimary).keyboardShortcut(.defaultAction)
            }

            HStack(spacing: NoopMetrics.gap) {
                stat("Elapsed", Self.elapsed(durationS), StrandPalette.accent)
                stat("Avg HR", avg.map { "\($0) bpm" }, StrandPalette.metricRose)
                stat("Peak HR", peak.map { "\($0) bpm" }, StrandPalette.statusCritical)
                if let kcal = workout.energyKcal { stat("Energy", "\(Int(kcal.rounded())) kcal", StrandPalette.metricAmber) }
                if let s = workout.strain { stat("Strain", String(format: "%.1f", s), StrandPalette.strainColor(s)) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Heart rate").font(.system(size: 17, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                chart
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 460)
        .background(StrandPalette.surfaceBase)
        .task { await load() }
    }

    @ViewBuilder private var chart: some View {
        let pts = points
        if pts.count > 1 {
            let start = workout.startTs
            Sparkline(values: pts.map(\.bpm), gradient: Self.gradient, lineWidth: 2.5, showsArea: true,
                      showsHead: false, showsHover: true,
                      valueFormat: { "\(Int($0.rounded())) bpm" },
                      indexLabel: { i in
                          guard pts.indices.contains(i) else { return "" }
                          return "\(Self.elapsed(Double(pts[i].ts - start))) elapsed · \(DayMath.clock(pts[i].ts))"
                      })
                .frame(height: 220)
            HStack {
                Text("0:00"); Spacer()
                Text(Self.elapsed(Double(pts[pts.count / 2].ts - start))); Spacer()
                Text(Self.elapsed(Double(pts[pts.count - 1].ts - start)))
            }
            .font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary)
            Text("Move over the chart to read the heart rate at any moment of the session.")
                .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
        } else {
            Text(loaded ? "No heart-rate samples stored for this session." : "Loading…")
                .font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private func stat(_ label: String, _ value: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
            Text(value ?? "—").font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface(cornerRadius: 16)
    }

    private func load() async {
        samples = (await repo.hrSamples(from: workout.startTs, to: workout.endTs, limit: 50_000)).sorted { $0.ts < $1.ts }
        loaded = true
    }

    /// h:mm:ss, or m:ss under an hour.
    static func elapsed(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func dateText(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }
}
