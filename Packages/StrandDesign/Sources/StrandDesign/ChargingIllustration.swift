import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Charging illustration
//
// A side view of the strap drawn from shapes so it stays crisp, themes with the palette and is cheap to render.
// The strap is one continuous silhouette: a band that fades out at both ends and a sensor pod rising out of it with
// filleted joins, and a slim level bar on the pod face.
//   idle / attached / unknown – the strap alone, neutral. The charging pack is drawn only while it is charging:
//              whether the pack is on or off otherwise is the caller's text, not the drawing.
//   charging – the pack seated on the pod with a lit bolt, a green seam where they meet, the level bar in the
//              blue→green charging gradient and a soft halo.
//   full     – the same seated pack, all green, bolt replaced by a check.
// Motion: when charging starts the pack lowers onto the pod and a light sweeps along the level bar twice; the
// illustration then holds still. Hovering replays the sweep. Only the small sweep layer redraws, and only on screen,
// with the app active and Reduce Motion off.
// It is an illustration: callers decide the phase from verified device state.

public struct ChargingIllustration: View {
    public enum Phase: Equatable {
        /// Pack reported detached: the strap alone.
        case idle
        /// Pack reported attached, charging not confirmed (unknown or not charging): the strap alone, unlit.
        case attached
        /// Nothing known about the pack (no report, or a stale / disconnected state): the strap alone.
        case unknown
        /// Verified charging on a fresh reading.
        case charging
        /// Verified charging at 100 %, or the charger's own full report.
        case full
    }

    public var phase: Phase
    /// Shown as the level bar's fill; nil draws an empty track.
    public var percent: Int?
    /// Dims the drawing for a stale or disconnected reading.
    public var dimmed: Bool
    public var height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = true
    @State private var packShown = false

    public init(phase: Phase, percent: Int?, dimmed: Bool = false, height: CGFloat = 120) {
        self.phase = phase; self.percent = percent; self.dimmed = dimmed; self.height = height
    }

    /// True only while the short sweep cue plays; the still drawing carries the state.
    @State private var sweeping = false
    @State private var sweepID = 0
    @State private var sweepStart = Date.distantPast
    static let sweepPeriod = 1.6
    static let sweepCycles = 2.0

    private var animating: Bool { sweeping && phase == .charging && !reduceMotion && appActive && !dimmed }
    private var fill: Double { Double(min(max(percent ?? 0, 0), 100)) / 100 }

    /// Lit only for confirmed charging or full.
    private var lit: Bool { phase == .charging || phase == .full }
    private var showsPack: Bool { lit }
    private var energy: Color { StrandPalette.statusPositive }
    private var energyInk: Color { StrandPalette.statusPositiveInk }
    /// Charging runs blue→green; full is all green.
    private var energyGradient: Gradient {
        Gradient(colors: [phase == .charging ? StrandPalette.accent : energy, energy])
    }
    /// The strap's neutral body tone: the text colour at low opacity reads on both light and dark surfaces.
    private var body0: Color { StrandPalette.textPrimary.opacity(0.10) }
    private var outline: Color { StrandPalette.textPrimary.opacity(0.16) }

    public var body: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { ctx, _ in drawStrap(in: &ctx, g: g) }
                if packShown {
                    pack(g)
                        .position(g.packCentre)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .offset(y: -g.h * 0.16).combined(with: .opacity),
                                                  removal: .offset(y: -g.h * 0.10).combined(with: .opacity)))
                }
                if animating {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        Canvas(rendersAsynchronously: false) { ctx, _ in
                            drawSweep(in: &ctx, g: g, elapsed: context.date.timeIntervalSince(sweepStart))
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: height * 2.2)
        .opacity(dimmed ? 0.5 : 1)
        .saturation(dimmed ? 0 : 1)
        .contentShape(Rectangle())
        .onAppear { setPack(showsPack, animated: false); if phase == .charging { startSweep(delay: 0) } }
        // Use the value onChange passes in: `self.phase` inside the action can still be the previous one.
        .onChange(of: phase) { new in
            let show = new == .charging || new == .full
            let arriving = show && !packShown
            setPack(show, animated: true)
            if new == .charging { startSweep(delay: arriving ? 0.45 : 0) } else { stopSweep() }
        }
        .onHover { inside in
            guard inside, phase == .charging, !sweeping else { return }
            let id = sweepID
            Task { @MainActor in await play(id: id) }
        }
        .onDisappear { stopSweep() }
        #if canImport(AppKit)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
        #endif
        .accessibilityHidden(true)   // the caller's text carries the state
    }

    // MARK: Motion

    private func setPack(_ show: Bool, animated: Bool) {
        guard packShown != show else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { packShown = show }
        } else if animated {
            withAnimation(StrandMotion.fade) { packShown = show }
        } else {
            packShown = show
        }
    }

    /// One short cue, after the pack has settled when it just arrived. A newer call supersedes an older one.
    private func startSweep(delay: Double) {
        sweepID += 1
        let id = sweepID
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await play(id: id)
        }
    }

    private func stopSweep() {
        sweepID += 1
        sweeping = false
    }

    private func play(id: Int) async {
        guard id == sweepID else { return }
        sweepStart = Date()
        withAnimation(StrandMotion.respecting(StrandMotion.fade)) { sweeping = true }
        try? await Task.sleep(nanoseconds: UInt64(Self.sweepPeriod * Self.sweepCycles * 1_000_000_000))
        guard id == sweepID else { return }
        withAnimation(StrandMotion.respecting(.easeOut(duration: 0.6))) { sweeping = false }
    }

    // MARK: Layout

    /// Shared geometry for the drawn strap and the pack view (separate so its arrival can animate).
    private struct Geometry {
        let size: CGSize
        var h: CGFloat { size.height }
        var w: CGFloat { size.width }
        /// Band centre line and half-thickness.
        var cy: CGFloat { h * 0.66 }
        var t: CGFloat { h * 0.06 }
        var bandMinX: CGFloat { w * 0.02 }
        var bandMaxX: CGFloat { w * 0.98 }
        /// Fillet radius where the pod meets the band.
        var f: CGFloat { h * 0.045 }
        var pod: CGRect {
            let pw = min(h * 0.92, w * 0.46)
            return CGRect(x: w / 2 - pw / 2, y: cy - h * 0.27, width: pw, height: h * 0.42)
        }
        var podTopRadius: CGFloat { h * 0.1 }
        var podBottomRadius: CGFloat { h * 0.045 }
        /// The pod's face (above the band) and the level bar centred in it.
        var face: CGRect { CGRect(x: pod.minX, y: pod.minY, width: pod.width, height: cy - t - pod.minY) }
        var bar: CGRect {
            let bw = pod.width * 0.6, bh = max(3, h * 0.055)
            return CGRect(x: pod.midX - bw / 2, y: face.midY - bh / 2 + h * 0.01, width: bw, height: bh)
        }
        var packSize: CGSize { CGSize(width: pod.width * 0.84, height: h * 0.2) }
        /// Seated: the pack's lower edge sits just inside the pod's top.
        var packCentre: CGPoint { CGPoint(x: pod.midX, y: pod.minY - packSize.height / 2 + h * 0.025) }
        var seamY: CGFloat { pod.minY + h * 0.012 }

        func filled(_ fill: Double) -> CGRect {
            CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * fill), height: bar.height)
        }

        /// Band + pod as one outline: the pod rises out of the band through concave fillets, the band ends are round.
        var silhouette: Path {
            let k: CGFloat = 0.5523   // cubic control distance for a quarter circle
            let p = pod, rt = podTopRadius, rb = podBottomRadius
            let top = cy - t, bottom = cy + t
            var path = Path()
            path.move(to: CGPoint(x: bandMinX + t, y: top))
            // Left band top → fillet up into the pod.
            path.addLine(to: CGPoint(x: p.minX - f, y: top))
            path.addQuadCurve(to: CGPoint(x: p.minX, y: top - f), control: CGPoint(x: p.minX, y: top))
            path.addLine(to: CGPoint(x: p.minX, y: p.minY + rt))
            path.addCurve(to: CGPoint(x: p.minX + rt, y: p.minY),
                          control1: CGPoint(x: p.minX, y: p.minY + rt * (1 - k)),
                          control2: CGPoint(x: p.minX + rt * (1 - k), y: p.minY))
            path.addLine(to: CGPoint(x: p.maxX - rt, y: p.minY))
            path.addCurve(to: CGPoint(x: p.maxX, y: p.minY + rt),
                          control1: CGPoint(x: p.maxX - rt * (1 - k), y: p.minY),
                          control2: CGPoint(x: p.maxX, y: p.minY + rt * (1 - k)))
            path.addLine(to: CGPoint(x: p.maxX, y: top - f))
            path.addQuadCurve(to: CGPoint(x: p.maxX + f, y: top), control: CGPoint(x: p.maxX, y: top))
            // Right band and its round end.
            path.addLine(to: CGPoint(x: bandMaxX - t, y: top))
            path.addCurve(to: CGPoint(x: bandMaxX, y: cy), control1: CGPoint(x: bandMaxX - t * (1 - k), y: top),
                          control2: CGPoint(x: bandMaxX, y: cy - t * k))
            path.addCurve(to: CGPoint(x: bandMaxX - t, y: bottom), control1: CGPoint(x: bandMaxX, y: cy + t * k),
                          control2: CGPoint(x: bandMaxX - t * (1 - k), y: bottom))
            // Right band bottom → fillet down into the pod's underside.
            path.addLine(to: CGPoint(x: p.maxX + f, y: bottom))
            path.addQuadCurve(to: CGPoint(x: p.maxX, y: bottom + f), control: CGPoint(x: p.maxX, y: bottom))
            path.addLine(to: CGPoint(x: p.maxX, y: p.maxY - rb))
            path.addCurve(to: CGPoint(x: p.maxX - rb, y: p.maxY),
                          control1: CGPoint(x: p.maxX, y: p.maxY - rb * (1 - k)),
                          control2: CGPoint(x: p.maxX - rb * (1 - k), y: p.maxY))
            path.addLine(to: CGPoint(x: p.minX + rb, y: p.maxY))
            path.addCurve(to: CGPoint(x: p.minX, y: p.maxY - rb),
                          control1: CGPoint(x: p.minX + rb * (1 - k), y: p.maxY),
                          control2: CGPoint(x: p.minX, y: p.maxY - rb * (1 - k)))
            path.addLine(to: CGPoint(x: p.minX, y: bottom + f))
            path.addQuadCurve(to: CGPoint(x: p.minX - f, y: bottom), control: CGPoint(x: p.minX, y: bottom))
            // Left band bottom and its round end.
            path.addLine(to: CGPoint(x: bandMinX + t, y: bottom))
            path.addCurve(to: CGPoint(x: bandMinX, y: cy), control1: CGPoint(x: bandMinX + t * (1 - k), y: bottom),
                          control2: CGPoint(x: bandMinX, y: cy + t * k))
            path.addCurve(to: CGPoint(x: bandMinX + t, y: top), control1: CGPoint(x: bandMinX, y: cy - t * k),
                          control2: CGPoint(x: bandMinX + t * (1 - k), y: top))
            path.closeSubpath()
            return path
        }
    }

    // MARK: Pack

    private func pack(_ g: Geometry) -> some View {
        let r = g.h * 0.075
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [StrandPalette.surfaceOverlay, StrandPalette.surfaceInset],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(StrandPalette.textPrimary.opacity(0.06)))
            .overlay(shape.strokeBorder(outline, lineWidth: 1))
            .overlay {
                Image(systemName: phase == .full ? "checkmark" : "bolt.fill")
                    .font(.system(size: g.h * 0.1, weight: .bold))
                    .foregroundStyle(LinearGradient(gradient: energyGradient, startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: StrandPalette.shadow, radius: 4, y: 2)
            .frame(width: g.packSize.width, height: g.packSize.height)
    }

    // MARK: Drawing

    private func horizontalFade(_ g: Geometry, _ color: Color) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [.init(color: color.opacity(0), location: 0),
                                         .init(color: color, location: 0.24),
                                         .init(color: color, location: 0.76),
                                         .init(color: color.opacity(0), location: 1)]),
                        startPoint: CGPoint(x: g.bandMinX, y: 0), endPoint: CGPoint(x: g.bandMaxX, y: 0))
    }

    private func drawStrap(in ctx: inout GraphicsContext, g: Geometry) {
        let pod = g.pod

        // Soft halo behind the pod while powered: a radial gradient, cheaper than a blur.
        if lit {
            let c = CGPoint(x: pod.midX, y: pod.minY)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - g.h * 0.75, y: c.y - g.h * 0.4, width: g.h * 1.5, height: g.h * 0.8)),
                     with: .radialGradient(Gradient(colors: [energy.opacity(0.18), energy.opacity(0)]),
                                           center: c, startRadius: g.h * 0.05, endRadius: g.h * 0.6))
        }
        // An opaque base under the pod so the halo never tints the strap itself.
        ctx.fill(Path(roundedRect: pod, cornerRadius: g.podTopRadius, style: .continuous),
                 with: .color(StrandPalette.surfaceRaised))

        // The silhouette, fading out towards the band ends, then a hairline outline that fades the same way.
        let silhouette = g.silhouette
        ctx.fill(silhouette, with: horizontalFade(g, StrandPalette.textPrimary.opacity(0.10)))
        ctx.stroke(silhouette, with: horizontalFade(g, StrandPalette.textPrimary.opacity(0.20)), lineWidth: 1)

        // Pod face: a gentle top-lit sheen and a thin highlight along its upper edge.
        let faceRadius = g.podTopRadius
        var face = ctx
        face.clip(to: Path(g.face))
        face.fill(Path(roundedRect: pod, cornerRadius: faceRadius, style: .continuous),
                  with: .linearGradient(Gradient(colors: [.white.opacity(0.10), .white.opacity(0)]),
                                        startPoint: CGPoint(x: 0, y: g.face.minY),
                                        endPoint: CGPoint(x: 0, y: g.face.maxY)))
        ctx.stroke(Path(roundedRect: pod.insetBy(dx: 1.5, dy: 1.5), cornerRadius: faceRadius - 1.5, style: .continuous)
                    .trimmedPath(from: 0.6, to: 0.9),
                   with: .color(.white.opacity(0.25)), lineWidth: 1)

        // Level bar.
        let bar = g.bar
        ctx.fill(Path(roundedRect: bar, cornerRadius: bar.height / 2), with: .color(StrandPalette.textPrimary.opacity(0.10)))
        if fill > 0 {
            let path = Path(roundedRect: g.filled(fill), cornerRadius: bar.height / 2)
            if lit {
                ctx.fill(path, with: .linearGradient(energyGradient, startPoint: CGPoint(x: bar.minX, y: 0),
                                                     endPoint: CGPoint(x: bar.maxX, y: 0)))
            } else {
                ctx.fill(path, with: .color(StrandPalette.textSecondary))
            }
        }

        guard lit else { return }
        // The seam where the seated pack meets the pod: a thin lit line over a soft glow.
        let seam = CGRect(x: pod.midX - g.packSize.width * 0.42, y: g.seamY - 0.75, width: g.packSize.width * 0.84, height: 1.5)
        ctx.fill(Path(ellipseIn: seam.insetBy(dx: -g.h * 0.04, dy: -g.h * 0.035)),
                 with: .radialGradient(Gradient(colors: [energy.opacity(0.35), energy.opacity(0)]),
                                       center: CGPoint(x: seam.midX, y: seam.midY), startRadius: 0,
                                       endRadius: seam.width * 0.55))
        ctx.fill(Path(roundedRect: seam, cornerRadius: 0.75), with: .color(energy.opacity(0.9)))
    }

    /// The charging cue: a soft band of light travels along the filled part of the bar while the seam brightens.
    private func drawSweep(in ctx: inout GraphicsContext, g: Geometry, elapsed: Double) {
        guard elapsed >= 0 else { return }
        let p = (elapsed / Self.sweepPeriod).truncatingRemainder(dividingBy: 1)
        let ease = p * p * (3 - 2 * p)
        let glow = sin(p * .pi)

        let seamW = g.packSize.width * 0.84
        let seam = CGRect(x: g.pod.midX - seamW / 2, y: g.seamY - 0.75, width: seamW, height: 1.5)
        ctx.fill(Path(ellipseIn: seam.insetBy(dx: -g.h * 0.05, dy: -g.h * 0.05)),
                 with: .radialGradient(Gradient(colors: [energy.opacity(0.35 * glow), energy.opacity(0)]),
                                       center: CGPoint(x: seam.midX, y: seam.midY), startRadius: 0, endRadius: seamW * 0.6))

        let filled = g.filled(fill)
        let bandW = max(filled.height * 3, filled.width * 0.45)
        let x0 = filled.minX - bandW + (filled.width + bandW) * ease
        var clipped = ctx
        clipped.clip(to: Path(roundedRect: filled, cornerRadius: filled.height / 2))
        clipped.fill(Path(CGRect(x: x0, y: filled.minY, width: bandW, height: filled.height)),
                     with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)]),
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
