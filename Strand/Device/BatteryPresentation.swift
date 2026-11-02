import SwiftUI
import StrandDesign
import WhoopProtocol

/// The strap battery as every surface shows it (top-right badge, menu bar, Settings → Strap, the live sheet), so they
/// agree on thresholds, freshness and charging.
///
/// - Low is below the low-battery alert's threshold (`BatteryAlertPolicy.lowPercent`), so the red badge and the
///   notification mean the same thing.
/// - A reading older than the alert policy's `staleAfter`, or one from before a disconnect, is stale: shown dimmed
///   with its time, and never shown as charging.
/// - Charging is only what a verified source reported on a fresh reading. A rising percentage is never taken as
///   charging, and nothing here estimates time to full or a charging-pack level (the protocol reports neither).
struct BatteryPresentation: Equatable {
    enum Charge: Equatable { case charging, notCharging, unknown }
    enum Level: Equatable { case low, medium, normal }

    let percent: Int?
    let stale: Bool
    let charge: Charge
    let connected: Bool
    let measuredAt: Date?

    static let lowBelow = BatteryAlertPolicy().lowPercent
    static let mediumBelow = 35
    static let staleAfter = BatteryAlertPolicy().staleAfter

    init(percent: Int?, stale: Bool, charge: Charge, connected: Bool, measuredAt: Date?) {
        self.percent = percent.map { min(max($0, 0), 100) }
        self.stale = stale
        self.charge = stale ? .unknown : charge
        self.connected = connected
        self.measuredAt = measuredAt
    }

    /// From the live strap state. A typed reading (`battery`) carries its time and source; the plain `batteryPct`
    /// fallback is used only while connected, as before.
    @MainActor
    init(live: LiveState, now: Date = Date()) {
        let status = live.battery
        let pct = status?.percent ?? (live.connected ? live.batteryPct.map { Int($0.rounded()) } : nil)
        let stale = !live.connected || (status?.isStale(now: now, after: Self.staleAfter) ?? false)
        let charge: Charge = switch status?.charging { case true?: .charging; case false?: .notCharging; case nil: .unknown }
        self.init(percent: pct, stale: stale, charge: charge, connected: live.connected, measuredAt: status?.at)
    }

    var isCharging: Bool { charge == .charging }
    /// Charging confirmed and the strap reads 100 %, the same condition the charging-complete alert uses.
    var isFull: Bool { isCharging && (percent ?? 0) >= 100 }

    var level: Level? {
        guard let p = percent else { return nil }
        return p < Self.lowBelow ? .low : p < Self.mediumBelow ? .medium : .normal
    }

    /// Fill/icon tint: neutral when unknown or stale, so an old reading doesn't look current.
    var tint: Color {
        guard let level, !stale else { return StrandPalette.textTertiary }
        if isCharging { return StrandPalette.statusPositive }
        switch level {
        case .low: return StrandPalette.statusCritical
        case .medium: return StrandPalette.statusWarning
        case .normal: return StrandPalette.statusPositive
        }
    }

    /// Text-safe version of `tint` for numbers and labels.
    var ink: Color {
        guard let level, !stale else { return StrandPalette.textSecondary }
        if isCharging { return StrandPalette.statusPositiveInk }
        switch level {
        case .low: return StrandPalette.statusCriticalInk
        case .medium: return StrandPalette.statusWarningInk
        case .normal: return StrandPalette.textPrimary
        }
    }

    var tone: StrandTone {
        guard let level, !stale else { return .neutral }
        if isCharging { return .positive }
        switch level { case .low: return .critical; case .medium: return .warning; case .normal: return .positive }
    }

    /// SF Symbol for the level; the bolt variant only while charging is confirmed.
    var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        guard let p = percent else { return "battery.0percent" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    var valueText: String { percent.map { "\($0)%" } ?? "—" }

    /// One short status line, the same words everywhere.
    var statusText: String {
        guard let percent else { return connected ? "Reading battery…" : "Strap not connected" }
        if stale {
            let when = measuredAt.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return connected ? "Last reading\(when)" : "Not connected · last reading\(when)"
        }
        if isFull { return "Fully charged" }
        if isCharging { return "Charging" }
        if percent < Self.lowBelow { return "Low · charge soon to avoid gaps" }
        return charge == .notCharging ? "On battery" : "Battery"
    }

    var accessibilityLabel: String {
        guard let percent else { return "Strap battery unknown, \(statusText.lowercased())" }
        return "Strap battery \(percent) percent, \(statusText.lowercased())"
    }
}
