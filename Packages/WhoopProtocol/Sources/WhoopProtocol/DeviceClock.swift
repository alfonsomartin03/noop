import Foundation

/// One GET_CLOCK exchange: host wall time when the request was written and when the reply arrived,
/// plus the strap time in the reply.
public struct ClockSample: Equatable, Sendable {
    public let hostSent: Double
    public let hostReceived: Double
    public let device: Double
    public init(hostSent: Double, hostReceived: Double, device: Double) {
        self.hostSent = hostSent; self.hostReceived = hostReceived; self.device = device
    }
}

/// Estimated relationship between the strap clock and the host clock: `host ≈ device + offset`.
/// A positive offset means the strap runs behind (observed: +14…18 s on fw 50.43.1.0).
public struct ClockEstimate: Equatable, Sendable {
    public let offset: Double
    /// Half the round trip plus the reply's 1-s resolution: the true offset lies within ±uncertainty.
    public let uncertainty: Double
    public let measuredAt: Double

    /// Strap time → host time. Applied only to values the caller explicitly converts; stored strap
    /// timestamps are never rewritten.
    public func hostTime(fromDevice t: Double) -> Double { t + offset }
    public func deviceTime(fromHost t: Double) -> Double { t - offset }
}

/// Turns GET_CLOCK samples into an offset estimate.
///
/// The reply is generated somewhere between send and receive, so the midpoint is the best host time
/// for it and half the round trip bounds the error. The first command after a (re)connect can wait
/// 5–12 s for an answer, so samples whose round trip exceeds `maxRoundTrip` are rejected rather than
/// trusted with a huge error bar.
public struct DeviceClockEstimator: Sendable {
    public enum Rejection: Equatable, Sendable {
        case roundTripTooLong(Double)
        case implausibleOffset(Double)
        case negativeRoundTrip
    }
    public var maxRoundTrip: Double = 3
    /// More than a day apart = the strap's RTC was reset, not drift. Reported, never applied.
    public var maxPlausibleOffset: Double = 86_400
    /// A change larger than this between estimates is a clock jump (RTC reset / SET_CLOCK elsewhere).
    public var jumpThreshold: Double = 5
    public private(set) var current: ClockEstimate?

    public init() {}

    public enum Outcome: Equatable, Sendable {
        case accepted(ClockEstimate)
        /// Accepted, but it moved more than `jumpThreshold` from the previous estimate.
        case jumped(from: ClockEstimate, to: ClockEstimate)
        case rejected(Rejection)
    }

    public mutating func add(_ s: ClockSample) -> Outcome {
        let rtt = s.hostReceived - s.hostSent
        guard rtt >= 0 else { return .rejected(.negativeRoundTrip) }
        guard rtt <= maxRoundTrip else { return .rejected(.roundTripTooLong(rtt)) }
        let offset = (s.hostSent + s.hostReceived) / 2 - s.device
        guard abs(offset) <= maxPlausibleOffset else { return .rejected(.implausibleOffset(offset)) }
        let next = ClockEstimate(offset: offset, uncertainty: rtt / 2 + 0.5, measuredAt: s.hostReceived)
        defer { current = next }
        if let prev = current, abs(prev.offset - offset) > jumpThreshold + prev.uncertainty + next.uncertainty {
            return .jumped(from: prev, to: next)
        }
        return .accepted(next)
    }

    public mutating func reset() { current = nil }
}
