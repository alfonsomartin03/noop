import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// Health (issue #14): biological age / healthspan, the Health Monitor (five nightly vitals against personal ranges) and
// the Stress Monitor (heart-rate activation timeline). Analytics live in `HealthMonitor.swift`; methods and research are
// in docs/HEALTH_MODELS.md. Values are wellness observations, never diagnoses.

struct HealthPageView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var summary: HealthMonitorSummary?
    @State private var detail: HealthMetricReading?

    var body: some View {
        ScreenScaffold(title: "Health", subtitle: "Healthspan, vital signs and heart-rate activation, from your own data.", spacing: 28) {
            ConnectionStrip()
            AgeHero(profile: profile)
            VO2MaxCard()
            monitor
            ActivationSection()
            Text("NOOP describes your measurements against your own history. Personal ranges aren't clinical normal ranges, and nothing here is a diagnosis. If you feel unwell, talk to a clinician.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: "\(repo.dataVersion)-\(repo.estimates.count)-\(repo.official.count)-\(Repository.dayString(Date()))") {
            let inputs = await repo.healthInputs()
            let today = Repository.dayString(Date())
            summary = await Task.detached(priority: .userInitiated) {
                HealthMonitor.summary(noop: inputs.noop, imported: inputs.imported, today: today)
            }.value
        }
        .sheet(item: Binding(get: { detail.map(MetricDetailItem.init) }, set: { detail = $0?.reading })) {
            HealthMetricDetail(reading: $0.reading)
        }
    }

    // MARK: Health Monitor

    @ViewBuilder private var monitor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Health Monitor").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                if let s = summary {
                    Text(s.headline).font(StrandFont.caption).foregroundStyle(s.deviations.isEmpty ? StrandPalette.textSecondary : StrandPalette.statusWarningInk)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let s = summary {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: NoopMetrics.gap)], spacing: NoopMetrics.gap) {
                    ForEach(s.readings, id: \.metric) { r in
                        Button { detail = r } label: { MonitorTile(reading: r) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens history and personal range")
                    }
                }
                Text("Each value is compared with your range from up to \(HealthMonitor.lookbackDays) earlier nights (at least \(HealthMonitor.minBaselineDays) needed) from the same source. A reading over \(HealthMonitor.staleAfterDays) days old is shown as stale, not as normal.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct MetricDetailItem: Identifiable {
    let reading: HealthMetricReading
    var id: String { reading.metric.rawValue }
}

// MARK: - Age hero

private struct AgeHero: View {
    @ObservedObject var profile: ProfileStore
    @State private var expanded = false
    private var ageSet: Bool { UserDefaults.standard.object(forKey: "profile.age") != nil }

    var body: some View {
        let availability = BiologicalAgeModel.availability(hasAge: ageSet, hasSex: UserDefaults.standard.object(forKey: "profile.sex") != nil)
        ZStack(alignment: .topLeading) {
            HealthAmbient()
            HStack(alignment: .center, spacing: 28) {
                AgeOrb()
                    .frame(width: 150, height: 150)
                    .overlay {
                        VStack(spacing: 2) {
                            Text("—").font(StrandFont.number(44, weight: .bold)).foregroundStyle(.white)
                            Text("estimate unavailable").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Biological age").font(StrandFont.title2).foregroundStyle(.white)
                    HStack(spacing: 18) {
                        fact("Chronological age", ageSet ? "\(profile.age)" : "Not set", ageSet ? "from your profile" : "add it in Settings")
                        fact("Pace of aging", "—", "needs an age model")
                        fact("Model", "None", "no defensible model yet")
                    }
                    if case let .unavailable(reason, missing) = availability {
                        Text(reason).font(StrandFont.caption).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup(isExpanded: $expanded) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(missing, id: \.self) { m in
                                    Label(m, systemImage: "circle.dashed").font(StrandFont.caption).foregroundStyle(.white.opacity(0.9))
                                }
                                Text("NOOP will only enable an estimate once a published, validated model's inputs are available here. See docs/HEALTH_MODELS.md for the models reviewed.")
                                    .font(StrandFont.footnote).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("What it would need").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        }
                        .tint(.white)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: StrandPalette.shadow, radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Biological age: estimate unavailable. Chronological age \(ageSet ? "\(profile.age)" : "not set").")
    }

    private func fact(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Text(value).font(StrandFont.number(20, weight: .bold)).foregroundStyle(.white)
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Deep emerald wash behind the age hero. Fixed colors: it reads the same in light and dark, and white text keeps contrast.
private struct HealthAmbient: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.02, green: 0.30, blue: 0.22), Color(red: 0.01, green: 0.18, blue: 0.16)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(RadialGradient(colors: [Color(red: 0.16, green: 0.75, blue: 0.52).opacity(0.45), .clear],
                                    center: .init(x: 0.15, y: 0.3), startRadius: 10, endRadius: 320))
    }
}

/// Organic orb: overlapping soft blobs that drift slowly. Still under Reduce Motion or when the window is inactive.
private struct AgeOrb: View {
    @Environment(\.controlActiveState) private var active
    var body: some View {
        let still = StrandMotion.reduceMotion || active == .inactive
        TimelineView(.animation(minimumInterval: 1 / 20, paused: still)) { ctx in
            let t = still ? 0 : ctx.date.timeIntervalSinceReferenceDate / 6
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t + Double(i) * 2.1
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 0.45, green: 0.95, blue: 0.72).opacity(0.85), Color(red: 0.05, green: 0.55, blue: 0.40).opacity(0.2)],
                                             center: .center, startRadius: 4, endRadius: 80))
                        .frame(width: 120 + CGFloat(sin(phase) * 8), height: 120 + CGFloat(cos(phase * 0.8) * 8))
                        .offset(x: CGFloat(cos(phase) * 7), y: CGFloat(sin(phase * 1.3) * 7))
                        .blendMode(.plusLighter)
                }
            }
            .blur(radius: 6)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1).padding(8))
        }
    }
}

// MARK: - Monitor tile

private struct MonitorTile: View {
    let reading: HealthMetricReading

    private var tint: Color {
        switch reading.status {
        case .within: return StrandPalette.statusPositiveInk
        case .above, .below: return StrandPalette.statusWarningInk
        default: return StrandPalette.textTertiary
        }
    }

    var body: some View {
        let m = reading.metric
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(m.title, systemImage: m.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.latest.map { HealthFormat.value($0.value, m) } ?? "—").font(StrandFont.number(28, weight: .bold))
                    .foregroundStyle(reading.latest == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text(m.unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Label(reading.status.label, systemImage: reading.status.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .strandSurface(cornerRadius: 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(m.title): \(reading.latest.map { "\(HealthFormat.value($0.value, m)) \(m.unit)" } ?? "no reading"). \(reading.status.label). \(caption)")
    }

    private var caption: String {
        guard let l = reading.latest else {
            return reading.metric == .skinTemp ? "NOOP's nightly skin-temperature change; none stored yet" : "Nothing stored from either source"
        }
        var s = "Night of \(HighlightsContent.long(l.day)) · \(reading.source)"
        if let b = reading.baseline { s += " · range \(HealthFormat.value(b.low, reading.metric))–\(HealthFormat.value(b.high, reading.metric))" }
        return s
    }
}

enum HealthFormat {
    static func value(_ v: Double, _ m: HealthMetric) -> String {
        let s = String(format: "%.\(m.decimals)f", v)
        return m == .skinTemp && v > 0 ? "+" + s : s
    }
}

// MARK: - Metric detail

private struct HealthMetricDetail: View {
    let reading: HealthMetricReading
    @Environment(\.dismiss) private var dismiss

    private var shown: [HealthPoint] { Array(reading.history.suffix(90)) }

    var body: some View {
        let m = reading.metric
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(m.title, systemImage: m.symbol).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.strandSecondary).keyboardShortcut(.cancelAction)
            }
            Text(m.explanation).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).fixedSize(horizontal: false, vertical: true)
            if shown.count >= 2 {
                chart.frame(height: 220)
            } else {
                Text("Not enough nights stored to draw a history yet.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                row("Latest", reading.latest.map { "\(HealthFormat.value($0.value, m)) \(m.unit) · night of \(HighlightsContent.long($0.day))" } ?? "None")
                row("Status", reading.status.label)
                row("Source", "\(reading.source) (value and range from this source only)")
                if let b = reading.baseline {
                    row("Personal range", "\(HealthFormat.value(b.low, m))–\(HealthFormat.value(b.high, m)) \(m.unit), median \(HealthFormat.value(b.median, m))")
                    row("Range built from", "\(b.count) nights, \(HighlightsContent.long(b.firstDay)) – \(HighlightsContent.long(b.lastDay))" + (b.outliers > 0 ? " · \(b.outliers) outlier\(b.outliers == 1 ? "" : "s") left out" : ""))
                }
                row("Coverage", coverage)
            }
            Text("The range is your median ± 2 robust spreads from earlier nights (never including the night shown). It describes your usual values, not a clinical normal range.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 560)
        .background(StrandPalette.surfaceBase)
    }

    private var coverage: String {
        guard let first = shown.first, let last = shown.last, let a = HighlightCalendar.date(first.day), let b = HighlightCalendar.date(last.day) else { return "No nights" }
        let span = Int((b.timeIntervalSince(a) / 86_400).rounded()) + 1
        return "\(shown.count) of \(span) nights have a value (\(HighlightsContent.long(first.day)) – \(HighlightsContent.long(last.day)))"
    }

    private var chart: some View {
        let m = reading.metric
        let pts = shown.compactMap { p in HighlightCalendar.date(p.day).map { (date: $0, value: p.value) } }
        return Chart {
            if let b = reading.baseline, let f = pts.first?.date, let l = pts.last?.date {
                RectangleMark(xStart: .value("From", f), xEnd: .value("To", l), yStart: .value("Low", b.low), yEnd: .value("High", b.high))
                    .foregroundStyle(StrandPalette.statusPositive.opacity(0.12))
                RuleMark(y: .value("Median", b.median)).foregroundStyle(StrandPalette.statusPositive.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(pts, id: \.date) { p in
                LineMark(x: .value("Night", p.date), y: .value(m.title, p.value))
                    .foregroundStyle(StrandPalette.accent).interpolationMethod(.monotone)
                PointMark(x: .value("Night", p.date), y: .value(m.title, p.value))
                    .foregroundStyle(StrandPalette.accent).symbolSize(14)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("\(m.title) history, \(pts.count) nights, with your personal range shaded")
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stress Monitor (heart-rate activation)

private struct ActivationSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var dayOffset = 0
    @State private var bins: [HRActivation.Bin] = []
    @State private var resting: (bpm: Double, source: String)?
    @State private var loaded = false
    /// Length of the shown local day (23–25 h across DST), so bins sit at their true time of day.
    @State private var dayLength = 86_400

    private var day: String { HighlightCalendar.addDays(Repository.dayString(Date()), -dayOffset) ?? Repository.dayString(Date()) }

    private static let colors = ActivationPalette.colors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stress Monitor").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text("Heart-rate activation through the day. Not a stress score.").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button { dayOffset += 1 } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                    Text(dayOffset == 0 ? "Today" : HighlightsContent.long(day)).font(.system(size: 13, weight: .semibold)).frame(minWidth: 96)
                    Button { dayOffset = max(0, dayOffset - 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(dayOffset == 0).accessibilityLabel("Next day")
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let resting {
                    timeline
                    legend
                    Text("Awake bins are coloured by heart rate's share of your heart-rate reserve above resting (\(Int(resting.bpm.rounded())) bpm, \(resting.source)) up to your max (\(profile.hrMax) bpm): under \(Int(HRActivation.moderateHRR * 100)) % near resting, \(Int(HRActivation.moderateHRR * 100))–\(Int(HRActivation.highHRR * 100)) % moderately raised, above that strongly raised. Movement, heat, caffeine and illness raise heart rate too, so this can't tell stress from activity, and NOOP doesn't infer emotions or mental health from it. A numerical stress score stays off until an HRV-based method can be validated on this data.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).fixedSize(horizontal: false, vertical: true)
                } else if loaded {
                    StrandNotice(symbol: "heart.slash", title: "Unavailable",
                                 message: "Heart-rate activation needs a resting heart rate from at least one scored night. It appears once NOOP has scored your sleep.",
                                 tint: StrandPalette.textSecondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface()
        }
        .task(id: "\(day)-\(repo.dataVersion)") { await load() }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(Array(bins.enumerated()), id: \.offset) { _, b in
                        Rectangle()
                            .fill(Self.colors[b.level] ?? .clear)
                            .overlay(b.level == .noData ? Rectangle().strokeBorder(StrandPalette.hairline, lineWidth: 0.25) : nil)
                            .frame(width: g.size.width * CGFloat(b.end - b.start) / CGFloat(max(dayLength, 1)))
                            .help("\(ZoneTimeline.shared.clock(b.start))–\(ZoneTimeline.shared.clock(b.end)): \(b.level.label)\(b.meanHR.map { ", avg \(Int($0.rounded())) bpm" } ?? "")")
                    }
                    Spacer(minLength: 0)   // the rest of today hasn't happened yet
                }
                .background(StrandPalette.surfaceInset.opacity(0.4))
            }
            .frame(height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Text("12 am"); Spacer(); Text("6 am"); Spacer(); Text("12 pm"); Spacer(); Text("6 pm"); Spacer(); Text("12 am")
            }
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart-rate activation timeline for \(dayOffset == 0 ? "today" : HighlightsContent.long(day))")
        .accessibilityValue(totalsText)
    }

    private var totalsText: String {
        let t = HRActivation.totals(bins)
        return HRActivation.Level.allCases.compactMap { l in t[l].map { "\(l.label) \(DayMath.hm(Double($0) / 60))" } }.joined(separator: ", ")
    }

    private var legend: some View {
        let t = HRActivation.totals(bins)
        let total = max(1, bins.reduce(0) { $0 + $1.end - $1.start })
        let covered = total - (t[.noData] ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach([HRActivation.Level.low, .moderate, .high, .exercise, .sleep, .noData], id: \.self) { l in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Self.colors[l] ?? .clear).frame(width: 12, height: 12)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(StrandPalette.hairlineStrong, lineWidth: 0.5))
                        Text(l.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        Text(DayMath.hm(Double(t[l] ?? 0) / 60)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Coverage: \(Int((Double(covered) / Double(total) * 100).rounded())) % of \(dayOffset == 0 ? "the day so far" : "the day") has readings, sleep or a workout. Gaps are shown as no data, never as calm.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func load() async {
        loaded = false
        defer { loaded = true }
        guard let l = await ActivationLoad.load(repo: repo, maxHR: profile.hrMax, day: day) else { resting = nil; bins = []; return }
        resting = l.resting
        dayLength = l.dayLength
        bins = l.bins
    }
}
