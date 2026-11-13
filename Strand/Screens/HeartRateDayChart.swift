import SwiftUI
import StrandDesign
import StrandAnalytics

// Overview heart-rate day chart (issue #26): the HR curve and the activation strip share one `DayTimeAxis`, one width
// and one x mapping, so equal timestamps sit at the same x on both, including on partial days, with gaps, after late
// syncs and on 23/25-hour days. The Health Stress Monitor draws its strip, axis and legend with the same pieces.

// MARK: - Activation styling (shared with Health)

enum ActivationStyle {
    /// Legend order: sleep first, then activation from calm to high, workout, then the two "no state" kinds.
    static let legendOrder: [DayTimeAxis.SpanKind] = [
        .observed(.sleep), .observed(.low), .observed(.moderate), .observed(.high), .observed(.exercise), .missing, .upcoming,
    ]

    static func color(_ kind: DayTimeAxis.SpanKind) -> Color {
        switch kind {
        case .observed(let l): return ActivationPalette.colors[l] ?? .clear
        case .missing: return StrandPalette.surfaceInset
        case .upcoming: return .clear
        }
    }

    static func label(_ kind: DayTimeAxis.SpanKind) -> String {
        switch kind {
        case .observed(let l): return l.label
        case .missing: return HRActivation.Level.noData.label
        case .upcoming: return "Upcoming"
        }
    }

    /// Spoken/tooltip meaning, so no state relies on colour alone.
    static func meaning(_ kind: DayTimeAxis.SpanKind) -> String {
        switch kind {
        case .observed(.sleep): return "purple"
        case .observed(.low): return "green, heart rate near resting"
        case .observed(.moderate): return "amber, heart rate moderately above resting"
        case .observed(.high): return "red, heart rate well above resting"
        case .observed(.exercise): return "blue with a running figure, a recorded workout"
        case .missing, .observed(.noData): return "hatched grey, elapsed time without enough readings"
        case .upcoming: return "empty dashed outline, time that hasn't happened yet"
        }
    }

    static let workoutSymbol = "figure.run"

    static func clock(_ ts: Int) -> String { ZoneTimeline.shared.clock(ts) }
    static func interval(_ s: DayTimeAxis.Span) -> String { "\(clock(s.start))–\(clock(s.end))" }
}

/// A legend swatch drawn exactly like the strip draws that kind.
struct ActivationSwatch: View {
    let kind: DayTimeAxis.SpanKind
    var size: CGFloat = 11

    var body: some View {
        Canvas { ctx, sz in
            let r = CGRect(origin: .zero, size: sz)
            ActivationStrip.draw(kind, in: r, ctx: &ctx)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            switch kind {
            case .upcoming:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            case .observed(.exercise):
                Image(systemName: ActivationStyle.workoutSymbol).font(.system(size: size * 0.62, weight: .bold)).foregroundStyle(.white)
            default:
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The compact legend shown on Overview: every state the strip can show, as swatch + words.
struct ActivationLegend: View {
    var showsUpcoming = true

    var body: some View {
        LegendFlow(spacing: 12, lineSpacing: 5) {
            ForEach(ActivationStyle.legendOrder.filter { showsUpcoming || $0 != .upcoming }, id: \.self) { kind in
                HStack(spacing: 5) {
                    ActivationSwatch(kind: kind)
                    Text(ActivationStyle.label(kind)).font(.system(size: 11)).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(ActivationStyle.label(kind)): \(ActivationStyle.meaning(kind))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activation legend")
    }
}

/// Left-to-right wrapping row (legend chips), each line left-aligned.
struct LegendFlow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 6

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, s))
            x += s.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rs = rows(width, subviews)
        let h = rs.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + lineSpacing * CGFloat(max(rs.count - 1, 0))
        let w = rs.map { r in r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(r.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(bounds.width, subviews) {
            var x = bounds.minX
            let h = r.map(\.1.height).max() ?? 0
            for (i, s) in r {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += h + lineSpacing
        }
    }
}

// MARK: - Strip and axis

/// The day's activation as contiguous spans on the shared axis. Observed states are filled, elapsed time without a
/// state is hatched, upcoming time is left empty with a dashed outline.
struct ActivationStrip: View {
    let axis: DayTimeAxis
    let spans: [DayTimeAxis.Span]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for s in spans {
                        let x0 = CGFloat(axis.fraction(s.start)) * size.width
                        let x1 = CGFloat(axis.fraction(s.end)) * size.width
                        Self.draw(s.kind, in: CGRect(x: x0, y: 0, width: max(x1 - x0, 0.5), height: size.height), ctx: &ctx)
                    }
                    if let up = spans.last(where: { $0.kind == .upcoming }) {
                        let x0 = CGFloat(axis.fraction(up.start)) * size.width
                        var p = Path()
                        p.addRoundedRect(in: CGRect(x: x0 + 0.5, y: 0.5, width: size.width - x0 - 1, height: size.height - 1),
                                         cornerSize: CGSize(width: 3, height: 3))
                        ctx.stroke(p, with: .color(StrandPalette.hairlineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                ForEach(Array(spans.enumerated()), id: \.offset) { _, s in
                    let x0 = CGFloat(axis.fraction(s.start)) * w, x1 = CGFloat(axis.fraction(s.end)) * w
                    if s.kind == .observed(.exercise), x1 - x0 >= height {
                        Image(systemName: ActivationStyle.workoutSymbol)
                            .font(.system(size: height * 0.62, weight: .bold)).foregroundStyle(.white)
                            .position(x: (x0 + x1) / 2, y: g.size.height / 2)
                    }
                }
            }
        }
        .frame(height: height)
        .background(StrandPalette.surfaceInset.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: height > 16 ? 8 : 4, style: .continuous))
    }

    static func draw(_ kind: DayTimeAxis.SpanKind, in r: CGRect, ctx: inout GraphicsContext) {
        switch kind {
        case .observed(.noData), .missing:
            ctx.fill(Path(r), with: .color(StrandPalette.surfaceInset))
            var hatch = Path()
            var x = r.minX - r.height
            while x < r.maxX {
                hatch.move(to: CGPoint(x: x, y: r.maxY)); hatch.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += 4
            }
            var c = ctx
            c.clip(to: Path(r))
            c.stroke(hatch, with: .color(StrandPalette.textTertiary.opacity(0.45)), lineWidth: 1)
        case .upcoming:
            break
        case .observed:
            ctx.fill(Path(r), with: .color(ActivationStyle.color(kind)))
        }
    }
}

/// Local-clock tick labels at their true positions on the shared axis.
struct DayAxisLabels: View {
    let axis: DayTimeAxis

    private static func label(_ ts: Int, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("j")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    var body: some View {
        let zone = ZoneTimeline.shared.zone(forSpan: axis.start, axis.end)
        let ticks = axis.ticks(zone: zone)
        GeometryReader { g in
            ForEach(ticks, id: \.self) { t in
                let text = Self.label(t == axis.end ? axis.start : t, zone: zone)
                let x = CGFloat(axis.fraction(t)) * g.size.width
                Text(text)
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
                    .position(x: min(max(x, 16), g.size.width - 16), y: g.size.height / 2)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

// MARK: - Heart rate + activation

/// What the activation strip can show for a day.
enum ActivationAvailability {
    case loading
    /// No resting heart rate yet (needs one scored night).
    case unavailable
    case ready([HRActivation.Bin])
}

/// HR curve over the day plotted by time, the activation strip under it on the same axis, shared tick labels and a
/// crosshair that reads both at one instant.
struct HeartRateDayTimeline: View {
    let axis: DayTimeAxis
    let runs: [[DayTimeAxis.Point]]
    let activation: ActivationAvailability
    let dayName: String

    @State private var hoverX: CGFloat?

    private var spans: [DayTimeAxis.Span]? {
        if case .ready(let bins) = activation { return axis.activationSpans(bins) }
        return nil
    }

    private static let gradient = Gradient(colors: [StrandPalette.metricCyan, StrandPalette.metricRose, StrandPalette.statusCritical])
    private static let stripHeight: CGFloat = 14
    private static let rowGap: CGFloat = 6

    var body: some View {
        let spans = self.spans
        VStack(alignment: .leading, spacing: Self.rowGap) {
            VStack(spacing: Self.rowGap) {
                plot
                    .frame(minHeight: 96, idealHeight: 140, maxHeight: .infinity)
                // Unavailable/loading: an empty strip keeps the layout steady; the reason is stated once, in the key below.
                ActivationStrip(axis: axis, spans: spans ?? [], height: Self.stripHeight)
            }
            .overlay { hoverLayer(spans) }
            DayAxisLabels(axis: axis)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate and activation, \(dayName)")
        .accessibilityValue(accessibilityText(spans))
    }

    // MARK: Plot

    private var domain: (lo: Double, hi: Double) {
        let all = runs.flatMap { $0 }.map(\.bpm)
        guard let mn = all.min(), let mx = all.max() else { return (40, 120) }
        let pad = max(4, (mx - mn) * 0.08)
        let lo = mn - pad, hi = max(mx + pad, lo + 30)
        return (lo, hi)
    }

    private var plot: some View {
        let d = domain
        let ticks = axis.ticks(zone: ZoneTimeline.shared.zone(forSpan: axis.start, axis.end))
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            func x(_ ts: Int) -> CGFloat { CGFloat(axis.fraction(ts)) * w }
            func y(_ v: Double) -> CGFloat { h - CGFloat((v - d.lo) / (d.hi - d.lo)) * h }
            // Upcoming time: a subdued panel, so it never reads as missing or calm.
            if axis.hasUpcoming {
                let cx = x(axis.cutoff)
                ctx.fill(Path(roundedRect: CGRect(x: cx, y: 0, width: w - cx, height: h), cornerRadius: 6),
                         with: .color(StrandPalette.surfaceInset.opacity(0.55)))
            }
            for t in ticks.dropFirst().dropLast() {
                var p = Path(); p.move(to: CGPoint(x: x(t), y: 0)); p.addLine(to: CGPoint(x: x(t), y: h))
                ctx.stroke(p, with: .color(StrandPalette.hairline), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            var base = Path(); base.move(to: CGPoint(x: 0, y: h - 0.5)); base.addLine(to: CGPoint(x: w, y: h - 0.5))
            ctx.stroke(base, with: .color(StrandPalette.hairline), lineWidth: 1)
            let shade = GraphicsContext.Shading.linearGradient(Self.gradient, startPoint: CGPoint(x: 0, y: h), endPoint: .zero)
            for run in runs {
                guard let first = run.first else { continue }
                if run.count == 1 {
                    let c = CGPoint(x: x(first.ts), y: y(first.bpm))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: shade)
                    continue
                }
                var line = Path()
                line.move(to: CGPoint(x: x(first.ts), y: y(first.bpm)))
                for p in run.dropFirst() { line.addLine(to: CGPoint(x: x(p.ts), y: y(p.bpm))) }
                var area = line
                area.addLine(to: CGPoint(x: x(run.last!.ts), y: h)); area.addLine(to: CGPoint(x: x(first.ts), y: h)); area.closeSubpath()
                var a = ctx; a.opacity = 0.16
                a.fill(area, with: shade)
                ctx.stroke(line, with: shade, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if axis.hasUpcoming && axis.cutoff > axis.start {
                var now = Path(); now.move(to: CGPoint(x: x(axis.cutoff), y: 0)); now.addLine(to: CGPoint(x: x(axis.cutoff), y: h))
                ctx.stroke(now, with: .color(StrandPalette.textTertiary), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .overlay(alignment: .topTrailing) {
            if axis.hasUpcoming && axis.cutoff > axis.start {
                Text("Upcoming").font(.system(size: 10, weight: .medium)).foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 6).padding(.top, 4)
            }
        }
        .overlay {
            if runs.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "heart.slash").font(.system(size: 18)).foregroundStyle(StrandPalette.textTertiary)
                    Text(axis.cutoff == axis.start ? "This day hasn't started yet" : "No heart-rate readings stored for this day yet")
                        .font(.system(size: 12)).foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.center)
                    if axis.cutoff > axis.start {
                        Text("They arrive when the strap syncs.").font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: Hover

    private func hoverLayer(_ spans: [DayTimeAxis.Span]?) -> some View {
        GeometryReader { g in
            let size = g.size
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverX = min(max(p.x, 0), size.width)
                        case .ended: hoverX = nil
                        }
                    }
                if let hx = hoverX, size.width > 0 {
                    let ts = axis.timestamp(atFraction: Double(hx / size.width))
                    let point = DayTimeAxis.nearest(ts, in: runs)
                    let span = spans.flatMap { DayTimeAxis.span(at: ts, in: $0) }
                    let plotH = size.height - Self.stripHeight - Self.rowGap
                    let d = domain
                    Rectangle().fill(StrandPalette.textTertiary.opacity(0.7))
                        .frame(width: 1, height: size.height)
                        .position(x: hx, y: size.height / 2)
                        .allowsHitTesting(false)
                    if let point {
                        let py = plotH - CGFloat((point.bpm - d.lo) / (d.hi - d.lo)) * plotH
                        Circle().fill(StrandPalette.textPrimary).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                            .position(x: CGFloat(axis.fraction(point.ts)) * size.width, y: py)
                            .allowsHitTesting(false)
                    }
                    let tip = tooltip(ts: ts, point: point, span: span)
                    tip
                        .position(ChartTooltipPlacement.position(anchor: CGPoint(x: hx, y: 18), tooltipSize: CGSize(width: 190, height: 40), in: size))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltip(ts: Int, point: DayTimeAxis.Point?, span: DayTimeAxis.Span?) -> ChartTooltip {
        let isUpcoming = span?.kind == .upcoming || ts >= axis.cutoff
        let value = point.map { "\(Int($0.bpm.rounded())) bpm" } ?? (isUpcoming ? "Upcoming" : "No reading")
        var label = ActivationStyle.clock(point?.ts ?? ts)
        if let span, span.kind != .upcoming { label += " · \(ActivationStyle.label(span.kind)) \(ActivationStyle.interval(span))" }
        return ChartTooltip(value: value, label: label, accent: span.flatMap { $0.kind == .upcoming || $0.kind == .missing ? nil : ActivationStyle.color($0.kind) })
    }

    // MARK: Accessibility

    private func accessibilityText(_ spans: [DayTimeAxis.Span]?) -> String {
        var parts: [String] = []
        let pts = runs.flatMap { $0 }
        if let f = pts.first, let l = pts.last, let lo = pts.map(\.bpm).min(), let hi = pts.map(\.bpm).max() {
            let gaps = runs.count - 1
            parts.append("Heart rate from \(ActivationStyle.clock(f.ts)) to \(ActivationStyle.clock(l.ts))\(gaps > 0 ? ", with \(gaps) gap\(gaps == 1 ? "" : "s") in the readings" : ""), \(Int(lo.rounded())) to \(Int(hi.rounded())) bpm.")
        } else {
            parts.append("No heart-rate readings.")
        }
        switch activation {
        case .ready:
            let list = (spans ?? []).map { s in
                s.kind == .upcoming ? "Upcoming from \(ActivationStyle.clock(s.start))" : "\(ActivationStyle.label(s.kind)) \(ActivationStyle.clock(s.start)) to \(ActivationStyle.clock(s.end))"
            }
            parts.append("Activation: " + list.joined(separator: "; ") + ".")
        case .unavailable: parts.append("Activation unavailable: needs a resting heart rate from a scored night.")
        case .loading: parts.append("Activation loading.")
        }
        return parts.joined(separator: " ")
    }
}
