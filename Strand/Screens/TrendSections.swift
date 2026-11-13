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
    /// Daily series: a missing day (> 1 day between readings, with slack for DST-free UTC day keys) breaks the line.
    static let dailyGap: TimeInterval = 1.5 * 86_400

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

    /// The selected window against the equal window before it (`TrendPeriodComparison` holds the rule). Nil for "all
    /// history". Uses the series' effective range, so a widened window compares like with like.
    static func change(_ days: [DailyMetric], _ value: (DailyMetric) -> Double?, series: TrendSeries, anchor: Date?,
                       unit: String, tolerance: Double, format: @escaping (Double) -> String) -> TrendChange? {
        let all = days.compactMap { d -> (date: Date, value: Double)? in
            guard let v = value(d), let dt = date(d.day) else { return nil }
            return (dt, v)
        }
        return change(all, range: series.effective, anchor: anchor, unit: unit, tolerance: tolerance, format: format)
    }

    static func change(_ all: [(date: Date, value: Double)], range: TrendRange, anchor: Date?, unit: String, tolerance: Double,
                       format: @escaping (Double) -> String) -> TrendChange? {
        guard let n = range.days, let anchor,
              let c = TrendPeriodComparison.compare(all, days: n, latest: anchor, today: date(AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970))),
                                                    tolerance: tolerance) else { return nil }
        return TrendChange(comparison: c, unit: unit, format: format)
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
            // Quiet range filter: sits on the page (hairline + accent wash), one step below the section tabs and the
            // Trends/detail switch, so the three levels never compete. Wraps under the subtitle when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { control; Spacer(minLength: 12); subtitle }
                VStack(alignment: .leading, spacing: 6) { control; subtitle }
            }
            if let sparseNote {
                Label(sparseNote, systemImage: "calendar.badge.clock")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarningInk)
                    .accessibilityLabel(sparseNote)
            }
        }
    }
}

extension TrendRangeBar {
    private var control: some View {
        SegmentedPillControl(TrendRange.allCases, selection: $range, title: "Time range", appearance: .quiet,
                             spokenLabel: { $0.name.prefix(1).uppercased() + $0.name.dropFirst() }) { $0.label }
            .accessibilityHint("Use the left and right arrow keys to change the range")
    }
    private var subtitle: some View { Text(range.subtitle).strandOverline() }
}

/// One period comparison in words: direction, difference with its unit, and both periods. Neutral: up is not "better".
struct TrendChange {
    let comparison: TrendPeriodComparison
    let unit: String
    let format: (Double) -> String

    private static func span(_ a: Date, _ b: Date) -> String {
        // Day dates are UTC midnights (see `TrendWindow.date`), so format them in UTC.
        var f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        f.timeZone = TimeZone(identifier: "UTC")!
        return "\(a.formatted(f))–\(b.formatted(f))"
    }
    private var unitSuffix: String { unit.isEmpty ? "" : " \(unit)" }

    var symbol: String {
        switch comparison.direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .unchanged: return "equal"
        case .insufficient: return "ellipsis"
        }
    }
    /// Short line for the stat bubble.
    var text: String {
        let prior = "vs prior \(comparison.days) d"
        switch comparison.direction {
        case .up, .down:
            let d = comparison.delta ?? 0
            return "\(d > 0 ? "+" : "−")\(format(abs(d)))\(unitSuffix) \(prior)"
        case .unchanged: return "About the same \(prior)"
        case .insufficient: return "Not enough data to compare"
        }
    }
    /// Both periods spelled out, for the tooltip and VoiceOver.
    var detail: String {
        let cur = "\(Self.span(comparison.currentStart, comparison.currentEnd)) (\(comparison.currentCount) days with data)"
        let prev = "\(Self.span(comparison.previousStart, comparison.previousEnd)) (\(comparison.previousCount) days with data)"
        let means = [comparison.currentMean, comparison.previousMean].map { $0.map { format($0) + unitSuffix } ?? "no data" }
        let head: String = switch comparison.direction {
        case .up: "Up"
        case .down: "Down"
        case .unchanged: "About the same"
        case .insufficient: "Not enough data to compare"
        }
        return "\(head). Average \(means[0]) for \(cur), compared with \(means[1]) for \(prev). Completed days only; missing days are not counted as zero."
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
    /// Against the preceding period; nil for none (e.g. all history).
    var change: TrendChange? = nil

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
                if let change {
                    Label(change.text, systemImage: change.symbol)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(StrandPalette.textSecondary)   // neutral on purpose: direction is not a verdict
                        .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                        .help(change.detail)
                        .accessibilityLabel(change.detail)
                }
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
                // In a `TrendCardGrid` row a card is stretched to the tallest card; the spacer keeps footers level.
                Spacer(minLength: 0)
                footer()
            }
            .frame(maxHeight: .infinity, alignment: .top)
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
                    // Shrinks a little before it truncates ("Active weeks" was cut to "Active wee…" in a 3-up row).
                    Text(it.0).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    Text(it.1).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(2).minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
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
                           valueFormat: { unit.isEmpty ? format($0) : "\(format($0)) \(unit)" }, style: .soft,
                           maxGap: TrendWindow.dailyGap)
            } else {
                TrendEmptyChart(count: series.points.count)
            }
        } footer: {
            TrendFooter([("Low", series.low.map(format) ?? "—"), ("High", series.high.map(format) ?? "—"),
                         ("Days", "\(series.points.count)")], accent: accent)
        }
    }
}

/// Trend cards in as many ≥ 320 pt columns as fit, every card in a row as tall as the tallest one. A `LazyVGrid`
/// left cards whose captions wrap (Respiratory rate, Skin temperature change) taller than their neighbours, with
/// footers at different heights (#18 audit).
struct TrendCardGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { TrendCardGridLayout(minWidth: 320, spacing: NoopMetrics.gap) { content() } }
}

struct TrendCardGridLayout: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat

    func columns(_ width: CGFloat, count: Int) -> Int {
        max(1, min(count, Int((width + spacing) / (minWidth + spacing))))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (cols: Int, cell: CGFloat, heights: [CGFloat]) {
        let cols = columns(width, count: subviews.count)
        let cell = (width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        let heights = stride(from: 0, to: subviews.count, by: cols).map { start in
            subviews[start..<min(start + cols, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
        }
        return (cols, cell, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minWidth
        let r = rows(subviews, width: width)
        return CGSize(width: width, height: r.heights.reduce(0, +) + CGFloat(max(0, r.heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in r.heights.enumerated() {
            for c in 0..<r.cols where row * r.cols + c < subviews.count {
                subviews[row * r.cols + c].place(at: CGPoint(x: bounds.minX + CGFloat(c) * (r.cell + spacing), y: y),
                                                 anchor: .topLeading, proposal: ProposedViewSize(width: r.cell, height: height))
            }
            y += height + spacing
        }
    }
}

// MARK: Sleep

/// Sleep over time: how long, how efficiently, and how the stages split.
struct SleepTrendsView: View {
    @EnvironmentObject var repo: Repository
    var body: some View { SleepTrendsContent(days: repo.days, loaded: repo.loaded, noopDays: Array(repo.estimates.values)) }
}

struct SleepTrendsContent: View {
    let days: [DailyMetric]
    let loaded: Bool
    /// Computed NOOP rows only; imported need/performance never enters this estimate.
    var noopDays: [DailyMetric] = []
    @State private var range: TrendRange

    /// `initialRange` lets previews and render checks open on any range (the control still changes it).
    init(days: [DailyMetric], loaded: Bool, noopDays: [DailyMetric] = [], initialRange: TrendRange = .month) {
        self.days = days; self.loaded = loaded; self.noopDays = noopDays
        _range = State(initialValue: initialRange)
    }

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
                let change = { (v: @escaping (DailyMetric) -> Double?, s: TrendSeries, unit: String, tol: Double, f: @escaping (Double) -> String) in
                    TrendWindow.change(days, v, series: s, anchor: anchor, unit: unit, tolerance: tol, format: f)
                }
                TrendSummaryRow {
                    TrendStat(label: "Average asleep", value: duration.mean.map(Self.hoursText), caption: "per night",
                              symbol: "bed.double.fill", accent: StrandPalette.sleepLight,
                              change: change({ $0.totalSleepMin.map { $0 / 60 } }, duration, "", 10.0 / 60, Self.hoursText))
                    TrendStat(label: "Efficiency", value: efficiency.mean.map { String(format: "%.0f", $0) }, unit: "%",
                              caption: efficiency.points.isEmpty ? "Not recorded" : "average",
                              symbol: "checkmark.seal.fill", accent: StrandPalette.statusPositive,
                              change: change({ $0.efficiency }, efficiency, "%", 1, { String(format: "%.0f", $0) }))
                    TrendStat(label: "Deep + REM", value: restorative.mean.map(DayMath.hm),
                              caption: restorative.points.isEmpty ? "Not recorded" : "per night",
                              symbol: "moon.stars.fill", accent: StrandPalette.sleepDeep,
                              change: change({ d in d.deepMin.flatMap { a in d.remMin.map { a + $0 } } }, restorative, "", 10, DayMath.hm))
                    TrendStat(label: "Nights", value: "\(duration.points.count)", caption: duration.effective.subtitle,
                              symbol: "calendar", accent: StrandPalette.sleepREM)
                }
                TrendLineCard(title: "Time asleep", unit: "", series: duration, gradient: TrendWindow.gradient(StrandPalette.sleepLight),
                              valueRange: TrendWindow.valueRange(duration.points, fallback: 4...10), format: Self.hoursText, note: "hours")
                TrendCardGrid {
                    let perf = TrendWindow.resolve(SleepPerformance.series(noopDays).compactMap { p in
                        TrendWindow.date(p.day).map { TrendPoint(date: $0, value: p.value) } }, range: range, anchor: anchor)
                    TrendLineCard(title: "Sleep performance", unit: "%", series: perf, gradient: TrendWindow.gradient(StrandPalette.sleepLight),
                                  valueRange: 0...100, note: "NOOP estimate · hours vs estimated need")
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
        // A few nightly bars: one day label each (automatic ticks put colliding "Nov 10 at 12 PM" labels between them).
        .chartXAxis {
            if !window.weekly && window.buckets.count <= 7 { SoftAxis.x(at: window.buckets.map(\.date)) }
            else { SoftAxis.x(count: 4, dates: window.buckets.map(\.date)) }
        }
        // Bars are binned on UTC calendar days: label the axis in UTC too, or a day reads as the evening before.
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
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
    var body: some View {
        VitalsTrendsContent(days: repo.days, loaded: repo.loaded,
                            importedDays: Array(repo.official.values), noopDays: Array(repo.estimates.values))
    }
}

struct VitalsTrendsContent: View {
    let days: [DailyMetric]
    let loaded: Bool
    /// Skin temperature is two different quantities: WHOOP's export is absolute wrist °C, NOOP stores a change from
    /// baseline. The merged `days` field mixes them, so each source gets its own card and series.
    var importedDays: [DailyMetric] = []
    var noopDays: [DailyMetric] = []
    @State private var range: TrendRange

    init(days: [DailyMetric], loaded: Bool, importedDays: [DailyMetric] = [], noopDays: [DailyMetric] = [],
         initialRange: TrendRange = .month) {
        self.days = days; self.loaded = loaded; self.importedDays = importedDays; self.noopDays = noopDays
        _range = State(initialValue: initialRange)
    }

    private func series(_ value: (DailyMetric) -> Double?) -> TrendSeries {
        TrendWindow.series(days, value, range: range, anchor: days.last.flatMap { TrendWindow.date($0.day) })
    }

    var body: some View {
        ScreenScaffold(title: "Vitals trends") {
            let rhr = series { $0.restingHr.map(Double.init) }, hrv = series { $0.avgHrv }
            let resp = series { $0.respRateBpm }, spo2 = series { $0.spo2Pct }, temp = TrendWindow.series(importedDays.sorted { $0.day < $1.day }, { $0.skinTempDevC }, range: range,
                                                                       anchor: days.last.flatMap { TrendWindow.date($0.day) })
            let tempChange = TrendWindow.series(noopDays.sorted { $0.day < $1.day }, { $0.skinTempDevC }, range: range,
                                                anchor: days.last.flatMap { TrendWindow.date($0.day) })
            let oneDecimal: (Double) -> String = { String(format: "%.1f", $0) }

            if [rhr, hrv, resp, spo2, temp, tempChange].allSatisfy(\.points.isEmpty) {
                ComingSoon(what: loaded ? "No vitals stored yet. They appear after a night of wear, or import your WHOOP export in Settings → Data."
                                        : "Loading your history…")
            } else {
                let lead = [rhr, hrv].first { !$0.points.isEmpty } ?? resp
                TrendRangeBar(range: $range, sparseNote: lead.widened ? lead.caption : nil)
                let anchor = days.last.flatMap { TrendWindow.date($0.day) }
                let whole: (Double) -> String = { "\(Int($0.rounded()))" }
                let change = { (v: @escaping (DailyMetric) -> Double?, s: TrendSeries, unit: String, tol: Double, f: @escaping (Double) -> String) in
                    TrendWindow.change(days, v, series: s, anchor: anchor, unit: unit, tolerance: tol, format: f)
                }
                TrendSummaryRow {
                    TrendStat(label: "Resting HR", value: rhr.mean.map { "\(Int($0.rounded()))" }, unit: "bpm", caption: rhr.points.isEmpty ? "Not recorded" : "average",
                              symbol: "heart.fill", accent: StrandPalette.metricRose,
                              change: change({ $0.restingHr.map(Double.init) }, rhr, "bpm", 1, whole))
                    TrendStat(label: "HRV", value: hrv.mean.map { "\(Int($0.rounded()))" }, unit: "ms", caption: hrv.points.isEmpty ? "Not recorded" : "average",
                              symbol: "waveform.path.ecg", accent: StrandPalette.metricPurple,
                              change: change({ $0.avgHrv }, hrv, "ms", 2, whole))
                    TrendStat(label: "Respiration", value: resp.mean.map(oneDecimal), unit: "rpm", caption: resp.points.isEmpty ? "Not recorded" : "average",
                              symbol: "lungs.fill", accent: StrandPalette.metricCyan,
                              change: change({ $0.respRateBpm }, resp, "rpm", 0.3, oneDecimal))
                    TrendStat(label: "Blood oxygen", value: spo2.mean.map(oneDecimal), unit: "%", caption: spo2.points.isEmpty ? "Not recorded" : "average",
                              symbol: "drop.fill", accent: StrandPalette.accent,
                              change: change({ $0.spo2Pct }, spo2, "%", 0.5, oneDecimal))
                }
                TrendCardGrid {
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
                                      valueRange: TrendWindow.valueRange(temp.points, fallback: 30...36), format: oneDecimal,
                                      note: "WHOOP import, wrist °C")
                    }
                    if !tempChange.points.isEmpty {
                        TrendLineCard(title: "Skin temperature change", unit: "°C", series: tempChange, gradient: TrendWindow.gradient(StrandPalette.metricAmber),
                                      valueRange: TrendWindow.valueRange(tempChange.points, fallback: -1...1), format: { String(format: "%+.1f", $0) },
                                      note: "NOOP, vs your baseline")
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
    @State private var loads: [DayLoadRecord] = []
    @State private var loaded = false

    var body: some View {
        ActivityTrendsContent(days: repo.days, workouts: workouts, apple: apple, loads: loads, loaded: loaded && repo.loaded)
            .task(id: repo.dataVersion) {
                workouts = await repo.workoutRows()
                apple = await repo.appleDailyRows()
                loads = await repo.dayLoads(from: "0000-00-00", to: "9999-99-99")
                loaded = true
            }
    }
}

struct ActivityTrendsContent: View {
    let days: [DailyMetric]
    let workouts: [WorkoutRow]
    let apple: [AppleDaily]
    var loads: [DayLoadRecord] = []
    let loaded: Bool
    @State private var range: TrendRange

    init(days: [DailyMetric], workouts: [WorkoutRow], apple: [AppleDaily], loads: [DayLoadRecord] = [], loaded: Bool,
         initialRange: TrendRange = .month) {
        self.days = days; self.workouts = workouts; self.apple = apple; self.loads = loads; self.loaded = loaded
        _range = State(initialValue: initialRange)
    }

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

    /// Scored days inside the same window the strain chart shows.
    private func zoneWindow(_ r: TrendRange, anchor: Date?) -> [DayLoadRecord] {
        guard let n = r.days else { return loads }
        guard let anchor else { return [] }
        let cutoff = anchor.addingTimeInterval(-Double(n - 1) * 86_400)
        return loads.filter { TrendWindow.date($0.day).map { $0 >= cutoff && $0 <= anchor } ?? false }
    }

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
                ZoneTotalsCard(totals: ZoneTotals.sum(zoneWindow(strain.effective, anchor: anchor)), range: strain.effective)
                charts(sessions: sessions, steps: steps, energy: energy)
            }
        }
    }

    private func summary(strain: TrendSeries, sessions: WorkoutWindow, steps: TrendSeries, energy: TrendSeries) -> some View {
        TrendSummaryRow {
            TrendStat(label: "Average strain", value: strain.mean.map { String(format: "%.1f", $0) }, unit: "/ 21",
                      caption: strain.points.isEmpty ? "Not recorded" : "per day",
                      symbol: "flame.fill", accent: StrandPalette.zone4,
                      change: TrendWindow.change(days, { $0.strain }, series: strain, anchor: anchor, unit: "", tolerance: 0.5,
                                                 format: { String(format: "%.1f", $0) }))
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
            TrendCardGrid {
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

/// Time in Zones 1–5 over the window, from NOOP's scored awake heart-rate seconds, as one zone spectrum (the same design
/// as the Strain detail, compact). Zone 0 is left out on purpose, and unrecorded time and sleep are in no zone, so the
/// slices are shares of Zones 1–5 time, never of the whole window.
struct ZoneTotalsCard: View {
    let totals: ZoneTotals
    let range: TrendRange

    var body: some View {
        TrendCard(title: "Time in heart-rate zones", caption: "Zones 1–5 · \(range.subtitle.lowercased()) · \(totals.days) scored day\(totals.days == 1 ? "" : "s")",
                  value: totals.days == 0 ? nil : DayMath.hm(Double(totals.totalS) / 60), valueLabel: "Zones 1–5 total",
                  height: 150, accent: StrandPalette.zone3) {
            if totals.days == 0 {
                TrendEmptyChart(count: 0, none: "No scored days in this window",
                                needs: "Zone time comes from days NOOP scored from the strap's heart rate.")
            } else {
                ZoneSpectrum((1...5).map { ZoneSpectrumSegment(zone: $0, seconds: totals.seconds[$0 - 1]) }, size: .compact)
            }
        } footer: {
            Text("Awake heart-rate time NOOP scored; shares are of Zones 1–5 time. Unrecorded time and sleep are in no zone; Zone 0 isn't shown.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
        .chartXAxis {
            if weeks.count <= 6 { SoftAxis.x(at: weeks.map(\.start)) } else { SoftAxis.x(count: 4, dates: weeks.map(\.start)) }
        }
        // Bars are binned on UTC calendar days: label the axis in UTC too, or a day reads as the evening before.
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
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
    /// Date axis matching `TrendChart`: "MMM 'yy" once the span reaches ~300 days (the automatic labels read
    /// "Dec 2025" here and "Dec '25" on the line charts beside it), else the automatic labels.
    @AxisContentBuilder
    static func x(count: Int, dates: [Date]) -> some AxisContent {
        if let first = dates.min(), let last = dates.max(), last.timeIntervalSince(first) >= 300 * 86_400 {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: count)) { value in
                AxisValueLabel { Text(value.as(Date.self).map { yearMonth.string(from: $0) } ?? "") }
                    .font(font).foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: count)) { _ in
                AxisValueLabel().font(font).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
    /// One label per bar (a few weekly bars): automatic ticks labelled the end of the last week, past the range.
    static func x(at dates: [Date]) -> some AxisContent {
        AxisMarks(preset: .aligned, values: dates) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(font).foregroundStyle(StrandPalette.textTertiary)
        }
    }
    private static let yearMonth: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM ''yy"
        f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
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
            SegmentedPillControl([false, true], selection: $showDetail, title: "View", controlSize: .small) { $0 ? detailTitle : "Trends" }
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
