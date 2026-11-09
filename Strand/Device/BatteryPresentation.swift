import SwiftUI
import StrandDesign
import WhoopProtocol

/// The strap battery as every surface shows it (top-right badge, menu bar, Settings → Strap, the live sheet), so they
/// agree on thresholds, freshness, attachment and charging.
///
/// - Low is below the low-battery alert's threshold (`BatteryAlertPolicy.lowPercent`), so the red badge and the
///   notification mean the same thing.
/// - The PERCENTAGE is stale when older than the alert policy's `staleAfter` or from before a disconnect: shown dimmed
///   with its time. Charging and attachment have their own freshness (`ChargingModel`); a fresh percentage never
///   refreshes them, and a disconnect makes both unknown.
/// - Charging is only what the strap reported (confirmed). A sustained percentage rise is shown separately as
///   "charging likely", never as charging, and never counts as full. Nothing here estimates time to full.
struct BatteryPresentation: Equatable {
    enum Charge: Equatable { case charging, likely, notCharging, unknown }
    enum Attachment: Equatable { case attached, detached, unknown }
    enum Level: Equatable { case low, medium, normal }

    let percent: Int?
    let stale: Bool
    let charge: Charge
    let attachment: Attachment
    let connected: Bool
    let measuredAt: Date?
    /// When the strap's charging fact was received (for "reported 14:02").
    let chargeReportedAt: Date?
    /// "Charging likely" holds against an older strap report of not charging / detached: when that report was received.
    let contradictedReportAt: Date?
    /// The charge / attachment fact is the last known one from before a reconnect, held until the strap reports again.
    let chargeHeld: Bool
    let attachmentHeld: Bool

    static let lowBelow = BatteryAlertPolicy().lowPercent
    static let mediumBelow = 35
    static let staleAfter = BatteryAlertPolicy().staleAfter

    init(percent: Int?, stale: Bool, charge: Charge, attachment: Attachment = .unknown, connected: Bool, measuredAt: Date?,
         chargeReportedAt: Date? = nil, contradictedReportAt: Date? = nil, chargeHeld: Bool = false, attachmentHeld: Bool = false) {
        self.percent = percent.map { min(max($0, 0), 100) }
        self.stale = stale
        self.charge = connected ? charge : .unknown
        self.attachment = connected ? attachment : .unknown
        self.connected = connected
        self.measuredAt = measuredAt
        self.chargeReportedAt = chargeReportedAt
        self.contradictedReportAt = connected && charge == .likely ? contradictedReportAt : nil
        self.chargeHeld = connected && chargeHeld
        self.attachmentHeld = connected && attachmentHeld
    }

    /// From the live strap state. A typed reading (`battery`) carries its time and source; the plain `batteryPct`
    /// fallback is used only while connected, as before. Charging and attachment come from `live.charging`.
    @MainActor
    init(live: LiveState, now: Date = Date()) {
        let status = live.battery
        let pct = status?.percent ?? (live.connected ? live.batteryPct.map { Int($0.rounded()) } : nil)
        let stale = !live.connected || (status?.isStale(now: now, after: Self.staleAfter) ?? false)
        let m = live.charging
        // A rise that began after the strap's last "not charging" outranks it as "likely" (never as charging).
        let charge: Charge = switch m.charging(now: now) {
        case .yes: .charging
        case .no: m.chargingLikely(now: now) ? .likely : .notCharging
        case .unknown: m.chargingLikely(now: now) ? .likely : .unknown
        }
        let attachment: Attachment = switch m.attached(now: now) { case .yes: .attached; case .no: .detached; case .unknown: .unknown }
        self.init(percent: pct, stale: stale, charge: charge, attachment: attachment, connected: live.connected,
                  measuredAt: status?.at, chargeReportedAt: m.chargingEvidence(now: now)?.receivedAt,
                  contradictedReportAt: m.likelyContradicts(now: now)?.receivedAt,
                  chargeHeld: m.chargingEvidence(now: now)?.isHeld ?? false,
                  attachmentHeld: m.attachmentEvidence(now: now)?.isHeld ?? false)
    }

    /// What the charging illustration draws, from the same model (never more than it says).
    var illustration: IllustrationState {
        if !connected { return .unknown }
        if isFull { return .full }
        if isCharging { return .charging }
        if attachment == .attached { return .attached }
        if attachment == .detached { return .detached }
        return .unknown
    }
    enum IllustrationState: Equatable { case detached, attached, charging, full, unknown }

    var isCharging: Bool { charge == .charging }
    /// Charging confirmed and a fresh reading of 100 %, the same condition the charging-complete alert uses.
    var isFull: Bool { isCharging && !stale && (percent ?? 0) >= 100 }

    /// A fresh reading below the low threshold while nothing says the strap is on its charger. Stale or unknown
    /// readings never raise it (the strap may have been charged since), and charging, "likely" or an attached pack
    /// clear it.
    var needsCharge: Bool {
        guard connected, !stale, level == .low else { return false }
        return charge != .charging && charge != .likely && attachment != .attached
    }

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
            if !connected { return "Not connected · last reading\(when)" }
            // The percentage is old, but a charging fact keeps its own freshness.
            let prefix = isCharging ? "Charging · " : attachment == .attached ? "Charger attached · " : ""
            return prefix.isEmpty ? "Last reading\(when)" : prefix + "last reading\(when)"
        }
        if isFull { return "Fully charged" }
        if isCharging { return chargeHeld ? "Charging · last reported \(chargeReportedAt.map { Self.time($0) } ?? "before reconnecting")" : "Charging" }
        if charge == .likely { return "Battery increasing — charging likely" }
        if attachment == .attached { return charge == .notCharging ? "Charger attached · not charging" : "Charger attached" }
        if percent < Self.lowBelow { return "Low · charge soon to avoid gaps" }
        return attachment == .detached || charge == .notCharging ? "On battery" : "Battery"
    }

    // MARK: The three facts, kept apart

    /// One labelled fact: what is known, and how (or "unknown" with why). Strap battery, pack and charging never merge.
    struct Fact: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String?
        let known: Bool
    }

    private static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    var facts: [Fact] {
        let strap: Fact = {
            guard let percent else {
                return Fact(id: "strap", label: "Strap battery", value: "Unknown",
                            detail: connected ? "Waiting for a reading" : "Strap not connected", known: false)
            }
            let when = measuredAt.map { "at \(Self.time($0))" }
            return Fact(id: "strap", label: "Strap battery", value: "\(percent)%",
                        detail: stale ? (connected ? "Last reading" : "Not connected · last reading") + (when.map { " \($0)" } ?? "") : nil,
                        known: !stale)
        }()
        let pack: Fact = {
            guard connected else { return Fact(id: "pack", label: "Charging pack", value: "Unknown", detail: "Strap not connected", known: false) }
            switch attachment {
            case .attached: return Fact(id: "pack", label: "Charging pack", value: "Attached", detail: attachmentSource, known: true)
            case .detached: return Fact(id: "pack", label: "Charging pack", value: "Not attached", detail: attachmentSource, known: true)
            case .unknown: return Fact(id: "pack", label: "Charging pack", value: "Unknown", detail: "No recent report from the strap", known: false)
            }
        }()
        let charging: Fact = {
            guard connected else { return Fact(id: "charging", label: "Charging", value: "Unknown", detail: "Strap not connected", known: false) }
            switch charge {
            case .charging:
                return Fact(id: "charging", label: "Charging", value: isFull ? "Full" : "Yes", detail: chargeSource, known: true)
            case .likely:
                let conflict = contradictedReportAt.map { " · the strap reported otherwise at \(Self.time($0))" } ?? ""
                return Fact(id: "charging", label: "Charging", value: "Likely",
                            detail: "Inferred from a rising percentage, not reported by the strap" + conflict, known: false)
            case .notCharging:
                return Fact(id: "charging", label: "Charging", value: "No", detail: chargeSource, known: true)
            case .unknown:
                return Fact(id: "charging", label: "Charging", value: "Unknown", detail: "No recent report from the strap", known: false)
            }
        }()
        return [strap, pack, charging]
    }

    private var chargeSource: String {
        let at = chargeReportedAt.map { " at \(Self.time($0))" } ?? ""
        return chargeHeld ? "Last reported by the strap\(at), before reconnecting · checking again" : "Reported by the strap\(at)"
    }
    private var attachmentSource: String {
        attachmentHeld ? "Last reported by the strap before reconnecting · checking again" : "Reported by the strap"
    }

    var accessibilityLabel: String {
        guard let percent else { return "Strap battery unknown, \(statusText.lowercased())" }
        return "Strap battery \(percent) percent, \(statusText.lowercased())"
    }
}
