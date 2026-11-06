import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trend sections
//
// The Sleep, Vitals and Activity trends in the Trends hub, plus the pieces the Scores tab shares with them. Everything
// here reads stored values as they are: a metric with no history shows an empty state, never a placeholder series, and
// nothing is recalculated. Windows are relative to the latest stored day (imports may stop long before today), and a window
// with no points widens to the next range, saying so.

/// The shared range control: W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL.
enum TrendRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .week:    return "W"
        case .month:   return "M"
        case .quarter: return "3M"
        case .half:    return "6M"
        case .year:    return "1Y"
        case .all:     return "ALL"
        }
    }
    /// Trailing-day window, or nil for "all history".
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search
    /// order when the selected window holds zero points.
    var widening: [TrendRange] {
        let order: [TrendRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }

    /// "week" / "3 months" / "all history".
    var name: String {
        switch self {
        case .week:    return "week"
        case .month:   return "month"
        case .quarter: return "3 months"
        case .half:    return "6 months"
        case .year:    return "year"
        case .all:     return "all history"
        }
    }

    /// "Trailing 90 days" / "All history".
    var subtitle: String { days.map { "Trailing \($0) days" } ?? "All history" }
}

/// One metric inside a range: the points shown, the range they came from, and how to describe that.
struct TrendSeries {
    var points: [TrendPoint]
    var effective: TrendRange
    var widened: Bool
    var caption: String

    var mean: Double? { points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count) }
    var low: Double? { points.map(\.value).min() }
    var high: Double? { points.map(\.value).max() }
    var canDraw: Bool { points.count >= 2 }
}

enum TrendWindow {
    // yyyy-MM-dd → Date (en_US_POSIX, UTC).
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func date(_ day: String) -> Date? { dayParser.date(from: day) }

    /// Points inside `range`, taken RELATIVE TO `anchor` (the latest day), not "now".
    static func points(_ all: [TrendPoint], in range: TrendRange, anchor: Date?) -> [TrendPoint] {
        guard let n = range.days else { return all }
        guard let anchor else { return [] }
        let cutoff = anchor.addingTimeInterval(-Double(n - 1) * 86_400)
        return all.filter { $0.date >= cutoff }
    }

    static func caption(count n: Int, selected: TrendRange, effective: TrendRange) -> String {
        if n == 0 { return "No readings stored" }
        let unit = n == 1 ? "reading" : "readings"
        if effective != selected { return "\(n) \(unit) · sparse — widened to \(effective.name)" }
        return "\(n) \(unit) · \(selected.name)"
    }

    /// The smallest range ≥ `range` whose window holds ≥1 point, else ALL.
    static func resolve(_ all: [TrendPoint], range: TrendRange, anchor: Date?) -> TrendSeries {
        for r in range.widening {
            let pts = points(all, in: r, anchor: anchor)
            if !pts.isEmpty {
                return TrendSeries(points: pts, effective: r, widened: r != range,
                                   caption: caption(count: pts.count, selected: range, effective: r))
            }
        }
        return TrendSeries(points: [], effective: .all, widened: .all != range,
                           caption: caption(count: 0, selected: range, effective: .all))
    }

    /// Stored daily rows as a series.
    static func series(_ days: [DailyMetric], _ value: (DailyMetric) -> Double?, range: TrendRange, anchor: Date?) -> TrendSeries {
        let all = days.compactMap { d -> TrendPoint? in
            guard let v = value(d), let dt = date(d.day) else { return nil }
            return TrendPoint(date: dt, value: v)
        }
        return resolve(all, range: range, anchor: anchor)
    }

    /// A padded value range for a series so the line isn't flat against the axis.
    static func valueRange(_ pts: [TrendPoint], fallback: ClosedRange<Double>, pad: Double = 0.12) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return fallback }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let span = hi - lo
        return (lo - span * pad)...(hi + span * pad)
    }

    /// Single-color gradient (for metric lines that aren't a value ramp).
    static func gradient(_ color: Color) -> Gradient {
        Gradient(stops: [.init(color: color.opacity(0.55), location: 0.0), .init(color: color, location: 1.0)])
    }
}

// MARK: Shared pieces

/// Range pills, the window in words, and a clear note when a window had to widen.
struct TrendRangeBar: View {
    @Binding var range: TrendRange
    /// Set when the leading series widened past the selected range.
    var sparseNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SegmentedPillControl(TrendRange.allCases, selection: $range) { $0.label }
                Spacer(minLength: 12)
                Text(range.subtitle).strandOverline()
            }
            if let sparseNote {
                Label(sparseNote, systemImage: "calendar.badge.clock")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningInk)
                    .accessibilityLabel(sparseNote)
            }
        }
    }
}

/// A compact number in a soft, rounded bubble: a tinted icon badge and label, a large rounded value with its unit,
/// one line of context. `accent` washes the bubble and colors the badge; `tint` colors the value itself.
struct TrendStat: View {
    let label: String
    let value: String?
    var unit: String? = nil
    var caption: String? = nil
    var tint: Color = StrandPalette.textPrimary
    var symbol: String? = nil
    var accent: Color = StrandPalette.accent

    @State private var hovering = false
    private static let radius: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StrandPalette.ink(accent))
                        .frame(width: 24, height: 24)
                        .background(accent.opacity(0.18), in: Circle())
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value ?? "—").font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let unit, value != nil {
                        Text(unit).font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(caption ?? " ").font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: shape)
        // Soft wash of the accent from the top-leading corner, like a lit bubble.
        .background(
            shape.fill(RadialGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)],
                                      center: .topLeading, startRadius: 0, endRadius: 220))
                .allowsHitTesting(false),
            alignment: .center
        )
        .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false))
        .overlay(shape.strokeBorder(accent.opacity(hovering ? 0.35 : 0.18), lineWidth: 0.75))
        .shadow(color: accent.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 18 : 12, y: hovering ? 8 : 5)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(StrandMotion.respecting(.spring(response: 0.35, dampingFraction: 0.7)), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// The `TrendStat`s at the top of a section: one row sharing the full width, or two columns when that row won't fit.
struct TrendSummaryRow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        EqualRowLayout(minWidth: 130, fallbackColumns: 2, spacing: NoopMetrics.gap) { content() }
    }
}

/// A chart with a readable title, its window, and the headline number beside it.
struct TrendCard<Chart: View, Footer: View>: View {
    let title: String
    let caption: String
    var value: String? = nil
    var valueLabel: String = "average"
    var height: CGFloat = NoopMetrics.chartHeight
    /// Colors the headline number; text-primary when nil.
    var accent: Color? = nil
    @ViewBuilder var chart: () -> Chart
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                        Text(caption).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 12)
                    if let value {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(value).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(accent.map(StrandPalette.scoreInk) ?? StrandPalette.textPrimary)
                            Text(valueLabel).font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                chart().frame(height: height)
                footer()
            }
        }
    }
}

/// The numbers under a trend chart as soft rounded pills.
struct TrendFooter: View {
    let items: [(String, String)]
    var accent: Color = StrandPalette.accent
    init(_ items: [(String, String)], accent: Color = StrandPalette.accent) { self.items = items; self.accent = accent }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.0).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                    Text(it.1).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// What a chart shows when its window can't draw a line.
struct TrendEmptyChart: View {
    var count: Int
    /// What one point of this chart is, and how many a trend needs.
    var one = "One reading so far"
    var none = "No readings in this window"
    var needs = "A trend needs at least two days."
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 40, height: 40).background(StrandPalette.surfaceRaised, in: Circle())
            Text(count == 1 ? one : none)
                .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(StrandPalette.textSecondary)
            Text(needs).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A line over a series, or the empty state, with its low and high.
struct TrendLineCard: View {
    let title: String
    let unit: String
    let series: TrendSeries
    var gradient: Gradient
    var valueRange: ClosedRange<Double>
    var height: CGFloat = NoopMetrics.chartHeight
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var note: String? = nil

    /// The gradient's color at the series average, for the headline and footer.
    private var accent: Color {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        let t = hi > lo ? min(max(((series.mean ?? lo) - lo) / (hi - lo), 0), 1) : 1
        return StrandPalette.sample(stops: gradient.stops, at: t)
    }

    var body: some View {
        TrendCard(title: title, caption: note.map { "\(series.caption) · \($0)" } ?? series.caption,
                  value: series.mean.map { unit.isEmpty ? format($0) : "\(format($0)) \(unit)" }, height: height, accent: accent) {
            if series.canDraw {
                TrendChart(points: series.points, gradient: gradient, valueRange: valueRange, showsArea: true, height: height,
                           valueFormat: { unit.isEmpty ? format($0) : "\(format($0)) \(unit)" }, style: .soft)
            } else {
                TrendEmptyChart(count: series.points.count)
            }
        } footer: {
            TrendFooter([("Low", series.low.map(format) ?? "—"), ("High", series.high.map(format) ?? "—"),
                         ("Days", "\(series.points.count)")], accent: accent)
        }
    }
}

private let trendCardColumns = [GridItem(.adaptive(minimum: 320), spacing: NoopMetrics.gap, alignment: .top)]

// MARK: Sleep

/// Sleep over time: how long, how efficiently, and how the stages split.
struct SleepTrendsView: View {
    @EnvironmentObject var repo: Repository
    var body: some View { SleepTrendsContent(days: repo.days, loaded: repo.loaded) }
}

struct SleepTrendsContent: View {
    let days: [DailyMetric]
    let loaded: Bool
    @State private var range: TrendRange = .month

    private static func hoursText(_ hours: Double) -> String { DayMath.hm(hours * 60) }

    var body: some View {
        ScreenScaffold(title: "Sleep trends") {
            let anchor = days.last.flatMap { TrendWindow.date($0.day) }
            // Plotted in hours, so the chart's axis reads like the durations around it.
            let duration = TrendWindow.series(days, { $0.totalSleepMin.map { $0 / 60 } }, range: range, anchor: anchor)
            if duration.points.isEmpty {
                ComingSoon(what: loaded ? "No nights stored yet. Sleep trends appear after a few nights of wear, or import your WHOOP export in Settings → Data."
                                        : "Loading your history…")
            } else {
                let efficiency = TrendWindow.series(days, { $0.efficiency }, range: range, anchor: anchor)
                let restorative = TrendWindow.series(days, { d in
                    guard let a = d.deepMin, let b = d.remMin else { return nil }
                    return a + b
                }, range: range, anchor: anchor)
                let stages = StageWindow(days: days, range: range, anchor: anchor)

                TrendRangeBar(range: $range, sparseNote: duration.widened ? duration.caption : nil)
                TrendSummaryRow {
                    TrendStat(label: "Average asleep", value: duration.mean.map(Self.hoursText), caption: "per night",
                              symbol: "bed.double.fill", accent: StrandPalette.sleepLight)
                    TrendStat(label: "Efficiency", value: efficiency.mean.map { String(format: "%.0f", $0) }, unit: "%",
                              caption: efficiency.points.isEmpty ? "Not recorded" : "average",
                              symbol: "checkmark.seal.fill", accent: StrandPalette.statusPositive)
                    TrendStat(label: "Deep + REM", value: restorative.mean.map(DayMath.hm),
                              caption: restorative.points.isEmpty ? "Not recorded" : "per night",
                              symbol: "moon.stars.fill", accent: StrandPalette.sleepDeep)
                    TrendStat(label: "Nights", value: "\(duration.points.count)", caption: duration.effective.subtitle,
                              symbol: "calendar", accent: StrandPalette.sleepREM)
                }
                TrendLineCard(title: "Time asleep", unit: "", series: duration, gradient: TrendWindow.gradient(StrandPalette.sleepLight),
                              valueRange: TrendWindow.valueRange(duration.points, fallback: 4...10), format: Self.hoursText, note: "hours")
                LazyVGrid(columns: trendCardColumns, alignment: .leading, spacing: NoopMetrics.gap) {
                    TrendLineCard(title: "Sleep efficiency", unit: "%", series: efficiency, gradient: TrendWindow.gradient(StrandPalette.statusPositive),
                                  valueRange: TrendWindow.valueRange(efficiency.points, fallback: 60...100))
                    TrendCard(title: "Sleep stages", caption: stages.caption, value: stages.totalText, valueLabel: "staged, average",
                              accent: StrandPalette.sleepDeep) {
                        if stages.buckets.count >= 2 {
                            StageChart(window: stages)
                        } else {
                            TrendEmptyChart(count: stages.buckets.count)
                        }
                    } footer: {
                        TrendFooter(StageWindow.Stage.allCases.map { s in
                            (s.title, stages.mean(s).map { "\(DayMath.hm($0)) · \(stages.share(s))%" } ?? "—")
                        }, accent: StrandPalette.sleepDeep)
                    }
                }
            }
        }
    }
}

/// Stored stage minutes in a window, one bar per night, or per week once nightly bars get too thin to read.
struct StageWindow {
    enum Stage: String, CaseIterable {
        case deep, rem, light
        var title: String { self == .rem ? "REM" : rawValue.capitalized }
        var color: Color {
            switch self {
            case .deep: return StrandPalette.sleepDeep
            case .rem: return StrandPalette.sleepREM
            case .light: return StrandPalette.sleepLight
            }
        }
    }
    struct Bucket: Identifiable {
        let date: Date
        let minutes: [Stage: Double]
        var id: Date { date }
    }
    static let maxNightlyBars = 45

    let nights: [(date: Date, minutes: [Stage: Double])]
    let buckets: [Bucket]
    let weekly: Bool
    let caption: String

    init(days: [DailyMetric], range: TrendRange, anchor: Date?) {
        let all = days.compactMap { d -> (Date, [Stage: Double])? in
            guard let date = TrendWindow.date(d.day), let a = d.deepMin, let b = d.remMin, let c = d.lightMin else { return nil }
            return (date, [.deep: a, .rem: b, .light: c])
        }
        // Resolved through the same widening as every other series.
        let series = TrendWindow.resolve(all.map { TrendPoint(date: $0.0, value: 1) }, range: range, anchor: anchor)
        let included = Set(series.points.map(\.date))
        let kept = all.filter { included.contains($0.0) }
        nights = kept.map { (date: $0.0, minutes: $0.1) }
        weekly = kept.count > Self.maxNightlyBars
        if weekly {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            cal.firstWeekday = 2
            let grouped = Dictionary(grouping: kept) { cal.dateInterval(of: .weekOfYear, for: $0.0)?.start ?? $0.0 }
            buckets = grouped.keys.sorted().map { week in
                let nights = grouped[week]!
                var out: [Stage: Double] = [:]
                for s in Stage.allCases { out[s] = nights.map { $0.1[s] ?? 0 }.reduce(0, +) / Double(nights.count) }
                return Bucket(date: week, minutes: out)
            }
        } else {
            buckets = kept.map { Bucket(date: $0.0, minutes: $0.1) }
        }
        caption = series.caption + (weekly ? " · weekly averages" : "")
    }

    func mean(_ s: Stage) -> Double? {
        nights.isEmpty ? nil : nights.map { $0.minutes[s] ?? 0 }.reduce(0, +) / Double(nights.count)
    }
    private var total: Double { Stage.allCases.compactMap(mean).reduce(0, +) }
    var totalText: String? { nights.isEmpty ? nil : DayMath.hm(total) }
    func share(_ s: Stage) -> Int { total > 0 ? Int(((mean(s) ?? 0) / total * 100).rounded()) : 0 }
}

private struct StageChart: View {
    let window: StageWindow

    var body: some View {
        Chart {
            ForEach(window.buckets) { b in
                ForEach(StageWindow.Stage.allCases, id: \.self) { s in
                    BarMark(x: .value("Date", b.date, unit: window.weekly ? .weekOfYear : .day),
                            y: .value("Hours", (b.minutes[s] ?? 0) / 60))
                        .foregroundStyle(by: .value("Stage", s.title))
                        .cornerRadius(window.buckets.count > 20 ? 2 : 5, style: .continuous)
                }
            }
        }
        .chartForegroundStyleScale(domain: StageWindow.Stage.allCases.map(\.title), range: StageWindow.Stage.allCases.map(\.color))
        .chartLegend(position: .top, alignment: .leading, spacing: 10)
        .chartXAxis { SoftAxis.x(count: 4) }
        .chartYAxis { SoftAxis.y(count: 4) }
        .chartYAxisLabel("hours")
        .accessibilityLabel("Sleep stages over time")
        .accessibilityValue(StageWindow.Stage.allCases.map { "\($0.title) \(window.share($0)) percent" }.joined(separator: ", "))
    }
}

// MARK: Vitals

/// Body signals over time. The live heart-rate view stays one switch away.
struct VitalsTrendsView: View {
    @EnvironmentObject var repo: Repository
    var body: some View { VitalsTrendsContent(days: repo.days, loaded: repo.loaded) }
}

struct VitalsTrendsContent: View {
    let days: [DailyMetric]
    let loaded: Bool
    @State private var range: TrendRange = .month

    private func series(_ value: (DailyMetric) -> Double?) -> TrendSeries {
        TrendWindow.series(days, value, range: range, anchor: days.last.flatMap { TrendWindow.date($0.day) })
    }

    var body: some View {
        ScreenScaffold(title: "Vitals trends") {
            let rhr = series { $0.restingHr.map(Double.init) }, hrv = series { $0.avgHrv }
            let resp = series { $0.respRateBpm }, spo2 = series { $0.spo2Pct }, temp = series { $0.skinTempDevC }
            let oneDecimal: (Double) -> String = { String(format: "%.1f", $0) }

            if [rhr, hrv, resp, spo2, temp].allSatisfy(\.points.isEmpty) {
                ComingSoon(what: loaded ? "No vitals stored yet. They appear after a night of wear, or import your WHOOP export in Settings → Data."
                                        : "Loading your history…")
            } else {
                let lead = [rhr, hrv].first { !$0.points.isEmpty } ?? resp
                TrendRangeBar(range: $range, sparseNote: lead.widened ? lead.caption : nil)
                TrendSummaryRow {
                    TrendStat(label: "Resting HR", value: rhr.mean.map { "\(Int($0.rounded()))" }, unit: "bpm", caption: rhr.points.isEmpty ? "Not recorded" : "average",
                              symbol: "heart.fill", accent: StrandPalette.metricRose)
                    TrendStat(label: "HRV", value: hrv.mean.map { "\(Int($0.rounded()))" }, unit: "ms", caption: hrv.points.isEmpty ? "Not recorded" : "average",
                              symbol: "waveform.path.ecg", accent: StrandPalette.metricPurple)
                    TrendStat(label: "Respiration", value: resp.mean.map(oneDecimal), unit: "rpm", caption: resp.points.isEmpty ? "Not recorded" : "average",
                              symbol: "lungs.fill", accent: StrandPalette.metricCyan)
                    TrendStat(label: "Blood oxygen", value: spo2.mean.map(oneDecimal), unit: "%", caption: spo2.points.isEmpty ? "Not recorded" : "average",
                              symbol: "drop.fill", accent: StrandPalette.accent)
                }
                LazyVGrid(columns: trendCardColumns, alignment: .leading, spacing: NoopMetrics.gap) {
                    TrendLineCard(title: "Resting heart rate", unit: "bpm", series: rhr, gradient: TrendWindow.gradient(StrandPalette.metricRose),
                                  valueRange: TrendWindow.valueRange(rhr.points, fallback: 40...80))
                    TrendLineCard(title: "Heart rate variability", unit: "ms", series: hrv, gradient: TrendWindow.gradient(StrandPalette.metricPurple),
                                  valueRange: TrendWindow.valueRange(hrv.points, fallback: 20...120))
                    if !resp.points.isEmpty {
                        TrendLineCard(title: "Respiratory rate", unit: "rpm", series: resp, gradient: TrendWindow.gradient(StrandPalette.metricCyan),
                                      valueRange: TrendWindow.valueRange(resp.points, fallback: 10...20), format: oneDecimal,
                                      note: "NOOP values are experimental")
                    }
                    if !spo2.points.isEmpty {
                        TrendLineCard(title: "Blood oxygen", unit: "%", series: spo2, gradient: TrendWindow.gradient(StrandPalette.metricCyan),
                                      valueRange: TrendWindow.valueRange(spo2.points, fallback: 90...100), format: oneDecimal)
                    }
                    if !temp.points.isEmpty {
                        TrendLineCard(title: "Skin temperature", unit: "°C", series: temp, gradient: TrendWindow.gradient(StrandPalette.metricAmber),
                                      valueRange: TrendWindow.valueRange(temp.points, fallback: -1...1), format: oneDecimal)
                    }
                }
            }
        }
    }
}

// MARK: Activity

/// Load and movement over time: day strain, stored workouts, and Apple Health steps and energy when imported.
struct ActivityTrendsView: View {
    @EnvironmentObject var repo: Repository
    @State private var workouts: [WorkoutRow] = []
    @State private var apple: [AppleDaily] = []
    @State private var loaded = false

    var body: some View {
        ActivityTrendsContent(days: repo.days, workouts: workouts, apple: apple, loaded: loaded && repo.loaded)
            .task(id: repo.dataVersion) {
                workouts = await repo.workoutRows()
                apple = await repo.appleDailyRows()
                loaded = true
            }
    }
}

struct ActivityTrendsContent: View {
    let days: [DailyMetric]
    let workouts: [WorkoutRow]
    let apple: [AppleDaily]
    let loaded: Bool
    @State private var range: TrendRange = .month

    /// The latest day any activity source reaches.
    private var anchor: Date? {
        let latest = [days.last?.day, apple.map(\.day).max(),
                      workouts.map(\.startTs).max().map(AnalyticsEngine.dayString)].compactMap { $0 }.max()
        return latest.flatMap(TrendWindow.date)
    }

    private func appleSeries(_ value: (AppleDaily) -> Double?, anchor: Date?) -> TrendSeries {
        let all = apple.compactMap { a -> TrendPoint? in
            guard let v = value(a), let d = TrendWindow.date(a.day) else { return nil }
            return TrendPoint(date: d, value: v)
        }.sorted { $0.date < $1.date }
        return TrendWindow.resolve(all, range: range, anchor: anchor)
    }

    private static func thousands(_ v: Double) -> String { Int(v.rounded()).formatted() }

    var body: some View {
        ScreenScaffold(title: "Activity trends") {
            let anchor = self.anchor
            let strain = TrendWindow.series(days, { $0.strain }, range: range, anchor: anchor)
            let sessions = WorkoutWindow(workouts: workouts, range: range, anchor: anchor)
            let steps = appleSeries({ $0.steps.map(Double.init) }, anchor: anchor)
            let energy = appleSeries({ $0.activeKcal }, anchor: anchor)

            if strain.points.isEmpty && workouts.isEmpty && steps.points.isEmpty && energy.points.isEmpty {
                ComingSoon(what: loaded ? "No activity stored yet. Day strain and workouts appear as the strap records, or import your WHOOP export or Apple Health in Settings → Data."
                                        : "Loading your activity…")
            } else {
                TrendRangeBar(range: $range, sparseNote: strain.widened ? strain.caption : nil)
                summary(strain: strain, sessions: sessions, steps: steps, energy: energy)
                TrendLineCard(title: "Day strain", unit: "", series: strain, gradient: StrandPalette.strainGradient,
                              valueRange: 0...21, format: { String(format: "%.1f", $0) },
                              note: "cardiovascular load, awake time")
                charts(sessions: sessions, steps: steps, energy: energy)
            }
        }
    }

    private func summary(strain: TrendSeries, sessions: WorkoutWindow, steps: TrendSeries, energy: TrendSeries) -> some View {
        TrendSummaryRow {
            TrendStat(label: "Average strain", value: strain.mean.map { String(format: "%.1f", $0) }, unit: "/ 21",
                      caption: strain.points.isEmpty ? "Not recorded" : "per day",
                      symbol: "flame.fill", accent: StrandPalette.zone4)
            TrendStat(label: "Workouts", value: "\(sessions.rows.count)", caption: sessions.rows.isEmpty ? "None stored" : sessions.effective.subtitle,
                      symbol: "figure.run", accent: StrandPalette.statusPositive)
            TrendStat(label: "Workout time", value: sessions.rows.isEmpty ? nil : DayMath.hm(sessions.totalMinutes), caption: sessions.topActivity,
                      symbol: "stopwatch.fill", accent: StrandPalette.metricAmber)
            if !steps.points.isEmpty {
                TrendStat(label: "Average steps", value: steps.mean.map(Self.thousands), caption: "Apple Health",
                          symbol: "shoeprints.fill", accent: StrandPalette.accent)
            } else if !energy.points.isEmpty {
                TrendStat(label: "Active energy", value: energy.mean.map(Self.thousands), unit: "kcal", caption: "Apple Health",
                          symbol: "bolt.heart.fill", accent: StrandPalette.metricRose)
            }
        }
    }

    private func workoutsCard(_ sessions: WorkoutWindow) -> some View {
        TrendCard(title: "Workouts per week", caption: sessions.caption,
                  value: sessions.weeks.isEmpty ? nil : String(format: "%.1f", sessions.averagePerWeek), valueLabel: "average, active weeks",
                  accent: StrandPalette.metricAmber) {
            if sessions.weeks.count >= 2 {
                WeeklyWorkoutChart(weeks: sessions.weeks)
            } else {
                TrendEmptyChart(count: sessions.weeks.count, one: "One active week so far", none: "No sessions in this window",
                                needs: "A trend needs at least two weeks.")
            }
        } footer: {
            TrendFooter([("Sessions", "\(sessions.rows.count)"), ("Active weeks", "\(sessions.weeks.count)"),
                         ("Longest", sessions.longestMinutes.map(DayMath.hm) ?? "—")], accent: StrandPalette.metricAmber)
        }
    }

    @ViewBuilder
    private func charts(sessions: WorkoutWindow, steps: TrendSeries, energy: TrendSeries) -> some View {
        if steps.points.isEmpty && energy.points.isEmpty {
            workoutsCard(sessions)
            Text("Steps and active energy appear here after an Apple Health import in Settings → Data.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        } else {
            LazyVGrid(columns: trendCardColumns, alignment: .leading, spacing: NoopMetrics.gap) {
                workoutsCard(sessions)
                if !steps.points.isEmpty {
                    TrendLineCard(title: "Steps", unit: "", series: steps, gradient: TrendWindow.gradient(StrandPalette.statusPositive),
                                  valueRange: TrendWindow.valueRange(steps.points, fallback: 0...20_000), format: Self.thousands, note: "Apple Health")
                }
                if !energy.points.isEmpty {
                    TrendLineCard(title: "Active energy", unit: "kcal", series: energy, gradient: TrendWindow.gradient(StrandPalette.metricAmber),
                                  valueRange: TrendWindow.valueRange(energy.points, fallback: 0...1_000), format: Self.thousands, note: "Apple Health")
                }
            }
        }
    }
}

/// Stored workouts in a window, by week. Only stored sessions count, so a week with no bar means none is stored.
struct WorkoutWindow {
    struct Week: Identifiable {
        let start: Date
        let count: Int
        var id: Date { start }
    }

    let rows: [WorkoutRow]
    let weeks: [Week]
    let effective: TrendRange
    let caption: String

    init(workouts: [WorkoutRow], range: TrendRange, anchor: Date?) {
        let dated = workouts.compactMap { w in TrendWindow.date(AnalyticsEngine.dayString(w.startTs)).map { (w, $0) } }
            .sorted { $0.1 < $1.1 }
        let series = TrendWindow.resolve(dated.map { TrendPoint(date: $0.1, value: 1) }, range: range, anchor: anchor)
        let first = series.points.first?.date
        let kept = dated.filter { d in first.map { d.1 >= $0 } ?? false }
        rows = kept.map(\.0)
        effective = series.effective
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        let grouped = Dictionary(grouping: kept) { cal.dateInterval(of: .weekOfYear, for: $0.1)?.start ?? $0.1 }
        weeks = grouped.keys.sorted().map { Week(start: $0, count: grouped[$0]!.count) }
        let unit = kept.count == 1 ? "session" : "sessions"
        caption = kept.isEmpty ? "No sessions stored" : series.widened ? "\(kept.count) \(unit) · sparse — widened to \(series.effective.name)" : "\(kept.count) \(unit) · \(range.name)"
    }

    private func minutes(_ w: WorkoutRow) -> Double { (w.durationS ?? Double(max(w.endTs - w.startTs, 0))) / 60 }
    var totalMinutes: Double { rows.map(minutes).reduce(0, +) }
    var longestMinutes: Double? { rows.map(minutes).max() }
    var averagePerWeek: Double { weeks.isEmpty ? 0 : Double(rows.count) / Double(weeks.count) }
    /// The most common activity, or a plain count when none is named.
    var topActivity: String {
        let named = rows.map(\.sport).filter { $0 != ActivityType.unknown.displayName }
        guard let top = Dictionary(grouping: named, by: { $0 }).max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.key
        else { return rows.isEmpty ? "None stored" : "Activity types not set" }
        return "Mostly \(top)"
    }
}

private struct WeeklyWorkoutChart: View {
    let weeks: [WorkoutWindow.Week]

    var body: some View {
        Chart(weeks) { w in
            BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Workouts", w.count))
                .foregroundStyle(LinearGradient(colors: [StrandPalette.metricAmber, StrandPalette.metricAmber.opacity(0.55)],
                                                startPoint: .top, endPoint: .bottom))
                .cornerRadius(weeks.count > 20 ? 3 : 8, style: .continuous)
        }
        .chartXAxis { SoftAxis.x(count: 4) }
        .chartYAxis { SoftAxis.y(count: 3) }
        .accessibilityLabel("Workouts per week")
    }
}

/// Axis marks for the bar charts, matching `TrendChart`'s soft style: dashed light grid, rounded labels.
enum SoftAxis {
    private static let font = Font.system(size: 11, weight: .medium, design: .rounded)
    private static let grid = StrokeStyle(lineWidth: 0.6, dash: [2, 4])

    static func x(count: Int) -> some AxisContent {
        AxisMarks(preset: .aligned, values: .automatic(desiredCount: count)) { _ in
            AxisValueLabel().font(font).foregroundStyle(StrandPalette.textTertiary)
        }
    }
    static func y(count: Int) -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: count)) { _ in
            AxisGridLine(stroke: grid).foregroundStyle(StrandPalette.hairline.opacity(0.6))
            AxisValueLabel().font(font).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

// MARK: Tab switcher

/// Sleep, Vitals and Activity each hold a trend page and the screen they always had. Same control, same place in each.
struct TrendTabSwitcher<Trends: View, Detail: View>: View {
    let storageKey: String
    let detailTitle: String
    @ViewBuilder var trends: () -> Trends
    @ViewBuilder var detail: () -> Detail
    @AppStorage private var showDetail: Bool

    init(storageKey: String, detailTitle: String, @ViewBuilder trends: @escaping () -> Trends, @ViewBuilder detail: @escaping () -> Detail) {
        self.storageKey = storageKey; self.detailTitle = detailTitle; self.trends = trends; self.detail = detail
        _showDetail = AppStorage(wrappedValue: false, storageKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $showDetail) {
                Text("Trends").tag(false)
                Text(detailTitle).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            .padding(.horizontal, NoopMetrics.screenPadding).padding(.top, 2).padding(.bottom, 4)
            .frame(maxWidth: NoopMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            if showDetail { detail() } else { trends() }
        }
    }
}

// MARK: Layouts

/// Children of equal width and equal height: all in one row while each keeps `minWidth`, else `fallbackColumns` to a row.
/// Height follows the tallest child's content, so a card never clips and never pads out with blank space. Decides from
/// the width actually offered: `ViewThatFits` compares ideal widths, which gave up on rows that fit comfortably.
struct EqualRowLayout: Layout {
    var minWidth: CGFloat
    var fallbackColumns: Int
    var spacing: CGFloat

    private func columns(_ width: CGFloat, count: Int) -> Int {
        let oneRow = CGFloat(count) * minWidth + CGFloat(count - 1) * spacing
        return width >= oneRow ? count : max(1, min(fallbackColumns, count))
    }

    private func cellWidth(_ width: CGFloat, columns: Int) -> CGFloat {
        (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    }

    /// Height of each row, top to bottom.
    private func rowHeights(_ subviews: Subviews, width: CGFloat, columns: Int) -> [CGFloat] {
        let cell = ProposedViewSize(width: cellWidth(width, columns: columns), height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(cell).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(subviews.count) * minWidth
        let rows = rowHeights(subviews, width: width, columns: columns(width, count: subviews.count))
        return CGSize(width: width, height: rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cols = columns(bounds.width, count: subviews.count), cell = cellWidth(bounds.width, columns: cols)
        var y = bounds.minY
        for (r, height) in rowHeights(subviews, width: bounds.width, columns: cols).enumerated() {
            for c in 0..<cols where r * cols + c < subviews.count {
                subviews[r * cols + c].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (cell + spacing), y: y), anchor: .topLeading,
                                             proposal: ProposedViewSize(width: cell, height: height))
            }
            y += height + spacing
        }
    }
}

/// Three score cards, aligned side by side while each keeps a readable width, stacked when they can't.
struct ScoreCardRow<First: View, Second: View, Third: View>: View {
    /// Narrowest a card reads well: its 150-point ring and full chip labels, plus card padding.
    private static var minCardWidth: CGFloat { 200 }

    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second
    @ViewBuilder var third: () -> Third

    var body: some View {
        EqualRowLayout(minWidth: Self.minCardWidth, fallbackColumns: 1, spacing: NoopMetrics.gap) {
            first(); second(); third()
        }
    }
}

/// A fixed-width summary beside a chart that fills the rest and matches its height; stacked when too narrow for both.
struct SummaryChartLayout: Layout {
    private let summaryWidth: CGFloat = 300, minChartWidth: CGFloat = 280, minChartHeight: CGFloat = 180
    private let columnGap: CGFloat = 24, rowGap: CGFloat = 16

    private func sideBySide(_ width: CGFloat) -> Bool { width >= summaryWidth + columnGap + minChartWidth }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? summaryWidth + columnGap + minChartWidth
        guard let summary = subviews.first else { return CGSize(width: width, height: 0) }
        if sideBySide(width) {
            let h = summary.sizeThatFits(ProposedViewSize(width: summaryWidth, height: nil)).height
            return CGSize(width: width, height: max(h, minChartHeight))
        }
        let h = summary.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: h + rowGap + minChartHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let summary = subviews[0], chart = subviews[1]
        if sideBySide(bounds.width) {
            summary.place(at: bounds.origin, proposal: ProposedViewSize(width: summaryWidth, height: bounds.height))
            chart.place(at: CGPoint(x: bounds.minX + summaryWidth + columnGap, y: bounds.minY),
                        proposal: ProposedViewSize(width: bounds.width - summaryWidth - columnGap, height: bounds.height))
        } else {
            let h = summary.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            summary.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: h))
            chart.place(at: CGPoint(x: bounds.minX, y: bounds.minY + h + rowGap),
                        proposal: ProposedViewSize(width: bounds.width, height: minChartHeight))
        }
    }
}
