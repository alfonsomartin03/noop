import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// Heart-rate activation pieces shared by the Health page's Stress Monitor and the compact strip in Overview's heart-rate
// card (issue #16). Same pipeline (`HRActivation.timeline`) on both; neither is a stress score.

enum ActivationPalette {
    static let colors: [HRActivation.Level: Color] = [
        .low: StrandPalette.statusPositive, .moderate: StrandPalette.metricAmber, .high: StrandPalette.statusCritical,
        .sleep: StrandPalette.sleepDeep, .exercise: StrandPalette.accent, .noData: StrandPalette.surfaceInset,
    ]
}

struct ActivationLoad {
    let bins: [HRActivation.Bin]
    let resting: (bpm: Double, source: String)
    /// Real length of the local day (23–25 h across DST).
    let dayLength: Int

    /// Spans shown as "Asleep": confirmed sessions only (main sleep, interrupted main sleep, nap; legacy rows without a
    /// kind were always main sleep). Uncertain episodes are not sleep: their bins fall through to the heart-rate check,
    /// so they read as activation where readings exist and as no data where they don't, and never add coverage.
    nonisolated static func sleepIntervals(_ episodes: [CachedSleepSession]) -> [(Int, Int)] {
        episodes.filter { $0.isMainSleep || $0.kind == SleepSessionKind.nap.rawValue }.map { ($0.startTs, $0.endTs) }
    }

    /// Resting HR: NOOP's latest scored night up to `day`, else imported (labelled). Nil without either.
    @MainActor
    static func load(repo: Repository, maxHR: Int, day: String) async -> ActivationLoad? {
        let noopRest = repo.estimates.values.filter { $0.day <= day && $0.restingHr != nil }.max { $0.day < $1.day }
        let impRest = repo.official.values.filter { $0.day <= day && $0.restingHr != nil }.max { $0.day < $1.day }
        let resting: (Double, String)
        if let n = noopRest, let r = n.restingHr { resting = (Double(r), "NOOP, night of \(HighlightsContent.long(n.day))") }
        else if let i = impRest, let r = i.restingHr { resting = (Double(r), "WHOOP import, night of \(HighlightsContent.long(i.day))") }
        else { return nil }
        guard let range = ZoneTimeline.shared.dayRange(day) else { return nil }
        let end = min(range.to, Int(Date().timeIntervalSince1970))
        guard end > range.from else { return ActivationLoad(bins: [], resting: resting, dayLength: range.to - range.from) }
        let hr = await repo.hrSamples(from: range.from, to: end, limit: 200_000)
        let sleeps = sleepIntervals(await repo.noopSleepEpisodes(from: range.from, to: end))
        let workouts = await repo.workoutRows().filter { $0.endTs > range.from && $0.startTs < end }.map { ($0.startTs, $0.endTs) }
        let rest = resting.0, mx = Double(maxHR)
        let samples = hr.map { (ts: $0.ts, bpm: $0.bpm) }
        let bins = await Task.detached(priority: .userInitiated) {
            HRActivation.timeline(samples: samples, from: range.from, to: end, restingHR: rest, maxHR: mx, sleep: sleeps, workouts: workouts)
        }.value
        return ActivationLoad(bins: bins, resting: resting, dayLength: range.to - range.from)
    }
}

/// The day as a row of coloured 15-minute bins; the rest of today stays empty.
struct ActivationBar: View {
    let bins: [HRActivation.Bin]
    let dayLength: Int
    var height: CGFloat = 30

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(bins.enumerated()), id: \.offset) { _, b in
                    Rectangle()
                        .fill(ActivationPalette.colors[b.level] ?? .clear)
                        .overlay(b.level == .noData ? Rectangle().strokeBorder(StrandPalette.hairline, lineWidth: 0.25) : nil)
                        .frame(width: g.size.width * CGFloat(b.end - b.start) / CGFloat(max(dayLength, 1)))
                        .help("\(ZoneTimeline.shared.clock(b.start))–\(ZoneTimeline.shared.clock(b.end)): \(b.level.label)\(b.meanHR.map { ", avg \(Int($0.rounded())) bpm" } ?? "")")
                }
                Spacer(minLength: 0)
            }
            .background(StrandPalette.surfaceInset.opacity(0.4))
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height > 16 ? 8 : 4, style: .continuous))
    }
}

/// Overview heart-rate card: the latest known activation state, a thin day strip and its coverage. Minimal on purpose;
/// the full timeline, legend and method live on the Health page.
struct ActivationMini: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    let day: String
    @State private var load: ActivationLoad?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Activation").font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                if let l = load, let last = HRActivation.latest(l.bins) {
                    Circle().fill(ActivationPalette.colors[last.level] ?? .clear).frame(width: 7, height: 7)
                    Text("\(last.level.label) · \(ZoneTimeline.shared.clock(last.start))–\(ZoneTimeline.shared.clock(last.end))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(StrandPalette.textPrimary)
                } else if loaded {
                    Text(load == nil ? "Needs a resting heart rate from a scored night" : "No readings yet")
                        .font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                if let l = load, !l.bins.isEmpty {
                    Text("\(Int((HRActivation.coverage(l.bins) * 100).rounded())) % covered")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if let l = load {
                ActivationBar(bins: l.bins, dayLength: l.dayLength, height: 10)
            }
            Text("Heart rate vs your resting and max, in 15-min bins — not a stress score. Details on the Health page.")
                .font(.system(size: 10)).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart-rate activation")
        .accessibilityValue(accessibilityText)
        .task(id: "\(day)-\(repo.dataVersion)-\(profile.hrMax)") {
            loaded = false
            load = await ActivationLoad.load(repo: repo, maxHR: profile.hrMax, day: day)
            loaded = true
        }
    }

    private var accessibilityText: String {
        guard let l = load else { return loaded ? "Unavailable: needs a resting heart rate from a scored night" : "Loading" }
        let latest = HRActivation.latest(l.bins).map { "Latest \($0.level.label), \(ZoneTimeline.shared.clock($0.start)) to \(ZoneTimeline.shared.clock($0.end))" } ?? "No readings yet"
        return "\(latest). \(Int((HRActivation.coverage(l.bins) * 100).rounded())) percent of the day so far has readings, sleep or a workout. Not a stress score."
    }
}

// MARK: - VO₂max estimate (Health page)

struct VO2MaxCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var result: VO2MaxEstimate.Result?

    private var ageSet: Bool { UserDefaults.standard.object(forKey: "profile.age") != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("VO₂max estimate", systemImage: "lungs.fill").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("Experimental, unvalidated estimate · \(VO2MaxEstimate.version)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            switch result {
            case .estimate(let e)?:
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f", e.vo2)).font(StrandFont.number(34, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    Text("mL/kg/min").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Text("15.3 × max HR \(Int(e.maxHR.rounded())) bpm (\(e.maxHRSource == .entered ? "entered in Profile" : "predicted from age")) ÷ resting HR \(Int(e.restingHR.rounded())) bpm (median of \(e.nights) NOOP nights, \(HighlightsContent.long(e.firstDay)) – \(HighlightsContent.long(e.lastDay))).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Heart-rate-ratio method (Uth et al. 2004). Not a lab test: individual error can be large, an age-predicted max adds error, and NOOP's sleep-derived resting HR is lower than a daytime resting HR, which pushes this up. Not validated against a measured VO₂max for you.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            case .unavailable(let reason, let missing)?:
                StrandNotice(symbol: "lungs", title: "Unavailable", message: reason + (missing.isEmpty ? "" : "."), tint: StrandPalette.textSecondary)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface()
        .task(id: "\(repo.dataVersion)-\(repo.estimates.count)-\(profile.age)-\(profile.hrMaxOverride)-\(Repository.dayString(Date()))") {
            let rest = repo.estimates.values.compactMap { m in m.restingHr.map { HealthPoint(day: m.day, value: Double($0)) } }
            result = VO2MaxEstimate.estimate(restingHR: rest, age: ageSet ? profile.age : nil,
                                             enteredMaxHR: profile.hrMaxOverride > 0 ? profile.hrMaxOverride : nil,
                                             today: Repository.dayString(Date()))
        }
    }
}
