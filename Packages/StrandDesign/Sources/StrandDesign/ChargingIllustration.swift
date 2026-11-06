import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Charging illustration
//
// A stylised strap (band + sensor pod) with its battery pack, drawn from shapes so it stays crisp, themes with the
// palette and stays cheap to render. The three phases read apart even when still:
//   idle     – pack reported detached: grey pack resting beside the strap, contacts showing, neutral pod.
//   attached – pack reported attached, charging not confirmed: seated, unlit, no flow.
//   unknown  – nothing known about the pack: drawn faint beside the strap.
//   charging – pack seated on the pod with a lit bolt, a blue→green current at the seam, the pod outlined and its
//              level bar filled in the charging gradient.
//   full     – the same seated pack, all green, bolt replaced by a check.
// Motion: when charging starts the pack drops onto the pod and a connect ring flashes from the seam; then current
// flows from the pack into the level bar (particles, a shimmer along the fill, a pulsing outline) for a few cycles.
// After that a single reminder cycle plays every `reminderInterval`, and hovering replays it. Only the small flow layer
// redraws, and only on screen, with the app active and Reduce Motion off.
// It is an illustration: callers decide the phase from verified device state, and the pack drawn here is not a claim
// that a pack is attached beyond what the caller's model says.

public struct ChargingIllustration: View {
    public enum Phase: Equatable {
        /// Pack reported detached: it rests beside the strap.
        case idle
        /// Pack reported attached, charging not confirmed (unknown or not charging): seated, unlit, no flow.
        case attached
        /// Nothing known about the pack (no report, or a stale / disconnected state): the pack is drawn faint.
        case unknown
        /// Verified charging on a fresh reading.
        case charging
        /// Verified charging at 100 %.
        case full
    }

    public var phase: Phase
    /// Shown as the pod's fill; nil draws an empty outline.
    public var percent: Int?
    /// Dims the drawing for a stale or disconnected reading.
    public var dimmed: Bool
    public var height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = true
    @State private var docked = false

    public init(phase: Phase, percent: Int?, dimmed: Bool = false, height: CGFloat = 120) {
        self.phase = phase; self.percent = percent; self.dimmed = dimmed; self.height = height
    }

    /// True while a flow burst plays. Each animated frame costs a window update (measured at roughly 15–20 % of a
    /// core while running), so the flow plays a few cycles when charging starts or the view appears, then rests as a
    /// still, fully coloured state with one short reminder cycle every `reminderInterval` (~5 % duty).
    @State private var bursting = false
    @State private var burstID = 0
    /// When the current burst began, and whether it opens with the connect ring (only when the pack just docked).
    @State private var burstStart = Date.distantPast
    @State private var connectFlash = false
    static let flowPeriod = 1.4
    static let burstCycles = 5.0
    static let reminderInterval = 30.0
    static let connectDuration = 0.8

    private var flowing: Bool { bursting && phase == .charging && !reduceMotion && appActive && !dimmed }
    private var fill: Double { Double(min(max(percent ?? 0, 0), 100)) / 100 }

    // Colour: grey when idle, a blue→green current while charging, solid green when full. The saturated tones carry
    // glows and fills; the ink tones carry strokes and glyphs so they keep contrast on the light surface.
    /// Lit only for confirmed charging or full; attached-but-not-charging stays grey.
    private var lit: Bool { phase == .charging || phase == .full }
    private var energy: Color { lit ? StrandPalette.statusPositive : StrandPalette.textTertiary }
    private var energyInk: Color { lit ? StrandPalette.statusPositiveInk : StrandPalette.textTertiary }
    private var current: Color { phase == .charging ? StrandPalette.accent : energy }
    private var energyGradient: Gradient { Gradient(colors: [current, energy]) }

    public var body: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size)
            ZStack(alignment: .topLeading) {
                // Static parts draw once per state change; only the small flow layer below redraws while charging.
                Canvas(rendersAsynchronously: false) { ctx, _ in draw(in: &ctx, g: g) }
                if flowing {
                    TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                        Canvas(rendersAsynchronously: false) { ctx, _ in
                            drawFlow(in: &ctx, g: g, t: context.date.timeIntervalSinceReferenceDate,
                                     elapsed: context.date.timeIntervalSince(burstStart))
                        }
                    }
                    .transition(.opacity)
                }
                pack(g)
                    .position(docked ? g.packDocked : g.packResting)
                    .opacity(phase == .unknown ? 0.3 : 1)
            }
        }
        .frame(height: height)
        .frame(maxWidth: height * 2.4)
        .opacity(dimmed ? 0.45 : 1)
        .saturation(dimmed ? 0 : 1)
        .contentShape(Rectangle())
        .onAppear { dock(to: phase, animated: false); if phase == .charging { startFlow(connect: false) } }
        // Use the value onChange passes in: `self.phase` inside the action can still be the previous one.
        .onChange(of: phase) { new in
            let wasDocked = docked
            dock(to: new, animated: true)
            if new == .charging { startFlow(connect: !wasDocked) } else { stopFlow() }
        }
        .onHover { inside in
            guard inside, phase == .charging, !bursting else { return }
            let id = burstID
            Task { @MainActor in await play(cycles: 2, connect: false, id: id) }
        }
        .onDisappear { stopFlow() }
        #if canImport(AppKit)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
        #endif
        .accessibilityHidden(true)   // the caller's text carries the state
    }

    // MARK: Motion scheduling

    /// Play the opening burst, then one reminder cycle every `reminderInterval` until the phase changes or the view
    /// goes away. A newer call supersedes an older loop.
    private func startFlow(connect: Bool) {
        burstID += 1
        let id = burstID
        Task { @MainActor in
            await play(cycles: Self.burstCycles, connect: connect, id: id)
            while id == burstID {
                try? await Task.sleep(nanoseconds: UInt64(Self.reminderInterval * 1_000_000_000))
                guard id == burstID else { return }
                if !bursting { await play(cycles: 1, connect: false, id: id) }
            }
        }
    }

    private func stopFlow() {
        burstID += 1
        bursting = false
    }

    private func play(cycles: Double, connect: Bool, id: Int) async {
        guard id == burstID else { return }
        burstStart = Date()
        connectFlash = connect && !reduceMotion
        withAnimation(StrandMotion.respecting(StrandMotion.fade)) { bursting = true }
        try? await Task.sleep(nanoseconds: UInt64(Self.flowPeriod * cycles * 1_000_000_000))
        guard id == burstID else { return }
        withAnimation(StrandMotion.respecting(.easeOut(duration: 0.8))) { bursting = false }
    }

    /// The pack drops onto the pod when charging starts and lifts off when it stops, once per change.
    private func dock(to phase: Phase, animated: Bool) {
        let target = phase == .attached || phase == .charging || phase == .full
        guard docked != target else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { docked = target }
        } else {
            docked = target
        }
    }

    // MARK: Layout

    /// Shared geometry for the drawn layer and the pack, which is a separate view so its docking can animate.
    private struct Geometry {
        let size: CGSize
        var h: CGFloat { size.height }
        var mid: CGPoint { CGPoint(x: size.width / 2, y: h * 0.64) }
        var pod: CGRect { CGRect(x: mid.x - h * 0.42, y: mid.y - h * 0.2, width: h * 0.84, height: h * 0.4) }
        var podRadius: CGFloat { h * 0.11 }
        /// The level bar inside the pod.
        var bar: CGRect { pod.insetBy(dx: pod.width * 0.14, dy: pod.height * 0.34) }
        var packSize: CGSize { CGSize(width: h * 0.62, height: h * 0.3) }
        /// Centre of the pack resting beside the strap, and seated on the pod's top edge.
        var packResting: CGPoint {
            CGPoint(x: min(pod.maxX + h * 0.18 + packSize.width / 2, size.width - packSize.width / 2 - 2),
                    y: h * 0.06 + packSize.height / 2)
        }
        var packDocked: CGPoint { CGPoint(x: mid.x, y: pod.minY - packSize.height / 2 + h * 0.03) }
        /// Where the seated pack meets the pod.
        var seam: CGPoint { CGPoint(x: mid.x, y: pod.minY + h * 0.03) }

        func filled(_ fill: Double) -> CGRect {
            CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * fill), height: bar.height)
        }
    }

    private func pack(_ g: Geometry) -> some View {
        let r = g.h * 0.07
        return RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(LinearGradient(colors: [StrandPalette.surfaceOverlay, StrandPalette.surfaceInset], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(lit ? AnyShapeStyle(LinearGradient(gradient: energyGradient, startPoint: .leading, endPoint: .trailing))
                                  : AnyShapeStyle(StrandPalette.hairlineStrong),
                              lineWidth: lit ? 1.5 : 1))
            .overlay {
                // Bolt while charging, check when full, a dim bolt at rest so the pack still reads as a charger.
                Image(systemName: phase == .full ? "checkmark" : "bolt.fill")
                    .font(.system(size: g.h * 0.15, weight: .bold))
                    .foregroundStyle(lit ? AnyShapeStyle(LinearGradient(gradient: energyGradient, startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(StrandPalette.textTertiary.opacity(0.6)))
                    .shadow(color: lit ? energy.opacity(0.6) : .clear, radius: g.h * 0.04)
            }
            .overlay(alignment: .trailing) {
                // Status light: lit while charging or full, off when idle.
                Circle().fill(lit ? energy : StrandPalette.hairlineStrong)
                    .frame(width: g.h * 0.045, height: g.h * 0.045)
                    .shadow(color: lit ? energy.opacity(0.8) : .clear, radius: 2)
                    .padding(.trailing, g.h * 0.055)
            }
            .overlay(alignment: .bottom) {
                // Contact pins: visible below the resting pack, seated into the pod once docked.
                HStack(spacing: g.h * 0.08) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(lit ? AnyShapeStyle(energyInk) : AnyShapeStyle(StrandPalette.hairlineStrong))
                            .frame(width: g.h * 0.05, height: g.h * 0.04)
                    }
                }
                .offset(y: g.h * 0.02)
            }
            .shadow(color: lit ? energy.opacity(0.35) : StrandPalette.shadow, radius: lit ? 6 : 3, y: 1)
            .frame(width: g.packSize.width, height: g.packSize.height)
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, g: Geometry) {
        let h = g.h, w = g.size.width
        let mid = g.mid

        // Band: a long soft capsule behind the pod.
        let band = CGRect(x: w * 0.06, y: mid.y - h * 0.09, width: w * 0.88, height: h * 0.18)
        ctx.fill(Path(roundedRect: band, cornerRadius: band.height / 2),
                 with: .linearGradient(Gradient(colors: [StrandPalette.surfaceInset, StrandPalette.hairlineStrong, StrandPalette.surfaceInset]),
                                       startPoint: CGPoint(x: band.minX, y: 0), endPoint: CGPoint(x: band.maxX, y: 0)))
        ctx.stroke(Path(roundedRect: band, cornerRadius: band.height / 2), with: .color(StrandPalette.hairline), lineWidth: 0.5)

        let pod = g.pod
        let podPath = Path(roundedRect: pod, cornerRadius: g.podRadius)

        // Halo around the pod while powered. A radial gradient rather than a blur filter: same softness, less cost.
        if lit {
            ctx.fill(Path(ellipseIn: pod.insetBy(dx: -h * 0.22, dy: -h * 0.16)),
                     with: .radialGradient(Gradient(colors: [energy.opacity(0.28), energy.opacity(0)]),
                                           center: CGPoint(x: pod.midX, y: pod.midY), startRadius: h * 0.1, endRadius: h * 0.6))
        }

        // Pod: the sensor body, with the charge level as a bar inside.
        ctx.fill(podPath, with: .linearGradient(Gradient(colors: [StrandPalette.surfaceRaised, StrandPalette.surfaceInset]),
                                                startPoint: CGPoint(x: 0, y: pod.minY), endPoint: CGPoint(x: 0, y: pod.maxY)))
        if lit {
            ctx.stroke(podPath, with: .linearGradient(energyGradient, startPoint: CGPoint(x: pod.minX, y: 0),
                                                      endPoint: CGPoint(x: pod.maxX, y: 0)), lineWidth: 1.5)
        } else {
            ctx.stroke(podPath, with: .color(StrandPalette.hairlineStrong), lineWidth: 1)
        }
        // Soft highlight along the top edge.
        ctx.stroke(Path(roundedRect: pod.insetBy(dx: 2, dy: 2), cornerRadius: h * 0.09).trimmedPath(from: 0.55, to: 0.95),
                   with: .color(.white.opacity(0.35)), lineWidth: 1)

        let bar = g.bar
        ctx.fill(Path(roundedRect: bar, cornerRadius: bar.height / 2), with: .color(StrandPalette.hairline))
        if fill > 0 {
            let filled = g.filled(fill)
            let path = Path(roundedRect: filled, cornerRadius: bar.height / 2)
            if lit {
                ctx.fill(path, with: .linearGradient(energyGradient, startPoint: CGPoint(x: bar.minX, y: 0),
                                                     endPoint: CGPoint(x: bar.maxX, y: 0)))
            } else {
                ctx.fill(path, with: .color(StrandPalette.textTertiary))
            }
        }

        guard lit else { return }

        // A steady current where pack meets pod: a bright core over a wide soft glow.
        let seam = g.seam
        ctx.fill(Path(ellipseIn: CGRect(x: seam.x - h * 0.34, y: seam.y - h * 0.1, width: h * 0.68, height: h * 0.2)),
                 with: .radialGradient(Gradient(colors: [current.opacity(0.55), current.opacity(0)]),
                                       center: seam, startRadius: 0, endRadius: h * 0.34))
        ctx.fill(Path(roundedRect: CGRect(x: seam.x - h * 0.16, y: seam.y - h * 0.008, width: h * 0.32, height: h * 0.016),
                      cornerRadius: h * 0.008),
                 with: .color(current.opacity(0.9)))
    }

    /// The moving part while charging: a connect ring when the pack has just docked, a pulsing outline and seam glow,
    /// points of light running from the seam into the bar's leading edge, and a shimmer sweeping along the fill.
    private func drawFlow(in ctx: inout GraphicsContext, g: Geometry, t: Double, elapsed: Double) {
        let h = g.h, seam = g.seam, pod = g.pod
        let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / Self.flowPeriod)

        // Connect ring: one expanding, fading ellipse from the seam.
        if connectFlash, elapsed >= 0, elapsed < Self.connectDuration {
            let p = elapsed / Self.connectDuration
            let rx = h * (0.12 + 0.6 * p), ry = rx * 0.45
            ctx.stroke(Path(ellipseIn: CGRect(x: seam.x - rx, y: seam.y - ry, width: rx * 2, height: ry * 2)),
                       with: .color(current.opacity(0.9 * (1 - p))), lineWidth: 2.5 * (1 - p) + 0.5)
        }

        // Breathing outline and seam glow.
        let podPath = Path(roundedRect: pod, cornerRadius: g.podRadius)
        ctx.stroke(podPath, with: .color(energy.opacity(0.18 * pulse)), lineWidth: 7)
        ctx.stroke(podPath, with: .color(energy.opacity(0.35 + 0.45 * pulse)), lineWidth: 1.5)
        ctx.fill(Path(ellipseIn: CGRect(x: seam.x - h * 0.24, y: seam.y - h * 0.07, width: h * 0.48, height: h * 0.14)),
                 with: .radialGradient(Gradient(colors: [current.opacity(0.45 * pulse), current.opacity(0)]),
                                       center: seam, startRadius: 0, endRadius: h * 0.24))

        // Current into the fill: particles curve from the seam to the bar's leading edge, shifting blue→green.
        let filled = g.filled(fill)
        let target = CGPoint(x: filled.maxX - filled.height / 2, y: filled.midY)
        let count = 5
        for i in 0..<count {
            let p = (t / Self.flowPeriod + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let start = CGPoint(x: seam.x + CGFloat(i - count / 2) * h * 0.05, y: seam.y)
            let control = CGPoint(x: start.x, y: target.y)
            let a = 1 - p
            let x = a * a * start.x + 2 * a * p * control.x + p * p * target.x
            let y = a * a * start.y + 2 * a * p * control.y + p * p * target.y
            let r = h * 0.026 * (1 - p * 0.4)
            let alpha = sin(p * .pi)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 2.4, y: y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                     with: .radialGradient(Gradient(colors: [current.opacity(0.35 * alpha), current.opacity(0)]),
                                           center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 2.4))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(p < 0.5 ? current.opacity(0.95 * alpha) : energy.opacity(0.95 * alpha)))
        }

        // Leading-edge spark where the current lands.
        ctx.fill(Path(ellipseIn: CGRect(x: target.x - h * 0.07, y: target.y - h * 0.07, width: h * 0.14, height: h * 0.14)),
                 with: .radialGradient(Gradient(colors: [energy.opacity(0.75 * pulse), energy.opacity(0)]),
                                       center: target, startRadius: 0, endRadius: h * 0.07))

        // Shimmer sweeping left to right along the filled part of the bar.
        guard fill > 0 else { return }
        let sweep = (t / Self.flowPeriod).truncatingRemainder(dividingBy: 1)
        let bandW = max(filled.height * 2, filled.width * 0.35)
        let x0 = filled.minX - bandW + (filled.width + bandW) * sweep
        var clipped = ctx
        clipped.clip(to: Path(roundedRect: filled, cornerRadius: filled.height / 2))
        clipped.fill(Path(CGRect(x: x0, y: filled.minY, width: bandW, height: filled.height)),
                     with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)]),
                                           startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x0 + bandW, y: 0)))
    }
}

#if DEBUG
#Preview("Charging illustration") {
    VStack(spacing: 24) {
        ChargingIllustration(phase: .idle, percent: 62)
        ChargingIllustration(phase: .attached, percent: 62)
        ChargingIllustration(phase: .charging, percent: 48)
        ChargingIllustration(phase: .full, percent: 100)
        ChargingIllustration(phase: .unknown, percent: 31, dimmed: true)
    }
    .padding(24)
    .background(StrandPalette.surfaceBase)
}
#endif
