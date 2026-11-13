import SwiftUI

// MARK: - Year Heat Strip (§9.4 Trends)
//
// A GitHub-style year grid: columns = weeks, rows = weekdays. Each cell is tinted
// by that day's recovery score via the signature recovery gradient. Empty days
// (no data) render as a faint inset square. Hover shows a tooltip via SwiftUI's
// built-in help.

/// A day's recovery datum for the heat strip.
public struct RecoveryDay: Identifiable, Sendable {
    public let id = UUID()
    public var date: Date
    /// Recovery 0...100, or nil if no data for that day.
    public var score: Double?

    public init(date: Date, score: Double?) {
        self.date = date
        self.score = score
    }
}

public struct YearHeatStrip: View {

    public var days: [RecoveryDay]
    public var cellSize: CGFloat
    public var spacing: CGFloat
    public var showsMonthLabels: Bool
    /// Whether hovering a cell highlights it with a ring and shows a tooltip
    /// (date + score + recovery state word). Defaults on.
    public var showsHover: Bool
    /// Formats a day's score for the tooltip's bold line.
    public var valueFormat: (Double) -> String

    public init(
        days: [RecoveryDay],
        cellSize: CGFloat = 12,
        spacing: CGFloat = 3,
        showsMonthLabels: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
    ) {
        self.days = days.sorted { $0.date < $1.date }
        self.cellSize = cellSize
        self.spacing = spacing
        self.showsMonthLabels = showsMonthLabels
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    // The grid layout constants used both for drawing and hover hit-testing.
    /// Width the strip is offered (measured), and the cell size that fits a year into it.
    @State private var offeredWidth: CGFloat?
    private static let minCell: CGFloat = 7
    /// `cellSize` when it fits; otherwise the largest cell ≥ `minCell` that shows every week. Below that the strip
    /// scrolls. A fixed 12 pt cell clipped the newest ~3 months off a 760 pt window (#18 audit).
    private func fittedCell(weeks: Int, width: CGFloat? = nil) -> CGFloat {
        guard let w = width ?? offeredWidth, weeks > 0 else { return cellSize }
        let fit = (w - gutterWidth - spacing - 1) / CGFloat(weeks) - spacing
        return max(Self.minCell, min(cellSize, fit.rounded(.down)))
    }
    /// Cached `fittedCell`, recomputed when the offered width or the week count changes.
    @State private var fitCell: CGFloat?
    private var cell: CGFloat { fitCell ?? cellSize }
    private let gutterWidth: CGFloat = 24
    private let monthLabelHeight: CGFloat = 10

    /// Hovered cell as (weekIndex, row), or nil.
    @State private var hoverCell: (week: Int, row: Int)? = nil

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday-first columns read nicely
        return c
    }

    // Group days into week columns. weekday 0 = Monday ... 6 = Sunday.
    private struct Week: Identifiable {
        let id = UUID()
        var cells: [RecoveryDay?] // length 7, indexed by weekday row
        var monthLabel: String?
    }

    // Lays days into week columns x weekday rows; leading/trailing blanks keep weekdays aligned.
    private func buildWeeks() -> [Week] {
        guard let first = days.map(\.date).min() else { return [] }
        var weeks: [Week] = []
        var current = Week(cells: Array(repeating: nil, count: 7), monthLabel: nil)
        var lastMonth = -1
        // Pad the first week so the first day lands on its weekday row.
        let firstRow = weekdayRow(first)
        var filledThisWeek = firstRow

        // Every calendar day from first to last, so a stretch with no data stays visible as empty cells instead of
        // collapsing the weeks around it together.
        let byDay = Dictionary(days.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { _, b in b })
        let start = calendar.startOfDay(for: days.map(\.date).min() ?? first)
        let end = calendar.startOfDay(for: days.map(\.date).max() ?? first)
        var filled: [RecoveryDay] = []
        var t = start
        while t <= end {
            filled.append(byDay[t] ?? RecoveryDay(date: t, score: nil))
            guard let next = calendar.date(byAdding: .day, value: 1, to: t) else { break }
            t = next
        }
        for day in filled {
            let row = weekdayRow(day.date)
            if row == 0 && filledThisWeek > 0 {
                weeks.append(current)
                current = Week(cells: Array(repeating: nil, count: 7), monthLabel: nil)
                filledThisWeek = 0
            }
            current.cells[row] = day
            // tag month label at the first cell of a new month
            let month = calendar.component(.month, from: day.date)
            if month != lastMonth {
                // Labels overflow their one-cell column, so keep them ≥ 3 weeks apart: a partial first month
                // ("Aug" on one week) would otherwise run into the next ("AugSep").
                let lastLabelled = weeks.lastIndex { $0.monthLabel != nil }
                if lastLabelled.map({ weeks.count - $0 >= 3 }) ?? true { current.monthLabel = monthShort(day.date) }
                else if let i = lastLabelled, weeks.count - i < 3, i == 0 { weeks[i].monthLabel = nil; current.monthLabel = monthShort(day.date) }
                lastMonth = month
            }
            filledThisWeek += 1
        }
        if filledThisWeek > 0 { weeks.append(current) }
        return weeks
    }

    private func weekdayRow(_ date: Date) -> Int {
        // Map Calendar weekday (1=Sun...7=Sat) to Monday-first 0...6.
        let wd = calendar.component(.weekday, from: date)
        return (wd + 5) % 7
    }

    private func monthShort(_ date: Date) -> String {
        let f = DateFormatterCache.month
        return f.string(from: date)
    }

    private let rowLabels = ["Mon", "", "Wed", "", "Fri", "", "Sun"]

    private static let trailingAnchor = "yearHeatStrip.trailing"

    /// Narrower than the grid (a 760 pt window), cells shrink to fit the whole year (≥ 7 pt); narrower still, the strip
    /// scrolls sideways and opens on the most recent weeks. A fixed frame used to clip them off the right edge.
    public var body: some View {
        let weeks = buildWeeks()
        let height = gridOriginY + 7 * (cell + spacing) - spacing
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    grid(weeks)
                    Color.clear.frame(width: 1, height: 1).id(Self.trailingAnchor)
                }
            }
            .frame(height: height)
            .background(GeometryReader { g in
                Color.clear.onAppear { offeredWidth = g.size.width; fitCell = fittedCell(weeks: weeks.count, width: g.size.width) }
                    .onChange(of: g.size.width) { offeredWidth = $0; fitCell = fittedCell(weeks: weeks.count, width: $0) }
            })
            .onAppear { proxy.scrollTo(Self.trailingAnchor, anchor: .trailing) }
            .onChange(of: weeks.count) { n in fitCell = fittedCell(weeks: n); proxy.scrollTo(Self.trailingAnchor, anchor: .trailing) }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func grid(_ weeks: [Week]) -> some View {
        // Total drawn size, so the hover overlay can be laid over the grid and
        // a tooltip can be clamped within bounds.
        let gridWidth = gridOriginX + CGFloat(weeks.count) * (cell + spacing) - spacing
        let gridHeight = gridOriginY + 7 * (cell + spacing) - spacing

        VStack(alignment: .leading, spacing: spacing) {
            if showsMonthLabels {
                HStack(spacing: spacing) {
                    // align with the weekday-label gutter
                    Color.clear.frame(width: gridOriginX - spacing, height: monthLabelHeight)
                    ForEach(weeks) { week in
                        // Ideal width, drawn over the next (label-less) weeks: a one-cell frame truncated "Sep" to "S…".
                        Text(week.monthLabel ?? "")
                            .font(.system(size: 8))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1).fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                }
                // Pin the row height: a label taller than `monthLabelHeight` pushed the grid down and the fixed-height
                // frame below then cut off the Sunday row.
                .frame(height: monthLabelHeight)
            }
            HStack(alignment: .top, spacing: spacing) {
                // weekday gutter
                VStack(alignment: .trailing, spacing: spacing) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(rowLabels[r])
                            .font(.system(size: 8))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: gutterWidth, height: cell, alignment: .trailing)
                    }
                }
                // week columns
                ForEach(Array(weeks.enumerated()), id: \.element.id) { weekIndex, week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cell(week.cells[row], isHovered: isHovered(weekIndex, row))
                        }
                    }
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .overlay(hoverOverlay(weeks: weeks, gridSize: CGSize(width: gridWidth, height: gridHeight)))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard showsHover else { return }
            switch phase {
            case .active(let location):
                hoverCell = cellIndex(at: location, weekCount: weeks.count)
            case .ended:
                hoverCell = nil
            }
        }
    }

    // MARK: Grid geometry

    /// x of the first week column (after the weekday gutter + HStack spacing).
    private var gridOriginX: CGFloat { gutterWidth + spacing }
    /// y of the first cell row (below the optional month-label row).
    private var gridOriginY: CGFloat { showsMonthLabels ? monthLabelHeight + spacing : 0 }

    private func isHovered(_ week: Int, _ row: Int) -> Bool {
        guard let h = hoverCell else { return false }
        return h.week == week && h.row == row
    }

    /// Map a local cursor location to a (week, row) cell, or nil if outside the
    /// grid or in the inter-cell gaps.
    // Hit-testing for hover: converts a cursor point back to (week, weekday).
    private func cellIndex(at point: CGPoint, weekCount: Int) -> (week: Int, row: Int)? {
        let stride = cell + spacing
        let lx = point.x - gridOriginX
        let ly = point.y - gridOriginY
        guard lx >= 0, ly >= 0 else { return nil }
        let week = Int(lx / stride)
        let row = Int(ly / stride)
        guard week >= 0, week < weekCount, row >= 0, row < 7 else { return nil }
        // Reject hits in the spacing gutter between cells.
        let withinX = lx - CGFloat(week) * stride
        let withinY = ly - CGFloat(row) * stride
        guard withinX <= cell, withinY <= cell else { return nil }
        return (week, row)
    }

    /// Centre of a cell in local coordinates.
    private func cellCenter(week: Int, row: Int) -> CGPoint {
        let stride = cell + spacing
        return CGPoint(
            x: gridOriginX + CGFloat(week) * stride + cell / 2,
            y: gridOriginY + CGFloat(row) * stride + cell / 2
        )
    }

    // MARK: Hover overlay (ring + tooltip)

    @ViewBuilder
    private func hoverOverlay(weeks: [Week], gridSize: CGSize) -> some View {
        if showsHover, let h = hoverCell, h.week < weeks.count,
           let day = weeks[h.week].cells[h.row], let score = day.score {
            let center = cellCenter(week: h.week, row: h.row)
            ZStack(alignment: .topLeading) {
                // subtle highlight ring on the hovered cell
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                    .frame(width: cell + 3, height: cell + 3)
                    .position(center)
                PositionedTooltip(
                    anchor: center,
                    container: gridSize,
                    tooltip: ChartTooltip(
                        value: valueFormat(score),
                        label: "\(DateFormatterCache.day.string(from: day.date)) · \(StrandPalette.recoveryState(score))",
                        accent: StrandPalette.recoveryColor(score)
                    )
                )
            }
            .animation(StrandMotion.fade, value: h.week)
            .animation(StrandMotion.fade, value: h.row)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func cell(_ day: RecoveryDay?, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2.5)
        if let day, let score = day.score {
            shape
                .fill(StrandPalette.recoveryColor(score))
                .frame(width: cell, height: cell)
                .opacity(isHovered ? 1.0 : (hoverCell == nil ? 1.0 : 0.78))
                .help("\(DateFormatterCache.day.string(from: day.date)) · recovery \(Int(score.rounded()))")
        } else if day != nil {
            shape
                .fill(StrandPalette.surfaceInset)
                .overlay(shape.stroke(StrandPalette.hairline.opacity(0.6), lineWidth: 0.5))
                .frame(width: cell, height: cell)
        } else {
            shape
                .fill(Color.clear)
                .frame(width: cell, height: cell)
        }
    }
}

// Small cached formatters (creating DateFormatter is expensive).
private enum DateFormatterCache {
    static let month: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}

#if DEBUG
private func sampleYear() -> [RecoveryDay] {
    let cal = Calendar.current
    let today = Date()
    return (0..<365).map { i in
        let date = cal.date(byAdding: .day, value: -(364 - i), to: today)!
        // Some gaps + a wavy recovery profile.
        let gap = (i % 23 == 0)
        let v = 55 + 28 * sin(Double(i) / 11.0) + Double((i * 31) % 17) - 8
        return RecoveryDay(date: date, score: gap ? nil : max(2, min(99, v)))
    }
}

#Preview("YearHeatStrip") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — past year").strandOverline()
        Text("Hover a cell: ring + date, score and recovery-state tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        YearHeatStrip(days: sampleYear())
    }
    .padding(28)
    .frame(width: 900, height: 240)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
