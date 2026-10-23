import SwiftUI

// MARK: - Hex Color Helper

public extension Color {
    /// Create a Color from a hex string like "#0B0D12" or "0B0D12" (RGB) or "#AARRGGBB" / "RRGGBBAA".
    /// Supported lengths: 6 (RGB), 8 (RGBA).
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        let r, g, b, a: Double
        switch raw.count {
        case 8: // RRGGBBAA
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8) & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        default: // RRGGBB (6) and any fallback
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Adaptive (light / dark) colors

public extension Color {
    /// A semantic color that resolves to `light` or `dark` hex with the system appearance.
    init(light: String, dark: String) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #else
        self.init(hex: dark)
        #endif
    }
}

// MARK: - Strand Palette
//
// Semantic tokens, adaptive to light and dark mode. Surfaces follow Apple's grouped-content model:
// a quiet background with elevated, rounded cards on top. Data colors are Apple system tones.

// Every colour comes from here; views must not hardcode hex.
public enum StrandPalette {

    // MARK: Surfaces — warm off-white canvas, white cards (dark mode: soft graphite)
    public static let surfaceBase    = Color(light: "#F1F3F8", dark: "#050608")
    public static let surfaceRaised  = Color(light: "#FFFFFF", dark: "#0F1117")
    public static let surfaceOverlay = Color(light: "#FFFFFF", dark: "#181B23")
    public static let surfaceInset   = Color(light: "#E8ECF3", dark: "#0A0B10")
    public static let hairline       = Color(light: "#1018281A", dark: "#FFFFFF1A")
    public static let hairlineStrong = Color(light: "#10182833", dark: "#FFFFFF33")

    // MARK: Text — soft charcoal. Secondary is a touch deeper than the #858A91 swatch so small
    // labels stay readable (≥4.5:1 on white); tertiary is the swatch itself, for hints only.
    public static let textPrimary    = Color(light: "#0E1116", dark: "#FFFFFF")
    public static let textSecondary  = Color(light: "#5A6070", dark: "#B4B9C6")
    public static let textTertiary   = Color(light: "#7A8090", dark: "#7C828E")

    /// Very soft card shadow color.
    public static let shadow = Color(light: "#1018281A", dark: "#00000099")

    // MARK: Glow
    public static let glowAmbient    = Color(hex: "#0AA2FF")

    // MARK: Accent — pastel blue. `accent` is a FILL (buttons, selection, rings); use `accentInk`
    // for text and icons so they stay legible on white.
    public static let accent         = Color(hex: "#0AA2FF")
    public static let accentHover    = Color(hex: "#3DB6FF")
    public static let accentMuted    = Color(light: "#0AA2FF26", dark: "#0AA2FF4D")
    public static let accentInk      = Color(light: "#0070E0", dark: "#4DC0FF")
    /// Secondary accent — soft lavender.
    public static let lavender       = Color(hex: "#B14CFF")
    public static let lavenderInk    = Color(light: "#7A2FE0", dark: "#C98BFF")
    /// Text/icon color that sits ON a pastel accent fill.
    public static let onAccent       = Color(hex: "#FFFFFF")
    /// Focus ring color.
    public static let focusRing      = Color(hex: "#0AA2FF")
    /// Opacity for dimmed/disabled sections (shared so screens don't invent their own value).
    public static let disabledOpacity: Double = 0.45

    // MARK: Recovery gradient — vivid traffic light (low red → high green).
    public static let recovery000 = Color(hex: "#FF1F5A")
    public static let recovery030 = Color(hex: "#FF7A00")
    public static let recovery055 = Color(hex: "#FFF200")
    public static let recovery078 = Color(hex: "#7CFF4D")
    public static let recovery100 = Color(hex: "#00FF85")

    /// Ordered gradient stops for the recovery scale (location + color).
    public static let recoveryStops: [Gradient.Stop] = [
        .init(color: recovery000, location: 0.00),
        .init(color: recovery030, location: 0.30),
        .init(color: recovery055, location: 0.55),
        .init(color: recovery078, location: 0.78),
        .init(color: recovery100, location: 1.00),
    ]

    /// The signature recovery gradient (coral → mint).
    public static let recoveryGradient = Gradient(stops: recoveryStops)

    // MARK: Strain ramp — peach → coral → lavender
    public static let strain000 = Color(hex: "#FFF200")
    public static let strain033 = Color(hex: "#FF8A00")
    public static let strain066 = Color(hex: "#FF1F5A")
    public static let strain100 = Color(hex: "#E02BFF")

    public static let strainStops: [Gradient.Stop] = [
        .init(color: strain000, location: 0.00),
        .init(color: strain033, location: 0.33),
        .init(color: strain066, location: 0.66),
        .init(color: strain100, location: 1.00),
    ]

    /// The strain gradient (output / heat).
    public static let strainGradient = Gradient(stops: strainStops)

    // MARK: Sleep stages
    public static let sleepAwake = Color(hex: "#FF8A00")
    public static let sleepLight = Color(hex: "#0AA2FF")
    public static let sleepDeep  = Color(hex: "#9A4DFF")
    public static let sleepREM   = Color(hex: "#00F5E0")

    // MARK: HR zones
    public static let zone1 = Color(hex: "#0AA2FF")
    public static let zone2 = Color(hex: "#00FF85")
    public static let zone3 = Color(hex: "#FFF200")
    public static let zone4 = Color(hex: "#FF8A00")
    public static let zone5 = Color(hex: "#FF1F5A")

    /// HR zones indexed 1...5; index 0 mirrors zone1 for convenience.
    public static let hrZones: [Color] = [zone1, zone1, zone2, zone3, zone4, zone5]

    // MARK: Status — fills (pastel) and inks (text/icon-safe) — never reused as recovery colors.
    public static let statusPositive = Color(hex: "#00FF85")
    public static let statusWarning  = Color(hex: "#FFC400")
    public static let statusCritical = Color(hex: "#FF1F5A")
    public static let statusPositiveInk = Color(light: "#08A040", dark: "#3DFF9A")
    public static let statusWarningInk  = Color(light: "#B86E00", dark: "#FFD633")
    public static let statusCriticalInk = Color(light: "#D11F3F", dark: "#FF5C85")

    // MARK: Per-metric accents
    public static let metricCyan   = Color(hex: "#00F0FF")
    public static let metricPurple = Color(hex: "#B14CFF")
    public static let metricAmber  = Color(hex: "#FFC400")
    public static let metricRose   = Color(hex: "#FF2BA0")

    /// A text/icon-safe version of a pastel data color. In light mode it is darkened toward the
    /// charcoal text color so it reads on white; in dark mode the pastel is used as-is.
    public static func ink(_ color: Color) -> Color {
        #if canImport(AppKit)
        let c = color.rgbaComponents
        let base = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        let dark = NSColor(srgbRed: c.r * 0.52, green: c.g * 0.52, blue: c.b * 0.52, alpha: c.a)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? base : dark
        })
        #else
        return color
        #endif
    }

    // MARK: - Sampling helpers

    /// Sample the recovery gradient (indigo → mint) at a recovery score 0...100.
    /// Returns the exact interpolated color used everywhere recovery is tinted.
    public static func recoveryColor(_ score: Double) -> Color {
        sample(stops: recoveryStops, at: score / 100.0)
    }

    /// Sample the strain gradient at a strain value on the 0...21 Whoop scale.
    public static func strainColor(_ strain: Double) -> Color {
        sample(stops: strainStops, at: strain / 21.0)
    }

    /// The state word for a recovery score, per spec §9.3.
    /// DEPLETED · LOW · MODERATE · PRIMED · PEAK
    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25:  return "DEPLETED"
        case ..<50:  return "LOW"
        case ..<70:  return "MODERATE"
        case ..<88:  return "PRIMED"
        default:     return "PEAK"
        }
    }

    /// HR-zone color for a 0...5 zone index (clamped).
    public static func hrZoneColor(_ zone: Int) -> Color {
        let z = max(1, min(5, zone))
        return hrZones[z]
    }

    /// Color for a sleep stage by canonical name (awake/light/deep/rem).
    public static func sleepStageColor(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return sleepAwake
        case .light: return sleepLight
        case .deep:  return sleepDeep
        case .rem:   return sleepREM
        }
    }

    // MARK: - Linear gradient stop interpolation

    /// Interpolate a set of gradient stops at a normalized position 0...1.
    /// Clamps out-of-range positions to the end stops.
    public static func sample(stops: [Gradient.Stop], at position: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        let t = min(max(position, 0.0), 1.0)

        // Find the bracketing pair.
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if t >= a.location && t <= b.location {
                lower = a
                upper = b
                break
            }
        }
        let span = upper.location - lower.location
        let localT = span > 0 ? (t - lower.location) / span : 0
        return interpolate(lower.color, upper.color, localT)
    }

    /// Linear-interpolate two colors in sRGB space.
    // Linear blend between two colours; used to sample gradients at an exact score.
    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = a.rgbaComponents
        let cb = b.rgbaComponents
        let tt = min(max(t, 0.0), 1.0)
        return Color(
            .sRGB,
            red:   ca.r + (cb.r - ca.r) * tt,
            green: ca.g + (cb.g - ca.g) * tt,
            blue:  ca.b + (cb.b - ca.b) * tt,
            opacity: ca.a + (cb.a - ca.a) * tt
        )
    }
}

// MARK: - Sleep stage enum (shared with Hypnogram)

// Stage names used by the Hypnogram.
public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    /// Display label.
    public var label: String {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        }
    }

    /// Vertical band order (top = awake, bottom = deep) for hypnogram layout.
    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem:   return 1
        case .light: return 2
        case .deep:  return 3
        }
    }
}

// MARK: - Color component extraction

extension Color {
    /// Resolve to sRGB RGBA components in 0...1. Works on macOS 13+ via platform color bridge.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

#if DEBUG
#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            swatchRow("Surfaces", [
                ("base", StrandPalette.surfaceBase),
                ("raised", StrandPalette.surfaceRaised),
                ("overlay", StrandPalette.surfaceOverlay),
                ("inset", StrandPalette.surfaceInset),
                ("hairline", StrandPalette.hairline),
                ("hairline.strong", StrandPalette.hairlineStrong),
            ])
            swatchRow("Text", [
                ("primary", StrandPalette.textPrimary),
                ("secondary", StrandPalette.textSecondary),
                ("tertiary", StrandPalette.textTertiary),
            ])
            swatchRow("Accent", [
                ("accent", StrandPalette.accent),
                ("hover", StrandPalette.accentHover),
                ("muted", StrandPalette.accentMuted),
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY GRADIENT").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("STRAIN RAMP").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.strainGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            swatchRow("Sleep stages", [
                ("awake", StrandPalette.sleepAwake),
                ("light", StrandPalette.sleepLight),
                ("deep", StrandPalette.sleepDeep),
                ("REM", StrandPalette.sleepREM),
            ])
            swatchRow("HR zones", [
                ("Z1", StrandPalette.zone1), ("Z2", StrandPalette.zone2),
                ("Z3", StrandPalette.zone3), ("Z4", StrandPalette.zone4),
                ("Z5", StrandPalette.zone5),
            ])
        }
        .padding(24)
    }
    .frame(width: 520, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func swatchRow(_ title: String, _ items: [(String, Color)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(width: 64, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1))
                    Text(name).font(.system(size: 9)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
