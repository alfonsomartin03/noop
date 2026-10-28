import Foundation

// SleepState.swift — the vocabulary for a stretch of a sleep record.
//
// Sleep/wake state and sleep STAGE are different claims with different reliability: wearables detect sleep far
// better than they separate quiet wake or classify stages (Chinoy 2021; Schyvens 2025). So "asleep, stage not
// estimated" is its own state, and "no usable data" (strap off, charging, BLE loss) is never folded into wake,
// light or deep. Stored in `StageSegment.stage` as the raw value.

public enum SleepState: String, Codable, Sendable, CaseIterable {
    case wake
    /// Asleep, but no stage estimate (abstention: e.g. no cardiac data for the epoch).
    case asleep
    case light
    case deep
    case rem
    /// Sleep/wake state not observed. Never counted as wake, sleep or any stage.
    case unknown

    public init(label: String) { self = SleepState(rawValue: label) ?? .unknown }

    /// Counts toward total sleep time (staged or not).
    public var isSleep: Bool { self == .asleep || self == .light || self == .deep || self == .rem }
    /// Carries a stage estimate.
    public var isStaged: Bool { self == .light || self == .deep || self == .rem }
    /// Sleep/wake state observed.
    public var isKnown: Bool { self != .unknown }
}

/// Why a segment is `.unknown` or `.asleep` — provenance, not a probability.
public enum SleepStateReason {
    public static let noMotionData = "no motion data"           // epoch without gravity samples (off-wrist / gap)
    public static let noCardiacData = "no cardiac data"         // sleep epoch without HR: stage withheld
}
