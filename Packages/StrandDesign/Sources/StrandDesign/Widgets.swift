import SwiftUI

// MARK: - Widget system
//
// Apple Health–style widgets: one elevated card, a quiet tinted header (SF Symbol + title), one
// primary metric, and optional secondary content. Three sizes share the same grid:
//
//   small  = 1 column  × 1 row
//   medium = 2 columns × 1 row
//   large  = 2 columns × 2 rows
//
// `WidgetGrid` packs them responsively: the column count follows the available width, and widgets
// fill the earliest hole so the layout never shows stray gaps.

public enum WidgetSize: Sendable {
    case small, medium, large

    var span: (cols: Int, rows: Int) {
        switch self {
        case .small:  return (1, 1)
        case .medium: return (2, 1)
        case .large:  return (2, 2)
        }
    }
}

// MARK: Layout

private struct WidgetSpanKey: LayoutValueKey {
    static let defaultValue: (cols: Int, rows: Int) = (1, 1)
}

public extension View {
    /// Declare how many grid cells this view spans inside a `WidgetGrid`.
    func widgetSize(_ size: WidgetSize) -> some View {
        layoutValue(key: WidgetSpanKey.self, value: size.span)
    }
}

// Custom Layout: packs small/medium/large widgets into a responsive column grid, first-fit, like Apple Health.
struct WidgetGridLayout: Layout {
    var minColumn: CGFloat
    var rowHeight: CGFloat
    var spacing: CGFloat

    // Column count follows available width.
    private func columns(for width: CGFloat) -> Int {
        max(2, Int((width + spacing) / (minColumn + spacing)))
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let cols = columns(for: width)
        let cell = (width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        var occupied: [[Bool]] = []

        func ensureRows(_ n: Int) {
            while occupied.count < n { occupied.append([Bool](repeating: false, count: cols)) }
        }
        // Checks whether a widget of w x h cells fits at row r, column c without overlapping.
        func fits(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= cols else { return false }
            ensureRows(r + h)
            for rr in r..<(r + h) { for cc in c..<(c + w) where occupied[rr][cc] { return false } }
            return true
        }

        var frames: [CGRect] = []
        for sub in subviews {
            let span = sub[WidgetSpanKey.self]
            let w = min(span.cols, cols), h = span.rows
            var placed = false
            var r = 0
            while !placed {
                for c in 0...(cols - w) where fits(r, c, w, h) {
                    for rr in r..<(r + h) { for cc in c..<(c + w) { occupied[rr][cc] = true } }
                    frames.append(CGRect(
                        x: CGFloat(c) * (cell + spacing),
                        y: CGFloat(r) * (rowHeight + spacing),
                        width: CGFloat(w) * cell + CGFloat(w - 1) * spacing,
                        height: CGFloat(h) * rowHeight + CGFloat(h - 1) * spacing))
                    placed = true
                    break
                }
                r += 1
            }
        }
        let rows = occupied.lastIndex(where: { $0.contains(true) }).map { $0 + 1 } ?? 0
        let height = rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing
        return (frames, height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640
        return CGSize(width: width, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (sub, f) in zip(subviews, result.frames) {
            sub.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// Responsive, gap-free grid for `StrandWidget`s. Mark each child with `.widgetSize(_:)` (a
/// `StrandWidget` does this for you via its `size`).
public struct WidgetGrid<Content: View>: View {
    private let content: Content
    private let minColumn: CGFloat
    private let rowHeight: CGFloat
    public init(minColumn: CGFloat = 176, rowHeight: CGFloat = 164, @ViewBuilder content: () -> Content) {
        self.minColumn = minColumn; self.rowHeight = rowHeight; self.content = content()
    }
    public var body: some View {
        WidgetGridLayout(minColumn: minColumn, rowHeight: rowHeight, spacing: NoopMetrics.gap) { content }
    }
}

// MARK: Container

/// The widget card: tinted symbol + title header, then free-form content. Optionally tappable.
public struct StrandWidget<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let size: WidgetSize
    var trailing: String?
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    public init(_ title: String, symbol: String, tint: Color, size: WidgetSize = .small,
                trailing: String? = nil, action: (() -> Void)? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.size = size
        self.trailing = trailing; self.action = action; self.content = content
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { card }
                    .buttonStyle(WidgetPressStyle())
            } else {
                card
            }
        }
        .widgetSize(size)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.28), in: Circle())
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.system(size: 12)).foregroundStyle(StrandPalette.textTertiary)
                }
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            content()
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .strandSurface()
        .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }
}

private struct WidgetPressStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: hovering && !configuration.isPressed ? -1 : 0)
            .shadow(color: StrandPalette.shadow.opacity(hovering ? 1 : 0), radius: 12, y: 6)
            .animation(StrandMotion.respecting(.easeOut(duration: 0.18)), value: configuration.isPressed)
            .animation(StrandMotion.respecting(.easeOut(duration: 0.18)), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: Content pieces

/// The primary metric: large number with a small unit, or a quiet em-dash when there's no data.
public struct WidgetValue: View {
    let value: String?
    let unit: String?
    var size: CGFloat
    public init(_ value: String?, unit: String? = nil, size: CGFloat = 34) {
        self.value = value; self.unit = unit; self.size = size
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value ?? "—")
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            if let unit, value != nil {
                Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// Secondary line under a value.
public struct WidgetCaption: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
    }
}

/// A quiet single-color trend line (no hover chrome), sized by the caller.
public struct WidgetSpark: View {
    let values: [Double]
    let tint: Color
    public init(_ values: [Double], tint: Color) { self.values = values; self.tint = tint }
    public var body: some View {
        if values.count > 1 {
            Sparkline(values: values, gradient: Gradient(colors: [StrandPalette.ink(tint), StrandPalette.ink(tint)]),
                      lineWidth: 2, showsArea: true, showsHead: false, showsHover: false)
        } else {
            Capsule().fill(StrandPalette.hairline).frame(height: 2).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Fitness-style progress ring with a rounded cap. `fraction` is 0...1.
public struct ProgressRing<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat
    @ViewBuilder let center: () -> Center
    @State private var shown: Double = 0

    public init(fraction: Double, tint: Color, lineWidth: CGFloat = 12,
                @ViewBuilder center: @escaping () -> Center) {
        self.fraction = fraction; self.tint = tint; self.lineWidth = lineWidth; self.center = center
    }

    public var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, shown)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.65), radius: lineWidth * 0.7)   // neon glow
            center()
        }
        .padding(lineWidth / 2)
        .onAppear { withAnimation(StrandMotion.respecting(StrandMotion.hero)) { shown = fraction } }
        .onChange(of: fraction) { new in withAnimation(StrandMotion.respecting(StrandMotion.gentle)) { shown = new } }
    }
}

/// Stacked sleep-stage bar with a compact legend.
public struct SleepStageBar: View {
    let stages: [(SleepStage, Double)]   // minutes
    public init(deep: Double?, rem: Double?, light: Double?, awake: Double? = nil) {
        stages = [(.deep, deep ?? 0), (.light, light ?? 0), (.rem, rem ?? 0), (.awake, awake ?? 0)]
            .filter { $0.1 > 0 }
    }
    public var body: some View {
        let total = max(stages.reduce(0) { $0 + $1.1 }, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(StrandPalette.sleepStageColor(s.0))
                            .frame(width: max(2, (geo.size.width - 2 * CGFloat(stages.count - 1)) * s.1 / total))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 4) {
                        Circle().fill(StrandPalette.sleepStageColor(s.0)).frame(width: 6, height: 6)
                        Text("\(s.0.label) \(Self.format(s.1))")
                            .font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
    static func format(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// Soft, dismissible-looking inline notice (empty / pending states).
public struct StrandNotice: View {
    let symbol: String, title: String, message: String?
    var tint: Color
    public init(symbol: String, title: String, message: String? = nil, tint: Color = StrandPalette.accent) {
        self.symbol = symbol; self.title = title; self.message = message; self.tint = tint
    }
    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(StrandPalette.ink(tint))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                if let message {
                    Text(message).font(.system(size: 13)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }
}
