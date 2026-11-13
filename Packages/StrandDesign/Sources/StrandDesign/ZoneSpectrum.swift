import SwiftUI

// MARK: - Zone spectrum
//
// One continuous intensity ribbon: each heart-rate zone takes a slice proportional to its time, in intensity order, with
// unrecorded time drawn as its own hatched slice so a gap never reads as zone time. A legend under the ribbon carries
// every zone's label, exact duration and share, so color never carries meaning alone. Used at full size in the Strain
// detail and compact in Activity Trends.

/// One slice of the ribbon.
public struct ZoneSpectrumSegment: Identifiable, Equatable, Sendable {
    /// Zone number (0…5). Used as identity and to pick the zone's color.
    public let zone: Int
    public let seconds: Int
    /// Optional bpm band, e.g. "114–133 bpm".
    public let range: String?
    public var id: Int { zone }
    public var shortLabel: String { "Z\(zone)" }
    public var name: String { "Zone \(zone)" }
    public init(zone: Int, seconds: Int, range: String? = nil) {
        self.zone = zone; self.seconds = max(0, seconds); self.range = range
    }
}

/// Pure layout math, kept apart from drawing so it can be tested.
public enum ZoneSpectrumLayout {
    /// Fractions of the ribbon for each segment, then the gap (last element), summing to 1 when anything is non-zero.
    /// Empty segments get 0; the gap is only present when `gapSeconds > 0`.
    public static func fractions(_ seconds: [Int], gapSeconds: Int = 0) -> [Double] {
        let parts = seconds.map { max(0, $0) } + [max(0, gapSeconds)]
        let total = parts.reduce(0, +)
        guard total > 0 else { return parts.map { _ in 0 } }
        return parts.map { Double($0) / Double(total) }
    }

    /// Slice widths for a ribbon `width` wide with `spacing` between visible slices. Any non-zero slice gets at least
    /// `minWidth` so a few seconds stay visible; the rest is shared proportionally. Zero slices get 0.
    public static func widths(_ fractions: [Double], width: CGFloat, spacing: CGFloat, minWidth: CGFloat = 4) -> [CGFloat] {
        let visible = fractions.filter { $0 > 0 }.count
        guard visible > 0 else { return fractions.map { _ in 0 } }
        let usable = max(0, width - spacing * CGFloat(visible - 1))
        let floorTotal = minWidth * CGFloat(visible)
        guard usable > floorTotal else { return fractions.map { $0 > 0 ? usable / CGFloat(visible) : 0 } }
        let spare = usable - floorTotal
        return fractions.map { $0 > 0 ? minWidth + spare * CGFloat($0) : 0 }
    }

    /// "42 %" share text; "<1 %" for a visible sliver; "0 %" for none.
    public static func percentText(_ fraction: Double) -> String {
        if fraction <= 0 { return "0 %" }
        let p = fraction * 100
        return p < 1 ? "<1 %" : "\(Int(p.rounded())) %"
    }

    /// "1 h 05 m" / "12 m" / "0 m".
    public static func duration(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        return m >= 60 ? String(format: "%d h %02d m", m / 60, m % 60) : "\(m) m"
    }
}

public struct ZoneSpectrum: View {
    public enum Size { case regular, compact }
    let segments: [ZoneSpectrumSegment]
    let gapSeconds: Int
    let gapLabel: String
    let size: Size
    @State private var hovered: Int?

    /// `gapSeconds`: time in the window with no supported reading. It gets its own hatched slice and legend entry.
    public init(_ segments: [ZoneSpectrumSegment], gapSeconds: Int = 0, gapLabel: String = "Not recorded", size: Size = .regular) {
        self.segments = segments.sorted { $0.zone < $1.zone }
        self.gapSeconds = max(0, gapSeconds); self.gapLabel = gapLabel; self.size = size
    }

    private var fractions: [Double] { ZoneSpectrumLayout.fractions(segments.map(\.seconds), gapSeconds: gapSeconds) }
    private var ribbonHeight: CGFloat { size == .regular ? 26 : 18 }
    private static let gapID = -1

    static func color(_ zone: Int) -> Color { zone == 0 ? StrandPalette.textTertiary.opacity(0.55) : StrandPalette.hrZoneColor(zone) }

    public var body: some View {
        let f = fractions
        VStack(alignment: .leading, spacing: size == .regular ? 14 : 10) {
            ribbon(f)
            intensityScale
            legend(f)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Heart-rate zone distribution")
    }

    // The ribbon: a single capsule clipped from proportional slices.
    private func ribbon(_ f: [Double]) -> some View {
        GeometryReader { g in
            let widths = ZoneSpectrumLayout.widths(f, width: g.size.width, spacing: 2)
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                    if widths[i] > 0 { slice(s.zone, width: widths[i]) }
                }
                if let w = widths.last, w > 0 { gapSlice(width: w) }
            }
            .frame(width: g.size.width, height: ribbonHeight, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
            .background(Capsule(style: .continuous).fill(StrandPalette.surfaceInset))
        }
        .frame(height: ribbonHeight + 6)
        .accessibilityHidden(true)
    }

    private func slice(_ zone: Int, width: CGFloat) -> some View {
        let c = Self.color(zone)
        let on = hovered == zone
        let dim = hovered != nil && !on
        return Rectangle()
            .fill(LinearGradient(colors: [c, c.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1) }
            .frame(width: width, height: ribbonHeight)
            .opacity(dim ? 0.35 : 1)
            .onHover { hovered = $0 ? zone : (hovered == zone ? nil : hovered) }
            .animation(StrandMotion.respecting(StrandMotion.interactive), value: hovered)
    }

    private func gapSlice(width: CGFloat) -> some View {
        let dim = hovered != nil && hovered != Self.gapID
        return Hatch()
            .stroke(StrandPalette.textTertiary.opacity(0.45), lineWidth: 1)
            .background(StrandPalette.surfaceInset)
            .frame(width: width, height: ribbonHeight)
            .clipped()
            .opacity(dim ? 0.35 : 1)
            .onHover { hovered = $0 ? Self.gapID : (hovered == Self.gapID ? nil : hovered) }
    }

    /// "lighter → harder" cue under the ribbon, so intensity order is explicit in words, not only by hue.
    private var intensityScale: some View {
        HStack(spacing: 6) {
            Text("Lighter").strandOverline()
            Rectangle().fill(StrandPalette.hairlineStrong).frame(height: 0.5)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
            Text("Harder").strandOverline()
        }
        .accessibilityHidden(true)
    }

    private func legend(_ f: [Double]) -> some View {
        let cols = [GridItem(.adaptive(minimum: size == .regular ? 150 : 118), spacing: 8, alignment: .leading)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                legendItem(key: s.zone, swatch: AnyView(Capsule().fill(Self.color(s.zone))),
                           title: s.shortLabel, detail: s.range, seconds: s.seconds, fraction: f[i],
                           accessibility: "\(s.name)\(s.range.map { ", \($0)" } ?? ""): \(ZoneSpectrumLayout.duration(s.seconds)), \(ZoneSpectrumLayout.percentText(f[i]))")
            }
            if gapSeconds > 0, let g = f.last {
                legendItem(key: Self.gapID, swatch: AnyView(Hatch().stroke(StrandPalette.textTertiary, lineWidth: 1)
                    .background(StrandPalette.surfaceInset).clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 0.5))),
                           title: gapLabel, detail: "no zone", seconds: gapSeconds, fraction: g,
                           accessibility: "\(gapLabel), counted in no zone: \(ZoneSpectrumLayout.duration(gapSeconds)), \(ZoneSpectrumLayout.percentText(g))")
            }
        }
    }

    private func legendItem(key: Int, swatch: AnyView, title: String, detail: String?, seconds: Int, fraction: Double,
                            accessibility: String) -> some View {
        let on = hovered == key
        return HStack(spacing: 8) {
            swatch.frame(width: 6, height: size == .regular ? 30 : 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(StrandPalette.textPrimary)
                    if let detail, size == .regular {
                        Text(detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Text(ZoneSpectrumLayout.duration(seconds)).font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(seconds > 0 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(ZoneSpectrumLayout.percentText(fraction)).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(StrandPalette.textTertiary).lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? StrandPalette.surfaceInset : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

/// Diagonal hatching for "no data" slices: texture, not hue, marks them as different from any zone.
struct Hatch: Shape {
    var spacing: CGFloat = 5
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return p
    }
}
