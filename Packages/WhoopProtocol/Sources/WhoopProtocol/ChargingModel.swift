import Foundation

// ChargingModel.swift — what NOOP knows about the strap's battery pack and charging, as two independent facts
// (pack attachment, active charging), each with its source, event time, receipt time and connection, plus a separately
// labelled inference from a sustained percentage rise. Pure and unit-tested; LiveState holds one per connection.
//
// Rules:
// - Attachment is not charging: BATTERY_PACK_CONNECTED says a pack is on, not that current flows.
// - Each fact keeps its own freshness. A new battery percentage never refreshes an old charging claim.
// - Ordering is by evidence time: a GET_BATTERY_PACK_INFO reply describes the moment it was REQUESTED, so a late reply
//   cannot override a newer BATTERY_PACK_REMOVED event.
// - A fact belongs to the connection it arrived on; a reconnect starts from unknown.
// - "Charging likely" (rising percentage) is never a confirmed claim and never drives the charge-complete alert.

public enum ChargingFact: String, Equatable, Sendable { case unknown, yes, no }

public struct ChargingEvidence: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// CHARGING_ON / CHARGING_OFF event (7/8).
        case chargingEvent
        /// BATTERY_PACK_CONNECTED / BATTERY_PACK_REMOVED event (21/22).
        case packEvent
        /// GET_BATTERY_PACK_INFO (151) reply in a verified shape.
        case packInfo
        /// WHOOP 4.0 BATTERY_LEVEL event's charging flag.
        case batteryEvent4
    }
    public let value: Bool
    public let source: Source
    /// When the state was true (event time, or the request time of a reply).
    public let eventAt: Date
    public let receivedAt: Date
    public let connection: UUID
}

/// GET_BATTERY_PACK_INFO reply, parsed only into shapes seen in captures.
public enum PackInfoReply: Equatable, Sendable {
    /// E02 (no pack attached): result FAILURE, body = 01 followed by 30 zero bytes (31 bytes).
    case detached
    /// SUCCESS: a pack answered, but the attached layout has never been captured; attachment stays unknown.
    case answeredUndecoded
    /// Any other shape: not evidence of anything.
    case unrecognized
}

public struct ChargingModel: Equatable, Sendable {
    public private(set) var connection: UUID
    public private(set) var attachment: ChargingEvidence?
    public private(set) var activity: ChargingEvidence?
    /// Percentage readings this connection (time, percent), for the "charging likely" inference.
    public private(set) var percents: [(at: Date, pct: Int)] = []

    /// A confirmed fact older than this (by receipt) is no longer shown as current. Events are edge-triggered, so this is
    /// generous; the periodic pack-info poll refreshes the detached state every minute.
    public static let factMaxAge: TimeInterval = 3 * 3600
    /// Rising-percentage inference: at least this rise, over at least this span, with no drop, from ≥ 3 readings…
    public static let likelyRise = 3
    public static let likelySpan: TimeInterval = 10 * 60
    /// …and it lapses this long after the last rising reading.
    public static let likelyExpiry: TimeInterval = 20 * 60

    public init(connection: UUID = UUID()) { self.connection = connection }

    public static func == (a: ChargingModel, b: ChargingModel) -> Bool {
        a.connection == b.connection && a.attachment == b.attachment && a.activity == b.activity
            && a.percents.map(\.pct) == b.percents.map(\.pct) && a.percents.map(\.at) == b.percents.map(\.at)
    }

    /// New connection: nothing carries over.
    public mutating func reset(connection: UUID) { self = ChargingModel(connection: connection) }

    // MARK: inputs

    /// A strap event (live only). Ignored if from another connection or older than the current fact.
    public mutating func applyEvent(kind: Whoop5EventKind, eventAt: Date, receivedAt: Date, connection: UUID) {
        guard connection == self.connection else { return }
        switch kind {
        case .chargingOn: set(\.activity, true, .chargingEvent, eventAt, receivedAt)
        case .chargingOff: set(\.activity, false, .chargingEvent, eventAt, receivedAt)
        case .batteryPackConnected:
            set(\.attachment, true, .packEvent, eventAt, receivedAt)
            // "Not charging" that was only inferred from the pack being OFF says nothing once it is back on: unknown.
            if let a = activity, a.eventAt <= eventAt, a.source == .packInfo || a.source == .packEvent { activity = nil }
        case .batteryPackRemoved:
            set(\.attachment, false, .packEvent, eventAt, receivedAt)
            set(\.activity, false, .packEvent, eventAt, receivedAt)   // the pack is the charger: removed → not charging
        default: break
        }
    }

    /// WHOOP 4.0 BATTERY_LEVEL event's charging flag.
    public mutating func applyBattery4Flag(_ charging: Bool, eventAt: Date, receivedAt: Date, connection: UUID) {
        guard connection == self.connection else { return }
        set(\.activity, charging, .batteryEvent4, eventAt, receivedAt)
    }

    /// A pack-info reply to a request sent at `requestedAt`.
    public mutating func applyPackInfo(_ r: PackInfoReply, requestedAt: Date, receivedAt: Date, connection: UUID) {
        guard connection == self.connection else { return }
        switch r {
        case .detached:
            set(\.attachment, false, .packInfo, requestedAt, receivedAt)
            set(\.activity, false, .packInfo, requestedAt, receivedAt)
        case .answeredUndecoded, .unrecognized:
            break
        }
    }

    /// A battery percentage (any source). Feeds only the inference; never refreshes a charging fact.
    public mutating func applyPercent(_ pct: Int, at: Date, connection: UUID) {
        guard connection == self.connection, (0...100).contains(pct) else { return }
        if let last = percents.last, last.pct == pct { return }   // only changes matter
        percents.append((at, pct))
        if percents.count > 12 { percents.removeFirst(percents.count - 12) }
    }

    private mutating func set(_ key: WritableKeyPath<ChargingModel, ChargingEvidence?>, _ v: Bool, _ s: ChargingEvidence.Source,
                              _ eventAt: Date, _ receivedAt: Date) {
        if let cur = self[keyPath: key], cur.eventAt > eventAt { return }   // older evidence never overrides newer
        self[keyPath: key] = ChargingEvidence(value: v, source: s, eventAt: eventAt, receivedAt: receivedAt, connection: connection)
    }

    // MARK: outputs

    private func fresh(_ e: ChargingEvidence?, now: Date) -> ChargingEvidence? {
        guard let e, now.timeIntervalSince(e.receivedAt) <= Self.factMaxAge else { return nil }
        return e
    }

    public func attached(now: Date) -> ChargingFact { fresh(attachment, now: now).map { $0.value ? .yes : .no } ?? .unknown }
    public func charging(now: Date) -> ChargingFact { fresh(activity, now: now).map { $0.value ? .yes : .no } ?? .unknown }
    /// The fresh charging fact itself (for "reported 14:02" captions).
    public func chargingEvidence(now: Date) -> ChargingEvidence? { fresh(activity, now: now) }
    public func attachmentEvidence(now: Date) -> ChargingEvidence? { fresh(attachment, now: now) }

    /// Sustained percentage rise, with no confirmed contrary fact. Not a confirmed charging state.
    public func chargingLikely(now: Date) -> Bool {
        guard charging(now: now) != .no, attached(now: now) != .no, let last = percents.last,
              now.timeIntervalSince(last.at) <= Self.likelyExpiry else { return false }
        // The longest non-decreasing tail of readings.
        var i = percents.count - 1
        while i > 0, percents[i - 1].pct <= percents[i].pct { i -= 1 }
        let tail = percents[i...]
        guard tail.count >= 3, let first = tail.first else { return false }
        return last.pct - first.pct >= Self.likelyRise && last.at.timeIntervalSince(first.at) >= Self.likelySpan
    }
}
