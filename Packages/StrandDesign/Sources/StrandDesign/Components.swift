import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

// Shared spacing/radius constants so every screen lines up; change here, not per view.
public enum NoopMetrics {
    public static let cardRadius: CGFloat = 22
    public static let cardPadding: CGFloat = 20
    public static let gap: CGFloat = 16          // gap between cards
    public static let sectionGap: CGFloat = 36   // gap between sections
    public static let screenPadding: CGFloat = 28
    public static let contentMaxWidth: CGFloat = 1080
    /// Corner radius for controls (buttons, inputs, chips are capsules/10pt).
    public static let controlRadius: CGFloat = 12
    public static let tileHeight: CGFloat = 112  // every metric tile is this tall
    public static let chartHeight: CGFloat = 220
}

// MARK: - Surface

/// The one card surface. All cards use this — same radius, border, fill.
// The one card surface used app-wide.
public struct NoopCard<Content: View>: View {
    private let padding: CGFloat
    @ViewBuilder private let content: () -> Content
    public init(padding: CGFloat = NoopMetrics.cardPadding, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .strandSurface(cornerRadius: NoopMetrics.cardRadius)
    }
}

public extension View {
    /// The one elevated surface: raised fill, hairline border, a barely-there shadow.
    func strandSurface(cornerRadius: CGFloat = NoopMetrics.cardRadius) -> some View {
        self
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Faint top-lit sheen so cards read as glassy tiles on the near-black canvas (invisible on white in light mode).
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
            .shadow(color: StrandPalette.shadow, radius: 14, y: 4)
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    let title: String; let trailing: String?
    public init(_ title: String, overline: String? = nil, trailing: String? = nil) {
        self.title = title; self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

// All metric tiles share a fixed height so rows of tiles align.
public struct StatTile: View {
    let label: String, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent

    public init(label: String, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
    }

    public var body: some View {
        NoopCard(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).strandOverline()
                Spacer(minLength: 4)
                Text(value).font(StrandFont.number(26)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline).frame(height: 22).padding(.top, 4)
                }
                HStack(spacing: 6) {
                    if let caption { Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let delta { Text(delta).font(StrandFont.captionNumber).foregroundStyle(deltaColor) }
                }
                .padding(.top, 2)
            }
        }
        .frame(height: NoopMetrics.tileHeight)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = NoopMetrics.chartHeight
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: String, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = NoopMetrics.chartHeight,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.chart = chart; self.footer = footer
    }

    public var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).strandOverline()
                        if let subtitle { Text(subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(String, String)]
    public init(_ items: [(String, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: String, status: String, detail: String
    var statusColor: Color = StrandPalette.accent
    public init(category: String, status: String, detail: String, statusColor: Color = StrandPalette.accent) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor
    }
    public var body: some View {
        NoopCard(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).strandOverline()
                Text(status).font(StrandFont.title1).foregroundStyle(StrandPalette.ink(statusColor))
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Range control (the ONE segmented pill control, used everywhere)

// The single segmented control used for every range/mode picker.
/// Pill segmented control (range pills, Trends sub-tabs). Each pill is a button with the selected trait; the control
/// takes keyboard focus and Left/Right arrows move the selection. `title` names the group for VoiceOver.
public struct SegmentedPillControl<T: Hashable>: View {
    /// `.inset`: filled track with a raised selected pill (sub-view switches). `.quiet`: no track, a hairline outline and
    /// an accent wash on the selection, so a range filter sits in the page instead of on top of it.
    public enum Appearance: Sendable { case inset, quiet }
    let items: [T]
    let label: (T) -> String
    let title: String?
    var controlSize: ControlSize
    var appearance: Appearance = .inset
    /// Spoken name per item when the visible label is an abbreviation ("3M" → "3 months").
    var spokenLabel: ((T) -> String)?
    @Binding var selection: T
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var hovered: Int?
    public init(_ items: [T], selection: Binding<T>, title: String? = nil, controlSize: ControlSize = .regular,
                label: @escaping (T) -> String) {
        self.items = items; self._selection = selection; self.title = title; self.controlSize = controlSize; self.label = label
    }

    public init(_ items: [T], selection: Binding<T>, title: String, appearance: Appearance, controlSize: ControlSize = .regular,
                spokenLabel: ((T) -> String)? = nil, label: @escaping (T) -> String) {
        self.init(items, selection: selection, title: title, controlSize: controlSize, label: label)
        self.appearance = appearance
        self.spokenLabel = spokenLabel
    }

    private func select(_ item: T) { withAnimation(StrandMotion.respecting(StrandMotion.interactive)) { selection = item } }

    /// The item `step` places from the current selection, clamped to the ends.
    static func moved(_ items: [T], from current: T, by step: Int) -> T? {
        guard let i = items.firstIndex(of: current) else { return items.first }
        let j = min(max(i + step, 0), items.count - 1)
        return j == i ? nil : items[j]
    }

    public var body: some View {
        let large = controlSize != .small && controlSize != .mini
        let quiet = appearance == .quiet
        HStack(spacing: quiet ? 2 : 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let sel = item == selection
                let hover = hovered == i && !sel && enabled
                Button { select(item) } label: {
                    Text(label(item))
                        .font(quiet ? .system(size: 12, weight: sel ? .bold : .semibold, design: .rounded).monospacedDigit()
                              : large ? StrandFont.captionNumber : .system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(quiet ? (sel ? StrandPalette.accentInk : hover ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                                         : sel ? StrandPalette.textPrimary : hover ? StrandPalette.textPrimary.opacity(0.85) : StrandPalette.textSecondary)
                        .frame(minWidth: quiet ? 28 : 32)
                        .padding(.vertical, quiet ? 4 : large ? 5 : 4).padding(.horizontal, quiet ? 9 : large ? 11 : 12)
                        .background {
                            if quiet {
                                Capsule(style: .continuous)
                                    .fill(sel ? StrandPalette.accentMuted : hover ? StrandPalette.surfaceInset : Color.clear)
                                    .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.accent.opacity(sel ? 0.25 : 0), lineWidth: 0.5))
                            } else {
                                Capsule(style: .continuous)
                                    .fill(sel ? StrandPalette.surfaceRaised : hover ? StrandPalette.surfaceRaised.opacity(0.45) : Color.clear)
                                    .shadow(color: StrandPalette.shadow.opacity(sel ? 1.6 : 0), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                .accessibilityLabel(spokenLabel?(item) ?? label(item))
                .accessibilityAddTraits(sel ? [.isSelected, .isButton] : [.isButton])
            }
        }
        .padding(quiet ? 2 : 3)
        .background {
            if quiet {
                Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5)
            } else {
                Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
            }
        }
        .opacity(enabled ? 1 : StrandPalette.disabledOpacity)
        .focusable()
        .focused($focused)
        .strandFocusRing(focused, shape: Capsule(style: .continuous))
        .onMoveCommand { dir in
            switch dir {
            case .left: if let n = Self.moved(items, from: selection, by: -1) { select(n) }
            case .right: if let n = Self.moved(items, from: selection, by: 1) { select(n) }
            default: break
            }
        }
        .animation(StrandMotion.respecting(StrandMotion.interactive), value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "")
    }
}

/// Primary section tabs (icon + name) for a page's top level, e.g. Trends ▸ Scores / Sleep / Vitals / Activity. Reads one
/// step above `SegmentedPillControl`: the selected section carries the accent wash and ink, the others stay quiet text,
/// so section, sub-view and range never compete. Arrow keys move between sections; focus draws its own ring, never the
/// selection's.
public struct SectionTabBar<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    let symbol: (T) -> String
    let title: String
    @Binding var selection: T
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var hovered: Int?
    @Namespace private var ns

    public init(_ items: [T], selection: Binding<T>, title: String, symbol: @escaping (T) -> String, label: @escaping (T) -> String) {
        self.items = items; self._selection = selection; self.title = title; self.symbol = symbol; self.label = label
    }

    private func select(_ item: T) { withAnimation(StrandMotion.respecting(.spring(response: 0.3, dampingFraction: 0.86))) { selection = item } }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let sel = item == selection
                let hover = hovered == i && !sel && enabled
                Button { select(item) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: symbol(item)).font(.system(size: 13, weight: .semibold))
                        Text(label(item)).font(.system(size: 14, weight: sel ? .semibold : .medium, design: .rounded))
                    }
                    .foregroundStyle(sel ? StrandPalette.accentInk : hover ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background {
                        if sel {
                            Capsule(style: .continuous).fill(StrandPalette.accentMuted)
                                .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.accent.opacity(0.25), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "section", in: ns)
                        } else if hover {
                            Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                .accessibilityLabel(label(item))
                .accessibilityAddTraits(sel ? [.isSelected, .isButton] : [.isButton])
            }
        }
        .padding(4)
        .background(StrandPalette.surfaceRaised, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        .shadow(color: StrandPalette.shadow, radius: 6, y: 2)
        .opacity(enabled ? 1 : StrandPalette.disabledOpacity)
        .focusable()
        .focused($focused)
        .strandFocusRing(focused, shape: Capsule(style: .continuous))
        .onMoveCommand { dir in
            switch dir {
            case .left: if let n = SegmentedPillControl<T>.moved(items, from: selection, by: -1) { select(n) }
            case .right: if let n = SegmentedPillControl<T>.moved(items, from: selection, by: 1) { select(n) }
            default: break
            }
        }
        .animation(StrandMotion.respecting(StrandMotion.interactive), value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint("Use the left and right arrow keys to change section")
    }
}

public extension View {
    /// Keyboard-focus indicator drawn outside the control (offset ring), so it is never mistaken for a selected state.
    /// Replaces the system ring where macOS lets us turn it off (14+); on 13 the system ring stays and this adds nothing.
    @ViewBuilder func strandFocusRing<S: InsettableShape>(_ focused: Bool, shape: S) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.focusEffectDisabled()
                .overlay(shape.inset(by: -3).stroke(StrandPalette.focusRing, lineWidth: 2).opacity(focused ? 1 : 0).allowsHitTesting(false))
        } else {
            self
        }
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: String; var tint: Color = StrandPalette.accent
    public init(_ text: String, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tint.opacity(0.32), in: Capsule())
            .foregroundStyle(StrandPalette.ink(tint))
    }
}


// MARK: - Buttons

/// Primary action: pastel-blue fill, charcoal label, soft press + hover feedback.
public struct StrandPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StrandPalette.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hovering ? StrandPalette.accentHover : StrandPalette.accent,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.controlRadius, style: .continuous))
            .opacity(enabled ? 1 : StrandPalette.disabledOpacity)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(StrandMotion.respecting(.easeOut(duration: 0.15)), value: configuration.isPressed)
            .animation(StrandMotion.respecting(.easeOut(duration: 0.15)), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Secondary action: quiet inset fill with a hairline border.
public struct StrandSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(hovering ? StrandPalette.hairline : StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.controlRadius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
            .opacity(enabled ? 1 : StrandPalette.disabledOpacity)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(StrandMotion.respecting(.easeOut(duration: 0.15)), value: configuration.isPressed)
            .animation(StrandMotion.respecting(.easeOut(duration: 0.15)), value: hovering)
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == StrandPrimaryButtonStyle {
    static var strandPrimary: StrandPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == StrandSecondaryButtonStyle {
    static var strandSecondary: StrandSecondaryButtonStyle { .init() }
}
